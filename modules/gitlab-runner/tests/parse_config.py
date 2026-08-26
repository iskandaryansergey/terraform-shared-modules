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

    # ---- bootstrap script, if supplied ----
    if len(sys.argv) > 2:
        ud = pathlib.Path(sys.argv[2]).read_text()
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
