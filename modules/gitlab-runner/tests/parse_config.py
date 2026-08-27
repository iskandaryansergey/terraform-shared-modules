#!/usr/bin/env python3
"""Parse the rendered config.toml and assert the SHAPE, not just the text.

`terraform test` can only match substrings, and a substring assertion cannot tell
`instance_ready_command` under [runners.autoscaler] from the same key under
[runners.autoscaler.plugin_config] - TOML binds a bare key to whichever table was
opened last. That distinction is the difference between a working readiness gate
and dead config, so it gets a real parser.

Usage: parse_config.py <config.toml> [manager-user-data.sh]
"""
import sys
import pathlib

try:
    import tomllib  # py3.11+
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib  # type: ignore

failures: list[str] = []


def check(ok: bool, msg: str) -> None:
    if not ok:
        failures.append(msg)


def check_policy_order(config_text: str) -> None:
    """P0-2 regression guard: the catch-all must not be the LAST policy.

    GitLab Runner selects the LAST MATCHING policy. A catch-all of ["* * * * *"]
    matches at every instant, so placing it last makes it win always and every
    more specific policy above it becomes unreachable dead config.

    This is invisible to inspection and to substring assertions: the rendered
    config.toml visibly contains `idle_count = 1`, correctly formatted, in the
    right table. It is simply never selected. Only an ORDER-aware check can see
    it, which is why it lives in the parser.
    """
    doc = tomllib.loads(config_text)
    runners = doc.get("runners")
    if not isinstance(runners, list) or not runners:
        return
    auto = runners[0].get("autoscaler", {})
    policies = auto.get("policy")
    if not isinstance(policies, list) or len(policies) < 2:
        return

    last = policies[-1]
    check("* * * * *" not in last.get("periods", []),
          f"the LAST [[runners.autoscaler.policy]] uses the catch-all period "
          f"[\"* * * * *\"]. GitLab Runner takes the last MATCHING policy, and a "
          f"catch-all matches always - so it wins at every instant and all "
          f"{len(policies) - 1} policy/policies above it are unreachable. Any warm "
          f"pool configured there silently does not exist and every job pays a full "
          f"cold start. Put the catch-all FIRST.")

    # A warm pool that is configured should be reachable, i.e. not shadowed.
    warm = [i for i, pol in enumerate(policies) if pol.get("idle_count", 0) > 0]
    if warm:
        catch_all_at = [i for i, pol in enumerate(policies)
                        if "* * * * *" in pol.get("periods", [])]
        if catch_all_at:
            check(max(warm) > max(catch_all_at),
                  f"a policy with idle_count > 0 sits at index {max(warm)}, BEFORE the "
                  f"catch-all at index {max(catch_all_at)}. Last-match-wins means the "
                  f"catch-all overrides it, so the warm pool never materialises.")


