# A locked-down key set: no IAM delegation, keys reachable only by the
# principals named here, only through the account's KMS VPC endpoints, inside
# the organization, with the policy and aliases protected.

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

variable "break_glass_role_arn" {
  type = string
}

variable "security_admin_role_arn" {
  type = string
}

variable "auditor_role_arn" {
  type = string
}

variable "app_role_arn" {
  type = string
}

variable "ingest_role_arn" {
  type = string
}

variable "organization_id" {
  type = string
}

variable "kms_vpc_endpoint_id" {
  type = string
}

variable "security_topic_arn" {
  type = string
}

module "kms" {
  source = "../.."

  name = "cardholder"

  # Only the key policy grants access; the deployer is named, never detected.
  iam_delegation  = false
  deployers       = [var.deployer_role_arn]
  detect_deployer = false

  administrators = [var.security_admin_role_arn]
  auditors       = [var.auditor_role_arn]

  key_defaults = {
    service_access       = "named"
    deletion_window_days = 30
  }

  keys = {
    data = {
      purpose                    = "database"
      users                      = [var.app_role_arn]
      require_encryption_context = ["tenant"]
    }
    ingest = {
      services   = ["s3"]
      encrypters = [var.ingest_role_arn]
      decrypters = [var.app_role_arn]
    }
  }

  guardrails = {
    organization_id              = var.organization_id
    vpc_endpoint_ids             = [var.kms_vpc_endpoint_id]
    min_deletion_window_days     = 30
    protect_policy               = true
    protect_aliases_and_rotation = true
    break_glass                  = [var.break_glass_role_arn]
  }

  notifications = {
    sns_topic_arn = var.security_topic_arn
    events        = ["deletion", "rotation", "schedule_deletion", "disable", "policy_change", "rotation_disabled", "alias_change"]
  }

  # The account has an organization trail.
  acknowledged_checks = ["cloudtrail_events_need_a_trail"]

  required_tag_keys = ["DataClassification"]
  tags              = { DataClassification = "pci" }
}

output "policies" {
  value = module.kms.policies
}

output "governance" {
  value = module.kms.governance
}

output "organization_policy_snippets" {
  value = module.kms.organization_policy_snippets
}
