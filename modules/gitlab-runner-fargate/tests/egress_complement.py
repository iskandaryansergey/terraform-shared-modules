#!/usr/bin/env python3
"""Verify the precomputed job-egress CIDR list against its stated exclusions.

Terraform cannot compute a CIDR complement, so locals.tf carries the complement
of the default exclusion set as a literal. A precomputed literal that claims to
be derived from another list is exactly the kind of thing that drifts silently:
someone adds a range to job_egress_exclude_cidrs, the literal stays as it was,
and the module now documents a carve-out it does not implement.

The sibling EC2 module shipped a hand-maintained 30-entry list of the same kind.
It was correct for RFC1918 and silently omitted CGNAT (100.64/10) - the standard
EKS pod range - so its headline network control did not cover the estates most
likely to need it. Nobody caught it because a 30-entry list of CIDRs cannot be
checked by eye. This is that check, mechanised (R2, R8).

Run with --emit to print a correct literal for a changed exclusion set.

Usage:  egress_complement.py <module-dir> [--emit]
Exit 0 = the literal matches its exclusions, 1 = drift, 2 = tool/usage error.
"""
from __future__ import annotations

import ipaddress
import pathlib
import re
import sys

CIDR = re.compile(r'"(\d{1,3}(?:\.\d{1,3}){3}/\d{1,2})"')


def complement(excluded: list[str]) -> list[ipaddress.IPv4Network]:
    """Everything in 0.0.0.0/0 that is not inside one of `excluded`."""
    allowed = [ipaddress.ip_network("0.0.0.0/0")]
    for entry in excluded:
        target = ipaddress.ip_network(entry)
        remaining: list[ipaddress.IPv4Network] = []
        for net in allowed:
            if not net.overlaps(target):
                remaining.append(net)
            elif target.subnet_of(net):
                remaining.extend(net.address_exclude(target))
            elif net.subnet_of(target):
                pass  # fully removed
            else:
                remaining.append(net)
        allowed = remaining
    return sorted(ipaddress.collapse_addresses(allowed))


def extract_block(text: str, start_pattern: str) -> list[str] | None:
    """Pull the CIDR strings out of the first [...] list after start_pattern."""
    anchor = re.search(start_pattern, text)
    if not anchor:
        return None
    open_idx = text.find("[", anchor.end())
    close_idx = text.find("]", open_idx)
    if open_idx == -1 or close_idx == -1:
        return None
    return CIDR.findall(text[open_idx:close_idx])


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2

    module_dir = pathlib.Path(sys.argv[1])
    emit = "--emit" in sys.argv

    variables = module_dir / "variables.tf"
    locals_tf = module_dir / "locals.tf"
    for p in (variables, locals_tf):
        if not p.is_file():
            print(f"FAIL: {p} not found")
            return 2

    # The declared exclusion set, from the variable's default.
    excluded = extract_block(
        variables.read_text(), r'variable\s+"job_egress_exclude_cidrs"'
    )
    if not excluded:
        print("FAIL: could not read the default of job_egress_exclude_cidrs from "
              "variables.tf. If the variable was renamed, this checker must be "
              "updated with it - a checker that silently finds nothing is worse "
              "than no checker.")
        return 2

    locals_text = locals_tf.read_text()

    # The literal that claims to be its complement.
    literal = extract_block(locals_text, r"computed_job_egress\s*=")
    if not literal:
        print("FAIL: could not read local.computed_job_egress from locals.tf.")
        return 2

    # locals.tf also mirrors the exclusion set for its precondition. If that copy
    # drifts from the variable default, the precondition guards the wrong thing.
    mirrored = extract_block(locals_text, r"default_exclusions\s*=")
    if mirrored is None:
        print("FAIL: could not read local.default_exclusions from locals.tf.")
        return 2

    expected = [str(n) for n in complement(excluded)]
    actual = literal

    problems: list[str] = []

    if sorted(mirrored) != sorted(excluded):
        problems.append(
            f"local.default_exclusions in locals.tf does not match the default of "
            f"job_egress_exclude_cidrs in variables.tf.\n"
            f"      variables.tf: {sorted(excluded)}\n"
            f"      locals.tf:    {sorted(mirrored)}\n"
            f"      The precondition that refuses a mismatched exclusion set "
            f"compares against the locals.tf copy, so a drifted copy makes that "
            f"guard check the wrong list."
        )

    if actual != expected:
        missing = [c for c in expected if c not in actual]
        extra = [c for c in actual if c not in expected]
        detail = ""
        if missing:
            detail += f"\n      MISSING from the literal (so unreachable): {missing}"
        if extra:
            # This is the dangerous direction: a range in the literal that the
            # exclusions say should be carved out.
            detail += (f"\n      PRESENT in the literal but excluded by the "
                       f"declared set (so reachable when it should not be): {extra}")
        if not missing and not extra:
            detail = "\n      Same set, different order or grouping."
        problems.append(
            f"local.computed_job_egress is not the complement of "
            f"job_egress_exclude_cidrs.{detail}"
        )

    if problems:
        print(f"FAIL: {len(problems)} egress-complement problem(s):")
        for p in problems:
            print(f"  - {p}")
        if emit or True:
            print("\nCorrect literal for the declared exclusion set "
                  f"({len(expected)} entries):")
            for i in range(0, len(expected), 5):
                print("    " + " ".join(f'"{c}",' for c in expected[i:i + 5]))
        return 1

    if emit:
        print(f"Literal for the declared exclusion set ({len(expected)} entries):")
        for i in range(0, len(expected), 5):
            print("    " + " ".join(f'"{c}",' for c in expected[i:i + 5]))

    total = sum(ipaddress.ip_network(c).num_addresses for c in expected)
    print(f"OK: local.computed_job_egress is exactly the complement of "
          f"job_egress_exclude_cidrs - {len(expected)} CIDRs, "
          f"{100 * total / 2 ** 32:.3f}% of IPv4, "
          f"excluding {', '.join(sorted(excluded))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
