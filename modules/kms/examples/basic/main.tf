# A workload's key set in one call: a data key for RDS and Secrets Manager,
# a logs key for CloudWatch Logs and the alarm topic. One region, so the
# replica provider is the default one.

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
  description = "The role the HCP Terraform workspace runs as."
  type        = string
}

variable "app_role_arn" {
  type = string
}

variable "organization_id" {
  type = string
}

variable "security_topic_arn" {
  type = string
}

module "kms" {
  source    = "../.."
  providers = { aws = aws, aws.replica = aws }

  name      = "payments"
  deployers = [var.deployer_role_arn]

  keys = {
    data = {
      services = ["rds", "secretsmanager"]
      users    = [var.app_role_arn]
    }
    logs = {
      purpose  = "logs"
      services = ["cloudwatch-to-sns"]
    }
  }

  guardrails = {
    organization_id = var.organization_id
  }

  # Native KMS events only (deletion, rotation, imported material expiry):
  # they need no CloudTrail trail.
  notifications = {
    sns_topic_arn = var.security_topic_arn
  }

  tags = { CostCentre = "payments" }
}

output "key_arns" {
  value = module.kms.key_arns
}

output "governance" {
  value = module.kms.governance
}

output "sns_topic_policy_requirement" {
  value = module.kms.sns_topic_policy_requirement
}
