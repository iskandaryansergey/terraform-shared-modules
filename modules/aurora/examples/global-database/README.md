# Global database across two regions

An Aurora PostgreSQL 17 global database: a writable primary in eu-west-2 (two `db.r7g.large`, creates the global cluster) and a read-only secondary in eu-west-1 (one instance, own CMK and network, write forwarding on). Two module calls with provider aliases; the secondary reads `module.primary.global_cluster_identifier`, which orders it after the primary cluster and its instances.

## Topology

```
eu-west-2 primary (2 instances)  ====storage replication====>  eu-west-1 secondary (1 reader)
  global cluster "ledger-global"                                 own KMS key, subnets, SG
```

## Failure modes

- **AWS does not support the RDS-managed secret on a global database.** Both calls set `manage_master_user_password = false`; the primary takes `master_password` with `allow_plaintext_credentials = true`, so the password is in this workspace's state in plaintext. Keep it in a sensitive HCP Terraform workspace variable and restrict state access. The `credentials_are_not_in_state` check is acknowledged for that reason.
- **The secondary needs its own key** in its region, and its own key policy check.
- **Engine and version must match** on both sides.
- **Failover is an operation**, not a Terraform change; afterwards the roles in code no longer match reality.
- **No reader autoscaling** on a secondary (AWS does not support it).
- Both calls share `name = "ledger"`: IAM role names include the region, so they do not collide.

## Use it from the private registry

`main.tf` here uses `source = "../../"` so CI validates the example against the
working tree. In your own configuration, take the module from the registry and
copy the settings:

```hcl
module "aurora" {
  source  = "app.terraform.io/citadel-hub/aurora/aws"
  version = "~> 2.0"

  providers = { aws = aws.secondary }
  name                           = "ledger"
  engine                         = "aurora-postgresql"
  engine_version                 = "17.9"
  instance_class                 = "db.r7g.large"
  instances                      = { a = {} }
  global_cluster_role            = "secondary"
  global_cluster_identifier      = module.primary.global_cluster_identifier
  enable_global_write_forwarding = true
  manage_master_user_password    = false
  # ... own kms_key_arn, subnets and security groups
}
```

Needs Terraform >= 1.7.0 and the AWS provider >= 5.90.0, < 7.0.0.

## Required inputs

| Input | Meaning |
|---|---|
| `master_password` | Primary master password. Sensitive; supply from a sensitive workspace variable, never a literal. Lands in state |
| `primary` | Object: vpc_id, subnet_ids, kms_key_arn, sns_topic_arn, client_sg_id for eu-west-2 |
| `secondary` | Same shape, for eu-west-1; nothing is reusable from the primary |

No input has a default for a real resource: bring your own network, key and
topic. Never the default VPC.

## What to read in the plan

- `kms_key_policy_requirements` per region: two keys, two policies.
- `governance`: both postures; the secondary shows the global role and write forwarding.
- The plan creates the global cluster, then the primary, then the secondary, in that order.

## Handing outputs to another workspace

Publish the outputs from this workspace, then read them with `tfe_outputs`:

```hcl
data "tfe_outputs" "aurora" {
  organization = "citadel-hub"
  workspace    = "ledger-global-aurora"
}

locals {
  aurora_connection = data.tfe_outputs.aurora.nonsensitive_values.primary_connection
}
```

`tfe_outputs` values are sensitive; keep them out of logs. Outputs hold no
secret, only ARNs, endpoints and requirements.
