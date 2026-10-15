# terraform-aws-dms: running a migration

The module builds the migration. This is how you run it on **HCP Terraform**
workspaces, from first plan to teardown. Commands run from AWS CloudShell (or
any shell with credentials for the migration account), not from the Terraform
run.

Read section 5 before you start. Rollback has to be built before cutover, not
after.

---

## 0. How this splits across workspaces

The migration has three phases and only one of them is Terraform's, so the split
that works is:

| Workspace | Owns | Run trigger | Apply mode |
|---|---|---|---|
| `dms-<name>-infra` | This module: instance, endpoints, tasks, validation tasks, alarms | VCS on the module directory | **Manual apply** |
| *(your pipeline)* | The pre-data and post-data SQL, and the gated assessment and validation steps | Manual, gated on the phase | Not Terraform |

There is no second "teardown" workspace: a workspace owns its state, and two
workspaces cannot share one. Teardown is a run in the `infra` workspace (see
section 7).

Three workspace settings matter more here than in a normal module:

- **Auto-apply OFF.** Always. An auto-applied plan during a CDC soak stops the
  task: see section 6a.
- **A run task or Sentinel policy** on the migration window, if you have one.
  Otherwise the freeze in section 6a is a human convention.
- **Workspace variables for secret ARNs, never secrets.** The module takes
  `secret_arn`, not a credential. Nothing sensitive belongs in a workspace
  variable here: DMS reads the credential itself and it never enters state or a
  plan.

State access: workspace state contains the endpoint configuration, the rendered
task settings and the ARNs. It does **not** contain database credentials on the
`secret_arn` path. It does if anyone sets `allow_plaintext_credentials = true`,
which is why that flag exists and defaults to false.

**DMS's database users.** DMS needs its own database user on each side, in its
own secret holding `host`, `port`, `username` and `password`. The RDS/Aurora
master secret cannot be used by DMS. The database name is not read from the
secret: it comes from `database_name` on the endpoint (for the MySQL family,
leave it empty). On a PostgreSQL target that uses `after_connect_script = "SET
session_replication_role = replica;"`, the DMS user needs the privilege to set
that parameter: `rds_superuser` on RDS and Aurora, or on PostgreSQL 15 and later
`GRANT SET ON PARAMETER session_replication_role TO <dms_user>;`. Check it before
the first start by running the statement as the DMS user.

**Set the `postgres` block before the first apply.** The provider never sends a
change to `postgres_settings` on an existing endpoint, so the module replaces
the endpoint when that block changes, and every task on it with it. Mid-migration
that is a new task starting from zero.

---

## 1. Before the first apply

The module cannot check any of this. All of it fails at runtime, most of it
after the full load has already run.

Re-export the contract outputs as root outputs of the `infra` workspace (or read
them with `tfe_outputs`), so they appear on the run's **Outputs** tab and can be
attached to the change record as text, not screenshots:

| Output | Goes to |
|---|---|
| `source_prerequisites` | the DBA team |
| `network_contract` | the network team |
| `account_prerequisites` | whoever owns IAM |
| `kms_key_policy_requirements` | the owner of each customer key |

Most of these are known at the first plan. Values that name created resources,
such as role ARNs, and `replication_instance_private_ips` (the firewall request)
are known only after the first apply.

Blocking items, in the order they bite:

1. **`dms-vpc-role` and `dms-cloudwatch-logs-role` exist in the account.** Fixed
   names, one set per account. Without the first, creating the subnet group
   fails with an error that names neither the role nor the fix.
2. **Every customer key's policy allows what `kms_key_policy_requirements`
   lists.** A missing CloudWatch Logs grant (with its encryption context for
   `dms-tasks-<name>`) fails the log group create part way through the apply.
3. **The source has done its homework.** Oracle supplemental logging fails
   *silently and wrongly* rather than loudly: without it an UPDATE arrives with
   no way to identify the row.
4. **The network is real.** Routes both ways, the on-prem hostname resolving
   from inside the VPC, both multi-AZ ENI addresses allowed through the on-prem
   firewall.
5. **The target schema exists**, because `target_table_prep_mode` defaults to
   `DO_NOTHING`. The pipeline builds it; the module runs no SQL, and
   `governance.tasks_expecting_a_prebuilt_target` names the tasks that depend
   on it.
