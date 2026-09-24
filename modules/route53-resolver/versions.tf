terraform {
  # 1.9 for cross-variable validation and optional() defaults. It also evaluates
  # both sides of || and &&, so conditions here are ternaries instead.
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # aws_vpc_security_group_egress_rule needs 5.20+; the resolver resources
      # are much older. Validated on 5.100.0.
      version = ">= 5.70.0, < 6.0.0"
    }
  }
}