def check_region_dropin(user_data: str) -> None:
    """P0-1 regression guard: gitlab-runner.service must receive an AWS region.

    aws-sdk-go-v2 does not read the region from IMDS by default, and
    fleeting-plugin-aws exposes no `region` config key - so the process
    environment is the only route. systemd starts services with a clean
    environment, so an `export` in the bootstrap shell and an `Environment=` line
    in some OTHER unit both fail to reach it.

    Without this the fleet launches zero workers while every alarm reports
    healthy, because registration long-polls over HTTPS and uses no AWS SDK.
    """
    check("gitlab-runner.service.d" in user_data,
          "the bootstrap must write a systemd drop-in under "
          "/etc/systemd/system/gitlab-runner.service.d/. Without it "
          "gitlab-runner.service starts with a clean environment, the fleeting "
          "plugin cannot resolve an AWS region, DescribeAutoScalingGroups fails, "
          "and the fleet launches ZERO workers with every alarm green.")

    # The drop-in must be written BEFORE the runner is started, and before
    # `fleeting install`, which also calls the AWS API.
    #
    # Line-based and comment-skipping on purpose. A substring search over the whole
    # script matched the explanatory COMMENT above the drop-in ("Written before
    # `fleeting install` because...") instead of the command, and reported a false
    # positive on correct code. A guard that cries wolf is a guard someone
    # switches off - so it has to find the invocation, not the mention.
    def _first_command_line(needle: str) -> int:
        for i, line in enumerate(user_data.splitlines()):
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            if needle in stripped:
                return i
        return -1

    dropin_at = _first_command_line("gitlab-runner.service.d")
    install_at = _first_command_line("gitlab-runner fleeting install")
    if dropin_at != -1 and install_at != -1:
        check(dropin_at < install_at,
              f"the AWS region drop-in (line {dropin_at + 1}) must be written BEFORE "
              f"`gitlab-runner fleeting install` (line {install_at + 1}) - that "
              f"command talks to the AWS API too, so it needs the region as well.")

    for var in ("AWS_REGION", "AWS_DEFAULT_REGION"):
        check(f"Environment={var}=" in user_data,
              f"the systemd drop-in must set {var}. aws-sdk-go-v2 reads "
              f"AWS_REGION and falls back to AWS_DEFAULT_REGION; set both.")

    # The drop-in is useless if nothing reloads systemd before enabling.
    reload_at = -1
    enable_at = -1
    for i, line in enumerate(user_data.splitlines()):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if stripped.startswith("systemctl daemon-reload") and i < 10_000:
            # The LAST reload before enable is the one that matters.
            if enable_at == -1:
                reload_at = i
        if stripped.startswith("systemctl enable gitlab-runner") and enable_at == -1:
            enable_at = i
    if reload_at != -1 and enable_at != -1:
        check(reload_at < enable_at,
              "systemctl daemon-reload must run after writing the drop-in and "
              "before `systemctl enable gitlab-runner`, or the unit starts without "
              "the region.")


