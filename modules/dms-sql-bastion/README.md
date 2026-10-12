# terraform-aws-dms-sql-bastion

Runs the SQL (and, if you allow it, shell) work either side of a DMS migration
from inside an isolated VPC. One EC2 instance with no inbound access, reached
only through Systems Manager, and one SSM Command document that runs:

- **one script** against one database (`Mode=run`);
- a **runbook**: a named, ordered list of steps defined in Terraform and
  reviewed in the plan (`Mode=runbook`);
- a **manifest**: the same list of steps as a JSON file in S3, for work that
  should not wait for an apply (`Mode=manifest`);
- a **connection check** against one database or all of them (`Mode=check`).

```
operator ── Run Command / Session Manager ──► bastion (DMS's subnet) ──► Aurora / on-prem DBs
                                                 ▲
                                scripts from S3, credentials from Secrets Manager
```

[modules/dms](../dms) builds the replication and records the scripts in
`migration_plan`, but executes no SQL. This module executes it. What runs,
against which database, in what order, with which variables and what happens
on an error is all yours to configure.

## Quick start

```hcl
module "sql_bastion" {
  source = "../../modules/dms-sql-bastion"

  name      = "core-banking"
  ami_id    = var.bastion_ami_id
  vpc_id    = var.vpc_id
  subnet_id = var.dms_subnet_ids[0]

  https_egress = {
    security_group_ids = [var.endpoints_security_group_id] # the VPC interface endpoints
    prefix_list_ids    = [var.s3_prefix_list_id]           # the S3 gateway endpoint
  }

  scripts = { bucket_name = "core-banking-migration-scripts" }

  targets = {
    aurora = {
      engine            = "aurora-postgresql"
      host              = "core.cluster-abc123.eu-west-2.rds.amazonaws.com"
      port              = 5432
      database          = "core"
      secret_arn        = var.migrator_secret_arn # schema owner, not the DMS user
      ca_bundle_path    = "/etc/pki/rds/global-bundle.pem"
      security_group_id = var.aurora_security_group_id
    }
  }

  runbooks = {
    pre-data = {
      description = "schema before the load"
      steps = [
        { name = "schemas", target = "aurora", script = "wave-1/pre/01-schemas.sql" },
        { name = "tables",  target = "aurora", script = "wave-1/pre/02-tables.sql", sha256 = "9f86d0..." },
      ]
    }
    post-data = {
      steps = [
        { name = "indexes",   target = "aurora", script = "wave-1/post/01-indexes.sql", transaction = "none", timeout_seconds = 14400 },
        { name = "sequences", target = "aurora", script = "wave-1/post/02-sequences.sql" },
      ]
    }
  }
}
```

Two examples wire it to [modules/dms](../dms):

- [examples/oracle-to-aurora](examples/oracle-to-aurora/main.tf). One list of
  hand-written scripts is uploaded to S3, pinned by SHA-256, recorded in
  `migration_plan` and turned into one runbook per phase.
- [examples/postgres-to-aurora](examples/postgres-to-aurora/main.tf).
  On-prem PostgreSQL to Aurora, full load + CDC. Nobody writes the target
  schema:
  - shell steps take it from the source with `pg_dump` (`--section=pre-data`,
    then `post-data`), and the next step applies it to Aurora;
  - the DMS task pauses before cached changes, so keys and indexes are built
    before CDC applies anything;
  - runbooks: `source-prep` (wal_level, slots, replication role, keyless
    tables), `pre-data`, `post-data`, `cutover-sequences`.

## Requirements

| | |
|---|---|
| Terraform | >= 1.9.0 |
| AWS provider | >= 5.70.0, < 6.0.0 |
| AMI | yours; see below |
| Network | the endpoints in `output.network_contract` |

### The AMI

The module uses `ami_id` verbatim and passes no user data: in an isolated VPC
the image has to arrive complete. It must carry:

