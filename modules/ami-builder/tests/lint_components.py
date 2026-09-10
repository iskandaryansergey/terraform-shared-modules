#!/usr/bin/env python3
"""Structural checks on the bundled AWSTOE component documents.

These exist because the interesting properties are structural and a substring
assertion cannot express them:

  - A step referencing an undeclared parameter fails the BUILD, twenty minutes
    in, not the plan. Same for a Terraform config passing a parameter the
    component does not declare. Both are cross-file properties.

  - "the file mentions sha256sum" is true whether the digest is actually checked
    or merely mentioned in a comment next to an unverified curl.

  - AWSTOE runs every command as root. A component that pipes a download into a
    shell is the supply-chain hole this whole module exists to close, so it gets
    caught here rather than in review.

  - Every step is its own shell. A variable set in one step and used in the next
    is an unbound-variable error under `set -u`, which stops the build at that
    step - and no amount of reading one step at a time makes it obvious.

Usage:
  lint_components.py <components-dir> [--tf-dir <dir-with-tf-passing-parameters>]
  lint_components.py --self-test

Exit 0 = clean, 1 = a check failed, 2 = tool/usage error.
"""

from __future__ import annotations

import pathlib
import re
import sys

try:
    import yaml
except ImportError:
    print("FATAL: pyyaml is required (pip install pyyaml)", file=sys.stderr)
    raise SystemExit(2)

failures: list[str] = []

VALID_PHASES = {"build", "validate", "test"}

# Downloads piped straight into an interpreter, running as root.
PIPE_TO_SHELL = re.compile(
    r"(curl|wget)\b[^|\n]*\|\s*(sudo\s+)?(ba|z|k)?sh\b", re.IGNORECASE
)

# TLS verification turned off on a fetch.
TLS_OFF = re.compile(
    r"(curl\b[^\n]*(\s-k\b|\s--insecure\b)|wget\b[^\n]*--no-check-certificate)",
    re.IGNORECASE,
)

SECRET_PATTERNS = [
    (re.compile(r"\b(AKIA|ASIA)[0-9A-Z]{16}\b"), "an AWS access key id"),
    (re.compile(r"\bglrt-[A-Za-z0-9_-]{10,}"), "a GitLab runner token"),
    (re.compile(r"-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----"), "a private key"),
    (re.compile(r"\b(password|passwd|secret|token)\s*=\s*[\"'][^\"'{$][^\"']{6,}"), "a literal credential"),
]

WORLD_WRITABLE = re.compile(r"chmod\s+(-[A-Za-z]+\s+)*777\b")

# {{ ParamName }} — AWSTOE's parameter substitution.
PARAM_REF = re.compile(r"\{\{\s*([A-Za-z][A-Za-z0-9_]*)\s*\}\}")

# Shell variables, for the one-step-one-shell check below. Assignments cover the
# forms that actually appear: NAME=, export NAME=, a for-loop variable, read.
SHELL_ASSIGN = re.compile(
    r"^\s*(?:export\s+|readonly\s+|declare\s+(?:-[A-Za-z]+\s+)?|local\s+)?"
    r"([A-Za-z_][A-Za-z0-9_]*)=",
    re.M,
)
SHELL_FOR = re.compile(r"\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b")
SHELL_READ = re.compile(r"\bread\s+(?:-[A-Za-z]+\s+)*([A-Za-z_][A-Za-z0-9_]*)")
# $NAME and ${NAME}. Positional and special parameters ($1, $?, $@) start with a
# digit or punctuation, so they never match - which also keeps awk programs like
# '{print $2}' out of the results.
SHELL_REF = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?")

# Set by the environment rather than by the script.
SHELL_ENV = {
    "PATH", "HOME", "PWD", "OLDPWD", "SHELL", "USER", "LOGNAME", "HOSTNAME",
    "TERM", "LANG", "IFS", "TMPDIR", "RANDOM", "UID", "EUID", "PS1", "PS4",
    "BASH", "BASH_SOURCE", "BASH_VERSION", "FUNCNAME", "LINENO", "SECONDS",
    "AWS_REGION", "AWS_DEFAULT_REGION", "AWS_EXECUTION_ENV",
}

