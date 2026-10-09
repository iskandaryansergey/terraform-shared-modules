# Isolated VPC, regulated PostgreSQL

A regulated Aurora PostgreSQL 16 cluster in an isolated VPC (no internet gateway, no NAT): two `db.r7g.large` instances pinned to two AZs, a customer-managed key enforced by `require_cmk`, an RDS-managed master secret rotated in a Sunday window, TLS enforced, ingress from an application security group and an on-prem CIDR, alarms and events to SNS, 90-day log exports, Performance Insights, Enhanced Monitoring, deletion protection and a final snapshot.

## Topology

```
app tier (SG)  ---\
                   >--- :5432 --->  Aurora, 2 instances, 2 AZs
on-prem (CIDR) ---/                 no IGW, no NAT, no public address
```

## Failure modes

- **Key policy** missing RDS, Secrets Manager or CloudWatch Logs: the apply fails part way with an access-denied naming the key. Check `kms_key_policy_requirements` first.
- **SNS topic policy** not allowing RDS and CloudWatch: the apply succeeds and no alarm ever arrives. See `sns_topic_policy_requirement`.
- **No route back for on-prem**, or a firewall dropping 5432: a healthy cluster and a timeout that looks like a security group problem. Run `verify_commands` from the app tier.
- **Secret fetch** needs the Secrets Manager interface endpoint in the VPC (see `network_contract`).
- A client that caches the password at start-up fails after rotation.

## Use it from the private registry

`main.tf` here uses `source = "../../"` so CI validates the example against the
working tree. In your own configuration, take the module from the registry and
copy the settings:

```hcl
module "aurora" {
  source  = "app.terraform.io/citadel-hub/aurora/aws"
  version = "~> 2.0"

  name           = "ledger"
  engine         = "aurora-postgresql"
  engine_version = "16"
  instance_class = "db.r7g.large"
  instances = {
    a = { availability_zone = "eu-west-2a", promotion_tier = 0 }
    b = { availability_zone = "eu-west-2b", promotion_tier = 1 }
  }
  # ... then the network, kms_key_arn, sns_topic_arn and tags from main.tf
}
```

Needs Terraform >= 1.7.0 and the AWS provider >= 5.90.0, < 7.0.0.

## Required inputs

| Input | Meaning |
|---|---|
| `vpc_id` | The isolated VPC |
| `subnet_ids` | Two or more private subnets, no internet route |
| `availability_zones` | Exactly two AZs matching the subnets |
| `app_security_group_id` | Application tier SG allowed to connect |
| `onprem_cidr` | On-prem range, never /0 |
| `kms_key_arn` | CMK in this region |
| `sns_topic_arn` | SNS topic in this region |

No input has a default for a real resource: bring your own network, key and
topic. Never the default VPC.

## What to read in the plan

- `kms_key_policy_requirements`: hand to the key owner before the first apply.
- `sns_topic_policy_requirement`: hand to the topic owner.
- `network_contract`: the VPC endpoints and CA bundle this needs.
- `governance`: the posture as data, and `acknowledged_checks` (empty here, so no advisory check should warn).

## Handing outputs to another workspace

Publish the outputs from this workspace, then read them with `tfe_outputs`:

```hcl
data "tfe_outputs" "aurora" {
  organization = "citadel-hub"
  workspace    = "ledger-aurora"
}

locals {
  aurora_connection = data.tfe_outputs.aurora.nonsensitive_values.connection
}
```

`tfe_outputs` values are sensitive; keep them out of logs. Outputs hold no
secret, only ARNs, endpoints and requirements.