def main() -> int:
    cfg_path = pathlib.Path(sys.argv[1])
    raw = cfg_path.read_text()

    try:
        cfg = tomllib.loads(raw)
    except tomllib.TOMLDecodeError as e:
        print(f"FAIL: rendered config.toml is not valid TOML: {e}")
        return 1

    # ---- top level ----
    check("concurrent" in cfg, "top-level `concurrent` missing")
    check(isinstance(cfg.get("concurrent"), int), "`concurrent` must be an integer")
    check("listen_address" in cfg, "`listen_address` missing (no metrics endpoint)")

    runners = cfg.get("runners")
    check(isinstance(runners, list) and len(runners) == 1,
          "expected exactly one [[runners]] block")
    if not runners:
        print("FAIL: no [[runners]] block; cannot continue")
        return 1
    r = runners[0]

    check(r.get("executor") == "docker-autoscaler",
          f"executor must be docker-autoscaler, got {r.get('executor')!r}")
    check(r.get("token") == "RUNNER_TOKEN_PLACEHOLDER",
          "token placeholder missing - the bootstrap substitution would not fire")
    check("glrt-" not in raw, "a real runner token leaked into the rendered config")

    # ---- docker executor ----
    docker = r.get("docker", {})
    check("image" in docker, "[runners.docker].image missing")
    check(isinstance(docker.get("privileged"), bool),
          "[runners.docker].privileged must be a bool")

    # ---- autoscaler: the table-scoping trap ----
    auto = r.get("autoscaler")
    check(isinstance(auto, dict), "[runners.autoscaler] missing")
    if not isinstance(auto, dict):
        print("FAIL: no [runners.autoscaler]; cannot continue")
        return 1

    for key in ("plugin", "capacity_per_instance", "max_use_count", "max_instances"):
        check(key in auto, f"[runners.autoscaler].{key} missing")

    # THE regression check. Must be on the autoscaler table itself, and must NOT
    # have leaked into plugin_config / connector_config / scale_throttle.
    check("instance_ready_command" in auto,
          "instance_ready_command is NOT on [runners.autoscaler] - the readiness "
          "gate will never run (it was probably emitted after a sub-table was opened)")
    for sub in ("plugin_config", "connector_config", "scale_throttle"):
        check("instance_ready_command" not in auto.get(sub, {}),
              f"instance_ready_command leaked into [runners.autoscaler.{sub}]")

    pc = auto.get("plugin_config", {})
    check("name" in pc, "[runners.autoscaler.plugin_config].name (the ASG) missing")
    check(set(pc.keys()) <= {"name", "profile", "config_file", "credentials_file",
                             "scale_in_termination"},
          f"unexpected keys in plugin_config: {sorted(set(pc.keys()) - {'name'})}")

    cc = auto.get("connector_config", {})
    check("username" in cc, "connector_config.username missing")
    check(cc.get("use_external_addr") is False,
          "connector_config.use_external_addr must be false (workers stay private)")

    policies = auto.get("policy")
    check(isinstance(policies, list) and len(policies) >= 1,
          "expected at least one [[runners.autoscaler.policy]]")
    if isinstance(policies, list):
        for i, p in enumerate(policies):
            check("idle_count" in p, f"policy[{i}] missing idle_count")
            check(isinstance(p.get("periods"), list), f"policy[{i}].periods must be a list")

    # concurrent should equal the fleet's real job slots, or capacity is stranded
    expected = auto.get("max_instances", 0) * auto.get("capacity_per_instance", 0)
    check(cfg.get("concurrent") == expected,
          f"concurrent ({cfg.get('concurrent')}) != max_instances x "
          f"capacity_per_instance ({expected}); capacity would go unused")

    # extra_runner_config_toml is appended at the end with a REQUIRED table header,
    # so it must attach where the header says and must not have leaked into the
    # last autoscaling policy.
    if "[runners.cache]" in raw:
        for pol in auto.get("policy", []) if isinstance(auto, dict) else []:
            check("Type" not in pol and "Path" not in pol,
                  "extra_runner_config_toml leaked into a [[runners.autoscaler.policy]] "
                  "block - the table header did not take effect")
        cache = r.get("cache")
        check(isinstance(cache, dict), "[runners.cache] did not attach to the runner")
        if isinstance(cache, dict):
            check(isinstance(cache.get("Type"), str), "[runners.cache].Type missing")
            # Path must be a sibling of Type, NOT nested under [runners.cache.s3];
            # without it every key is prefixed "project/..." and a prefix-scoped
            # IAM grant denies every save and restore.
            if "Path" in raw:
                check("Path" in cache,
                      "[runners.cache].Path is not on the cache table - a prefix-scoped "
                      "IAM policy would deny every cache operation")

    # ---- P0-2 regression: policy ORDER, not just policy presence ----
    # Substring assertions structurally cannot express ordering, and this defect is
    # invisible to inspection: the shadowed policy renders correctly and is simply
    # never selected.
    check_policy_order(raw)

    # ---- bootstrap script, if supplied ----
    if len(sys.argv) > 2:
        ud = pathlib.Path(sys.argv[2]).read_text()

        # ---- P0-1 regression: the AWS region must reach gitlab-runner.service ----
        # The single most consequential defect this module had: the fleet launched
        # zero workers while all seven alarms reported healthy.
        check_region_dropin(ud)
        check("trap on_exit EXIT" in ud,
              "bootstrap has no EXIT trap - explicit `exit 1` paths would report nothing")
        check("glrt-" not in ud, "a real runner token leaked into the bootstrap script")
        check("RUNNER_TOKEN_PLACEHOLDER" in ud,
              "bootstrap does not carry the token placeholder")
        check("--allowerasing" in ud,
              "package install lacks --allowerasing; curl-minimal conflicts on AL2023")
        # log shipping must be configured before anything that can fail
        if "amazon-cloudwatch-agent" in ud:
            check(ud.index("amazon-cloudwatch-agent") < ud.index("gitlab-runner fleeting install"),
                  "CloudWatch agent is installed after steps that can fail - a failed "
                  "bootstrap would never ship its log")
            check("journald" in ud, "the gitlab-runner journal is not shipped")
        check("python3 -c" in ud and 'python3 - "$TOKEN"' not in ud,
              "token must reach python via stdin, never argv")

        # --- CloudWatch agent config: extract and schema-check it ---
        # An invalid agent config used to sit at the very front of the bootstrap,
        # so it could abort every boot. Nothing was checking the artifact.
        import json as _json
        import re as _re
        m = _re.search(r"<<'CWEOF'\n(.*?)\nCWEOF", ud, _re.S)
        if "amazon-cloudwatch-agent" in ud:
            check(m is not None, "CloudWatch agent config block not found")
            if m:
                try:
                    agent = _json.loads(m.group(1))
                except _json.JSONDecodeError as e:
                    failures.append(f"CloudWatch agent config is not valid JSON: {e}")
                    agent = None
                if agent:
                    collected = agent.get("logs", {}).get("logs_collected", {})
                    # `files` is the documented shape; `journald` is NOT a member
                    # of logs_collected and would be rejected by the agent.
                    check("files" in collected,
                          "agent config must collect via logs_collected.files")
                    check("journald" not in collected,
                          "logs_collected.journald is not in the CloudWatch agent "
                          "schema - stream the unit's journal to a file and tail it")
                    paths = [c.get("file_path") for c in
                             collected.get("files", {}).get("collect_list", [])]
                    check("/var/log/runner-bootstrap.log" in paths,
                          "the bootstrap log is not shipped")
                    check("/var/log/gitlab-runner.log" in paths,
                          "the gitlab-runner log is not shipped")
                    for c in collected.get("files", {}).get("collect_list", []):
                        check(c.get("log_group_name"), "a collect_list entry has no log_group_name")
                        check(c.get("log_stream_name"), "a collect_list entry has no log_stream_name")
            # observability failing must not break the fleet
            check("|| echo \"WARN: log shipping" in ud,
                  "log-shipping setup must be non-fatal - it runs before everything "
                  "else, so a hard failure there aborts every boot")

        # --- liveness heartbeat: the primary health signal ---
        check("runner-heartbeat.timer" in ud and "runner-heartbeat.service" in ud,
              "heartbeat units missing - RunnerHealthy would never be published and "
              "the liveness alarm would sit in permanent ALARM")
        check("enable --now runner-heartbeat.timer" in ud,
              "heartbeat timer is never enabled")
        # the script runs under `set -u`, so a missing Environment= is a hard fail
        for env in ("AWS_DEFAULT_REGION", "NAMESPACE", "FLEET"):
            check(f"Environment={env}=" in ud,
                  f"heartbeat service has no {env} - the script runs under set -u "
                  f"and would exit non-zero")
        # installed before the slow steps, or the alarm has no datapoints during boot
        if "runner-heartbeat.timer" in ud and "gitlab-runner fleeting install" in ud:
            check(ud.index("runner-heartbeat.timer") < ud.index("gitlab-runner fleeting install"),
                  "heartbeat is installed after the slow steps - the liveness alarm "
                  "would rely on missing-data guessing during every boot")
        # the AWS CLI must exist before the trap that uses it is armed
        if "trap on_exit EXIT" in ud:
            check(ud.index("command -v aws") < ud.index("trap on_exit EXIT"),
                  "the EXIT trap publishes a metric with a CLI that isn't installed "
                  "yet - early failures would be silent")
        # a find under `set -euo pipefail` must not kill the script before its own
        # diagnostic runs
        if "find /etc/gitlab-runner" in ud:
            find_line = [l for l in ud.splitlines() if "find /etc/gitlab-runner" in l][0]
            check("|| true" in find_line,
                  "the plugin `find` fallback lacks `|| true`: pipefail makes a "
                  "missing search root kill the script before the FATAL message")

    if failures:
        print(f"FAIL: {len(failures)} problem(s) in the rendered config:")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("OK: rendered config.toml and bootstrap script pass all structural checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
