#!/usr/bin/env python3
"""Catches validations that only work on current Terraform.

Terraform 1.9 evaluates BOTH operands of || and &&. 1.12 short-circuits. So:

    condition = var.x == "" || can(regex("^a", var.x))          # fine, can() swallows
    condition = var.x == "" || length(var.x) > 3                # fine, length can't throw
    condition = var.x == "" || regex("^a", var.x) == "a"        # CRASHES on 1.9, PASSES on 1.12

The third form is a real bug that a green test run on a current binary will not
find. It bit the sibling gitlab-runner module in its own test file, which is
what the dual-version CI gate exists to catch.

This module's declared floor is 1.9.0 and there is no 1.9.8 binary here, so the
rule is checked statically instead of discovered in CI.

The fix is always the same: a nested ternary, which IS lazy on every version.

    condition = var.x == "" ? true : regex("^a", var.x) == "a"

Usage:
  lint_validations.py <file-or-dir> [...]
  lint_validations.py --self-test

Exit 0 = clean, 1 = a finding, 2 = tool/usage error.
"""

from __future__ import annotations

import pathlib
import re
import sys

# Functions and constructs that raise rather than return false. Not exhaustive
# by design: it covers what actually appears in validation conditions.
# A reference the expression itself null-tests. If the code says it can be
# null, this tool can rely on that rather than guessing.
NULL_TESTED = re.compile(
    r"((?:var|local|data|each|count)\.[A-Za-z0-9_.]+|\b[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*)"
    r"\s*(?:==|!=)\s*null"
)

THROWING = [
    "regex(",
    "min(",
    "max(",
    "sum(",
    "one(",
    "substr(",
    "base64decode(",
    "csvdecode(",
    "zipmap(",
    "tostring(",
    "toset(",
    "flatten(",
    "regexall(",  # safe itself, but its result is usually indexed
    "yamldecode(",
    "jsondecode(",
    "parseint(",
    "element(",
    "cidrhost(",
    "cidrsubnet(",
    "cidrnetmask(",
    "index(",
    "lookup(",  # two-arg lookup throws on a missing key
    "tonumber(",
    "slice(",  # throws when the range is outside the list
    "timeadd(",
    "formatdate(",
]

# Indexing throws on a missing key or an out-of-range position.
INDEX = re.compile(r"\[\s*(?:[0-9]+|\"[^\"]*\"|[a-z_][a-z0-9_.]*)\s*\]", re.IGNORECASE)

SAFE_WRAPPERS = ("can(", "try(")

findings: list[str] = []


def mask_strings(text: str) -> str:
    """Replace the contents of every double-quoted string with underscores,
    preserving length and the quotes themselves.

    Without this, a regex literal like "^cron\\(" unbalances every paren walk
    downstream: the counter never returns to zero, the walk runs to end-of-text
    and the whole remainder of the condition is treated as protected. That was a
    silent false negative on exactly the shape this module uses.
    """
    out = list(text)
    i = 0
    n = len(text)
    while i < n:
        if out[i] == '"':
            j = i + 1
            while j < n:
                if out[j] == "\\":
                    j += 2
                    continue
                if out[j] == '"':
                    break
                out[j] = "_"
                j += 1
            i = j + 1
        else:
            i += 1
    return "".join(out)


def strip_balanced(text: str, opener: str) -> str:
    """Remove every `opener...)` span, including nested parens. What is left is
    the part of the expression that is NOT protected.

    Paren matching runs over a string-masked copy so quoted parens cannot throw
    the walk off, but the slices returned come from the ORIGINAL text.
    """
    masked = mask_strings(text)
    out = []
    i = 0
    n = len(text)
    while i < n:
        idx = masked.find(opener, i)
        if idx == -1:
            out.append(text[i:])
            break
        out.append(text[i:idx])
        depth = 0
        j = idx + len(opener) - 1  # position of the '('
        while j < n:
            if masked[j] == "(":
                depth += 1
            elif masked[j] == ")":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        else:
            # Unbalanced: refuse to guess. Keeping the remainder UNPROTECTED is
            # the fail-safe direction - a false positive is visible, a false
            # negative is not.
            out.append(text[idx:])
            break
        i = j + 1
    return "".join(out)