- the SSM agent (Amazon Linux 2023 has it);
- AWS CLI v2, `bash` and `python3` (3.9 or later; the runner uses the standard
  library only);
- the client for each target engine: `psql` for the postgres family, `mysql`
  or the MariaDB client for the mysql family, `sqlplus` from Oracle Instant
  Client;
- anything your shell steps call (`pg_dump`, `pg_restore`, ...);
- every CA bundle a target's `ca_bundle_path` names. For RDS and Aurora, the
  global bundle from `https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem`.

A missing client or bundle fails the step with exit code 4 and names what is
missing. Run `Mode=check` once after the first apply: it checks every target.

### The network

`output.network_contract` lists it. In short:

- **Interface endpoints:** `ssm`, `ssmmessages`, `ec2messages`,
  `secretsmanager`, `logs`, plus `kms` when a customer key is involved.
  Without the first three the instance never registers and is not offered in
  Run Command.
- **S3 gateway endpoint.**
- **Endpoint security group:** must admit 443 from the bastion.
- **Database ports:** each database must admit the bastion on its port.
  - A target with `security_group_id`: the module adds that rule
    (`manage_target_ingress`).
  - An on-prem database (`cidr_blocks`): the firewall request is yours.

## Steps

A step is the unit of work in a runbook or a manifest:

| Field | Default | |
|---|---|---|
| `name` | `step-<n>` | unique in its list; what `StartAt` resumes from |
| `target` | (required) | a `targets` key; steps in one list can mix targets and engines |
| `script` | (required) | object key under `scripts.prefix` |
| `sha256` | | the step refuses any other content (exit 3) |
| `type` | `sql`, or `shell` for `*.sh` | `shell` needs `allow_shell_steps` |
| `transaction` | `auto` | `auto`: one transaction on PostgreSQL and Oracle, statement by statement on MySQL. `single`: refused on MySQL, whose DDL commits implicitly. `none`: each statement commits (e.g. `CREATE INDEX CONCURRENTLY`) |
| `timeout_seconds` | `default_timeout_seconds` | the runner stops the client; the database rolls back |
| `on_error` | `stop` | `continue` runs the remaining steps, and the run still ends failed |
| `variables` | the target's `variables` | see below |

Steps run one at a time, in list order. When a step fails and its `on_error`
is `stop`, the run lists what it did not run and prints the `StartAt` that
resumes it.

### Variables

A step's `variables` override its target's `variables`. `Mode=run` takes them
as `Variables=name=value;name=value`. They reach the script as:

| Engine | Mechanism | In the script |
|---|---|---|
| PostgreSQL | `psql --set name=value` | `:'name'` (literal), `:"name"` (identifier) |
| MySQL | `SET @name = 'value';` before the script | `@name` |
| Oracle | `DEFINE name = "value"` (substitution on only when there are variables) | `&name` |
| shell | environment variable | `$name` |

Values are limited to letters, digits, space and `_ . , : / @ + % -`, because
they land inside SQL.

### Shell steps

`allow_shell_steps = true` lets a step run a bash script from the scripts
prefix. Use it for what SQL cannot do: `pg_dump --schema-only` for evidence,
`pg_restore`, a loop over schemas. The script runs as root on the bastion,
with:

