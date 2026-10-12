# On-prem PostgreSQL to Aurora PostgreSQL, full load + CDC, in an isolated VPC.
#
# Nobody hand-writes the target schema: it is the source's, taken with
# pg_dump by a shell step on the bastion and applied to Aurora by the next
# step. The DMS task pauses after the full load, so primary keys and indexes
# exist before the first cached change is applied.
#
#   terraform apply                                            uploads the scripts, pins their SHA-256
#   Run Command  Mode=check                                    every database reachable with its credential
#   Run Command  Mode=runbook,Runbook=source-prep              wal_level, slots, replication role, keyless tables
#   Run Command  Mode=runbook,Runbook=pre-data,DryRun=true
#   Run Command  Mode=runbook,Runbook=pre-data                 tables (no keys) on Aurora, DMS grants
#   DMS console  start the task                                full load; stops before cached changes
#   Run Command  Mode=runbook,Runbook=post-data                keys, indexes, FKs, triggers; ANALYZE
#   DMS console  resume the task                               cached changes, then CDC
#   ... cutover window: stop writes, CDCLatencyTarget ~0, stop the task ...
#   Run Command  Mode=runbook,Runbook=cutover-sequences        sequence positions from the quiet source
#   point the application at Aurora

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
  region = "eu-west-2"
}

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Private subnets for DMS; the bastion takes the first, so it reaches what DMS reaches."
  type        = list(string)
}

variable "dms_security_group_id" {
  type = string
}

variable "endpoints_security_group_id" {
  description = "Security group on the VPC interface endpoints (ssm, ssmmessages, ec2messages, secretsmanager, logs)."
  type        = string
}

variable "s3_prefix_list_id" {
  description = "Prefix list of the S3 gateway endpoint."
  type        = string
}

variable "aurora_security_group_id" {
  type = string
}

variable "onprem_cidr" {
  description = "Where the on-prem PostgreSQL lives. The firewall between the VPC and it must admit tcp/5432 from the DMS and bastion subnets."
  type        = string
}

variable "bastion_ami_id" {
  description = "Pre-baked: SSM agent, AWS CLI v2, python3, psql and pg_dump at least the source's major version, the RDS CA bundle at /etc/pki/rds/global-bundle.pem and the on-prem CA at /etc/pki/onprem/ca.pem."
  type        = string
}

variable "scripts_bucket" {
  description = "An existing, versioned bucket for the migration scripts."
  type        = string
}

variable "dms_source_secret_arn" {
  description = "The DMS user on the source (REPLICATION, SELECT on the migrated tables): host, port, username, password."
  type        = string
}

variable "dms_target_secret_arn" {
  description = "The DMS user on Aurora: host, port, username, password."
  type        = string
}

variable "source_migrator_secret_arn" {
  description = "A source user for the bastion: reads the catalog, pg_dump --schema-only (SELECT on the migrated tables), creates the heartbeat schema."
  type        = string
}

variable "target_migrator_secret_arn" {
  description = "The Aurora schema owner for the bastion. Not the DMS user, not the master."
  type        = string
}

variable "secret_kms_key_arn" {
  type = string
}

variable "onprem_ca_pem" {
  description = "The CA that signed the on-prem PostgreSQL server certificate, for DMS. The bastion reads the same CA from its AMI."
  type        = string
}

variable "rds_ca_bundle_pem" {
  type = string
}

variable "alerts_topic_arn" {
  type = string
}

# ---------------------------------------------------------------------------
# The migration, in one place
# ---------------------------------------------------------------------------

locals {
  name        = "billing"
  wave        = "wave-1"
  schemas     = "app"
  aurora_host = "billing.cluster-abc123.eu-west-2.rds.amazonaws.com"
  onprem_host = "pg-billing.corp.example"

  # Role names inside the databases, as the scripts grant to them.
  dms_source_user = "dms_replication"
  dms_target_user = "dms_writer"

  # Every static file the runbooks run, uploaded under <wave>/<path> and
  # pinned by SHA-256. Edit a file and the next apply uploads it and changes
  # the pin in the same plan.
  files = [
    "sql/source/01-check-prerequisites.sql",
    "sql/source/02-dms-heartbeat.sql",
    "sql/target/01-control-schema.sql",
    "sql/target/02-dms-grants.sql",
    "sql/target/09-analyze.sql",
    "tools/dump-schema.sh",
    "tools/dump-sequences.sh",
  ]
  sha = { for f in local.files : f => filesha256("${path.module}/${f}") }
  key = { for f in local.files : f => "${local.wave}/${f}" }

  # Written by a shell step during the run, so there is nothing to pin at plan
  # time: the run log records the SHA-256 of what was generated and applied.
  generated = {
    pre_data  = "${local.wave}/generated/pre-data.sql"
    post_data = "${local.wave}/generated/post-data.sql"
    sequences = "${local.wave}/generated/sequences.sql"
  }
}

