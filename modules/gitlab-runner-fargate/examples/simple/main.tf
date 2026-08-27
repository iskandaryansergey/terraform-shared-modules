# Smallest configuration that is still honest about what this platform needs.
#
# It plans against a real VPC, so it is a quick-start you can actually apply
# rather than a snippet. What it does NOT do is pretend the images exist: you
# must build them from ../../docker first and pass the digests.
#
# `terraform plan` here is also the CI gate that catches an in-module example
# that cannot plan.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0, < 6.0.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-west-1"
}

variable "vpc_id" {
  description = "Existing VPC. Must have a NAT gateway or an egress proxy - the manager polls GitLab over the internet and no VPC endpoint can reach it."
  type        = string
}

variable "manager_subnet_ids" {
  description = "Private subnets for the manager task."
  type        = list(string)
}

variable "job_subnet_ids" {
  description = "Private subnets for job tasks. Prefer subnets holding nothing else: the Fargate driver does not verify the job task's SSH host key, so the subnet is part of the containment."
  type        = list(string)
}

variable "manager_image" {
  description = "Manager image DIGEST (built from ../../docker/Dockerfile.manager). Must contain gitlab-runner and the Fargate driver."
  type        = string
}

variable "job_image" {
  description = "Job image DIGEST (built from ../../docker/Dockerfile.job). Remember image: in .gitlab-ci.yml is IGNORED - this is where the image is chosen."
  type        = string
}

variable "gitlab_url" {
  description = "GitLab instance URL."
  type        = string
  default     = "https://gitlab.com"
}

variable "runner_token" {
  description = "GitLab runner AUTHENTICATION token (glrt-...). Create the runner in the UI or via POST /user/runners first; registration tokens are deprecated."
  type        = string
  sensitive   = true
}

# The module refuses to take the token as a string, so the example has to create
# the secret. That is the point of the design: the safe path is the only path, so
# the token cannot end up in state by taking a shortcut.
#
# Note the token still reaches state HERE, because this example accepts it as a
# variable. In production, create the secret out of band and pass only its ARN.
resource "aws_secretsmanager_secret" "runner_token" {
  name                    = "gitlab/runner/${local.name}"
  description             = "GitLab runner authentication token for the ${local.name} Fargate fleet"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "runner_token" {
  secret_id     = aws_secretsmanager_secret.runner_token.id
  secret_string = var.runner_token
}

locals {
  name = "ci-fargate"
}

resource "aws_s3_bucket" "cache" {
  bucket_prefix = "${local.name}-cache-"
  force_destroy = true # example only; a real cache bucket should outlive the fleet
}

resource "aws_s3_bucket_public_access_block" "cache" {
  bucket                  = aws_s3_bucket.cache.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cache" {
  bucket = aws_s3_bucket.cache.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Without this the cache bucket grows forever - job caches are never cleaned up
# by the runner.
resource "aws_s3_bucket_lifecycle_configuration" "cache" {
  bucket = aws_s3_bucket.cache.id
  rule {
    id     = "expire-cache"
    status = "Enabled"
    filter {}
    expiration {
      days = 14
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_sns_topic" "alerts" {
  name = "${local.name}-runner-alerts"
}

module "runners" {
  source = "../.."

  name       = local.name
  gitlab_url = var.gitlab_url

  runner_token_secret_arn = aws_secretsmanager_secret.runner_token.arn

  vpc_id             = var.vpc_id
  manager_subnet_ids = var.manager_subnet_ids
  job_subnet_ids     = var.job_subnet_ids

  manager_image = var.manager_image

  job_profiles = {
    default = {
      image  = var.job_image
      cpu    = 1024
      memory = 2048
      # No task_role_arn on purpose. One shared task role is one blast radius for
      # every project on the fleet; use GitLab OIDC (see modules/ci-oidc) for
      # per-project AWS access.
    }
  }

  default_job_profile = "default"
  manager_concurrent  = 5

  cache_bucket_name = aws_s3_bucket.cache.id
  cache_path        = local.name

  # Alarms with no destination are an audit trail, not an alerting system.
  alarm_sns_topic_arns = [aws_sns_topic.alerts.arn]

  tags = {
    Environment = "example"
    Service     = "gitlab-ci"
  }
}

output "next_steps" {
  description = "What to do after apply."
  value       = <<-EOT
    1. Confirm the manager is running:
       ${module.runners.verify_commands.manager_running}

    2. Watch it register with GitLab:
       ${module.runners.verify_commands.manager_logs}

    3. Run a pipeline. Remember: image: and services: in .gitlab-ci.yml are
       IGNORED - the job runs in ${var.job_image}.

    4. If jobs never start, check stopped-task reasons before anything else:
       ${module.runners.verify_commands.stopped_reasons}

    5. The account Fargate vCPU quota is usually the real ceiling, not
       manager_concurrent:
       ${module.runners.verify_commands.vcpu_quota}
  EOT
}

output "job_task_definition_arns" {
  description = "Exactly what a pipeline may select with FARGATE_TASK_DEFINITION, and exactly what the manager may run."
  value       = module.runners.job_task_definition_arns
}

output "manager_policy_statements" {
  description = "The fleet's containment boundary - worth reading in a plan diff."
  value       = module.runners.manager_policy_statements
}
