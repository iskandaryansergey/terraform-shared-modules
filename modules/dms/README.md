# terraform-aws-dms

Database migration on AWS DMS for a regulated estate: an isolated VPC with no
internet path, AWS access over VPC endpoints, hybrid connectivity to an
on-premises source, and a private Aurora target.

It builds the replication instance (or serverless capacity), endpoints, tasks
with typed settings, validation-only tasks, premigration assessments, a manifest
for the SQL either side of the data, and the alarms for the failure that
matters: a CDC task that stops while everything still looks green.

```hcl
module "migration" {
  source  = "app.terraform.io/citadel-hub/dms/aws"
  version = "~> 1.0"

  name               = "core-to-aurora"
  subnet_ids         = var.private_subnet_ids # two AZs minimum, routed to both databases
  security_group_ids = [var.dms_sg_id]

  kms_key_arn    = var.cmk_arn
  require_cmk    = true
  engine_version = "3.5.3" # pin it; see auto_minor_version_upgrade below

  certificates = {
    # Oracle verifies against a wallet (base64 of cwallet.sso), not a PEM.
    onprem-wallet = { wallet = filebase64("${path.module}/cwallet.sso") }
    rds-ca        = { pem = file("${path.module}/rds-ca.pem") }
  }

  endpoints = {
    src = {
      role               = "source"
      engine             = "oracle"
      server_name        = "oracle-prod.internal" # feeds network_contract only
      port               = 1521                   # same
      database_name      = "CORE"                 # always sent to DMS
      secret_arn         = var.source_secret_arn  # DMS's own user: host, port, username, password
      secret_kms_key_arn = var.secret_key_arn
      ssl_mode           = "verify-ca"            # the strongest mode DMS supports on Oracle
      certificate_key    = "onprem-wallet"
    }
    tgt = {
      role               = "target"
      engine             = "aurora-postgresql"
      database_name      = "core"
      secret_arn         = var.target_secret_arn
      secret_kms_key_arn = var.secret_key_arn
      ssl_mode           = "verify-full"
      certificate_key    = "rds-ca"
      postgres = {
        after_connect_script = "SET session_replication_role = replica;"
      }
    }
  }

  sql_scripts = {
    pre_data = [{
      name   = "01-schema"
      path   = "sql/01-schema.sql"
      sha256 = filesha256("${path.module}/sql/01-schema.sql")
    }]
    post_data = [{
      name   = "02-constraints"
      path   = "sql/02-constraints.sql"
      sha256 = filesha256("${path.module}/sql/02-constraints.sql")
    }]
  }

  tasks = {
    core = {
      source_endpoint = "src"
      target_endpoint = "tgt"
      migration_type  = "full-load-and-cdc"
      table_mappings  = file("${path.module}/mappings/core.json")
      start           = false # start it deliberately
    }
  }

  sns_topic_arn = var.alerts_topic_arn
}
```

Hand the module's contract outputs to the teams that act on them by re-exporting
them as root outputs of the workspace (or reading them with `tfe_outputs`):
`source_prerequisites` goes to the DBA team, `network_contract` and
`replication_instance_private_ips` to the network team, `account_prerequisites`
to whoever owns IAM, `kms_key_policy_requirements` to the key owners, and
`migration_plan` to the pipeline that runs the SQL.

## Requirements

| Component | Supported | What a workspace must do |
|---|---|---|
| Terraform | `>= 1.9.0` | Set the workspace's Terraform version to 1.9 or later. Conditions use ternaries because 1.9 evaluates both sides of `\|\|` and `&&` |
| `hashicorp/aws` | `>= 5.70.0, < 6.0.0` | Commit the `.terraform.lock.hcl` for a 5.x provider; the module is validated on 5.100.0. A 6.x provider is not supported |
| Account | `dms-vpc-role` and `dms-cloudwatch-logs-role` | Fixed names, one set per account. Create them once in the landing zone, or set `create_account_service_roles = true` in exactly one module. `output.account_prerequisites` says which are missing |
| Network | VPC endpoints for `secretsmanager`, `kms`, `logs`, `sns` as used; an `s3` gateway endpoint for an S3 target | The module creates no network resources. `output.network_contract` lists what the configuration needs |