def extract_conditions(text: str) -> list[tuple[int, str]]:
    """Every `condition = ...` inside a validation, precondition, postcondition
    or check assert block, with its line number."""
    results: list[tuple[int, str]] = []
    for m in re.finditer(r"^([ \t]*)condition\s*=\s*", text, re.M):
        start = m.end()
        line_no = text.count("\n", 0, m.start()) + 1
        # The condition runs until a line whose indentation is <= the block's
        # and which starts a new attribute or closes the block.
        indent = len(m.group(1))
        i = start
        depth = 0
        masked = mask_strings(text)
        while i < len(text):
            ch = masked[i]
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                if depth == 0:
                    break
                depth -= 1
            elif ch == "\n" and depth == 0:
                # Peek: another attribute at the same or lower indent ends it.
                nl = text.find("\n", i + 1)
                nxt = text[i + 1 : nl if nl != -1 else len(text)]
                stripped = nxt.strip()
                if stripped and (len(nxt) - len(nxt.lstrip())) <= indent:
                    break
                if re.match(r"\s*(error_message|condition)\s*=", nxt):
                    break
            i += 1
        results.append((line_no, text[start:i]))
    return results


def extract_locals(text: str) -> list[tuple[int, str]]:
    """Every top-level assignment inside a `locals { ... }` block.

    Conditions are not the only place `||` and `&&` appear. The one genuine
    eager-operator hazard in this module lived in a local, where a
    condition-only scan could not see it - and locals are evaluated BEFORE any
    check or precondition, so a throw there is strictly worse: nothing gets to
    report it.
    """
    results: list[tuple[int, str]] = []
    masked = mask_strings(text)
    for m in re.finditer(r"^locals\s*\{", text, re.M):
        # Walk to the matching close brace.
        i = m.end() - 1
        depth = 0
        while i < len(text):
            if masked[i] == "{":
                depth += 1
            elif masked[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        body_start, body_end = m.end(), i
        body, mbody = text[body_start:body_end], masked[body_start:body_end]

        # Each `name = <expr>` at the block's own nesting level.
        for a in re.finditer(r"^[ \t]*([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*", body, re.M):
            j = a.end()
            depth = 0
            while j < len(body):
                ch = mbody[j]
                if ch in "([{":
                    depth += 1
                elif ch in ")]}":
                    if depth == 0:
                        break
                    depth -= 1
                elif ch == "\n" and depth == 0:
                    nl = body.find("\n", j + 1)
                    nxt = body[j + 1 : nl if nl != -1 else len(body)]
                    if re.match(r"[ \t]*[A-Za-z_][A-Za-z0-9_-]*\s*=", nxt) or not nxt.strip():
                        break
                j += 1
            expr = body[a.end():j]
            if "||" in expr or "&&" in expr:
                line_no = text.count("\n", 0, body_start + a.start()) + 1
                results.append((line_no, expr))
    return results


def split_top_level_operands(cond: str) -> tuple[str, list[str]]:
    """Split a condition on || and && that sit at bracket depth zero.

    Depth matters because only a TOP-LEVEL operator has eagerly-evaluated
    operands. An && inside `[for s in ... : s if a && b]` is nested: the
    surrounding jsondecode() or [0] is not its operand and carries no eager
    hazard. Scanning the whole condition instead of its operands was what made
    this linter fire on four of the module's own tests.

    Returns ("", []) when there is no top-level operator.
    """
    masked = mask_strings(cond)
    depth = 0
    parts: list[str] = []
    op = ""
    last = 0
    i = 0
    while i < len(masked) - 1:
        ch = masked[i]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif depth == 0 and masked[i : i + 2] in ("||", "&&"):
            op = masked[i : i + 2]
            parts.append(cond[last:i])
            last = i + 2
            i += 2
            continue
        i += 1
    if not op:
        return "", []
    parts.append(cond[last:])
    return op, parts


def split_ternary_segments(expr: str) -> list[str]:
    """`a && b ? x : y` split into its condition and its two branches.

    `?:` binds LOOSER than `||`/`&&` in HCL, so the operands of that `&&` are
    `a` and `b` - not the whole ternary. Without this split, an expression like
    `local.create && var.on ? flatten([r[0]]) : []` looks like an `&&` whose
    second operand indexes a list, which is a false positive on a shape the
    module uses deliberately.

    Every branch is still returned and scanned, because a branch has its own
    operators and the same eager rule applies inside it. What changes is that
    a branch is no longer treated as an operand of the condition's operator.

    A `:` inside brackets belongs to a for-expression or an object, and the
    depth counter leaves those alone.
    """
    masked = mask_strings(expr)
    segments: list[str] = []
    depth = 0
    last = 0
    for i, ch in enumerate(masked):
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif depth == 0 and ch in "?:":
            segments.append(expr[last:i])
            last = i + 1
    segments.append(expr[last:])
    return [s for s in segments if s.strip()]


def extract_for_bodies(expr: str) -> list[str]:
    """The result expression of every `for ... :` inside `expr`.

    A `||` in a for body is evaluated once PER ELEMENT, so on the 1.9 floor
    both its operands run for every element - the hazard is identical to a
    top-level one. Treating a for body as opaque was how the module's one real
    instance of this hid from the linter: the operator was not at the top level
    of any condition, it was inside anytrue([for r in ... : A || B]).

    Finding the end of the for HEADER means finding the `:` that separates it
    from the body - and skipping any `:` that belongs to a ternary in the `in`
    expression, which is why this counts `?` rather than taking the first `:`.
    """
    masked = mask_strings(expr)
    bodies: list[str] = []
    for m in re.finditer(r"\bfor\s", masked):
        i = m.end()
        depth = 0
        pending_ternary = 0
        while i < len(expr):
            ch = masked[i]
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                if depth == 0:
                    break
                depth -= 1
            elif depth == 0 and ch == "?":
                pending_ternary += 1
            elif depth == 0 and ch == ":":
                if pending_ternary:
                    pending_ternary -= 1
                else:
                    break  # the for separator
            i += 1
        if i >= len(expr) or masked[i] != ":":
            continue
        # The body runs to the close of the enclosing bracket, or to an `if`
        # filter - both are scanned, so take everything.
        j = i + 1
        depth = 0
        while j < len(expr):
            ch = masked[j]
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                if depth == 0:
                    break
                depth -= 1
            j += 1
        body = expr[i + 1 : j].strip()
        if body:
            bodies.append(body)
    return bodies


def lint_text(text: str, label: str) -> None:
    # Conditions AND locals. Locals were the blind spot: the module's one real
    # eager-operator hazard sat in one, so moving an expression out of a check
    # block was enough to step around this linter entirely - and a throw in a
    # local happens before any check can report it.
    # Each unit is (line, expression-to-analyse, enclosing-expression). The
    # third element matters: a for BODY does not contain its own `for ... in
    # data.x` header, so a rule that needs to know where the iteration variable
    # came from has to look at the expression the body was cut out of.
    units: list[tuple[int, str, str]] = []
    for line_no, expr in extract_conditions(text) + extract_locals(text):
        for piece in [expr] + extract_for_bodies(expr):
            units.extend(
                (line_no, segment, expr) for segment in split_ternary_segments(piece)
            )

    for line_no, cond, outer in units:
        # Only || and && are eager, and only at the top level. A ternary is lazy
        # on every version.
        op, operands = split_top_level_operands(cond)
        if not op:
            continue

        # Per-operand, because the version difference lives in a specific
        # place: on 1.12 a later operand is SKIPPED when an earlier one settles
        # the result; on 1.9 it is evaluated anyway. So the hazard is only ever
        # in operands 2..n, and only when an earlier operand is a genuine guard.
        #
        # `x[0] == 1 && x[0] == 2` throws on operand ONE on every version - same
        # behaviour on 1.9 and 1.12, so not this linter's business. That shape
        # was producing false positives across the repo's test files.
        def operand_hits(part: str) -> list[str]:
            bare = part
            for w in SAFE_WRAPPERS:
                bare = strip_balanced(bare, w)
            found = [t for t in THROWING if t in bare]
            if re.search(r"/\s*(var|local)\.", bare):
                found.append("/ division")
            if re.search(r"(==|!=)\s*null", outer) and re.search(
                r"(var|local)\.[a-z_0-9]+\.[a-z_][a-z_0-9]*", bare, re.I
            ):
                found.append("attribute access past a null guard")
            if INDEX.search(bare):
                found.append("[...] indexing")

            # Relational operators throw on a null operand ("argument must not
            # be null"), and a data-source or resource attribute CAN be null -
            # unlike a var, which this repo declares nullable = false
            # everywhere. That is the shape of the one real instance in this
            # module: `r.from <= 22` where from_port comes from
            # aws_vpc_security_group_rule, whose sibling fields the same code
            # already null-checks.
            #
            # No throwing function is involved, so the function-name list could
            # never have caught it. coalesce/try/can are the fix and are
            # stripped above, so a wrapped access does not trip this.
            if re.search(
                r"(?:data|aws_[a-z0-9_]+)\.[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+"
                r"\s*(?:<=|>=|<|>)|"
                r"(?:<=|>=|<|>)\s*(?:data|aws_[a-z0-9_]+)\.[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+",
                bare,
            ):
                found.append("relational comparison against a possibly-null attribute")

            # The high-confidence form, and no guessing anywhere in it: an
            # earlier operand tests a reference against null, and a LATER
            # operand compares that same reference relationally. The code has
            # declared the value nullable by testing it, so on the 1.9 floor -
            # where both operands evaluate - `null >= 0` throws. Mechanical,
            # provenance-free, and it is the single most common way this bug is
            # written.
            for ref in NULL_TESTED.findall(outer):
                if re.search(
                    rf"{re.escape(ref)}\s*(?:<=|>=|<|>)|(?:<=|>=|<|>)\s*{re.escape(ref)}",
                    bare,
                ):
                    found.append(
                        f"relational comparison on {ref}, which an earlier operand "
                        f"tests against null"
                    )

            return found

        per_operand = [operand_hits(o) for o in operands]

        # A guard is an earlier operand that cannot itself throw.
        guarded = any(not h for h in per_operand[:-1])
        hits = sorted({t for h in per_operand[1:] for t in h}) if guarded else []

        if hits:
            findings.append(
                f"{label}:{line_no}: condition uses {op} with an unprotected "
                f"throwing expression ({', '.join(sorted(set(hits)))}). "
                f"Terraform 1.9 evaluates both operands, so this crashes on the "
                f"declared floor and passes on current. Use a nested ternary."
            )


SELF_TEST_BAD = [
    (
        "or with an unprotected regex",
        '''
variable "x" {
  type = string
  validation {
    condition     = var.x == "" || regex("^a", var.x) == "a"
    error_message = "bad."
  }
}
''',
    ),
    (
        "and with an unprotected index",
        '''
variable "y" {
  type = list(string)
  validation {
    condition     = length(var.y) > 0 && var.y[0] == "a"
    error_message = "bad."
  }
}
''',
    ),
    (
        "or with an unprotected jsondecode",
        '''
variable "z" {
  type = string
  validation {
    condition     = var.z == "" || jsondecode(var.z).kind == "x"
    error_message = "bad."
  }
}
''',
    ),
    (
        "precondition with an unprotected parseint",
        '''
resource "null_resource" "r" {
  lifecycle {
    precondition {
      condition     = var.a == "" || parseint(var.a, 16) > 0
      error_message = "bad."
    }
  }
}
''',
    ),
]

SELF_TEST_BAD += [
    (
        "paren inside a string literal defeating the paren walk",
        '''
variable "s" {
  validation {
    condition     = can(regex("^cron\\\\(", var.s)) && regex("^cron", var.s) == "cron"
    error_message = "bad."
  }
}
''',
    ),
    (
        "division by a variable",
        '''
variable "n" {
  validation {
    condition     = var.n == 0 || 100 / var.n > 1
    error_message = "bad."
  }
}
''',
    ),
    (
        "min() over a possibly-empty list",
        '''
variable "l" {
  validation {
    condition     = length(var.l) == 0 || min(var.l...) > 0
    error_message = "bad."
  }
}
''',
    ),
    (
        "one() over a possibly-long list",
        '''
variable "l" {
  validation {
    condition     = length(var.l) < 2 && one(var.l) != ""
    error_message = "bad."
  }
}
''',
    ),
    (
        "base64decode on unvalidated input",
        '''
variable "b" {
  validation {
    condition     = var.b == "" || base64decode(var.b) != ""
    error_message = "bad."
  }
}
''',
    ),
    (
        "substr past the end",
        '''
variable "s" {
  validation {
    condition     = length(var.s) < 4 && substr(var.s, 0, 4) == "abcd"
    error_message = "bad."
  }
}
''',
    ),
]

SELF_TEST_BAD += [
    (
        "a null-tested reference compared relationally in a later operand",
        '''
variable "rate" {
  type     = number
  nullable = true
  validation {
    condition     = var.rate == null || (var.rate >= 0 && var.rate <= 100)
    error_message = "bad - on the 1.9 floor both operands evaluate and null >= 0 throws."
  }
}
''',
    ),
    (
        "the same shape hidden in a local, where a condition-only scan cannot see it",
        '''
locals {
  rate_ok = local.rate == null || local.rate >= 0
}
''',
    ),
    (
        "an indexed list in a local behind a length guard",
        '''
locals {
  first_or_default = length(var.items) == 0 || var.items[0] == "x"
}
''',
    ),
    (
        "slice() out of range behind a length guard",
        '''
variable "l" {
  validation {
    condition     = length(var.l) >= 2 || join(",", slice(var.l, 1, 2)) == "a"
    error_message = "bad."
  }
}
''',
    ),
]


SELF_TEST_GOOD = [
    (
        "&& nested inside a for-expression filter is not a top-level operand",
        '''
run "x" {
  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.build[0].policy).Statement :
      s if s.Sid == "X" && contains(s.Action, "kms:GenerateDataKey*")
    ]) == 1
    error_message = "fine."
  }
}
''',
    ),
    (
        "attribute access on a typed object with optional() defaults",
        '''
variable "o" {
  type     = object({ a = optional(number, 1) })
  nullable = false
  validation {
    condition     = var.o.a >= 1 && var.o.a <= 10
    error_message = "fine."
  }
}
''',
    ),

    (
        "nested ternary is lazy on every version",
        '''
variable "x" {
  type = string
  validation {
    condition     = var.x == "" ? true : can(regex("^a", var.x))
    error_message = "fine."
  }
}
''',
    ),
    (
        "can() swallows the throw",
        '''
variable "x" {
  type = string
  validation {
    condition     = var.x == "" || can(regex("^a", var.x))
    error_message = "fine."
  }
}
''',
    ),
    (
        "length cannot throw on a string",
        '''
variable "t" {
  type = map(string)
  validation {
    condition = alltrue([
      for k, v in var.t : length(k) <= 128 && length(v) <= 256
    ])
    error_message = "fine."
  }
}
''',
    ),
    (
        "no boolean operator at all",
        '''
variable "n" {
  type = number
  validation {
    condition     = var.n >= 1
    error_message = "fine."
  }
}
''',
    ),
]


SELF_TEST_BAD += [
    (
        "a hazard inside a ternary branch is still a hazard",
        '''
locals {
  first = var.enabled ? length(var.items) == 0 || var.items[0] == "x" : false
}
''',
    ),
]

SELF_TEST_GOOD += [
    (
        "a ternary whose condition uses && and whose branch indexes a list",
        '''
locals {
  built = local.create && var.build_on_apply ? flatten([
    for r in aws_imagebuilder_image.this[0].output_resources : tolist(r.amis)
  ]) : []
}
''',
    ),
    (
        "a local with a boolean operator over values that cannot throw",
        '''
locals {
  is_isolated = var.create_endpoints && length(var.nat_gateway_ids) == 0
}
''',
    ),
]


def self_test() -> int:
    global findings
    bad = 0

    for label, src in SELF_TEST_BAD:
        findings = []
        lint_text(src, "case")
        if findings:
            print(f"  ok    detected: {label}")
        else:
            print(f"  FAIL  NOT detected: {label}")
            bad += 1

    for label, src in SELF_TEST_GOOD:
        findings = []
        lint_text(src, "case")
        if findings:
            print(f"  FAIL  false positive on: {label}")
            for f in findings:
                print(f"          {f}")
            bad += 1
        else:
            print(f"  ok    no false positive: {label}")

    # The module's own files must be clean.
    findings = []
    here = pathlib.Path(__file__).resolve().parent.parent
    for f in sorted(here.glob("*.tf")) + sorted((here / "tests").glob("*.tftest.hcl")):
        lint_text(f.read_text(), f.name)
    if findings:
        print("  FAIL  the module's own validations do not pass:")
        for f in findings:
            print(f"          {f}")
        bad += 1
    else:
        print("  ok    the module's own validations are clean")

    print()
    if bad:
        print(f"SELF-TEST FAILED: {bad} case(s)")
        return 1
    print(
        f"SELF-TEST OK: {len(SELF_TEST_BAD)} defects detected, "
        f"{len(SELF_TEST_GOOD)} safe forms accepted, module clean"
    )
    return 0


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[1] == "--self-test":
        return self_test()

    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2

    files: list[pathlib.Path] = []
    for arg in argv[1:]:
        p = pathlib.Path(arg)
        if p.is_dir():
            # *.tftest.hcl too: conditions in run/assert blocks are subject to
            # the same rule, and the sibling module's instance of this bug was
            # in its test file.
            files.extend(sorted(p.glob("*.tf")))
            files.extend(sorted(p.glob("*.tftest.hcl")))
            files.extend(sorted((p / "tests").glob("*.tftest.hcl")))
        elif p.is_file():
            files.append(p)
        else:
            print(f"FATAL: {p} does not exist", file=sys.stderr)
            return 2

    if not files:
        print("FATAL: no .tf files to check", file=sys.stderr)
        return 2

    for f in files:
        lint_text(f.read_text(), str(f))

    if findings:
        print(f"FAILED: {len(findings)} finding(s)", file=sys.stderr)
        for f in findings:
            print(f"  - {f}", file=sys.stderr)
        return 1

    print(f"OK: {len(files)} file(s), no eager-operator hazards in any condition")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
