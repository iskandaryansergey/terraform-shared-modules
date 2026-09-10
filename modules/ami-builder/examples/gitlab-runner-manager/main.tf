# Builds the manager AMI that modules/gitlab-runner needs in an isolated VPC.
#
# Why it exists: that module's default manager bootstrap curls
# packages.gitlab.com and runs `gitlab-runner fleeting install`, which pulls the
# plugin from GitLab.com. In a VPC with no route to the internet neither is
# reachable and both hang rather than failing cleanly - which is why its
# COSTS.md lists a baked manager AMI as prerequisite P1 rather than an
# optimisation.
#
# This is that AMI: fetch once here, in a build subnet that does have egress,
# instead of on every manager boot in an estate that doesn't.
#
# The two subnets are the point, so don't collapse them:
#
#   build subnet  - egress to packages.gitlab.com. Exists to build images.
#   runner subnet - fully isolated. Runs the manager from the finished AMI.

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

variable "build_subnet_id" {
  description = "Subnet with egress to packages.gitlab.com and gitlab.com. NOT the subnet the runner fleet lives in."
  type        = string
}

variable "build_security_group_id" {
  description = "Security group for the build instance. Egress 443 to the package repositories and the AWS APIs."
  type        = string
}

variable "log_bucket" {
  description = "Bucket for build logs. Worth more here than usual: when a pinned runner version has been withdrawn from the repository, the dnf error in this log is the only thing that says so."
  type        = string
}

variable "parent_ami_id" {
  description = "Pinned Amazon Linux 2023 arm64 AMI. Bump deliberately, so that the image you audited and the image you rebuild are the same base."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK for the image snapshots. Banking estates generally mandate one."
  type        = string
}

# Versions pinned, checksums supplied. The manager AMI exists to make the runner
# fleet reproducible, and an AMI built from whatever was latest that morning
# isn't.
variable "runner_version" {
  description = "gitlab-runner package version, e.g. 17.5.3-1."
  type        = string
}

variable "fleeting_plugin_version" {
  description = "fleeting-plugin-aws version, e.g. 1.0.0."
  type        = string
}

variable "repo_script_sha256" {
  description = "SHA-256 of the GitLab package repository setup script. Without it the script runs as root unverified."
  type        = string
}

module "manager_image" {
  source = "../../"

  name        = "gitlab-runner-manager"
  description = "GitLab runner manager: gitlab-runner + fleeting-plugin-aws, baked for an isolated VPC"

  parent_image = var.parent_ami_id

  components = [
    {
      name = "os-update"
      arn  = "arn:aws:imagebuilder:${var.region}:aws:component/update-linux/1.0.2/1"
    },
    {
      name    = "hardening"
      bundled = "amazon-linux-hardening"
      parameters = {
        # The manager's access path is SSM Session Manager. "no", not "false":
        # these are the tokens sshd_config takes and `sshd -T` echoes back.
        AllowPasswordAuth = "no"
      }
    },
    {
      name    = "gitlab-runner"
      bundled = "install-gitlab-runner"
      parameters = {
        RunnerVersion    = var.runner_version
        PluginVersion    = var.fleeting_plugin_version
        RepoScriptSha256 = var.repo_script_sha256
      }
    },
    {
      name    = "verify"
      bundled = "verify-image"
      parameters = {
        # The manager reads its config from user-data at boot, so a config.toml
        # in the image would be both wrong and a place a token could hide.
        ForbiddenPaths = "/etc/gitlab-runner/config.toml /root/.aws/credentials"
      }
    },
  ]

  # The manager is a t4g, so the image has to be arm64 - which means the build
  # instance does too. Both types here are Graviton: a mixed list is refused,
  # because Image Builder picks from it on availability.
  instance_types = ["m7g.large", "m6g.large"]

  subnet_id          = var.build_subnet_id
  security_group_ids = [var.build_security_group_id]

