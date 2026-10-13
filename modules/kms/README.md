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
  source    = "app.terraform.io/citadel-hub/kms/aws"
  version   = "~> 2.0"
  providers = { aws = aws, aws.replica = aws }

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
  source    = "app.terraform.io/citadel-hub/kms/aws"
  version   = "~> 2.0"
  providers = { aws = aws, aws.replica = aws } # a second region's provider when keys replicate

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

## What it refuses, and what it warns about

**Refused at plan:**

- A `spec` and `usage` that do not combine, e.g. `HMAC_256` with
  `ENCRYPT_DECRYPT`. The provider does not check this; KMS refuses it at
  apply.
- Service presets on a key of the wrong kind. AWS services encrypt with
  symmetric keys only; `route53-dnssec` needs `ECC_NIST_P256` signing, in
  us-east-1.
- `replicate` without `multi_region`, or a replica provider in the primary's
  own region.
- `iam_delegation = false` with no deployer. KMS refuses a policy that would
  lock out the principal applying it, and nobody else could change it later.
- `protect_policy` or `protect_aliases_and_rotation` with no deployer and no
  break-glass: the next apply could not change what they protect.
- Consumer requirements that would make a key public (`"*"` or a non-ARN
  principal), use an action that is not a plain `kms:` action, or ask for a
  management action (`PutKeyPolicy`, `ScheduleKeyDeletion`, ...).
- A key policy over 32768 characters, a character KMS rejects, or two
  statements with the same Sid.
- Assumed-role session ARNs as principals. They change with every session.
- A key in a custom key store that is asymmetric or replicates.
- A key missing a tag listed in `required_tag_keys`.

**Warned by `check` blocks.** Each can be accepted by name in
`acknowledged_checks` and is then listed in `governance`.

| Check | Warns when |
|---|---|
| `symmetric_keys_rotate` | a symmetric key has `rotation = false` |
| `deletion_window_leaves_time_to_notice` | a deletion window is under 30 days |
| `every_requirement_found_its_key` | a consumer requirement names a key outside this set, or no key at all |
| `every_principal_role_is_resolved` | a requirement's role (e.g. `secret_readers`) is not in `principal_roles` |
| `every_requirement_is_machine_readable` | a consumer emits prose-only or malformed requirements, or is not a list |
| `keys_have_an_organization_perimeter` | a key can be reached from another account and `guardrails.organization_id` is empty |
| `deletion_protection_has_an_exemption` | deletion protection is on with no deployer and no break-glass |
| `cloudtrail_events_need_a_trail` | CloudTrail-based notifications are on; they need an active trail |
| `multi_region_keys_are_replicated` | a multi-Region primary has no replica here |
| `key_policies_leave_room_to_grow` | a policy is above 80% of the size limit |
| `strict_mode_keeps_services_named` | `iam_delegation = false`, yet a key lets anyone in the account use it through its services |
| `replicas_have_their_vpc_endpoints` | primaries are behind VPC endpoints and replicas are not |

## Requirements

| | |
|---|---|
| Terraform | >= 1.9.0 (cross-variable validation) |
| AWS provider | >= 5.73.0, < 6.0.0. 5.73 fixed state wedging on a rejected policy |
| Providers | `aws` and `aws.replica`. When nothing replicates, pass `aws` for both |
| Workspace role | `iam:GetRole` on itself, only while the deployer is detected (`deployers` empty, `detect_deployer = true`) |
| CloudTrail | an active trail, only for the CloudTrail-based notifications |

`terraform validate` cannot run on the module directory itself, because of the
aliased provider. CI validates it through `tests/wrapper`.

## Keys

Each entry in `keys` is a key. A `purpose` picks its kind and presets; any
field set on the key overrides or, for `services`, adds to it:

| `purpose` | Kind | Presets |
|---|---|---|
| (none) | symmetric | none |
| `logs` | symmetric | `logs` |
| `secrets` | symmetric | `secretsmanager`, `ssm` |
| `database` | symmetric | `rds`, `dms`, `backup` |
| `storage` | symmetric | `s3`, `ebs`, `efs`, `backup` |
| `messaging` | symmetric | `sns`, `sqs` and the event sources that publish to them |
| `signing` | `ECC_NIST_P256`, `SIGN_VERIFY` | none |
| `mac` | `HMAC_256`, `GENERATE_VERIFY_MAC` | none |
| `dnssec` | `ECC_NIST_P256`, `SIGN_VERIFY` | `route53-dnssec` |

`key_defaults` sets rotation, rotation period, deletion window, service access
and tags for every key that does not set them itself.

## How a policy is built

Each key's policy is built from these statements, in order. A statement with
no principals is left out.

