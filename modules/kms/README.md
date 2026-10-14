# terraform-aws-kms

A workload's KMS key set in one call. Each key's policy is **compiled**, not
written by hand, from four sources:

- who manages the keys and who uses them;
- presets for the AWS services that use them, with the conditions AWS
  documents;
- the requirements other modules emit, which this module reads as data;
- guardrails: organization and VPC endpoint perimeters, and protection of
  deletion, policy and aliases.

[Costs](COSTS.md) ·
[Changelog](CHANGELOG.md) ·
[Upgrading from 1.x](docs/UPGRADE-2.0.md)

## Usage

The smallest call is one key, `main`, with every default:

```hcl
module "kms" {
  source  = "app.terraform.io/citadel-hub/kms/aws"
  version = "~> 2.0"

  name = "orders"
}
```

The defaults:

- symmetric, rotating yearly, with a 30-day deletion window;
- IAM policies in the account grant use, as with the AWS default policy;
- the role running the plan is the deployer, and only it may delete or
  disable the key.

A workload's key set, used by other modules:

```hcl
module "kms" {
  source  = "app.terraform.io/citadel-hub/kms/aws"
  version = "~> 2.0"

  name      = "payments"
  deployers = [var.workspace_role_arn]

  keys = {
    data = { purpose = "database", users = [var.app_role_arn] }
    logs = { purpose = "logs" }
  }

  # Other modules hand back what they need from these keys.
  consumers = {
    aurora = module.aurora.kms_key_policy_requirements
    dms    = module.dms.kms_key_policy_requirements
  }

  guardrails = { organization_id = var.organization_id }
}
```

Pass `module.kms.key_arns["data"]` to the consumers. Each consumer passes the
ARN back in its requirements, and that is how a requirement finds its key.
There is no cycle: the policy is a separate resource from the key.

