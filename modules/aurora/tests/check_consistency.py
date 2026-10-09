#!/usr/bin/env python3
"""Keeps the aurora module's code, docs, examples and tests in step.

Every rule here is something that drifted at least once by hand:

  checks        check names in checks.tf == the acknowledged_checks allow-list
                == the README "Advisory checks" table == every test file's
                every_check list
  counts        the numbers README and CHANGELOG quote (preconditions,
                validations, checks, moved blocks) == the code
  variables     every var.X used is declared; every declared variable is used
  locals        every local.X used is defined; every local defined is used
  examples      every argument an example passes to the module is a variable;
                every module output it reads exists
  reference     the README's Inputs and Outputs sections list every variable
                and output, and nothing that does not exist
  placeholders  no ALL-CAPS placeholder (TESTCOUNT, TODO, TBD, FIXME) left in
                the docs

Usage:
  check_consistency.py [module-dir]      default: the directory above tests/

Exit 0 = consistent, 1 = a finding, 2 = tool/usage error.
"""

from __future__ import annotations

import pathlib
import re
import sys

findings: list[str] = []


def finding(rule: str, message: str) -> None:
    findings.append(f"{rule:<13} {message}")


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def strip_comments(hcl: str) -> str:
    """Drop # and // line comments outside strings, so a name in a comment
    neither counts as a use nor as a definition."""
    out = []
    for line in hcl.splitlines():
        in_str = False
        cut = len(line)
        i = 0
        while i < len(line):
            c = line[i]
            if c == "\\" and in_str:
                i += 2
                continue
            if c == '"':
                in_str = not in_str
            elif not in_str and (c == "#" or line.startswith("//", i)):
                cut = i
                break
            i += 1
        out.append(line[:cut])
    return "\n".join(out)


def block_body(text: str, start: int) -> str:
    """The text between the brace at or after start and its match."""
    open_at = text.index("{", start)
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[open_at + 1 : i]
    raise ValueError("unbalanced braces")


WORDS = {
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
    "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
    "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
    "eighty": 80, "ninety": 90,
}


def to_number(token: str) -> int | None:
    """"43", "Forty-three", "ten" -> int; anything else -> None."""
    if token.isdigit():
        return int(token)
    total = 0
    for part in token.lower().split("-"):
        if part not in WORDS:
            return None
        total += WORDS[part]
    return total


# ---------------------------------------------------------------------------


def check_names(mod: pathlib.Path) -> None:
    code = set(re.findall(r'^check "([a-z_]+)"', read(mod / "checks.tf"), re.M))
    if not code:
        finding("checks", "no check blocks found in checks.tf")
        return

    variables = read(mod / "variables.tf")
    allow: set[str] = set()
    m = re.search(r'variable "acknowledged_checks"', variables)
    if m:
        # The validation's literals only - the description quotes a name too.
        body = block_body(variables, m.start())
        v = re.search(r"\bvalidation\s*\{", body)
        if v:
            allow = set(re.findall(r'"([a-z_]+)"', block_body(body, v.start())))

    readme = read(mod / "README.md")
    section = readme.split("### Advisory checks", 1)[-1].split("\n## ", 1)[0]
    documented = set(re.findall(r"^\| `([a-z_]+)` \|", section, re.M))

    sources = {"acknowledged_checks validation": allow, 'README "Advisory checks"': documented}
    for test in sorted((mod / "tests").glob("*.tftest.hcl")):
        t = read(test)
        m = re.search(r"every_check\s*=\s*\[", t)
        if m:
            body = t[m.end() : t.index("]", m.end())]
            sources[f"{test.name} every_check"] = set(re.findall(r'"([a-z_]+)"', body))

    for where, names in sources.items():
        for name in sorted(code - names):
            finding("checks", f"{where} is missing {name}")
        for name in sorted(names - code):
            finding("checks", f"{where} names {name}, which is not a check in checks.tf")


def check_counts(mod: pathlib.Path) -> None:
    tf = {p.name: strip_comments(read(p)) for p in mod.glob("*.tf")}
    real = {
        "preconditions": sum(len(re.findall(r"\bprecondition\s*\{", t)) for t in tf.values()),
        "validations": len(re.findall(r"\bvalidation\s*\{", tf.get("variables.tf", ""))),
        "checks": len(re.findall(r'^check "', tf.get("checks.tf", ""), re.M)),
        "moved blocks": len(re.findall(r"^moved\s*\{", tf.get("moved.tf", ""), re.M)),
    }

    claims = [
        ("README.md", r"([\w-]+) preconditions and ([\w-]+) validations", ("preconditions", "validations")),
        ("README.md", r"([\w-]+) `check` blocks", ("checks",)),
        ("CHANGELOG.md", r"([\w-]+) advisory checks", ("checks",)),
        ("CHANGELOG.md", r"([\w-]+) `moved`\s+blocks", ("moved blocks",)),
    ]
    for doc, pattern, kinds in claims:
        path = mod / doc
        if not path.exists():
            continue
        for m in re.finditer(pattern, read(path), re.I):
            for token, kind in zip(m.groups(), kinds):
                said = to_number(token)
                if said is not None and said != real[kind]:
                    line = read(path)[: m.start()].count("\n") + 1
                    finding("counts", f"{doc}:{line} says {token} {kind}; the code has {real[kind]}")