| Statement | From |
|---|---|
| `EnableIamPolicies`: account root, `kms:*` | `iam_delegation = true` (the AWS default). Lets IAM policies grant access |
| `Deployers`, `BreakGlass`: management, policy changes, grants | `deployers` (or the detected planning role), `guardrails.break_glass` |
| `Administrators`: management; no cryptographic use, no grants | `administrators`. Policy changes only with `administrators_can_change_policy` |
| `Auditors`: describe and list | `auditors` |
| `Users`, `Encrypters`, `Decrypters` | the cryptographic actions for the key's kind: all, the producing half, the consuming half. With `require_encryption_context`, only with that context |
| `Describe`, `GrantsForAwsResources` | the same principals and `grant_users`; grants only with `kms:GrantIsForAWSResource` |
| `OtherAccounts…` | `keys[*].accounts`: use and resource grants, delegated to those accounts' IAM |
| Service presets | `keys[*].services`, `via_services` |
| `Consumer…`: one per machine-readable requirement | `consumers` |
| `extra_statements` | per key, the escape hatch |
| `Deny…` guardrails | `guardrails` |

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

| Preset | Principal | Scoped by |
|---|---|---|
| `logs` | `logs.<region>.amazonaws.com` | `kms:EncryptionContext:aws:logs:arn` = log groups in this account |
| `cloudtrail` | `cloudtrail.amazonaws.com` | trail encryption context, `aws:SourceAccount` |
| `eventbridge-bus` | `events.amazonaws.com` | bus encryption context, `aws:SourceAccount` |
| `route53-dnssec` | `dnssec-route53.amazonaws.com` | `aws:SourceAccount`, hosted zone `aws:SourceArn` |
| `cloudwatch-to-sns`, `dms-events-to-sns`, `rds-events-to-sns`, `s3-events-to-sns` | the publishing service | `aws:SourceAccount` |
| `eventbridge-to-sns` | `events.amazonaws.com` | nothing: AWS does not support `aws:Source*` conditions here |
| `eventbridge-to-sqs`, `s3-events-to-sqs`, `sns-to-sqs` | the publishing service | `aws:SourceAccount` |
| `autoscaling-ebs` | the Auto Scaling service-linked role | the role must exist before the key policy names it |

**Caller-path services**, the other 38 (`s3`, `rds`, `secretsmanager`, `ebs`,
`dynamodb`, `glue`, `redshift`, ...). The service calls KMS with the caller's
own identity, through a forward access session. All of a key's caller-path
presets, and its `via_services`, share one statement:

- **Who:** set by `service_access`.
  - `account` (the default): any principal in this account and in
    `keys[*].accounts`, as AWS managed keys allow.
  - `named`: only the key's users, encrypters, decrypters and deployers.
- **Conditions:** `kms:CallerAccount`, and `kms:ViaService` for those services
  only.

`kms:ViaService` never appears on a service-principal statement, because it
only applies to forward access sessions. Step Functions execution roles belong
in `users`, not behind the `states` preset: AWS documents that a ViaService
condition on an execution role breaks executions.

A replica's presets name the replica's region.

## Consumer contracts

Modules in this repo emit `kms_key_policy_requirements`, a list in which each
entry is one need. Contract version 2 (`output.contract_schema`):

| Field | Type | Meaning |
|---|---|---|
| `key` | string | the key ARN, key ID or alias ARN the producer was given |
| `sid` | string | stable within the producer |
| `principals` | object(`services`, `arns`, `roles`) | service principals; IAM ARNs; symbolic roles |
| `actions` | list(string) | `kms:` actions |
| `conditions` | list(object(`test`, `variable`, `values`)) | IAM condition operator, key, values |
| `purpose` | string | why |

**Matching** is per region: a requirement naming the primary's ARN or alias
lands in the primary's policy, one naming the replica's ARN in the replica's.

**Roles.** A producer cannot know who runs Terraform or who reads a secret, so
it names a role. `principal_roles` maps each role to ARNs; `deployer` is built
in and maps to the deployers. What happens to a role nobody resolved depends
on `iam_delegation`:

- `true`: IAM policies cover it, and `coverage` reports it.
- `false`: nothing grants it, and the check warns.

**`output.coverage`** shows where each requirement went. No requirement is
dropped silently.

| Field | Holds |
|---|---|
| `matched` | per key and region, the requirements compiled into its policy |
| `unmatched` | requirements that name a key outside this set |
| `unaddressed` | requirements whose `key` is prose, not an identifier |
| `unresolved_roles` | roles not in `principal_roles` |
| `without_principals` | requirements that resolved to nobody |
| `not_machine_readable`, `malformed` | prose-only entries, and entries of the wrong shape |
| `not_applicable` | requirements with an empty `key`: the producer has that feature off |
| `unreadable_consumers` | consumers that are not a list of requirements |

## Guardrails

Each guardrail is a `Deny` statement for every principal (`"*"`), following
the AWS data-perimeter patterns, with the exemptions AWS services need:

| Setting | Denies | Exempt |
|---|---|---|
| `organization_id`, `trusted_accounts` | use by principals outside the organization; service principals acting for another organization | `trusted_accounts`, the deployers' accounts, AWS service principals |
| `vpc_endpoint_ids`, `replica_vpc_endpoint_ids` | direct cryptographic calls not made through these endpoints | calls a service makes for a caller (`aws:ViaAWSService`), service principals, EBS (`aws:ec2-infrastructure`), `vpc_endpoint_exempt_principals` |
| `deletion_protection` (default on) | `ScheduleKeyDeletion`, `DisableKey` | deployers, `break_glass` |
| `min_deletion_window_days` | scheduling deletion with a shorter window | nobody |
| `protect_policy` | `PutKeyPolicy` | deployers, `break_glass` |
| `protect_aliases_and_rotation` | alias changes, turning rotation off | deployers, `break_glass` |

