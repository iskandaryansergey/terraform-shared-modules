# A multi-Region key with a disaster-recovery replica. The key set compiles
# the replica's policy for eu-west-1; modules/replica creates it there. Here
# both live in one configuration; README shows the split into a separate
# disaster-recovery workspace.

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
  source = "../.."

  name           = "ledger"
  deployers      = [var.deployer_role_arn]
  replica_region = "eu-west-1"

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
    sns_topic_arn = var.security_topic_arn
  }
}

module "kms_dr" {
  source    = "../../modules/replica"
  providers = { aws = aws.dr }

  replicas      = module.kms.replicas
  sns_topic_arn = var.dr_security_topic_arn
}

output "keys" {
  value = module.kms.keys
}

output "replica_key_arns" {
  value = module.kms_dr.key_arns
}

output "cost" {
  value = module.kms.cost
}

output "sns_topic_policy_requirements" {
  description = "primary goes into the eu-west-2 topic's policy, replica into the eu-west-1 one."
  value = {
    primary = module.kms.sns_topic_policy_requirement
    replica = module.kms_dr.sns_topic_policy_requirement
  }
}
