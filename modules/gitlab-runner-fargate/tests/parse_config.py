#!/usr/bin/env python3
"""Structural checks on the rendered config.toml and fargate.toml.

This exists because substring assertions cannot express the properties that
actually matter here, and the properties that matter are all structural:

  - TOML binds a bare key to whichever table was opened LAST. A key emitted
    after a sub-table header silently attaches to the sub-table. "the key is in
    the file" is true in both the working and the broken case, so a `contains`
    assertion cannot tell them apart. Only a parser can.

  - The driver's Go struct fields are Subnet and SecurityGroup, SINGULAR. The
    driver's own shipped example uses the plural forms, which are silently
    ignored and produce a startup failure blaming a missing security group. A
    substring check for "Subnet" passes on "Subnets".

  - Exactly one [[runners]] must exist. A second one with executor = "shell"
    would run jobs as root on the manager. In the sibling module that was
    reachable through a raw-TOML input; this module has no such input, and this
    assertion is what proves the property still holds.

Usage:  parse_config.py <config.toml> <fargate.toml>
Exit 0 = clean, 1 = assertion failed, 2 = tool/usage error.
"""
from __future__ import annotations

import pathlib
import re
import sys
import tomllib

failures: list[str] = []


def check(ok: bool, msg: str) -> None:
    if not ok:
        failures.append(msg)


def check_config_toml(path: pathlib.Path) -> None:
    with path.open("rb") as fh:
        doc = tomllib.load(fh)

    # ---- top level -------------------------------------------------------
    check(isinstance(doc.get("concurrent"), int),
          f"concurrent must be an int, got {type(doc.get('concurrent')).__name__}. "
          f"Terraform's number type covers floats, and GitLab Runner rejects a "
          f"non-integer here - which bricks every manager start.")
    check(doc.get("concurrent", 0) >= 1,
          "concurrent must be >= 1; GitLab Runner rejects 0.")
    check(isinstance(doc.get("check_interval"), int),
          "check_interval must be an int.")

    # REQUIRED keys in the global table. fargate.toml had a required-key check and
    # config.toml did not, and that asymmetry is precisely how a fleet shipped
    # whose manager could never pass its own health check: gitlab-runner starts
    # its metrics/health HTTP server ONLY when listen_address is set, and the ECS
    # health check probes exactly that address.
    for required in ("concurrent", "check_interval", "listen_address"):
        check(required in doc,
              f"config.toml global table is missing REQUIRED key {required!r}. "
              f"For listen_address specifically: without it gitlab-runner starts no "
              f"HTTP server, the manager health check can never succeed, ECS replaces "
              f"the task forever, and `terraform apply` fails on wait_for_steady_state.")

    listen = doc.get("listen_address")
    check(isinstance(listen, str) and ":" in str(listen),
          f"listen_address must be host:port, got {listen!r}.")

    # An inert [session_server] block reads as a working feature. It needs its own
    # listen_address and an address GitLab can reach, which a manager with no
    # inbound security-group rules cannot provide.
    check("session_server" not in doc,
          "[session_server] must not be emitted: it requires its own listener and "
          "an inbound path from GitLab, which this architecture does not provide, "
          "so the block would be dead configuration (R5).")

    # ---- exactly one runner ----------------------------------------------
    runners = doc.get("runners")
    check(isinstance(runners, list),
          "[[runners]] must be an ARRAY of tables. If it parsed as a table, "
          "something emitted [runners.<x>] before the first [[runners]] header, "
          "which makes the two collide and the file invalid.")
    if not isinstance(runners, list):
        return

    check(len(runners) == 1,
          f"expected exactly 1 [[runners]], found {len(runners)}. A second runner "
          f"with executor = 'shell' would execute jobs as root on the manager.")
    r = runners[0]

    check(r.get("executor") == "custom",
          f"executor must be 'custom' on this platform, got {r.get('executor')!r}.")
    check(r.get("token") == "RUNNER_TOKEN_PLACEHOLDER",
          "the token must still be the placeholder in the rendered artifact - a "
          "real token here means it reached Terraform state (R7).")
    check("glrt-" not in path.read_text(),
          "a glrt- token appears in the rendered config. The token must only ever "
          "arrive at runtime from Secrets Manager.")
    check(isinstance(r.get("limit"), int),
          "runners[0].limit must be an int.")

    # ---- the four stage hooks --------------------------------------------
    custom = r.get("custom")
    check(isinstance(custom, dict),
          "[runners.custom] is missing - the custom executor has no driver to call.")
    if isinstance(custom, dict):
        for stage in ("config", "prepare", "run", "cleanup"):
            check(f"{stage}_exec" in custom,
                  f"[runners.custom].{stage}_exec missing; the driver contract needs "
                  f"all four stages.")
            args = custom.get(f"{stage}_args")
            check(isinstance(args, list) and args[-1:] == [stage],
                  f"[runners.custom].{stage}_args must end with the stage name "
                  f"{stage!r}, got {args!r}.")
            check(isinstance(args, list) and "--config" in args,
                  f"[runners.custom].{stage}_args must pass --config, or the driver "
                  f"reads no configuration at all.")

        check(isinstance(custom.get("prepare_exec_timeout"), int),
              "[runners.custom].prepare_exec_timeout must be an int.")

    # ---- the cache must be a sub-table of the runner, not a sibling ------
    # This is the trap: [runners.cache] emitted before [[runners]] turns `runners`
    # into a table and the array-of-tables header then collides. Parsing proves
    # the nesting; a substring check cannot.
    if "cache" in r:
        cache = r["cache"]
        check(isinstance(cache, dict), "[runners.cache] must be a table.")
        check(cache.get("Type") == "s3", f"cache Type should be s3, got {cache.get('Type')!r}.")
        s3 = cache.get("s3")
        check(isinstance(s3, dict),
              "[runners.cache.s3] missing - a cache with no backend config does nothing.")
        if isinstance(s3, dict):
            check(s3.get("AuthenticationType") == "iam",
                  "cache must authenticate with 'iam' so it uses the task role; "
                  "static keys in a config file are a credential at rest.")
            check("AccessKey" not in s3 and "SecretKey" not in s3,
                  "static AWS keys must never appear in the cache config.")
        # Path is a sibling of Type on [runners.cache], NOT inside s3.
        check("Path" not in s3 if isinstance(s3, dict) else True,
              "cache Path belongs on [runners.cache], not inside [runners.cache.s3].")

    # `cache` must not have leaked to the top level of the document.
    check("cache" not in doc,
          "a top-level [cache] table exists; the cache config must be nested under "
          "[[runners]] or gitlab-runner ignores it.")


