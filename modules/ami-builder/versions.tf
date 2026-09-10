terraform {
  # 1.9 for cross-variable validation and optional() defaults. It also evaluates
  # both sides of || and &&, so every condition in here is a ternary instead.
  # tests/lint_validations.py enforces that - there's no 1.9 binary locally to
  # find out the hard way.
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Higher than the repo's usual 5.40 floor: lifecycle_policy and the
      # distribution's ssm_parameter_configuration are both newer than that.
      # Tested on 5.100.0; the floor is a safe guess, not a bisected minimum.
      version = ">= 5.70.0, < 6.0.0"
    }
  }
}
