# Smallest configuration that is still honest about what a governed image
# pipeline needs.
#
# It plans against a real VPC, so it is a quick-start you can actually apply
# rather than a snippet. `terraform plan` here is also the CI gate that catches
# an in-module example that cannot plan.
#
# What this produces: a hardened Amazon Linux 2023 image with Docker, rebuilt on
# the first of each month, published to an SSM parameter, deprecated at 30 days
# and deleted at 180 with the last three and anything recently launched exempt.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70.0, < 6.0.0"
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

variable "subnet_id" {
  description = "Private subnet for the build instance. Needs a route to the AWS APIs, and to wherever dnf fetches packages from."
  type        = string
}

variable "security_group_id" {
  description = "Security group for the build instance. Egress only; no ingress is required."
  type        = string
}

variable "log_bucket" {
  description = "Existing bucket for build logs. Without it a failed build discards its component output."
  type        = string
}

# Pinning the parent image is the difference between an artifact you can
# reproduce and one you cannot. Resolving it through a data source here keeps the
# example runnable while still handing the module a concrete AMI id: the value
# the module receives is a specific image, and it is recorded in state.
#
# For a truly reproducible pipeline, replace this with a literal ami-... that you
# bump deliberately. Note that governance.parent_image_pinned will report true
# either way - it reads the value the module receives, which is a concrete AMI
# id. What moves is which id most_recent resolves to on your next plan, and
# governance.components_fetch_from_moving_sources reports the other half: the
# bundled components run dnf without version pins, so a pinned parent alone does
# not make the image byte-reproducible.
data "aws_ami" "al2023" {
  owners      = ["amazon"]
  most_recent = true

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

module "base_image" {
  source = "../../"

  name        = "al2023-ci-base"
  description = "Hardened Amazon Linux 2023 with Docker, for CI workers"

  parent_image = data.aws_ami.al2023.id

  components = [
    # Note there is no update-linux component here. The bundled hardening
    # component already runs `dnf update --security`, and stacking the
    # AWS-managed full-update component in front of it pays a second metadata
    # refresh for packages the first pass has already applied.
    # Shipped with the module. Versioned with it, rather than copy-pasted here.
    {
      name    = "hardening"
      bundled = "amazon-linux-hardening"
    },
    {
      name    = "docker"
      bundled = "install-docker"
      parameters = {
        DockerUser = "ec2-user"
        # One job per instance: a daemon restart should take the job with it.
        LiveRestore = "false"
      }
    },
    # Test-phase only. Runs last, and fails the build rather than the fleet.
    {
      name    = "verify"
      bundled = "verify-image"
    },
  ]

  # Build infrastructure
  subnet_id          = var.subnet_id
  security_group_ids = [var.security_group_id]
  instance_types     = ["m6i.large", "m6a.large"]

  log_s3_bucket = var.log_bucket
  log_s3_prefix = "imagebuilder/al2023-ci-base"

  # Consumption: a launch template resolving resolve:ssm:<this> picks up each new
  # image with no Terraform run.
  ami_ssm_parameter_name = "/ami/al2023-ci-base/latest"

  # First of the month at 03:00 Dublin.
  #
  # EXPRESSION_MATCH_ONLY, not the module's default. The default only builds
  # when the base image or a component VERSION changed - it cannot see that new
  # packages exist in the repository. With a pinned parent and content-addressed
  # components, nothing ever changes between applies, so the default would give
  # you a cron that never fires and a patching baseline that never patches.
  # Building unconditionally costs about $0.04 a month.
  schedule_expression                = "cron(0 3 1 * ? *)"
  schedule_timezone                  = "Europe/Dublin"
  pipeline_execution_start_condition = "EXPRESSION_MATCH_ONLY"

  # Retention. Snapshot storage is the only line that grows without bound, so
  # deletion is on - at a long horizon, with the recency exemption protecting
  # anything still being launched.
  lifecycle_deprecate_after_days           = 30
  lifecycle_delete_after_days              = 180
  lifecycle_retain_at_least                = 3
  lifecycle_exclude_recently_launched_days = 30

  ami_tags = {
    Purpose = "ci-worker"
    OS      = "al2023"
  }

  tags = {
    Environment = "shared"
    Owner       = "platform"
  }
}

output "pipeline_arn" {
  description = "Trigger a build with: aws imagebuilder start-image-pipeline-execution --image-pipeline-arn <this>"
  value       = module.base_image.pipeline_arn
}

output "ami_reference" {
  description = "Paste into a launch template's image_id."
  value       = module.base_image.ami_launch_template_reference
}

output "governance" {
  description = "The posture this pipeline actually has, as data."
  value       = module.base_image.governance
}

output "network_contract" {
  description = "Hand this to whoever owns the VPC."
  value       = module.base_image.network_contract
}
