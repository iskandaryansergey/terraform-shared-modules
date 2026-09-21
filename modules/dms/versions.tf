terraform {
  # 1.9 for cross-variable validation and optional() defaults. It also evaluates
  # both sides of || and &&, so conditions here are ternaries instead -
  # tests/lint_validations.py enforces that.
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # aws_dms_s3_endpoint and the serverless aws_dms_replication_config are
      # both newer than the repo's usual 5.40 floor. Validated on 5.100.0.
      version = ">= 5.70.0, < 6.0.0"
    }
  }
}