6. **Transport is configured for the engine.** Oracle verifies with a wallet and
   `verify-ca`; the module refuses `verify-full` there. See the README's SSL
   table.

---

## 2. Apply, pre-data, connection test, assessment

The apply creates everything **stopped**. `start = false` is the default so that
approving a plan never begins writing to a target.

Then, before starting anything:

```bash
# 1. Pre-data, by your pipeline. By hand:
psql -h <target> -d <db> -v ON_ERROR_STOP=1 -f sql/01-pre-data-schema.sql
```

Record which version ran: your pipeline's own log of what it executed, or by
hand the `sha256sum` of the file, so the change record states which version was
applied rather than "the one in the repo at the time".

```bash
# 2. Can DMS reach both databases? A missed firewall rule or VPC endpoint
#    surfaces here, as a timeout rather than an error.
#    (verify_commands.test_connections is this, filled in.)
aws dms test-connection --replication-instance-arn <instance-arn> --endpoint-arn <endpoint-arn>
aws dms describe-connections \
  --filters Name=replication-instance-arn,Values=<instance-arn> \
  --query 'Connections[].[EndpointIdentifier,Status,LastFailureMessage]' --output table
```

### Premigration assessment (a gated step)

With `premigration_assessment.enabled`, the module creates the role and
`output.premigration_assessment.commands.<task>` holds the exact commands. Run
the assessment as a gate **before a task is started**, and attach the report to
the change record.

```bash
# start (the command always passes --result-encryption-mode)
<output.premigration_assessment.commands.core.start>

# status, until it reports completed
<output.premigration_assessment.commands.core.status>

# the report lands at commands.core.report: s3://<bucket>/<folder>/<name>/<task>/
```

The operator running these needs the permissions in
`output.premigration_assessment.operator_permissions`, including `iam:PassRole` on the
assessment role. A failed individual assessment (unsupported types, LOBs without
primary keys, missing privileges, supplemental logging) is a finding to fix on
the source or in the mappings, not a reason to start anyway. The assessment runs
against the task, so it is available in provisioned mode only.

---

## 3. The full load

```bash
aws dms start-replication-task --replication-task-arn <task-arn> \
  --start-replication-task-type start-replication
```

Then re-arm the CDC alarms (`verify_commands.arm_alarms.<task>`). A CDC alarm
on a task that has never run is already in ALARM, because no data counts as
breaching, and an alarm only notifies on a change of state. Setting it to OK
at start means a task that stalls before publishing a datapoint flips it back
to ALARM within 15 minutes, and that flip notifies. A task paused by
`stop_before_cached_changes` alarms the same way; that one is expected.

Before the first start, check the notification path: `notification_requirements`
lists the statements the topic policy needs, and `kms_key_policy_requirements`
what an encrypted topic's key needs. A topic that refuses DMS or CloudWatch
drops every notification while the subscriptions show as active.

Watch it **per table**. A task at 99% with one table erroring looks healthy in
the console:

```bash
watch -n 60 "aws dms describe-table-statistics --replication-task-arn <task-arn> \
  --query 'TableStatistics[?TableState!=\`Table completed\`].[SchemaName,TableName,TableState,FullLoadRows]' \
  --output table"
```

| What you see | What it means |
|---|---|
| `Table error` | The task continues; that table does not |
| Tables stuck at 0 rows | Usually a source permission gap (the DMS user lacks `SELECT` on the tables; the connection test does not read them), or a selection rule matching a schema name with different casing |
| Running, and the task log group is empty | `dms-cloudwatch-logs-role` is missing or cannot write (check `account_service_roles_exist`). Fix that first: nothing else here is diagnosable without the log |
| `FreeStorageSpace` falling | Cached changes accumulating. A full disk stops **every** task on the instance |

The target's triggers and foreign keys are inert for this phase because of
`postgres.after_connect_script = "SET session_replication_role = replica;"`. It
runs on every connection DMS opens, so it applies to DMS's sessions only and
nothing needs restoring afterwards. If the load fails on permissions at
connect, check that the DMS user may set that parameter.

---

## 4. Post-data, then the CDC soak

