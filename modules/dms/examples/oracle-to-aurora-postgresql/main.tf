# The migration this module was shaped around: a production Oracle source that
# has to keep serving traffic, an Aurora PostgreSQL target, and a cutover window
# measured in minutes rather than hours.
#
# full-load-and-cdc, so the load runs once and then changes keep flowing until
# you stop the task deliberately. What that buys you is a cutover whose length
# is CDC latency, not database size - see RUNBOOK.md.
#
# Both credentials live in Secrets Manager. Neither ever reaches Terraform
# state, and DMS reads them itself through a role scoped to one secret each.

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
  default     = "eu-west-1"
}

variable "subnet_ids" {
  description = "Private subnets for the replication instance, in at least two AZs. They need a route to the Oracle source (on-prem or another VPC) and to the Aurora target."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group for the replication instance. Egress to 1521 on the source and 5432 on the target; no ingress."
  type        = string
}

variable "source_secret_arn" {
  description = "Secrets Manager secret holding the Oracle credential, in the shape DMS expects: username, password, host and port. It is a database user of its own for DMS, not the RDS-managed master secret, which DMS cannot read. The database name comes from the endpoint, not the secret."
  type        = string
}

variable "target_secret_arn" {
  description = "Secrets Manager secret holding the Aurora PostgreSQL credential."
  type        = string
}

variable "secret_kms_key_arn" {
  description = "CMK the two secrets are encrypted with. Without it DMS can call GetSecretValue and still not decrypt."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK for replication storage, which is where cached changes and in-flight LOBs sit."
  type        = string
}

variable "sns_topic_arn" {
  description = "Topic for task events and alarms. The one that matters is a task stopping on its own."
  type        = string
}

variable "rds_ca_bundle_pem" {
  description = "PEM of the RDS CA bundle, for verify-full against the Aurora target. Download the regional bundle from AWS."
  type        = string
}

variable "oracle_wallet_base64" {
  description = "Base64 of the Oracle wallet (cwallet.sso) holding the CA that signed the Oracle source's certificate: base64 -w0 cwallet.sso. DMS verifies Oracle against a wallet, not a PEM."
  type        = string
}

module "migration" {
  source = "../../"

  name = "oracle-to-aurora"

  # Sizing follows the source's change rate, not its size. A t3 keeps up with a
  # quiet schema; an OLTP source in CDC needs a c-class or the latency alarms
  # start firing and never stop.
  instance_class       = "dms.c5.large"
  allocated_storage_gb = 100
  engine_version       = "3.5.3"
  multi_az             = true

  subnet_ids         = var.subnet_ids
  security_group_ids = [var.security_group_id]

  kms_key_arn = var.kms_key_arn
  require_cmk = true

  # Verifying a server needs a CA to verify against. Uploaded here and
  # referenced by certificate_key below - referencing the module's own output
  # from its own input would be a dependency cycle. Oracle takes a wallet, and
  # DMS supports only none or verify-ca on Oracle; the Aurora side verifies
  # against the RDS CA bundle with verify-full.
  certificates = {
    oracle-wallet = { wallet = var.oracle_wallet_base64 }
    rds-ca        = { pem = var.rds_ca_bundle_pem }
  }

  endpoints = {
    oracle-prod = {
      role          = "source"
      engine        = "oracle"
      server_name   = "oracle-prod.internal.example.com"
      port          = 1521
      database_name = "ORCL"

      secret_arn         = var.source_secret_arn
      secret_kms_key_arn = var.secret_kms_key_arn

      ssl_mode        = "verify-ca"
      certificate_key = "oracle-wallet"
    }

    aurora-target = {
      role          = "target"
      engine        = "aurora-postgresql"
      server_name   = "app-target.cluster-abc123.eu-west-1.rds.amazonaws.com"
      port          = 5432
      database_name = "app"

      secret_arn         = var.target_secret_arn
      secret_kms_key_arn = var.secret_kms_key_arn

      ssl_mode        = "verify-full"
      certificate_key = "rds-ca"

      # The target already has its foreign keys and triggers, and the full
      # load runs tables in parallel in no set order: child rows arrive before
      # their parents. This runs on every DMS connection and switches both off
      # for DMS's sessions only. Set it before the first apply - changing it
      # later replaces the endpoint and the task. The DMS user needs
      # rds_superuser (or, on PostgreSQL 15+, SET on session_replication_role).
      postgres = {
        after_connect_script = "SET session_replication_role = replica;"
      }
    }
  }

  tasks = {
    app = {
      source_endpoint = "oracle-prod"
      target_endpoint = "aurora-target"
      migration_type  = "full-load-and-cdc"

      # Kept in a file rather than inline so tests/lint_task_settings.py can
      # check it: a mapping with no selection rule migrates nothing and reports
      # success.
      table_mappings = file("${path.module}/mappings/app-schema.json")

      # Created stopped. Starting a task begins writing to the target the
      # moment the plan is approved, which is rarely what a reviewer expects.
      start = false

      settings = {
        # The target is pre-created by the schema conversion step, with its own
        # indexes and constraints. DO_NOTHING keeps them; after_connect_script
        # on the target endpoint stops the foreign keys rejecting the load.
        target_table_prep_mode = "DO_NOTHING"

        # Oracle LOBs: LIMITED is fast and truncates past the cap, FULL is
        # correct and slow. 64 KB covers the CLOBs in this schema - confirm
        # yours with SELECT MAX(DBMS_LOB.GETLENGTH(col)).
        lob_mode        = "LIMITED"
        lob_max_size_kb = 64

        validation_enabled = true
        validation_threads = 8

        # NOT parallel_load_threads: TargetMetadata.ParallelLoadThreads applies
        # only to DynamoDB, Kinesis, MSK, OpenSearch and Redshift targets, and
        # it is a full-load setting rather than a CDC one. On Aurora PostgreSQL
        # it is silently ignored - the exact trap this module exists to close.
        #
        # batch_apply_enabled is the lever that actually moves CDC apply
        # throughput on a relational target. It batches changes instead of
        # applying them one transaction at a time, at the cost of applying them
        # out of transactional order within a batch. With it on, the module
        # renders SUSPEND_TABLE for data and apply errors, so one bad row
        # suspends its table instead of silently dropping the whole task to
        # one-by-one apply.
        batch_apply_enabled = true
      }
    }
  }

  sns_topic_arn             = var.sns_topic_arn
  alarm_cdc_latency_seconds = 300
  log_retention_days        = 90

  tags = {
    Environment = "production"
    Owner       = "platform"
    Migration   = "oracle-decommission"
  }
}

output "source_prerequisites" {
  description = "Hand this to whoever owns the Oracle database before the first task start. None of it is enforceable from Terraform."
  value       = module.migration.source_prerequisites
}

output "network_contract" {
  description = "Hand this to whoever owns the VPC and the database firewalls."
  value       = module.migration.network_contract
}

output "replication_instance_private_ips" {
  description = "The addresses the source and target firewalls have to allow."
  value       = module.migration.replication_instance_private_ips
}

output "verify_commands" {
  description = "Connection tests first, then task status, then CDC latency."
  value       = module.migration.verify_commands
}

output "governance" {
  description = "The posture this migration actually has, as data."
  value       = module.migration.governance
}
