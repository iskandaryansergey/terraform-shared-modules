# Changelog: dms-sql-bastion

All notable changes to this module. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the module follows
[semantic versioning](https://semver.org). Releases are tagged
`dms-sql-bastion-vX.Y.Z`.

## [1.0.0] - unreleased

First release.

### Added

- **Instance.** One EC2 instance from a caller-supplied AMI:
  - no public address, no key pair, no user data, no ingress;
  - IMDSv2 required;
  - encrypted root volume, with an optional customer key;
  - `running` stops and starts it between waves.
- **Network.** A security group with egress only to:
  - the given VPC endpoints (443);
  - each target's security group or CIDR, on its port;
  - `additional_egress_rules`.

  An optional ingress rule on each target's security group
  (`manage_target_ingress`). `additional_security_group_ids` adds more groups.
- **IAM.** An instance role with:
  - SSM core;
  - read on the scripts prefix and on the target secrets;
  - `kms:Decrypt` through Secrets Manager and S3 only;
  - write to the run log group;
  - `additional_iam_policy_arns` and `additional_iam_policy_json`.
- **SSM Command document `<name>-run-sql`.** A thin bash launcher around a
  Python 3.9 standard-library runner (`scripts/runner.py`). Modes:
  - `run`: one script;
  - `runbook`: a named ordered list of steps from `runbooks`, reviewed in the
    plan;
  - `manifest`: the same step list as JSON in S3, gated by
    `allow_s3_manifests`;
  - `check`: one target or every target.

  Every parameter is constrained by `allowedValues` or `allowedPattern`.
- **Steps.** Each step has a target, a script, an optional SHA-256, a type
  (`sql`, or `shell` behind `allow_shell_steps`), a transaction mode, a
  timeout, `on_error` and variables. Runs support:
  - `StartAt`, to resume from a step;
  - `DryRun`, which verifies every script and connects to every target
    without executing anything;
  - a per-run summary.
- **Engines.** PostgreSQL family (`psql`), MySQL family (`mysql` or the MariaDB
  client), Oracle (`sqlplus`). Variables reach SQL through `psql --set`,
  `SET @name` and `DEFINE`.
- **Targets.** Each target also takes `client_options`, `env` and default
  `variables`.
- **Credential handling.** The password never reaches argv. Client output is
  masked against it. Each client runs in its own process group, which is
  terminated on a step timeout or when the run is stopped.
- **Run log group** with retention.
- **Outputs:**
  - `commands`: check, run, runbook, dry run, resume, manifest, result, logs,
    session;
  - `runbooks`;
  - `network_contract`;
  - `kms_key_policy_requirements`;
  - `operator_policy_json`.
- **Tests:**
  - `tests/bastion.tftest.hcl`: 27 runs, mocked provider;
  - `tests/runner/test_runner.py`: 48 tests that run the real runner against a
    fake AWS CLI and stub clients. They include the rendered launcher end to
    end, and a shell step generating the script the next step runs.
- Shell steps receive `DMS_SCRIPTS_BUCKET`, `DMS_SCRIPTS_PREFIX` and the AWS
  region, so a step can upload what it generates.
- Examples:
  - `oracle-to-aurora`: hand-written scripts;
  - `postgres-to-aurora`: the schema taken from the source with `pg_dump` by
    shell steps, with full load + CDC paused before cached changes for
    post-data.
