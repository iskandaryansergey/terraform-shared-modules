# kms/modules/replica

Creates the disaster-recovery replicas of a key set, in the replica region,
from the key set's `output.replicas`. It decides nothing: each replica's
policy, aliases, tags, deletion window and notification patterns are
compiled by the key set ([`../..`](../..)), where they are reviewed.

## Usage

Next to the key set, with a provider for the replica region:

```hcl
module "kms_dr" {
  source    = "app.terraform.io/citadel-hub/kms/aws//modules/replica"
  version   = "~> 2.0"
  providers = { aws = aws.dr }

  replicas = module.kms.replicas
}
```

Or in a separate workspace in the replica region. The primary's workspace
re-exports `module.kms.replicas` as a root output and shares its state with
this workspace (Settings, General, Remote state sharing), and the key set
names this workspace's role in `replica_deployers`:

```hcl
provider "aws" {
  region = "eu-west-1" # the key set's replica_region
}

provider "tfe" {}

data "tfe_outputs" "kms" {
  organization = var.tfe_organization
  workspace    = "ledger-kms"
}

module "kms_dr" {
  source  = "app.terraform.io/citadel-hub/kms/aws//modules/replica"
  version = "~> 2.0"

  replicas      = data.tfe_outputs.kms.nonsensitive_values.replicas
  sns_topic_arn = var.dr_security_topic_arn
}
```

A separate workspace has its own state, so an existing replica's policy,
aliases and rules keep applying while the primary region is down. Creating a
replica needs the primary region: `ReplicateKey` runs there. A run trigger
from the primary's workspace keeps the replicas current.

A replica of a key with imported material (`origin = "EXTERNAL"`) is created
pending import: the key set's `key_custodians` import the same material in
this region, out of band.

## What it refuses

- **A provider in any region but the key set's `replica_region`.** The
  compiled policies name that region; a replica elsewhere would get the wrong
  presets.
- **A `replicas` value of another shape** (its `schema` field): one this
  module does not read. Use this module from the same kms major version as
  the key set.

## Requirements

| | |
|---|---|
| Terraform | >= 1.9.0 |
| AWS provider | >= 5.73.0, < 6.0.0, one provider in the replica region |
| The key set | applied first: a replica needs its primary |
| The role applying this module | in the key set's `deployers` (same workspace) or `replica_deployers` (separate workspace): the replica's policy is compiled there, and only those principals may replicate the primary and own the replica. Its IAM also needs `kms:CreateKey` and `kms:TagResource` in the replica region |

## Inputs

| Input | Default | |
|---|---|---|
| `replicas` | (required) | the key set's `output.replicas`. Null creates nothing |
| `sns_topic_arn` | `""` | a topic in the replica region for the replicas' key events. The events are the key set's `notifications.events` |
| `tags` | `{}` | extra tags; the key set's tags win |
| `create` | `true` | `false` plans nothing |

## Outputs

| Output | For |
|---|---|
| `keys`, `key_arns` | consumers in the replica region: ARN, ID and alias ARNs |
| `sns_topic_policy_requirement` | the replica region's topic owner |
| `verify_commands` | CloudShell checks after an apply |

## Limits

- **Never exercised against real AWS**, like the key set.
- **The replica follows the key set's last apply.** A policy change made in
  the key set reaches the replicas only when this module applies.
- **Destroying the replica** schedules its deletion with the primary's
  deletion window. The primary is unaffected; a primary scheduled for deletion
  waits until its last replica is gone.
- **After a failover** (`UpdatePrimaryRegion`) this module and the key set
  both fail to read their key: they manage a fixed primary and replica.

Versioning, support and the changelog are the key set's:
[CHANGELOG](../../CHANGELOG.md).
