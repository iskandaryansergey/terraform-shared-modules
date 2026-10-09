# Aurora Global Database: a writable primary in eu-west-2 and a read-only
# secondary in eu-west-1, replicated at the storage layer (typically under a
# second of lag).
#
# Topology:
#
#   eu-west-2 (primary)                       eu-west-1 (secondary)
#   +-------------------------------+         +-------------------------------+
#   | global cluster "ledger-global"| ======> | cluster, own CMK, own subnets |
#   | cluster, 2x db.r7g.large      | storage | 1x db.r7g.large reader        |
#   +-------------------------------+ repl.   +-------------------------------+
#
# Two module calls, one provider alias each. The secondary is created after the
# primary because it reads module.primary.global_cluster_identifier - that
# reference is the ordering, so keep it.
#
# What fails, and how it shows up:
#
#   - The secondary's key. An encrypted cluster in a new region needs a key in
#     that region; the primary's CMK does not exist there. The module refuses
#     to plan a secondary without kms_key_arn, and the key policy has to allow
#     RDS and CloudWatch Logs - see output.kms_key_policy_requirements, which
#     is per cluster, so read both.
#   - Different engine or engine_version between the two. The secondary must
#     match the primary. A major-only version resolves to each region's current
#     minor at create time, and a global database needs them compatible; if
#     they are not, pin the same full minor in both.
#   - The secondary's network. Its subnets, VPC and any client security groups
#     are eu-west-1 resources. The IDs in var.secondary are not the primary's.
#   - Failover. Promoting the secondary (a managed failover or a detach) is an
#     operation you run in the console or CLI, not a Terraform change. After
#     it, Terraform's idea of "primary" and "secondary" is wrong until you
#     reconcile it - treat a regional failover as an incident with a runbook.
#   - Credentials. AWS does not support the RDS-managed master secret in a
#     global database, so BOTH calls set manage_master_user_password = false.
#     The primary takes master_password, which lands in Terraform state in
#     plaintext (hence allow_plaintext_credentials = true). Keep it in a
#     sensitive HCP Terraform workspace variable and restrict who can read
#     the state. The secondary takes none - master user, password and
#     database replicate from the primary, and the module refuses
#     database_name or a password there. Nothing rotates this password for
#     you: rotate it by changing the variable (and the database user).
#   - Backtrack is unsupported on a global database; the module refuses it.
#   - Reader autoscaling is not supported on a global secondary, so the
#     secondary has none; it is also unneeded for a standby that serves
#     little traffic until a failover.
#
# Both calls use the same name "ledger" on purpose. Every IAM role the module
# creates (monitoring, proxy) is named "<name>-<region>-...", so the two
# regions do not collide in the account's one global IAM namespace. Cluster
# identifiers are regional, so they do not collide either.

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.90.0, < 7.0.0"
    }
  }
}

provider "aws" {
  region = var.primary_region
}

provider "aws" {
  alias  = "secondary"
  region = var.secondary_region
}

variable "primary_region" {
  description = "Region of the writable cluster."
  type        = string
  default     = "eu-west-2"
}

variable "secondary_region" {
  description = "Region of the read-only cluster. Must differ from primary_region and offer Aurora Global Database for the engine and instance class."
  type        = string
  default     = "eu-west-1"
}

variable "master_password" {
  description = <<-EOT
    Master password of the primary. Stored in Terraform state in plaintext,
    because AWS does not support the RDS-managed secret on a global database.
    Supply it from a sensitive workspace variable, never a literal in a file,
    and restrict access to the state. 8-128 characters, none of / @ " or space.
  EOT
  type        = string
  sensitive   = true
}

