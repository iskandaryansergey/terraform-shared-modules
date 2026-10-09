# Aurora MySQL with a read tier and RDS Proxy in front.
#
# Topology:
#
#   app (SG) ---> RDS Proxy (IAM auth REQUIRED) --+--> writer endpoint --> "writer"
#                 :3306, pooled connections       |
#                                                 +--> proxy reader endpoint
#                                                        --> "reader", "reporting",
#                                                            + autoscaled readers
#   BI tools --> custom endpoint "reporting" --------------> "reporting" only
#
# The writer takes writes, "reader" is the failover target for it, and
# "reporting" is kept off the general reader pool by a custom endpoint, so a
# month-end query has its own endpoint. Replicas added by autoscaling join the
# proxy's reader endpoint and the cluster reader endpoint, never the
# "reporting" endpoint, because that one lists its member explicitly.
#
# What fails, and how it shows up:
#
#   - IAM auth REQUIRED on the proxy means every client must present an IAM
#     token. A client that sends the database password is refused with an
#     access-denied that looks like a wrong password. The caller needs
#     rds-db:connect on the proxy's resource ID (prx-...), not the cluster's.
#   - The proxy's own role reads the app-user secret(s). If a secret's key is
#     customer-managed, that key's policy must allow the proxy role to decrypt;
#     see output.kms_key_policy_requirements. Targets stay UNAVAILABLE until it
#     does, and nothing fails at apply.
#   - The proxy reads Secrets Manager from inside the VPC. Its security group
#     has no egress except to the database, so an explicit 443 rule to the
#     Secrets Manager interface endpoint is required (proxy.egress_rules); the
#     module warns when it is missing. Without it the proxy cannot log in to
#     the database and every client sees a connection error.
#   - The proxy logs in as the database users in proxy.secret_arns. This
#     example takes an app-user secret instead of the master secret: with the
#     master secret (proxy.use_master_secret = true) every client acts with
#     the master user's privileges, and a client holding rds-db:connect on the
#     proxy owns the database.
#   - Session pinning. Clients that SET session variables, use temporary
#     tables or prepared statements pin their connection to one database
#     connection, which defeats the pooling. The proxy still works; it just
#     stops saving connections. Watch DatabaseConnectionsCurrentlySessionPinned.
#   - Autoscaled readers are not in Terraform state and are not members of the
#     "reporting" endpoint. They have to be gone before the cluster can be
#     deleted; the module's README says how.
#   - Scaling in removes a replica that may hold a connection. Applications
#     need to retry on a dropped connection, with or without the proxy.
#   - BI connects straight to the database, so it needs IAM or password auth
#     of its own; the proxy's IAM-only rule does not cover it.
#
# The proxy is billed per vCPU-hour of the cluster's instances (minimum 2
# vCPU) whether or not anything connects. It earns that back when the
# application opens a connection per request, runs Lambda against the
# database, or must ride through a failover without reconnecting.

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
  description = "VPC for the database and proxy security groups. Bring your own - never the default VPC."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id))
    error_message = "vpc_id must be a VPC ID (vpc-xxxxxxxx)."
  }
}

variable "subnet_ids" {
  description = "Private subnets in at least two AZs. The proxy uses the same ones."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2 && alltrue([for s in var.subnet_ids : can(regex("^subnet-[0-9a-f]{8,17}$", s))])
    error_message = "subnet_ids needs at least two subnet IDs (subnet-xxxxxxxx), in different AZs."
  }
}

variable "app_security_group_id" {
  description = "Security group of the application tier. It reaches the proxy, not the database."
  type        = string

  validation {
    condition     = can(regex("^sg-[0-9a-f]{8,17}$", var.app_security_group_id))
    error_message = "app_security_group_id must be a security group ID (sg-xxxxxxxx)."
  }
}

