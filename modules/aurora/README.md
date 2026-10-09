# terraform-aws-aurora

Terraform module for Amazon Aurora PostgreSQL and Aurora MySQL clusters in
private, regulated environments. It manages the cluster, its instances and every
supporting resource (subnet group, security groups, parameter groups, IAM roles,
log groups, alarms, event subscriptions, RDS Proxy, autoscaling, global
database membership). Each supporting resource can be created by the module or
supplied by the caller. Unsafe configurations are refused at plan time,
risky-but-valid postures are reported by `check` blocks, and the integration
points the module cannot own (KMS key policies, SNS topic policies, VPC
endpoints) are emitted as structured outputs for their owners.

[Costs](https://github.com/ivasik-k7/terraform-shared-modules/blob/aurora-v2.0.0/modules/aurora/COSTS.md) ·
[Changelog](https://github.com/ivasik-k7/terraform-shared-modules/blob/aurora-v2.0.0/modules/aurora/CHANGELOG.md) ·
[Examples](#examples) ·
[Issues](https://github.com/ivasik-k7/terraform-shared-modules/issues)

## Contents

1. [Quick start](#quick-start)
2. [Requirements and compatibility](#requirements-and-compatibility)
3. [Architecture](#architecture)
4. [Resource inventory](#resource-inventory)
5. [Design and mechanics](#design-and-mechanics)
6. [Validation model](#validation-model)
7. [Configuration recipes](#configuration-recipes)
8. [Inputs](#inputs)
9. [Outputs](#outputs)
10. [Operations](#operations)
11. [Limitations](#limitations)
12. [Versioning, testing and support](#versioning-testing-and-support)

---

## Quick start

```hcl
module "orders_db" {
  source  = "app.terraform.io/citadel-hub/aurora/aws"
  version = "~> 2.0"

  name           = "orders"
  engine         = "aurora-postgresql"
  engine_version = "17.9"
  instance_class = "db.r7g.large"
  instances = {
    a = { promotion_tier = 0 }
    b = { promotion_tier = 1 }
  }

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids
  ingress_rules = {
    app = { referenced_security_group_id = var.app_sg_id, description = "orders service" }
  }

  sns_topic_arn                   = var.alerts_topic_arn
  enabled_cloudwatch_logs_exports = ["postgresql"]
}
```

This plans 22 resources and raises no advisory check:

| Resource | Count | Configuration |
|---|---:|---|
| `aws_rds_cluster.this` | 1 | Encrypted (`aws/rds`), deletion protection, RDS-managed master secret, Performance Insights 7 days, backups 7 days |
| `aws_rds_cluster_instance.this` | 2 | `orders-a`, `orders-b`, Enhanced Monitoring at 60 s, not publicly accessible |
| `aws_db_subnet_group.this` | 1 | `orders`, from `subnet_ids` |
| `aws_security_group.this` + ingress rules | 1 + 1 | TCP 5432 from `ingress_rules` only, no egress |
| `aws_rds_cluster_parameter_group.this` | 1 | `orders-cluster-aurora-postgresql17`, `rds.force_ssl = 1` plus logging parameters |
| `aws_db_parameter_group.this` | 1 | `orders-instance-aurora-postgresql17` |
| `aws_iam_role.monitoring` + inline policy | 1 + 1 | `orders-<region>-monitor`, scoped to `RDSOSMetrics` |
| `aws_cloudwatch_log_group.this` | 1 | `/aws/rds/cluster/orders/postgresql`, 30 days |
| `aws_cloudwatch_metric_alarm.*` | 8 | Writer CPU, reader CPU, replica lag, transaction ID age, memory × 2, local storage × 2 |
| `aws_db_event_subscription.*` | 2 | Cluster and instance events to `sns_topic_arn` |
| `terraform_data.created_at` | 1 | Creation timestamp for the final snapshot name |

Clients connect with `module.orders_db.connection` (host, port, secret ARN,
TLS requirement). The password is read from Secrets Manager; it is never in
Terraform state.

---

## Requirements and compatibility

| Component | Supported | Tested in CI |
|---|---|---|
| Terraform | `>= 1.7.0` | 1.7.5 and the latest release |
| `hashicorp/aws` | `>= 5.90.0, < 7.0.0` | 5.100.0 and the latest 6.x |

How the module stays compatible with both ends of those ranges:

| Constraint | Consequence in the code |
|---|---|
| Terraform 1.7 validations can reference only their own variable | Every rule that compares two inputs is a `precondition` on `aws_rds_cluster.this`, evaluated at plan |
| Terraform < 1.12 evaluates both operands of `\|\|` and `&&` | Conditions use nested ternaries, `can()` and `try()`; `tests/lint_validations.py` enforces it in CI |
| Terraform 1.7 has no write-only or ephemeral arguments | A static password uses `master_password`, gated by `allow_plaintext_credentials` |
| `data.aws_region.name` is deprecated in v6; `region` does not exist in v5 | The region is parsed from `data.aws_region.current.endpoint` (`ec2.<region>.amazonaws.com`) |

A root module with wider constraints (for example `aws = ">= 5.0"`) needs no
change. A committed `.terraform.lock.hcl` that pins the provider below 5.90
needs one `terraform init -upgrade`.

---

## Architecture

```
                      ┌──────────── caller-owned ─────────────┐
                      │ VPC, subnets, VPC endpoints           │
                      │ KMS keys + key policies               │
                      │ SNS topic + topic policy              │
                      └───────────────────────────────────────┘
                                   ▲  network_contract,
                                   │  kms_key_policy_requirements,
                                   │  sns_topic_policy_requirement
 clients ──TLS──► [proxy SG] ──► RDS Proxy ──┐              (optional)
    │                             │ reads    │
    │                             ▼          │
    │                   Secrets Manager ◄────┼── RDS-managed master secret
    │                   (proxy.secret_arns)  │   (+ rotation schedule)
    │                                        ▼
    └──TLS──► [DB SG] ──► aws_rds_cluster.this ◄── cluster parameter group (TLS, logging)
                            │   storage: KMS (kms_key_arn)
                            │   global: aws_rds_global_cluster.this (primary) or join (secondary)
                            ├── aws_rds_cluster_instance.this["<key>"] ◄── instance parameter group
                            │      └── Enhanced Monitoring role ──► RDSOSMetrics
                            ├── aws_rds_cluster_endpoint.this["<key>"]
                            ├── Application Auto Scaling (reader replicas, outside state)
                            ├── role associations / activity stream ──► Kinesis
                            └── logs    ──► /aws/rds/cluster/<name>/<type>
                                metrics ──► CloudWatch alarms ──► SNS
                                events  ──► RDS event subscriptions ──► SNS
```

### File layout

| File | Responsibility |
|---|---|
| `main.tf` | Global cluster, `terraform_data.created_at`, `aws_rds_cluster.this` and all cross-input preconditions |
| `instances.tf` | Instances, custom endpoints, reader autoscaling target and policy |
| `network.tf` | Subnet group, database and proxy security groups and every rule |
| `parameter-groups.tf` | Cluster and instance parameter groups |
| `credentials.tf` | Rotation schedule of the RDS-managed master secret |
| `iam.tf` | Enhanced Monitoring and RDS Proxy roles with inline policies |
| `proxy.tf` | RDS Proxy, default target group, target, read-only endpoint |
| `integrations.tf` | IAM role associations (PostgreSQL) and Database Activity Streams |
| `observability.tf` | Log groups, event subscriptions, alarms |
| `checks.tf` | The 30 advisory `check` blocks |
| `locals.tf` | Derived values: family, port, KMS fallbacks, credential path, posture |
| `data.tf` | Partition, region and caller identity, count-gated on `create` |
| `moved.tf` | Address migrations, kept permanently |
| `outputs.tf` | Resource outputs and the contract outputs |

---

## Resource inventory

Every resource the module can create. `<name>` is `var.name`; `<family>` is the
parameter group family with dots replaced by hyphens (`aurora-postgresql17`,
`aurora-mysql8-0`).

| Address | Created when | Name |
|---|---|---|
| `aws_rds_cluster.this` | `create` | `<name>` |
| `aws_rds_cluster_instance.this[key]` | one per `instances` key | `<name>-<key>` |
| `aws_rds_global_cluster.this` | `global_cluster_role = "primary"` and `create_global_cluster` | `global_cluster_identifier` |
| `terraform_data.created_at` | `final_snapshot_identifier = ""` | — |
| `aws_db_subnet_group.this` | `create_db_subnet_group` | `db_subnet_group_name`, else `<name>` |
| `aws_security_group.this` | `create_security_group` | prefix `<name>-db-` |
| `aws_vpc_security_group_ingress_rule.this[key]` | one per `ingress_rules` key | tag `<name>-db-<key>` |
| `aws_vpc_security_group_egress_rule.this[key]` | one per `egress_rules` key | tag `<name>-db-<key>` |
| `aws_rds_cluster_parameter_group.this` | `create_cluster_parameter_group` | `<name>-cluster-<family>` |
| `aws_db_parameter_group.this` | `create_db_parameter_group` | `<name>-instance-<family>` |
| `aws_secretsmanager_secret_rotation.master` | managed secret and a `master_password_rotation` schedule | — |
| `aws_iam_role.monitoring`, `aws_iam_role_policy.monitoring` | `enhanced_monitoring_interval > 0` and `create_monitoring_role` | `<name>-<region>-monitor` |
| `aws_rds_cluster_endpoint.this[key]` | one per `custom_endpoints` key | `<name>-<key>` |
| `aws_appautoscaling_target.readers`, `aws_appautoscaling_policy.readers` | `reader_autoscaling.enabled` | `<name>-readers` |
| `aws_rds_cluster_role_association.this[key]` | aurora-postgresql, one per `cluster_iam_roles` key | — |
| `aws_rds_cluster_activity_stream.this` | `activity_stream.enabled` | — |
| `aws_db_proxy.this`, `aws_db_proxy_default_target_group.this`, `aws_db_proxy_target.this` | `proxy.enabled` | `<name>-proxy` |
| `aws_db_proxy_endpoint.reader` | `proxy.enabled` and `proxy.create_reader_endpoint` | `<name>-proxy-ro` |
| `aws_iam_role.proxy`, `aws_iam_role_policy.proxy` | `proxy.enabled` and `proxy.create_role` | `<name>-<region>-proxy` |
| `aws_security_group.proxy`, `aws_vpc_security_group_ingress_rule.proxy[key]`, `aws_vpc_security_group_egress_rule.proxy[key]` | `proxy.enabled` and `proxy.create_security_group` | prefix `<name>-proxy-` |
| `aws_vpc_security_group_egress_rule.proxy_to_cluster`, `aws_vpc_security_group_ingress_rule.from_proxy` | both security groups module-created | — |
| `aws_vpc_security_group_egress_rule.proxy_to_brought_groups[i]` | proxy group module-created, database groups brought | — |
| `aws_cloudwatch_log_group.this[type]` | `create_log_groups`, one per exported log type | `/aws/rds/cluster/<name>/<type>` |
| `aws_db_event_subscription.cluster`, `aws_db_event_subscription.instances` | `create_event_subscriptions` | `<name>-cluster`, `<name>-instances` |
| `aws_cloudwatch_metric_alarm.*` | `create_alarms`, see [Alarms](#alarms) | `<name>-…` |

Every taggable resource gets `merge(var.tags, { ManagedBy = "Terraform", Module
= "aurora", DatabaseCluster = <name> })` plus a `Name` tag. The module's keys
are merged last and cannot be overridden. Instances also merge
`instances[key].tags` before the module's keys.

---

## Design and mechanics

### Replacement safety

A replaced `aws_rds_cluster` is a new, empty database. The module limits what a
plan that replaces it can destroy:

- **Dependents reference the cluster by `cluster_identifier`, never by `id` or
  `arn`.** `cluster_identifier` is set from `var.name`, so it stays known while
  a replacement is planned. Instances, custom endpoints, the proxy target, role
  associations, autoscaling and event subscriptions keep known arguments and
  are not planned for replacement alongside the cluster.
- **`local.cluster_arn` is built from partition, region, account and name**
  rather than read from the resource, for the same reason. The activity stream
  uses it.
- **`deletion_protection = true` by default.** A plan that replaces the cluster
  fails at the cluster's delete, with every instance still serving.
- Inputs that force replacement are listed in
  [What replaces resources](#what-replaces-resources).

### Creation-time attributes

AWS fixes some attributes when the cluster is created. Sending them again later
forces a replacement or is refused by AWS, so the module sets them once and
ignores them afterwards. Where it matters, a `check` compares the running value
with the input.

| Resource | Ignored attribute | Reason | Difference reported by |
|---|---|---|---|
| `aws_rds_cluster` | `snapshot_identifier`, `restore_to_point_in_time` | The restore source only applies at create | — |
| | `master_username`, `database_name` | ForceNew; inherited from a snapshot, PITR source or primary | `connection` reports the actual values |
| | `engine_lifecycle_support` | No modify API | `extended_support_matches_the_setting` |
| | `master_user_secret_kms_key_id` | Fixed once RDS owns the secret | `master_secret_key_is_the_one_configured` |
| | `performance_insights_kms_key_id` | Fixed once Performance Insights is on | `performance_insights_key_is_the_one_configured` |
| | `replication_source_identifier`, `source_region` | Not managed by this module | — |
| `aws_rds_cluster_instance` | `performance_insights_kms_key_id` | As above | As above |
| `aws_rds_global_cluster` | `engine_version`, `engine_lifecycle_support` | The provider upgrades a global cluster with major upgrades always allowed | Upgrades go through `modify-global-cluster` |
| `aws_rds_cluster_activity_stream` | `kms_key_id` | The API returns an ARN or a key ID; the attribute is ForceNew | `activity_stream_key_is_the_one_configured` |
| `terraform_data.created_at` | `input` | Keeps the first `plantimestamp()` | — |

### Plan-time determinism

`count` and `for_each` depend only on booleans and on map keys the caller
writes (`create_*`, `*.enabled`, `instances`, `ingress_rules`, …), never on
whether an ARN or ID is empty. An ARN produced by a resource in the same
configuration is unknown at plan, so every bring-your-own input can come from
resources the caller creates in the same run.

### Instances and the writer

- `instances` is a map whose key is part of the identifier (`<name>-<key>`).
  Adding or removing a key creates or destroys only that instance.
- Per-instance overrides: `instance_class`, `availability_zone`,
  `promotion_tier`, `ca_cert_identifier`, `preferred_maintenance_window`,
  `tags`. Empty values fall back to the module-level input.
- `engine_version` is not set on instances; the cluster owns it.
- **AWS chooses the initial writer**: the first instance to become available.
  `promotion_tier` orders failover only. The intended writer is
  `local.failover_target`: the lowest `promotion_tier`, then the first key in
  lexical order. `verify_commands.move_the_writer` fails over to it.

### Credentials

`governance.credential_source` is derived as follows. The managed secret and a
static password are mutually exclusive, and a precondition refuses both or
neither.

| Condition | `credential_source` | Arguments sent on the cluster |
|---|---|---|
| `global_cluster_role = "secondary"` | `replicated from the global primary` | No user, password or database |
| `manage_master_user_password = true` | `rds-managed secret` | `manage_master_user_password = true`, `master_user_secret_kms_key_id` |
| `master_password` set | `plaintext in terraform state` | `master_password` (requires `allow_plaintext_credentials`) |
| `snapshot_identifier` set | `inherited from snapshot` | No user or database |
| `restore_to_point_in_time` set | `inherited from point-in-time source` | No user or database |

`aws_secretsmanager_secret_rotation.master` replaces RDS's default 7-day
rotation with `master_password_rotation.schedule_expression` or
`automatically_after_days`. `rotate_immediately` defaults to `false`, so setting
a schedule does not rotate the password during the apply.

### Encryption

Storage encryption is always on. Each purpose resolves its key as below; an
empty result means the AWS-managed key for that service.

| Purpose | Input | Fallback | Under `require_cmk`, an empty key is |
|---|---|---|---|
| Cluster storage | `kms_key_arn` | `aws/rds` | Refused |
| Master secret | `master_user_secret_kms_key_arn` | `kms_key_arn`, then `aws/secretsmanager` | Refused when the managed secret is on |
| Performance Insights | `performance_insights_kms_key_arn` | `kms_key_arn`, then `aws/rds` | Refused when enabled |
| Log groups | `cloudwatch_logs_kms_key_arn` | `kms_key_arn`, then the CloudWatch default | Refused when exporting; `create_log_groups = false` is always refused |
| Activity stream | `activity_stream.kms_key_arn` | `kms_key_arn` | Refused whenever the stream is on |
| Proxy secrets | `proxy.secret_kms_key_arn` | The master secret's key with `use_master_secret` | Not covered |

Every key and `sns_topic_arn` must be in the cluster's region; a precondition
matches `:<region>:` in each ARN. `kms_key_policy_requirements` lists, for each
key, the principal, actions and `kms:ViaService` condition its policy must
allow.

### Parameter groups and TLS

**Family.** `aurora-postgresql<major>` from `"17.9"`; `aurora-mysql<major.minor>`
from `"8.0.mysql_aurora.3.10.4"`. `parameter_group_family` overrides it, and
`parameter_group_family_matches_the_engine` warns on a mismatch.

**Merge order** of the cluster parameter group; later entries win:

1. `recommended_parameters` (on by default):
   - PostgreSQL: `log_min_duration_statement = 5000`, `log_lock_waits = 1`, `log_autovacuum_min_duration = 10000`
   - MySQL: `slow_query_log = 1`, `long_query_time = 5`, `log_output = FILE`, `innodb_print_all_deadlocks = 1`
2. `cluster_parameters` (default `apply_method = "pending-reboot"`)
3. With `enforce_tls`: `rds.force_ssl = 1` or `require_secure_transport = ON`, `immediate`

A `cluster_parameters` value for the TLS parameter other than `1`, `on` or
`true` is refused rather than silently overwritten. `effective_parameters`
outputs the merged result.

**Naming and major upgrades.** Groups are named after the family
(`<name>-cluster-<family>`) and use `create_before_destroy`. A major upgrade
changes the family, and therefore the name, so the new groups are created
beside the old ones. With `allow_major_version_upgrade = true` the cluster also
sends `db_instance_parameter_group_name` (the new instance group) on the
`ModifyDBCluster` call, which AWS requires for a major upgrade; the provider
omits it on other modifications.

### Network

The database security group has exactly the configured rules. Terraform
removes the default allow-all egress rule from groups it creates.

| Rule | Source → destination | Port | Created when |
|---|---|---|---|
| `ingress_rule.this[key]` | `ingress_rules` source → DB SG | `port` (5432/3306 by default) | DB SG module-created |
| `egress_rule.this[key]` | DB SG → `egress_rules` destination | `egress_rules[key].port`, TCP or UDP | DB SG module-created |
| `ingress_rule.proxy[key]` | `proxy.ingress_rules` source → proxy SG | engine default port | proxy SG module-created |
| `egress_rule.proxy[key]` | proxy SG → `proxy.egress_rules` destination (Secrets Manager on 443) | as configured | proxy SG module-created |
| `egress_rule.proxy_to_cluster` + `ingress_rule.from_proxy` | proxy SG ↔ DB SG | `port` | both module-created |
| `egress_rule.proxy_to_brought_groups[i]` | proxy SG → each `vpc_security_group_ids` | `port` | proxy SG module-created, DB SGs brought |

Rules are keyed by caller labels or list position, never by an ID, so IDs
unknown at plan are safe. With a brought group on either side, the missing half
is listed in `network_contract.rules_you_must_add`. `ingress_rules` and
`egress_rules` are refused when the module does not create the group they would
go into.

### IAM

**Enhanced Monitoring role** (`<name>-<region>-monitor`). The region is part of
the name because IAM is global and a global database often reuses the cluster
name in both regions.

```json
{
  "AssumeRole": { "Service": "monitoring.rds.amazonaws.com",
                  "Condition": { "StringEquals": { "aws:SourceAccount": "<account>" } } },
  "Policy": [
    { "Action": ["logs:CreateLogGroup", "logs:PutRetentionPolicy"],
      "Resource": ["arn:<partition>:logs:<region>:<account>:log-group:RDSOSMetrics",
                   "arn:<partition>:logs:<region>:<account>:log-group:RDSOSMetrics:*"] },
    { "Action": ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams", "logs:GetLogEvents"],
      "Resource": ["arn:<partition>:logs:<region>:<account>:log-group:RDSOSMetrics:log-stream:*"] }
  ]
}
```

**RDS Proxy role** (`<name>-<region>-proxy`):

```json
{
  "AssumeRole": { "Service": "rds.amazonaws.com" },
  "Policy": [
    { "Action": ["secretsmanager:GetSecretValue"], "Resource": ["<each proxy secret ARN>"] },
    { "Action": ["kms:Decrypt"], "Resource": ["<proxy secret key>"],
      "Condition": { "StringEquals": { "kms:ViaService": "secretsmanager.<region>.amazonaws.com" } } }
  ]
}
```

The `kms:Decrypt` statement exists only when a proxy secret key is known
(`proxy.secret_kms_key_arn`, or the master secret's key). Both roles take
`permissions_boundary_arn` and `iam_role_path`.

### Global database

| Role | Behaviour |
|---|---|
| `primary` | Creates `aws_rds_global_cluster.this`, or joins `global_cluster_identifier` with `create_global_cluster = false`. Needs a static password, because AWS does not support the managed secret on global members |
| `secondary` | Joins `global_cluster_identifier` with no user, password or database name. Needs its own `kms_key_arn` in its region. Supports `enable_global_write_forwarding`, and can be headless (`instances = {}`) |

**Ordering.** `output.global_cluster_identifier` has `depends_on` on the primary
cluster **and its instances**. A secondary that reads it from the primary's
module call is created only once the primary can accept replication, and on
destroy the two are not torn down concurrently.

The major version of a global database is changed on the global cluster with
`modify-global-cluster`; members refuse `allow_major_version_upgrade`.

### Final snapshot naming

A fixed `<name>-final` collides the second time a cluster with the same name is
deleted. With `final_snapshot_identifier = ""` the name is
`<name>-final-<YYYYMMDDhhmm>`. The timestamp is `plantimestamp()`, captured once
in `terraform_data.created_at` (`ignore_changes = [input]`). That resource's
`triggers_replace` are the inputs that replace the cluster, so a new cluster
gets a new timestamp.

### Serverless v2

`serverlessv2_scaling_configuration` is sent only when at least one instance is
`db.serverless`. `min_capacity = 0` enables auto-pause after
`seconds_until_auto_pause` (300 to 86400). Auto-pause needs aurora-postgresql
13.15, 14.12, 15.7 or 16.3 and later (every 17.x), or aurora-mysql 3.08 and
later; `auto_pause_has_an_engine_that_supports_it` checks exact versions. When
the cluster can pause, the writer CPU alarm treats missing data as not
breaching.

### RDS Proxy

- Engine family `POSTGRESQL` or `MYSQL`. The proxy listens on the engine's
  default port, whatever `port` is.
- One `auth` block per secret: `proxy.secret_arns`, or the RDS-managed master
  secret with `proxy.use_master_secret = true`. Without either the plan is
  refused, because every client would act as the master user.
- `require_tls = true` and `iam_auth = "DISABLED"` by default. Connection pool
  settings go on the default target group; `debug_logging` is off.
- The target is the cluster, by identifier, after the instances exist. An
  optional `READ_ONLY` endpoint is named `<name>-proxy-ro`.

### Observability

**Log groups** are created before the cluster (`depends_on`), so retention,
class and key apply before RDS first writes. Otherwise RDS creates
`/aws/rds/cluster/<name>/<type>` itself, with no expiry and the default key.

**Performance Insights** is set explicitly on the cluster and on every instance
from one input. The provider treats an unset cluster value as `false`, not as
"whatever AWS reports". `database_insights_mode = "advanced"` needs a retention
of exactly 465 days.

#### Alarms

Created with `create_alarms` (default on); every action goes to `sns_topic_arn`.

| Alarm | Metric | Dimensions | Statistic, period × evaluations | Fires when (default) | Missing data | Created when |
|---|---|---|---|---|---|---|
| `<name>-writer-cpu` | `CPUUtilization` | `DBClusterIdentifier`, `Role=WRITER` | Average, 300 s × 3 | > `alarm_cpu_percent` (80) | Breaching; not breaching if the cluster can pause | Not a secondary |
| `<name>-reader-cpu` | `CPUUtilization` | `DBClusterIdentifier`, `Role=READER` | Average, 300 s × 3 | > `alarm_cpu_percent` | Not breaching; on a secondary, as writer CPU | Readers exist, or a secondary |
| `<name>-<key>-freeable-memory` | `FreeableMemory` | `DBInstanceIdentifier` | Minimum, 300 s × 2 | < `alarm_freeable_memory_bytes` (256 MiB) | Not breaching | Per instance |
| `<name>-<key>-free-local-storage` | `FreeLocalStorage` | `DBInstanceIdentifier` | Minimum, 300 s × 2 | < `alarm_free_local_storage_bytes` (2 GiB) | Not breaching | Per provisioned instance |
| `<name>-replica-lag` | `AuroraReplicaLagMaximum` | `DBClusterIdentifier`, `Role=WRITER` | Maximum, 60 s × 5 | > `alarm_replica_lag_ms` (2000) | Not breaching | Readers exist, not a secondary |
| `<name>-<key>-acu-utilization` | `ACUUtilization` | `DBInstanceIdentifier` | Average, 300 s × 3 | > `alarm_acu_utilization_percent` (90) | Not breaching | Per `db.serverless` instance |
| `<name>-writer-connections` | `DatabaseConnections` | `DBClusterIdentifier`, `Role=WRITER` | Maximum, 300 s × 2 | > `alarm_connections` | Not breaching | `alarm_connections > 0` |
| `<name>-transaction-id-age` | `MaximumUsedTransactionIDs` | `DBClusterIdentifier`, `Role=WRITER` | Maximum, 300 s × 1 | > `alarm_transaction_ids` (1e9) | Not breaching | aurora-postgresql, not a secondary |
| `<name>-volume-size` | `VolumeBytesUsed` | `DBClusterIdentifier` | Maximum, 3600 s × 1 | > `alarm_volume_bytes` | Not breaching | `alarm_volume_bytes > 0` |
| `<name>-global-rpo-lag` | `AuroraGlobalDBRPOLag` | Metrics Insights: `SELECT MAX(AuroraGlobalDBRPOLag) FROM "AWS/RDS" WHERE DBClusterIdentifier = '<name>'` | 60 s × 5 | > `alarm_global_rpo_lag_ms` (10000) | Breaching; missing when headless | A secondary |

Writer CPU, reader CPU on a secondary, and RPO lag also send OK actions. The RPO
alarm uses a Metrics Insights query so that it matches the series whether or
not AWS publishes it with an extra `SourceRegion` dimension.

**Event subscriptions**: `<name>-cluster` (`source_type = db-cluster`,
`cluster_event_categories`) and `<name>-instances` (`db-instance`, the
identifiers in `instances`, `instance_event_categories`).

---

## Validation model

Three layers, all evaluated during `terraform plan`:

| Layer | Count | Scope | Effect | Error shown as |
|---|---:|---|---|---|
| Variable `validation` | 114 | One variable | Plan fails | `Invalid value for variable` |
| Resource `precondition` | 43 | Any combination of inputs | Plan fails before any resource is created | `Resource precondition failed` on `aws_rds_cluster.this[0]` (two are on child resources) |
| `check` block | 30 | Inputs and planned or known state | Warning; the plan continues | `Check block assertion failed` |

Forty-three preconditions and 114 validations refuse configurations that would
fail at apply after partial creation, or that are unsafe without an explicit
acknowledgement:

| Refused | Reason |
|---|---|
| Both or neither of the managed secret and `master_password` | AWS rejects the create after the network and parameter groups exist |
| `master_password` without `allow_plaintext_credentials` | Stored in state in plaintext |
| The managed secret on a global member | Not supported by AWS |
| `enforce_tls = false` without `allow_insecure_transport`; a TLS-disabling value in `cluster_parameters` | Cleartext credentials; a contradicting value would be overwritten |
| `publicly_accessible` without `allow_public_access` | Public addresses on every instance |
| `create_security_group = false` with no `vpc_security_group_ids` | RDS would attach the VPC's default group |
| `ingress_rules` or `egress_rules` without the module's group; the same for the proxy | The rules would be dropped |
| `0.0.0.0/0` or `::/0` ingress; all-traffic egress | — |
| More than 5 security groups on the cluster | RDS limit |
| A KMS key or SNS topic ARN in another region | Fails at apply after other resources exist |
| `require_cmk` with any purpose on an AWS-managed key | The message lists the purposes |
| Alarms or event subscriptions without `sns_topic_arn` | Notifications would go nowhere |
| Empty `instances` (except on a secondary); fewer than two subnets for a created subnet group | No compute; RDS needs two AZs |
| An `engine_version` of the other engine; log types the engine does not publish; `cluster_iam_roles` feature names on the wrong engine | API errors at apply |
| More than one data source (snapshot, PITR, secondary) | — |
| A secondary without its own key, or with a database name or password; a primary created from a restore | Unsupported topologies |
| `allow_major_version_upgrade`, backtrack or reader autoscaling on global members; write forwarding outside a secondary | Not supported by AWS |
| Advanced Database Insights without Performance Insights at 465 days | API constraint |
| An activity stream on `db.serverless` or `db.t*`, or without a customer-managed key | API constraint |
| A proxy with fewer than two subnets, without `vpc_id` for its group, or logging in as the master user without `use_master_secret` | — |
| Custom endpoint members that are not `instances` keys | — |
| A `name` longer than 41 characters; reserved master usernames; Aurora MySQL 2 | Identifier length; RDS restrictions |

### Advisory checks

Thirty `check` blocks warn without blocking the plan. In HCP Terraform, health
assessments re-evaluate them, so a cluster that drifts into a warned state is
reported without a new run. Adding a check's name to `acknowledged_checks`
silences it and records the decision in `governance.acknowledged_checks`. Every
check is silent when `create = false`.

| Check | Warns when |
|---|---|
| `cluster_survives_an_az` | No reader to fail over to (not on a global secondary) |
| `instances_are_spread_across_azs` | Every instance pinned to the same AZ |
| `somebody_hears_a_failover` | `create_alarms` and `create_event_subscriptions` both false |
| `deleting_the_cluster_is_protected` | `deletion_protection = false` |
| `deleting_the_cluster_leaves_a_snapshot` | `skip_final_snapshot = true` |
| `backups_cover_a_week` | `backup_retention_days` below 7 |
| `query_level_metrics_exist` | Performance Insights off |
| `database_logs_leave_the_instance` | `enabled_cloudwatch_logs_exports` empty |
| `log_retention_is_bounded` | Module-created log groups that never expire |
| `tls_is_enforced_where_the_module_can_see` | `enforce_tls` with a brought cluster parameter group |
| `the_module_controls_who_connects` | `create_security_group = false` |
| `ingress_stays_inside_private_address_space` | Ingress outside RFC 1918, 100.64.0.0/10 and IPv6 unique-local |
| `something_can_connect` | The module's group has no ingress, no other group and no proxy |
| `credentials_are_not_in_state` | A plaintext `master_password` |
| `engine_version_is_exact` | A major-only `engine_version` |
| `minor_upgrades_do_not_fight_the_pin` | An exact version with `auto_minor_version_upgrade = true` |
| `extended_support_matches_the_setting` | The running cluster's Extended Support setting differs from `engine_lifecycle_support` |
| `extended_support_is_a_decision` | `engine_lifecycle_support` enables Extended Support |
| `auto_pause_has_an_engine_that_supports_it` | `min_capacity = 0` on a minor too old to pause |
| `the_proxy_has_clients` | Module-created proxy group with no `proxy.ingress_rules` |
| `the_proxy_can_reach_secrets_manager` | Module-created proxy group with no egress on 443 |
| `the_proxy_can_decrypt_its_secrets` | Module-created proxy role, own `proxy.secret_arns` and no `proxy.secret_kms_key_arn` |
| `master_secret_key_is_the_one_configured` | The master secret's key differs from the one configured |
| `performance_insights_key_is_the_one_configured` | The Performance Insights key differs from the one configured |
| `activity_stream_key_is_the_one_configured` | The activity stream runs with another key than the one configured |
| `database_insights_advanced_on_a_global_member` | Advanced Database Insights on a global member at create |
| `major_upgrade_applies_immediately` | `allow_major_version_upgrade` with `apply_immediately = false` |
| `reader_autoscaling_has_a_reader` | Autoscaling that can never act: one instance and `min_capacity = 0` |
| `mysql_log_exports_have_their_switches` | `audit` or `general` exported with the engine switch off |
| `parameter_group_family_matches_the_engine` | `parameter_group_family` names another engine or major |

---

## Configuration recipes

Each fragment goes inside the [quick start](#quick-start) module block.

**Customer-managed keys for every purpose**

```hcl
  kms_key_arn        = var.db_kms_key_arn # storage, and the fallback for every purpose
  require_cmk        = true
  log_retention_days = 90
```

**Serverless v2 that scales to zero**

```hcl
  instance_class      = "db.serverless"
  instances           = { a = {} }
  acknowledged_checks = ["cluster_survives_an_az"]
  serverlessv2_scaling_configuration = {
    min_capacity             = 0
    max_capacity             = 4
    seconds_until_auto_pause = 1800
  }
```

**RDS Proxy with application users**

```hcl
  proxy = {
    enabled            = true
    secret_arns        = [var.app_user_secret_arn]
    secret_kms_key_arn = var.app_secret_kms_key_arn
    ingress_rules = {
      app = { referenced_security_group_id = var.app_sg_id, description = "orders service" }
    }
    egress_rules = {
      secrets = { prefix_list_id = var.secretsmanager_endpoint_pl, port = 443, description = "Secrets Manager endpoint" }
    }
  }
```

**Global database**

```hcl
module "primary" {
  # quick-start inputs, in the primary region
  global_cluster_role         = "primary"
  global_cluster_identifier   = "orders-global"
  manage_master_user_password = false
  master_password             = var.db_password # from a sensitive workspace variable
  allow_plaintext_credentials = true
  acknowledged_checks         = ["credentials_are_not_in_state"]
}

module "secondary" {
  providers = { aws = aws.dr }
  # quick-start inputs, with the secondary region's network
  global_cluster_role         = "secondary"
  global_cluster_identifier   = module.primary.global_cluster_identifier
  manage_master_user_password = false
  kms_key_arn                 = var.dr_kms_key_arn
}
```

**Bring your own network and parameter groups**

```hcl
  create_db_subnet_group         = false
  db_subnet_group_name           = "corp-db"
  create_security_group          = false
  vpc_security_group_ids         = [var.db_sg_id]
  ingress_rules                  = {}
  create_cluster_parameter_group = false
  cluster_parameter_group_name   = "corp-aurora-postgresql17"
  acknowledged_checks            = ["the_module_controls_who_connects", "tls_is_enforced_where_the_module_can_see"]
```

### Examples

| Example | Shows |
|---|---|
| [isolated-vpc-postgresql](https://github.com/ivasik-k7/terraform-shared-modules/tree/aurora-v2.0.0/modules/aurora/examples/isolated-vpc-postgresql) | Two AZs, one CMK with `require_cmk`, IAM authentication, alarms, contract outputs |
| [proxy-and-readers](https://github.com/ivasik-k7/terraform-shared-modules/tree/aurora-v2.0.0/modules/aurora/examples/proxy-and-readers) | Aurora MySQL, a reporting reader behind a custom endpoint, reader autoscaling, RDS Proxy |
| [global-database](https://github.com/ivasik-k7/terraform-shared-modules/tree/aurora-v2.0.0/modules/aurora/examples/global-database) | A primary in eu-west-2 and a secondary in eu-west-1 with its own key |
| [serverless-v2-dev](https://github.com/ivasik-k7/terraform-shared-modules/tree/aurora-v2.0.0/modules/aurora/examples/serverless-v2-dev) | One pausing `db.serverless` instance with its checks acknowledged |

---

## Inputs

### Module

| Name | Type | Default | Description |
|---|---|---|---|
| `create` | `bool` | `true` | Master switch. `false` plans nothing; on a live deployment that is a destroy |
| `name` | `string` | required | Cluster identifier and the prefix of every name; 1–41 characters |
| `tags` | `map(string)` | `{}` | Tags for every resource |
| `required_tag_keys` | `list(string)` | `[]` | Keys that must be present and non-empty in `tags` |
| `acknowledged_checks` | `list(string)` | `[]` | Advisory checks accepted on purpose |

### Engine

| Name | Type | Default | Description |
|---|---|---|---|
| `engine` | `string` | required | `aurora-postgresql` or `aurora-mysql` |
| `engine_version` | `string` | required | Exact version, such as `"17.9"` or `"8.0.mysql_aurora.3.10.4"` |
| `parameter_group_family` | `string` | `""` | Overrides the derived family |
| `auto_minor_version_upgrade` | `bool` | `false` | Let AWS apply minor versions |
| `allow_major_version_upgrade` | `bool` | `false` | Permit a major version change |
| `engine_lifecycle_support` | `string` | `"open-source-rds-extended-support-disabled"` | Extended Support at end of standard support; creation-time only |

### Instances

| Name | Type | Default | Description |
|---|---|---|---|
| `instance_class` | `string` | required | Default class; `db.serverless` for Serverless v2 |
| `instances` | `map(object)` | required | Instances keyed by a stable name (schema below) |
| `serverlessv2_scaling_configuration` | `object` | `{ min_capacity = 0.5, max_capacity = 4, seconds_until_auto_pause = 3600 }` | ACU range for `db.serverless` instances |
| `ca_cert_identifier` | `string` | `"rds-ca-rsa2048-g1"` | Server CA, overridable per instance |
| `publicly_accessible` | `bool` | `false` | Public addresses; needs `allow_public_access` |
| `allow_public_access` | `bool` | `false` | Acknowledges `publicly_accessible` |
| `apply_immediately` | `bool` | `false` | Apply modifications now instead of in the maintenance window |

```hcl
instances = map(object({
  instance_class               = optional(string, "")  # "" = var.instance_class
  availability_zone            = optional(string, "")  # "" = AWS places it; changing it replaces the instance
  promotion_tier               = optional(number, 1)   # 0-15, failover order
  ca_cert_identifier           = optional(string, "")
  preferred_maintenance_window = optional(string, "")
  tags                         = optional(map(string), {})
}))  # keys match ^[a-z0-9][a-z0-9-]{0,19}$
```

### Storage and encryption

| Name | Type | Default | Description |
|---|---|---|---|
| `storage_type` | `string` | `"aurora"` | `aurora` (billed per I/O) or `aurora-iopt1` (I/O-Optimized) |
| `kms_key_arn` | `string` | `""` | Storage key and the fallback for every purpose; changing it replaces the cluster |
| `require_cmk` | `bool` | `false` | Refuse any purpose on an AWS-managed key |

### Credentials

| Name | Type | Default | Description |
|---|---|---|---|
| `database_name` | `string` | `""` | Initial database; creation-time only |
| `master_username` | `string` | `"dbadmin"` | Master user; creation-time only |
| `manage_master_user_password` | `bool` | `true` | RDS-managed secret in Secrets Manager |
| `master_user_secret_kms_key_arn` | `string` | `""` | Key for the managed secret |
| `master_password_rotation` | `object` | `{}` | Rotation schedule (schema below) |
| `master_password` | `string`, sensitive | `""` | Static password: 8–128 characters, none of `/`, `@`, `"` or space |
| `allow_plaintext_credentials` | `bool` | `false` | Acknowledges a static password in state |
| `iam_database_authentication_enabled` | `bool` | `false` | IAM token authentication |

```hcl
master_password_rotation = object({
  schedule_expression      = optional(string, "")  # "rate(N days)" or "cron(...)"
  automatically_after_days = optional(number, 0)   # 1-1000; exclusive with schedule_expression
  duration                 = optional(string, "")  # rotation window, "1h" to "24h"
  rotate_immediately       = optional(bool, false)
})
```

### Restore

| Name | Type | Default | Description |
|---|---|---|---|
| `snapshot_identifier` | `string` | `""` | Cluster snapshot name or ARN, including `rds:` and `awsbackup:` names |
| `restore_to_point_in_time` | `object` | `{}` | Point-in-time copy of another cluster (schema below) |

```hcl
restore_to_point_in_time = object({
  source_cluster_identifier  = optional(string, "")   # set either this...
  source_cluster_resource_id = optional(string, "")   # ...or this (cluster-XXXX), for a deleted source
  restore_to_time            = optional(string, "")   # RFC 3339 UTC; exclusive with the next
  use_latest_restorable_time = optional(bool, false)
  restore_type               = optional(string, "full-copy")  # or copy-on-write
})
```

### Global database

| Name | Type | Default | Description |
|---|---|---|---|
| `global_cluster_role` | `string` | `"none"` | `none`, `primary` or `secondary` |
| `global_cluster_identifier` | `string` | `""` | Global cluster to create or join |
| `create_global_cluster` | `bool` | `true` | On a primary, create the global cluster |
| `enable_global_write_forwarding` | `bool` | `false` | On a secondary, forward writes to the primary |

### Network

| Name | Type | Default | Description |
|---|---|---|---|
| `create_db_subnet_group` | `bool` | `true` | Create the subnet group from `subnet_ids` |
| `db_subnet_group_name` | `string` | `""` | Name of the created group, or the existing group |
| `subnet_ids` | `list(string)` | `[]` | Subnets in at least two AZs; also the proxy's default |
| `vpc_id` | `string` | `""` | VPC for the module-created security groups |
| `create_security_group` | `bool` | `true` | Create the database security group |
| `vpc_security_group_ids` | `list(string)` | `[]` | Existing groups to attach; at most 5 groups in total |
| `ingress_rules` | `map(object)` | `{}` | Ingress on the database port, keyed by label |
| `egress_rules` | `map(object)` | `{}` | Egress from the database group |
| `port` | `number` | `0` | Database port; `0` means the engine default |
| `network_type` | `string` | `"IPV4"` | `IPV4` or `DUAL` |

```hcl
ingress_rules = map(object({
  description                  = string
  cidr_ipv4                    = optional(string, "")  # exactly one source; /0 is refused
  cidr_ipv6                    = optional(string, "")
  referenced_security_group_id = optional(string, "")  # sg-..., or <account>/sg-... across a peering
  prefix_list_id               = optional(string, "")
}))

egress_rules = map(object({
  description                  = string
  port                         = number                  # 1-65535
  protocol                     = optional(string, "tcp") # tcp or udp
  cidr_ipv4                    = optional(string, "")    # exactly one destination
  cidr_ipv6                    = optional(string, "")
  referenced_security_group_id = optional(string, "")
  prefix_list_id               = optional(string, "")
}))
```

### Parameters

| Name | Type | Default | Description |
|---|---|---|---|
| `create_cluster_parameter_group` | `bool` | `true` | Create the cluster parameter group |
| `cluster_parameter_group_name` | `string` | `""` | Existing cluster parameter group |
| `create_db_parameter_group` | `bool` | `true` | Create the instance parameter group |
| `db_parameter_group_name` | `string` | `""` | Existing instance parameter group |
| `cluster_parameters` | `map(object({ value = string, apply_method = optional(string, "pending-reboot") }))` | `{}` | Cluster parameters by name |
| `db_parameters` | same as `cluster_parameters` | `{}` | Instance parameters by name |
| `enforce_tls` | `bool` | `true` | Write the TLS parameter |
| `allow_insecure_transport` | `bool` | `false` | Acknowledges `enforce_tls = false` |
| `recommended_parameters` | `bool` | `true` | Merge the logging parameters |

### Backup, maintenance and deletion

| Name | Type | Default | Description |
|---|---|---|---|
| `backup_retention_days` | `number` | `7` | 1–35 |
| `preferred_backup_window` | `string` | `"02:00-03:00"` | UTC |
| `preferred_maintenance_window` | `string` | `"sun:04:00-sun:05:00"` | UTC; also applied to instances |
| `backtrack_window_seconds` | `number` | `0` | aurora-mysql only; up to 259200 |
| `deletion_protection` | `bool` | `true` | Refuse cluster deletion |
| `skip_final_snapshot` | `bool` | `false` | Delete without a final snapshot |
| `final_snapshot_identifier` | `string` | `""` | `""` gives `<name>-final-<timestamp>` |
| `delete_automated_backups` | `bool` | `false` | Delete automated backups with the cluster |
| `copy_tags_to_snapshot` | `bool` | `true` | Copy cluster tags to snapshots |

### Features

| Name | Type | Default | Description |
|---|---|---|---|
| `enable_data_api` | `bool` | `false` | RDS Data API (HTTP endpoint) |
| `enable_local_write_forwarding` | `bool` | `false` | Readers forward writes to the writer |
| `cluster_iam_roles` | `map(object({ role_arn = string, feature_name = optional(string, "") }))` | `{}` | Roles for S3, Lambda, SageMaker, Comprehend or Bedrock; `feature_name` is required on PostgreSQL and empty on MySQL |
| `activity_stream` | `object({ enabled = optional(bool, false), mode = optional(string, "async"), kms_key_arn = optional(string, "") })` | `{}` | Database Activity Streams |
| `custom_endpoints` | `map(object({ type = optional(string, "READER"), static_members = optional(list(string), []), excluded_members = optional(list(string), []) }))` | `{}` | Members are `instances` keys |
| `timeouts` | `object({ create, update, delete })` | `"120m"` each | Cluster and instance timeouts |

### Reader autoscaling

```hcl
reader_autoscaling = object({
  enabled            = optional(bool, false)
  min_capacity       = optional(number, 1)    # 0 <= min <= max <= 15
  max_capacity       = optional(number, 3)
  metric             = optional(string, "RDSReaderAverageCPUUtilization")  # or RDSReaderAverageDatabaseConnections
  target_value       = optional(number, 70)
  scale_in_cooldown  = optional(number, 300)
  scale_out_cooldown = optional(number, 300)
  disable_scale_in   = optional(bool, false)
})
```

### RDS Proxy

```hcl
proxy = object({
  enabled                      = optional(bool, false)
  require_tls                  = optional(bool, true)
  iam_auth                     = optional(string, "DISABLED")  # or REQUIRED
  client_password_auth_type    = optional(string, "")          # MYSQL_NATIVE_PASSWORD, MYSQL_CACHING_SHA2_PASSWORD,
                                                               # POSTGRES_SCRAM_SHA_256, POSTGRES_MD5
  idle_client_timeout          = optional(number, 1800)        # 1-28800 seconds
  debug_logging                = optional(bool, false)
  max_connections_percent      = optional(number, 90)
  max_idle_connections_percent = optional(number, 50)
  connection_borrow_timeout    = optional(number, 120)
  session_pinning_filters      = optional(list(string), [])    # EXCLUDE_VARIABLE_SETS
  init_query                   = optional(string, "")
  create_reader_endpoint       = optional(bool, true)
  create_role                  = optional(bool, true)
  role_arn                     = optional(string, "")          # with create_role = false
  secret_arns                  = optional(list(string), [])
  use_master_secret            = optional(bool, false)
  secret_kms_key_arn           = optional(string, "")
  create_security_group        = optional(bool, true)
  security_group_ids           = optional(list(string), [])    # with create_security_group = false
  subnet_ids                   = optional(list(string), [])    # [] means var.subnet_ids
  ingress_rules                = optional(map(object), {})     # same schema as ingress_rules
  egress_rules                 = optional(map(object), {})     # same schema as egress_rules
})
```

### Observability

| Name | Type | Default | Description |
|---|---|---|---|
| `sns_topic_arn` | `string` | `""` | Topic for alarms and events; required while either is on |
| `create_alarms` | `bool` | `true` | CloudWatch alarms |
| `create_event_subscriptions` | `bool` | `true` | RDS event subscriptions |
| `cluster_event_categories` | `list(string)` | `["failover", "failure", "maintenance", "notification", "global-failover"]` | Cluster events |
| `instance_event_categories` | `list(string)` | `["availability", "failover", "failure", "low storage", "maintenance", "recovery"]` | Instance events |
| `alarm_cpu_percent` | `number` | `80` | Writer CPU, or reader CPU on a secondary |
| `alarm_freeable_memory_bytes` | `number` | `268435456` | 256 MiB |
| `alarm_free_local_storage_bytes` | `number` | `2147483648` | 2 GiB |
| `alarm_replica_lag_ms` | `number` | `2000` | Maximum replica lag |
| `alarm_acu_utilization_percent` | `number` | `90` | Serverless only |
| `alarm_connections` | `number` | `0` | `0` disables |
| `alarm_transaction_ids` | `number` | `1000000000` | aurora-postgresql only |
| `alarm_global_rpo_lag_ms` | `number` | `10000` | Global secondary only |
| `alarm_volume_bytes` | `number` | `0` | `0` disables |
| `enabled_cloudwatch_logs_exports` | `list(string)` | `[]` | PostgreSQL: `postgresql`, `iam-db-auth-error`, `instance`. MySQL: `audit`, `error`, `general`, `slowquery`, `iam-db-auth-error`, `instance` |
| `create_log_groups` | `bool` | `true` | Create the log groups before the cluster |
| `log_retention_days` | `number` | `30` | A CloudWatch retention value; `0` never expires |
| `log_group_class` | `string` | `"STANDARD"` | Or `INFREQUENT_ACCESS`; changing it replaces the groups |
| `log_group_skip_destroy` | `bool` | `false` | Keep the log groups when Terraform would delete them |
| `cloudwatch_logs_kms_key_arn` | `string` | `""` | Key for the log groups |
| `enhanced_monitoring_interval` | `number` | `60` | `0`, `1`, `5`, `10`, `15`, `30` or `60` seconds |
| `create_monitoring_role` | `bool` | `true` | Create the Enhanced Monitoring role |
| `monitoring_role_arn` | `string` | `""` | Existing role, with `create_monitoring_role = false` |
| `performance_insights_enabled` | `bool` | `true` | On the cluster and every instance |
| `performance_insights_retention_days` | `number` | `7` | 7, a multiple of 31 up to 713, or 731 |
| `performance_insights_kms_key_arn` | `string` | `""` | Key for Performance Insights |
| `database_insights_mode` | `string` | `"standard"` | `advanced` needs 465 days of retention |

### IAM

| Name | Type | Default | Description |
|---|---|---|---|
| `permissions_boundary_arn` | `string` | `""` | Permissions boundary for every created role |
| `iam_role_path` | `string` | `"/"` | Path for every created role |

---

## Outputs

### Resource outputs

| Name | Description |
|---|---|
| `cluster_identifier` | Cluster identifier (equal to `name`) |
| `cluster_arn` | Cluster ARN |
| `cluster_resource_id` | `cluster-XXXX`; used in IAM database authentication policies and for a PITR of a deleted cluster |
| `cluster_endpoint` | Writer endpoint |
| `cluster_reader_endpoint` | Reader endpoint |
| `cluster_port` | Database port |
| `cluster_hosted_zone_id` | Route 53 zone of the endpoints |
| `engine_version_actual` | Engine version running |
| `master_user_secret_arn` | Managed master secret ARN, or null |
| `master_user_secret_kms_key_id` | Key of the managed secret, or null |
| `global_cluster_identifier` | Global cluster, or null; waits for the cluster and its instances |
| `global_cluster_arn` | ARN of the module-created global cluster |
| `instance_identifiers` | Identifier per instance key |
| `instance_arns` | ARN per instance key |
| `instance_endpoints` | Endpoint per instance key |
| `writer_instance_key` | Key of the writer as of the last refresh |
| `custom_endpoints` | Endpoint per custom endpoint key |
| `security_group_id` | Module-created database security group, or null |
| `security_group_ids` | Every security group on the cluster |
| `db_subnet_group_name` | Subnet group in use |
| `cluster_parameter_group_name` | Cluster parameter group in use |
| `db_parameter_group_name` | Instance parameter group in use |
| `effective_parameters` | `{ cluster, instance }` parameters the module wrote; null for brought groups |
| `monitoring_role_arn` | Enhanced Monitoring role in use |
| `log_group_names` | Log group per exported type |
| `log_group_arns` | ARN per module-created log group |
| `alarm_arns` | ARN by alarm name |
| `activity_stream_kinesis_stream_name` | Kinesis stream of the activity stream |
| `proxy_arn` | RDS Proxy ARN, or null |
| `proxy_endpoint` | Read/write proxy endpoint |
| `proxy_reader_endpoint` | Read-only proxy endpoint, or null |
| `proxy_role_arn` | Proxy role in use |
| `proxy_security_group_id` | Module-created proxy security group, or null |

### Contract outputs

Structured, non-sensitive outputs for other teams. Each is null when
`create = false`, and each passes through `tfe_outputs.nonsensitive_values`.

| Output | Shape |
|---|---|
| `connection` | `{ host, reader_host, proxy_host, proxy_reader_host, port, proxy_port, engine, database, username, secret_arn, secret_kms_key_arn, ca_cert_identifiers, tls_required, iam_auth, security_group_id }` |
| `network_contract` | `{ subnet_group, subnet_ids, security_group_ids, database_port, proxy_port, rules_you_must_add[], vpc_endpoints[], notes[] }` |
| `kms_key_policy_requirements` | `[{ key, principal, actions[], condition, why }]`, one entry per customer-managed key in use |
| `sns_topic_policy_requirement` | `{ topic, statements[{ principal, action, condition, why }] }` for `events.rds.amazonaws.com` and `cloudwatch.amazonaws.com` |
| `governance` | Credentials and transport, network, encryption (`keys`, `purposes_without_cmk`), resilience, versions (the actual `engine_lifecycle_support`), observability, `acknowledged_checks`, data egress paths, `cost_drivers` |
| `verify_commands` | AWS CLI commands: `cluster_is_available`, `writer_is_where_you_expect`, `move_the_writer`, `parameters_are_applied`, `tls_is_enforced`, `plaintext_is_refused`, `master_secret`, `extended_support_is_off`, `alarms_have_a_target`, `proxy_targets_are_available` |

`connection.database` and `connection.username` are read from the cluster, not
from the inputs, so they are correct after a restore.
`network_contract.vpc_endpoints` lists the interface and gateway endpoints an
isolated VPC needs for the features in use: Secrets Manager, S3, Lambda,
Bedrock, SageMaker, Comprehend and the RDS Data API.

Both policy outputs can be read in the first plan, before anything is applied,
when the key and topic ARNs are known at plan time. Send them to the key and
topic owners then: a wrong key policy fails the apply part way, and a wrong
topic policy loses notifications silently.

---

## Operations

### Day-2 changes

| Change | Procedure |
|---|---|
| Minor upgrade | Change `engine_version`; applied in the maintenance window unless `apply_immediately` |
| Major upgrade | `engine_version`, `allow_major_version_upgrade = true` and `apply_immediately = true` in one apply; set both flags back to `false` afterwards |
| Major upgrade of a global database | `aws rds modify-global-cluster --global-cluster-identifier <id> --engine-version <exact> --allow-major-version-upgrade`, then update `engine_version` in every region |
| Add or remove an instance | Edit `instances`; only that instance changes |
| Move the writer | Run `verify_commands.move_the_writer`; open connections are dropped |
| Rotation window | `master_password_rotation.schedule_expression = "cron(0 3 ? * SUN *)"` |
| Disable reader autoscaling | Set `min_capacity = 0` and `max_capacity = 0`, apply, wait until `writer_is_where_you_expect` lists only the `instances`, then disable |
| Pending modifications | With `apply_immediately = false` they appear in every plan until the maintenance window; this is not drift |
| Destroy | Set `deletion_protection = false` and apply, then destroy; the final snapshot remains, and is billed |

### What replaces resources

| Input change | Effect |
|---|---|
| `name`, `engine`, `kms_key_arn` | **Cluster replaced** (blocked by deletion protection) |
| The subnet group name (`create_db_subnet_group`, `db_subnet_group_name`) | **Cluster and instances replaced** |
| An `instances` key, or its `availability_zone` | That instance replaced |
| A `custom_endpoints` key | That endpoint replaced |
| The proxy's subnets | Proxy replaced |
| `activity_stream.mode` | Stream restarted |
| `log_group_class` | Log groups, and the logs in them, replaced |
| `instance_class`, `port`, `network_type`, `storage_type`, parameters | In place |
| `global_cluster_role` from `none` to a global role on an existing cluster | Refused by the provider. Create the global cluster with `aws rds create-global-cluster --source-db-cluster-identifier`, then use `create_global_cluster = false` |

### Verification

`verify_commands` holds ready-to-run AWS CLI commands for CloudShell in the
cluster's account and region. `plaintext_is_refused` needs a host inside the
VPC.

---

## Limitations

- **Not yet applied against real AWS.** Verified with a mocked provider on both
  provider majors and against the provider schema.
- **Alarm dimensions are documented, not observed.** A metric published under
  different dimensions leaves its alarm in `INSUFFICIENT_DATA`, or in `ALARM`
  where missing data is breaching.
- **Turning on Performance Insights or the managed secret on an existing
  cluster uses the AWS-managed key**, even when a customer-managed key is
  configured, because the key attribute is in `ignore_changes`. AWS cannot
  change it afterwards, so set both at creation.
- **Alarms follow `global_cluster_role`, not the cluster's current role.** After
  a global switchover or failover, swap the roles in code.
- **An existing regional cluster cannot join a global database** through the
  module, and global upgrades run outside Terraform.
- **Autoscaled readers are outside Terraform state.** They get no per-instance
  alarms or instance events, and must be scaled to zero before autoscaling is
  disabled or the cluster is destroyed.
- **`activity_stream.mode = "sync"` is accepted on aurora-mysql**, which supports
  only `async`; AWS refuses it at apply.
- **The activity stream entry in `kms_key_policy_requirements`** puts a
  `kms:ViaService` condition on consumer access. Consumers decrypt with KMS
  directly, so they need a grant on the `aws:rds:dbc-id` encryption context
  instead.
- **The proxy port** is the engine default, **Performance Insights** has no
  per-instance setting, and **TLS in a brought parameter group** is not visible
  to the module.

### Not in scope

VPC, subnets and VPC endpoints; KMS keys, SNS topics and their policies;
database users, schemas and grants; DNS records (RDS endpoints are not Route 53
alias targets, so use a CNAME); AWS Backup plans (select the cluster by
`cluster_arn`); blue/green deployments, zero-ETL, Aurora Limitless and
Serverless v1; global failover and switchover.

---

## Versioning, testing and support

**Versioning.** Semantic versioning, tagged `aurora-vX.Y.Z`. A major release is
anything that changes what an unchanged configuration plans: a removed or
renamed input or output, a new required input, a changed default, a change
that turns an update into a replacement, an address change, or a raised
Terraform or provider floor. Minor releases add optional inputs, outputs,
checks, alarms or resources; patches change no plan. Deprecated inputs keep
working until the next major release. `moved` blocks are never removed, so
versions can be skipped.

**Testing.**

| Layer | Coverage |
|---|---|
| `tests/aurora.tftest.hcl` | 20 mocked plan runs: default resource set and posture, naming and tags, both engines, Serverless v2, autoscaling, bring-your-own, proxy, global primary and secondary, `create = false`, contract outputs, refusals and checks |
| `tests/check_consistency.py` | Check names, the counts quoted here, variables, locals and examples agree with the code |
| `tests/check_plan.py <plan.json>` | Gate for a real plan: no cluster or instance deleted or replaced, encryption, deletion protection, TLS, no public instance, no `/0` rule, no password in state; plus `--require-cmk` and `--required-tags` |
| `tests/lint_validations.py` | No condition depends on short-circuit evaluation |
| CI | Terraform 1.7.5 and the latest release; AWS provider 5.100.0 and the latest 6.x; TFLint |

```sh
cd modules/aurora
terraform init -backend=false && terraform test
python3 tests/check_consistency.py
terraform show -json plan.tfplan > plan.json && python3 tests/check_plan.py plan.json --require-cmk
```

**Support.** Open an issue on
[ivasik-k7/terraform-shared-modules](https://github.com/ivasik-k7/terraform-shared-modules/issues)
titled `aurora: …`, with the plan output for a bug.

**License.** MIT; see [LICENSE](https://github.com/ivasik-k7/terraform-shared-modules/blob/main/LICENSE).