variable "primary" {
  description = <<-EOT
    Primary-region inputs, all of them real resources in primary_region:
      vpc_id         the VPC for the cluster's security group
      subnet_ids     private subnets in at least two AZs
      kms_key_arn    customer-managed key in primary_region
      sns_topic_arn  topic in primary_region for alarms and events
      client_sg_id   security group of the application tier
  EOT
  type = object({
    vpc_id        = string
    subnet_ids    = list(string)
    kms_key_arn   = string
    sns_topic_arn = string
    client_sg_id  = string
  })

  validation {
    condition = (
      can(regex("^vpc-[0-9a-f]{8,17}$", var.primary.vpc_id)) &&
      length(var.primary.subnet_ids) >= 2 &&
      alltrue([for s in var.primary.subnet_ids : can(regex("^subnet-[0-9a-f]{8,17}$", s))]) &&
      can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.primary.kms_key_arn)) &&
      can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:", var.primary.sns_topic_arn)) &&
      can(regex("^sg-[0-9a-f]{8,17}$", var.primary.client_sg_id))
    )
    error_message = "primary needs a vpc-... ID, at least two subnet-... IDs, a KMS key ARN, an SNS topic ARN and an sg-... ID."
  }
}

variable "secondary" {
  description = <<-EOT
    Secondary-region inputs, all of them real resources in secondary_region.
    Same shape as var.primary; nothing from the primary region can be reused,
    including the KMS key.
  EOT
  type = object({
    vpc_id        = string
    subnet_ids    = list(string)
    kms_key_arn   = string
    sns_topic_arn = string
    client_sg_id  = string
  })

  validation {
    condition = (
      can(regex("^vpc-[0-9a-f]{8,17}$", var.secondary.vpc_id)) &&
      length(var.secondary.subnet_ids) >= 2 &&
      alltrue([for s in var.secondary.subnet_ids : can(regex("^subnet-[0-9a-f]{8,17}$", s))]) &&
      can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.secondary.kms_key_arn)) &&
      can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:", var.secondary.sns_topic_arn)) &&
      can(regex("^sg-[0-9a-f]{8,17}$", var.secondary.client_sg_id))
    )
    error_message = "secondary needs a vpc-... ID, at least two subnet-... IDs, a KMS key ARN, an SNS topic ARN and an sg-... ID."
  }
}

# A variable validation cannot read another variable before Terraform 1.9, so
# this is a check block (1.5+): it warns at plan time.
check "regions_differ" {
  assert {
    condition     = var.secondary_region != var.primary_region
    error_message = "secondary_region must differ from primary_region. Two clusters in one region is not a global database."
  }
}

locals {
  # Same keys on both clusters, so cost and ownership roll up as one system.
  required_tag_keys = ["Environment", "Owner", "CostCentre", "DataClass", "Application"]
  tags = {
    Environment = "production"
    Owner       = "platform-data"
    CostCentre  = "cc-4410"
    DataClass   = "confidential"
    Application = "ledger"
  }
}

module "primary" {
  source = "../../"

  name = "ledger"

  # Exact version, and the same in both regions. Upgrades of a global database
  # go through the global cluster - README "Global database upgrades".
  engine         = "aurora-postgresql"
  engine_version = "17.9"
  instance_class = "db.r7g.large"
  instances = {
    a = { promotion_tier = 0 }
    b = { promotion_tier = 1 }
  }

  # primary + create_global_cluster (the default) makes this call create the
  # global cluster too. The identifier is global to the account, so it is not
  # the same string as the regional cluster name.
  global_cluster_role       = "primary"
  global_cluster_identifier = "ledger-global"

  database_name   = "ledger"
  master_username = "ledger_admin"

  # AWS does not support the RDS-managed secret on a global database, so the
  # password is supplied instead - and so it is in this workspace's state in
  # plaintext. Keep it in a sensitive HCP Terraform workspace variable and
  # restrict state access. The module's credentials_are_not_in_state check
  # would warn; it is acknowledged here because there is no alternative.
  manage_master_user_password = false
  master_password             = var.master_password
  allow_plaintext_credentials = true
  acknowledged_checks         = ["credentials_are_not_in_state"]

  vpc_id     = var.primary.vpc_id
  subnet_ids = var.primary.subnet_ids
  ingress_rules = {
    app = { referenced_security_group_id = var.primary.client_sg_id, description = "Ledger application tier" }
  }

  kms_key_arn = var.primary.kms_key_arn
  require_cmk = true

  sns_topic_arn                   = var.primary.sns_topic_arn
  enabled_cloudwatch_logs_exports = ["postgresql"]
  log_retention_days              = 90
  backup_retention_days           = 35