Run post-data once the full load completes: secondary
indexes, foreign keys, triggers, grants. Built now rather than during the load,
because index maintenance slows the load and foreign keys reject rows that
arrive parent-last. Primary keys are not in this list: they belong in pre-data,
because CDC applies changes from the moment each table finishes loading and
every UPDATE or DELETE on a table without a key is a full scan.

To build the secondary indexes CDC needs before any cached change is applied,
set `settings.stop_before_cached_changes = true`: the task stops after the full
load, you run post-data, then resume it (`--start-replication-task-type
resume-processing`).

Then watch the number the cutover window is made of. CloudWatch publishes task
metrics under the task **resource ID** (the last segment of the task ARN), not
the task name. `output.task_resource_ids` has it, and
`output.verify_commands.cdc_latency.<task>` is this command filled in:

```bash
aws cloudwatch get-metric-statistics --namespace AWS/DMS \
  --metric-name CDCLatencyTarget \
  --dimensions Name=ReplicationInstanceIdentifier,Value=<instance-id> \
               Name=ReplicationTaskIdentifier,Value=<task-resource-id> \
  --start-time $(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 3600 --statistics Average Maximum --output table
```

| Reading | Meaning |
|---|---|
| Flat and low (seconds) | The target keeps up. Cutover is a short window |
| Flat but high (minutes) | Keeping up; the window is that many minutes long |
| **Growing without bound** | The target will never catch up. Fix before planning a cutover: bigger instance, `batch_apply_enabled`, or fewer tables per task |
| **No datapoints at all** | The task has stopped. The latency alarms treat missing data as breaching for exactly this reason |

Do not plan a cutover until latency is stable across a **full business cycle**,
including the nightly batch. Keeping up all day and falling two hours behind at
02:00 means a two-hour window, not a two-minute one.

### What alarms, and what to do

Per CDC task: `cdc-latency-target` and `cdc-latency-source`. Per task that
validates, and per validation-only task: `validation-failed` and
`validation-suspended`. Per instance: free storage, CPU and freeable memory.

| Alarm | First move |
|---|---|
| `cdc-latency-source` | Usually the source: log contention, a long transaction, or an undersized instance |
| `cdc-latency-target` | The target or the apply path: `batch_apply_enabled`, instance class, target load |
| `validation-failed` | Rows differ. Detail is in the control schema's `awsdms_validation_failures` and in `describe-table-statistics` (`verify_commands.validation_state.<task>`) |
| `validation-suspended` | Validation could not compare rows or hit its failure limit. The evidence for those rows does not exist until it is re-run |
| `free-storage` | The threshold is 15% of `allocated_storage_gb` by default. Cached changes are accumulating: find the stalled side |

**First soak only: soak-test the alarms.** The alarms are built on dimensions
AWS publishes for DMS tasks, but this module has not run against a live
migration. After the first task starts:

```bash
# Does the account publish CDCLatencyTarget under the dimensions the alarms use?
# (verify_commands.verify_endpoint_coverage)
aws cloudwatch list-metrics --namespace AWS/DMS \
  --query 'Metrics[?MetricName==`CDCLatencyTarget`].Dimensions' --output json
```

The output should list `ReplicationInstanceIdentifier` and
`ReplicationTaskIdentifier` with your task's resource ID. If it returns nothing
while the task is running, the latency alarms cannot fire on data and will sit
in ALARM permanently (missing data is breaching); the usual cause in an isolated
VPC is a missing route for CloudWatch metrics, see `network_contract`.

---

## 5. Rollback has to exist before cutover

Once the application writes to the new target, the old source is stale. Rolling
back means moving those writes *back*, and DMS cannot do that retroactively
because the changes were never captured.

If the migration must be reversible, build the reverse path **before** cutover.
An endpoint carries one `role`, and the module refuses a task that reads from a
`target`, so this needs **four** endpoint entries, each database defined twice:

```hcl
endpoints = {
  oracle-src = { role = "source", engine = "oracle",            secret_arn = var.oracle_secret, ... }
  aurora-tgt = { role = "target", engine = "aurora-postgresql", secret_arn = var.aurora_secret, ... }

  # The same two databases, in the other direction.
  aurora-src = { role = "source", engine = "aurora-postgresql", secret_arn = var.aurora_secret, ... }
  oracle-tgt = { role = "target", engine = "oracle",            secret_arn = var.oracle_secret, ... }
}

tasks = {
  forward  = { source_endpoint = "oracle-src", target_endpoint = "aurora-tgt", migration_type = "full-load-and-cdc", ... }
  rollback = { source_endpoint = "aurora-src", target_endpoint = "oracle-tgt", migration_type = "cdc", start = false, ... }
}
```

