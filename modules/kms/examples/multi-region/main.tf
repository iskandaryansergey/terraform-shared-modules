# A multi-Region key with a replica for disaster recovery. The replica gets its
# own policy, built for its region (the logs preset names logs.eu-west-1 there),
# and its own aliases.

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

provider "aws" {
  alias  = "dr"
  region = "eu-west-1"
}

variable "deployer_role_arn" {
  type = string
}

variable "organization_id" {
  type = string
}

variable "security_topic_arn" {
  description = "An SNS topic in eu-west-2."
  type        = string
}

variable "dr_security_topic_arn" {
  description = "An SNS topic in eu-west-1: EventBridge targets a topic in its own region."
  type        = string
}

module "kms" {
  source    = "../.."
  providers = { aws = aws, aws.replica = aws.dr }

  name      = "ledger"
  deployers = [var.deployer_role_arn]

  keys = {
    data = {
      multi_region = true
      replicate    = true
      services     = ["dynamodb", "s3", "logs"]
    }
  }

  guardrails = {
    organization_id = var.organization_id
  }

  notifications = {
    sns_topic_arn         = var.security_topic_arn
    replica_sns_topic_arn = var.dr_security_topic_arn
  }
}

output "keys" {
  value = module.kms.keys
}

output "cost" {
  value = module.kms.cost
}

output "sns_topic_policy_requirement" {
  description = "primary goes into the eu-west-2 topic's policy, replica into the eu-west-1 one."
  value       = module.kms.sns_topic_policy_requirement
}