# AWSTOE's own build-time substitutions - {{ imagebuilder:buildDate }} and
# friends. PARAM_REF cannot match these anyway because of the colon, so this set
# is documentation rather than a filter. Kept because a future PARAM_REF that
# allows colons would need it immediately.
BUILTIN_REFS = {"imagebuilder"}


def check(ok: bool, msg: str) -> None:
    if not ok:
        failures.append(msg)


def collect_text(node) -> str:
    """Every string anywhere in the document, so a check cannot be dodged by
    nesting the offending command one level deeper than the linter looks."""
    out: list[str] = []
    if isinstance(node, str):
        out.append(node)
    elif isinstance(node, dict):
        for k, v in node.items():
            out.append(str(k))
            out.append(collect_text(v))
    elif isinstance(node, list):
        for v in node:
            out.append(collect_text(v))
    return "\n".join(out)


def declared_parameters(doc: dict) -> set[str]:
    """AWSTOE declares parameters as a list of single-key maps."""
    names: set[str] = set()
    for entry in doc.get("parameters") or []:
        if isinstance(entry, dict):
            names.update(entry.keys())
    return names


def lint_component(path: pathlib.Path) -> set[str]:
    name = path.name
    try:
        doc = yaml.safe_load(path.read_text())
    except yaml.YAMLError as exc:
        check(False, f"{name}: not valid YAML: {exc}")
        return set()

    if not isinstance(doc, dict):
        check(False, f"{name}: document must be a mapping at the top level.")
        return set()

    # ---- AWSTOE schema -------------------------------------------------
    for key in ("name", "schemaVersion", "phases"):
        check(key in doc, f"{name}: missing required top-level key {key!r}.")

    phases = doc.get("phases")
    if not isinstance(phases, list):
        check(False, f"{name}: phases must be a list.")
        return declared_parameters(doc)

    seen_phases: set[str] = set()
    for phase in phases:
        if not isinstance(phase, dict):
            check(False, f"{name}: each phase must be a mapping.")
            continue
        pname = phase.get("name")
        check(
            pname in VALID_PHASES,
            f"{name}: phase {pname!r} is not one of {sorted(VALID_PHASES)}; "
            f"AWSTOE ignores unknown phases silently, so the steps would never run.",
        )
        check(pname not in seen_phases, f"{name}: phase {pname!r} appears more than once.")
        if pname:
            seen_phases.add(pname)

        steps = phase.get("steps")
        check(isinstance(steps, list), f"{name}: phase {pname!r} has no steps list.")
        if not isinstance(steps, list):
            continue

        step_names: set[str] = set()
        for step in steps:
            if not isinstance(step, dict):
                check(False, f"{name}: a step in phase {pname!r} is not a mapping.")
                continue
            sname = step.get("name")
            check(sname is not None, f"{name}: a step in phase {pname!r} has no name.")
            check(
                sname not in step_names,
                f"{name}: step name {sname!r} is reused inside phase {pname!r}; "
                f"AWSTOE keys its outputs by step name.",
            )
            if sname:
                step_names.add(sname)
            check("action" in step, f"{name}: step {sname!r} has no action.")
            check("inputs" in step, f"{name}: step {sname!r} has no inputs.")

    # ---- shell hygiene -------------------------------------------------
    body = collect_text(doc)

    check(
        not PIPE_TO_SHELL.search(body),
        f"{name}: a download is piped into a shell and AWSTOE runs it as root. "
        f"Fetch to a file, verify a digest, then execute.",
    )
    check(
        not TLS_OFF.search(body),
        f"{name}: a fetch disables TLS verification.",
    )
    check(
        not WORLD_WRITABLE.search(body),
        f"{name}: chmod 777 appears; a world-writable path baked into an AMI is "
        f"writable by every process on every instance launched from it.",
    )
    for pattern, what in SECRET_PATTERNS:
        check(
            not pattern.search(body),
            f"{name}: what looks like {what} is embedded in the document. "
            f"Anything baked into an AMI is distributed to everyone who can launch it.",
        )

    # Every ExecuteBash body should fail fast. Without `set -e` a failing
    # command inside a multi-line block is ignored and the step reports success.
    for phase in phases:
        if not isinstance(phase, dict):
            continue
        for step in phase.get("steps") or []:
            if not isinstance(step, dict) or step.get("action") != "ExecuteBash":
                continue
            cmds = (step.get("inputs") or {}).get("commands") or []
            joined = "\n".join(c for c in cmds if isinstance(c, str))
            # Single-line commands are their own exit status; only multi-line
            # blocks can silently swallow a failure.
            if joined.count("\n") >= 2:
                check(
                    re.search(r"set\s+-[a-z]*e", joined) is not None,
                    f"{name}: ExecuteBash step {step.get('name')!r} is a multi-line "
                    f"block with no `set -e`; a failing line would be ignored and the "
                    f"step would report success.",
                )

    # ---- one step, one shell -------------------------------------------
    # Each ExecuteBash step runs as its own script, so a variable has to be
    # assigned in the step that uses it. Pass anything else through a file.
    for phase in phases:
        if not isinstance(phase, dict):
            continue
        for step in phase.get("steps") or []:
            if not isinstance(step, dict) or step.get("action") != "ExecuteBash":
                continue
            cmds = (step.get("inputs") or {}).get("commands") or []
            block = "\n".join(c for c in cmds if isinstance(c, str))
            assigned = (
                set(SHELL_ASSIGN.findall(block))
                | set(SHELL_FOR.findall(block))
                | set(SHELL_READ.findall(block))
            )
            for ref in sorted(set(SHELL_REF.findall(block))):
                if ref in assigned or ref in SHELL_ENV:
                    continue
                check(
                    False,
                    f"{name}: step {step.get('name')!r} uses ${ref} but never sets it. "
                    f"AWSTOE runs every step in a separate shell, so a variable from an "
                    f"earlier step is unset here - and under `set -u` that fails the "
                    f"build at this step. Write the value to a file and read it back.",
                )

    # ---- parameters ----------------------------------------------------
    declared = declared_parameters(doc)
    referenced = {m for m in PARAM_REF.findall(body) if m not in BUILTIN_REFS}

    # A reference AWSTOE cannot resolve fails the build.
    for ref in sorted(referenced - declared):
        check(
            False,
            f"{name}: {{{{ {ref} }}}} is referenced but not declared in parameters; "
            f"AWSTOE fails the build on an unresolvable reference.",
        )

    # Not an error, but a declared-and-unused parameter is usually a rename that
    # only got done in one place.
    for unused in sorted(declared - referenced):
        check(
            False,
            f"{name}: parameter {unused!r} is declared but never referenced. "
            f"Either use it or drop it - a caller setting it would have no effect.",
        )

    return declared