- `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `DB_ENGINE`,
  `DB_SSL_MODE`, `DB_CA_BUNDLE`, `DMS_TARGET`;
- `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`, `PGSSLMODE` and
  `PGSSLROOTCERT` for PostgreSQL, so `pg_dump` just works;
- `DB_MYSQL_DEFAULTS_FILE`, a 0600 option file, for MySQL;
- `DMS_SCRIPTS_BUCKET` and `DMS_SCRIPTS_PREFIX`, so a step can write a script
  for a later step to run (with `s3:PutObject` granted through
  `additional_iam_policy_json`), and `AWS_REGION` for the CLI;
- its variables;
- a working directory that is removed after the run.

Off by default: a shell step can do anything the instance role can.

### Manifests

`Mode=manifest,ManifestKey=<key>` runs a JSON file from the scripts prefix:

```json
{
  "description": "wave 2 hotfix",
  "steps": [
    { "name": "fix-fk", "target": "aurora", "script": "wave-2/fix-fk.sql", "sha256": "..." },
    { "name": "reindex", "target": "aurora", "script": "wave-2/reindex.sql", "transaction": "none" }
  ]
}
```

A manifest goes through the same checks as a runbook. Unknown keys are refused
by name, so a misspelled `trasnaction` fails instead of being ignored. Pass the
manifest's own SHA-256 as `ExpectedSha256` to pin it.

A manifest is not reviewed in a plan. `allow_s3_manifests = false` limits
multi-step runs to runbooks.

## Running

`output.commands` has every command filled in: `check_all`, `check`, `run`,
`runbook`, `runbook_dry_run`, `runbook_resume`, `manifest`, `result`, `logs`,
`session`. `output.runbooks` shows each runbook's steps as the runner will see
them.

```bash
# Prove every script is the reviewed one and every database is reachable.
aws ssm send-command --document-name core-banking-run-sql --instance-ids i-0123... \
  --parameters Mode=runbook,Runbook=pre-data,DryRun=true \
  --cloudwatch-output-config CloudWatchOutputEnabled=true,CloudWatchLogGroupName=/dms-sql-bastion/core-banking

# Run it.
aws ssm send-command ... --parameters Mode=runbook,Runbook=pre-data

# It failed at "tables"; fix the script, upload it, then resume there.
aws ssm send-command ... --parameters Mode=runbook,Runbook=pre-data,StartAt=tables

