#!/usr/bin/env python3
"""Rehearses the 1.x -> 2.x upgrade against this module, without AWS.

moved.tf promises that a 1.x deployment plans as updates. This proves it the
only way that counts - a real plan of this module over a 1.x state:

  1. writes a root module calling ../ with the inputs docs/UPGRADE-2.0.md
     section 2 prescribes for a typical 1.x cluster (two instances, a created
     subnet group, a security group, a log group, a custom endpoint);
  2. writes that deployment's state at the 1.x addresses, in both shapes 1.x
     shipped: early (aws_db_subnet_group.main without count) and late
     (aws_db_subnet_group.main[0]);
  3. runs `terraform plan -refresh=false`: no resource is read from AWS; the
     one data source that would call AWS (aws_caller_identity) is answered by
     a fake STS endpoint on localhost;
  4. fails unless every 1.x object moved (resource_changes[].previous_address)
     and nothing that holds data or placement is deleted or replaced: the
     cluster, its instances, the subnet group, the log groups. Then runs
     check_plan.py over the same plan.

The state carries what a 1.x apply leaves in state for the ForceNew
attributes; the rest is left null and shows as in-place updates, which is
what a first 2.x plan shows anyway (docs/UPGRADE-2.0.md section 6).

Usage:
  python3 tests/check_moved.py                 # both layouts
  python3 tests/check_moved.py --keep DIR      # keep the rehearsal roots
Needs terraform on PATH and network access for `terraform init` (or a
provider cache). Exit 0 = both layouts clean, 1 = a failed promise.
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading

MODULE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ACCOUNT = "111122223333"
REGION = "eu-west-2"
NAME = "orders"
KMS = f"arn:aws:kms:{REGION}:{ACCOUNT}:key/11111111-2222-4333-8444-555555555555"
SUBNET_GROUP = f"{NAME}-subnet-group"
SUBNETS = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0aaaaaaaaaaaaaaa2", "subnet-0aaaaaaaaaaaaaaa3"]
VPC = "vpc-0aaaaaaaaaaaaaaa0"
ENGINE_VERSION = "16.4"

# The promises: 1.x address -> 2.x address, per layout. Instance keys follow.
MOVES = {
    "aws_rds_cluster.main": "aws_rds_cluster.this[0]",
    'aws_rds_cluster_instance.instances["writer"]': 'aws_rds_cluster_instance.this["writer"]',
    'aws_rds_cluster_instance.instances["reader"]': 'aws_rds_cluster_instance.this["reader"]',
    "aws_security_group.aurora[0]": "aws_security_group.this[0]",
    'aws_cloudwatch_log_group.aurora_logs["postgresql"]': 'aws_cloudwatch_log_group.this["postgresql"]',
    "aws_rds_cluster_parameter_group.main[0]": "aws_rds_cluster_parameter_group.this[0]",
    "aws_db_parameter_group.main[0]": "aws_db_parameter_group.this[0]",
    "aws_iam_role.enhanced_monitoring[0]": "aws_iam_role.monitoring[0]",
    'aws_rds_cluster_endpoint.custom["analytics"]': 'aws_rds_cluster_endpoint.this["analytics"]',
}
SUBNET_MOVES = {
    "early": ("aws_db_subnet_group.main", "aws_db_subnet_group.this[0]"),
    "late": ("aws_db_subnet_group.main[0]", "aws_db_subnet_group.this[0]"),
}
# Never deleted or replaced by the upgrade.
KEEP = {"aws_rds_cluster", "aws_rds_cluster_instance", "aws_rds_global_cluster", "aws_db_subnet_group", "aws_cloudwatch_log_group"}

ROOT_TF = """
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "%(provider)s" }
  }
}

provider "aws" {
  region                      = "%(region)s"
  access_key                  = "rehearsal"
  secret_key                  = "rehearsal"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  endpoints {
    sts = "%(sts)s"
  }
}

module "db" {
  source = "%(module)s"

  name           = "%(name)s"
  engine         = "aurora-postgresql"
  engine_version = "%(engine_version)s"
  kms_key_arn    = "%(kms)s"

