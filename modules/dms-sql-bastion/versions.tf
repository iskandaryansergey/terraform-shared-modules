terraform {
  # 1.9 for cross-variable validation and optional() defaults. It also evaluates
  # both sides of || and &&, so conditions here are ternaries or can().
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70.0, < 6.0.0"
    }
  }
}
