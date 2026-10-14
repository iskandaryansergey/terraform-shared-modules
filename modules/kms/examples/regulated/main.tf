# A key set for a regulated workload: data under customer-supplied (imported)
# key material, a signing key in yearly generations, tenant isolation by
# encryption context, algorithm limits, and the stricter guardrails.

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
  description = "The role the HCP Terraform workspace applies as."
  type        = string
}

variable "break_glass_role_arn" {
  description = "Emergency key administration; assumed with MFA."
  type        = string
}

variable "hsm_ceremony_role_arn" {
  description = "The role that imports key material from the on-premises HSM."
  type        = string
}

variable "app_role_arn" {
  description = "The application; its session carries a tenant tag."
  type        = string
}

variable "organization_id" {
  type = string
}

variable "security_topic_arn" {
  description = "An SNS topic in eu-west-2 for key events."
  type        = string
}

module "kms" {
  source = "../.."

  name      = "ledger"
  deployers = [var.deployer_role_arn]

  key_custodians = [var.hsm_ceremony_role_arn]

  keys = {
    # Customer-supplied material: the key is created pending import, and the
    # ceremony role imports the material out of band.
    data = {
      origin                     = "EXTERNAL"
      purpose                    = "database"
      users                      = [var.app_role_arn]
      require_encryption_context = ["tenant"]
      encryption_context_values  = { tenant = ["$${aws:PrincipalTag/tenant}"] }
    }

    # Signing keys cannot rotate automatically: a new generation each year.
    # Verifiers keep the old public keys; signing moves to the newest.
    statements = {
      purpose            = "signing"
      generations        = ["2025", "2026"]
      allowed_algorithms = ["ECDSA_SHA_256"]
      encrypters         = [var.app_role_arn]
    }
  }

  guardrails = {
    organization_id                 = var.organization_id
    min_deletion_window_days        = 30
    min_days_unused_before_deletion = 90
    protect_policy                  = true
    protect_aliases_and_rotation    = true
    protect_tags                    = true
    protect_key_material            = true
    break_glass                     = [var.break_glass_role_arn]
    break_glass_requires_mfa        = true
  }

  notifications = {
    sns_topic_arn = var.security_topic_arn
    events        = ["deletion", "rotation", "import_expiry", "schedule_deletion", "disable", "policy_change"]
  }

  # The account has an organization trail.
  acknowledged_checks = ["cloudtrail_events_need_a_trail"]

  required_tag_keys = ["DataClassification"]
  tags              = { DataClassification = "confidential" }
}

output "key_arns" {
  value = module.kms.key_arns
}

output "generations" {
  value = module.kms.generations
}

output "compliance_snippets" {
  description = "AWS Config rules and CloudWatch Logs filters for the platform team."
  value       = module.kms.compliance_snippets
}

output "verify_commands" {
  value = module.kms.verify_commands
}
