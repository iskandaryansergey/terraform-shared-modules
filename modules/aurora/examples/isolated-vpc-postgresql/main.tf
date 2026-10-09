# Regulated Aurora PostgreSQL in an isolated VPC.
#
# Topology:
#
#   app tier (SG)  ---\
#                      >--- :5432 --->  Aurora cluster, 2 instances, 2 AZs
#   on-prem (CIDR) ---/                 no IGW, no NAT, no public address
#
# The database needs no outbound path of its own: replication, backups, log
# export, Enhanced Monitoring and secret rotation all happen on the AWS side.
# What does need one is a client that fetches the master secret, which needs
# the Secrets Manager interface endpoint in this VPC. output.network_contract
# lists every endpoint this configuration depends on.
#
# What fails, and how it shows up:
#
#   - A CMK whose key policy does not allow RDS, Secrets Manager or CloudWatch
#     Logs. The apply fails part way - cluster, secret or log group - with an
#     access-denied that names the key. output.kms_key_policy_requirements is
#     the exact list; check the key before you apply.
#   - An SNS topic whose policy does not allow RDS events and CloudWatch alarms
#     to publish. The apply succeeds and nothing ever arrives. This is the
#     silent one. output.sns_topic_policy_requirement is what the topic needs.
#   - On-prem clients with no route back, or a firewall that drops 5432. The
#     cluster is healthy and the connection times out, which reads exactly like
#     a security group problem. Run verify_commands from the app tier first.
#   - Instance 'a' is not always the writer: AWS makes whichever instance
#     finishes creating first the writer. promotion_tier orders failover only.

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
  description = "The isolated VPC. Bring your own - the module creates a security group in it and nothing else."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id))
    error_message = "vpc_id must be a VPC ID (vpc-xxxxxxxx)."
  }
}

variable "subnet_ids" {
  description = "Private database subnets, one per AZ in at least two AZs. They need no internet route, and the on-prem CIDR needs a route back to them."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2 && alltrue([for s in var.subnet_ids : can(regex("^subnet-[0-9a-f]{8,17}$", s))])
    error_message = "subnet_ids needs at least two subnet IDs (subnet-xxxxxxxx), in different AZs."
  }
}

variable "availability_zones" {
  description = "Exactly two AZs in var.region, matching the subnets above. Each instance is pinned to one, so a single AZ loss cannot take both."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) == 2 && length(distinct(var.availability_zones)) == 2 && alltrue([for az in var.availability_zones : can(regex("^[a-z]{2}(-[a-z]+)+-[0-9][a-z]$", az))])
    error_message = "availability_zones must be two different AZ names, like [\"eu-west-2a\", \"eu-west-2b\"]."
  }
}

variable "app_security_group_id" {
  description = "Security group of the application tier. The database accepts connections from members of this group and nothing else in the VPC."
  type        = string

  validation {
    condition     = can(regex("^sg-[0-9a-f]{8,17}$", var.app_security_group_id))
    error_message = "app_security_group_id must be a security group ID (sg-xxxxxxxx)."
  }
}

variable "onprem_cidr" {
  description = "On-premises range that connects directly (batch, DBAs), reached over Direct Connect or Cloud WAN. The narrowest range that covers them - never 0.0.0.0/0, which the module refuses."
  type        = string

  validation {
    condition     = can(cidrhost(var.onprem_cidr, 0)) && !endswith(var.onprem_cidr, "/0")
    error_message = "onprem_cidr must be a valid IPv4 CIDR other than /0."
  }
}

variable "iam_role_path" {
  description = "Path for the roles the module creates (Enhanced Monitoring here), for estates whose SCPs or permissions boundaries select roles by path. Starts and ends with /."
  type        = string
  default     = "/"

  validation {
    condition     = can(regex("^/([a-zA-Z0-9+=,.@_-]+/)*$", var.iam_role_path))
    error_message = "iam_role_path must start and end with / (for example /platform/databases/)."
  }
}

variable "kms_key_arn" {
  description = "Customer-managed key, in this region, for storage, the master secret, Performance Insights and the log groups. Its policy must allow what output.kms_key_policy_requirements lists."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN."
  }
}

variable "sns_topic_arn" {
  description = "Existing SNS topic, in this region, for alarms and RDS events. Its policy must allow output.sns_topic_policy_requirement, and if it is encrypted, so must its key."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:", var.sns_topic_arn))
    error_message = "sns_topic_arn must be an SNS topic ARN."
  }
}

module "aurora" {
  source = "../../"

  name = "ledger"

  # Exact version. With auto_minor_version_upgrade at its default (false) the
  # cluster stays on it until you change it here, so every upgrade is a plan
  # you review. Check what is current with:
  #   aws rds describe-db-engine-versions --engine aurora-postgresql \
  #     --query 'DBEngineVersions[].EngineVersion'
  engine         = "aurora-postgresql"
  engine_version = "17.9"

  # Graviton, memory-optimised. Burstable classes (db.t4g) run out of CPU
  # credits under sustained load, so they are for dev only.
  instance_class = "db.r7g.large"

  # Two instances in two AZs: one fails, the other is already running. Tier 0
  # fails over first. Pinned AZs are what makes "two AZs" a statement rather
  # than a hope - left empty, AWS usually spreads them but does not promise to.
  instances = {
    a = { availability_zone = var.availability_zones[0], promotion_tier = 0 }
    b = { availability_zone = var.availability_zones[1], promotion_tier = 1 }
  }

  database_name = "ledger"
  # A named admin user rather than a shared "postgres"-style default, so the
  # audit log says whose account it is. The module rejects only the accounts
  # RDS reserves for itself (rdsadmin and friends) at plan time; the engine's
  # own reserved words are rejected by the API at create.
  master_username = "ledger_admin"

