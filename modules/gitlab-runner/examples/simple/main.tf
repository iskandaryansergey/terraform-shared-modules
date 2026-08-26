# Simplest useful fleet: Spot workers that scale to zero when nothing is queued.
# Create the runner in GitLab first (Settings -> CI/CD -> Runners -> New runner)
# and pass its glrt- token.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.40.0, < 6.0.0" }
  }
}

provider "aws" {
  region = "us-east-1"
}

variable "runner_token" {
  description = "GitLab runner authentication token (glrt-...)."
  type        = string
  sensitive   = true
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  description = "Private subnets across 3 AZs."
  type        = list(string)
}

module "runners" {
  source = "../.." # the gitlab-runner module

  name              = "ci"
  vpc_id            = var.vpc_id
  worker_subnet_ids = var.private_subnet_ids
  runner_token      = var.runner_token

  max_instances = 5 # spend guardrail

  # Pin what the manager fetches and runs as root. The module refuses to build
  # unpinned unless you explicitly set allow_unpinned_artifacts = true.
  gitlab_runner_version   = "17.9.0-1"
  fleeting_plugin_version = "1.1.0"

  tags = { Team = "platform" }
}

output "worker_asg_name" {
  value = module.runners.worker_asg_name
}

output "max_concurrent_jobs" {
  value = module.runners.max_concurrent_jobs
}