Three things to settle before committing to it:

- **The old target becomes a CDC source.** Aurora then needs `wal_level =
  logical`, a replication slot and the `rds_replication` grant: the same
  homework the original source had, on the database you just migrated into.
- **Loopback prevention.** Without it the two tasks feed each other
  indefinitely. It lives in `LoopbackPreventionSettings`, which this module does
  not expose as a typed setting: use `raw_overrides` and have it reviewed.
- **Write credentials on the old source.** `oracle-tgt` needs a credential that
  can write to the system you are migrating away from. Different grant, and
  usually a different approval.

---

## 6. The cutover

The point of no return is step 9. Everything before it is reversible by doing
nothing.

```bash
# 1. Stop writes to the source. Maintenance mode, or revoke write permissions:
#    a "quiet" application is not a stopped one.

# 2. Wait for CDCLatencyTarget to reach ~0 and hold. This is the window.

# 3. STOP THE FORWARD TASK, before the application writes anywhere. While both
#    the application and DMS can write to the target, a late source change can
#    overwrite a newer application write: a silent corruption window.
aws dms stop-replication-task --replication-task-arn <task-arn>

# 4. Run a full-load validation-only task now, with the source quiet and the
#    target not yet written by the application. It compares every row at this
#    moment (validation_tasks entry, mode = "full-load"; its ARN is in
#    output.validation_task_arns). It changes nothing.
aws dms start-replication-task --replication-task-arn <validation-task-arn> \
  --start-replication-task-type start-replication
# Wait until the task has finished and stopped, then:
aws dms describe-table-statistics --replication-task-arn <validation-task-arn> \
  --query 'TableStatistics[].[SchemaName,TableName,ValidationState,ValidationPendingRecords,ValidationFailedRecords,ValidationSuspendedRecords]' \
  --output json > cutover-validation.json

# 5. Capture the rest of the evidence the change record needs.
aws dms describe-table-statistics --replication-task-arn <task-arn> \
  --query 'TableStatistics[].[TableName,Inserts,Updates,Deletes,ValidationState]' \
  --output json > cutover-table-stats.json
# Export output.governance from the workspace's Outputs tab (or the run's state
# version) into the change record.
# Anything not "Validated" is a question to answer now, while the source is
# still there to compare against. If governance.tasks_whose_validation_cannot_run
# lists the task, DMS cannot validate that pair: reconcile another way and say so.

# 6. Re-run the sequence reset. DMS migrates rows, not sequence positions, and
#    CDC has been adding rows since post-data ran. The application's first
#    insert fails on a duplicate key otherwise: the most common Oracle to
#    Aurora PostgreSQL cutover failure there is.
psql -h <target> -d <db> -v ON_ERROR_STOP=1 -f sql/03-post-data-sequences.sql

# 7. Start the rollback task, if you built one. It must be running BEFORE the
#    first application write lands, or the reverse stream has a gap.

# 8. Set start = false on the forward task (or remove it) in the module call,
#    and apply through the unlock-apply-lock routine in section 6a. See below.

# 9. Point the application at the target.   <-- point of no return
```

Nothing needs restoring on the target for `session_replication_role`: the load
guard applied to DMS's connections only.

**Why step 8 matters.** The provider resumes a stopped task with
`start_replication_task = true` after any modification of it. A forward task left
at `start = true` is silently restarted by the next apply that touches it, and
then writes old source changes over the application's data. The plan for that
apply should show only the `start` change; if it shows anything else on the task,
stop and read it.

Do not delete anything yet. Keep the source readable and the tasks in place
until the new target has survived a full business cycle.

---

## 6a. The apply freeze

**A Terraform apply stops a running task. Treat this as a freeze rule.**

The AWS provider stops a replication task to modify almost any argument, and
resumes it only if `start_replication_task = true`. This module defaults that
to `false`, deliberately, so an apply never starts a migration, and tasks are
started by CLI. Together that means an apply touching the task resource **stops
CDC and leaves it stopped**.

