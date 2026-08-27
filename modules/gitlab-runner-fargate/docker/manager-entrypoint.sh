#!/bin/sh
# Manager entrypoint. Ships in YOUR image; Terraform never transports it.
#
# That is the point. In the EC2 sibling module, the config travelled through a
# shell heredoc inside user_data, and three separate audits found a new way to
# turn a caller-supplied string into shell there. Here the module passes only
# base64 blobs and one secret through the ECS task definition, and the shell that
# consumes them is a reviewed, shellcheck-clean file in the image. No caller
# value is ever interpolated into shell.
#
# Contract with the module (all supplied by the task definition):
#   RUNNER_CONFIG_B64          base64 config.toml, token as a placeholder
#   RUNNER_FARGATE_CONFIG_B64  base64 fargate.toml
#   RUNNER_CA_PEM_B64          base64 CA bundle, or empty
#   RUNNER_TOKEN               the glrt- token, from Secrets Manager via valueFrom
#   AWS_REGION / AWS_DEFAULT_REGION
set -eu

CONFIG_DIR=/etc/gitlab-runner
METADATA_DIR=/opt/gitlab-runner/metadata
CONFIG="$CONFIG_DIR/config.toml"

fatal() { echo "FATAL: $*" >&2; exit 1; }

[ -n "${RUNNER_CONFIG_B64:-}" ]         || fatal "RUNNER_CONFIG_B64 is empty"
[ -n "${RUNNER_FARGATE_CONFIG_B64:-}" ] || fatal "RUNNER_FARGATE_CONFIG_B64 is empty"
[ -n "${RUNNER_TOKEN:-}" ]              || fatal "RUNNER_TOKEN is empty - check the task execution role can read the secret"

# gitlab-runner writes .runner_system_id next to config.toml and refuses to start
# if it cannot, which is why the task definition mounts a writable volume here
# rather than running with a fully read-only root filesystem.
mkdir -p "$CONFIG_DIR" "$METADATA_DIR"
chmod 0700 "$CONFIG_DIR" "$METADATA_DIR"

# 0600 BEFORE any content lands, not after.
install -m 0600 /dev/null "$CONFIG"
printf '%s' "$RUNNER_CONFIG_B64" | base64 -d > "$CONFIG"

install -m 0600 /dev/null "$CONFIG_DIR/fargate.toml"
printf '%s' "$RUNNER_FARGATE_CONFIG_B64" | base64 -d > "$CONFIG_DIR/fargate.toml"

# Substitute the token via python's stdin - never argv, so it cannot appear in
# `ps` or /proc/*/cmdline, and never a sed expression, so no character in the
# token can be interpreted as syntax.
python3 - "$CONFIG" <<'PY'
import os, sys, pathlib
path = pathlib.Path(sys.argv[1])
token = os.environ["RUNNER_TOKEN"]
text = path.read_text()
if "RUNNER_TOKEN_PLACEHOLDER" not in text:
    sys.exit("FATAL: placeholder missing from config.toml - refusing to start "
             "with a config whose token was not substituted")
path.write_text(text.replace("RUNNER_TOKEN_PLACEHOLDER", token))
PY

# Prove the substitution happened, quietly. grep -q writes nothing, so the token
# cannot reach the log through this check.
if grep -q "RUNNER_TOKEN_PLACEHOLDER" "$CONFIG"; then
  fatal "token substitution failed"
fi
unset RUNNER_TOKEN

# Private CA for a self-managed GitLab.
#
# Written ONLY into the writable config volume. The previous version also copied
# it to /usr/local/share/ca-certificates and ran update-ca-certificates - both of
# which live on the read-only root filesystem the task definition sets. Under
# `set -e` the unguarded `cp` failed with EROFS and killed the entrypoint before
# gitlab-runner ever started, so every caller who set a private CA got a
# crash-looping manager. config.toml's tls-ca-file points here instead, which is
# the runner's own documented mechanism and needs no system trust store change.
if [ -n "${RUNNER_CA_PEM_B64:-}" ]; then
  mkdir -p "$CONFIG_DIR/certs"
  chmod 0700 "$CONFIG_DIR/certs"
  install -m 0644 /dev/null "$CONFIG_DIR/certs/ca.crt"
  printf '%s' "$RUNNER_CA_PEM_B64" | base64 -d > "$CONFIG_DIR/certs/ca.crt"
  # Sanity-check it, because a truncated or mis-encoded bundle otherwise surfaces
  # as an opaque TLS error at registration time.
  grep -q "BEGIN CERTIFICATE" "$CONFIG_DIR/certs/ca.crt" \
    || fatal "RUNNER_CA_PEM_B64 did not decode to a PEM certificate bundle"
fi

# ECS sends SIGTERM, and gitlab-runner treats SIGTERM as "abort every running
# build". SIGQUIT is the graceful one: stop accepting work, exit when current
# builds finish. Forward it so a redeploy drains instead of killing.
#
# This only buys as much time as the task definition's stopTimeout, which Fargate
# caps at 120s. Jobs longer than that still die on redeploy - a platform limit.
runner_pid=""
on_term() {
  echo "SIGTERM received; forwarding SIGQUIT for a graceful drain" >&2
  [ -n "$runner_pid" ] && kill -QUIT "$runner_pid" 2>/dev/null || true
  wait "$runner_pid" 2>/dev/null || true
  exit 0
}
trap on_term TERM INT

gitlab-runner run --working-directory=/home/gitlab-runner &
runner_pid=$!
wait "$runner_pid"