  instance_class = "db.r6g.large"
  instances = {
    writer = { availability_zone = "eu-west-2a", promotion_tier = 0 }
    reader = { availability_zone = "eu-west-2b", promotion_tier = 1 }
  }

  database_name   = "orders"
  master_username = "admin"

  vpc_id                 = "%(vpc)s"
  subnet_ids             = %(subnets)s
  create_db_subnet_group = true
  db_subnet_group_name   = "%(subnet_group)s"
  ingress_rules = {
    app = { referenced_security_group_id = "sg-0bbbbbbbbbbbbbbb0", description = "application" }
  }

  custom_endpoints = {
    analytics = { type = "READER", static_members = ["reader"] }
  }

  enabled_cloudwatch_logs_exports = ["postgresql"]

  # 1.x had it off; turned on in a later change (docs/UPGRADE-2.0.md section 2).
  performance_insights_enabled = false

  create_alarms              = false
  create_event_subscriptions = false
}
"""


def inst(attrs: dict, key=None, schema_version=0, deps=None) -> dict:
    i = {"schema_version": schema_version, "attributes": attrs, "sensitive_attributes": []}
    if key is not None:
        i["index_key"] = key
    if deps:
        i["dependencies"] = deps
    return i


def res(rtype: str, name: str, instances: list, schema_version_by_type: dict) -> dict:
    for i in instances:
        i["schema_version"] = schema_version_by_type.get(rtype, 0)
    return {"module": "module.db", "mode": "managed", "type": rtype, "name": name,
            "provider": 'provider["registry.terraform.io/hashicorp/aws"]', "instances": instances}


def old_state(layout: str, versions: dict) -> dict:
    """A 1.x deployment as its apply left it, at the 1.x addresses."""
    cluster_arn = f"arn:aws:rds:{REGION}:{ACCOUNT}:cluster:{NAME}"
    sg = "sg-0ccccccccccccccc0"
    cluster = {
        "id": NAME, "cluster_identifier": NAME, "arn": cluster_arn, "cluster_resource_id": "cluster-REHEARSAL",
        "engine": "aurora-postgresql", "engine_mode": "provisioned", "engine_version": ENGINE_VERSION,
        "engine_version_actual": ENGINE_VERSION, "database_name": "orders", "master_username": "admin",
        "db_subnet_group_name": SUBNET_GROUP, "port": 5432, "storage_encrypted": True, "kms_key_id": KMS,
        "availability_zones": ["eu-west-2a", "eu-west-2b", "eu-west-2c"], "vpc_security_group_ids": [sg],
        "db_cluster_parameter_group_name": f"{NAME}-cpg-20250101", "deletion_protection": True,
        "skip_final_snapshot": False, "final_snapshot_identifier": f"{NAME}-final-snapshot",
        "backup_retention_period": 7, "manage_master_user_password": True, "network_type": "IPV4",
        "enabled_cloudwatch_logs_exports": ["postgresql"], "storage_type": "aurora",
        "engine_lifecycle_support": "open-source-rds-extended-support", "tags": {}, "tags_all": {},
        # 1.x defaulted Performance Insights off; the provider stores "" then.
        "performance_insights_enabled": False, "performance_insights_kms_key_id": "",
        "iam_database_authentication_enabled": False, "copy_tags_to_snapshot": False,
    }
    members = {}
    for key, az, tier in (("writer", "eu-west-2a", 0), ("reader", "eu-west-2b", 1)):
        members[key] = {
            "id": f"{NAME}-{key}", "identifier": f"{NAME}-{key}", "cluster_identifier": NAME,
            "arn": f"arn:aws:rds:{REGION}:{ACCOUNT}:db:{NAME}-{key}", "engine": "aurora-postgresql",
            "engine_version": ENGINE_VERSION, "instance_class": "db.r6g.large", "availability_zone": az,
            "db_subnet_group_name": SUBNET_GROUP, "publicly_accessible": False, "promotion_tier": tier,
            "db_parameter_group_name": f"{NAME}-pg-20250101", "auto_minor_version_upgrade": True,
            "ca_cert_identifier": "rds-ca-rsa2048-g1", "tags": {}, "tags_all": {},
            "writer": key == "writer", "performance_insights_enabled": False,
            "performance_insights_kms_key_id": "", "monitoring_interval": 0, "monitoring_role_arn": "",
        }
    subnet_group = {
        "id": SUBNET_GROUP, "name": SUBNET_GROUP, "arn": f"arn:aws:rds:{REGION}:{ACCOUNT}:subgrp:{SUBNET_GROUP}",
        "description": f"Subnet group for {NAME}", "subnet_ids": SUBNETS, "vpc_id": VPC,
        "supported_network_types": ["IPV4"], "tags": {}, "tags_all": {},
    }
    v = versions
    resources = [
        res("aws_rds_cluster", "main", [inst(cluster)], v),
        res("aws_rds_cluster_instance", "instances", [inst(members[k], key=k) for k in members], v),
        res("aws_db_subnet_group", "main", [inst(subnet_group, key=(None if layout == "early" else 0))], v),
        res("aws_security_group", "aurora", [inst({
            "id": sg, "arn": f"arn:aws:ec2:{REGION}:{ACCOUNT}:security-group/{sg}", "name": f"{NAME}-sg",
            "description": f"Security group for {NAME}", "vpc_id": VPC, "ingress": [], "egress": [],
            "revoke_rules_on_delete": False, "tags": {}, "tags_all": {}}, key=0)], v),
        res("aws_cloudwatch_log_group", "aurora_logs", [inst({
            "id": f"/aws/rds/cluster/{NAME}/postgresql", "name": f"/aws/rds/cluster/{NAME}/postgresql",
            "arn": f"arn:aws:logs:{REGION}:{ACCOUNT}:log-group:/aws/rds/cluster/{NAME}/postgresql",
            "retention_in_days": 7, "log_group_class": "STANDARD", "skip_destroy": False,
            "tags": {}, "tags_all": {}}, key="postgresql")], v),
        res("aws_rds_cluster_parameter_group", "main", [inst({
            "id": f"{NAME}-cpg-20250101", "name": f"{NAME}-cpg-20250101", "family": "aurora-postgresql16",
            "arn": f"arn:aws:rds:{REGION}:{ACCOUNT}:cluster-pg:{NAME}-cpg-20250101", "description": "1.x",
            "tags": {}, "tags_all": {}}, key=0)], v),
        res("aws_db_parameter_group", "main", [inst({
            "id": f"{NAME}-pg-20250101", "name": f"{NAME}-pg-20250101", "family": "aurora-postgresql16",
            "arn": f"arn:aws:rds:{REGION}:{ACCOUNT}:pg:{NAME}-pg-20250101", "description": "1.x",
            "tags": {}, "tags_all": {}}, key=0)], v),
        res("aws_iam_role", "enhanced_monitoring", [inst({
            "id": f"{NAME}-rds-monitoring-role", "name": f"{NAME}-rds-monitoring-role",
            "arn": f"arn:aws:iam::{ACCOUNT}:role/{NAME}-rds-monitoring-role",
            "assume_role_policy": json.dumps({"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Principal": {"Service": "monitoring.rds.amazonaws.com"}, "Action": "sts:AssumeRole"}]}),
            "path": "/", "max_session_duration": 3600, "force_detach_policies": False,
            "tags": {}, "tags_all": {}}, key=0)], v),
        res("aws_rds_cluster_endpoint", "custom", [inst({
            "id": f"{NAME}-analytics", "cluster_endpoint_identifier": f"{NAME}-analytics",
            "cluster_identifier": NAME, "custom_endpoint_type": "READER", "static_members": [f"{NAME}-reader"],
            "arn": f"arn:aws:rds:{REGION}:{ACCOUNT}:cluster-endpoint:{NAME}-analytics",
            "tags": {}, "tags_all": {}}, key="analytics")], v),
    ]
    return {"version": 4, "terraform_version": "1.7.5", "serial": 1, "lineage": "rehearsal-1x",
            "outputs": {}, "resources": resources, "check_results": None}


class FakeSTS(http.server.BaseHTTPRequestHandler):
    BODY = (f'<GetCallerIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/"><GetCallerIdentityResult>'
            f'<Arn>arn:aws:iam::{ACCOUNT}:user/rehearsal</Arn><UserId>AIDAREHEARSAL</UserId><Account>{ACCOUNT}</Account>'
            f'</GetCallerIdentityResult><ResponseMetadata><RequestId>rehearsal</RequestId></ResponseMetadata></GetCallerIdentityResponse>')

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(200)
        self.send_header("Content-Type", "text/xml")
        self.end_headers()
        self.wfile.write(self.BODY.encode())

    def log_message(self, *a):
        pass


def tf(args, cwd):
    return subprocess.run(["terraform", *args], cwd=cwd, capture_output=True, text=True)


def schema_versions(cwd) -> dict:
    p = tf(["providers", "schema", "-json"], cwd)
    s = json.loads(p.stdout)["provider_schemas"]["registry.terraform.io/hashicorp/aws"]["resource_schemas"]
    return {k: v.get("version", 0) for k, v in s.items()}


def rehearse(layout: str, root: str, sts: str, provider: str) -> list[str]:
    os.makedirs(root, exist_ok=True)
    with open(os.path.join(root, "main.tf"), "w") as f:
        f.write(ROOT_TF % {"provider": provider, "region": REGION, "sts": sts, "module": MODULE, "name": NAME,
                           "engine_version": ENGINE_VERSION, "kms": KMS, "vpc": VPC, "subnets": json.dumps(SUBNETS),
                           "subnet_group": SUBNET_GROUP})
    p = tf(["init", "-input=false", "-no-color"], root)
    if p.returncode != 0:
        return [f"terraform init failed:\n{p.stdout}{p.stderr}"]
    with open(os.path.join(root, "terraform.tfstate"), "w") as f:
        json.dump(old_state(layout, schema_versions(root)), f)
    p = tf(["plan", "-input=false", "-no-color", "-refresh=false", "-out=plan.tfplan"], root)
    if p.returncode != 0:
        out = p.stdout + p.stderr
        return [f"terraform plan failed:\n{out[out.find('Error:'):][:4000] if 'Error:' in out else out[-4000:]}"]
    plan = json.loads(tf(["show", "-json", "plan.tfplan"], root).stdout)
    with open(os.path.join(root, "plan.json"), "w") as f:
        json.dump(plan, f)

    failures = []
    moved = {rc.get("previous_address"): rc["address"] for rc in plan.get("resource_changes", []) if rc.get("previous_address")}
    expected = {f"module.db.{a}": f"module.db.{b}" for a, b in MOVES.items()}
    sa, sb = SUBNET_MOVES[layout]
    expected[f"module.db.{sa}"] = f"module.db.{sb}"
    for old, new in sorted(expected.items()):
        if moved.get(old) != new:
            failures.append(f"{old} did not move to {new} (moved to: {moved.get(old)})")
    for rc in plan.get("resource_changes", []):
        actions = rc["change"]["actions"]
        if rc["type"] in KEEP and "delete" in actions:
            what = "replaced" if "create" in actions else "deleted"
            failures.append(f"{rc['address']} would be {what}")
    gate = subprocess.run([sys.executable, os.path.join(MODULE, "tests", "check_plan.py"), os.path.join(root, "plan.json")],
                          capture_output=True, text=True)
    if gate.returncode != 0:
        failures.append(f"check_plan.py failed:\n{gate.stdout}{gate.stderr}")
    return failures


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--keep", metavar="DIR", help="write the rehearsal roots here and keep them")
    ap.add_argument("--provider", default=">= 5.90.0, < 7.0.0", help="AWS provider constraint to rehearse with")
    a = ap.parse_args()

    server = http.server.HTTPServer(("127.0.0.1", 0), FakeSTS)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    sts = f"http://127.0.0.1:{server.server_address[1]}"

    base = a.keep or tempfile.mkdtemp(prefix="aurora-moved-")
    failed = False
    try:
        for layout in ("early", "late"):
            failures = rehearse(layout, os.path.join(base, layout), sts, a.provider)
            if failures:
                failed = True
                print(f"FAIL  {layout} 1.x layout")
                for f in failures:
                    print(f"      - {f}")
            else:
                print(f"ok    {layout} 1.x layout: every object moved; nothing that holds data or placement is replaced")
    finally:
        server.shutdown()
        if not a.keep:
            shutil.rmtree(base, ignore_errors=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
