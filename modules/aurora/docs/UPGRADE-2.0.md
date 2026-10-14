# Upgrading to aurora 2.0

From the 1.x interface (`cluster_identifier`, `aws_rds_cluster.main`) to 2.0.0,
in an HCP Terraform workspace. The cluster, its instances, its endpoints and its
log groups carry over through 11 `moved` blocks and plan as updates — **if**
the inputs that force replacement still match what is running. Several defaults
changed underneath them; this page lists every one.

**Not yet rehearsed on a live cluster.** It is derived from the 1.x code, the
2.0 code and the provider source. Where those cannot settle a question, it says
**verify** — do that on a non-production workspace first.

---

## 1. Before you start

| | |
|---|---|
| Workspace Terraform version | **1.7 or later** (Settings → General) — 1.x declared 1.5. A root `required_version` such as `>= 1.7.3` can stay |
| Lock file | If the committed `.terraform.lock.hcl` pins the AWS provider below 5.90, run `terraform init -upgrade` once wherever your pipeline can, and commit the result. HCP Terraform's own `init` honours the file and fails otherwise |
| Module block name | **Keep it.** The `moved` blocks are relative to `module.<x>`; renaming the block as well loses them |
| Plan read access | Someone who can read the speculative plan in full, including `# forces replacement` annotations |

---

## 2. Inputs that must match what is running

Get the running values first, from CloudShell:

```bash
aws rds describe-db-clusters --db-cluster-identifier <old cluster_identifier> \
  --query 'DBClusters[0].{engine:Engine,version:EngineVersion,port:Port,subnets:DBSubnetGroup,kms:KmsKeyId,user:MasterUsername,db:DatabaseName,members:DBClusterMembers[].DBInstanceIdentifier}'
```

| 2.0 input | Must be | Otherwise |
|---|---|---|
| `name` | The old `cluster_identifier`, lowercase. More than 41 characters cannot be carried over | **Replaces the cluster** |
| `engine` | The running engine. Now required — 1.x defaulted to `aurora-postgresql` | **Replaces** |
| `kms_key_arn` | The `kms` ARN above (the old `kms_key_id`; AWS reports an ARN even if you passed an ID). `""` if it is `aws/rds` | **Replaces** |
| `create_db_subnet_group`, `db_subnet_group_name` | 1.x created the group (`create_db_subnet_group = true`, the default): keep `true` and set `db_subnet_group_name` to `subnets` above — `<old cluster_identifier>-subnet-group` unless you overrode it. 1.x used your group: `false` and the same name | **Replaces the cluster and every instance**. 2.0 names a created group `<name>` by default |
| `engine_version` | The **running** version, exact. 1.x defaulted `auto_minor_version_upgrade = true`, so it has probably moved past what your code says | A downgrade AWS refuses at apply |
| `instance_class`, `instances` | Both now required. The same keys as the old `instances` map, valid under the new rules (lowercase, 1–20 characters). 1.x defaulted to `{ writer = { instance_class = "db.t3.medium", promotion_tier = 0 } }` — write that out if you relied on it | A changed key replaces that instance; a missing one deletes it |
| `port` | The running port, or `0` for the engine default | In place, with a restart |
| `master_username`, `database_name` | The running values. 1.x defaulted `master_username = "admin"`; 2.0 defaults `"dbadmin"` | Not a replacement — 2.0 ignores both after creation, and `output.connection` reports the values the cluster has. Set them to the running values anyway, so the code says what runs |

**Performance Insights** defaults to on in 2.0 (1.x: off). On a cluster that
had it off and uses a customer-managed key, the first plan is **refused**: the
provider would not send the key, and AWS would encrypt Performance Insights
with `aws/rds` for good. Either set `performance_insights_enabled = false`
for the upgrade apply and turn it on in a later change, or run the
`aws rds modify-db-cluster --enable-performance-insights
--performance-insights-kms-key-id <key>` the refusal prints, then plan again.

Two things must already be true of the 1.x cluster, or it cannot be adopted
without replacement: `storage_encrypted = true` (2.0 has no off switch) and
`engine_mode = "provisioned"` (Serverless v1 is not supported). A cluster that
carries `source_region` is fine: 2.0 ignores it.

