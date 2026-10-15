# Changelog: dms

All notable changes to this module. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the module follows
[semantic versioning](https://semver.org): see "Versioning and support" in
[README.md](README.md). Releases are tagged `vX.Y.Z`.

Entries marked **BREAKING** change what an unchanged caller's plan does. This is
the first release, so nothing is breaking relative to an earlier version; the
**default changes** below are marked for callers who adopted a pre-release
build.

## [0.1.0] - unreleased

First release.

### Added

Capabilities:

- Provisioned compute (replication instance, subnet group, tasks) and
  serverless compute (one replication config per task), selected by
  `compute_mode`.
- Database endpoints (`endpoints`) for `aurora`, `aurora-postgresql`,
  `mariadb`, `mysql`, `oracle`, `postgres`, `sqlserver`, `db2`, `db2-zos`,
  `sybase` and `redshift`, and S3 targets (`s3_targets`).
  Credentials through Secrets Manager with a module-created role per secret;
  plaintext credentials refused unless `allow_plaintext_credentials`.
- CA certificates and Oracle wallets (`certificates`), referenced by
  `certificate_key`.
- Tasks with typed, validated settings rendered to the DMS settings JSON, and
  `raw_overrides` merged over them. Table mappings validated for a selection
  rule and unique rule-ids.
- Alarms (CDC latency on source and target, free storage, CPU, freeable
  memory), DMS event subscriptions, and a task log group with retention.
- Customer-key support across storage, endpoints, secrets, S3 targets and logs,
  with `require_cmk`.
- Contract outputs: `source_prerequisites`, `network_contract`,
  `account_prerequisites`, `verify_commands`,
  `task_settings_json`, `governance`.
- Account-wide service roles (`dms-vpc-role`, `dms-cloudwatch-logs-role`),
  off by default (`create_account_service_roles`).
- Advisory checks, 19 in all, accepted individually with `acknowledged_checks`
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
- `kms_key_policy_requirements` entries carry the contract v2 fields (`sid`,
  `principals`, `conditions`, `purpose`), so `modules/kms` can compile them
  into key policies; existing fields unchanged.
- `log_group_skip_destroy` (default `true`): teardown keeps the task log group.
- Output `task_resource_ids`.

Runtime safety (from a review of what plans cleanly and then fails in DMS):

- `settings.stop_before_cached_changes` (`StopTaskCachedChangesNotApplied`):
  pause a full-load-and-cdc task after the load, before cached changes apply,
  to build the indexes CDC needs.
- `settings.fail_on_open_transaction` (default `true`) and
  `settings.transaction_consistency_timeout` (default 600): an Oracle
  transaction still open at CDC start fails the task instead of being skipped.
- Check `account_service_roles_exist`: looks up `dms-vpc-role` and
  `dms-cloudwatch-logs-role` and warns when either is missing. Without the
  logs role a task runs with an empty log group. Needs `iam:ListRoles` on the
  plan principal. With a Redshift target it also requires
  `dms-access-for-endpoint`.

Notifications and account prerequisites:

- `notification_requirements`: the SNS topic-policy statements DMS
  (`dms.amazonaws.com`), CloudWatch alarms (`cloudwatch.amazonaws.com`) and,
  in serverless mode, EventBridge (`events.amazonaws.com`) need, each scoped by
  `aws:SourceArn`. Also a test command.
- `sns_topic_kms_key_arn`: an SSE-KMS topic's key. `kms_key_policy_requirements`
  then lists the publishers that need `kms:GenerateDataKey*` and `kms:Decrypt`
  on it.
- Serverless mode: an EventBridge rule (source `aws.dms`, category `Failure`,
  this migration's replication config ARNs) forwards replication failures to
  `sns_topic_arn`. The serverless check now says what is still missing:
  latency alarms and a log group.
- `verify_commands.arm_alarms`: resets each CDC alarm to OK when a task
  starts. A CDC alarm on a task that has never run is already in ALARM, and an
  alarm only notifies on a change of state. The RUNBOOK names it as a step.
- `account_prerequisites`: `dms-access-for-endpoint` with a Redshift target
  (created by `create_account_service_roles`, with `AmazonDMSRedshiftS3Role`),
  and `AWSServiceRoleForDMSServerless` in serverless mode or with
  premigration assessments. The assessment operator permissions add
  `iam:CreateServiceLinkedRole`.
- `deployer_requirements`: the Athena, Glue and S3 permissions S3 target
  validation needs on the principal that creates the task.

S3 targets:

- `glue_catalog_generation = true` adds the Glue, Athena and S3 read
  permissions the DMS documentation lists to the target's role.

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

- PostgreSQL endpoints are replaced when their `postgres` block changes.
  Provider 5.x sends `postgres_settings` on create only, so an edit to
  `after_connect_script` or the heartbeat applied cleanly, changed nothing in
  DMS, and planned the same diff forever. The replacement also replaces every
  task on the endpoint; set the block before the first apply.
- With `batch_apply_enabled`, data and apply errors render `SUSPEND_TABLE`. Under
  `LOG_ERROR` one bad row switched the task to one-by-one apply for good.
  `batch_apply_enabled` with `lob_mode` `FULL` or `INLINE` is refused.
- `source_prerequisites`: Oracle now lists `CREATE SESSION`, `SELECT` on the
  migrated tables, `LOGMINING`, `DBMS_CRYPTO` for validation and ALL COLUMNS
  supplemental logging for keyless tables; PostgreSQL lists `rds_superuser` and
  a primary key on every captured table (DMS ignores UPDATE and DELETE without
  one).
- The isolated example creates primary keys in pre-data, not post-data: CDC
  starts applying as each table finishes loading, and without a key every
  UPDATE and DELETE is a full scan. Oracle `DATE` columns are `timestamp(0)`.
- The Oracle example sets `after_connect_script` on the target, whose foreign
  keys otherwise reject the parallel full load. The serverless example no
  longer sets `slot_name`, which needs a pre-created slot and a CDC start
  position serverless cannot take.
- RUNBOOK: reloading a table under `DO_NOTHING` truncates it first and needs a
  running task; `RecoverableErrorCount = -1` is described as the DMS default
  (bounded retries for most errors), not retry forever; the privilege for
  `session_replication_role` is named.
- Comments and documentation no longer claim `database_name` reaches DMS on the
  secret path for the MySQL family: the provider does not send it there.
- Validator logging uses `VALIDATOR_EXT`, the component id DMS stores and
  returns. A component DMS drops would show as a diff on every plan, and every
  applied diff stops a running task.
- `apply_error_max` now acts: above 0 it sets `ApplyErrorEscalationPolicy` to
  `STOP_TASK`. Under the previous `LOG_ERROR`, reaching the count changed
  nothing.
- Endpoints are ordered after their roles' inline policies, not only the
  roles. A task started on the first apply could otherwise race the secret
  policy.
- `network_contract.required_egress` names the endpoint and what to fill in
  when `server_name` or `port` is unset, instead of printing `:0`. Its notes
  add the Secrets Manager endpoint override for private subnets and the rule
  that VPC endpoint subnets match the replication subnet group.
- The `oracle_ssl_uses_a_wallet` check no longer warns about sensitive values
  when `certificates` is passed as sensitive.
- `source_prerequisites` (PostgreSQL) lists the heartbeat schema. The
  `table_mappings` description warns that `_` is a single-character wildcard.
- RUNBOOK: re-arm the alarms and check the notification path at the first
  start; adopt a kept `dms-tasks-<name>` log group with an `import` block
  before re-applying under the same name.

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
- **BREAKING (default):** `s3_targets[*].cdc_path` defaults to `""` instead of
  `"cdc"`. DMS does not support CdcPath with date partitioning (the default) or
  Glue catalog generation; that combination is now refused at plan.
- **BREAKING (default):** `FailOnTransactionConsistencyBreached` is `true`
  (was `false`). See `settings.fail_on_open_transaction`.
- **BREAKING (validation):** `docdb` and `neptune` endpoints are refused.
  Provider 5.x drops the Secrets Manager fields for them, so they reached DMS
  without credentials.
- **BREAKING (default):** `endpoints[*].postgres.execute_timeout` defaults to
  60 (the DMS default) instead of 0. The provider sent 0 for the old unset
  value.
- **BREAKING (default):** `instance_event_categories` adds `failover`.
- **BREAKING (validation):** `batch_apply_enabled` into an S3 target is
  refused. DMS does not support it there and documents possible data loss.
- `log_retention_is_bounded` also warns with `create_log_group = false`: the
  module then applies no retention, and the check certified one. The new
  `governance.log_group_managed_by_module` says whether `log_retention_days`
  is applied to anything.
- RUNBOOK section 6a corrects what a replaced instance does to its tasks:
  `publicly_accessible` and `availability_zone` changes fail at apply unless
  the tasks are replaced in the same run, because DMS will not delete an
  instance that still has tasks. The descriptions of `kms_key_arn`,
  `publicly_accessible` and `availability_zone` now say they replace.
- **BREAKING (removed):** `sql_scripts`, `output.migration_plan` and the
  check `the_target_schema_comes_from_somewhere`. The module never ran the
  scripts, and whatever does run them keeps its own record of what it
  executed; a second copy here was a manifest nobody read. In their place:
  `governance.tasks_expecting_a_prebuilt_target` (every `DO_NOTHING` task, from
  the merged settings) and `verify_commands.start_task`.
- Check `raw_overrides_use_known_task_settings` and
  `governance.tasks_with_unknown_task_settings`: a `raw_overrides` section or
  key outside the DMS-documented list is reported at plan, because DMS drops
  it silently. The list (`known_task_settings` in locals.tf) is kept equal to
  the linter's by a self-tested drift check; both gained the documented keys
  they lacked (`DataMaskingErrorPolicy`, `MaxKeyColumnSize`, `RecoveryTimeout`,
  `EnableLogContext`, `DeleteTaskLogs`, `ResyncSettings`, the Time Travel
  keys, the resync log components).
- `aws_dms_certificate` ids carry an 8-character digest of the content and
  the resource is `create_before_destroy`: rotating a CA under the same key
  uploads the new certificate, repoints the endpoints and deletes the old one
  in one apply. Before, Terraform deleted the in-use certificate first.
- Serverless mode refuses endpoints DMS Serverless does not support: SAP ASE,
  Db2 as a target, Db2 with SSL (DMS Serverless documentation). They applied
  and failed at Testing Connection.
- Tests: three runs that passed for the wrong reason now trip only the guard
  they name; the guards for `availability_zone` with `multi_az`, `require_cmk`
  on S3 targets and in serverless mode, and the `transport_is_verified` check
  have failing-case runs; every check's acknowledgement branch is tested; every
  variable with a validation has at least one failing-case run; four asserts
  that compared a value to itself or to a shared mock are replaced with
  identity checks.
- Table mappings are checked at plan against the DMS table-mapping
  documentation (precondition on the subnet group, naming the task and
  `rule-id`): rule types, selection/transformation actions and targets,
  object-locators, wildcard restrictions, table-settings shapes, numeric
  `rule-id`s, unique `rule-name`s, exclude-only mappings. The linter gained the
  same rules; its action list lacked ten documented actions (`add-prefix`,
  `include-column`, the suffix/prefix family, the data-masking family), which
  it reported as unknown. `known_mapping_rules` in locals.tf and the linter's
  `MAPPING_RULES` are kept equal by a self-tested drift check.
- `tests/fixtures/*.json` are now compared with the live rendering by
  `tests/task_settings.tftest.hcl`; they had drifted on
  `FailOnTransactionConsistencyBreached` and are regenerated.
- `permissions_boundary_arn` no longer applies to `dms-vpc-role` and
  `dms-cloudwatch-logs-role`, whose AWS-managed policies a landing-zone
  boundary could cap silently.
