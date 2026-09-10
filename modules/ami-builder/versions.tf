terraform {
  # 1.9 for cross-variable validation and optional() defaults.
  #
  # 1.9 also evaluates both sides of || and &&, so nothing here puts a throwing
  # expression next to one. tests/lint_validations.py checks that, since we don't
  # have 1.9.8 locally to find out the hard way.
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Higher than the repo's usual 5.40 floor because lifecycle_policy and the
      # distribution's ssm_parameter_configuration are both recent additions.
      # Validated on 5.100.0; the floor is a guess on the safe side, not a
      # bisected minimum.
      version = ">= 5.70.0, < 6.0.0"
    }
  }
}
