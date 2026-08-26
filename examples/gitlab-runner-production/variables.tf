variable "aws_region" {
  description = "Region for the fleet."
  type        = string
  default     = "us-east-1"
}

variable "vpc_id" {
  description = "Existing VPC (owned by your landing zone, not by this stack)."
  type        = string
}

variable "worker_subnet_ids" {
  description = "PRIVATE subnets for workers, three AZs. AZ spread is one of the biggest levers on Spot availability - don't skimp here."
  type        = list(string)

  validation {
    condition     = length(var.worker_subnet_ids) >= 3
    error_message = "Use at least three AZs in production - Spot depth and failure isolation both depend on it."
  }
}

variable "manager_subnet_ids" {
  description = "Private subnet(s) for the manager. Separate from the worker subnets is tidier but not required."
  type        = list(string)
  default     = []
}

variable "gitlab_url" {
  description = "GitLab instance (SaaS or self-managed)."
  type        = string
  default     = "https://gitlab.com"
}

variable "runner_token_ssm_parameter" {
  description = <<-EOT
    Name of an SSM SecureString parameter that ALREADY holds the glrt- token.
    Deliberately not passing the token through Terraform: a variable would land in
    state in cleartext, and anyone who can read state could then register a runner
    and receive your jobs.

    Create it out of band, e.g.:
      aws ssm put-parameter --name /ci/gitlab-runner/prod-token --type SecureString \
        --key-id alias/ci-runners --value 'glrt-xxxx'
  EOT
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary applied to both the manager and worker roles. Required here on purpose - it caps the blast radius even if a policy is later attached carelessly."
  type        = string
}

variable "worker_ami_id" {
  description = <<-EOT
    Your baked worker AMI: Docker + sshd + SSM agent preinstalled and patched.
    Required in production for three reasons - boot time IS job latency when you
    scale from zero, an internally-scanned image removes the boot-time package
    supply chain, and a pinned AMI keeps `terraform plan` stationary (an AL2023
    release would otherwise change the launch template on an unrelated apply).
  EOT
  type        = string
}

variable "manager_ami_id" {
  description = "Pinned manager AMI (arm64 if manager_instance_type is a Graviton family). Pinning is what makes it safe to enable instance refresh."
  type        = string
}

variable "gitlab_runner_version" {
  description = "Pinned gitlab-runner package version, e.g. \"17.9.0-1\"."
  type        = string
}

variable "fleeting_plugin_version" {
  description = "Pinned AWS fleeting plugin version, e.g. \"1.1.0\"."
  type        = string
}

variable "fleeting_plugin_sha256" {
  description = "SHA-256 of the fleeting plugin binary. The manager verifies it and refuses to start on mismatch - this is what closes the \"registry pull with no integrity check\" gap."
  type        = string
  default     = ""
}

variable "max_instances" {
  description = "Worker ceiling - your hard spend guardrail. Size it to your real peak concurrency."
  type        = number
  default     = 20
}

variable "alarm_sns_topic_arns" {
  description = "SNS topic(s) that page someone. An alarm nobody receives is decoration."
  type        = list(string)

  validation {
    condition     = length(var.alarm_sns_topic_arns) > 0
    error_message = "Wire at least one SNS topic - silent CI failure is the failure mode this module is most likely to hit."
  }
}

variable "job_policy_arns" {
  description = "Policies granting the WORKER role what jobs legitimately need (ECR pull, an S3 cache bucket, ...). Keep this tight: it is the blast radius of a malicious or compromised job."
  type        = list(string)
  default     = []
}

variable "cache_bucket" {
  description = "S3 bucket for GitLab's distributed cache. Empty disables it - but with single-use workers a shared cache is usually the single biggest CI speed win."
  type        = string
  default     = ""
}

variable "cache_key_prefix" {
  description = "Prefix within the cache bucket this fleet may read/write. Scoping the grant (rather than granting the whole bucket) is what stops one project's jobs poisoning another's cache."
  type        = string
  default     = "runner"
}

variable "tags" {
  description = "FinOps / ownership tags."
  type        = map(string)
  default = {
    Environment = "prod"
    ManagedBy   = "Terraform"
    Component   = "gitlab-ci-runners"
  }
}
