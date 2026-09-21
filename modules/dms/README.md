# terraform-aws-dms

Database migration on AWS DMS, built for a regulated estate: a fully isolated
VPC with no internet path, AWS access over VPC endpoints, hybrid connectivity to
an on-premises source, and a private Aurora target.

Source and target endpoints, a replication instance or serverless capacity,
tasks whose settings are typed rather than hand-written JSON, a manifest for the
SQL either side of the data, and the alarms that catch the failure that actually
matters — a CDC task that stops while everything still looks green.

**Status:** implemented and audited — 23 resources, 42 variables, 75 validations,
17 preconditions, 15 advisory checks, 19 outputs, 56 plan tests green, two
linters with self-test regressions.

Three independent audits (security, well-architected, correctness) produced
**8 CRITICAL, 12 HIGH and ~25 MEDIUM/LOW** findings. The code defects are fixed,
each with a regression test. See [What the audits found](#what-the-audits-found).

**No migration has been run with this module.** Every runtime claim comes from
the provider schema, the DMS documentation and the API's behaviour — not from
observation. That disclaimer does not cover *misread* documentation: three of the
criticals were cases where the primary source contradicted this module. See
[Limits](#limits).

| Also here | For |
|---|---|
| [COSTS.md](COSTS.md) | What a migration costs, priced from the live price list |
| [RUNBOOK.md](RUNBOOK.md) | Running one on Terraform Cloud: phases, freeze rule, cutover, teardown |

---

## The three problems this module exists for

**1. Credentials end up in state.** `username` and `password` on a DMS endpoint
are stored in Terraform state in plaintext and returned by `DescribeEndpoints`
to anyone with the API permission. The module refuses them unless
`allow_plaintext_credentials = true`, and wires Secrets Manager instead — a role
per endpoint, scoped to one secret, trusting the **regional** DMS principal (the
global one is rejected by Secrets Manager, with an error naming neither the role
nor the fix).

**2. DMS is silent about what it does not understand.** `replication_task_settings`
is a JSON blob and an unrecognised key is ignored without error:
`"EnableValdiation": true` validates nothing. A table mapping with no selection
rule matches no tables and the task *completes successfully*. Two rules sharing
a `rule-id` means one quietly does not exist.

So the module renders that JSON from typed inputs, validates mappings at plan
time, and ships `tests/lint_task_settings.py` for anything added on top.

**3. A stopped CDC task tells nobody.** DMS does not retry it. The target stops
receiving changes, the source keeps taking writes, and no metric goes red —
because a stopped task publishes *no datapoints at all*. Hence
`treat_missing_data = "breaching"` on the latency alarms and `"state change"` in
the task event subscription.

---

## The migration is three phases; DMS owns one

```
pre_data        schemas, tables, types, sequences          your pipeline
   │            (DMS creates none of it under DO_NOTHING)
   ▼
full load  ─▶  CDC                                          DMS
   │            triggers and FKs inert via after_connect_script
   ▼
post_data       indexes, FKs, constraints, grants,          your pipeline
                sequence reset
   ▼
cutover         stop task ▸ verify ▸ reset sequences ▸      RUNBOOK §6
                restore ▸ repoint
```

`sql_scripts` records the SQL either side as a **manifest** — name, path,
`filesha256()` — and `output.migration_plan` emits the whole ordered sequence
with those checksums, so a change record can state which version of which script
ran. The module deliberately **does not execute any of it**: running DDL against
a private Aurora from an apply needs network reachability into the isolated VPC,
credentials on the runner, and it makes a schema change a side effect of a
Terraform run. That belongs in your pipeline as its own reviewable step.

The one hook DMS genuinely has is `postgres.after_connect_script` on the target
— `SET session_replication_role = replica;` — which is how triggers stay quiet
and foreign keys stop rejecting rows that arrive parent-last during a full load.

---

## Quick start

```hcl
module "migration" {
  source = "../../modules/dms"

  name               = "core-to-aurora"
  subnet_ids         = var.private_subnet_ids     # two AZs minimum
  security_group_ids = [var.dms_sg_id]

  kms_key_arn    = var.cmk_arn
  require_cmk    = true
  engine_version = "3.5.3"                        # pin it

  certificates = { onprem-ca = { pem = file("ca.pem") } }

  endpoints = {
    src = {
      role               = "source"
      engine             = "oracle"
      server_name        = "oracle-prod.internal"  # feeds network_contract
      port               = 1521
      secret_arn         = var.source_secret_arn   # the credential path
      secret_kms_key_arn = var.secret_key_arn
      ssl_mode           = "verify-full"
      certificate_key    = "onprem-ca"
    }
    tgt = {
      role               = "target"
      engine             = "aurora-postgresql"
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
    pre_data  = [{ name = "01-schema", path = "sql/01-schema.sql",
                   sha256 = filesha256("${path.module}/sql/01-schema.sql") }]
    post_data = [{ name = "02-constraints", path = "sql/02-constraints.sql",
                   sha256 = filesha256("${path.module}/sql/02-constraints.sql") }]
  }

  tasks = {
    core = {
      source_endpoint = "src"
      target_endpoint = "tgt"
      migration_type  = "full-load-and-cdc"
      table_mappings  = file("${path.module}/mappings/core.json")
      start           = false                     # start it deliberately
    }
  }

  sns_topic_arn = var.alerts_topic_arn
}
```

Then, before anything else:

```bash
terraform output -json source_prerequisites   # -> the DBA team
terraform output -json network_contract       # -> the network team
terraform output -json migration_plan         # -> the pipeline
```

### Examples

| Example | Shows |
|---|---|
| [`isolated-vpc-onprem-to-aurora/`](examples/isolated-vpc-onprem-to-aurora/) | **The regulated case**: on-prem source over Cloud WAN, private Aurora, no internet path, pre/post-data SQL, and the on-prem firewall request as an output |
| [`oracle-to-aurora-postgresql/`](examples/oracle-to-aurora-postgresql/) | The same migration in a simpler network |
| [`serverless-cdc-to-s3/`](examples/serverless-cdc-to-s3/) | Continuous CDC into a lake on serverless compute, Parquet, partitioned |

---

## What the module refuses

**A database credential in state.** `username`/`password` are refused; so is a
password hidden in `extra_connection_attributes`, which reaches state and the
API in the clear.

**Talking to a database without verifying it.** `ssl_mode` defaults to
`verify-full`; `none` and `require` need `allow_insecure_transport = true`.

**Claiming verification without a CA.** `verify-full` with no certificate is a
setting that reads as strict and verifies nothing.

**Deleting target data by accident.** `TRUNCATE_BEFORE_LOAD` and
`DROP_AND_CREATE` need `allow_destructive_target_prep = true` — and that gate
reads the *merged* settings, so a `raw_overrides` cannot slip past it.

**A task that migrates nothing.** Mappings need a selection rule and unique
rule-ids, checked at plan time; `FailOnNoTablesCaptured` is on by default so the
runtime half fails loudly too.

**An endpoint used backwards**, including an S3 target as a task's source.

**A public replication instance.** Needs `allow_public_replication_instance`.

### Advisory checks

Fifteen `check` blocks warn without refusing: no SNS topic, validation off,
logging off, unbounded log retention, single-AZ, a full-load-only task on a
provisioned instance, an unpinned engine version, a plaintext credential,
cleartext transport, serverless compute (which this module cannot watch),
control tables in the target's default schema, DEBUG logging left on, a storage
alarm too small to react to, **a target schema nothing creates**, and **a
PostgreSQL target whose constraints are live during the load**.

All are gated on `create`, so a switched-off module is silent.

---

## The parts people get wrong

**Secrets carry the connection details.** With `secret_arn` set, DMS takes host,
port, database and credential **from the secret** — the provider rejects
`server_name` as conflicting. The module accepts it, does not send it, and uses
it to build `network_contract`, because the firewall request needs a host and a
port. The secret's JSON needs `username`, `password`, `host`, `port`, `dbname`.

**The source database has homework.** `source_prerequisites` returns it per
engine. The worst is Oracle supplemental logging: without it an `UPDATE` arrives
with no way to identify the row, and DMS applies it to the wrong one — silent
and wrong, not stopped.

**A replication slot outlives the task.** A PostgreSQL source keeps WAL for an
inactive slot forever; the *source* fills its disk. The module sets a heartbeat
to keep it advancing; dropping it afterwards is yours (RUNBOOK §7).

**An apply stops a running task.** The provider stops a task to change almost
anything and only restarts it if `start_replication_task = true`, which defaults
false here. On Terraform Cloud, **lock the workspace** for the migration —
RUNBOOK §6a.

**Serverless is not automatically cheaper**, and this module creates no
observability for it at all.

---

## Testing

| Layer | Proves | Run |
|---|---|---|
| 56 plan tests | Graph shape, rendered settings, IAM policy content, every validation and precondition, the contract outputs | `terraform test` |
| `lint_task_settings.py` | Unknown settings keys, contradictory LOB flags, mappings with no selection rule, duplicate rule-ids | `python3 tests/lint_task_settings.py examples tests/fixtures` |
| `lint_validations.py` | No validation or local puts a throwing expression in a later `\|\|`/`&&` operand | `python3 tests/lint_validations.py .` |
| A migration | That any of it works | Nothing here has done this |

`tests/fixtures/` holds the module's **real rendered task settings**, one per LOB
mode, because the settings half of that linter had never been pointed at a
settings document — which is how a broken `INLINE` rendering passed a green
self-test.

---

## What the audits found

Three independent audits, read-only, no shared context. The five worth knowing:

**`raw_overrides` defeated every gate, and `governance` certified the result as
clean.** The typed-settings design is the whole premise — but the gates, checks
and governance output read the *typed input* while DMS received the *merged*
JSON. One string field could disable validation and logging and enable
`DROP_AND_CREATE` while the change record said otherwise. Every posture field is
now computed from the merged settings.

**Every task precondition evaporated in serverless mode.** They lived on a
resource with `for_each = {}` there, and a precondition on zero instances never
runs. `allow_destructive_target_prep` protected nothing. All module-wide
invariants now live on the subnet group, present in both compute modes.

**`lob_mode = "INLINE"` rendered a setting DMS ignores.** DMS only reads
`InlineLobMaxSize` when `FullLobMode` is true. The caller asked for inline LOBs
and silently got default handling — the module's own headline trap, in the
module.

**`ParallelLoadThreads` does nothing on a PostgreSQL target**, and the flagship
example set it with a comment claiming the opposite. `batch_apply_enabled` is
the real lever.

**Every price in COSTS.md was wrong** — carried from memory, 7–23% high, matching
no AWS region. Regenerated from the Price List bulk API; the one figure still
unverifiable (the serverless DCU rate, absent from the list) is labelled as such.

---

## Limits

- **No migration has been run with this module.**
- **The CloudWatch task dimension is unverified.** If DMS publishes
  `ReplicationTaskIdentifier` differently from the task id, the CDC alarms never
  receive data — and because they treat missing data as breaching, they would
  page continuously instead of failing silently. RUNBOOK §4 has the one command
  that settles it. **Check this on the first soak.**
- **Serverless has no observability here** — no alarms, no event subscriptions,
  no log group. A check says so at plan time.
- **Relational engines plus S3 only.** Kafka, Kinesis, MongoDB, DocumentDB,
  OpenSearch and Redis are out of scope.
- **The module runs no SQL.** `sql_scripts` is a manifest; execution is your
  pipeline's.
- **Account-wide roles are not created by default.** `dms-vpc-role` and
  `dms-cloudwatch-logs-role` are fixed-name singletons.
- **Schema conversion is not in scope.** DMS moves data; the target schema is
  yours.
- **Validation compares rows, not everything.** LOBs are skipped by default, and
  nothing the mappings excluded is checked.
- **`LoopbackPreventionSettings` is not typed**, so a bidirectional rollback
  configuration needs `raw_overrides`.

## Inputs

Forty-two variables. The ones that matter most:

| Name | Type | Default | Notes |
|---|---|---|---|
| `name` | string | — | Prefixes everything; also the log group suffix |
| `compute_mode` | string | `"provisioned"` | Or `"serverless"` — unwatched by this module |
| `subnet_ids` | list(string) | — | Two AZs minimum, routed to both databases |
| `endpoints` | map(object) | `{}` | `secret_arn` is the supported credential path |
| `sql_scripts` | object | `{}` | Pre/post-data manifest with checksums |
| `tasks` | map(object) | `{}` | Typed settings; mappings validated at plan |
| `s3_targets` | map(object) | `{}` | Separate resource, separate shape |
| `certificates` | map(object) | `{}` | Referenced by `certificate_key` |
| `kms_key_arn` / `require_cmk` | string / bool | `""` / `false` | Storage, endpoints, logs |
| `multi_az` | bool | `true` | Halving it halves the bill and the safety net |
| `sns_topic_arn` | string | `""` | Without it nothing is watching |
| `allow_plaintext_credentials` | bool | `false` | Credentials in state |
| `allow_insecure_transport` | bool | `false` | `ssl_mode` below `verify-*` |
| `allow_destructive_target_prep` | bool | `false` | Target data deleted before load |

## Outputs

| Name | Use |
|---|---|
| `migration_plan` | The ordered three-phase sequence with script checksums |
| `source_prerequisites` | Hand to the DBA team before the first task start |
| `network_contract` | Hand to the network team — DNS, return path, endpoints |
| `account_prerequisites` | The two fixed-name IAM roles DMS needs |
| `replication_instance_private_ips` | What the on-prem firewall must allow |
| `task_settings_json` | The rendered settings, for a change review |
| `governance` | The effective posture, as data |
| `verify_commands` | Connection test, task status, CDC latency, what is still billing |