## What the module refuses

These fail at plan, with a message naming the field. Each one is a
configuration DMS would accept and then get wrong, or fail at apply or at the
first task start.

| Refused | Because |
|---|---|
| `username`/`password` on an endpoint, or a password in `extra_connection_attributes` | They reach state and `DescribeEndpoints` in plaintext. Use `secret_arn`, or set `allow_plaintext_credentials = true` |
| `ssl_mode` of `none` or `require` | Cleartext or unverified. Needs `allow_insecure_transport = true`. SQL Server's only encrypted modes are `require` and `verify-full`, so on SQL Server `verify-full` is the path that needs no acknowledgement |
| `verify-ca` or `verify-full` with no certificate | Nothing to verify against |
| An `ssl_mode` DMS does not support for the engine | See the table below |
| A PEM certificate on an Oracle endpoint | Warns (`oracle_ssl_uses_a_wallet`): DMS expects an Oracle wallet in `certificates[*].wallet` |
| `TRUNCATE_BEFORE_LOAD` or `DROP_AND_CREATE` | Needs `allow_destructive_target_prep = true`. The gate reads the merged settings, so `raw_overrides` cannot slip past it |
| A table mapping with no selection rule, or duplicate `rule-id`s | The task completes successfully having moved nothing |
| A task using an endpoint that does not exist, or in the wrong direction (including an S3 target as a source) | Terraform would otherwise fail on a map lookup |
| Full LOB mode (`lob_mode` `FULL` or `INLINE`) into an S3 target | DMS does not support it. Use `LIMITED` with `lob_max_size_kb` above the largest LOB |
| `cdc_start_time` or `cdc_start_position` in serverless mode | `aws_dms_replication_config` has no such argument, so it would be dropped. Start with `aws dms start-replication --cdc-start-position` |
| A CDC start point on a task that never reads changes | Silently ignored |
| `require_cmk` without a customer key on storage, every endpoint, every S3 target, the assessment, and the module-created task log group | DMS would fall back to an AWS-managed key. With `create_log_group = false` or `log_retention_days = 0`, DMS creates the log group itself with the AWS-managed key |
| `publicly_accessible` | Needs `allow_public_replication_instance = true` |
| `validation_tasks` or `premigration_assessment` in serverless mode | Both run on a replication instance |
| A `validation_tasks` entry whose mode is `cdc` against a parent that never reads changes, whose parent DMS cannot validate, or whose key collides with a task | The validator could not run |
| Duplicate keys across `endpoints` and `s3_targets` | Tasks look both up by one key |

### SSL modes per engine

DMS supports a different set of modes per engine. The module refuses the rest at
plan rather than at endpoint create or connection test.

| Engine | `ssl_mode` |
|---|---|
| `oracle`, `db2`, `db2-zos` | `none`, `verify-ca`. On Oracle, `verify-ca` needs a wallet (`certificates[*].wallet`) |
| `mysql`, `mariadb`, `aurora` | `none`, `verify-ca`, `verify-full` |
| `sqlserver` | `none`, `require`, `verify-full` |
| `sybase` | `none`, `verify-full` |
| `redshift` | `none` (DMS reaches it through S3) |
| `postgres`, `aurora-postgresql`, `docdb`, `neptune` | any |

The default is `verify-full`, so an Oracle, Db2, Db2 z/OS, SAP ASE or Redshift
endpoint must set `ssl_mode` explicitly.

### Advisory checks

Eighteen `check` blocks warn without refusing. Each is silenced by naming it in
`acknowledged_checks`, and the decision is then listed in `output.governance`
for a reviewer. All are silent when `create = false`.