def lint_tf_parameter_names(tf_dir: pathlib.Path, declared: dict[str, set[str]]) -> None:
    """Cross-check parameters passed from Terraform against what the bundled
    components declare. Passing an undeclared parameter fails the build, not the
    plan, so nothing in Terraform catches it."""
    for tf in sorted(tf_dir.rglob("*.tf")):
        text = tf.read_text()
        # Match a components entry naming a bundled component and a parameters
        # map, in either attribute order.
        for block in re.findall(r"\{[^{}]*bundled\s*=\s*\"[^\"]+\"[^{}]*(?:\{[^{}]*\}[^{}]*)*\}", text):
            m = re.search(r"bundled\s*=\s*\"([^\"]+)\"", block)
            if not m:
                continue
            comp = m.group(1)
            if comp not in declared:
                continue
            pm = re.search(r"parameters\s*=\s*\{([^{}]*)\}", block)
            if not pm:
                continue
            for key in re.findall(r"^\s*([A-Za-z][A-Za-z0-9_]*)\s*=", pm.group(1), re.M):
                check(
                    key in declared[comp],
                    f"{tf.name}: passes parameter {key!r} to bundled component "
                    f"{comp!r}, which does not declare it. AWSTOE fails the build, "
                    f"not the plan. Declared: {sorted(declared[comp])}.",
                )


