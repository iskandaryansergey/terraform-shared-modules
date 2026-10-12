# Oracle on-prem to Aurora PostgreSQL in an isolated VPC, with the SQL either
# side of the load run from a bastion inside the VPC.
#
#   terraform apply                      uploads the scripts, pins their SHA-256
#   Run Command: Mode=runbook,Runbook=pre-data,DryRun=true    verify, connect
#   Run Command: Mode=runbook,Runbook=pre-data
#   DMS console: start the task
#   Run Command: Mode=runbook,Runbook=post-data
#
# One list of scripts (local.phases) feeds all three places that need it: the
# dms module's migration_plan, the bastion's runbooks, and the S3 upload.
#
# The bastion sits in one of DMS's own subnets, so it reaches exactly what DMS
# reaches. Its targets use the migrator credential (the schema owner), not the
# DMS user: DMS only reads and writes rows, the scripts own the schema.

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

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Private subnets for DMS; the bastion takes the first."
  type        = list(string)
}

variable "dms_security_group_id" {
  type = string
}

variable "endpoints_security_group_id" {
  description = "Security group on the VPC interface endpoints (ssm, ssmmessages, ec2messages, secretsmanager, logs, kms)."
  type        = string
}

variable "s3_prefix_list_id" {
  description = "Prefix list of the S3 gateway endpoint."
  type        = string
}

variable "aurora_security_group_id" {
  type = string
}

variable "bastion_ami_id" {
  description = "Pre-baked: SSM agent, AWS CLI v2, python3, psql, sqlplus (Instant Client), and the RDS CA bundle at /etc/pki/rds/global-bundle.pem."
  type        = string
}

variable "dms_source_secret_arn" {
  type = string
}

variable "dms_target_secret_arn" {
  type = string
}

variable "migrator_secret_arn" {
  description = "The Aurora schema owner: username and password."
  type        = string
}

variable "onprem_migrator_secret_arn" {
  description = "An Oracle user for source-side checks and scripts."
  type        = string
}

variable "secret_kms_key_arn" {
  type = string
}

variable "onprem_wallet_base64" {
  type      = string
  sensitive = true
}

variable "rds_ca_bundle_pem" {
  type = string
}

variable "alerts_topic_arn" {
  description = "SNS topic for DMS task failures."
  type        = string
}

variable "scripts_bucket" {
  description = "An existing, versioned bucket for the migration scripts."
  type        = string
}

locals {
  name          = "core-banking"
  aurora_host   = "core.cluster-abc123.eu-west-2.rds.amazonaws.com"
  onprem_host   = "ora-core.corp.example"
  onprem_cidr   = "10.20.0.0/16"
  oracle_server = "CORE"

  # The scripts, in run order, per phase. Add a file here and it is uploaded,
  # pinned by SHA-256, listed in migration_plan and run by the runbook.
  phases = {
    pre-data = [
      { name = "schema", file = "sql/01-schema.sql", target = "aurora" },
    ]
    post-data = [
      { name = "constraints", file = "sql/02-constraints.sql", target = "aurora" },
    ]
  }

  scripts = merge([
    for phase, steps in local.phases : {
      for s in steps : "${phase}/${s.name}" => merge(s, {
        key    = "wave-1/${phase}/${basename(s.file)}"
        sha256 = filesha256("${path.module}/${s.file}")
      })
    }
  ]...)
}

resource "aws_s3_object" "scripts" {
  for_each = local.scripts

  bucket = var.scripts_bucket
  key    = "migrations/${each.value.key}"
  source = "${path.module}/${each.value.file}"
  etag   = filemd5("${path.module}/${each.value.file}")
}

module "dms" {
  source = "../../../dms"

  name = local.name

  instance_class = "dms.c5.xlarge"
  engine_version = "3.5.3"
  multi_az       = true

  subnet_ids         = var.subnet_ids
  security_group_ids = [var.dms_security_group_id]

