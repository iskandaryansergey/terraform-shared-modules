terraform {
  # 1.9 for cross-variable validation. It evaluates both sides of || and &&,
  # so conditions are ternaries or can() - tests/lint_validations.py checks.
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 5.73 fixed persistent validation errors when a malformed policy reached
      # state; earlier 5.x can wedge a key whose policy AWS rejected once.
      version = ">= 5.73.0, < 6.0.0"

      # Replica keys are created in the region of this provider. Pass the
      # default provider here when no key replicates.
      configuration_aliases = [aws.replica]
    }
  }
}
