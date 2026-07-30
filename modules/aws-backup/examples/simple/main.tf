# Simplest useful case: a vault plus a daily plan (35-day retention) that backs
# up everything tagged Backup=true. The IAM role, encryption (AWS-managed key),
# and selection are all handled for you.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.40.0, < 6.0.0" }
  }
}

provider "aws" {
  region = "us-east-1"
}

module "backups" {
  source = "../.." # the aws-backup module

  vault_name = "app-backup"

  plans = {
    daily = {
      rules = {
        daily = {
          schedule          = "cron(0 5 * * ? *)" # 05:00 UTC
          delete_after_days = 35
        }
      }
      selections = {
        tagged = { selection_tags = [{ key = "Backup", value = "true" }] }
      }
    }
  }
}

output "vault_arn" {
  value = module.backups.vault_arn
}

output "plan_ids" {
  value = module.backups.plan_ids
}
