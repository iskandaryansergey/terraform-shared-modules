terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0, < 6.0.0"
    }
  }

  # Production state belongs in a locked-down remote backend. Note this stack's
  # state does NOT contain the runner token (we use the SSM path below), but it
  # does describe your CI infrastructure - treat it as sensitive.
  #
  # backend "s3" {
  #   bucket       = "acme-tfstate-prod"
  #   key          = "ci/gitlab-runners/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}