---

## 3. Credentials

`master_password` carries over under the same name. What is new is
`allow_plaintext_credentials`, required with it, and the default
`manage_master_user_password = true` — 1.x defaulted to `false`.

| 1.x setup | 2.0 | What happens at the apply |
|---|---|---|
| `manage_master_user_password = true` | The same (now the default) | Nothing. The secret's key is fixed; `master_user_secret_kms_key_arn` is only compared |
| `master_password`, keep it | `manage_master_user_password = false`, `master_password` unchanged (from a sensitive workspace variable), `allow_plaintext_credentials = true` | Nothing; the password stays in state, and `credentials_are_not_in_state` warns until acknowledged |
| `master_password`, move to RDS-managed | `manage_master_user_password = true`, `master_password` removed | In place, but **RDS replaces the password** with a generated one at this apply. Every client must read `connection.secret_arn` first. The password leaves the current state |
| Global database | `manage_master_user_password = false`, `master_password` and `allow_plaintext_credentials = true` on the primary; nothing on secondaries | AWS does not support the managed secret on global members, so the password stays in state |

**Moving to RDS-managed does not erase the old password.** It is in every
state version the workspace kept before this apply, readable by anyone with
state access to the workspace's history. Rotate it, or treat the move itself
as the rotation — RDS has just replaced it.

---

## 4. Steps in HCP Terraform

1. On a branch, change the module block:

   ```hcl
   module "orders_db" {                                 # same name as before
     source  = "app.terraform.io/citadel-hub/aurora/aws"
     version = "~> 2.0"
     # inputs mapped with §2, §3 and §7
   }
   ```

