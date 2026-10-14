# Changelog — aurora

All notable changes to this module. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the module
follows [semantic versioning](https://semver.org): see "Versioning and support"
in [README.md](README.md). Releases are tagged `aurora-vX.Y.Z`.

Entries marked **BREAKING** change what an unchanged caller's plan does.
Moving from 1.x is covered step by step in [docs/UPGRADE-2.0.md](docs/UPGRADE-2.0.md).

## [2.0.0] - unreleased

A rewrite. The interface, defaults and resource addresses change; 11 `moved`
blocks carry existing deployments across, from both 1.x layouts (the subnet
group with and without `count`). `tests/check_moved.py` rehearses the upgrade
against the module without AWS.

### Added

- RDS Proxy (`proxy`), with each part created or brought: role, secrets,
  security group, subnets, a read-only endpoint.
- Reader autoscaling (`reader_autoscaling`).
- Global database roles (`global_cluster_role` = `none`, `primary`,
  `secondary`), creating or joining a global cluster, headless secondaries, and
  global write forwarding.
- Point-in-time restore (`restore_to_point_in_time`), including from a deleted
  cluster's retained backups by resource ID.
- `allow_plaintext_credentials`: a `master_password`, which lands in state,
  now needs this acknowledgement.
- A rotation schedule for the RDS-managed master secret (`master_password_rotation`).
- Per-purpose KMS keys (`master_user_secret_kms_key_arn`,
  `performance_insights_kms_key_arn`, `cloudwatch_logs_kms_key_arn`,
  `activity_stream.kms_key_arn`) and `require_cmk`.
- TLS enforcement in the cluster parameter group (`enforce_tls`), and a small
  set of recommended logging parameters (`recommended_parameters`).
- Alarms on the writer and reader roles, per-instance memory and local storage,
  replica lag, ACU utilisation, connections, PostgreSQL transaction ID age,
  volume size and global RPO lag; RDS event subscriptions for the cluster and
  its instances.
- 36 advisory checks, and `acknowledged_checks` to accept one in code.
- IAM database authentication contract (`iam_database_users`,
  `create_iam_database_auth_policies`, output `iam_database_auth`): exact
  `rds-db:connect` ARNs for cluster and proxy users, policy documents or
  managed policies, token commands, engine SQL and a Data API policy.
- Audit logging preset (`audit_logging`): pgAudit on aurora-postgresql,
  Advanced Auditing on aurora-mysql, with the log export required.
- Plan-time refusal when Performance Insights or the managed master secret is
  turned on for an existing cluster with a customer key, which AWS would
  otherwise encrypt with the AWS-managed key permanently.
- Refusal of activity stream `sync` mode on aurora-mysql; checks for proxy
  TLS and egress outside private ranges; key policy requirements for activity
  stream consumers (encryption context) and the proxy's secret key.
- Contract outputs: `connection`, `governance`, `network_contract`,
  `kms_key_policy_requirements`, `sns_topic_policy_requirement`,
  `verify_commands`, `effective_parameters`.
- `kms_key_policy_requirements` entries carry contract version 2 fields for
  `modules/kms` to compile: `sid`, `principals` (`services`, `arns`, symbolic
  `roles` such as `deployer`), `conditions` (`test`, `variable`, `values`) and
  `purpose`. Additive, not breaking: `key`, `principal`, `actions`,
  `condition` and `why` are unchanged. Secret readers and Performance
  Insights readers are separate entries (`MasterSecretReaders`,
  `PerformanceInsightsReaders`) with only the actions they need, so a compiled
  key policy does not give them the deployer's `CreateGrant`.
- `egress_rules`, prefix-list and cross-account security group sources, and a
  separate proxy security group with its own rules.
- Module-created log groups with retention, key, class and `skip_destroy`.
- `engine_lifecycle_support` (Extended Support), `database_insights_mode`,
  `iam_role_path`, `permissions_boundary_arn`, `required_tag_keys`,
  `custom_endpoints` keyed by instance key, `cluster_iam_roles` on both engines.
- `docs/UPGRADE-2.0.md`, `COSTS.md`, this changelog.

### Changed

- **BREAKING** Terraform **>= 1.7** (was >= 1.5) and AWS provider
  **>= 5.90, < 7.0** (was ~> 5.0). Both v5 and v6 are supported. Rules that
  compare two inputs are preconditions on the cluster, so some input errors
  read "Resource precondition failed" rather than "Invalid value for variable".
- **BREAKING** `engine`, `instance_class` and `instances` are required.
- **BREAKING** `master_password` needs `manage_master_user_password = false`
  (no longer the default) and `allow_plaintext_credentials = true`.
- **BREAKING** Renamed: `cluster_identifier` → `name`, `kms_key_id` →
  `kms_key_arn`, `backup_retention_period` → `backup_retention_days`,
  `monitoring_interval` → `enhanced_monitoring_interval`,
  `cloudwatch_log_retention_days` → `log_retention_days`,
  `serverless_scaling_configuration` → `serverlessv2_scaling_configuration`,
  `backtrack_window` → `backtrack_window_seconds`, `enable_http_endpoint` →
  `enable_data_api`, `cluster_endpoints` → `custom_endpoints`,
  `iam_role_associations` → `cluster_iam_roles`,
  `performance_insights_retention_period` → `performance_insights_retention_days`,
  `performance_insights_kms_key_id` → `performance_insights_kms_key_arn`,
  `master_user_secret_kms_key_id` → `master_user_secret_kms_key_arn`,
  three of the alarm thresholds, and the global and activity-stream inputs. The
  full map is in the upgrade guide.
- **BREAKING** Defaults: `manage_master_user_password` `false` → `true`;
  `auto_minor_version_upgrade` `true` → `false`; `performance_insights_enabled`
  `false` → `true`; `enhanced_monitoring_interval` 0 → 60; log retention 7 → 30
  days; `master_username` `"admin"` → `"dbadmin"`; maintenance window
  `sun:03:00` → `sun:04:00`, now also applied to instances;
  `delete_automated_backups` (provider default `true`) → `false`;
  `alarm_connections` 80 → 0 (off); replica lag threshold 1000 → 2000 ms.
- **BREAKING** `create_alarms` and `create_event_subscriptions` default on and
  require `sns_topic_arn`.
- **BREAKING** The database security group has exactly `ingress_rules` and no
  egress; it is renamed (`<name>-db-*`) and replaced on upgrade.
- **BREAKING** Parameter groups are named for their family
  (`<name>-cluster-<family>`, `<name>-instance-<family>`) and replaced on
  upgrade; `cluster_parameters` and `db_parameters` are maps keyed by name, with
  `apply_method` defaulting to `pending-reboot`.
- **BREAKING** The Enhanced Monitoring role is `<name>-<region>-monitor`, with an
  inline policy scoped to `RDSOSMetrics`; replaced on upgrade.
- **BREAKING** A created subnet group is named `<name>` unless
  `db_subnet_group_name` says otherwise.
- **BREAKING** Alarms are replaced: new names, metrics and dimensions.
- **BREAKING** Tags: `Module = "aurora"` and `DatabaseCluster = <name>` replace
  `Module = "Aurora"` and `Cluster`; the module's keys can no longer be
  overridden.
- **BREAKING** `engine_version` for aurora-mysql must be 8.0 / 3.x.
- `master_username`, `database_name`, the restore inputs,
  `engine_lifecycle_support`, `source_region` and the secret and Performance
  Insights keys are ignored after creation instead of replacing the cluster or
  sending a change AWS refuses.
- Instances, endpoints, the proxy target and alarms refer to the cluster by
  name, so a planned cluster replacement no longer plans the instances for
  replacement too: deletion protection now stops it with the compute intact.
- Performance Insights is one setting for the cluster and every instance.
- The final snapshot is `<name>-final-<creation time>`, unique per cluster
  lifetime.

### Removed

- **BREAKING** `engine_mode` and Serverless v1, `storage_encrypted` (always on),
  `iops`, `availability_zones`, `enable_automated_backup`,
  `security_group_name`, `db_subnet_group_description`, `cluster_tags`,
  `security_group_tags`, `instance_tags`, `source_db_cluster_identifier`,
  `source_region`, `activity_stream_audit_fields_included`,
  `alarm_free_storage_space_bytes`, the separate parameter group families, and
  per-instance `publicly_accessible` and Performance Insights settings.
- **BREAKING** Outputs: `writer_connection_string`, `reader_connection_string`,
  the parameter group and subnet group IDs and ARNs, `cluster_members`,
  `global_cluster_members`, `availability_zones` and the other attribute
  echoes. Their replacements are mapped in the upgrade guide.

### Fixed

- Alarms had no actions, so they changed state without telling anyone.
- The storage alarm watched `FreeStorageSpace` and the replica lag alarm
  `AuroraBinlogReplicaLag`; neither measures Aurora local storage or Aurora
  replica lag.
- CPU and connection alarms read a cluster average, which hides a saturated
  writer behind idle readers.
- The fixed final snapshot name `<id>-final-snapshot` collided the second time
  a cluster of the same name was deleted, failing the delete.
- `storage_type = "gp3"` and `iops` were accepted for Aurora, which uses
  neither.
- Global secondaries could not join an existing global cluster.
- The declared Terraform floor (1.5) was below the version the module's
  cross-variable validations need.

### Security

- The master password is RDS-managed by default and never in state; a
  plaintext `master_password` needs `allow_plaintext_credentials` and is
  flagged by a check in every plan.
- TLS is enforced by default.
- Storage encryption cannot be turned off.
- The database security group has no egress (was allow-all to `0.0.0.0/0`), and
  `0.0.0.0/0` / `::/0` ingress is refused.
- The Enhanced Monitoring role's trust is limited to this account
  (`aws:SourceAccount`) and its policy to the one log group it writes, instead
  of the broad AWS-managed policy.
- `require_cmk` refuses any purpose that would fall back to an AWS-managed key;
  KMS keys and SNS topics from another region are refused.
- A proxy with no secrets of its own needs `use_master_secret` before it logs
  clients in as the master user.