resource "aws_s3_object" "scripts" {
  for_each = toset(local.files)

  bucket = var.scripts_bucket
  key    = "migrations/${local.key[each.value]}"
  source = "${path.module}/${each.value}"
  etag   = filemd5("${path.module}/${each.value}")
}

# ---------------------------------------------------------------------------
# DMS
# ---------------------------------------------------------------------------

module "dms" {
  source = "../../../dms"

  name = local.name

  instance_class       = "dms.r5.large"
  allocated_storage_gb = 100
  engine_version       = "3.5.3"
  multi_az             = true

  subnet_ids         = var.subnet_ids
  security_group_ids = [var.dms_security_group_id]

  certificates = {
    onprem-ca = { pem = var.onprem_ca_pem }
    rds-ca    = { pem = var.rds_ca_bundle_pem }
  }

  endpoints = {
    onprem-pg = {
      role               = "source"
      engine             = "postgres"
      server_name        = local.onprem_host
      port               = 5432
      database_name      = "billing"
      secret_arn         = var.dms_source_secret_arn
      secret_kms_key_arn = var.secret_kms_key_arn
      ssl_mode           = "verify-full"
      certificate_key    = "onprem-ca"

      # Set before the first apply: a later change replaces the endpoint and
      # the task with it.
      postgres = {
        heartbeat_enable    = true
        heartbeat_frequency = 5
        heartbeat_schema    = "dms_heartbeat" # created by the source-prep runbook
      }
    }
    aurora = {
      role               = "target"
      engine             = "aurora-postgresql"
      server_name        = local.aurora_host
      port               = 5432
      database_name      = "billing"
      secret_arn         = var.dms_target_secret_arn
      secret_kms_key_arn = var.secret_kms_key_arn
      ssl_mode           = "verify-full"
      certificate_key    = "rds-ca"

      # Triggers and foreign keys arrive with post-data, while CDC is still
      # running. This keeps them from firing on, or rejecting, DMS's writes.
      postgres = {
        after_connect_script = "SET session_replication_role = replica;"
      }
    }
  }

  tasks = {
    app = {
      source_endpoint = "onprem-pg"
      target_endpoint = "aurora"
      migration_type  = "full-load-and-cdc"
      table_mappings  = file("${path.module}/mappings.json")

      settings = {
        # The pause where post-data runs: after the load, before the changes
        # cached during it are applied. Resume the task to continue.
        stop_before_cached_changes = true

        # text, bytea and jsonb are LOBs to DMS. LIMITED truncates above the
        # cap; measure yours (SELECT max(octet_length(col)) ...) and set it
        # above the largest.
        lob_mode        = "LIMITED"
        lob_max_size_kb = 1024
      }
    }
  }

  sns_topic_arn = var.alerts_topic_arn

  # What runs, in order, for the change record. The bastion's runbooks below
  # are built from the same keys.
  sql_scripts = {
    pre_data = [
      { name = "control-schema", path = local.key["sql/target/01-control-schema.sql"], sha256 = local.sha["sql/target/01-control-schema.sql"] },
      { name = "pre-data", path = local.generated.pre_data, description = "pg_dump --section=pre-data of the source, generated during the run" },
      { name = "dms-grants", path = local.key["sql/target/02-dms-grants.sql"], sha256 = local.sha["sql/target/02-dms-grants.sql"] },
    ]
    post_data = [
      { name = "post-data", path = local.generated.post_data, description = "pg_dump --section=post-data of the source, generated during the run" },
      { name = "analyze", path = local.key["sql/target/09-analyze.sql"], sha256 = local.sha["sql/target/09-analyze.sql"] },
      { name = "sequences", path = local.generated.sequences, description = "setval per sequence from the quiet source, generated at cutover" },
    ]
  }
}

# ---------------------------------------------------------------------------
# The bastion and its runbooks
# ---------------------------------------------------------------------------

module "sql_bastion" {
  source = "../.."

  name      = local.name
  ami_id    = var.bastion_ami_id
  vpc_id    = var.vpc_id
  subnet_id = var.subnet_ids[0]

  https_egress = {
    security_group_ids = [var.endpoints_security_group_id]
    prefix_list_ids    = [var.s3_prefix_list_id]
  }

  scripts = {
    bucket_name = var.scripts_bucket
    prefix      = "migrations"
  }

