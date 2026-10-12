# Serverless v2 for dev

A disposable Aurora PostgreSQL 17 cluster on Serverless v2 that costs no compute while idle: one `db.serverless` instance scaling 0 to 4 ACU, pausing after 1800 s without connections. Deletion protection and the final snapshot are off, there is no SNS topic, and the advisory checks those corners would trip are listed in `acknowledged_checks` so each stays a recorded decision.

## Topology

```
developers / CI (SG) --- :5432 ---> 1 x db.serverless (0-4 ACU, auto-pause 1800 s)
                                    AWS-managed key, no alarms, destroy in one step
```

## Failure modes

- **A paused cluster looks down.** The first connection waits about 15 seconds; set client connect timeouts to 30 s or more.
- **Engines older than 16.3** (or the equivalent minor of 13-15) cannot pause; pin an exact recent minor (16.3 or later, or any 17.x).
- **Max capacity is the bill ceiling**: 4 ACU billed at full tilt, with no alarm to say so.
- **Not a production starting point.** The AWS-managed key cannot be changed later without replacing the cluster; start from `isolated-vpc-postgresql`.

## Use it from the private registry

`main.tf` here uses `source = "../../"` so CI validates the example against the
working tree. In your own configuration, take the module from the registry and
copy the settings:

```hcl
module "aurora" {
  source  = "app.terraform.io/citadel-hub/aurora/aws"
  version = "~> 2.0"

  name           = "orders-dev"
  engine         = "aurora-postgresql"
  engine_version = "17.9"
  instance_class = "db.serverless"
  instances      = { "1" = {} }
  serverlessv2_scaling_configuration = {
    min_capacity             = 0
    max_capacity             = 4
    seconds_until_auto_pause = 1800
  }
  create_alarms              = false
  create_event_subscriptions = false
  acknowledged_checks        = ["cluster_survives_an_az", "somebody_hears_a_failover"]
  # ... plus the deletion settings, network and tags from main.tf
}
```

Needs Terraform >= 1.7.0 and the AWS provider >= 5.90.0, < 7.0.0.

## Required inputs

| Input | Meaning |
|---|---|
| `vpc_id` | The dev VPC |
| `subnet_ids` | Two or more private subnets |
| `developer_security_group_id` | SG of the bastion, VPN or CI runner |

No input has a default for a real resource: bring your own network, key and
topic. Never the default VPC.

## What to read in the plan

- `governance`: expect no notifications, no deletion protection and no final snapshot, and the four acknowledged checks listed.
- `network_contract`: what the dev VPC must provide.
- `kms_key_policy_requirements`: empty for the AWS-managed key.

## Handing outputs to another workspace

Publish the outputs from this workspace, then read them with `tfe_outputs`:

```hcl
data "tfe_outputs" "aurora" {
  organization = "citadel-hub"
  workspace    = "orders-dev-aurora"
}

locals {
  aurora_connection = data.tfe_outputs.aurora.nonsensitive_values.connection
}
```

`tfe_outputs` values are sensitive; keep them out of logs. Outputs hold no
secret, only ARNs, endpoints and requirements.
