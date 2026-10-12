# Continuous CDC from an RDS PostgreSQL source into a data lake, on serverless
# compute.
#
# Serverless because this replication runs indefinitely at a variable rate:
# there is no cutover, no end date, and nobody to remember to delete a
# provisioned instance. DMS scales between the DCU bounds and the bill follows
# the change rate instead of the clock.
#
# Read the cost note before copying this: serverless scales DOWN but never to
# zero, so min_dcu bills around the clock while the source is quiet. On a source
# with long idle periods a small provisioned instance is cheaper - COSTS.md has
# the crossover.

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
  description = "Private subnets in at least two AZs, with a route to the RDS source and an S3 gateway endpoint."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group for the replication. Egress to 5432 on the source and 443 for S3 and the AWS APIs."
  type        = string
}

variable "source_secret_arn" {
  description = "Secrets Manager secret holding the PostgreSQL credential."
  type        = string
}

variable "secret_kms_key_arn" {
  description = "CMK the secret is encrypted with."
  type        = string
}

variable "lake_bucket" {
  description = "Existing S3 bucket for the lake. The module creates a role scoped to the prefix below, not to the whole bucket."
  type        = string
}

variable "lake_kms_key_arn" {
  description = "CMK the lake is encrypted with. DMS needs GenerateDataKey on it, which the module's role grants."
  type        = string
}

variable "sns_topic_arn" {
  description = "Topic for replication events."
  type        = string
}

variable "rds_ca_bundle_pem" {
  description = "PEM of the RDS CA bundle, for verify-full against the source."
  type        = string
}

module "cdc_to_lake" {
  source = "../../"

  name         = "sales-cdc-lake"
  compute_mode = "serverless"

  serverless = {
    # 1 DCU is 2 GB of memory. The floor is what you pay while the source is
    # idle; the ceiling is what a burst of changes can reach for.
    min_dcu  = 2
    max_dcu  = 16
    multi_az = true
  }

  subnet_ids         = var.subnet_ids
  security_group_ids = [var.security_group_id]

  kms_key_arn = var.lake_kms_key_arn
  require_cmk = true

  certificates = {
    rds-ca = { pem = var.rds_ca_bundle_pem }
  }

  endpoints = {
    sales-db = {
      role          = "source"
      engine        = "postgres"
      server_name   = "sales.cluster-abc123.eu-west-1.rds.amazonaws.com"
      port          = 5432
      database_name = "sales"

      secret_arn         = var.source_secret_arn
      secret_kms_key_arn = var.secret_kms_key_arn

      ssl_mode        = "verify-full"
      certificate_key = "rds-ca"

      postgres = {
        # The heartbeat writes to a tiny table on a schedule, which keeps the
        # replication slot advancing while the source is quiet. Without it an
        # idle source accumulates WAL until its disk fills - an outage on the
        # database you were only reading from.
        heartbeat_enable    = true
        heartbeat_frequency = 5
        heartbeat_schema    = "awsdms"

        # No slot_name: DMS then creates and manages the slot itself. A named
        # slot must already exist and needs a CDC start position, which
        # serverless mode cannot take - the replication would fail to start.
      }
    }
  }

  s3_targets = {
    lake = {
      bucket_name   = var.lake_bucket
      bucket_folder = "raw/sales"

      # Parquet keeps the source's types. CSV would hand every downstream
      # consumer the job of guessing them back.
      data_format      = "parquet"
      compression_type = "GZIP"

      encryption_mode = "SSE_KMS"
      kms_key_arn     = var.lake_kms_key_arn

      # Without partitioning a long-running CDC stream becomes one flat prefix
      # that every query has to scan.
      date_partition_enabled  = true
      date_partition_sequence = "YYYYMMDD"

      # Which operation produced the row, and when. A consumer cannot tell a
      # delete from an absence without the first, or order changes without the
      # second.
      include_op_for_full_load = true
      timestamp_column_name    = "dms_ingest_ts"
    }
  }

  tasks = {
    sales = {
      source_endpoint = "sales-db"
      target_endpoint = "lake"
      migration_type  = "full-load-and-cdc"
      table_mappings  = file("${path.module}/mappings/cdc-to-lake.json")
      start           = false

      settings = {
        target_table_prep_mode = "DO_NOTHING"
        # Validation compares a PostgreSQL source with an S3 target only because
        # the target is parquet, with a timestamp column and a day-level date
        # partition - the module reports validation as unable to run otherwise.
        # Serverless has no validation alarms or validation_tasks.
        validation_enabled = true

        # LIMITED with a generous ceiling (16384 KB): DMS does not support full
        # LOB mode for an S3 target, and the module refuses lob_mode FULL or
        # INLINE into one. Size lob_max_size_kb above the largest LOB in the
        # source (check with a MAX(length()) query) - past it, values are
        # truncated without an error, which in a lake surfaces months later.
        lob_mode        = "LIMITED"
        lob_max_size_kb = 16384
      }
    }
  }

  sns_topic_arn      = var.sns_topic_arn
  log_retention_days = 30

  tags = {
    Environment = "production"
    Owner       = "data-platform"
    DataClass   = "confidential"
  }
}

output "source_prerequisites" {
  description = "What the PostgreSQL source needs before CDC works - logical WAL, the replication role, and a plan for the slot."
  value       = module.cdc_to_lake.source_prerequisites
}

output "network_contract" {
  description = "Hand to whoever owns the VPC. The S3 gateway endpoint is the one people forget."
  value       = module.cdc_to_lake.network_contract
}

output "serverless_replication_arns" {
  description = "Start and stop these with aws dms start-replication / stop-replication."
  value       = module.cdc_to_lake.serverless_replication_arns
}

output "governance" {
  description = "The posture, as data."
  value       = module.cdc_to_lake.governance
}
