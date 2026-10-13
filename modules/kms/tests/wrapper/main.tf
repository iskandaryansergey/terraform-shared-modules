# A root for `terraform validate`. The module declares
# configuration_aliases = [aws.replica], and Terraform cannot validate such a
# module on its own: a root has to pass the aliased provider. CI validates
# here. No credentials needed; validate never calls AWS.

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
  alias  = "replica"
  region = "eu-west-1"
}

module "kms" {
  source    = "../.."
  providers = { aws = aws, aws.replica = aws.replica }

  name = "validate"
  keys = {
    data = { multi_region = true, replicate = true, services = ["logs", "rds", "secretsmanager"] }
  }
}