SELF_TEST_CASES = [
    (
        "pipe to shell",
        """
name: bad
schemaVersion: 1.0
phases:
  - name: build
    steps:
      - name: Install
        action: ExecuteBash
        inputs:
          commands:
            - curl -fsSL https://example.com/install.sh | bash
""",
    ),
    (
        "undeclared parameter",
        """
name: bad
schemaVersion: 1.0
phases:
  - name: build
    steps:
      - name: Install
        action: ExecuteBash
        inputs:
          commands:
            - echo "{{ NotDeclared }}"
""",
    ),
    (
        "unknown phase name",
        """
name: bad
schemaVersion: 1.0
phases:
  - name: buidl
    steps:
      - name: Install
        action: ExecuteBash
        inputs:
          commands:
            - echo hi
""",
    ),
    (
        "baked credential",
        """
name: bad
schemaVersion: 1.0
phases:
  - name: build
    steps:
      - name: Configure
        action: ExecuteBash
        inputs:
          commands:
            - echo AKIAIOSFODNN7EXAMPLE > /root/key
""",
    ),
    (
        "multi-line block without set -e",
        """
name: bad
schemaVersion: 1.0
phases:
  - name: build
    steps:
      - name: Install
        action: ExecuteBash
        inputs:
          commands:
            - |
              dnf install -y something
              echo done
              true
""",
    ),
    (
        "a variable carried over from an earlier step",
        """
name: bad
schemaVersion: 1.0
phases:
  - name: build
    steps:
      - name: Fetch
        action: ExecuteBash
        inputs:
          commands:
            - |
              set -euo pipefail
              TARGET="$(mktemp)"
              curl -fsSL --max-time 30 https://example.com/x -o "$TARGET"
              test -s "$TARGET"
      - name: Verify
        action: ExecuteBash
        inputs:
          commands:
            - |
              set -euo pipefail
              EXPECTED=deadbeef
              echo "$EXPECTED  $TARGET" | sha256sum -c -
""",
    ),
    (
        "tls verification disabled",
        """
name: bad
schemaVersion: 1.0
phases:
  - name: build
    steps:
      - name: Fetch
        action: ExecuteBash
        inputs:
          commands:
            - curl -k https://example.com/x -o /tmp/x
""",
    ),
    (
        "world-writable path",
        """
name: bad
schemaVersion: 1.0
phases:
  - name: build
    steps:
      - name: Break
        action: ExecuteBash
        inputs:
          commands:
            - chmod 777 /opt/app
""",
    ),
]


def self_test() -> int:
    """A guard nobody proved is a guard nobody should trust. Reintroduce each
    defect and confirm the linter catches it."""
    import tempfile

    bad = 0
    for label, doc in SELF_TEST_CASES:
        global failures
        failures = []
        with tempfile.TemporaryDirectory() as td:
            p = pathlib.Path(td) / "case.yaml"
            p.write_text(doc)
            lint_component(p)
        if failures:
            print(f"  ok    detected: {label}")
        else:
            print(f"  FAIL  NOT detected: {label}")
            bad += 1

    # And the shipped components must be clean.
    failures = []
    here = pathlib.Path(__file__).resolve().parent.parent / "components"
    for f in sorted(here.glob("*.yaml")):
        lint_component(f)
    if failures:
        print("  FAIL  the shipped components do not pass their own linter:")
        for f in failures:
            print(f"          {f}")
        bad += 1
    else:
        print("  ok    shipped components are clean")

    print()
    if bad:
        print(f"SELF-TEST FAILED: {bad} case(s)")
        return 1
    print(f"SELF-TEST OK: {len(SELF_TEST_CASES)} defects detected, shipped components clean")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[1] == "--self-test":
        return self_test()

    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2

    comp_dir = pathlib.Path(argv[1])
    if not comp_dir.is_dir():
        print(f"FATAL: {comp_dir} is not a directory", file=sys.stderr)
        return 2

    files = sorted(comp_dir.glob("*.yaml")) + sorted(comp_dir.glob("*.yml"))
    if not files:
        print(f"FATAL: no component documents in {comp_dir}", file=sys.stderr)
        return 2

    declared: dict[str, set[str]] = {}
    for f in files:
        declared[f.stem] = lint_component(f)

    if "--tf-dir" in argv:
        tf_dir = pathlib.Path(argv[argv.index("--tf-dir") + 1])
        if tf_dir.is_dir():
            lint_tf_parameter_names(tf_dir, declared)

    if failures:
        print(f"FAILED: {len(failures)} finding(s)", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1

    print(f"OK: {len(files)} component(s) pass all structural checks")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