`output.organization_policy_snippets` gives an SCP and an RCP that enforce
the same perimeter across the organization.

## Notifications

`notifications.sns_topic_arn` sends key events to SNS through EventBridge
rules scoped to this set's keys. Replicas get their own rules in their region,
with `replica_sns_topic_arn`.

| Events | Source | Default |
|---|---|---|
| `deletion`, `rotation`, `import_expiry` | native KMS events | on |
| `schedule_deletion`, `cancel_deletion`, `disable`, `enable`, `policy_change`, `rotation_disabled`, `rotate_on_demand`, `grant_change`, `alias_change`, `tag_change`, `replication` | CloudTrail; needs an active trail | off |

The topic policies must let EventBridge publish:
`output.sns_topic_policy_requirement` has the statement for each region.

## Contract outputs

| Output | For |
|---|---|
| `key_arns`, `keys`, `alias_arns` | the consumers: what to encrypt with |
| `public_keys` | verifiers of signing keys: the PEM public key |
| `iam_policy_statements` | principal owners: the IAM side, when IAM delegation is on |
| `policies` | the reviewer: the compiled policy of every key and replica |
| `coverage` | the reviewer: what each consumer requirement became |
| `governance` | the change record: rotation, deletion windows, delegation, deployers and their source, guardrails, who manages and uses each key |
| `organization_policy_snippets` | the platform team: SCP and RCP |
| `sns_topic_policy_requirement` | the topic owner: the statement that lets the notification rules publish |
| `cost` | FinOps: monthly storage cost now and its upper bound |
| `verify_commands` | CloudShell checks after an apply |
| `contract_schema` | producing modules: the requirement shape to emit |

## Examples

| Example | Shows |
|---|---|
| [minimal](examples/minimal) | `name` alone: one key and every default |
| [basic](examples/basic) | A workload's key set with purposes, presets, the organization perimeter and notifications |
| [strict](examples/strict) | No IAM delegation, separated duties, VPC endpoints, every guardrail |
| [contract-driven](examples/contract-driven) | Key policies compiled from `db-script-runner`'s requirements, with no statement written by hand |
| [multi-region](examples/multi-region) | A multi-Region key with a disaster-recovery replica and notifications in both regions |

## Most-used inputs

| Input | Default | |
|---|---|---|
| `name` | (required) | key set name; default aliases are `alias/<name>-<key>` |
| `keys` | `{ main = {} }` | the keys; see the `keys` input on the registry |
| `key_defaults` | rotate yearly, 30-day window | defaults for every key |
| `deployers` | `[]`: the planning role, detected | the Terraform workspace role(s) |
| `administrators` | `[]` | key administrators for every key |
| `users` | `[]` | key users for every key |
| `auditors` | `[]` | read-only access to every key |
| `consumers` | `{}` | other modules' `kms_key_policy_requirements` |
| `principal_roles` | `{}` | ARNs for the symbolic roles in requirements |
| `iam_delegation` | `true` | `false`: only the key policy grants access |
| `guardrails` | deletion protection on | perimeters and protections |
| `notifications` | none | key events to an SNS topic |
| `required_tag_keys` | `[]` | tags every key must carry |
| `acknowledged_checks` | `[]` | warnings you have decided to accept |

## Limits

- **Never exercised against real AWS.** Policies, presets and guardrails come
  from the AWS documentation and the provider v5.100 source, and are tested
  with a mocked provider. The first apply in a sandbox account is the real
  test. Read `policies` before applying to production keys.
- **`terraform destroy` removes the guardrails first.** Destroying
  `aws_kms_key_policy` resets the key's policy to the provider default
  (account root, `kms:*`) before the key's deletion is scheduled. The denies
  protect a managed key; they do not stop its own workspace from destroying
  it. `governance.survives_terraform_destroy` says so.
- **A detected deployer follows whoever plans.** A local plan by another role
  shows a policy change. Name the workspace role in `deployers` to pin it.
- **The first plan of a new key** shows its policy as known after apply,
  because requirements match on the key's ARN. Later plans show the diff.
- **Consumer statements land after the key exists.** A consumer resource that
  checks the key when it is created needs the matching preset (see above).
- **CloudTrail-based notifications** need an active trail.
- **No on-demand rotation.** Provider 5.x has no argument for it. Use
  `aws kms rotate-key-on-demand`.
- **These force a new key:** changing `spec`, `usage`, `multi_region` or
  `custom_key_store_id`.
- **Every grant argument forces a new grant**, with a new grant token.
- **IAM principals must exist** before a policy names them. The provider
  retries for 2–3 minutes.
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

Every breaking change is marked in the changelog, and a major release has an
upgrade guide. Supported: the latest minor of the current major. Deprecated
inputs stay for one minor release with a warning.
