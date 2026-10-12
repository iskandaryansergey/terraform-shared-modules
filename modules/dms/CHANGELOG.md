# Changelog: dms

All notable changes to this module. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the module follows
[semantic versioning](https://semver.org): see "Versioning and support" in
[README.md](README.md). Releases are tagged `dms-vX.Y.Z`.

Entries marked **BREAKING** change what an unchanged caller's plan does. This is
the first release, so nothing is breaking relative to an earlier version; the
**default changes** below are marked for callers who adopted a pre-release
build.

## [1.0.0] - unreleased

First release.

### Added

Capabilities:

- Provisioned compute (replication instance, subnet group, tasks) and
  serverless compute (one replication config per task), selected by
  `compute_mode`.
- Database endpoints (`endpoints`) for `aurora`, `aurora-postgresql`,
  `mariadb`, `mysql`, `oracle`, `postgres`, `sqlserver`, `db2`, `db2-zos`,
  `sybase`, `redshift`, `docdb` and `neptune`, and S3 targets (`s3_targets`).
  Credentials through Secrets Manager with a module-created role per secret;
  plaintext credentials refused unless `allow_plaintext_credentials`.
- CA certificates and Oracle wallets (`certificates`), referenced by
  `certificate_key`.
- Tasks with typed, validated settings rendered to the DMS settings JSON, and
  `raw_overrides` merged over them. Table mappings validated for a selection
  rule and unique rule-ids.
- `sql_scripts`: a manifest of pre-data and post-data SQL with checksums,
  emitted as `migration_plan`. The module executes no SQL.
- Alarms (CDC latency on source and target, free storage, CPU, freeable
  memory), DMS event subscriptions, and a task log group with retention.
- Customer-key support across storage, endpoints, secrets, S3 targets and logs,
  with `require_cmk`.
- Contract outputs: `source_prerequisites`, `network_contract`,
  `account_prerequisites`, `migration_plan`, `verify_commands`,
  `task_settings_json`, `governance`.
- Account-wide service roles (`dms-vpc-role`, `dms-cloudwatch-logs-role`),
  off by default (`create_account_service_roles`).
- Advisory checks, 18 in all, accepted individually with `acknowledged_checks`
  and listed in `output.governance.acknowledged_checks`.

Validation-only tasks and validation posture:

- `validation_tasks`: validation-only tasks over an existing task. They inherit
  the parent's endpoints and mappings, always render
  `TargetTablePrepMode = DO_NOTHING` and `ValidationOnly = true`, and run as
  `full-load` or `cdc`. Provisioned mode only. Output `validation_task_arns`,
  and `governance.validation_only_tasks`.
- Validation alarms `validation_failed` and `validation_suspended`
  (`ValidationFailedOverallCount`, `ValidationSuspendedOverallCount`, missing
  data not breaching) for every task that validates, with
  `create_validation_alarms` and `alarm_validation_failed_records`.
- Honest validation posture: `governance.tasks_whose_validation_cannot_run` and
  the check `validation_is_claimed_where_it_cannot_run`. DMS validates Oracle,
  PostgreSQL-compatible, MySQL-compatible, SQL Server and Db2 LUW sources, to
  the same targets plus Redshift and S3 (S3 only as parquet with a timestamp
  column and a day-level date partition).
- RUNBOOK cutover step: run a full-load validation-only task just before
  cutover and attach its `describe-table-statistics` output.

Premigration assessment and key policies:

- `premigration_assessment` (`enabled`, `bucket_name`, `bucket_folder`,
  `kms_key_arn`, `create_role`, `role_arn`): a module-created role (trust
  `dms.amazonaws.com` with `aws:SourceAccount`; S3 write on the bucket folder,
  list on the bucket; KMS through S3 when a key is set) and output
  `premigration_assessment` with per-task start, status and report commands,
  always with `--result-encryption-mode`. Provisioned mode only. RUNBOOK gates
  it before a task is started.
- Output `kms_key_policy_requirements`: what each customer key's policy must
  allow (replication storage, endpoint keys, the CloudWatch Logs grant with its
  encryption context for `dms-tasks-<name>`, secret keys, S3 target keys, the
  assessment key).
- `log_group_skip_destroy` (default `true`): teardown keeps the task log group.
- Output `task_resource_ids`.

### Fixed

- `ssl_mode` is validated per engine, following the DMS SSL table: Oracle, Db2
  and Db2 z/OS `none` or `verify-ca` (Oracle with a wallet in
  `certificates[*].wallet`); MySQL, MariaDB and Aurora MySQL `none`,
  `verify-ca` or `verify-full`; SQL Server `none`, `require` or `verify-full`;
  SAP ASE `none` or `verify-full`; Redshift `none`; PostgreSQL any. A new check,
  `oracle_ssl_uses_a_wallet`, warns when an Oracle endpoint verifies with a PEM.
  The README quick start and both Oracle examples now use `verify-ca` with a
  wallet.
- `database_name` is always sent to DMS, including on the Secrets Manager path:
  the secret DMS reads holds host, port, username and password, not the
  database. Documentation that said otherwise is corrected.
- The `aws:SourceArn` in the endpoint-secret and S3-target role trust is now
  `arn:<partition>:dms:<region>:<account>:*`, the form AWS documents. A narrower
  ARN risked a denied `AssumeRole` at run time.
- CDC alarms use the task **resource ID** (the last segment of the task ARN) as
  `ReplicationTaskIdentifier`, the dimension DMS publishes under, instead of the
  task name. `verify_commands.cdc_latency`, `validation_state`, `failed_tables`
  and `stop_task` are now maps keyed by task, with real ARNs and IDs.
- Logging posture (`governance.task_log_levels`, check
  `debug_logging_is_temporary`) reads the merged settings, so `raw_overrides`
  cannot hide DEBUG logging.
- Plan-time refusals for configurations DMS rejects or ignores at apply: full
  LOB mode (`lob_mode` `FULL` or `INLINE`) into an S3 target;
  `cdc_start_time` or `cdc_start_position` in serverless mode
  (`aws_dms_replication_config` has no such argument); `require_cmk` without the
  module-created task log group.
- `alarm_free_storage_bytes` defaults to a threshold that follows the volume, so
  default configurations no longer trip `the_storage_alarm_leaves_room_to_react`.
- The `serverless-cdc-to-s3` example uses `lob_mode = "LIMITED"` with
  `lob_max_size_kb = 16384`, because DMS does not support full LOB mode for S3.
- The `isolated-vpc-onprem-to-aurora` example's sequence reset now works: its
  `id` columns are `GENERATED BY DEFAULT AS IDENTITY`, so
  `pg_get_serial_sequence` finds a sequence, and the reset uses
  `setval(seq, max, true)` for populated tables and `setval(seq, 1, false)` for
  empty ones.
- The Aurora module's `connection` output no longer tells the caller to hand
  `secret_arn` to DMS: DMS cannot use the RDS-managed master secret. DMS needs
  its own database user and its own secret holding host and port.
- Documentation: `session_replication_role` set through `after_connect_script`
  applies per DMS connection, so nothing needs restoring in post-data. The
  RUNBOOK per-table reload is `aws dms reload-tables`; `RecoverableErrorCount =
  -1` is described as retry forever; the list of changes that replace the
  instance is corrected; teardown covers keeping logs and evidence and uses
  `create = false` or a destroy run in the same workspace; `COSTS.md`
  arithmetic is corrected and its prices carry their pull date.

### Changed

- **BREAKING (default):** `auto_minor_version_upgrade` defaults to `false`. A
  pinned `engine_version` with automatic minor upgrades fights itself: after AWS
  upgrades the instance, every later plan tries to set the pinned version back,
  and DMS refuses. New check `minor_upgrades_do_not_fight_the_pin`. Take minor
  versions by raising `engine_version`.
- **BREAKING (default):** `alarm_free_storage_bytes` defaults to `0`, meaning 15%
  of `allocated_storage_gb` (rounded up), instead of a fixed byte count. An
  explicit value must be `0` or at least 1 GiB.
- **BREAKING (default):** `log_group_skip_destroy` is `true`, so destroying the
  module leaves the `dms-tasks-<name>` log group in the account until its
  retention expires. A later migration with the same `name` needs the group
  removed first, or `create_log_group = false`.
- **BREAKING (validation):** `ssl_mode` values DMS does not support for an
  engine are refused at plan; in particular `verify-full` on Oracle, Db2 and
  Db2 z/OS (the module default is `verify-full`, so these endpoints must set
  `ssl_mode`).
- **BREAKING (validation):** the three new plan-time refusals under "Fixed"
  (full LOB into S3, a CDC start point in serverless mode, `require_cmk` without
  the module log group) apply to configurations that previously planned.
- The CDC latency alarms' `ReplicationTaskIdentifier` dimension changes from the
  task name to the task resource ID, so existing alarms are updated in place.
- The role trust `aws:SourceArn` on the endpoint-secret and S3-target roles
  changes to the `dms:<region>:<account>:*` form, updated in place.