Everything here is enough to trigger it, because they all feed the rendered
settings JSON:

`table_mappings` / `log_level` / `validation_threads` / `lob_max_size_kb` /
`commit_rate` / `control_schema` / `migration_type` / `cdc_start_time` /
any `raw_overrides` edit

Terraform cannot warn you: the provider never reads `start_replication_task`
back, so state says `false` while the task runs.

**On HCP Terraform, enforce it with workspace settings, not discipline:**

- **Auto-apply off** for the whole migration. Non-negotiable.
- **Lock the workspace** (Settings, Lock) between full-load start and cutover.
  A locked workspace refuses runs, which is the only mechanism that survives
  someone merging a tidy-up PR on a Friday.
- If you use run tasks or Sentinel, gate on the lock reason so the refusal
  explains itself.

Unlock, apply, re-lock: deliberately, inside the window, with the task stopped.

**What a change does to the instance and the tasks.** Read the plan, then
decide whether it belongs in a cutover window:

| Change | Effect |
|---|---|
| `subnet_ids` | In-place update of the subnet group |
| `kms_key_arn` on an endpoint, or the module's `kms_key_arn` (which endpoints inherit) | Immutable on the endpoint, and a task's endpoint ARNs are immutable on the task: **replaces the endpoints and the tasks that use them**, and the replication instance too when it is the module key. The tasks are destroyed first, so this applies cleanly; the CDC position is lost |
| `publicly_accessible` or `availability_zone` | Replaces the instance - and **the apply fails** unless the tasks are replaced in the same run. The provider changes a task's `replication_instance_arn` in place, so Terraform deletes the old instance before it touches the tasks, and DMS refuses to delete an instance that still has tasks (`InvalidResourceStateFault`). Replace every task of the module in that apply, which makes Terraform destroy them first: `terraform apply -replace='module.<name>.aws_dms_replication_task.this["<task>"]'` (one `-replace` per task, `aws_dms_replication_task.validation` included). Cached changes and the CDC position are lost either way |
| `name` | Replaces everything, tasks first, so it applies cleanly - and starts the migration over |
| `certificates[*].pem` or `.wallet` (a CA rotation) | A new certificate is created first, the endpoints are repointed, then the old one is deleted - one apply, the tasks on those endpoints are updated in place. The certificate id carries a digest of the content, which is what makes this order possible |
| Serverless: the module's `kms_key_arn`, `serverless.availability_zone`, `name` | Replaces every replication config (`compute_config` keys are immutable). CDC starts over. Any other change to a task stops the replication and resumes it only if `start = true` |

Adopting a CMK mid-migration in response to a control finding is the realistic
way a replacement happens. Cutover-window only, with a plan to reload.

---

## 7. Teardown