def check_variables_and_locals(mod: pathlib.Path) -> None:
    tf = {p.name: strip_comments(read(p)) for p in mod.glob("*.tf")}
    everything = "\n".join(tf.values())

    declared = set(re.findall(r'^variable "([a-z0-9_]+)"', tf.get("variables.tf", ""), re.M))
    used = set(re.findall(r"\bvar\.([a-z0-9_]+)", everything))
    for name in sorted(used - declared):
        finding("variables", f"var.{name} is used but not declared")
    for name in sorted(declared - used):
        finding("variables", f"variable {name} is declared but never used")

    defined: set[str] = set()
    for text in tf.values():
        for m in re.finditer(r"^locals\s*\{", text, re.M):
            defined |= set(re.findall(r"^  ([a-z0-9_]+)\s*=", block_body(text, m.start()), re.M))
    used_locals = set(re.findall(r"\blocal\.([a-z0-9_]+)", everything))
    for name in sorted(used_locals - defined):
        finding("locals", f"local.{name} is used but not defined")
    for name in sorted(defined - used_locals):
        finding("locals", f"local {name} is defined but never used")


def check_examples(mod: pathlib.Path) -> None:
    declared = set(re.findall(r'^variable "([a-z0-9_]+)"', read(mod / "variables.tf"), re.M))
    outputs = set(re.findall(r'^output "([a-z0-9_]+)"', read(mod / "outputs.tf"), re.M))
    meta = {"source", "version", "providers", "depends_on", "count", "for_each"}

    files = sorted((mod / "examples").glob("*/*.tf"))
    repo_example = mod.parent.parent / "examples" / "aurora"
    if repo_example.is_dir():
        files += sorted(repo_example.glob("*.tf"))

    for path in files:
        text = strip_comments(read(path))
        callers = []
        for m in re.finditer(r'^module "([a-z0-9_]+)"\s*\{', text, re.M):
            body = block_body(text, m.start())
            if not re.search(r'source\s*=\s*"[^"]*(\.\./\.\./|modules/aurora|/aurora/aws)"', body):
                continue
            callers.append(m.group(1))
            # Collapse nested maps and objects, innermost first, so only the
            # module's own arguments are left at the top level.
            depth_zero = body
            while re.search(r"\{[^{}]*\}", depth_zero):
                depth_zero = re.sub(r"\{[^{}]*\}", "@", depth_zero)
            for arg in re.findall(r"^\s*([a-z0-9_]+)\s*=", depth_zero, re.M):
                if arg not in meta and arg not in declared:
                    finding("examples", f"{path.relative_to(mod.parent.parent)} passes {arg}, which is not a module variable")
        for name in callers:
            for out in re.findall(rf"\bmodule\.{name}\.([a-z0-9_]+)", text):
                if out not in outputs:
                    finding("examples", f"{path.relative_to(mod.parent.parent)} reads module.{name}.{out}, which is not an output")


def section(text: str, heading: str) -> str:
    """The body of a "## heading" section, up to the next "## " heading."""
    m = re.search(rf"^## {re.escape(heading)}\s*$", text, re.M)
    if not m:
        return ""
    rest = text[m.end():]
    end = re.search(r"^## ", rest, re.M)
    return rest[: end.start()] if end else rest


def check_reference(mod: pathlib.Path) -> None:
    """When the README carries an Inputs or Outputs reference, it names every
    variable and output, and nothing else in its first column."""
    readme = read(mod / "README.md")
    pairs = [
        ("Inputs", set(re.findall(r'^variable "([a-z0-9_]+)"', read(mod / "variables.tf"), re.M)), "variable"),
        ("Outputs", set(re.findall(r'^output "([a-z0-9_]+)"', read(mod / "outputs.tf"), re.M)), "output"),
    ]
    for heading, names, kind in pairs:
        body = section(readme, heading)
        if not body:
            continue
        # First table column, which may list several names, plus HCL schema
        # blocks that open with "<name> = object(" or "<name> = map(".
        listed = set()
        for row in re.findall(r"^\| ([^|]+) \|", body, re.M):
            listed |= set(re.findall(r"`([a-z0-9_]+)`", row))
        listed |= set(re.findall(r"^([a-z0-9_]+) = (?:object|map)\(", body, re.M))
        for name in sorted(names - listed):
            finding("reference", f'README "{heading}" does not list the {kind} {name}')
        for name in sorted(listed - names):
            finding("reference", f'README "{heading}" lists {name}, which is not {"an" if kind[0] in "aeiou" else "a"} {kind}')


def check_placeholders(mod: pathlib.Path) -> None:
    docs = [mod / "README.md", mod / "CHANGELOG.md", mod / "COSTS.md"]
    docs += sorted((mod / "docs").glob("*.md")) + sorted((mod / "examples").glob("*/README.md"))
    pattern = re.compile(r"\b(TESTCOUNT|TODO|TBD|FIXME|XXX)\b")
    for path in docs:
        if not path.exists():
            continue
        for n, line in enumerate(read(path).splitlines(), 1):
            for m in pattern.finditer(line):
                finding("placeholders", f"{path.relative_to(mod)}:{n} still has {m.group(1)}")


def main(argv: list[str]) -> int:
    if len(argv) > 2:
        print(__doc__, file=sys.stderr)
        return 2
    mod = pathlib.Path(argv[1]) if len(argv) == 2 else pathlib.Path(__file__).resolve().parent.parent
    if not (mod / "checks.tf").exists() or not (mod / "variables.tf").exists():
        print(f"{mod} does not look like the aurora module", file=sys.stderr)
        return 2

    for rule in (check_names, check_counts, check_variables_and_locals, check_examples, check_reference, check_placeholders):
        rule(mod)

    if findings:
        print(f"FAIL: {len(findings)} finding(s)")
        for f in findings:
            print(f"  {f}")
        return 1
    print("OK: checks, counts, variables, locals, examples and docs are consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
