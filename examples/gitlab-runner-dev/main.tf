# DEV / SANDBOX runner fleet.
#
# Optimised for "cheap and quick to stand up", and it makes that trade explicitly:
#   - 100% Spot, tiny ceiling, aggressive scale-to-zero (idle_count = 0 always)
#   - unpinned gitlab-runner/plugin, so you don't chase version numbers in a sandbox
#   - one worker reused for several jobs, to skip repeated cold boots
#   - alarms off, short log retention
#
# Do NOT copy this into production. See ../gitlab-runner-production for that -
# the differences are called out at the bottom of the README.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.40.0, < 6.0.0" }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = "dev"
      ManagedBy   = "Terraform"
      Component   = "gitlab-ci-runners"
      Ephemeral   = "true"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_id" {
  description = "Existing VPC."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets with egress (NAT). Two is fine for dev."
  type        = list(string)
}

variable "runner_token" {
  description = "GitLab runner authentication token (glrt-...). Fine to pass directly in a sandbox; production should use the SSM path instead."
  type        = string
  sensitive   = true
}

module "runners" {
  source = "../../modules/gitlab-runner"

  name              = "ci-dev"
  vpc_id            = var.vpc_id
  worker_subnet_ids = var.private_subnet_ids
  gitlab_url        = "https://gitlab.com"

  # Sandbox: the token in state is an accepted risk here, not in prod.
  runner_token = var.runner_token

  # Small ceiling - a runaway pipeline in dev shouldn't cost real money.
  max_instances         = 2
  capacity_per_instance = 1

  # Reuse a worker for a few jobs: in dev, boot time hurts more than the
  # (small) risk of state leaking between your own jobs.
  max_use_count = 10

  # Always scale to zero. A dev fleet sitting idle overnight is pure waste.
  autoscaling_policies = [
    { idle_count = 0, idle_time = "5m0s", periods = ["* * * * *"] },
  ]

  # Cheapest thing that still builds: all Spot, small burstable workers.
  spot_enabled          = true
  worker_instance_types = ["t3.medium", "t3a.medium", "t3.large", "t3a.large"]
  worker_disk_gb        = 30
  manager_instance_type = "t4g.micro"

  # Sandbox convenience: don't chase version pins here. The module makes you
  # say so out loud, and the manager logs a warning at boot.
  allow_unpinned_artifacts = true

  # Keep it quiet and cheap - you're watching the pipeline, not a dashboard.
  create_alarms      = false
  log_retention_days = 7

  # Still off, even in dev: if you need DinD, do it on a dedicated fleet.
  docker_privileged = false

  tags = { Team = "platform", CostCenter = "engineering-sandbox" }
}

output "worker_asg_name" {
  value = module.runners.worker_asg_name
}

output "max_concurrent_jobs" {
  value = module.runners.max_concurrent_jobs
}

output "verify" {
  description = "Paste-ready checks for whether the fleet actually came up."
  value       = module.runners.verify_commands
}
