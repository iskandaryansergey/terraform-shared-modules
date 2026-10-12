# Dev and test Aurora PostgreSQL on Serverless v2 that costs nothing while idle.
#
# Topology: one db.serverless instance, scaling between 0 and 4 ACU. After 30
# minutes with no connections it pauses and stops billing compute; storage is
# still billed. The first connection after a pause waits about 15 seconds
# while it resumes, so this is for developers and CI, not for anything with a
# latency budget.
#
# Four advisory checks would warn on this configuration. Each names a corner
# this example cuts on purpose, so each is listed in acknowledged_checks below:
# the warning stops, and the decision stays visible in output.governance.
#
#   cluster_survives_an_az              one instance, so one AZ
#   somebody_hears_a_failover           no sns_topic_arn, so no alarms or events
#   deleting_the_cluster_is_protected   deletion_protection = false
#   deleting_the_cluster_leaves_a_snapshot   skip_final_snapshot = true
#
# Do not promote this file to production by editing it. Storage here uses the
# AWS-managed key, and changing kms_key_arn later replaces the cluster - a new,
# empty database with the same name. Start from isolated-vpc-postgresql.
#
# What fails, and how it shows up:
#
#   - A paused cluster looks down. Connection attempts block for the resume,
#     and a client with a 5 second timeout reports an outage that is not one.
#     Set connect timeouts to 30 seconds or more for anything pointed at this.
#   - An engine older than 16.3 (or the equivalent minor in 13 to 15) cannot
#     pause. The module's auto_pause check warns; AWS refuses the scaling
#     configuration at apply. Pin an exact recent minor (16.3+, or any 17.x).
#   - Everything scaled to max_capacity is billed at max_capacity. 4 ACU is the
#     ceiling on the bill, and the alarm that would tell you about it needs a
#     topic this example does not have.

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
  region = var.region
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-west-2"
}

variable "vpc_id" {
  description = "The dev VPC. Bring your own - never the default VPC, whose subnets route to an internet gateway."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id))
    error_message = "vpc_id must be a VPC ID (vpc-xxxxxxxx)."
  }
}

variable "subnet_ids" {
  description = "Private subnets in at least two AZs. Even a one-instance cluster needs a subnet group that spans two, so a later second instance has somewhere to go."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2 && alltrue([for s in var.subnet_ids : can(regex("^subnet-[0-9a-f]{8,17}$", s))])
    error_message = "subnet_ids needs at least two subnet IDs (subnet-xxxxxxxx), in different AZs."
  }
}

variable "developer_security_group_id" {
  description = "Security group of whatever connects: a bastion, a VPN attachment, a CI runner. Only members of it can reach the database."
  type        = string

  validation {
    condition     = can(regex("^sg-[0-9a-f]{8,17}$", var.developer_security_group_id))
    error_message = "developer_security_group_id must be a security group ID (sg-xxxxxxxx)."
  }
}

module "aurora" {
  source = "../../"

  name = "orders-dev"

  # Exact version. Scale-to-zero needs a recent minor (16.3+ on 16; every 17
  # release has it).
  engine         = "aurora-postgresql"
  engine_version = "17.9"

  # The one db.serverless instance. A single key is enough: there is no reader
  # to fail over to, and the alarm that would care is off.
  instance_class = "db.serverless"
  instances = {
    "1" = {}
  }

  # 0 ACU minimum is the whole point: an idle cluster pauses after 1800 s (the
  # shortest sensible value - the setting accepts 300 to 86400) and billing
  # stops. 4 ACU (about 8 GiB) is the cost ceiling; every ACU-hour up to it is
  # billed. If developers run into it, raise it here, in code, where the next
  # person sees it.
  serverlessv2_scaling_configuration = {
    min_capacity             = 0
    max_capacity             = 4
    seconds_until_auto_pause = 1800
  }

  database_name   = "orders"
  master_username = "orders_admin"

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids
  ingress_rules = {
    developers = { referenced_security_group_id = var.developer_security_group_id, description = "Developer and CI access" }
  }

  # No kms_key_arn, no require_cmk: dev data is synthetic or disposable, and
  # the AWS-managed aws/rds key costs nothing and needs no key policy. The
  # master secret is RDS-managed (the default) and also uses the AWS-managed
  # key, so a principal in another account cannot decrypt it.

  # No sns_topic_arn, deliberately. Alarms and event subscriptions default to
  # on and then REQUIRE a topic, so both are switched off explicitly: nothing
  # silent, nothing billed. Add a topic and delete both lines when someone
  # starts to depend on this database.
  create_alarms              = false
  create_event_subscriptions = false

  # The intentional warnings, acknowledged by name. Remove an entry the day
  # the corner it covers stops being cut.
  acknowledged_checks = [
    "cluster_survives_an_az",
    "somebody_hears_a_failover",
    "deleting_the_cluster_is_protected",
    "deleting_the_cluster_leaves_a_snapshot",
  ]

  # Apply changes now rather than at the next maintenance window. Some changes
  # restart the instance, which a dev database can afford and a dev team
  # waiting until Sunday cannot.
  apply_immediately = true

  # Disposable on purpose. Both are the opposite of the module's defaults, so
  # they are written out. terraform destroy works in one step and leaves no
  # snapshot and, with delete_automated_backups, no retained backups to be
  # billed for after the cluster is gone.
  deletion_protection      = false
  skip_final_snapshot      = true
  delete_automated_backups = true

  # Left at the default 7 days: backup storage up to the size of the volume is
  # free, so a shorter window saves nothing on a small dev database.

  # Logs go to CloudWatch for a week - enough to debug the thing you changed
  # yesterday, short enough that ingestion never becomes a line on the bill.
  enabled_cloudwatch_logs_exports = ["postgresql"]
  log_retention_days              = 7

  # Performance Insights stays on: 7 days are free and it is the quickest way
  # to find the slow query. Enhanced Monitoring is off, which also skips the
  # monitoring IAM role; a paused instance emits nothing to it anyway.
  performance_insights_enabled = true
  enhanced_monitoring_interval = 0

  # Dev is still attributable. The required keys make a missing CostCentre a
  # plan failure instead of an anonymous line in Cost Explorer next month.
  required_tag_keys = ["Environment", "Owner", "CostCentre", "DataClass", "Application"]
  tags = {
    Environment = "dev"
    Owner       = "orders-team"
    CostCentre  = "cc-2208"
    DataClass   = "internal"
    Application = "orders"
  }
}

output "connection" {
  description = "Everything a client needs to connect, with no secret in it. The first connection after a pause takes about 15 seconds."
  value       = module.aurora.connection
}

output "governance" {
  description = "The posture, as data. Expect no notifications, no deletion protection and no final snapshot - all deliberate here."
  value       = module.aurora.governance
}

output "network_contract" {
  description = "What the dev VPC has to provide."
  value       = module.aurora.network_contract
}

output "kms_key_policy_requirements" {
  description = "Empty for the AWS-managed key. Here so the contract is the same shape in every example."
  value       = module.aurora.kms_key_policy_requirements
}

output "verify_commands" {
  description = "Run after apply. cluster_is_available also tells you whether the cluster is paused."
  value       = module.aurora.verify_commands
}
