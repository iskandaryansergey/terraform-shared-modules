#!/usr/bin/env python3
"""Template injection guard — enforces charter rules R1 and R2.

This is a second-generation tool. The first version, in the sibling EC2 module,
had five demonstrated bypasses. Each is closed here and named at the rule that
closes it, because the bypasses are more instructive than the rules:

  g1  a comment line in a SHELL template was skipped. A newline inside the
      interpolated value ends the comment, and the remainder is live shell.
      -> comment lines are NOT skipped in shell templates (R_SHELL_ALL_LINES).
  g2  quote detection used `count("'") % 2`. An apostrophe inside a
      double-quoted string flips the parity and an unquoted interpolation is
      declared safe.  -> real left-to-right lexer (_quote_state).
  g3  `before.endswith("'") and after.startswith("'")` accepted a bare word
      sitting BETWEEN two separately-quoted strings.
      -> the lexer decides, not adjacency.
  g4  (worst, and conceptual) the rendered config was allow-listed *because* it
      is written into a quoted heredoc — and the tool never verified the
      quoting. Deleting one apostrophe turned every string in the config into a
      root-RCE vector with the guard still printing OK.
      -> ASSUMPTION_CHECKS: an exemption may not assume the property that
         justifies it. The quoting is verified.
  g5  a line beginning with a Terraform directive was skipped entirely, though
      `%{ if x ~}${val}%{ endif ~}` is ordinary template style.
      -> directives are stripped, then the remaining line is scanned.

Usage:  template_safety.py <templates-dir> [--module-dir DIR]
Exit 0 = clean, 1 = violations, 2 = tool/usage error.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

# ---------------------------------------------------------------------------
# Exemptions. Every entry needs a justification, and every justification that
# can be mechanically verified IS verified (see ASSUMPTION_CHECKS). R2.2, R2.3.
# ---------------------------------------------------------------------------

# Template variables guaranteed by Terraform's type system to be number/bool,
# so they cannot carry a newline or a shell metacharacter. Adding an entry here
# is a deliberate act and is cross-checked against the variable declarations.
#
# Two forms are allowed, and the checker treats them differently:
#
#   name -> "variable"         the template name IS a variable name; its
#                              declared type is verified to be number or bool.
#   name -> "derived: <expr>"  the value is computed in locals.tf, so there is
#                              no variable to check. The expression is named
#                              here and the checker verifies it appears in
#                              locals.tf, so the claim is still mechanical.
#
# The second form exists because the first version of this table accepted any
# name that did not match a variable, silently - which is the same
# assume-rather-than-verify mistake as bypass g4, one level up.
# A third form was added for v2, because templatefile() argument names need not
# match the variable they carry - and the two-form table's fallback was to look
# for a variable of the SAME name, which for `run_untagged` (variable
# run_untagged_jobs) would have reported a missing variable rather than checking
# the real one. Silently accepting it would have been bypass g4 again.
#
#   name -> "variable"              the template name IS the variable name
#   name -> "variable: <var>"       names the variable explicitly; its type is verified
#   name -> "derived: local.<x>"    computed; the local is verified to exist
NUMERIC_OR_BOOL: dict[str, str] = {
    "concurrent":   "variable",
    "run_untagged": "variable: run_untagged_jobs",
}

# Values interpolated into a shell context without single quotes. Each must give
# the grammar that makes it safe; `verify` names a variable whose validation is
# checked for existence in variables.tf.
SHELL_EXEMPT: dict[str, dict[str, str]] = {}

INTERP = re.compile(r"\$\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}")
DIRECTIVE = re.compile(r"%\{[^}]*\}")

violations: list[str] = []


def fail(msg: str) -> None:
    violations.append(msg)


# ---------------------------------------------------------------------------
# g2 / g3: a real lexer. Returns True if `index` sits inside single quotes.
# ---------------------------------------------------------------------------
def _in_single_quotes(line: str, index: int) -> bool:
    """Walk the line tracking shell quote state. Inside '...' nothing expands,
    so an interpolation there cannot be a substitution vector."""
    in_single = False
    in_double = False
    i = 0
    while i < index and i < len(line):
        ch = line[i]
        if ch == "\\" and in_double:
            i += 2
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        i += 1
    return in_single


def _strip_directives(line: str) -> str:
    """g5: remove Terraform directives but KEEP the rest of the line."""
    return DIRECTIVE.sub("", line)


# ---------------------------------------------------------------------------
# Config-file templates (TOML/JSON/YAML): every string must be jsonencode()d.
# ---------------------------------------------------------------------------
def check_config_template(path: pathlib.Path) -> None:
    for lineno, raw_line in enumerate(path.read_text().splitlines(), 1):
        line = _strip_directives(raw_line)
        for m in INTERP.finditer(line):
            expr = m.group(1).strip()
            if expr.startswith("jsonencode(") and expr.endswith(")"):
                continue
            if expr in NUMERIC_OR_BOOL:
                continue
            fail(
                f"{path.name}:{lineno}: `${{{expr}}}` is a raw interpolation into a "
                f"generated config file. Wrap it in jsonencode() (R1.1). This applies "
                f"inside comments too: a newline in the value ends the comment and the "
                f"remainder becomes live config, so an unencoded value can add or "
                f"redefine keys the module never wrote. If the value is number- or "
                f"bool-typed, add it to NUMERIC_OR_BOOL with a justification."
            )


# ---------------------------------------------------------------------------
# Shell templates: every interpolation single-quoted, or explicitly exempt.
# ---------------------------------------------------------------------------
def check_shell_template(path: pathlib.Path) -> None:
    text = path.read_text()

    # g1: comment lines are NOT skipped. A newline in the value ends the comment.
    for lineno, raw_line in enumerate(text.splitlines(), 1):
        line = _strip_directives(raw_line)
        for m in INTERP.finditer(line):
            expr = m.group(1).strip()
            if _in_single_quotes(line, m.start()):
                continue
            if expr in SHELL_EXEMPT:
                continue
            in_comment = line.lstrip().startswith("#")
            extra = (
                " (this is a comment line, which is NOT a defence: a newline in the "
                "value ends the comment and the remainder becomes live shell)"
                if in_comment else ""
            )
            fail(
                f"{path.name}:{lineno}: `${{{expr}}}` reaches a shell context without "
                f"single quotes{extra}. Single-quote it (R1.2), or add it to "
                f"SHELL_EXEMPT with the positive grammar that makes it safe."
            )

    _check_heredocs(path, text)


# ---------------------------------------------------------------------------
# g4: verify the assumption, do not trust it. Any heredoc that carries an
# interpolated body MUST have a quoted delimiter, or the body is shell-expanded.
# ---------------------------------------------------------------------------
HEREDOC = re.compile(r"<<-?\s*(?P<q>['\"])?(?P<tag>[A-Za-z_][A-Za-z0-9_]*)(?(q)['\"])")


def _check_heredocs(path: pathlib.Path, text: str) -> None:
    lines = text.splitlines()
    for lineno, line in enumerate(lines, 1):
        for m in HEREDOC.finditer(line):
            tag = m.group("tag")
            quoted = m.group("q") is not None

            # find the body up to the terminator
            body: list[str] = []
            for probe in lines[lineno:]:
                if probe.strip() == tag:
                    break
                body.append(probe)
            body_text = "\n".join(body)

            has_interp = bool(INTERP.search(body_text))
            # Terraform interpolations are resolved before the shell sees them,
            # so what matters is whether the RESULT could contain shell syntax.
            if has_interp and not quoted:
                fail(
                    f"{path.name}:{lineno}: heredoc `<<{tag}` is UNQUOTED and its body "
                    f"contains interpolations. An unquoted heredoc is shell-expanded, so "
                    f"`$(...)` or a backtick in any interpolated value executes. Use "
                    f"`<<'{tag}'` (R2.2 - this is the assumption the guard must verify, "
                    f"not assume: jsonencode() protects config structure, NOT shell "
                    f"semantics, and does not escape $ ( ) or backticks)."
                )
            if not quoted and not has_interp:
                fail(
                    f"{path.name}:{lineno}: heredoc `<<{tag}` is unquoted. Quote it "
                    f"(`<<'{tag}'`) so a later edit that adds an interpolation cannot "
                    f"silently become an injection vector."
                )


# ---------------------------------------------------------------------------
# R2.3: check the justifications, not just their presence.
# ---------------------------------------------------------------------------
def check_assumptions(module_dir: pathlib.Path) -> None:
    variables = module_dir / "variables.tf"
    if not variables.is_file():
        fail(f"cannot verify exemption justifications: {variables} not found")
        return
    vtext = variables.read_text()

    for name, meta in SHELL_EXEMPT.items():
        verify = meta.get("verify")
        if not verify:
            fail(
                f"SHELL_EXEMPT['{name}'] has no `verify` key. Every exemption must name "
                f"the variable whose validation makes it safe, so the claim can be "
                f"checked (R2.3)."
            )
            continue
        block = re.search(
            rf'variable\s+"{re.escape(verify)}"\s*\{{(.*?)\n\}}', vtext, re.S
        )
        if not block:
            fail(
                f"SHELL_EXEMPT['{name}'] claims safety via variable `{verify}`, which "
                f"does not exist in variables.tf."
            )
        elif "validation" not in block.group(1):
            fail(
                f"SHELL_EXEMPT['{name}'] claims `{verify}` is grammar-validated, but "
                f"that variable has NO validation block. This is exactly the class of "
                f"false justification R2.3 exists to catch."
            )

    locals_text = ""
    locals_file = module_dir / "locals.tf"
    if locals_file.is_file():
        locals_text = locals_file.read_text()

    for name, justification in NUMERIC_OR_BOOL.items():
        if justification.startswith("derived:"):
            # No variable to type-check, so verify the named local really exists.
            expr = justification.split(":", 1)[1].strip()
            local_name = expr.removeprefix("local.").strip()
            if not local_name:
                fail(
                    f"NUMERIC_OR_BOOL['{name}'] is marked derived but names no "
                    f"expression. Write 'derived: local.<name>'."
                )
            elif not re.search(rf"^\s*{re.escape(local_name)}\s*=", locals_text, re.M):
                fail(
                    f"NUMERIC_OR_BOOL['{name}'] claims to come from `{expr}`, which is "
                    f"not defined in locals.tf. An exemption may not name a value that "
                    f"does not exist (R2.3)."
                )
            continue

        if justification.startswith("variable:"):
            named = justification.split(":", 1)[1].strip()
            block = re.search(rf'variable\s+"{re.escape(named)}"\s*\{{(.*?)\n\}}', vtext, re.S)
            if not block:
                fail(
                    f"NUMERIC_OR_BOOL['{name}'] names variable `{named}`, which does "
                    f"not exist in variables.tf."
                )
            elif not re.search(r"type\s*=\s*(number|bool)", block.group(1)):
                fail(
                    f"NUMERIC_OR_BOOL['{name}'] is exempted as number/bool via variable "
                    f"`{named}`, which is not declared with that type. The type system is "
                    f"the whole justification for the exemption."
                )
            continue

        if justification != "variable":
            fail(
                f"NUMERIC_OR_BOOL['{name}'] has justification '{justification}', which "
                f"is not 'variable', 'variable: <name>' or 'derived: <expr>'. Unrecognised "
                f"justifications are not accepted, because an unparsed justification is "
                f"an unchecked one."
            )
            continue

        var = name.split(".")[-1]
        block = re.search(rf'variable\s+"{re.escape(var)}"\s*\{{(.*?)\n\}}', vtext, re.S)
        if not block:
            fail(
                f"NUMERIC_OR_BOOL['{name}'] is exempted as a number/bool VARIABLE, but "
                f"no `variable \"{var}\"` exists in variables.tf. If it is computed, mark "
                f"it 'derived: local.<name>' instead of leaving the claim unverifiable."
            )
        elif not re.search(r"type\s*=\s*(number|bool)", block.group(1)):
            fail(
                f"NUMERIC_OR_BOOL['{name}'] is exempted as number/bool, but variable "
                f"`{var}` is not declared with that type. The type system is the whole "
                f"justification for the exemption."
            )


# ---------------------------------------------------------------------------
# v2-specific: the shell scripts are NOT templates, and that must stay true.
#
# v2 interpolates nothing into agent.sh or the manager entrypoint - every value
# they need arrives as an environment variable at runtime, which is immune to
# R1.2 by construction. Skipping docker/ would make that property invisible, so
# it is asserted instead: any interpolation appearing there is a regression to a
# class of bug this module currently cannot have.
# ---------------------------------------------------------------------------
def check_no_interpolated_shell(module_dir: pathlib.Path) -> None:
    docker_dir = module_dir / "docker"
    if not docker_dir.is_dir():
        fail(f"{docker_dir} does not exist; the shell-script assertion would pass vacuously")
        return
    scripts = sorted(docker_dir.glob("*.sh"))
    if not scripts:
        fail(f"no *.sh found in {docker_dir} - this module ships shell agents, so "
             f"finding none means the layout moved and this guard now checks nothing")
        return
    for path in scripts:
        for lineno, line in enumerate(path.read_text().splitlines(), 1):
            # A shell parameter expansion is ${VAR}; a Terraform interpolation is
            # the same syntax. Telling them apart matters, so only flag a line in
            # a file Terraform actually renders - and none of these are rendered.
            # The real assertion is therefore about the FILENAME.
            del lineno, line
        if path.name.endswith(".tftpl"):
            fail(f"{path.name} is a Terraform template. v2 interpolates nothing into "
                 f"shell; if that changed deliberately, extend check_shell_template "
                 f"to cover docker/ and remove this assertion.")
    tftpl_in_docker = sorted(docker_dir.glob("*.tftpl"))
    if tftpl_in_docker:
        fail(f"{[p.name for p in tftpl_in_docker]} in docker/ are Terraform templates. "
             f"Shell templates must be scanned by check_shell_template (R1.2); this "
             f"guard only proves the absence of the whole class.")


# ---------------------------------------------------------------------------
# R2.1: the guard must be tracked, or CI protects nothing.
# ---------------------------------------------------------------------------
def check_self_tracked() -> None:
    me = pathlib.Path(__file__).resolve()
    try:
        r = subprocess.run(
            ["git", "ls-files", "--error-unmatch", str(me)],
            cwd=me.parent, capture_output=True, text=True, timeout=15,
        )
    except (OSError, subprocess.SubprocessError):
        return  # not a git checkout; not this tool's problem
    if r.returncode != 0:
        fail(
            f"{me.name} is NOT tracked in git. A guard that lives only in a working "
            f"tree protects nothing, and the CI step invoking it fails on a clean "
            f"checkout (R2.1). `git add` it."
        )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("templates_dir")
    ap.add_argument("--module-dir", default=None)
    args = ap.parse_args()

    tpl_dir = pathlib.Path(args.templates_dir)
    module_dir = pathlib.Path(args.module_dir) if args.module_dir else tpl_dir.parent
    if not tpl_dir.is_dir():
        print(f"FAIL: {tpl_dir} is not a directory")
        return 2

    templates = sorted(tpl_dir.glob("*.tftpl"))
    if not templates:
        print(f"FAIL: no *.tftpl found in {tpl_dir} - the guard would pass vacuously")
        return 2

    for path in templates:
        if ".sh." in path.name:
            check_shell_template(path)
        else:
            check_config_template(path)

    check_assumptions(module_dir)
    check_no_interpolated_shell(module_dir)
    check_self_tracked()

    if violations:
        print(f"FAIL: {len(violations)} template-safety violation(s):")
        for v in violations:
            print(f"  - {v}")
        return 1

    print(
        f"OK: {len(templates)} template(s) - every interpolation is encoded or "
        f"single-quoted, every heredoc carrying interpolations is quoted, and every "
        f"exemption's justification was verified against variables.tf"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