  # Replication lag is the number a global database lives by. The default
  # alarm_replica_lag_ms (2000) is within-region reader lag; the cross-region
  # figure - committed transactions not yet stored here - is the module's
  # "<name>-global-rpo-lag" alarm on the secondary (alarm_global_rpo_lag_ms).

  deletion_protection = true
  skip_final_snapshot = false

  required_tag_keys = local.required_tag_keys
  tags              = local.tags
}

module "secondary" {
  source = "../../"

  # Everything in this call is created in the secondary region.
  providers = {
    aws = aws.secondary
  }

  # Same name as the primary - safe, because IAM role names include the region
  # and cluster identifiers are regional.
  name = "ledger"

  # Must match the primary.
  engine         = "aurora-postgresql"
  engine_version = "17.9"
  instance_class = "db.r7g.large"

  # One instance, not zero. A headless secondary (instances = {}) is valid and
  # costs only storage and replication - it is the cheapest warm standby. It
  # is not used here because (1) enable_global_write_forwarding needs a reader
  # to accept the forwarded writes, (2) a regional failover onto a cluster
  # with no instance first waits for one to be created, minutes added to the
  # recovery, and (3) with no instance, local reads and the alarms on this
  # cluster have nothing to measure. If recovery time is not a requirement,
  # instances = {} is the saving.
  instances = {
    a = { promotion_tier = 0 }
  }

  # secondary joins the primary's global cluster. Referencing the primary
  # module's output, not repeating the string, makes Terraform create the
  # secondary after the primary cluster and its instances exist (the output
  # waits for them), not just the global cluster.
  global_cluster_role       = "secondary"
  global_cluster_identifier = module.primary.global_cluster_identifier

  # Forward writes from this region's clients to the primary. They pay the
  # cross-region round trip (tens of milliseconds) and read-your-writes is
  # not guaranteed unless the session sets aurora_replica_read_consistency.
  # Off, this cluster is strictly read-only.
  enable_global_write_forwarding = true

  # No database_name, master_username or password: they replicate from the
  # primary and the module refuses them here. The managed secret is off for
  # the same reason as on the primary.
  manage_master_user_password = false

  # Tighten the cross-region lag alarm to your RPO (default 10000 ms).
  alarm_global_rpo_lag_ms = 5000

  # No reader_autoscaling: AWS does not support it on a global secondary.

  vpc_id     = var.secondary.vpc_id
  subnet_ids = var.secondary.subnet_ids
  ingress_rules = {
    app = { referenced_security_group_id = var.secondary.client_sg_id, description = "Ledger application tier, DR region" }
  }

  # A key in THIS region. The primary's key does not exist here.
  kms_key_arn = var.secondary.kms_key_arn
  require_cmk = true

  sns_topic_arn                   = var.secondary.sns_topic_arn
  enabled_cloudwatch_logs_exports = ["postgresql"]
  log_retention_days              = 90

  deletion_protection = true
  skip_final_snapshot = false

  required_tag_keys = local.required_tag_keys
  tags = merge(local.tags, {
    Role = "dr-secondary"
  })
}

output "global_cluster_identifier" {
  description = "The global cluster both clusters belong to."
  value       = module.primary.global_cluster_identifier
}

output "primary_connection" {
  description = "Connection details for the writable cluster. The password is the one passed as var.master_password; there is no managed secret."
  value       = module.primary.connection
}

output "secondary_connection" {
  description = "Connection details for the read-only cluster. Use host (the cluster endpoint) with write forwarding, reader_host for plain reads."
  value       = module.secondary.connection
}

output "governance" {
  description = "The posture of each cluster, as data, for the change record."
  value = {
    primary   = module.primary.governance
    secondary = module.secondary.governance
  }
}

output "network_contract" {
  description = "Hand to whoever owns each region's VPC."
  value = {
    primary   = module.primary.network_contract
    secondary = module.secondary.network_contract
  }
}

output "kms_key_policy_requirements" {
  description = "Hand to each key owner. The two keys are separate and each policy is checked separately."
  value = {
    primary   = module.primary.kms_key_policy_requirements
    secondary = module.secondary.kms_key_policy_requirements
  }
}

output "verify_commands" {
  description = "Run after apply, one set per region, from inside that region's VPC."
  value = {
    primary   = module.primary.verify_commands
    secondary = module.secondary.verify_commands
  }
}