# Follow the output.
aws logs tail /dms-sql-bastion/core-banking --follow
```

In the console it is the same fields on the Run Command page. Tick
"Enable CloudWatch logs" and name the run log group, so the full output is
kept. The console view truncates it at 24,000 characters.

### Document parameters

| Parameter | Default | Used by |
|---|---|---|
| `Mode` | `run` | `run`, `runbook`, `manifest`, `check` |
| `Target` | | `run`; `check` (empty: every target) |
| `ScriptKey` | | `run`; `*.sh` is a shell step |
| `ExpectedSha256` | | `run` (the script), `manifest` (the manifest) |
| `Transaction` | `auto` | `run` |
| `Variables` | | `run` |
| `Runbook` | | `runbook` |
| `ManifestKey` | | `manifest` |
| `StartAt` | | `runbook`, `manifest` |
| `DryRun` | `false` | all: verify scripts and connect to every target used, execute nothing |
| `StepTimeoutSeconds` | `0` (= `default_timeout_seconds`) | steps without their own timeout |
| `TimeoutSeconds` | `run_timeout_seconds` | the whole run |

Every parameter has `allowedValues` or `allowedPattern`. SSM substitutes them
into the launcher as text, so none of them can carry a quote.

### What a run does

1. The launcher writes the runner (`scripts/runner.py`) and its
   configuration (targets and runbooks, rendered at apply time) to a private
   directory, then starts the runner.
2. The runner builds the step list and validates every step: target, key,
   SHA-256 format, type, transaction, timeout, variables. Then it applies
   `StartAt`.
3. For each step it:
   - downloads the script and logs its S3 version and SHA-256, then checks the
     SHA-256 against the step's;
   - reads the target's secret (`username`, `password`) once per run;
   - runs the client in its own process group, with a minimal environment.
4. Clients by engine:
   - **PostgreSQL:** `psql --set ON_ERROR_STOP=1`, `--single-transaction`
     unless `none`, password in `PGPASSWORD`.
   - **MySQL family:** `mysql --defaults-extra-file`, a 0600 option file. TLS
     flags are chosen for the MariaDB or the MySQL client, whichever the AMI
     carries.
   - **Oracle:** `sqlplus -S -L /nolog` with `CONNECT` on stdin and
     `WHENEVER SQLERROR EXIT FAILURE ROLLBACK`.
5. Every line of client output is masked against the password before it is
   printed. The password never reaches argv.
6. On a step timeout, or when SSM stops the run, the runner terminates the
   client's whole process group.
7. At the end it prints a summary: each step's status, duration, S3 version and
   SHA-256.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | ok |
| 1 | the runner itself failed |
| 2 | a client or shell step reported an error |
| 3 | SHA-256 mismatch |
| 4 | configuration: parameter, manifest, secret, missing client or bundle |
| 5 | interrupted |
| 6 | step timeout |

## Per-target settings

Beyond host, port, database and credential, each target takes:

| Field | |
|---|---|
| `ssl_mode`, `ca_bundle_path` | see the `targets` description. `require` and `disable` need `allow_insecure_transport` |
| `client_options` | extra client arguments, passed as argv entries (never through a shell), e.g. `["--quiet"]` |
| `env` | client and shell-step environment, e.g. `{ PGOPTIONS = "-c lock_timeout=30s -c statement_timeout=0" }` or `{ NLS_LANG = "AMERICAN_AMERICA.AL32UTF8" }`. The credential variables cannot be overridden |
| `variables` | default script variables for every step on this target |

## Extension points

| Variable | For |
|---|---|
| `additional_security_group_ids` | a platform team's shared security group |
| `additional_egress_rules` | more egress (LDAP, an artifact mirror, another database) |
| `additional_iam_policy_arns` | managed policies on the instance role |
| `additional_iam_policy_json` | an inline policy, e.g. write to an evidence bucket from a shell step |
| `kms_key_arn`, `permissions_boundary_arn` | the usual |

## Who can run what

Nobody gets access from this module. `output.operator_policy_json` is a policy
for the people who run scripts. It allows:

- `ssm:SendCommand` with this document on this instance only;
- `ssm:StartSession` on this instance;
- reading results and run logs;
- uploading to the scripts prefix.

Attach it to their role.

Session Manager gives a root shell on a box that can reach the databases.
Grant `StartSession` to fewer people than `SendCommand`, and turn on session
logging in the account's Session Manager preferences (account-wide, so not
managed here).

## Between waves

`running = false` stops the instance: it bills its volume only, and no session
can be opened. Set it back to `true` before the next wave.

## What this module does not do

These are deliberate, for weight:

- **No record of what already ran.** Re-running a step runs it again. Write
  scripts to be re-runnable (`IF NOT EXISTS`). Use `StartAt` to resume, and
  keep the Run Command history and the run log group as the record.
- **No lock.** Two operators can run at the same time.
- **No parallel steps.** Steps run one at a time.
- **No SQL Server, no Oracle TCPS.** Oracle transport encryption is native
  network encryption in the AMI's `sqlnet.ora`.
- **One instance, one AZ.** It holds no state; if it is lost, apply again.

For a ledger, a lock and an automated cutover, see
[modules/dms-orchestrator](../dms-orchestrator).

## Testing

```bash
terraform test                          # plan-level, mocked provider
python3 tests/runner/test_runner.py     # the runner and the launcher
```

`test_runner.py` runs the real runner against a fake AWS CLI and stub `psql`,
`mysql`, `sqlplus` and `bash` that record their argv, environment, stdin and
option files. It covers:

- step order, `StartAt`, `DryRun`, `on_error`;
- manifests;
- every exit code, including step timeout and SIGTERM, where it also checks
  that no client process survives;
- per-engine arguments and transactions;
- variables;
- that the password never reaches argv or output.

It also renders the real launcher with Terraform, runs `shellcheck` on it, and
runs it end to end.

It does not prove client behaviour against a live server. Run `DryRun=true`
and a trivial script on each target before the first real wave.