  # Network. The module creates the subnet group and one security group with
  # exactly these ingress rules and no egress at all: a database initiates
  # nothing, so there is nothing for an egress rule to allow.
  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids
  ingress_rules = {
    app    = { referenced_security_group_id = var.app_security_group_id, description = "Ledger application tier" }
    onprem = { cidr_ipv4 = var.onprem_cidr, description = "Data centre batch and DBA access over the WAN" }
  }

  # Encryption. require_cmk turns "forgot a key on one of five things" into a
  # plan failure: storage, the master secret, Performance Insights and the log
  # groups all use this key, and none can silently fall back to an AWS-managed
  # one. An AWS-managed key cannot be shared cross-account, so neither could the
  # snapshots - and changing the key later replaces the cluster.
  kms_key_arn = var.kms_key_arn
  require_cmk = true

  # Credentials. These are the defaults, stated because an auditor asks. RDS
  # generates the master password, stores it in Secrets Manager under the CMK
  # and rotates it every 7 days. It never touches Terraform state; the secret
  # ARN is in output.connection.
  manage_master_user_password = true

  # Rotation pinned into a change window: Sundays 03:00 UTC, allowed to take
  # up to 3 hours. The RDS default is every 7 days at a time RDS picks, which
  # is the middle of someone's working day. Every client must re-read the
  # secret after a rotation - one that caches the password at start-up fails
  # at its next new connection, and that is the failure to rehearse first.
  master_password_rotation = {
    schedule_expression = "cron(0 3 ? * SUN *)"
    duration            = "3h"
  }

  # Refuse unencrypted connections: rds.force_ssl = 1 in the cluster parameter
  # group. The default, stated for the same reason. Clients that verify the
  # server certificate need the CA bundle named in output.network_contract.
  enforce_tls = true

  # Short-lived IAM tokens for applications instead of a password. The database
  # user still has to be granted rds_iam. Failures land in the iam-db-auth-error
  # log exported below.
  iam_database_authentication_enabled = true

  # Alarms and event subscriptions only exist when there is somewhere to send
  # them. alarm_connections is about 80% of the ~1800 connections a 16 GiB
  # instance allows; recompute it if instance_class changes.
  sns_topic_arn     = var.sns_topic_arn
  alarm_connections = 1400

  # Engine logs leave the instance, or they age out on it within days and go
  # with it when it is replaced. 90 days covers a quarter-end review. Ingestion
  # is billed per GB, and lowering log_min_duration_statement below the
  # module's 5000 ms default is what multiplies it. The log groups use
  # kms_key_arn, so its policy must allow CloudWatch Logs.
  enabled_cloudwatch_logs_exports = ["postgresql", "iam-db-auth-error"]
  log_retention_days              = 90

  # log_group_class stays STANDARD (the default). INFREQUENT_ACCESS costs about
  # half as much to ingest, but has no metric filters, subscription filters or
  # Live Tail - so it cannot feed an alert or a SIEM. Consider it only for a
  # log type nobody alerts on and that exists for retention. Changing it later
  # replaces the log groups, and the logs in them.
  log_group_class = "STANDARD"

  # Roles the module creates go under this path.
  iam_role_path = var.iam_role_path

  # Observability. Database Insights standard and Performance Insights with the
  # free 7 days of history; raising retention beyond that is billed per vCPU-
  # month. Enhanced Monitoring is the only view of the OS during an incident.
  database_insights_mode              = "standard"
  performance_insights_enabled        = true
  performance_insights_retention_days = 7
  enhanced_monitoring_interval        = 60

  # The longest point-in-time window RDS offers. Backup storage up to the size
  # of the cluster volume is free; beyond it, it is billed per GB-month, which
  # is the line that grows quietly on a busy cluster. Anything longer than 35
  # days is AWS Backup's job, not this setting's.
  backup_retention_days = 35

  # Deleting this database takes two deliberate steps: set false and apply,
  # then destroy. Both are defaults, stated because they are the point. The
  # final snapshot is named <name>-final and is billed until someone deletes it.
  deletion_protection = true
  skip_final_snapshot = false

  # Every key in required_tag_keys must be present and non-empty or the plan
  # fails, so nothing this module creates is anonymous in Cost Explorer. Tags
  # are copied to snapshots (copy_tags_to_snapshot defaults to true).
  required_tag_keys = ["Environment", "Owner", "CostCentre", "DataClass", "Application"]
  tags = {
    Environment = "production"
    Owner       = "platform-data"
    CostCentre  = "cc-4410"
    DataClass   = "confidential"
    Application = "ledger"
  }
}

output "connection" {
  description = "Everything a client needs to connect, with no secret in it. Hand to the application team."
  value       = module.aurora.connection
}

output "governance" {
  description = "The posture, as data, for the change record."
  value       = module.aurora.governance
}

output "network_contract" {
  description = "Hand to whoever owns the VPC: the endpoints an isolated VPC must have, and the CA bundle clients verify against."
  value       = module.aurora.network_contract
}

output "kms_key_policy_requirements" {
  description = "Hand to the key owner. Check the key policy against this before the first apply."
  value       = module.aurora.kms_key_policy_requirements
}

output "sns_topic_policy_requirement" {
  description = "Hand to the topic owner. Without it the apply succeeds and no alarm ever arrives."
  value       = module.aurora.sns_topic_policy_requirement
}

output "verify_commands" {
  description = "Run after apply, from inside the VPC where the command needs a connection. plaintext_is_refused must fail."
  value       = module.aurora.verify_commands
}
