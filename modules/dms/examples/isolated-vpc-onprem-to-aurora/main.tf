# On-premises source, private Aurora PostgreSQL target, fully isolated VPC.
#
# This is the shape a regulated estate actually has, and it is the one with the
# most ways to fail silently:
#
#   - No internet gateway and no NAT. Every AWS API call the replication
#     instance makes goes through a VPC endpoint or it hangs. DMS does not
#     report "no route" - the task sits there until it times out.
#   - The source is reached over Cloud WAN. The route has to exist in the
#     segment, the on-prem firewall has to allow the replication instance's
#     ENIs, and the on-prem hostname has to RESOLVE from inside the VPC.
#   - The target is a private Aurora cluster, so it is the easy half.
#
# Nothing in Terraform can check any of that. output.network_contract is what
# you hand to the network team, and output.replication_instance_private_ips is
# what the on-prem firewall request is made of.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70.0, < 6.0.0"
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

variable "subnet_ids" {
  description = "Private subnets in at least two AZs, attached to the Cloud WAN segment that reaches the on-prem source. No internet route."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group for the replication instance. Egress to the on-prem database port, to the Aurora port, and 443 to the VPC endpoints. No ingress."
  type        = string
}

variable "source_secret_arn" {
  description = "Secrets Manager secret holding the on-prem database credential. DMS reads it through the interface endpoint, never through the internet."
  type        = string
}

variable "target_secret_arn" {
  description = "Secrets Manager secret holding the Aurora credential."
  type        = string
}

variable "secret_kms_key_arn" {
  description = "CMK the secrets are encrypted with. DMS needs kms:Decrypt on it as well as GetSecretValue."
  type        = string
}

variable "replication_kms_key_arn" {
  description = "CMK for replication storage. This volume holds cached changes and in-flight LOBs - production data in transit, at rest."
  type        = string
}

variable "onprem_wallet_base64" {
  description = "Base64 of the Oracle wallet (cwallet.sso) holding the CA that signed the on-prem database's certificate: base64 -w0 cwallet.sso. DMS verifies an Oracle source against a wallet, not a PEM, and supports only none or verify-ca on Oracle - so verify-full is not available here."
  type        = string
}

variable "assessment_bucket_name" {
  description = "Existing S3 bucket for premigration assessment reports, in this region. The module creates the role DMS writes them with, scoped to a folder."
  type        = string
}

variable "rds_ca_bundle_pem" {
  description = "PEM of the RDS CA bundle for the Aurora target."
  type        = string
}

variable "sns_topic_arn" {
  description = "Topic for task events and alarms, in this region."
  type        = string
}

variable "onprem_hostname" {
  description = "Hostname of the on-prem source. It must resolve from inside the VPC - via Route 53 Resolver rules forwarding to on-prem DNS, or a private hosted zone. A name that resolves only on-prem is the most common first-run failure here."
  type        = string
}

module "migration" {
  source = "../../"

  name = "core-banking-to-aurora"

  # Sized for an on-prem source over a WAN link: the constraint is usually the
  # link and the source's log read rate, not DMS. Start here and let the CDC
  # latency alarm say whether it is enough.
  instance_class       = "dms.c5.xlarge"
  allocated_storage_gb = 200
  engine_version       = "3.5.3"

  # Non-negotiable for a committed cutover. An AZ failure mid-load otherwise
  # restarts a multi-terabyte full load across a WAN link.
  multi_az = true

  subnet_ids         = var.subnet_ids
  security_group_ids = [var.security_group_id]

  # Never. This instance holds credentials for a core banking system.
  publicly_accessible = false

  kms_key_arn = var.replication_kms_key_arn
  require_cmk = true

  certificates = {
    # An Oracle endpoint verifies against a wallet; the module refuses a PEM
    # here (check oracle_ssl_uses_a_wallet) and refuses verify-full on Oracle.
    onprem-wallet = { wallet = var.onprem_wallet_base64 }
    rds-ca        = { pem = var.rds_ca_bundle_pem }
  }

  endpoints = {
    core-onprem = {
      role   = "source"
      engine = "oracle"
      # With secret_arn set, server_name and port do not reach DMS - the secret
      # carries host and port (and its user is the DMS user's own, not a shared
      # admin credential). They are here because network_contract is built from
      # them, and that is the firewall request. database_name always reaches
      # DMS: the secret does not hold it, and Oracle needs it (SID or service
      # name).
      server_name   = var.onprem_hostname
      port          = 1521
      database_name = "CORE"

      secret_arn         = var.source_secret_arn
      secret_kms_key_arn = var.secret_kms_key_arn

      # Over a WAN link crossing a bank's own estate, unverified TLS is not a
      # defensible position in an audit. verify-ca is the strongest mode DMS
      # supports on Oracle, and it needs the wallet above.
      ssl_mode        = "verify-ca"
      certificate_key = "onprem-wallet"
    }

    aurora-core = {
      role          = "target"
      engine        = "aurora-postgresql"
      server_name   = "core.cluster-abc123.eu-west-2.rds.amazonaws.com"
      port          = 5432
      database_name = "core"

      secret_arn         = var.target_secret_arn
      secret_kms_key_arn = var.secret_kms_key_arn

      ssl_mode        = "verify-full"
      certificate_key = "rds-ca"

      postgres = {
        # The only pre-data hook DMS has. It runs on every connection DMS opens
        # to the target, so for the duration of the load the target's triggers
        # do not fire and its foreign keys do not reject rows that arrive
        # parent-last. It affects DMS's own sessions only, so nothing needs
        # restoring afterwards. The DMS database user needs the privilege to
        # set it.
        after_connect_script = "SET session_replication_role = replica;"
      }
    }
  }

