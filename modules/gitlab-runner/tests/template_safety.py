#!/usr/bin/env python3
"""Guard the CLASS of bug, not the instance.

Two root-code-execution defects in this module came from the same mistake:
a caller-supplied string reaching a shell or a heredoc without being encoded,
protected only by a character allow-list. Point fixes don't stop that recurring;
this does.

Rules enforced:

  1. config.toml.tftpl  - every interpolation of a STRING-valued variable must go
     through jsonencode(). Numeric/boolean template vars are exempt (the type
     system guarantees them), and are listed explicitly so adding a new one is a
     deliberate act.
  2. *.sh.tftpl - every interpolation must sit inside single quotes, or be one of
     an explicit allow-list of values that are structurally safe (validated to a
     strict grammar, or not in a shell-evaluated position).

Run: template_safety.py <templates-dir>
"""
import pathlib
import re
import sys

# Template variables that are numbers or booleans by type, so cannot carry a
# shell metacharacter or newline. Adding to this list must be deliberate.
NUMERIC_OR_BOOL = {
    "concurrent", "capacity_per_instance", "max_use_count", "max_instances",
    "docker_privileged", "p.idle_count", "p.scale_factor", "p.scale_factor_limit",
    "scale_throttle.burst", "scale_throttle.limit",
}

# The one value that must stay raw in the TOML template, because it IS raw TOML.
# Its safety rests on validation at the variable, recorded here so the exemption
# is a deliberate, reviewable decision rather than an oversight:
#   - must begin with a TOML table header (so a bare key can't rebind a table)
#   - must not contain a line starting with "TFCFG_" (the heredoc delimiter
#     prefix), which is what stops a breakout from the bootstrap heredoc
#   - marked sensitive, and documented as trusted caller input
TOML_ALLOWED = {
    "extra_config": "raw TOML by design; table-header + TFCFG_ delimiter validation",
}

# Values whose safety is established elsewhere, with the reason recorded.
SHELL_ALLOWED = {
    # documented as trusted input, validated to start with a TOML table header,
    # and rejected if it contains the heredoc delimiter prefix
    "extra_config": "trusted input; table-header + delimiter validation",
    # written inside a quoted heredoc, so not shell-evaluated
    "config_toml": "emitted inside a quoted heredoc",
    # validated to a strict positive grammar at the variable
    "region": "validated AWS region-shaped string",
    "fleet_name": "var.name is validated ^[a-zA-Z0-9-]{2,32}$",
    "alarm_namespace": "derived from var.name",
    "log_group": "derived from var.name",
    "token_ssm_parameter": "validated SSM parameter name",
    "runner_version": "validated package-version grammar",
    "plugin_sha256": "validated 64-char hex",
    "repo_script_sha256": "validated 64-char hex",
    "heredoc_nonce": "derived sha256 substring",
    "ssh_username": "validated POSIX username",
    "install_docker": "boolean",
    "unpinned": "boolean",
    "ship_logs": "boolean",
    "extra": "trusted worker user_data; documented and marked sensitive",
}

failures: list[str] = []
INTERP = re.compile(r"\$\{([^}]*)\}")


def check_toml_template(path: pathlib.Path) -> None:
    for lineno, line in enumerate(path.read_text().splitlines(), 1):
        stripped = line.lstrip()
        # Terraform template directives, not value interpolation
        if stripped.startswith("%{"):
            continue
        for m in INTERP.finditer(line):
            expr = m.group(1).strip()
            if (expr.startswith("jsonencode(")
                    or expr in NUMERIC_OR_BOOL
                    or expr in TOML_ALLOWED):
                continue
            failures.append(
                f"{path.name}:{lineno}: `${{{expr}}}` is a raw interpolation. "
                f"Wrap it in jsonencode() - this file is transported through a "
                f"shell heredoc, so an un-encoded newline becomes shell code. "
                f"(If it is numeric or boolean, add it to NUMERIC_OR_BOOL.)"
            )


def check_shell_template(path: pathlib.Path) -> None:
    text = path.read_text()
    for lineno, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("%{") or line.lstrip().startswith("#"):
            continue
        for m in INTERP.finditer(line):
            expr = m.group(1).strip()
            if expr in SHELL_ALLOWED:
                continue
            # single-quoted immediately around the interpolation?
            before, after = line[: m.start()], line[m.end():]
            if before.rstrip().endswith("'") and after.lstrip().startswith("'"):
                continue
            if before.count("'") % 2 == 1:  # inside an open single-quoted span
                continue
            failures.append(
                f"{path.name}:{lineno}: `${{{expr}}}` reaches a shell context "
                f"without single quotes and is not on the allow-list. Either "
                f"single-quote it, or add it to SHELL_ALLOWED with the reason its "
                f"grammar makes it safe."
            )


def main() -> int:
    tpl_dir = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "templates")
    seen = 0
    for path in sorted(tpl_dir.glob("*.tftpl")):
        seen += 1
        if path.name.endswith(".sh.tftpl"):
            check_shell_template(path)
        else:
            check_toml_template(path)

    if seen == 0:
        print(f"FAIL: no templates found in {tpl_dir}")
        return 1
    if failures:
        print(f"FAIL: {len(failures)} unsafe interpolation(s):")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"OK: {seen} template(s) - every interpolation is encoded, quoted, or "
          f"explicitly justified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
