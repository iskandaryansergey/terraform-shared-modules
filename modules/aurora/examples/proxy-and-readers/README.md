# RDS Proxy and a read tier

Aurora MySQL 8.0 with a writer, a reader and a `reporting` reader, RDS Proxy in front with IAM auth required and a reader endpoint, reader autoscaling on CPU (1 to 4), a custom `reporting` endpoint whose only member is the reporting instance, and I/O-Optimized storage.

## Topology

```
app (SG) --> RDS Proxy (IAM REQUIRED) --> writer / reader / reporting + autoscaled readers
BI tools --> custom endpoint "reporting" ----------------> reporting instance only
```

## Failure modes

- **IAM auth REQUIRED**: clients sending a password are refused, with an error that looks like a wrong password. Callers need `rds-db:connect` on the proxy resource ID.
- **The proxy needs 443 to the Secrets Manager endpoint** (`proxy.egress_rules`) and a key policy letting its role decrypt the app secret; otherwise targets stay unavailable and apply still succeeds.
- **The proxy logs in as an app-user secret**, not the master user (`use_master_secret` is left off on purpose).
- **Session pinning** defeats pooling; watch `DatabaseConnectionsCurrentlySessionPinned`.
- **Autoscaled replicas** are not in state and not in the `reporting` endpoint; scale to 0 before destroying.
- I/O-Optimized pays off when I/O exceeds roughly 25% of the bill.

## Use it from the private registry

`main.tf` here uses `source = "../../"` so CI validates the example against the
working tree. In your own configuration, take the module from the registry and
copy the settings:

```hcl
module "aurora" {
  source  = "app.terraform.io/citadel-hub/aurora/aws"
  version = "~> 2.0"

  name           = "catalogue"
  engine         = "aurora-mysql"
  engine_version = "8.0"
  instance_class = "db.r7g.large"
  instances = {
    writer    = { promotion_tier = 0 }
    reader    = { promotion_tier = 1 }
    reporting = { promotion_tier = 15 }
  }
  storage_type = "aurora-iopt1"
  proxy = {
    enabled     = true
    iam_auth    = "REQUIRED"
    secret_arns = [var.app_secret_arn]
    # ingress_rules and egress_rules as in main.tf
  }
  # ... reader_autoscaling, custom_endpoints, network and tags from main.tf
}
```

Needs Terraform >= 1.7.0 and the AWS provider >= 5.90.0, < 7.0.0.

## Required inputs

| Input | Meaning |
|---|---|
| `vpc_id` | VPC for the database and proxy groups |
| `subnet_ids` | Two or more private subnets |
| `app_security_group_id` | App tier SG, allowed to the proxy |
| `bi_security_group_id` | BI tools SG, direct to the database |
| `app_secret_arn` | Secret of the app database user the proxy logs in as |
| `secretsmanager_endpoint_security_group_id` | SG of the Secrets Manager endpoint |
| `kms_key_arn` | CMK in this region |
| `sns_topic_arn` | SNS topic in this region |

No input has a default for a real resource: bring your own network, key and
topic. Never the default VPC.

## What to read in the plan

- `kms_key_policy_requirements`: includes the proxy role decrypting the app secret.
- `network_contract`: the Secrets Manager endpoint the proxy relies on.
- `governance`: proxy, autoscaling and endpoint posture.
- Autoscaled replicas do not appear in the plan.

## Handing outputs to another workspace

Publish the outputs from this workspace, then read them with `tfe_outputs`:

```hcl
data "tfe_outputs" "aurora" {
  organization = "citadel-hub"
  workspace    = "catalogue-aurora"
}

locals {
  proxy_host = data.tfe_outputs.aurora.nonsensitive_values.connection.proxy_host
}
```

`tfe_outputs` values are sensitive; keep them out of logs. Outputs hold no
secret, only ARNs, endpoints and requirements.