variable "bi_security_group_id" {
  description = "Security group of the reporting and BI tools. They reach the database directly, on the reporting endpoint, bypassing the proxy."
  type        = string

  validation {
    condition     = can(regex("^sg-[0-9a-f]{8,17}$", var.bi_security_group_id))
    error_message = "bi_security_group_id must be a security group ID (sg-xxxxxxxx)."
  }
}

variable "app_secret_arn" {
  description = <<-EOT
    Secrets Manager secret holding the application's database user (a JSON
    secret with username and password, for a user created with least
    privilege). The proxy logs in as it. Not the master secret: that would
    give every client the master user's rights. Its key policy must allow the
    proxy role - see output.kms_key_policy_requirements.
  EOT
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:", var.app_secret_arn))
    error_message = "app_secret_arn must be a Secrets Manager secret ARN."
  }
}

variable "secretsmanager_endpoint_security_group_id" {
  description = "Security group of the Secrets Manager interface VPC endpoint. The proxy is allowed to reach it on 443; the endpoint's own group must allow the proxy's group in."
  type        = string

  validation {
    condition     = can(regex("^sg-[0-9a-f]{8,17}$", var.secretsmanager_endpoint_security_group_id))
    error_message = "secretsmanager_endpoint_security_group_id must be a security group ID (sg-xxxxxxxx)."
  }
}

variable "kms_key_arn" {
  description = "Customer-managed key, in this region, for storage, the master secret, Performance Insights and the log groups."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN."
  }
}

variable "sns_topic_arn" {
  description = "Existing SNS topic, in this region, for alarms and RDS events."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:", var.sns_topic_arn))
    error_message = "sns_topic_arn must be an SNS topic ARN."
  }
}

module "aurora" {
  source = "../../"

  name = "catalogue"

  # Exact version: Aurora MySQL 3.10 is a long-term support release (standard
  # support to April 2028). A major-only "8.0" would let AWS pick, and the
  # module warns about it (engine_version_is_exact).
  engine         = "aurora-mysql"
  engine_version = "8.0.mysql_aurora.3.10.4"
  instance_class = "db.r7g.large"

  # Three fixed instances; autoscaling adds more on top. The keys are what
  # custom_endpoints refer to. Promotion tier orders failover only: "reader"
  # (tier 1) is the writer's successor, and "reporting" (tier 15, last) is
  # promoted only if nothing else is healthy, so a failover does not hand the
  # writer role to the instance busy with month-end queries.
  instances = {
    writer    = { promotion_tier = 0 }
    reader    = { promotion_tier = 1 }
    reporting = { promotion_tier = 15 }
  }

  database_name   = "catalogue"
  master_username = "catalogue_admin"

  # Network. Two sources: the proxy reaches the database through its own
  # module-created security group (the module opens it to the proxy), and BI
  # connects directly because reporting queries are long-running and gain
  # nothing from pooling. The application is deliberately absent from here.
  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids
  ingress_rules = {
    bi = { referenced_security_group_id = var.bi_security_group_id, description = "Reporting and BI tools, direct" }
  }

  kms_key_arn = var.kms_key_arn
  require_cmk = true

  # I/O-Optimized: no per-request I/O charge, in exchange for roughly 30% more
  # on instances and 125% more on storage. It pays off when I/O is above about
  # 25% of what the cluster would otherwise bill - typically a write-heavy
  # catalogue, heavy reporting scans, or a small database with a large working
  # set. Check VolumeReadIOPs and VolumeWriteIOPs in Cost Explorer first; on a
  # read-light workload standard storage is cheaper. You can switch once every
  # 30 days, so it is a reversible decision.
  storage_type = "aurora-iopt1"

