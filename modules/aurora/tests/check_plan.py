#!/usr/bin/env python3
"""Gates a real plan of the aurora module before it is applied.

The module refuses most unsafe inputs at plan time. What it cannot see is the
plan itself - what Terraform is about to do to a cluster that already exists -
and what a caller acknowledged on purpose. This reads `terraform show -json`
output and fails on what a reviewer should never have to spot by eye:

  errors (exit 1)
    - a cluster, instance or global cluster that would be deleted or replaced
    - a subnet group that would be deleted or replaced (the cluster names it;
      the name is ForceNew there), or a log group (its logs go with it)
    - a cluster without storage encryption, or without deletion protection
    - an instance that is publicly accessible
    - a security group rule open to 0.0.0.0/0 or ::/0
    - a cluster parameter group that does not enforce TLS
      (rds.force_ssl = 1 / require_secure_transport = ON)
    - a master password in the plan (it lands in state in plaintext)
    - with --require-cmk: a cluster on the AWS-managed key
    - with --required-tags K1,K2: a cluster missing one of those tags

  warnings (printed, exit 0)
    - any other resource of the module that would be deleted or replaced

Every rule is about resources of these types, wherever they sit in the
configuration, so it works on a root module that calls aurora under any name.

Usage:
  terraform plan -out plan.tfplan
  terraform show -json plan.tfplan > plan.json
  check_plan.py plan.json [--require-cmk] [--required-tags CostCentre,Owner]
                          [--allow-replace ADDRESS ...]
  check_plan.py --self-test

Exit 0 = clean (warnings allowed), 1 = an error, 2 = tool/usage error.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field

PROTECTED = {
    "aws_rds_cluster", "aws_rds_cluster_instance", "aws_rds_global_cluster",
    "aws_db_subnet_group", "aws_cloudwatch_log_group",
}
MODULE_TYPES = PROTECTED | {
    "aws_db_subnet_group", "aws_security_group", "aws_rds_cluster_parameter_group",
    "aws_db_parameter_group", "aws_db_proxy", "aws_rds_cluster_endpoint",
    "aws_cloudwatch_log_group", "aws_iam_role", "aws_rds_cluster_activity_stream",
}
TLS_ON = {("rds.force_ssl", "1"), ("require_secure_transport", "on"), ("require_secure_transport", "1")}


@dataclass
class Report:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


def changes(plan: dict):
    """Each resource change as (address, type, actions, after, after_sensitive, after_unknown)."""
    for rc in plan.get("resource_changes", []):
        ch = rc.get("change", {})
        yield (
            rc["address"],
            rc["type"],
            ch.get("actions", []),
            ch.get("after") or {},
            ch.get("after_sensitive") or {},
            ch.get("after_unknown") or {},
        )


def configured_key(plan: dict, address: str) -> bool:
    """Whether the configuration gives the cluster at address a key, as a
    constant or a reference. For a cluster inside a module call that is the
    call's kms_key_arn argument (this module's input); for a cluster written
    directly, its own kms_key_id."""
    def has_value(expr: dict | None) -> bool:
        if not expr:
            return False
        return bool(expr.get("references")) or bool(expr.get("constant_value"))

    module = (plan.get("configuration") or {}).get("root_module", {})
    call = None
    # address: module.a.module.b.aws_rds_cluster.this[0] -> walk a, then b.
    for name in re.findall(r"module\.([^.\[]+)(?:\[[^\]]*\])?\.", address):
        call = (module.get("module_calls") or {}).get(name)
        if call is None:
            return False
        module = call.get("module", {})
    if call is not None:
        return has_value((call.get("expressions") or {}).get("kms_key_arn"))
    for res in module.get("resources", []):
        if res.get("type") == "aws_rds_cluster" and address.startswith(res.get("address", "")):
            return has_value((res.get("expressions") or {}).get("kms_key_id"))
    return False


def check(plan: dict, require_cmk: bool, required_tags: list[str], allow_replace: set[str]) -> Report:
    r = Report()

    for address, rtype, actions, after, after_sensitive, after_unknown in changes(plan):
        removing = "delete" in actions
        writing = "create" in actions or "update" in actions

        if removing:
            what = "replaced" if "create" in actions else "deleted"
            if rtype in PROTECTED and address not in allow_replace:
                r.errors.append(f"{address} would be {what}. If that is intended, pass --allow-replace {address}")
            elif rtype in MODULE_TYPES:
                r.warnings.append(f"{address} would be {what}")

        if not writing:
            continue

        if rtype == "aws_rds_cluster":
            if after.get("storage_encrypted") is False:
                r.errors.append(f"{address}: storage_encrypted is false")
            if after.get("deletion_protection") is False:
                r.errors.append(f"{address}: deletion_protection is false")
            # `terraform show -json` includes sensitive values. after_sensitive
            # alone means nothing: the schema marks master_password sensitive,
            # so it is true on every cluster, password or not.
            if after.get("master_password") is not None or after_unknown.get("master_password") is True:
                r.errors.append(f"{address}: master_password is set - it is stored in state in plaintext")
            if require_cmk and not after.get("kms_key_id"):
                # Unknown is either "AWS picks the default key" (nothing
                # configured) or a key created in the same run. Only the
                # configuration can tell them apart.
                if after_unknown.get("kms_key_id") is True and configured_key(plan, address):
                    r.warnings.append(f"{address}: kms_key_id is known only after apply - check it is a customer-managed key")
                else:
                    r.errors.append(f"{address}: no kms_key_id - storage is on the AWS-managed key")
            tags = after.get("tags_all") or after.get("tags") or {}
            for key in required_tags:
                if not str(tags.get(key, "")).strip():
                    r.errors.append(f"{address}: required tag {key} is missing or empty")

        elif rtype == "aws_rds_cluster_instance":
            if after.get("publicly_accessible") is True:
                r.errors.append(f"{address}: publicly_accessible is true")

        elif rtype in ("aws_vpc_security_group_ingress_rule", "aws_vpc_security_group_egress_rule"):
            for attr in ("cidr_ipv4", "cidr_ipv6"):
                if after.get(attr) in ("0.0.0.0/0", "::/0"):
                    r.errors.append(f"{address}: {attr} is {after[attr]}")

        elif rtype == "aws_rds_cluster_parameter_group":
            params = {(p.get("name"), str(p.get("value", "")).lower()) for p in after.get("parameter") or []}
            if not params & TLS_ON:
                r.errors.append(f"{address}: TLS is not enforced (no rds.force_ssl = 1 or require_secure_transport = ON)")

    return r


# ---------------------------------------------------------------------------
# Self-test: a plan shaped like `terraform show -json`, with one of each
# problem, and a clean one.
# ---------------------------------------------------------------------------


def _rc(address, rtype, actions, after, after_sensitive=None):
    return {
        "address": address,
        "type": rtype,
        "change": {"actions": actions, "after": after, "after_sensitive": after_sensitive or {}},
    }


def self_test() -> int:
    clean = {"resource_changes": [
        _rc("module.db.aws_rds_cluster.this[0]", "aws_rds_cluster", ["create"], {
            "storage_encrypted": True, "deletion_protection": True, "kms_key_id": "arn:aws:kms:x",
            "tags_all": {"CostCentre": "cc-1", "Owner": "team"}, "master_password": None,
        # Sensitive by schema, null in value: an RDS-managed password. Clean.
        }, {"master_password": True}),
        _rc('module.db.aws_rds_cluster_instance.this["1"]', "aws_rds_cluster_instance", ["update"], {"publicly_accessible": False}),
        _rc('module.db.aws_vpc_security_group_ingress_rule.this["app"]', "aws_vpc_security_group_ingress_rule", ["create"], {"cidr_ipv4": "10.0.0.0/16"}),
        _rc("module.db.aws_rds_cluster_parameter_group.this[0]", "aws_rds_cluster_parameter_group", ["create"], {
            "parameter": [{"name": "rds.force_ssl", "value": "1"}],
        }),
        _rc("module.db.aws_security_group.this[0]", "aws_security_group", ["delete", "create"], {}),
    ]}

    bad = {"resource_changes": [
        _rc("module.db.aws_rds_cluster.this[0]", "aws_rds_cluster", ["delete", "create"], {
            "storage_encrypted": False, "deletion_protection": False, "kms_key_id": None, "tags_all": {"Owner": ""},
            "master_password": "hunter2",
        }, {"master_password": True}),
        _rc('module.db.aws_rds_cluster_instance.this["1"]', "aws_rds_cluster_instance", ["update"], {"publicly_accessible": True}),
        _rc('module.db.aws_vpc_security_group_ingress_rule.this["any"]', "aws_vpc_security_group_ingress_rule", ["create"], {"cidr_ipv6": "::/0"}),
        _rc("module.db.aws_rds_cluster_parameter_group.this[0]", "aws_rds_cluster_parameter_group", ["create"], {
            "parameter": [{"name": "rds.force_ssl", "value": "0"}],
        }),
        _rc('module.db.aws_cloudwatch_log_group.this["postgresql"]', "aws_cloudwatch_log_group", ["delete"], {}),
    ]}

    expected_in_bad = [
        "would be replaced", "storage_encrypted is false", "deletion_protection is false",
        "master_password is set", "AWS-managed key", "required tag CostCentre", "required tag Owner",
        "publicly_accessible is true", "cidr_ipv6 is ::/0", "TLS is not enforced",
        'aws_cloudwatch_log_group.this["postgresql"] would be deleted',
    ]

    failed = 0
    r = check(clean, require_cmk=True, required_tags=["CostCentre", "Owner"], allow_replace=set())
    if r.errors:
        failed += 1
        print(f"  FAIL  clean plan raised errors: {r.errors}")
    else:
        print("  ok    clean plan passes")
    if len(r.warnings) == 1 and "aws_security_group" in r.warnings[0]:
        print("  ok    a replaced supporting resource is a warning, not an error")
    else:
        failed += 1
        print(f"  FAIL  expected one security-group warning, got {r.warnings}")

    r = check(bad, require_cmk=True, required_tags=["CostCentre", "Owner"], allow_replace=set())
    for text in expected_in_bad:
        if any(text in e for e in r.errors):
            print(f"  ok    detected: {text}")
        else:
            failed += 1
            print(f"  FAIL  missed: {text}")

    # A key unknown at plan: from a resource in the same run (warning), or
    # none configured, so AWS will pick its default (error).
    def unknown_key_plan(call_expressions):
        rc = _rc("module.db.aws_rds_cluster.this[0]", "aws_rds_cluster", ["create"],
                 {"storage_encrypted": True, "deletion_protection": True})
        rc["change"]["after_unknown"] = {"kms_key_id": True}
        return {"resource_changes": [rc], "configuration": {"root_module": {"module_calls": {
            "db": {"expressions": call_expressions, "module": {"resources": []}}}}}}

    r = check(unknown_key_plan({"kms_key_arn": {"references": ["aws_kms_key.db.arn", "aws_kms_key.db"]}}), True, [], set())
    if not r.errors and any("known only after apply" in w for w in r.warnings):
        print("  ok    a key created in the same run is a warning")
    else:
        failed += 1
        print(f"  FAIL  same-run key: errors={r.errors} warnings={r.warnings}")

    r = check(unknown_key_plan({}), True, [], set())
    if any("AWS-managed key" in e for e in r.errors):
        print("  ok    no key configured is an error even while the value is unknown")
    else:
        failed += 1
        print(f"  FAIL  missing key not detected: {r.errors}")

    r = check(bad, require_cmk=False, required_tags=[], allow_replace={"module.db.aws_rds_cluster.this[0]"})
    if any("would be replaced" in e for e in r.errors):
        failed += 1
        print("  FAIL  --allow-replace did not allow the replacement")
    else:
        print("  ok    --allow-replace accepts a named replacement")

    if failed:
        print(f"\nSELF-TEST FAILED: {failed} problem(s)")
        return 1
    print("\nSELF-TEST OK")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description="Gate a terraform plan of the aurora module.")
    p.add_argument("plan", nargs="?", help="output of terraform show -json <planfile>")
    p.add_argument("--require-cmk", action="store_true", help="fail when a cluster is on the AWS-managed key")
    p.add_argument("--required-tags", default="", help="comma-separated tag keys every cluster must carry")
    p.add_argument("--allow-replace", nargs="*", default=[], metavar="ADDRESS", help="addresses allowed to be deleted or replaced")
    p.add_argument("--self-test", action="store_true")
    a = p.parse_args()

    if a.self_test:
        return self_test()
    if not a.plan:
        p.print_usage(sys.stderr)
        return 2
    try:
        with open(a.plan, encoding="utf-8") as fh:
            plan = json.load(fh)
    except (OSError, json.JSONDecodeError) as e:
        print(f"cannot read {a.plan}: {e}", file=sys.stderr)
        return 2
    if "resource_changes" not in plan:
        print(f"{a.plan} has no resource_changes - is it `terraform show -json <planfile>` output?", file=sys.stderr)
        return 2

    tags = [t.strip() for t in a.required_tags.split(",") if t.strip()]
    r = check(plan, a.require_cmk, tags, set(a.allow_replace))

    for w in r.warnings:
        print(f"WARN   {w}")
    for e in r.errors:
        print(f"ERROR  {e}")
    if r.errors:
        print(f"\nFAIL: {len(r.errors)} error(s), {len(r.warnings)} warning(s)")
        return 1
    print(f"OK: no errors, {len(r.warnings)} warning(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