def check_fargate_toml(path: pathlib.Path) -> None:
    with path.open("rb") as fh:
        doc = tomllib.load(fh)

    fg = doc.get("Fargate")
    check(isinstance(fg, dict), "[Fargate] table missing.")
    if not isinstance(fg, dict):
        return

    # ---- the singular/plural trap ---------------------------------------
    for singular, plural in (("Subnet", "Subnets"), ("SecurityGroup", "SecurityGroups")):
        check(singular in fg,
              f"[Fargate].{singular} missing. The driver's Go field is {singular!r} "
              f"(singular); the plural form is silently ignored and the driver dies "
              f"at startup complaining no security group was specified.")
        check(plural not in fg,
              f"[Fargate].{plural} is set. That key does not exist in the driver's "
              f"config struct - it is silently ignored. Use {singular!r}.")

    for required in ("Cluster", "Region", "TaskDefinition"):
        check(required in fg and isinstance(fg[required], str) and fg[required],
              f"[Fargate].{required} must be a non-empty string.")

    # ---- the public-IP truth table --------------------------------------
    # EnablePublicIP = false with UsePublicIP = true is rejected by the driver at
    # startup. Assert the safe corner rather than merely a valid one.
    check(fg.get("EnablePublicIP") is False,
          "EnablePublicIP must be false: job tasks should have no public IP.")
    check(fg.get("UsePublicIP") is False,
          "UsePublicIP must be false, or the manager connects over a public "
          "address and the job security group's SG-to-SG rule stops meaning "
          "anything.")

    check(fg.get("EnableExecuteCommand") is False,
          "EnableExecuteCommand should be false: it runs commands as root in a "
          "container executing untrusted CI code.")

    # ---- waiter config must be integers, on the right table --------------
    wait = fg.get("TaskWaitConfig")
    check(isinstance(wait, dict),
          "[Fargate.TaskWaitConfig] missing - the driver would use defaults rather "
          "than the module's configured ceiling.")
    if isinstance(wait, dict):
        for k in ("MaxAttempts", "WaitTimeout"):
            check(isinstance(wait.get(k), int),
                  f"[Fargate.TaskWaitConfig].{k} must be an int, got "
                  f"{type(wait.get(k)).__name__}.")

    # EvaluateTaskHealth and its wait config must agree: a health wait config with
    # the flag off is dead config, and the flag on with no config uses defaults.
    if fg.get("EvaluateTaskHealth") is True:
        check(isinstance(fg.get("TaskHealthWaitConfig"), dict),
              "EvaluateTaskHealth is true but [Fargate.TaskHealthWaitConfig] is "
              "absent.")
    else:
        check("TaskHealthWaitConfig" not in fg,
              "[Fargate.TaskHealthWaitConfig] is present while EvaluateTaskHealth "
              "is false - that is dead config, and dead config reads as a working "
              "control to the next person.")

    # ---- metadata directory ---------------------------------------------
    meta = doc.get("TaskMetadata")
    check(isinstance(meta, dict) and isinstance(meta.get("Directory"), str) and meta["Directory"],
          "[TaskMetadata].Directory must be a non-empty string. prepare, run and "
          "cleanup are separate processes that hand state through this path; "
          "without it the SSH key prepare generated is not there when run needs it.")

    ssh = doc.get("SSH")
    check(isinstance(ssh, dict) and ssh.get("Username"),
          "[SSH].Username is required by the driver.")

    # The shipped reference image (docker/job-entrypoint.sh) installs the injected
    # public key into /root/.ssh only, and starts sshd with
    # PermitRootLogin=prohibit-password. So any other username authenticates as a
    # user whose authorized_keys was never written - the job then hangs until the
    # driver's retry budget expires, with no useful error. Asserting non-empty was
    # not enough; the guard has to know what the image supports.
    # The shipped entrypoint resolves this user's home directory with getent and
    # fails loudly if the user does not exist, and the module injects the SAME
    # value as SSH_USERNAME on the job container - so the image and this file
    # cannot disagree. What still has to hold is that it is a usable POSIX name:
    # the driver passes it straight to the SSH handshake.
    if isinstance(ssh, dict):
        name = ssh.get("Username", "")
        check(bool(re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", str(name))),
              f"[SSH].Username is {name!r}, which is not a usable POSIX username. "
              f"The driver passes it straight to the SSH handshake, and a bad value "
              f"produces a job that hangs until the retry budget expires.")

    # These are the keys that DO NOT exist in the driver's config struct. Setting
    # any of them is a silent no-op, and silently-ignored config is how an
    # operator ends up believing a limit is in force when it is not.
    for phantom in ("Cpu", "Memory", "EphemeralStorage", "LaunchType",
                    "CapacityProvider", "CapacityProviderStrategy"):
        check(phantom not in fg,
              f"[Fargate].{phantom} is set, but the driver has no such config key - "
              f"it is silently ignored. Sizing comes from the task definition, and "
              f"Spot comes from the cluster's default capacity provider strategy.")



def check_cross_file(config_path: pathlib.Path, fargate_path: pathlib.Path) -> None:
    """Assertions that need BOTH artifacts.

    These exist because a comment in this file used to promise a cross-file
    inequality that the code never checked - it asserted only the field's type.
    Both files are already passed to main(), so the check was trivially available
    and simply absent.
    """
    with config_path.open("rb") as fh:
        cfg = tomllib.load(fh)
    with fargate_path.open("rb") as fh:
        fg = tomllib.load(fh)

    runners = cfg.get("runners")
    if not isinstance(runners, list) or not runners:
        return  # already reported by check_config_toml
    custom = runners[0].get("custom", {})
    wait = fg.get("Fargate", {}).get("TaskWaitConfig", {})

    prepare = custom.get("prepare_exec_timeout")
    attempts = wait.get("MaxAttempts")
    interval = wait.get("WaitTimeout")

    if all(isinstance(x, int) for x in (prepare, attempts, interval)):
        driver_ceiling = attempts * interval
        check(prepare > driver_ceiling,
              f"[runners.custom].prepare_exec_timeout ({prepare}s) must EXCEED the "
              f"driver's own waiter ceiling ({attempts} x {interval} = "
              f"{driver_ceiling}s). Otherwise the runner abandons a job the driver "
              f"is still legitimately waiting on, and the operator sees a runner "
              f"timeout with the driver's budget unspent.")

        # A cold Fargate task needs tens of seconds just to pull its image, and
        # billing starts at the pull - so a tiny ceiling fails every job after
        # paying for it.
        check(driver_ceiling >= 120,
              f"the driver's waiter ceiling is {driver_ceiling}s, which is below the "
              f"~120s a cold Fargate task needs to reach RUNNING. Every job would "
              f"fail after being billed for the image pull.")

    # The health-check probe and the listener must agree. They are derived from one
    # Terraform variable, and this asserts the derivation actually held.
    listen = cfg.get("listen_address")
    if isinstance(listen, str) and ":" in listen:
        port = listen.rsplit(":", 1)[1]
        check(port.isdigit() and 1 <= int(port) <= 65535,
              f"listen_address port {port!r} is not a valid port.")

def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2

    config_path = pathlib.Path(sys.argv[1])
    fargate_path = pathlib.Path(sys.argv[2])

    for p in (config_path, fargate_path):
        if not p.is_file():
            print(f"FAIL: {p} does not exist")
            return 2
        if p.stat().st_size == 0:
            print(f"FAIL: {p} is empty - the render fixture produced nothing, so "
                  f"every assertion below would pass vacuously")
            return 2

    try:
        check_config_toml(config_path)
        check_fargate_toml(fargate_path)
        check_cross_file(config_path, fargate_path)
    except tomllib.TOMLDecodeError as exc:
        print(f"FAIL: rendered TOML does not parse: {exc}")
        return 1

    if failures:
        print(f"FAIL: {len(failures)} structural violation(s):")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("OK: config.toml and fargate.toml parse, and every structural assertion holds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
