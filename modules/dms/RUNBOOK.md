# terraform-aws-dms — running a migration

The module builds the migration. This is how you run it, on **Terraform Cloud
workspaces**, from first plan to teardown.

Read §5 before you start. Rollback has to be built before cutover, not after.

---

## 0. How this splits across workspaces

DMS is not a single-workspace shape. The migration has three phases and only one
of them is Terraform's, so the split that works is:

| Workspace | Owns | Run trigger | Apply mode |
|---|---|---|---|
| `dms-<name>-infra` | This module: instance, endpoints, tasks, alarms | VCS on the module directory | **Manual apply** |
| *(your pipeline)* | The pre-data and post-data SQL | Manual, gated on the phase | Not Terraform |
| `dms-<name>-teardown` | Nothing — a destroy-only workspace pointed at the same state | Manual, at the end | Manual apply |

Three workspace settings matter more here than in a normal module:

- **Auto-apply OFF.** Always. An auto-applied plan during a CDC soak stops the
  task — see §6a. This is the single most important setting on the workspace.
- **A run task or Sentinel gate** on the migration window, if you have one.
  Otherwise the freeze in §6a is a human convention and will eventually be
  forgotten by someone in a hurry.
- **Workspace variables for the secret ARNs, never the secrets.** The module
  takes `secret_arn`, not a credential. Nothing sensitive belongs in a TFC
  variable here — the whole point of the Secrets Manager path is that DMS reads
  the credential itself and it never enters state or a plan.

State access note for a regulated estate: TFC state contains the endpoint
configuration, the rendered task settings and the ARNs. It does **not** contain
database credentials on the `secret_arn` path. It does if anyone sets
`allow_plaintext_credentials = true`, which is why that flag exists and defaults
to false.

---

## 1. Before the first apply

The module cannot check any of this. All of it fails at runtime, most of it
after the full load has already run.

From a successful plan in the `infra` workspace, read the three contracts:

```bash
terraform output -json source_prerequisites   # -> the DBA team
terraform output -json network_contract       # -> the network team
terraform output -json account_prerequisites  # -> whoever owns IAM
terraform output -json migration_plan         # -> whoever runs the pipeline
```

On TFC these are on the run's **Outputs** tab after the first apply, or from
`terraform output` against the remote state. Circulate them as artefacts of the
change record, not as screenshots.

Blocking items, in the order they bite:

1. **`dms-vpc-role` and `dms-cloudwatch-logs-role` exist in the account.** Fixed
   names, one set per account. Without the first, creating the subnet group
   fails with an error that names neither the role nor the fix.
2. **The source has done its homework.** Oracle supplemental logging is the one
   that fails *silently and wrongly* rather than loudly: without it an UPDATE
   arrives with no way to identify the row.
3. **The network is real.** Routes both ways, the on-prem hostname resolving
   from inside the VPC, both multi-AZ ENI addresses allowed through the on-prem
   firewall.
4. **The target schema exists**, because `target_table_prep_mode` defaults to
   `DO_NOTHING`. That is phase 1 of `migration_plan`.

---

## 2. Apply, then pre-data

The apply creates everything **stopped**. `start = false` is the default so that
approving a plan never begins writing to a target.

```bash
# In the infra workspace: plan, review, apply manually.
# Then, before starting anything, run phase 1 from migration_plan:
psql -h <target> -d <db> -v ON_ERROR_STOP=1 -f sql/01-pre-data-schema.sql
```

Record the checksum that ran. `migration_plan.phase_1_pre_data.scripts[].sha256`
is there so the change record can state which version of the script was applied,
rather than "the one in the repo at the time".

Then confirm DMS can actually reach both databases — this is where a missed
firewall rule or a missing VPC endpoint surfaces, as a timeout rather than an
error:

```bash
aws dms test-connection --replication-instance-arn <instance-arn> --endpoint-arn <endpoint-arn>
aws dms describe-connections \
  --filters Name=replication-instance-arn,Values=<instance-arn> \
  --query 'Connections[].[EndpointIdentifier,Status,LastFailureMessage]' --output table
```

---

## 3. The full load

```bash
aws dms start-replication-task --replication-task-arn <task-arn> \
  --start-replication-task-type start-replication
```

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
| Tables stuck at 0 rows | Usually a source permission gap, or a selection rule matching a schema name with different casing |
| `FreeStorageSpace` falling | Cached changes accumulating. A full disk stops **every** task on the instance |

The target's triggers and foreign keys should be inert for this phase — that is
what `postgres.after_connect_script = "SET session_replication_role = replica;"`
does, and it applies to DMS's connections only.