| Check | Warns when |
|---|---|
| `somebody_hears_a_failed_task` | tasks exist and there is no `sns_topic_arn` |
| `serverless_replication_is_not_watched_by_this_module` | `compute_mode = "serverless"` |
| `control_tables_have_their_own_schema` | a task writes DMS control tables to the target's default schema |
| `debug_logging_is_temporary` | a task logs at DEBUG or DETAILED_DEBUG in its merged settings |
| `the_target_schema_comes_from_somewhere` | `DO_NOTHING` with no `pre_data` script |
| `the_full_load_is_not_fighting_the_targets_constraints` | a PostgreSQL target has no `after_connect_script` |
| `the_storage_alarm_leaves_room_to_react` | the free-storage threshold is under 15% of `allocated_storage_gb` |
| `cdc_tasks_are_validated` | validation is off in a task's merged settings |
| `tasks_write_logs` | logging is off in a task's merged settings |
| `log_retention_is_bounded` | `log_retention_days = 0` |
| `replication_survives_an_az` | single-AZ |
| `full_load_does_not_leave_the_meter_running` | every task is full-load only on a provisioned instance |
| `engine_version_is_pinned` | `engine_version` is empty |
| `credentials_are_not_in_state` | an endpoint holds a plaintext credential |
| `transport_is_verified` | an endpoint uses `ssl_mode = "none"` |
| `minor_upgrades_do_not_fight_the_pin` | `engine_version` is pinned and `auto_minor_version_upgrade` is on |
| `oracle_ssl_uses_a_wallet` | an Oracle endpoint verifies with a PEM instead of a wallet |
| `validation_is_claimed_where_it_cannot_run` | validation is on for a task DMS cannot validate (below) |

## The migration is three phases; DMS owns one

```
pre_data        schemas, tables, types, sequences          your pipeline
   |            (DMS creates none of it under DO_NOTHING)
   v
assessment      premigration assessment, gated              your pipeline
   v
full load -> CDC                                            DMS
   |            triggers and FKs inert via after_connect_script
   v
post_data       indexes, FKs, constraints, grants           your pipeline
   v
cutover         stop writes > drain CDC > stop task >       RUNBOOK section 6
                validation-only run > reset sequences >
                repoint
```

`sql_scripts` records the SQL either side as a **manifest** (name, path,
`filesha256()`), and `output.migration_plan` emits the ordered sequence with
those checksums, so a change record can state which version of which script
ran. The module does not execute any of it: running DDL against a private Aurora
from an apply needs network reachability into the isolated VPC and credentials on
the runner, and it makes a schema change a side effect of a Terraform run.

The one hook DMS has is `postgres.after_connect_script` on a PostgreSQL target.
`SET session_replication_role = replica;` runs on every connection DMS opens, so
triggers stay quiet and foreign keys stop rejecting rows that arrive parent-last
during the load. It affects DMS's sessions only; nothing needs restoring
afterwards. The DMS database user needs the privilege to set it.

## Behaviour to know about

**Secrets carry host, port and credentials, not the database.** With
`secret_arn` set, DMS reads host, port, username and password from the secret
and the provider rejects `server_name` and `port` as conflicting, so the module
does not send them. It still takes them, because `network_contract` is built
from them and the firewall request needs a host and a port. `database_name` is
always sent from the endpoint, because the secret does not carry it and Oracle
needs it (SID or service name). Give DMS **its own database user and its own
secret**: the RDS/Aurora-managed master secret is not usable by DMS.

**Defaults that differ from the provider.**

| Input | Default | Why |
|---|---|---|
| `multi_az` | `true` | A single-AZ instance that fails mid-load restarts the load from zero |
| `auto_minor_version_upgrade` | `false` | With a pinned `engine_version`, an automatic minor upgrade makes every later plan try to set the old version back, which DMS refuses. Take minor versions by raising `engine_version` outside a cutover window |
| `alarm_free_storage_bytes` | `0` | 0 means 15% of `allocated_storage_gb`, rounded up, so the threshold follows the volume |
| `log_group_skip_destroy` | `true` | Teardown keeps the task log group; it still expires logs after `log_retention_days` |
| `start` (per task) | `false` | Applying a plan never begins writing to a target |
| `ssl_mode` | `verify-full` | See the engine table |

