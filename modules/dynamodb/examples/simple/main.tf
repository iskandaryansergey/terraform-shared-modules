# Simplest useful case: a single-key, on-demand table with the secure defaults
# (PITR on, deletion protection on, encrypted). Declare the key's type once in
# `attributes` and you're done.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.40.0, < 6.0.0" }
  }
}

provider "aws" {
  region = "us-east-1"
}

module "table" {
  source = "../.." # the dynamodb module

  name       = "sessions"
  hash_key   = "pk"
  attributes = { pk = "S" }
  # PAY_PER_REQUEST, PITR, deletion protection, encryption - all on by default
}

output "table_name" {
  value = module.table.table_name
}

output "table_arn" {
  value = module.table.table_arn
}