---

## 4. Post-data, then the CDC soak

Run phase 3 of `migration_plan` once the full load completes: indexes, foreign
keys, constraints, grants. Built now rather than during the load, because index
maintenance slows the load and foreign keys reject rows that arrive parent-last.

Then watch the number the cutover window is made of:

```bash
aws cloudwatch get-metric-statistics --namespace AWS/DMS \
  --metric-name CDCLatencyTarget \
  --dimensions Name=ReplicationInstanceIdentifier,Value=<instance-id> \
               Name=ReplicationTaskIdentifier,Value=<task-id> \
  --start-time $(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 3600 --statistics Average Maximum --output table
```

| Reading | Meaning |
|---|---|
| Flat and low (seconds) | The target keeps up. Cutover is a short window |
| Flat but high (minutes) | Keeping up; the window is that many minutes long |
| **Growing without bound** | The target will never catch up. Fix before planning a cutover: bigger instance, `batch_apply_enabled`, or fewer tables per task |
| **No datapoints at all** | The task has stopped. The alarms treat missing data as breaching for exactly this reason |

Do not plan a cutover until latency is stable across a **full business cycle**,
including the nightly batch. Keeping up all day and falling two hours behind at
02:00 means a two-hour window, not a two-minute one.

**First soak only:** confirm the alarms are real.

```bash
# Does DMS publish the dimensions the alarms are built on?
aws cloudwatch list-metrics --namespace AWS/DMS \
  --query 'Metrics[?MetricName==`CDCLatencyTarget`].Dimensions' --output json
```

If that returns nothing while the task is running, the latency alarms cannot
fire on data and will sit in ALARM permanently. That is the one claim in this
module a live run has never verified.

---

## 5. Rollback has to exist before cutover

Once the application writes to the new target, the old source is stale. Rolling
back means moving those writes *back*, and DMS cannot do that retroactively
because the changes were never captured.

If the migration must be reversible, build the reverse path **before** cutover.
An endpoint carries one `role`, and the module refuses a task that reads from a
`target` — so this needs **four** endpoint entries, each database defined twice:

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
  logical`, a replication slot and the `rds_replication` grant — the same
  homework the original source had, on the database you just migrated into.
- **Loopback prevention.** Without it the two tasks feed each other
  indefinitely. It lives in `LoopbackPreventionSettings`, which this module does
  not expose as a typed setting — use `raw_overrides` and have it reviewed.
- **Write credentials on the old source.** `oracle-tgt` needs a credential that
  can write to the system you are migrating away from. Different grant, and
  usually a different approval.

---

## 6. The cutover

The point of no return is step 8. Everything before it is reversible by doing
nothing.

```bash
# 1. Stop writes to the source. Maintenance mode, or revoke write permissions -
#    a "quiet" application is not a stopped one.

# 2. Wait for CDCLatencyTarget to reach ~0 and hold. This is the window.

# 3. STOP THE FORWARD TASK, before the application writes anywhere. While both
#    the application and DMS can write to the target, a late source change can
#    overwrite a newer application write - a silent corruption window.
aws dms stop-replication-task --replication-task-arn <task-arn>

# 4. Verify, and capture the evidence the change record needs.
aws dms describe-table-statistics --replication-task-arn <task-arn> \
  --query 'TableStatistics[].[TableName,Inserts,Updates,Deletes,ValidationState]' \
  --output json > cutover-table-stats.json
terraform output -json governance > cutover-governance.json
# Anything not "Validated" is a question to answer now, while the source is
# still there to compare against.

# 5. Re-run the sequence reset. DMS migrates rows, not sequence positions, and
#    CDC has been adding rows since post-data ran. The application's first
#    insert fails on a duplicate key otherwise - the most common Oracle to
#    Aurora PostgreSQL cutover failure there is.
psql -h <target> -d <db> -v ON_ERROR_STOP=1 -f sql/03-post-data-sequences.sql

# 6. Restore the target to normal behaviour: session_replication_role back to
#    origin for application sessions, triggers and FKs live.

# 7. Start the rollback task, if you built one. It must be running BEFORE the
#    first application write lands, or the reverse stream has a gap.

