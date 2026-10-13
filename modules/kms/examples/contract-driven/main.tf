# Contract-driven key policies: the script runner is given the keys, emits
# what it needs from them (kms_key_policy_requirements, contract v2), and the
# key set compiles those requirements into its key policies. Nobody writes a
# key policy statement for the runner by hand.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.73.0, < 6.0.0"
    }
  }
}

provider "aws" {
  region = "eu-west-2"
}

variable "deployer_role_arn" {
  type = string
}

variable "organization_id" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "endpoints_security_group_id" {
  type = string
}

variable "s3_prefix_list_id" {
  type = string
}

variable "runner_ami_id" {
  type = string
}

variable "aurora_security_group_id" {
  type = string
}

variable "migrator_secret_arn" {
  type = string
}

module "kms" {
  source    = "../.."
  providers = { aws = aws, aws.replica = aws }

  name      = "billing"
  deployers = [var.deployer_role_arn]

  keys = {
    # The runner's root volume, its run logs and the scripts bucket. The logs
    # preset is here because CloudWatch Logs checks the key when the log group
    # is created - before the runner's own requirement reaches the policy.
    runner = { services = ["logs"] }
    # Secrets the runner reads.
    secrets = {}
  }

  consumers = {
    runner = module.runner.kms_key_policy_requirements
  }

  guardrails = { organization_id = var.organization_id }
}

module "runner" {
  source = "../../../db-script-runner"

  name      = "billing"
  ami_id    = var.runner_ami_id
  vpc_id    = var.vpc_id
  subnet_id = var.subnet_id

  kms_key_arn = module.kms.key_arns["runner"]

  https_egress = {
    security_group_ids = [var.endpoints_security_group_id]
    prefix_list_ids    = [var.s3_prefix_list_id]
  }

  scripts = {
    bucket_name = "billing-migration-scripts"
    kms_key_arn = module.kms.key_arns["runner"]
  }

  targets = {
    aurora = {
      engine             = "aurora-postgresql"
      host               = "billing.cluster-abc123.eu-west-2.rds.amazonaws.com"
      port               = 5432
      database           = "billing"
      secret_arn         = var.migrator_secret_arn
      secret_kms_key_arn = module.kms.key_arns["secrets"]
      ca_bundle_path     = "/etc/pki/rds/global-bundle.pem"
      security_group_id  = var.aurora_security_group_id
    }
  }
}

output "coverage" {
  description = "Where each of the runner's requirements landed."
  value       = module.kms.coverage
}

output "policies" {
  value = module.kms.policies
}
