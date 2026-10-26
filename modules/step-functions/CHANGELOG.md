# Changelog: step-functions

All notable changes to this module. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the module
follows [semantic versioning](https://semver.org): see "Versioning and
support" in [README.md](README.md). Releases are tagged `vX.Y.Z`.

## [0.1.0] - unreleased

First release.

### Added

- One state machine, STANDARD or EXPRESS, from an ASL (or JSONata) definition.
- An execution role with the documented confused-deputy trust and the
  permissions AWS documents per integration (Lambda, SQS, SNS, DynamoDB,
  EventBridge, nested state machines, ECS, Glue, KMS), Distributed Map,
  logging, X-Ray and customer-managed encryption; plus `role.statements`; or
  a brought role with `output.role_requirements`.
- A `/aws/vendedlogs/states/<name>` log group with retention, class and key.
- `publish` and `aliases` with canary routing.
- EventBridge Scheduler schedules and EventBridge rules, each with a role
  scoped to this state machine.
- Alarms on failed, timed-out, aborted, throttled and long-running executions.
- 7 advisory checks, including one that compares the ARNs in the definition
  with what the role is granted.
- Contract outputs: `start_execution_policy_json`, `deployer_requirements`,
  `role_requirements`, `kms_key_policy_requirements` (v2), `governance`,
  `verify_commands`.