# 8. Point the application at the target.   <-- point of no return
```

Do not delete anything yet. Keep the source readable and the tasks in place
until the new target has survived a full business cycle.

---

## 6a. The apply freeze

**A Terraform apply stops a running task. Treat this as a freeze rule.**

The AWS provider stops a replication task to modify almost any argument, and
only restarts it if `start_replication_task = true`. This module defaults that
to `false` — deliberately, so an apply never starts a migration — and tasks are
started by CLI. Together that means an apply touching the task resource **stops
CDC and leaves it stopped**.

Everything here is enough to trigger it, because they all feed the rendered
settings JSON:

`table_mappings` · `log_level` · `validation_threads` · `lob_max_size_kb` ·
`commit_rate` · `control_schema` · `migration_type` · `cdc_start_time` ·
any `raw_overrides` edit

Terraform cannot warn you: the provider never reads `start_replication_task`
back, so state says `false` while the task runs.

**On Terraform Cloud, enforce it with workspace settings, not discipline:**

- **Auto-apply off** for the whole migration. Non-negotiable.
- **Lock the workspace** (Settings → Lock) between full-load start and cutover.
  A locked workspace refuses runs, which is the only mechanism that survives
  someone merging a tidy-up PR on a Friday.
- If you use run tasks or Sentinel, gate on the lock reason so the refusal
  explains itself.

Unlock, apply, re-lock — deliberately, inside the window, with the task stopped.

**Changes that replace the instance outright**, losing every task and all cached
changes: `kms_key_arn`, `publicly_accessible`, `availability_zone`,
`subnet_ids`, `name`. Adopting a CMK mid-migration in response to a control
finding is the realistic way this happens. Cutover-window only.

---

## 7. Teardown

A stopped task does not stop the instance. See
[COSTS.md §5](COSTS.md#5-leaving-it-running): a forgotten `dms.c5.xlarge`
multi-AZ is $6,132/year.

```bash
# What is still running and billing.
aws dms describe-replication-instances \
  --query 'ReplicationInstances[].[ReplicationInstanceIdentifier,ReplicationInstanceClass,MultiAZ,InstanceCreateTime]' \
  --output table
```

On TFC: unlock the workspace, queue a **destroy run**, review the plan (it should
remove the tasks, endpoints, instance and subnet group in that order), apply it
manually. A destroy-only workspace makes this a one-click, logged, reviewable
action instead of a local `terraform destroy` on someone's laptop.

Then the things Terraform does not own:

1. **Drop the PostgreSQL replication slot**, if the source was PostgreSQL. DMS
   does not remove it, an inactive slot pins WAL forever, and the source's disk
   fills — an outage on the database you migrated *away from*:

   ```sql
   SELECT slot_name, active, pg_size_pretty(
     pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
   FROM pg_replication_slots;

   SELECT pg_drop_replication_slot('<slot>');
   ```

2. **Oracle**: turn off the supplemental logging added for the migration, if
   nothing else needs it.
3. **MySQL**: restore the binlog retention setting.
4. **Drop the `dms_control` schema** from the target once the evidence is
   captured — `awsdms_apply_exceptions` holds failed rows and their SQL.

---

## 8. When a task stops on its own

The `"state change"` event subscription and the latency alarms exist to tell you
this happened.

```bash
# Why it stopped. StopReason is the field that matters.
aws dms describe-replication-tasks \
  --filters Name=replication-task-id,Values=<task-id> \
  --query 'ReplicationTasks[].[Status,StopReason,LastFailureMessage]' --output table

aws logs tail dms-tasks-<instance-id> --since 2h
```

| StopReason | What to do |
|---|---|
| `FULL_LOAD_ONLY_FINISHED` | Expected on a `full-load` task. Go to teardown |
| `RECOVERABLE_ERROR` | DMS gave up retrying. Fix the cause, then resume |
| Table error escalation | One table exceeded `table_error_max`. Fix, then `reload-target` that table |
| Source log unavailable | The source purged logs DMS needed — binlog or archive retention. The task cannot resume; the load starts again |
| Nothing obvious, right after a TFC run | **Check §6a.** An apply touched the task |

**Resume, do not restart**, unless you mean to reload:

```bash
# Resumes from where CDC stopped.
aws dms start-replication-task --replication-task-arn <arn> \
  --start-replication-task-type resume-processing

# Starts the full load again from zero. Rarely what you want, and over a WAN
# link it is the expensive kind of retry.
aws dms start-replication-task --replication-task-arn <arn> \
  --start-replication-task-type reload-target
```

### Credential rotation

DMS caches the credential at connection time and does not re-read it on
rotation. An unannounced rotation mid-CDC fails the task on its next reconnect
and needs a resume. If the DBA team runs rotation on a schedule you do not
control, freeze it for the migration window — and put that in the change record,
because it is a 3am event otherwise.