Replicas for disaster recovery are created by a second, small module; see
[Disaster recovery](#disaster-recovery).

## What it refuses, and what it warns about

**Refused at plan:**

- A `spec` and `usage` that do not combine, e.g. `HMAC_256` with
  `ENCRYPT_DECRYPT`. The provider does not check this; KMS refuses it at
  apply.
- Service presets on a key of the wrong kind. AWS services encrypt with
  symmetric keys only; `route53-dnssec` needs `ECC_NIST_P256` signing, in
  us-east-1.
- `replicate` without `multi_region`, or without a `replica_region` other
  than the key's own.
- `iam_delegation = false`, `protect_policy` or `protect_aliases_and_rotation`
  without named `deployers`. KMS refuses a policy that would lock out the
  principal applying it, and a detected deployer is the plan's role, not
  necessarily the apply's.
- Consumer requirements that would make a key public (`"*"`, a wildcard or a
  non-ARN principal), use an action that is not a plain `kms:` action, or
  cover a management action in any spelling (`kms:Put*`, `kms:putkeypolicy`).
  Refused on the first plan, before any key exists, when the requirement is
  known at plan (a role created in the same run is checked at apply).
- A key policy over 32768 characters (the replica's too), a character KMS
  rejects, or two statements with the same Sid.
- Assumed-role session ARNs, or wildcards, as principals.
- A key in a custom key store that is not `SYMMETRIC_DEFAULT`, is
  multi-Region, or replicates.
- Two keys with the same alias, counting the default `<name>-<key>`.
- Grant operations the key kind cannot take (`Decrypt` on a signing key), or
  encryption context constraints on a non-symmetric key.
- More than 50 tags on a key, or a key missing a tag listed in
  `required_tag_keys`.
- An EventBridge pattern over 4096 characters (a few dozen keys in one set).
- Imported key material (`origin = "EXTERNAL"`) on anything but a symmetric
  key outside a custom key store: provider 5.x imports symmetric material
  only.
- Generations whose `<key>-<generation>` names repeat, or collide with another
  key; an algorithm name KMS does not use.
- A rotation period above `guardrails.max_rotation_period_days`: the apply
  would deny itself.

**Warned by `check` blocks.** Each can be accepted by name in
`acknowledged_checks` and is then listed in `governance`.

| Check                                   | Warns when                                                                                      |
| --------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `symmetric_keys_rotate`                 | a symmetric key has `rotation = false`                                                          |
| `deletion_window_leaves_time_to_notice` | a deletion window is under 30 days                                                              |
| `every_requirement_found_its_key`       | a consumer requirement names a key outside this set, or a `key` that is not an ARN, ID or alias |
| `every_principal_role_is_resolved`      | a requirement's role (e.g. `secret_readers`) is not in `principal_roles`                        |
| `every_requirement_is_machine_readable` | a consumer emits prose-only or malformed requirements, or is not a list                         |
| `keys_have_an_organization_perimeter`   | a key can be reached from another account and `guardrails.organization_id` is empty             |
| `deletion_protection_has_an_exemption`  | deletion protection is on with no deployer and no break-glass                                   |
| `cloudtrail_events_need_a_trail`        | CloudTrail-based notifications are on; they need an active trail                                |
| `multi_region_keys_are_replicated`      | a multi-Region primary has `replicate = false`                                                  |
| `key_policies_leave_room_to_grow`       | a policy is above 26000 characters (about 80% of the limit)                                     |
| `strict_mode_keeps_services_named`      | `iam_delegation = false`, yet a key lets anyone in the account use it through its services      |
| `replicas_have_their_vpc_endpoints`     | primaries are behind VPC endpoints and replicas are not                                         |
| `duties_are_separated`                  | a principal both administers and uses a key                                                     |
| `imported_material_expiry_is_watched`   | a key with imported material has no `import_expiry` notification                                |

## Requirements

|                      |                                                                                                                                                                                                                                                                                                                   |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Terraform            | >= 1.9.0 (cross-variable validation)                                                                                                                                                                                                                                                                              |
| AWS provider         | >= 5.73.0, < 6.0.0. 5.73 fixed state wedging on a rejected policy                                                                                                                                                                                                                                                 |
| Providers            | `aws`, nothing else. `modules/replica` takes one provider in the replica region                                                                                                                                                                                                                                   |
| Workspace role (IAM) | `kms:CreateKey`, `kms:TagResource`, `kms:ListAliases` and, for destroy, `kms:PutKeyPolicy` and `kms:ScheduleKeyDeletion` (the policy is reset to the account default before the key is deleted); `events:PutRule`, `events:PutTargets` with notifications; `iam:GetRole` on itself while the deployer is detected |
| Deployers            | named in `deployers` for `protect_policy`, `protect_aliases_and_rotation` or `iam_delegation = false`. A detected deployer is the plan's role; with separate HCP Terraform plan and apply roles, list both                                                                                                        |
| CloudTrail           | an active trail, only for the CloudTrail-based notifications                                                                                                                                                                                                                                                      |
| Workspace settings   | Terraform version 1.9 or later; `terraform init -upgrade` once so the lock file allows provider 5.73+                                                                                                                                                                                                             |

## Keys

Each entry in `keys` is a key. A `purpose` picks its kind and presets; any
field set on the key overrides or, for `services`, adds to it:

| `purpose`   | Kind                              | Presets                                                                                                                                                                                        |
| ----------- | --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| (none)      | symmetric                         | none                                                                                                                                                                                           |
| `logs`      | symmetric                         | `logs`                                                                                                                                                                                         |
| `secrets`   | symmetric                         | `secretsmanager`, `ssm`                                                                                                                                                                        |
| `database`  | symmetric                         | `rds`, `dms`, `backup`                                                                                                                                                                         |
| `storage`   | symmetric                         | `s3`, `ebs`, `efs`, `backup`                                                                                                                                                                   |
| `messaging` | symmetric                         | `sns`, `sqs`, `cloudwatch-to-sns`, `eventbridge-to-sns`, `eventbridge-to-sqs`, `sns-to-sqs`. Add `s3-events-to-*`, `rds-events-to-sns` or `dms-events-to-sns` in `services` when those publish |
| `signing`   | `ECC_NIST_P256`, `SIGN_VERIFY`    | none                                                                                                                                                                                           |
| `mac`       | `HMAC_256`, `GENERATE_VERIFY_MAC` | none                                                                                                                                                                                           |
| `dnssec`    | `ECC_NIST_P256`, `SIGN_VERIFY`    | `route53-dnssec`                                                                                                                                                                               |

`key_defaults` sets rotation, rotation period, deletion window, service access
and tags for every key that does not set them itself.

## How a policy is built

Each key's policy is built from these statements, in order. A statement with
no principals is left out.

| Statement                                                                                                         | From                                                                                                                                                 |
| ----------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `EnableIamPolicies`: account root, `kms:*`                                                                        | `iam_delegation = true` (the AWS default). Lets IAM policies grant access                                                                            |
| `Deployers`, `BreakGlass`: management, policy changes, grants, replication                                        | `deployers` (or the detected planning role), `guardrails.break_glass`                                                                                |
| `Administrators`: management; no cryptographic use, no grants, no replication                                     | `administrators`. Policy changes only with `administrators_can_change_policy`                                                                        |
| `Auditors`: describe and list                                                                                     | `auditors`                                                                                                                                           |
| `Users`, `Encrypters`, `Decrypters`                                                                               | the cryptographic actions for the key's kind: all, the producing half, the consuming half. With `require_encryption_context`, only with that context |
| `Describe`                                                                                                        | users, encrypters, decrypters and `grant_users`                                                                                                      |
| `GrantsForAwsResources`                                                                                           | users and `grant_users`, symmetric keys only; grants only with `kms:GrantIsForAWSResource`                                                           |
| `OtherAccounts…`                                                                                                  | `keys[*].accounts`: use and resource grants, delegated to those accounts' IAM                                                                        |
| `KeyCustodians…`                                                                                                  | `key_custodians`, on imported-material keys: import parameters (SHA-256 wrapping only), import and delete material                                   |
| `DenyOtherAlgorithms`, `DenyKeyMaterialDeletion`                                                                  | `keys[*].allowed_algorithms`; `guardrails.protect_key_material`                                                                                      |
| `DenyReplicationOutsideTheReplicaRegion`, `DenyPromotionOutsideTheTwoRegions`                                     | multi-Region keys with `replica_region` set                                                                                                          |
| `ReplicaDeployers`                                                                                                | `replica_deployers`: replicate the primary; own the replica                                                                                          |
| Service presets: `Service…`, `Source…`, `ServiceLinkedAutoScaling…`, `ThroughServices`, `ThroughServicesGrants`   | `keys[*].services`, `via_services`                                                                                                                   |
| `Consumer<Consumer><index><sid>`: one per machine-readable requirement, plus `…Grants` for unscoped grant actions | `consumers`                                                                                                                                          |
| `extra_statements`                                                                                                | per key, the escape hatch                                                                                                                            |
| `Deny…` guardrails                                                                                                | `guardrails`                                                                                                                                         |

Management actions are listed explicitly. The AWS default policy uses
wildcards (`kms:Create*`, `kms:Put*`), which also grant every operation KMS
adds later.

The key is **created** with every statement but the consumers'. They join the
live policy through `aws_kms_key_policy`, once the consumers exist. So a
service that checks the key when its resource is created (CloudWatch Logs,
CloudTrail, an EventBridge bus) needs its preset on the key, not only a
consumer requirement.

`output.iam_policy_statements` gives, per key, the IAM statements a principal
needs on its side when `iam_delegation` is on.

### Service presets

`output.service_presets` lists all 51. Two kinds:

**Service principals**, for services that call KMS as themselves:

| Preset                                                                            | Principal                                               | Scoped by                                                                             |
| --------------------------------------------------------------------------------- | ------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `logs`                                                                            | `logs.<region>.amazonaws.com`                           | `kms:EncryptionContext:aws:logs:arn` = log groups in this account                     |
| `cloudtrail`                                                                      | `cloudtrail.amazonaws.com`                              | trail encryption context, `aws:SourceAccount`                                         |
| `eventbridge-bus`                                                                 | `events.amazonaws.com`                                  | bus encryption context, `aws:SourceAccount` (its `DescribeKey` statement is unscoped) |
| `route53-dnssec`                                                                  | `dnssec-route53.amazonaws.com`                          | `aws:SourceAccount`, hosted zone `aws:SourceArn`                                      |
| `cloudwatch-to-sns`, `dms-events-to-sns`, `rds-events-to-sns`, `s3-events-to-sns` | the publishing service                                  | `aws:SourceAccount`                                                                   |
| `eventbridge-to-sns`                                                              | `events.amazonaws.com`                                  | nothing: AWS does not support `aws:Source*` conditions here                           |
| `eventbridge-to-sqs`, `s3-events-to-sqs`, `sns-to-sqs`                            | the publishing service                                  | `aws:SourceAccount`                                                                   |
| `ses`                                                                             | `ses.amazonaws.com` (receiving mail, publishing to SNS) | `aws:SourceAccount`                                                                   |
| `autoscaling-ebs`                                                                 | the Auto Scaling service-linked role                    | the role must exist before the key policy names it                                    |

**Caller-path services**, the other 37 (`s3`, `rds`, `secretsmanager`, `ebs`,
`dynamodb`, `glue`, `redshift`, ...). The service calls KMS with the caller's
own identity, through a forward access session. All of a key's caller-path
presets, and its `via_services`, share one statement:

- **Who:** set by `service_access`.
  - `account` (the default): any principal in this account and in
    `keys[*].accounts`, as AWS managed keys allow.
  - `named`: only the key's users, encrypters, decrypters, deployers and
    `keys[*].accounts`.
- **Conditions:** `kms:CallerAccount`, and `kms:ViaService` for those services
  only.

`kms:ViaService` never appears on a service-principal statement, because it
only applies to forward access sessions. Step Functions execution roles belong
in `users`, not behind the `states` preset: AWS documents that a ViaService
condition on an execution role breaks executions.

A replica's presets name the replica's region.

`eventbridge-to-sns` (in the `messaging` profile) is unscoped, as AWS
requires. On a key that also carries `eventbridge-bus` or `eventbridge-to-sqs`,
EventBridge can then use the key without their conditions: keep SNS topics on
a key of their own when that matters.

## Consumer contracts

Producing modules (aurora, dms, dms-orchestrator, db-script-runner,
ami-builder, gitlab-runner-fargate-v2) emit `kms_key_policy_requirements`, a
list in which each entry is one need. Contract version 2
(`output.contract_schema`):

| Field        | Type                                       | Meaning                                                                                                                         |
| ------------ | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| `key`        | string                                     | the key ARN, key ID or alias ARN the producer was given                                                                         |
| `sid`        | string                                     | stable within the producer. The compiled Sid also carries the entry's index, so reordering a producer's list renames statements |
| `principals` | object(`services`, `arns`, `roles`)        | service principals; IAM ARNs; symbolic roles                                                                                    |
| `actions`    | list(string)                               | `kms:` actions                                                                                                                  |
| `conditions` | list(object(`test`, `variable`, `values`)) | IAM condition operator, key, values                                                                                             |
| `purpose`    | string                                     | why                                                                                                                             |

**Matching** is per region: a requirement naming the primary's ARN or alias
lands in the primary's policy, one naming the replica's ARN in the replica's.

**What a requirement cannot get.** These stop the plan, before any key is
created:

- a principal that is not an IAM ARN, or contains a wildcard (`"*"` would make
  a key public);
- `kms:*`, or an action that covers a management action in any spelling:
  `kms:PutKeyPolicy`, `kms:Put*`, `kms:putkeypolicy`, `kms:Schedule*`,
  `kms:Replicate*`...

Grant actions (`CreateGrant`, `ListGrants`, `RevokeGrant`) without a
`kms:ViaService` or `kms:GrantIsForAWSResource` condition are compiled into a
second statement, `…Grants`, that allows grants for AWS resources only. Without
that, the principal could grant the key to anyone.

**Roles.** A producer cannot know who runs Terraform or who reads a secret, so
it names a role. `principal_roles` maps each role to ARNs; `deployer` is built
in and maps to the deployers. What happens to a role nobody resolved depends
on `iam_delegation`:

- `true`: IAM policies cover it, and `coverage` reports it.
- `false`: nothing grants it, and the check warns.

**`output.coverage`** shows where each requirement went. No requirement is
dropped silently.

| Field                  | Holds                                                                                     |
| ---------------------- | ----------------------------------------------------------------------------------------- |
| `matched`              | per key and region, the requirements compiled into its policy                             |
| `unmatched`            | requirements that name a key outside this set                                             |
| `unaddressed`          | requirements whose `key` is prose, not an identifier                                      |
| `unresolved_roles`     | roles not in `principal_roles`                                                            |
| `without_principals`   | requirements that resolved to nobody                                                      |
| `not_machine_readable` | prose-only entries                                                                        |
| `malformed`            | a condition without values, the same test and key twice, or a string where a list belongs |
| `not_applicable`       | requirements with an empty `key`: the producer has that feature off                       |
| `unreadable_consumers` | consumers that are not a list of requirements                                             |

## Guardrails

Each guardrail is a `Deny` statement for every principal (`"*"`), following
the AWS data-perimeter patterns, with the exemptions AWS services need:

| Setting                                        | Denies                                                                                         | Exempt                                                                                                                                                                                                                                                        |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `organization_id`, `trusted_accounts`          | use by principals outside the organization; service principals acting for another organization | `trusted_accounts`, the deployers' and `replica_deployers`' accounts, AWS service principals                                                                                                                                                                  |
| `vpc_endpoint_ids`, `replica_vpc_endpoint_ids` | direct cryptographic calls not made through these endpoints                                    | calls a service makes for a caller (`aws:ViaAWSService`), service principals, EBS (`aws:ec2-infrastructure`), service-linked roles, `vpc_endpoint_exempt_principals`. Principals of `keys[*].accounts` calling from their own VPCs are denied unless exempted |
| `deletion_protection` (default on)             | `ScheduleKeyDeletion`, `DisableKey`                                                            | deployers, `break_glass` (and `replica_deployers` on replicas)                                                                                                                                                                                                |
| `min_deletion_window_days`                     | scheduling deletion with a shorter window                                                      | nobody                                                                                                                                                                                                                                                        |
| `min_days_unused_before_deletion`              | scheduling the deletion of a key used in the last N days                                       | nobody                                                                                                                                                                                                                                                        |
| `max_rotation_period_days`                     | enabling rotation with a longer period                                                         | nobody                                                                                                                                                                                                                                                        |
| `protect_tags`                                 | tag changes (a tag is a grant under ABAC)                                                      | deployers, `break_glass`                                                                                                                                                                                                                                      |
| `protect_key_material`                         | deleting imported key material                                                                 | `break_glass`                                                                                                                                                                                                                                                 |
| `break_glass_requires_mfa`                     | anything by `break_glass` without MFA                                                          | nobody                                                                                                                                                                                                                                                        |
| `protect_policy`                               | `PutKeyPolicy`                                                                                 | deployers, `break_glass`                                                                                                                                                                                                                                      |
| `protect_aliases_and_rotation`                 | alias changes, turning rotation off                                                            | deployers, `break_glass`                                                                                                                                                                                                                                      |

Multi-Region keys with `replica_region` set also deny `ReplicateKey` to any
other region, and `UpdatePrimaryRegion` outside the two: a replica's policy is
chosen by whoever replicates, so a copy elsewhere would carry none of these.

**Deletion protection alone stops accidents, not an administrator.** With
`iam_delegation = true`, any IAM principal allowed `kms:PutKeyPolicy` can
rewrite the policy without the deny, then delete the key. `protect_policy`
closes that. It needs named deployers.

`output.organization_policy_snippets` gives the platform team an SCP (no
lockout bypass anywhere; deletion, disabling, policy changes and replication
of these keys only by the deployers and break-glass) and an RCP (the
organization perimeter, empty without `organization_id`).

## Notifications

`notifications.sns_topic_arn` sends key events to SNS through EventBridge
rules scoped to this set's keys. The same events are compiled for the
replicas, and `modules/replica` sends them to a topic in the replica region.

| Events                                                                                                                                                                             | Source                            | Default |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------- | ------- |
| `deletion`, `rotation`, `import_expiry`                                                                                                                                            | native KMS events                 | on      |
| `schedule_deletion`, `cancel_deletion`, `disable`, `enable`, `policy_change`, `rotation_disabled`, `rotate_on_demand`, `grant_change`, `alias_change`, `tag_change`, `replication` | CloudTrail; needs an active trail | off     |

The topic policy must let EventBridge publish:
`output.sns_topic_policy_requirement` has the statement. `modules/replica`
emits its own for the replica region's topic.

## Disaster recovery

A multi-Region key's replica is created by a second module, `modules/replica`,
with one provider in the replica region. This module still compiles
everything the replica needs and hands it over in `output.replicas`:

```hcl
module "kms" {
  source  = "app.terraform.io/citadel-hub/kms/aws"
  version = "~> 2.0"

  name           = "ledger"
  replica_region = "eu-west-1"
  keys           = { data = { multi_region = true, replicate = true } }
}

module "kms_dr" {
  source    = "app.terraform.io/citadel-hub/kms/aws//modules/replica"
  version   = "~> 2.0"
  providers = { aws = aws.dr } # a provider in eu-west-1

  replicas = module.kms.replicas
}
```

What stays here, and why:

- **The replica's policy is compiled here.** It uses the replica region's
  presets, `guardrails.replica_vpc_endpoint_ids`, and the consumer
  requirements that name the replica's ARN. There is one place to review it:
  `output.policies.<key>.replica`.
- **The replica ARN is known here.** A replica keeps its primary's key ID,
  so `keys.<key>.replica_arn` is known once the primary exists, before the
  replica does.
- **`modules/replica` only creates resources.** It refuses a provider in any
  region other than `replica_region`.

`modules/replica` can live in the same workspace, or in a separate one in the
disaster-recovery region that reads `replicas` through `tfe_outputs`:

- **Name that workspace's role in `replica_deployers`.** The replica's policy
  is compiled here; only named principals may replicate the primary and own
  the replica. Without it, `iam_delegation = false` refuses the replication,
  and `protect_policy` locks the role out of the replica's policy.
- **Creating a replica needs the primary region**: `ReplicateKey` runs there.
  An existing replica's policy, aliases and rules keep applying while the
  primary region is down.
- **After a failover** (`UpdatePrimaryRegion`) both workspaces fail to read
  their key: the module manages a fixed primary and replica. Restore the
  roles, or move the state.

The [multi-region](examples/multi-region) example shows both layouts.

## Regulated workloads

| Need                                                                | Input                                                         | What it does                                                                                                                                                       |
| ------------------------------------------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Customer-supplied key material (BYOK)                               | `keys[*].origin = "EXTERNAL"`, `key_custodians`               | creates the key pending import; the custodians import the material out of band, so it never reaches state. Deleting the material makes the data unreadable at once |
| A cryptoperiod for keys that cannot rotate (signing, MAC, imported) | `keys[*].generations`                                         | one key per generation; the last takes the aliases and grants, `key_arns["<key>"]` follows it, earlier ones stay to decrypt and verify. `output.generations`       |
| Tenant isolation                                                    | `keys[*].encryption_context_values`                           | direct use must carry context values, policy variables allowed (`${aws:PrincipalTag/tenant}`)                                                                      |
| Access by tag (ABAC)                                                | `iam_policy_statements.<key>.abac`, `guardrails.protect_tags` | an IAM statement scoped by the module's `KeySet` and `Key` tags; only the owners change tags                                                                       |
| Algorithm policy                                                    | `keys[*].allowed_algorithms`                                  | denies every other encryption, signing or MAC algorithm                                                                                                            |
| Cryptoperiod that cannot be stretched                               | `guardrails.max_rotation_period_days`                         | denies enabling rotation with a longer period                                                                                                                      |
| Dual control for emergencies                                        | `guardrails.break_glass_requires_mfa`                         | break-glass needs an MFA session                                                                                                                                   |
| Detective controls                                                  | `output.compliance_snippets`                                  | AWS Config rules (Security Hub KMS.3, KMS.4, required tags) and the CIS metric filter for disabled or deleted keys, for the platform team                          |
| Separation of duties                                                | `duties_are_separated` check                                  | warns when one principal administers and uses a key                                                                                                                |

The [regulated](examples/regulated) example uses all of them.

## Contract outputs

| Output                                                | For                                                                                                                              |
| ----------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `key_arns`, `keys`, `alias_arns`                      | the consumers: what to encrypt with                                                                                              |
| `public_keys`                                         | verifiers of signing keys: the PEM public key, every generation                                                                  |
| `generations`                                         | rotation runbooks: each key's generations and the active one                                                                     |
| `iam_policy_statements`                               | principal owners: the IAM side, when IAM delegation is on                                                                        |
| `policies`                                            | the reviewer: the compiled policy of every key and replica                                                                       |
| `coverage`                                            | the reviewer: what each consumer requirement became                                                                              |
| `governance`                                          | the change record: rotation, deletion windows, delegation, deployers and their source, guardrails, who manages and uses each key |
| `organization_policy_snippets`, `compliance_snippets` | the platform team: SCP and RCP; Config rules and metric filters                                                                  |
| `sns_topic_policy_requirement`                        | the topic owner: the statement that lets the notification rules publish                                                          |
| `replicas`                                            | `modules/replica`: everything it needs to create the replicas                                                                    |
| `cost`                                                | FinOps: monthly storage cost now and its upper bound                                                                             |
| `verify_commands`                                     | CloudShell checks after an apply                                                                                                 |
| `contract_schema`                                     | producing modules: the requirement shape to emit                                                                                 |

## Examples

| Example                                     | Shows                                                                                                                    |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| [minimal](examples/minimal)                 | `name` alone: one key and every default                                                                                  |
| [basic](examples/basic)                     | A workload's key set with purposes, presets, the organization perimeter and notifications                                |
| [strict](examples/strict)                   | No IAM delegation, separated duties, VPC endpoints, every guardrail                                                      |
| [regulated](examples/regulated)             | Imported key material, signing-key generations, tenant isolation, algorithm limits, MFA break-glass, compliance snippets |
| [contract-driven](examples/contract-driven) | Key policies compiled from `db-script-runner`'s requirements, with no statement written by hand                          |
| [multi-region](examples/multi-region)       | A multi-Region key with a disaster-recovery replica through `modules/replica`, and notifications in both regions         |

## Most-used inputs

| Input                 | Default                           |                                                        |
| --------------------- | --------------------------------- | ------------------------------------------------------ |
| `name`                | (required)                        | key set name; default aliases are `alias/<name>-<key>` |
| `keys`                | `{ main = {} }`                   | the keys; see the `keys` input on the registry         |
| `key_defaults`        | rotate yearly, 30-day window      | defaults for every key                                 |
| `deployers`           | `[]`: the planning role, detected | the Terraform workspace role(s)                        |
| `administrators`      | `[]`                              | key administrators for every key                       |
| `users`               | `[]`                              | key users for every key                                |
| `auditors`            | `[]`                              | read-only access to every key                          |
| `consumers`           | `{}`                              | other modules' `kms_key_policy_requirements`           |
| `principal_roles`     | `{}`                              | ARNs for the symbolic roles in requirements            |
| `iam_delegation`      | `true`                            | `false`: only the key policy grants access             |
| `guardrails`          | deletion protection on            | perimeters and protections                             |
| `notifications`       | none                              | key events to an SNS topic                             |
| `replica_region`      | `""`                              | where `modules/replica` creates the replicas           |
| `required_tag_keys`   | `[]`                              | tags every key must carry                              |
| `acknowledged_checks` | `[]`                              | warnings you have decided to accept                    |

## Limits

- **`terraform destroy` removes the guardrails first.** Destroying
  `aws_kms_key_policy` resets the key's policy to the provider default
  (account root, `kms:*`) before the key's deletion is scheduled. The denies
  protect a managed key; they do not stop its own workspace from destroying
  it. `governance.survives_terraform_destroy` says so.
- **A detected deployer follows whoever plans.** A local plan by another role
  shows a policy change, and with separate HCP Terraform plan and apply roles
  the detected one is the plan role - which then holds management rights in
  the key policy. Name the roles in `deployers` for anything but a sandbox.
- **The first plan of a new key** shows its policy as known after apply,
  because requirements match on the key's ARN. Later plans show the diff.
- **Consumer statements land after the key exists.** A consumer resource that
  checks the key when it is created needs the matching preset (see above).
- **CloudTrail-based notifications** need an active trail.
- **A replica follows its primary's plan.** A policy change made here
  reaches the replica only when `modules/replica` applies. In a separate
  workspace, link the two with a run trigger.
- **No on-demand rotation.** Provider 5.x has no argument for it. Use
  `aws kms rotate-key-on-demand`.
- **Imported key material:**
  - symmetric only on provider 5.x (asymmetric and HMAC import arrive in 6.x);
  - unusable until imported; a replica needs the same material imported in
    its region;
  - material imported with an expiry stops the key when it ends.
- **Removing a generation deletes that key**, after its deletion window.
  Anything it encrypted or signed must be re-encrypted or re-signed first.
- **These force a new key:** changing `spec`, `usage`, `multi_region` or
  `custom_key_store_id`.
- **Every grant argument forces a new grant**, with a new grant token.
- **IAM principals must exist** before a policy names them. The provider
  retries for 2–3 minutes. A principal deleted later blocks every policy
  change until it is removed from the inputs.
- **Retiring grants on destroy** (`retire_on_delete`) needs the grant's
  `retiring_principal`, or `kms:RetireGrant` in the deployer's IAM policy.
- **Administrators can change tags and aliases.** Where IAM policies grant
  access by tag or alias (ABAC), that is a way to grant themselves use; turn
  on `protect_aliases_and_rotation`, and keep tag-based grants off these keys.
- **Security Hub KMS.5** (no public access) may flag wildcard conditions such
  as the `logs` preset's `log-group:*`. Run `verify_commands.<key>.public`
  (IAM Access Analyzer) for the authoritative answer.
- **Partitions:** `aws` and `aws-us-gov`. In `aws-cn` the presets' service
  names (`.amazonaws.com`) do not match.
- **Requests are not modelled.** KMS request quotas and cost are shared across
  the account. `COSTS.md` gives the arithmetic.

## Versioning and support

Semantic versioning, tagged `kms-vX.Y.Z`.

**Breaking** means anything that changes an unchanged caller's plan:

- removed or renamed inputs and outputs;
- changed defaults;
- replacements;
- address changes;
- raised version floors.

Every breaking change is marked in the [changelog](CHANGELOG.md), and a
major release has an upgrade guide ([2.0](docs/UPGRADE-2.0.md)). Supported:
the latest minor of the current major, on Terraform >= 1.9 and AWS provider
5.73–5.x. Deprecated inputs stay for one minor release with a warning.