  # Premigration assessment: DMS checks the task against the source and target
  # and writes a report to S3 before any data moves. The module creates the
  # role; the command is in output.premigration_assessment, run as a gated step
  # before the task is started.
  premigration_assessment = {
    enabled       = true
    bucket_name   = var.assessment_bucket_name
    bucket_folder = "dms-assessments"
    kms_key_arn   = var.replication_kms_key_arn
  }

  tasks = {
    core = {
      source_endpoint = "core-onprem"
      target_endpoint = "aurora-core"
      migration_type  = "full-load-and-cdc"
      table_mappings  = file("${path.module}/mappings/core-banking.json")

      # Created stopped. Starting a migration out of a core banking system is a
      # change-controlled act, not a side effect of an apply.
      start = false

      settings = {
        # The Aurora schema is created by the conversion step, with its
        # constraints and grants. DMS must not touch them.
        target_table_prep_mode = "DO_NOTHING"

        # Validation is the audit evidence that the target matches the source.
        validation_enabled = true
        validation_threads = 8

        # FULL LOB mode (the target is Aurora, not S3): a truncated LOB in a banking record is a data defect
        # that surfaces in a regulatory report, not in an error log. It costs
        # throughput, which over a WAN link is the scarce resource - measure it
        # before deciding it is too slow.
        lob_mode = "FULL"

        # Keep the control tables in their own schema so they are obvious to a
        # reviewer and easy to exclude from the target's backups.
        control_schema = "dms_control"
      }
    }
  }

  # Reconciliation evidence for the change record: a validation-only task over
  # the same endpoints and mappings. Start it just before cutover (RUNBOOK) and
  # attach its describe-table-statistics output. It never prepares the target.
  validation_tasks = {
    pre-cutover = {
      task    = "core"
      mode    = "full-load"
      threads = 8
      start   = false
    }
  }

  sns_topic_arn = var.sns_topic_arn

  # A WAN link that flaps shows up as latency before it shows up as failure.
  alarm_cdc_latency_seconds = 300

  # Long enough to cover a change-review cycle after cutover.
  log_retention_days = 365

  tags = {
    Environment  = "production"
    Owner        = "platform-migration"
    DataClass    = "confidential"
    ChangeRecord = "CHG0000000"
    CostCentre   = "migration-programme"
  }
}

# ---------------------------------------------------------------------------
# The three outputs this topology lives or dies on
# ---------------------------------------------------------------------------

output "firewall_request" {
  description = "Hand to the on-prem network team. These are the addresses that will connect to the source database, and there is one per AZ because the instance is multi-AZ."
  value = {
    source_addresses = module.migration.replication_instance_private_ips
    destination      = "${var.onprem_hostname}:1521"
    direction        = "outbound from AWS to on-premises, over the Cloud WAN attachment"
    return_path_note = "The on-prem side must route the VPC CIDR back through the same Cloud WAN segment. Asymmetric routing here presents as a connection that tests fine and then stalls mid-load."
  }
}

output "network_contract" {
  description = "Hand to whoever owns the VPC. Every interface endpoint listed here is mandatory in an isolated VPC - a missing one is a hang, not an error."
  value       = module.migration.network_contract
}

output "source_prerequisites" {
  description = "Hand to the on-prem DBA team before the first task start. Oracle supplemental logging is the one that fails silently and wrongly rather than loudly."
  value       = module.migration.source_prerequisites
}

output "governance" {
  description = "The posture, as data, for the change record."
  value       = module.migration.governance
}

output "premigration_assessment" {
  description = "Start, status and report commands per task. Run the assessment before starting the task and attach the report to the change record."
  value       = module.migration.premigration_assessment
}

output "kms_key_policy_requirements" {
  description = "Hand to the owner of each CMK before the first apply: what its key policy has to allow."
  value       = module.migration.kms_key_policy_requirements
}

output "verify_commands" {
  description = "Connection test first. In this topology it is the check that fails when DNS, routing or the firewall is not ready."
  value       = module.migration.verify_commands
}