  # Autoscale readers on average CPU of the reader pool. min 1 keeps one scaled
  # replica warm; max 4 is the cost ceiling on this tier - each replica is
  # billed at the writer's class (db.r7g.large). target_value 70 leaves
  # headroom for a failover onto the remaining readers. Cooldowns are longer
  # on scale-in so a brief lull does not drop a replica that is needed again
  # in ten minutes.
  reader_autoscaling = {
    enabled            = true
    min_capacity       = 1
    max_capacity       = 4
    metric             = "RDSReaderAverageCPUUtilization"
    target_value       = 70
    scale_in_cooldown  = 600
    scale_out_cooldown = 300
  }

  # A custom READER endpoint for reporting. static_members takes instance keys
  # from var.instances, not identifiers. With a static list, only "reporting"
  # answers on this name and autoscaled replicas stay out of it. The reverse
  # is not true: "reporting" is still a member of the cluster reader endpoint
  # and the proxy's reader endpoint, so general reads can land on it. Keep
  # them off it with a second custom endpoint that excludes it
  # (excluded_members) if that matters, and point the application at that.
  custom_endpoints = {
    reporting = {
      type           = "READER"
      static_members = ["reporting"]
    }
  }

  # RDS Proxy.
  #   iam_auth REQUIRED   clients present IAM tokens, no database passwords on
  #                       the application side. The proxy itself logs in with
  #                       the secret below.
  #   secret_arns         the app user the proxy logs in as. The alternative,
  #                       use_master_secret = true, runs every client as the
  #                       master user and is left off on purpose.
  #   create_role         true (default): the module creates a role that reads
  #                       exactly secret_arns.
  #   create_security_group true (default): the module creates the proxy's
  #                       group, allows ingress_rules in and the database port
  #                       out. The database's group accepts the proxy.
  #   egress_rules        443 to the Secrets Manager endpoint, which the proxy
  #                       needs to read secret_arns from inside the VPC.
  #   create_reader_endpoint (default true) a read-only proxy endpoint, for
  #                       the application's reads.
  #   require_tls (default) clients must use TLS to the proxy.
  proxy = {
    enabled                = true
    iam_auth               = "REQUIRED"
    create_reader_endpoint = true
    create_role            = true
    create_security_group  = true
    secret_arns            = [var.app_secret_arn]
    ingress_rules = {
      app = { referenced_security_group_id = var.app_security_group_id, description = "Catalogue application tier" }
    }
    egress_rules = {
      secretsmanager = { referenced_security_group_id = var.secretsmanager_endpoint_security_group_id, port = 443, description = "Secrets Manager interface endpoint" }
    }
  }

  sns_topic_arn = var.sns_topic_arn

  # The slow query log is the first thing wanted when the reporting endpoint
  # misbehaves; "error" catches failovers and crashes. "general" and "audit"
  # are left out - they are expensive per GB and rarely wanted.
  enabled_cloudwatch_logs_exports = ["error", "slowquery"]
  log_retention_days              = 30

  deletion_protection = true
  skip_final_snapshot = false

  required_tag_keys = ["Environment", "Owner", "CostCentre", "DataClass", "Application"]
  tags = {
    Environment = "production"
    Owner       = "catalogue-team"
    CostCentre  = "cc-3107"
    DataClass   = "internal"
    Application = "catalogue"
  }
}

output "connection" {
  description = "Everything a client needs. Applications use proxy_host and proxy_reader_host; BI uses the reporting endpoint below."
  value       = module.aurora.connection
}

output "reporting_endpoint" {
  description = "Custom endpoint that routes to the reporting instance only."
  value       = module.aurora.custom_endpoints["reporting"]
}

output "governance" {
  description = "The posture, as data, for the change record."
  value       = module.aurora.governance
}

output "network_contract" {
  description = "Hand to whoever owns the VPC."
  value       = module.aurora.network_contract
}

output "kms_key_policy_requirements" {
  description = "Hand to the key owner. Includes the proxy role's access to the app secret's key."
  value       = module.aurora.kms_key_policy_requirements
}

output "verify_commands" {
  description = "Run after apply, from inside the VPC where the command needs a connection."
  value       = module.aurora.verify_commands
}