  certificates = {
    onprem-wallet = { wallet = var.onprem_wallet_base64 }
    rds-ca        = { pem = var.rds_ca_bundle_pem }
  }

  endpoints = {
    core-onprem = {
      role               = "source"
      engine             = "oracle"
      server_name        = local.onprem_host
      port               = 1521
      database_name      = local.oracle_server
      secret_arn         = var.dms_source_secret_arn
      secret_kms_key_arn = var.secret_kms_key_arn
      ssl_mode           = "verify-ca"
      certificate_key    = "onprem-wallet"
    }
    aurora-core = {
      role               = "target"
      engine             = "aurora-postgresql"
      server_name        = local.aurora_host
      port               = 5432
      database_name      = "core"
      secret_arn         = var.dms_target_secret_arn
      secret_kms_key_arn = var.secret_kms_key_arn
      ssl_mode           = "verify-full"
      certificate_key    = "rds-ca"
      postgres = {
        after_connect_script = "SET session_replication_role = replica;"
      }
    }
  }

  tasks = {
    core = {
      source_endpoint = "core-onprem"
      target_endpoint = "aurora-core"
      migration_type  = "full-load"
      table_mappings  = file("${path.module}/mappings.json")
    }
  }

  sns_topic_arn = var.alerts_topic_arn

  # A one-off full load: the instance is torn down after cutover, so the
  # warning about a provisioned instance billing between loads is accepted.
  acknowledged_checks = ["full_load_does_not_leave_the_meter_running"]

  # The scripts run from the bastion, not from Terraform; the manifest records
  # what they are so the change record can say what ran.
  sql_scripts = {
    pre_data  = [for s in local.phases["pre-data"] : { name = s.name, path = local.scripts["pre-data/${s.name}"].key, sha256 = local.scripts["pre-data/${s.name}"].sha256 }]
    post_data = [for s in local.phases["post-data"] : { name = s.name, path = local.scripts["post-data/${s.name}"].key, sha256 = local.scripts["post-data/${s.name}"].sha256 }]
  }
}

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

  # One runbook per phase, steps in local.phases order, each pinned to the
  # SHA-256 of the file Terraform uploaded.
  runbooks = {
    for phase, steps in local.phases : phase => {
      description = "wave 1 ${phase}"
      steps = [for s in steps : {
        name   = s.name
        target = s.target
        script = local.scripts["${phase}/${s.name}"].key
        sha256 = local.scripts["${phase}/${s.name}"].sha256
      }]
    }
  }

  targets = {
    aurora = {
      engine             = "aurora-postgresql"
      host               = local.aurora_host
      port               = 5432
      database           = "core"
      secret_arn         = var.migrator_secret_arn
      secret_kms_key_arn = var.secret_kms_key_arn
      ca_bundle_path     = "/etc/pki/rds/global-bundle.pem"
      security_group_id  = var.aurora_security_group_id
    }
    # Source-side checks (Mode=check) and any script the DBA asks to run on
    # Oracle. Oracle TLS is native network encryption from the AMI's
    # sqlnet.ora; the runner does not manage TCPS.
    onprem = {
      engine             = "oracle"
      host               = local.onprem_host
      port               = 1521
      database           = local.oracle_server
      secret_arn         = var.onprem_migrator_secret_arn
      secret_kms_key_arn = var.secret_kms_key_arn
      cidr_blocks        = [local.onprem_cidr]
    }
  }

  # Off between waves: set false after the post-data run.
  running = true
}

output "sql_bastion_commands" {
  value = module.sql_bastion.commands
}

output "sql_bastion_runbooks" {
  value = module.sql_bastion.runbooks
}

output "sql_bastion_network_contract" {
  value = module.sql_bastion.network_contract
}

output "operator_policy_json" {
  value = module.sql_bastion.operator_policy_json
}

output "migration_plan" {
  value = module.dms.migration_plan
}
