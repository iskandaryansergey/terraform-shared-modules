# The smallest call: one symmetric key with every default - rotation yearly, a
# 30-day deletion window, IAM delegation, deletion protection, and the role
# running the plan detected as the deployer.

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

module "kms" {
  source = "../.."

  name = "orders"
}

output "key_arn" {
  value = module.kms.key_arns["main"]
}
