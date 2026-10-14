# Example: a multi-Region key with a disaster-recovery replica

One key, `data`: a multi-Region primary in eu-west-2, and its replica in
eu-west-1.

| Call | Provider | Does |
|---|---|---|
| `module.kms` | default (eu-west-2) | creates the primary, and compiles everything the replica needs into `output.replicas` |
| `module.kms_dr` (`modules/replica`) | `aws.dr` (eu-west-1) | creates the replica, its policy, aliases and notification rules from that output |

What it shows:

- **The policy is compiled once, in the key set.** The replica's policy
  names its own region (the `logs` preset grants
  `logs.eu-west-1.amazonaws.com`) and carries
  `guardrails.replica_vpc_endpoint_ids` and the consumer requirements that
  name the replica's ARN. `modules/replica` only creates resources.
- **The replica ARN is known early.** A replica keeps its primary's key ID,
  so `module.kms.keys.data.replica_arn` is known once the primary exists.
  Consumers can be wired to it before the replica is created.
- **Notifications in both regions.** EventBridge rules see only their own
  region's events and target topics in it. Each module emits the topic
  policy statement for its own region.
- **Cost:** `output.cost` counts the replica: $1/month plus its rotations,
  like a key.

## A separate disaster-recovery workspace

The two calls do not have to share a workspace. In the disaster-recovery
region's workspace, read the blueprint from the primary's:

```hcl
data "tfe_outputs" "kms" {
  organization = var.tfe_organization
  workspace    = "ledger-kms"
}

module "kms_dr" {
  source  = "app.terraform.io/citadel-hub/kms/aws//modules/replica"
  version = "~> 2.0"

  replicas = data.tfe_outputs.kms.nonsensitive_values.replicas
}
```

The primary's workspace must re-export `module.kms.replicas` as a root output
and share its state with the disaster-recovery workspace, and the key set must
name that workspace's role in `replica_deployers`. The disaster-recovery
workspace needs an `aws` provider in eu-west-1 and the `tfe` provider. With the
replica in its own state, an outage of the primary region does not stop
changes to the existing replica; creating one needs the primary region.

What fails in it:

- **`multi_region` is fixed at creation.** It cannot be turned off, and
  turning it on replaces the key.
- **A provider in the wrong region is refused.** `modules/replica` checks that
  its provider is in `replica_region`, because the compiled policy names that
  region.
- **The replica follows the primary's plan.** A policy change made in the
  key set reaches the replica only when the replica's workspace applies.
  Separate workspaces should be linked by a run trigger.
- **VPC endpoint guardrails are regional.** A replica needs
  `guardrails.replica_vpc_endpoint_ids`, and the key set warns when it is
  missing.