A stopped task does not stop the instance. See
[COSTS.md section 5](COSTS.md#5-leaving-it-running): a forgotten `dms.c5.xlarge`
multi-AZ is $6,132/year at list price (see COSTS.md for the pricing date).

```bash
# What is still running and billing (verify_commands.what_is_still_billing).
aws dms describe-replication-instances \
  --query 'ReplicationInstances[].[ReplicationInstanceIdentifier,ReplicationInstanceClass,MultiAZ,InstanceCreateTime]' \
  --output table
```

**First, keep the evidence.** Do this before destroying anything:

1. Export the validation output, table statistics and `governance` captured at
   cutover (section 6), and the assessment reports in the assessment bucket.
2. Keep the task logs. `log_group_skip_destroy = true` (the default) leaves the
   `dms-tasks-<name>` log group and its logs in place when Terraform destroys
   the module; they still expire after `log_retention_days`. If your retention
   rule is longer than that, export them (for example
   `aws logs create-export-task`) or raise the retention first.

   The kept group also blocks the next apply under the same `name` (a
   rehearsal, then the real run): the create fails with
   ResourceAlreadyExistsException. Adopt it instead of deleting the logs:

   ```hcl
   import {
     to = module.dms.aws_cloudwatch_log_group.tasks[0]
     id = "dms-tasks-<name>"
   }
   ```
3. Drop the `dms_control` schema from the target **after** step 1:
   `awsdms_apply_exceptions` holds failed rows and their SQL.

**Then take the infrastructure down, in the same workspace.** A workspace's
state cannot be shared with a second workspace, so there is no separate
destroy-only workspace. Two real approaches, both reviewable and logged:

- **A pull request that sets `create = false`** on the module call. The
  speculative plan on the PR shows exactly what is removed, review approves it,
  and a manual apply removes the tasks, endpoints, instance and subnet group.
  The workspace and its history remain.
- **A destroy run** (Settings, Destruction and Deletion, queue destroy plan) after
  unlocking the workspace, reviewed in the run page before applying.

A task log group that the module kept (`skip_destroy`) is no longer in state. To
build a migration with the same `name` later, either delete the group first or
set `create_log_group = false`, or Terraform fails with
`ResourceAlreadyExistsException`.

Then the things Terraform does not own:

1. **Drop the PostgreSQL replication slot**, if the source was PostgreSQL. DMS
   does not remove it, an inactive slot pins WAL forever, and the source's disk
   fills: an outage on the database you migrated *away from*:

   ```sql
   SELECT slot_name, active, pg_size_pretty(
     pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
   FROM pg_replication_slots;

   SELECT pg_drop_replication_slot('<slot>');
   ```

2. **Oracle**: turn off the supplemental logging added for the migration, if
   nothing else needs it.
3. **MySQL**: restore the binlog retention setting.

---

## 8. When a task stops on its own

The `"state change"` event subscription and the latency alarms exist to tell you
this happened.

```bash
# Why it stopped. Status and StopReason come from the task; the detail of a
# failure is LastFailureMessage and the task log.
aws dms describe-replication-tasks \
  --filters Name=replication-task-id,Values=<task-id> \
  --query 'ReplicationTasks[].[Status,StopReason,LastFailureMessage]' --output table

aws logs tail dms-tasks-<instance-id> --since 2h
```

`StopReason` is a field DMS sets with a fixed set of values. One you will meet
on a full-load-only task is `FULL_LOAD_ONLY_FINISHED`, which is expected: go to
teardown. Other values are listed in the DMS API reference for the replication
task; do not guess from the name.

What the failure usually is, read from `LastFailureMessage` and the log:

| Cause | What to do |
|---|---|
| Table error escalation | One table exceeded `table_error_max` (default 50) and the task stopped by policy. Fix the cause, resume the task, then reload that table (below) |
| Source log unavailable | The source purged logs DMS needed: binlog or archive retention. The task cannot resume; the load starts again |
| A task that is *running* but not progressing | The module renders `RecoverableErrorCount = -1`, the DMS default: DMS restarts the task itself after a recoverable error (nine times while running, six while starting, indefinitely for some error classes). Between restarts a failing connection shows as growing CDC latency, not a stopped task. Read the log and the `cdc-latency` alarms |
| Nothing obvious, right after an HCP Terraform run | **Check section 6a.** An apply touched the task |

**Resume, do not restart**, unless you mean to reload:

```bash
# Resumes from where CDC stopped.
aws dms start-replication-task --replication-task-arn <arn> \
  --start-replication-task-type resume-processing

# Reloads ONE table (or a few) without restarting the task. The task must be
# RUNNING - resume it first. Under DO_NOTHING (the module default) DMS does not
# empty the table before reloading it: TRUNCATE it on the target first, or
# every row is loaded a second time. Test on the first rehearsal whether
# SchemaName/TableName take the source names (CORE/ACCOUNT on Oracle) or the
# transformed target names.
psql -h <target-host> -d <db> -c 'TRUNCATE core.account;'
aws dms reload-tables --replication-task-arn <arn> \
  --tables-to-reload SchemaName=core,TableName=account \
  --reload-option data-reload

# Starts the whole task's full load again from zero. Rarely what you want, and
# over a WAN link it is the expensive kind of retry. Under DO_NOTHING TRUNCATE
# every in-scope target table first, for the same reason as above.
aws dms start-replication-task --replication-task-arn <arn> \
  --start-replication-task-type reload-target
```

### Credential rotation

DMS caches the credential at connection time and does not re-read it on
rotation. An unannounced rotation mid-CDC fails the task on its next reconnect
and needs a resume. If the DBA team runs rotation on a schedule you do not
control, freeze it for the migration window and put that in the change record,
because it is a 3am event otherwise.