  targets = {
    onprem = {
      engine             = "postgres"
      host               = local.onprem_host
      port               = 5432
      database           = "billing"
      secret_arn         = var.source_migrator_secret_arn
      secret_kms_key_arn = var.secret_kms_key_arn
      ca_bundle_path     = "/etc/pki/onprem/ca.pem"
      cidr_blocks        = [var.onprem_cidr]

      # Never hold a lock on a busy source for long: fail fast instead.
      env       = { PGOPTIONS = "-c lock_timeout=10s" }
      variables = { schemas = local.schemas, dms_user = local.dms_source_user }
    }
    aurora = {
      engine             = "aurora-postgresql"
      host               = local.aurora_host
      port               = 5432
      database           = "billing"
      secret_arn         = var.target_migrator_secret_arn
      secret_kms_key_arn = var.secret_kms_key_arn
      ca_bundle_path     = "/etc/pki/rds/global-bundle.pem"
      security_group_id  = var.aurora_security_group_id

      variables = { schemas = local.schemas, dms_user = local.dms_target_user }
    }
  }

  # dump-schema.sh and dump-sequences.sh: pg_dump and psql on the source,
  # output uploaded for the next step.
  allow_shell_steps = true

  # ...which needs to write the generated scripts, and only there.
  additional_iam_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "WriteGeneratedScripts"
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = ["arn:aws:s3:::${var.scripts_bucket}/migrations/${local.wave}/generated/*"]
    }]
  })

  runbooks = {
    source-prep = {
      description = "check the source is ready for CDC; create the heartbeat schema"
      steps = [
        { name = "check-prerequisites", target = "onprem", script = local.key["sql/source/01-check-prerequisites.sql"], sha256 = local.sha["sql/source/01-check-prerequisites.sql"], transaction = "none" },
        { name = "heartbeat-schema", target = "onprem", script = local.key["sql/source/02-dms-heartbeat.sql"], sha256 = local.sha["sql/source/02-dms-heartbeat.sql"] },
      ]
    }

    pre-data = {
      description = "the source's tables on Aurora, without keys; DMS grants"
      steps = [
        { name = "control-schema", target = "aurora", script = local.key["sql/target/01-control-schema.sql"], sha256 = local.sha["sql/target/01-control-schema.sql"] },
        {
          name      = "dump-pre-data", target = "onprem", script = local.key["tools/dump-schema.sh"], sha256 = local.sha["tools/dump-schema.sh"]
          variables = { section = "pre-data", out_key = local.generated.pre_data }
        },
        { name = "apply-pre-data", target = "aurora", script = local.generated.pre_data },
        { name = "dms-grants", target = "aurora", script = local.key["sql/target/02-dms-grants.sql"], sha256 = local.sha["sql/target/02-dms-grants.sql"] },
      ]
    }

    # Run while the task is stopped before cached changes.
    post-data = {
      description = "keys, indexes, foreign keys, triggers; fresh statistics"
      steps = [
        {
          name      = "dump-post-data", target = "onprem", script = local.key["tools/dump-schema.sh"], sha256 = local.sha["tools/dump-schema.sh"]
          variables = { section = "post-data", out_key = local.generated.post_data }
        },
        # One transaction: a failed index rolls the whole section back, and a
        # rerun from StartAt=apply-post-data starts clean. Big tables take
        # time, so the timeout is generous.
        { name = "apply-post-data", target = "aurora", script = local.generated.post_data, timeout_seconds = 14400 },
        { name = "analyze", target = "aurora", script = local.key["sql/target/09-analyze.sql"], sha256 = local.sha["sql/target/09-analyze.sql"], transaction = "none", timeout_seconds = 7200 },
      ]
    }

    # Run in the cutover window, after the task is stopped.
    cutover-sequences = {
      description = "sequence positions from the quiet source"
      steps = [
        {
          name      = "dump-sequences", target = "onprem", script = local.key["tools/dump-sequences.sh"], sha256 = local.sha["tools/dump-sequences.sh"]
          variables = { out_key = local.generated.sequences }
        },
        { name = "apply-sequences", target = "aurora", script = local.generated.sequences },
      ]
    }
  }

  # Off between waves.
  running = true
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "runbooks" {
  value = module.sql_bastion.runbooks
}

output "commands" {
  value = module.sql_bastion.commands
}

output "network_contract" {
  value = {
    dms     = module.dms.network_contract
    bastion = module.sql_bastion.network_contract
  }
}

output "operator_policy_json" {
  value = module.sql_bastion.operator_policy_json
}

output "migration_plan" {
  value = module.dms.migration_plan
}

output "source_prerequisites" {
  value = module.dms.source_prerequisites
}
