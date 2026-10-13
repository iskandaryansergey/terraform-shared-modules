# Changelog: kms

All notable changes to this module. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the module
follows [semantic versioning](https://semver.org). Releases are tagged
`kms-vX.Y.Z`.

Entries marked **BREAKING** change what an unchanged caller's plan does.
Moving from 1.x is covered in [docs/UPGRADE-2.0.md](docs/UPGRADE-2.0.md).

## [2.0.0] - Planned Release

A rewrite. One call now manages a set of keys, and each key's policy is
compiled from roles, service presets, consumer contracts and guardrails.

### Added

- `keys`: a map of keys, default `{ main = {} }`, so `name` alone plans.
  Per key: `purpose` profiles (logs, secrets, database, storage, messaging,
  signing, mac, dnssec) that set the kind and presets; `spec` and `usage`,
  checked against each other; aliases; rotation; deletion window;
  multi-Region; replica; service presets; roles; grants; extra statements;
  tags. `key_defaults` sets rotation, deletion window, service access and
  tags for every key.
- Roles with separated duties:
  - `deployers`: detected from the planning role when not named
    (`detect_deployer`);
  - `administrators`: explicit action list, no wildcards, no cryptographic
    use, no policy changes unless `administrators_can_change_policy`;
  - `auditors`: read-only;
  - `users`, `encrypters`, `decrypters` (the two halves of the cryptographic
    actions), `grant_users`;
  - `accounts`: other accounts, which then delegate to their own principals.
  `iam_delegation = false` removes the account-root statement.
- `require_encryption_context`: direct calls must carry the named context
  keys.
- 51 service presets: service principals only where the service calls KMS as
  itself, `kms:ViaService` with `kms:CallerAccount` for the rest; `via_services`
  for anything not in the catalogue; `service_access` (`account` or `named`)
  to choose who may use a key through its services. `output.service_presets`
  lists them.
- Consumer contracts: `consumers` reads other modules'
  `kms_key_policy_requirements` (contract v2), resolves symbolic roles through
  `principal_roles`, refuses requirements that would make a key public or
  hand out management actions, and compiles the rest into
  `aws_kms_key_policy`, per region. `output.coverage` reports every
  requirement that did not compile, and why.
- Guardrails, each with the exemptions AWS services need:
  - organization perimeter, with confused-deputy protection;
  - VPC endpoint perimeter, per region;
  - deletion protection;
  - a minimum deletion window;
  - policy protection;
  - alias and rotation protection;
  - break-glass principals.
  `output.organization_policy_snippets` gives the matching SCP and RCP.
- Custom key stores (CloudHSM and external).
- Multi-Region replicas through the `aws.replica` provider, with their own
  policy, aliases, VPC endpoints, consumer requirements and notifications.
- Notifications: native KMS events by default; eleven CloudTrail-based event
  groups on request. `output.sns_topic_policy_requirement` has one statement
  per region.
- `required_tag_keys`.
- Outputs:
  - `keys`, `key_arns`, `key_ids`, `alias_arns`, `public_keys`;
  - `policies`, `coverage`, `governance`;
  - `iam_policy_statements`, `service_presets`,
    `organization_policy_snippets`;
  - `cost`, `verify_commands`, `contract_schema`.
- Twelve advisory checks, with `acknowledged_checks`.
- Tests: 127 runs against a mocked provider. Examples: minimal, basic,
  strict, contract-driven, multi-region.

### Changed

- **BREAKING:** the interface. Every 1.x input is mapped in the upgrade guide.
- **BREAKING:** resource addresses are keyed by key name (`aws_kms_key.this["<key>"]`).
- **BREAKING:** the key policy is owned by `aws_kms_key_policy`; the key is
  created with a bootstrap policy and ignores later changes to it.
- **BREAKING:** the default policy no longer gives the account root `kms:*` and
  nothing else. It adds a statement for the deployer (named or detected), and
  deletion protection is on by default.
- **BREAKING:** the default description is `<name> <key>, managed by
  Terraform`. It is updated in place; set `description` to keep the 1.x one.
- **BREAKING:** grants default to `retire_on_delete = false` (1.x: `true`).
  Any grant argument change replaces the grant.
- **BREAKING:** floors raised to Terraform 1.9 and AWS provider 5.73.
- **BREAKING:** tags: `Name`, `Purpose` and `Environment` are gone. The
  module sets `ManagedBy`, `Module`, `KeySet` and `Key` last.

### Removed

- `key_policy` (a complete hand-written policy). Use `extra_statements`, or
  `iam_delegation` with roles and presets.
- `purpose`, `environment`, `create_alias`, `alias_name`, `is_enabled`
  (now per key `enabled`).
- `bypass_policy_lockout_safety_check`. The check is never bypassed.
- Grant `grant_creation_tokens`.
