terraform {
  # 1.9 for validations that read other variables. It also evaluates both
  # sides of || and &&, so conditions here are ternaries or can().
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.90.0, < 7.0.0"
    }
  }
}