  # Single region, so kms_key_arn covers it and require_cmk is satisfied without
  # a distribution_kms_key_arns entry.
  kms_key_arn = var.kms_key_arn
  require_cmk = true

  log_s3_bucket = var.log_bucket
  log_s3_prefix = "imagebuilder/gitlab-runner-manager"

  # 20 GB matches the runner module's manager_disk_gb default.
  root_volume_size_gb = 20

  # This is how the runner module should consume the image: set the runner's
  # manager_ami_id from this parameter rather than hardcoding an AMI id that goes
  # stale the next time this pipeline runs.
  ami_ssm_parameter_name = "/ami/gitlab-runner-manager/latest"

  # Monthly, unconditionally.
  #
  # EXPRESSION_MATCH_ONLY rather than the module's default: with a pinned parent
  # and content-addressed component versions, "dependency updates available" is
  # never true between applies, so the default is a schedule that can't fire.
  # The module refuses to plan that combination - see check
  # "the_schedule_can_actually_fire".
  #
  # A rebuilt AMI doesn't replace the running manager on its own. The runner
  # module reads the SSM parameter at plan time, so the fleet moves on your next
  # apply. See the wiring note at the bottom.
  schedule_expression                = "cron(0 2 1 * ? *)"
  schedule_timezone                  = "Europe/Dublin"
  pipeline_execution_start_condition = "EXPRESSION_MATCH_ONLY"

  enable_image_tests = true

  # Turn this on once Inspector EC2 scanning is enabled in the account. Off by
  # default because the module can't see that prerequisite, and setting it true
  # without it fails the build.
  enable_image_scanning = false

  # Deprecate at 45 days, keep the last 3, and never touch an image something
  # launched in the last 60 days — a manager AMI is long-lived by design.
  lifecycle_deprecate_after_days           = 45
  lifecycle_retain_at_least                = 3
  lifecycle_exclude_recently_launched_days = 60
  lifecycle_exclude_tags                   = { Retain = "true" }

  ami_tags = {
    Purpose   = "gitlab-runner-manager"
    Component = "ci"
  }

  tags = {
    Environment = "shared"
    Owner       = "platform"
    DataClass   = "internal"
  }
}

output "manager_ami_parameter" {
  description = "Pass this to the gitlab-runner module. Read the current value with: aws ssm get-parameter --name <this> --query Parameter.Value --output text"
  value       = module.manager_image.ami_ssm_parameter_name
}

output "pipeline_arn" {
  description = "Trigger the first build with: aws imagebuilder start-image-pipeline-execution --image-pipeline-arn <this>"
  value       = module.manager_image.pipeline_arn
}

output "component_versions" {
  description = "Exact component versions baked into the image. Worth capturing in the change record."
  value       = module.manager_image.component_versions
}

output "governance" {
  description = "The posture this pipeline has, as data."
  value       = module.manager_image.governance
}

# ---------------------------------------------------------------------------
# Wiring the result into the runner module
# ---------------------------------------------------------------------------
#
# The runner module wants a concrete manager_ami_id, so read the parameter this
# pipeline publishes:
#
#   data "aws_ssm_parameter" "manager_ami" {
#     name = module.manager_image.ami_ssm_parameter_name
#   }
#
#   module "runners" {
#     source          = "../../../gitlab-runner"
#     manager_ami_id  = data.aws_ssm_parameter.manager_ami.value
#     ...
#   }
#
# Terraform reads the parameter at plan time, so a new AMI reaches the manager
# on your next apply rather than on its own - and the manager is replaced when it
# does, because manager_ami_id feeds the launch template. That's the behaviour
# you want here: replacing the instance that holds the runner registration
# should be a deliberate act, not something a nightly pipeline decides.
#
# Workers are the opposite. They're ephemeral and replaced constantly, so
# pointing worker_ami_id at a parameter is fine. Build that image with a second
# instance of this module using the install-docker component.
