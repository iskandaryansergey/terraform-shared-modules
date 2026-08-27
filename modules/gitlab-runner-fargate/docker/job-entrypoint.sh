#!/bin/sh
# Job task entrypoint. Installs the per-job public key the driver injects, then
# execs sshd.
#
# The driver generates a FRESH ECDSA P-256 keypair per job, keeps the private
# half on the manager at mode 0600, and passes the public half as SSH_PUBLIC_KEY
# in a RunTask container override - so there is no static key to manage or
# rotate. It injects it ONLY into a container named exactly `ci-coordinator`.
set -eu

# An empty value here yields an empty authorized_keys and a job that hangs until
# the driver's retry budget expires, with no useful error. Fail loudly instead.
# The reference image GitLab links to omits this check; that is why jobs on it
# hang mysteriously.
[ -n "${SSH_PUBLIC_KEY:-}" ] || { echo "FATAL: SSH_PUBLIC_KEY is empty - is this container named ci-coordinator?" >&2; exit 1; }

# The user the driver will authenticate as. Supplied by the task definition from
# the module's ssh_username input, so the image and fargate.toml cannot disagree.
#
# The previous version hardcoded /root/.ssh, which meant any ssh_username other
# than "root" wrote the key into the wrong home directory: prepare succeeded, the
# task reached RUNNING, and then run's SSH was refused - a job that hangs until
# the driver's retry budget expires, after paying for the full task lifetime.
SSH_USERNAME="${SSH_USERNAME:-root}"

if ! getent passwd "$SSH_USERNAME" >/dev/null 2>&1; then
  echo "FATAL: SSH_USERNAME=$SSH_USERNAME does not exist in this image." >&2
  echo "       Add it in Dockerfile.job (useradd -m -s /bin/sh $SSH_USERNAME)," >&2
  echo "       or set ssh_username = \"root\" on every job profile." >&2
  exit 1
fi

HOME_DIR="$(getent passwd "$SSH_USERNAME" | cut -d: -f6)"
[ -n "$HOME_DIR" ] || { echo "FATAL: $SSH_USERNAME has no home directory" >&2; exit 1; }

KEYS="$HOME_DIR/.ssh"
mkdir -p "$KEYS"
install -m 0600 /dev/null "$KEYS/authorized_keys"
printf '%s\n' "$SSH_PUBLIC_KEY" > "$KEYS/authorized_keys"
chown -R "$SSH_USERNAME" "$KEYS"
chmod 0700 "$KEYS"
unset SSH_PUBLIC_KEY

# Host keys are generated PER TASK, not baked into the image. That is why host-key
# pinning is impossible with the upstream driver - it has no out-of-band channel
# to learn a key generated seconds ago - and it is also why a stale key from a
# previous task can never be presented.
#
# Not `|| true`: a failure here means sshd cannot start, and swallowing it
# produces exactly the diagnostic-free hang the SSH_PUBLIC_KEY check above exists
# to prevent.
ssh-keygen -A || { echo "FATAL: ssh-keygen -A failed; sshd cannot start" >&2; exit 1; }

# PermitRootLogin matters only when SSH_USERNAME is root; harmless otherwise.
exec /usr/sbin/sshd -D -e \
  -o PasswordAuthentication=no \
  -o PermitRootLogin=prohibit-password \
  -o PubkeyAuthentication=yes \
  -o AllowTcpForwarding=no \
  -o X11Forwarding=no \
  -o PermitTunnel=no \
  -o AllowAgentForwarding=no \
  -o MaxAuthTries=3 \
  -o LoginGraceTime=30