**Validation is reported where it can actually run.** DMS accepts
`EnableValidation = true` on any task and does nothing on a pair it cannot
validate. It validates Oracle, PostgreSQL-compatible, MySQL-compatible, SQL
Server and Db2 LUW sources, to the same targets plus Redshift, and S3 only as
parquet with a timestamp column and a day-level date partition. The module
computes this per task: `governance.tasks_whose_validation_cannot_run` lists the
tasks where validation is on but cannot run, and the check
`validation_is_claimed_where_it_cannot_run` warns. Reconcile those another way.

**Validation-only tasks.** `validation_tasks` compares the source and target of
an existing task without migrating anything. Each inherits the parent's
endpoints and mappings, always renders `TargetTablePrepMode = DO_NOTHING` and
`ValidationOnly = true`, and runs `full-load` (one pass) or `cdc` (needs a
parent that reads changes). Provisioned only. Run a full-load one just before
cutover and attach its `describe-table-statistics` output to the change record
(RUNBOOK section 6).

**Validation alarms.** `ValidationFailedOverallCount` and
`ValidationSuspendedOverallCount` alarm for every task that validates and every
validation-only task (`create_validation_alarms`,
`alarm_validation_failed_records`). Missing data is not breaching there: a task
that validated everything and stopped publishes nothing, which is the good
outcome.

**Premigration assessment.** With `premigration_assessment.enabled`, the module
creates the role DMS writes reports with (trust `dms.amazonaws.com` plus
`aws:SourceAccount`; S3 write on the bucket folder, list on the bucket, and KMS
through S3 when a key is set) and `output.premigration_assessment` carries the
start, status and report location per task. The provider has no resource for an
assessment run, so a gated pipeline step executes the command. It always passes
`--result-encryption-mode`: `SSE_KMS` with `kms_key_arn`, else `SSE_S3`.
Provisioned only.

**CDC alarms use the task resource ID.** CloudWatch publishes task metrics
under the last segment of the task ARN as `ReplicationTaskIdentifier`, not the
task name. `output.task_resource_ids` has the IDs and `verify_commands.cdc_latency`
uses them. Latency alarms treat missing data as breaching, so a stopped task
alarms instead of showing INSUFFICIENT DATA.

**Key policies are the key owner's.** The module uses customer keys but cannot
write their policies. `output.kms_key_policy_requirements` lists what each key
has to allow: replication storage, endpoint keys, the CloudWatch Logs grant with
its encryption context for `dms-tasks-<name>`, the secret keys for the secret
roles, S3 target keys and the assessment key. A missing Logs grant fails the log
group create part way through the apply.

**Role trust.** The endpoint-secret and S3-target roles trust DMS with
`aws:SourceAccount` and `aws:SourceArn` of `arn:<partition>:dms:<region>:<account>:*`,
the form AWS documents. The secret role trusts the regional principal
(`dms.<region>.amazonaws.com`), which Secrets Manager requires. The assessment
role carries no `aws:SourceArn`.

**An apply can stop a running task.** The provider stops a task to change
almost anything, and resumes it afterwards only if `start_replication_task` is
`true`. Lock the HCP Terraform workspace for the migration (RUNBOOK section 6a).
The reverse also holds: a task left at `start = true` after you stopped it on
purpose is resumed by the next apply that modifies it.