2. Translate every input with [the table in §7](#7-every-1x-variable). Pay
   attention to `ingress_rules`: the new security group has **exactly** those
   rules and no egress, so an untranslated `allowed_*` list cuts clients off.
3. Set `sns_topic_arn`, or set `create_alarms = false` and
   `create_event_subscriptions = false` — 2.0 refuses alarms with nowhere to go.
4. Open a pull request. The VCS-connected workspace runs a speculative plan.
   Download its JSON (or `terraform show -json` a local plan) and run
   `python3 tests/check_plan.py plan.json`: it fails on a replaced or deleted
   cluster, instance, global cluster, subnet group or log group.
5. In the plan, look for these, in this order:
   - `module.<x>.aws_rds_cluster.this[0] must be replaced` — **must not appear.**
     Find the attribute marked `# forces replacement`, fix the input in §2, push,
     and read the new plan.
   - `aws_rds_cluster_instance.this[...] must be replaced` or `will be destroyed`
     — an instance key or `availability_zone` that does not match.
   - `aws_db_subnet_group.this[0] must be replaced` — the subnet group name.
   - `has moved to` — one line per `moved` block that applied (§5).
6. Read the rest against §6. Merge in a change window and confirm the apply:
   TLS enforcement and the security group swap take effect during it.
7. Run `verify_commands` from CloudShell (`terraform output` in the workspace, or
   the workspace's Outputs tab once re-exported).
8. If you moved to the RDS-managed secret, the old password is still in older
   state versions (§3).
9. Read the plan's check warnings. Fix them, or put the ones you accept in
   `acknowledged_checks` — `extended_support_matches_the_setting` will warn on
   most 1.x clusters (§6).

---

## 5. The moved blocks

| 1.x address | 2.0 address |
|---|---|
| `aws_rds_cluster.main` | `aws_rds_cluster.this[0]` |
| `aws_rds_cluster_instance.instances[*]` | `aws_rds_cluster_instance.this[*]` |
| `aws_rds_global_cluster.main[0]` | `aws_rds_global_cluster.this[0]` |
| `aws_db_subnet_group.main` (early 1.x) or `aws_db_subnet_group.main[0]` (late 1.x) | `aws_db_subnet_group.this[0]`, in two chained blocks so both shapes arrive |
| `aws_rds_cluster_parameter_group.main[0]` | `aws_rds_cluster_parameter_group.this[0]` |
| `aws_db_parameter_group.main[0]` | `aws_db_parameter_group.this[0]` |
| `aws_security_group.aurora[0]` | `aws_security_group.this[0]` |
| `aws_iam_role.enhanced_monitoring[0]` | `aws_iam_role.monitoring[0]` |
| `aws_rds_cluster_endpoint.custom[*]` | `aws_rds_cluster_endpoint.this[*]` |
| `aws_cloudwatch_log_group.aurora_logs[*]` | `aws_cloudwatch_log_group.this[*]` |

`aws_rds_cluster_role_association.this` and `aws_rds_cluster_activity_stream.this`
keep their 1.x addresses. These blocks stay in every later version, so a
workspace can go from 1.x to any 2.x directly.

**Rehearsed, without AWS.** `tests/check_moved.py` plans this module over a
1.x state in both shapes, with the inputs in §2, and fails unless every
object moves and no cluster, instance, subnet group or log group is replaced
or deleted. It passes on provider 5.100 and 6.x. It cannot know your inputs:
the gate on your own plan is `tests/check_plan.py` (§4).

---

## 6. What still changes on the first plan

Expected, with the inputs in §2 right.

| Resource | Change | Means |
|---|---|---|
| Cluster parameter group | Replaced, create-before-destroy: `<id>-cpg-*` → `<name>-cluster-<family>` | Carries the recommended logging parameters and **`rds.force_ssl = 1` / `require_secure_transport = ON`, applied immediately**: clients without TLS are refused from this apply. `cluster_parameters` is now a map, and `apply_method` defaults to `pending-reboot` |
| Instance parameter group | Replaced, create-before-destroy: `<id>-pg-*` → `<name>-instance-<family>` | The old group is deleted once the instances name the new one (**verify** with `apply_immediately = false`) |
| Database security group | Replaced, create-before-destroy: prefix `<id>-` → `<name>-db-` | Old count-indexed rules go with it; the new group has exactly `ingress_rules` and **no egress**, where 1.x allowed all outbound |
| Enhanced Monitoring role | Replaced: `<id>-rds-monitoring-role` → `<name>-<region>-monitor`; or created, since the interval default went 0 → 60 | The managed-policy attachment is destroyed and a scoped inline policy created. A short gap in OS metrics |
| Alarms | The four 1.x alarms destroyed; up to ten kinds created | 1.x alarms had no actions, read cluster averages, and watched `FreeStorageSpace` and `AuroraBinlogReplicaLag`, which do not measure Aurora local storage or replica lag |
| Event subscriptions | Created | Cluster and instance events to `sns_topic_arn` |
| Cluster | In place | Tags; Performance Insights on (default `false` → `true`; refused on a CMK cluster that had it off - §2); `delete_automated_backups` `true` → `false`; the new parameter and security groups; `final_snapshot_identifier`; maintenance window if you used the 1.x default (`sun:03:00` → `sun:04:00`) |
| Instances | In place | Parameter group, Performance Insights, Enhanced Monitoring, `auto_minor_version_upgrade` `true` → `false`, tags, the cluster's maintenance window (1.x left AWS's), the CA if it is not `rds-ca-rsa2048-g1` — clients must trust the new one |
| Subnet group | In place | Description and tags |
| Log groups | In place | Retention 7 → 30 if you used the default, the key if one is set, tags |
| Global cluster | In place | Deletion protection follows `deletion_protection` (1.x left it off). Its engine version is ignored from now on |
| `terraform_data.created_at` | Created | The final snapshot suffix is the time of this plan, not of the cluster's creation |
| Activity stream | Nothing: same address, same `resource_arn`, and `kms_key_id` is ignored after creation | The stream is not restarted. If the configured key differs from the running one, `activity_stream_key_is_the_one_configured` says so |
| aurora-mysql feature roles | `aws_rds_cluster_role_association.this[*]` destroyed; the roles move to the cluster's own `iam_roles` | 2.0 associates MySQL roles without a feature name. The order of the disassociation and the re-association in one apply is **verify** |

**Extended Support.** 2.0 ignores `engine_lifecycle_support` after creation.
A 1.x cluster was created without the setting, so it has AWS's default —
**enabled** — and `extended_support_matches_the_setting` warns.
`governance.engine_lifecycle_support` shows the real value. It costs nothing
until the major leaves standard support; plan the major upgrade before then, or
restore from a snapshot to change it.

---

## 7. Every 1.x variable

| 1.x | 2.0 |
|---|---|
| `cluster_identifier` | `name` (2–41 chars, lowercase) |
| `engine` | `engine` — now required |
| `engine_version` | `engine_version` — pin the exact running version; aurora-mysql is 8.0 / 3.x only |
| `engine_mode` | Removed: always `provisioned`. Serverless v2 is `instance_class = "db.serverless"` |
| `serverless_scaling_configuration` | `serverlessv2_scaling_configuration` — an object with defaults (0.5–4 ACU), used when any instance is `db.serverless` |
| `backtrack_window` | `backtrack_window_seconds` |
| `enable_http_endpoint` | `enable_data_api` |
| `instances` | `instances` — required. `instance_class` per instance is now optional (module-wide `instance_class`, required); per-instance `publicly_accessible`, `performance_insights_enabled` and `performance_insights_retention_period` removed; `availability_zone` and `preferred_maintenance_window` added |
| `auto_minor_version_upgrade` | Same; default `true` → `false` |
| `storage_encrypted` | Removed: always `true` |
| `kms_key_id` | `kms_key_arn` — an ARN |
| `iops` | Removed: Aurora cluster volumes take no provisioned IOPS |
| `storage_type` | Same; `"gp3"` refused; default `"aurora"` |
| `database_name` | Same; `""` for none; ignored after creation |
| `master_username` | Same; default `"admin"` → `"dbadmin"`; ignored after creation |
| `master_password` | Same; now also needs `manage_master_user_password = false` and `allow_plaintext_credentials = true` (§3) |
| `port` | Same; `0` for the engine default |
| `availability_zones` | Removed: per-instance `availability_zone` |
| `publicly_accessible` | Same, plus `allow_public_access` |
| `create_cluster_parameter_group`, `cluster_parameter_group_name` | Same. With `true` the name must be empty: the module names its group for the family |
| `create_db_parameter_group`, `db_parameter_group_name` | Same, the same way |
| `cluster_parameter_group_family`, `db_parameter_group_family` | `parameter_group_family`, one for both |
| `cluster_parameters`, `db_parameters` | Same names; a list of `{ name, value, apply_method }` becomes a map keyed by name; default `apply_method` `pending-reboot` |
| `create_security_group` | Same |
| `security_group_name` | Removed: prefix `<name>-db-` |
| `vpc_security_group_ids` | Same; at most 5 including the module's |
| `allowed_cidr_blocks`, `allowed_ipv6_cidr_blocks`, `allowed_security_groups` | `ingress_rules`: one labelled entry per source, with `cidr_ipv4`, `cidr_ipv6` or `referenced_security_group_id` and a `description` |
| `iam_database_authentication_enabled` | Same |
| `backup_retention_period` | `backup_retention_days` |
| `enable_automated_backup` | Removed: Aurora always keeps at least a day; `backup_retention_days = 1` |
| `preferred_backup_window` | Same |
| `preferred_maintenance_window` | Same; default `sun:03:00-sun:04:00` → `sun:04:00-sun:05:00`; now also the instances' window |
| `skip_final_snapshot`, `copy_tags_to_snapshot`, `deletion_protection` | Same |
| `enabled_cloudwatch_logs_exports` | Same |
| `cloudwatch_log_retention_days` | `log_retention_days`; default 7 → 30 |
| `monitoring_interval` | `enhanced_monitoring_interval`; default 0 → 60 |
| `create_monitoring_role`, `monitoring_role_arn` | Same names. A brought role now needs `create_monitoring_role = false` explicitly |
| `performance_insights_enabled` | Same; default `false` → `true`; cluster and instances together |
| `performance_insights_retention_period` | `performance_insights_retention_days` |
| `performance_insights_kms_key_id` | `performance_insights_kms_key_arn`; ignored after it is set |
| `alarm_cpu_threshold_percent` | `alarm_cpu_percent` |
| `alarm_connections_threshold` | `alarm_connections`; default 80 → 0 (off) |
| `alarm_free_storage_space_bytes` | Removed: `alarm_free_local_storage_bytes` |
| `alarm_replica_lag_milliseconds` | `alarm_replica_lag_ms`; default 1000 → 2000 |
| `create_alarms` | Same; needs `sns_topic_arn` |
| `enable_global_cluster` | `global_cluster_role = "primary"` with `create_global_cluster = true` |
| `is_primary_region` | `global_cluster_role` |
| `global_cluster_identifier` | Same |
| `source_db_cluster_identifier` | Removed: nothing read it |
| `source_region` | Removed; ignored on an existing cluster |
| `tags` | Same, plus `required_tag_keys` |
| `cluster_tags`, `security_group_tags` | Removed: `tags` |
| `instance_tags` | `instances[*].tags` |
| `create_db_subnet_group` | Same |
| `db_subnet_group_name` | Same; with `create_db_subnet_group = true` it now names the created group (default `<name>`) |
| `db_subnet_group_description` | Removed |
| `manage_master_user_password` | Same; default `false` → `true`; refused on global members |
| `master_user_secret_kms_key_id` | `master_user_secret_kms_key_arn`; ignored after the secret exists |
| `snapshot_identifier` | Same; ignored after creation |
| `final_snapshot_identifier` | Same; default `<id>-final-snapshot` → `<name>-final-<creation time>` |
| `apply_immediately`, `enable_local_write_forwarding`, `timeouts` | Same |
| `allow_major_version_upgrade` | Same; refused on global members |
| `network_type` | Same; default `"IPV4"` |
| `cluster_endpoints` | `custom_endpoints`; members are instance keys, not identifiers |
| `iam_role_associations` | `cluster_iam_roles`; `feature_name` required on aurora-postgresql, empty on aurora-mysql |
| `enable_activity_stream`, `activity_stream_mode`, `activity_stream_kms_key_id` | `activity_stream = { enabled, mode, kms_key_arn }` |
| `activity_stream_audit_fields_included` | Removed: engine-native audit fields apply to RDS for Oracle, not Aurora |

## 8. Every 1.x output

| 1.x | 2.0 |
|---|---|
| `cluster_id` | `cluster_identifier` |
| `cluster_arn`, `cluster_resource_id`, `cluster_endpoint`, `cluster_reader_endpoint`, `cluster_port` | Same |
| `cluster_database_name`, `cluster_master_username` | `connection.database`, `connection.username` |
| `cluster_engine`, `cluster_engine_version` | `connection.engine`, `engine_version_actual` |
| `cluster_engine_mode` | Removed |
| `global_cluster_id`, `global_cluster_arn` | `global_cluster_identifier`, `global_cluster_arn` |
| `global_cluster_members`, `cluster_members` | Removed; `instance_identifiers`, `writer_instance_key` |
| `cluster_instance_ids` | `instance_identifiers` — a map by key now |
| `cluster_instance_arns`, `cluster_instance_endpoints` | `instance_arns`, `instance_endpoints` |
| `security_group_id`, `db_subnet_group_name` | Same |
| `security_group_name` | Removed |
| `db_subnet_group_id`, `db_subnet_group_arn`, `db_subnet_ids` | Removed; `network_contract.subnet_ids` |
| `cluster_parameter_group_id`, `cluster_parameter_group_arn`, `db_parameter_group_id`, `db_parameter_group_arn` | `cluster_parameter_group_name`, `db_parameter_group_name` |
| `enhanced_monitoring_role_arn` | `monitoring_role_arn` |
| `enhanced_monitoring_role_name` | Removed |
| `cloudwatch_log_groups` | `log_group_names` (and `log_group_arns`) |
| `availability_zones`, `preferred_backup_window`, `preferred_maintenance_window` | Removed; `governance.maintenance_window` |
| `backup_retention_period`, `storage_encrypted`, `kms_key_id`, `iam_database_authentication_enabled` | `governance` |
| `writer_connection_string`, `reader_connection_string` | `connection` |
| `master_user_secret_arn`, `master_user_secret_kms_key_id`, `custom_endpoints`, `activity_stream_kinesis_stream_name` | Same |
| `custom_endpoint_arns` | Removed |
| `iam_role_associations` | `governance.cluster_iam_roles` (labels) |
| `alarm_high_cpu`, `alarm_high_connections`, `alarm_low_storage`, `alarm_high_replica_lag` | `alarm_arns`, by alarm name |