**On-premises hostnames need a resolver.** In an isolated VPC the VPC resolver
has no path to your DNS servers, so a corporate hostname returns nothing and the
connection test times out in a way that reads like a firewall problem. That is
[`terraform-aws-route53-resolver`](https://github.com/ivasik-k7/terraform-shared-modules/tree/dms-v1.0.0/modules/route53-resolver),
not this module; build it first.

**The source database has homework.** `source_prerequisites` returns it per
engine. The worst is Oracle supplemental logging: without it an `UPDATE`
arrives with no way to identify the row.

**A replication slot outlives the task.** A PostgreSQL source keeps WAL for an
inactive slot; the source fills its disk. The module sets a heartbeat to keep
the slot advancing; dropping the slot afterwards is yours (RUNBOOK section 7).

### Compute modes

| | `provisioned` | `serverless` |
|---|---|---|
| Replication | one instance, one `aws_dms_replication_task` per task | one `aws_dms_replication_config` per task, DCU-scaled |
| Alarms, event subscriptions, task log group | yes | none |
| `validation_tasks`, `premigration_assessment` | yes | refused |
| `cdc_start_time`, `cdc_start_position` | yes | refused |
| Cost floor | the instance, until deleted | `min_dcu`, around the clock |

## Examples

| Example | Shows |
|---|---|
| [`isolated-vpc-onprem-to-aurora`](https://github.com/ivasik-k7/terraform-shared-modules/tree/dms-v1.0.0/modules/dms/examples/isolated-vpc-onprem-to-aurora) | The regulated case: Oracle on-prem over Cloud WAN verified with a wallet (`verify-ca`), private Aurora, pre/post-data SQL with identity columns and a sequence reset, a validation-only task, premigration assessment, and the firewall request as an output |
| [`oracle-to-aurora-postgresql`](https://github.com/ivasik-k7/terraform-shared-modules/tree/dms-v1.0.0/modules/dms/examples/oracle-to-aurora-postgresql) | The same migration in a simpler network, with batch apply |
| [`serverless-cdc-to-s3`](https://github.com/ivasik-k7/terraform-shared-modules/tree/dms-v1.0.0/modules/dms/examples/serverless-cdc-to-s3) | Continuous CDC into a lake on serverless compute: parquet, day-partitioned, `LIMITED` LOBs because DMS does not support full LOB mode for S3 |

## Most-used inputs

The registry's Inputs tab is the reference; descriptions in `variables.tf` are
written to be read there.

| Name | Default | Notes |
|---|---|---|
| `name` | required | Prefixes every resource; also the log group suffix |
| `subnet_ids`, `security_group_ids` | required | Two AZs minimum, routed to both databases; egress only |
| `compute_mode` | `"provisioned"` | `"serverless"` is not watched by this module |
| `endpoints` | `{}` | `secret_arn` is the credential path; `ssl_mode` is validated per engine |
| `s3_targets` | `{}` | S3 is a separate resource with its own shape |
| `certificates` | `{}` | `pem` or `wallet`; referenced by `certificate_key` |
| `tasks` | `{}` | Typed settings; mappings validated at plan |
| `validation_tasks` | `{}` | Validation-only tasks over an existing task |
| `premigration_assessment` | disabled | Role plus per-task commands; provisioned only |
| `sql_scripts` | `{}` | Pre/post-data manifest with checksums |
| `kms_key_arn`, `require_cmk` | `""`, `false` | Storage, endpoints, logs |
| `multi_az`, `engine_version` | `true`, `""` | Pin the version; minor upgrades are off by default |
| `sns_topic_arn` | `""` | Without it nothing is watching |
| `acknowledged_checks` | `[]` | Advisory checks you have decided to live with |
| `allow_plaintext_credentials`, `allow_insecure_transport`, `allow_destructive_target_prep` | `false` | Each acknowledges one refusal |

## Outputs

| Name | Use |
|---|---|
| `migration_plan` | The ordered phases with script checksums; hand to the pipeline |
| `source_prerequisites` | Per source engine, what the DBA team must change before CDC works |
| `network_contract` | Subnets, endpoints, egress, DNS and return-path notes; hand to the network team |
| `account_prerequisites` | The two fixed-name IAM roles DMS needs |
| `kms_key_policy_requirements` | What each customer key's policy must allow; hand to the key owners before the first apply |
| `governance` | The effective posture from the merged settings, including `acknowledged_checks` |
| `verify_commands` | Connection test, task status, and per-task CDC latency, validation state, failed tables and stop commands |
| `premigration_assessment` | Per-task start, status and report commands; `null` unless enabled |
| `task_settings_json` | The rendered settings per task, for a change review |
| `replication_instance_arn`, `replication_instance_id` | The instance; `null` in serverless mode |
| `replication_instance_private_ips` | What the source and target firewalls must allow |
| `replication_subnet_group_id` | The subnet group |
| `task_arns`, `task_ids` | Per task; empty in serverless mode |
| `task_resource_ids` | Per task, the CloudWatch `ReplicationTaskIdentifier` |
| `validation_task_arns` | Per validation-only task |
| `serverless_replication_arns` | Per serverless replication config; empty in provisioned mode |
| `endpoint_arns` | Per endpoint, including S3 targets |
| `certificate_arns` | Per certificate the module uploaded |
| `endpoint_secret_role_arns`, `s3_target_role_arns` | The roles DMS assumes, per endpoint or target |
| `log_group_name` | The task log group; `null` in serverless mode |

## Limits

- **The module has not been exercised against real AWS.** Behaviour comes from
  the provider schema, the DMS documentation and mocked plan tests. Run the
  first soak with `verify_commands.verify_endpoint_coverage` to confirm that
  DMS publishes `CDCLatencyTarget` under the instance and task resource ID
  dimensions the alarms use.
- **The SSL-mode table and the validation support matrix follow the DMS
  documentation.** DMS changes both between engine versions; recheck them when
  you raise `engine_version`.
- **Premigration assessment commands, the assessment role's trust and the KMS
  requirements have not been run.** The assessment role carries only
  `aws:SourceAccount`, because what DMS presents for an assessment run is not
  documented closely enough to pin.
- **Serverless has no observability here**: no alarms, no event subscriptions,
  no log group, no validation-only tasks and no assessment.
- **Scope.** Relational engines (`aurora`, `aurora-postgresql`, `mariadb`,
  `mysql`, `oracle`, `postgres`, `sqlserver`, `db2`, `db2-zos`, `sybase`,
  `redshift`) and S3 targets are typed and tested. `docdb` and `neptune` are
  accepted as endpoint engines with no engine-specific handling: no
  `source_prerequisites`, validation cannot run, and only
  `extra_connection_attributes` reaches DMS for their settings. Kafka, Kinesis,
  MongoDB, OpenSearch, DynamoDB and Redis endpoints are not supported.
- **The module runs no SQL.** `sql_scripts` is a manifest.
- **Account-wide roles are not created by default.**
- **Schema conversion is out of scope.** DMS moves data; the target schema is
  yours.
- **Validation compares rows, not everything.** LOBs are skipped by default and
  nothing the mappings excluded is checked.
- **`LoopbackPreventionSettings` is not typed**, so a bidirectional rollback
  configuration needs `raw_overrides`.
- **Credential rotation is not picked up mid-task.** DMS caches the credential
  at connection time.

## Versioning and support

Semantic versioning, tagged `dms-vX.Y.Z`. A major release is anything that
changes what an unchanged configuration plans: a removed or renamed input or
output, a new required input, a changed default, a change that turns an update
into a replacement, a changed resource address, or a raised Terraform or
provider floor. Minor releases add optional inputs, outputs, checks and alarms;
patches change no plan. A deprecated input keeps working until the next major
release, and `moved` blocks are never removed, so a workspace can skip versions.

Supported: Terraform `>= 1.9.0` and `hashicorp/aws` `>= 5.70.0, < 6.0.0`.

Tests: `terraform test` plan tests (`tests/`), `tests/lint_task_settings.py`
(unknown settings keys, contradictory LOB flags, mappings without a selection
rule, duplicate rule-ids) over the examples and the rendered settings in
`tests/fixtures/`, and `tests/lint_validations.py` (no validation puts a
throwing expression in a later `||` or `&&` operand).

| Document | Question |
|---|---|
| [RUNBOOK.md](https://github.com/ivasik-k7/terraform-shared-modules/blob/dms-v1.0.0/modules/dms/RUNBOOK.md) | How to run a migration on HCP Terraform, from first plan to teardown |
| [COSTS.md](https://github.com/ivasik-k7/terraform-shared-modules/blob/dms-v1.0.0/modules/dms/COSTS.md) | What it costs, and which line has no ceiling |
| [CHANGELOG.md](https://github.com/ivasik-k7/terraform-shared-modules/blob/dms-v1.0.0/modules/dms/CHANGELOG.md) | What changed in each version |
