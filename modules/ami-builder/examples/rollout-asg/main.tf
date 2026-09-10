# The consumption side: a worker fleet that tracks this pipeline's image, and
# the lever that gets it back when a build turns out bad.
#
# This is mode A from ROLLOUT.md. The launch template holds
# `resolve:ssm:/ami/<name>/latest`, which EC2 resolves at instance launch - so a
# new image reaches the fleet on the next instance replacement with no Terraform
# run at all. That is what makes a scheduled pipeline useful rather than tidy.
#
# What you give up is the ASG's own safety net: auto_rollback returns the group
# to its previous launch template version, and in this shape the template never
# changes - the AMI moved underneath it. Rollback here is a deliberate pin, and
# that is what pinned_ami_id below is for.
#
# See ROLLOUT.md for the other two modes and for the two-parameter promotion
# pattern, which is what a regulated estate usually wants instead.

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
  description = "Private subnet for the image build instance."
  type        = string
}

variable "build_security_group_id" {
  description = "Security group for the build instance. Egress only."
  type        = string
}

variable "fleet_subnet_ids" {
  description = "Subnets the worker fleet runs in. More than one AZ, unlike the build subnet."
  type        = list(string)
}

variable "fleet_security_group_id" {
  description = "Security group for the workers."
  type        = string
}

variable "log_bucket" {
  description = "Existing bucket for build logs."
  type        = string
}

variable "parent_ami_id" {
  description = "Pinned Amazon Linux 2023 AMI to build from. Bump it deliberately."
  type        = string
}

variable "fleet_instance_profile_name" {
  description = "Instance profile for the workers. Leave empty to skip, but then nothing can reach them over SSM."
  type        = string
  default     = ""
}

# The rollback lever.
#
# Empty (the default) means the fleet tracks the pipeline through SSM. Set it to
# a known-good AMI id and apply: the launch template stops resolving, the ASG's
# launch_template trigger starts an instance refresh on its own, and the next
# build cannot move the fleet back.
#
# Tag that image Retain=true before you depend on it - lifecycle_exclude_tags
# below is what makes the tag mean something.
# 0 on purpose. resolve:ssm: against a parameter that does not exist yet fails
# RunInstances, and an ASG retries that forever - so the fleet stays empty until
# the first build has published the parameter. Trigger it with
# verify_commands.trigger_build, then raise this.
variable "fleet_desired_capacity" {
  description = "Workers to run. Leave at 0 until the pipeline has published its first image."
  type        = number
  default     = 0
}

variable "pinned_ami_id" {
  description = "Pin the fleet to this AMI instead of tracking the pipeline. Empty tracks the pipeline."
  type        = string
  default     = ""

  validation {
    condition     = var.pinned_ami_id == "" ? true : can(regex("^ami-[0-9a-f]{8,17}$", var.pinned_ami_id))
    error_message = "pinned_ami_id must be empty or an AMI id like ami-0123456789abcdef0."
  }
}

module "worker_image" {
  source = "../../"

  name        = "al2023-worker"
  description = "Amazon Linux 2023 CI worker with Docker"

  parent_image = var.parent_ami_id

  components = [
    { name = "hardening", bundled = "amazon-linux-hardening" },
    {
      name    = "docker"
      bundled = "install-docker"
      parameters = {
        DockerUser  = "ec2-user"
        LiveRestore = "false"
      }
    },
    { name = "verify", bundled = "verify-image" },
  ]

  subnet_id          = var.build_subnet_id
  security_group_ids = [var.build_security_group_id]

  log_s3_bucket = var.log_bucket
  log_s3_prefix = "imagebuilder/al2023-worker"

  # This is the whole consumption contract: the pipeline writes here after every
  # successful build, and the launch template below reads it at launch.
  ami_ssm_parameter_name = "/ami/al2023-worker/latest"

  schedule_expression                = "cron(0 3 1 * ? *)"
  schedule_timezone                  = "Europe/Dublin"
  pipeline_execution_start_condition = "EXPRESSION_MATCH_ONLY"

  # Retention is the rollback window - see ROLLOUT.md section 4. 90 days is an
  # honest answer to "how far back would we ever roll", and the Retain tag is
  # the break-glass for an image that has to outlive it.
  lifecycle_deprecate_after_days           = 30
  lifecycle_delete_after_days              = 90
  lifecycle_retain_at_least                = 5
  lifecycle_exclude_recently_launched_days = 30
  lifecycle_exclude_tags                   = { Retain = "true" }

  ami_tags = {
    Purpose = "ci-worker"
  }

  tags = {
    Environment = "shared"
    Owner       = "platform"
  }
}

# ---------------------------------------------------------------------------
# The fleet
# ---------------------------------------------------------------------------

resource "aws_launch_template" "worker" {
  name_prefix   = "al2023-worker-"
  instance_type = "m6i.large"

  # resolve:ssm: is evaluated by EC2 at RunInstances, not by Terraform at plan.
  # A pin swaps it for a literal id, which is a template change and therefore a
  # trigger for the refresh below.
  image_id = var.pinned_ami_id != "" ? var.pinned_ami_id : module.worker_image.ami_launch_template_reference

  vpc_security_group_ids = [var.fleet_security_group_id]

  dynamic "iam_instance_profile" {
    for_each = var.fleet_instance_profile_name != "" ? [1] : []

    content {
      name = var.fleet_instance_profile_name
    }
  }

  # The image is hardened but IMDSv2 is a per-instance setting, not a property
  # of the AMI - it has to be set again here.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name          = "al2023-worker"
      Environment   = "shared"
      TracksImageOf = module.worker_image.pipeline_name
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "worker" {
  name_prefix         = "al2023-worker-"
  min_size            = 0
  max_size            = 6
  desired_capacity    = var.fleet_desired_capacity
  vpc_zone_identifier = var.fleet_subnet_ids

  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.worker.id
    version = aws_launch_template.worker.latest_version
  }

  # Rolling replacement, with the fleet staying mostly up.
  #
  # A launch template change always starts a refresh, so a pin (or an unpin)
  # rolls the fleet by itself. A new image does NOT, because nothing in the
  # template changed - the AMI moved underneath the resolve:ssm: reference.
  # Starting that refresh is the deliberate step, and the command is in the
  # outputs below.
  #
  # No auto_rollback: it returns the group to the previous launch template
  # version, and in this shape there isn't one. Rollback is the pin.
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 90
      instance_warmup        = 300
    }
  }

  tag {
    key                 = "Environment"
    value               = "shared"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Outputs, written as the commands you will actually run
# ---------------------------------------------------------------------------

output "tracking" {
  description = "What the fleet is currently following."
  value = {
    mode      = var.pinned_ami_id != "" ? "PINNED - the pipeline cannot move this fleet" : "tracking the pipeline through SSM"
    image_id  = aws_launch_template.worker.image_id
    parameter = module.worker_image.ami_ssm_parameter_name
    # The floor on how far back a pin can point.
    rollback_depth_images = module.worker_image.governance.rollback_depth_images
  }
}

output "roll_forward" {
  description = "Move the fleet onto the newest image. Nothing in Terraform changes, so this is the trigger."
  value = {
    what_is_current = "aws ssm get-parameter --name ${module.worker_image.ami_ssm_parameter_name} --query Parameter.Value --output text"
    first_build     = "aws imagebuilder start-image-pipeline-execution --image-pipeline-arn ${module.worker_image.pipeline_arn}   # needed once before the fleet can launch at all"
    replace_fleet   = "aws autoscaling start-instance-refresh --auto-scaling-group-name ${aws_autoscaling_group.worker.name} --preferences '{\"MinHealthyPercentage\":90,\"InstanceWarmup\":300}'"
    watch           = "aws autoscaling describe-instance-refreshes --auto-scaling-group-name ${aws_autoscaling_group.worker.name} --query 'InstanceRefreshes[0].[Status,PercentageComplete,StatusReason]'"
  }
}

output "roll_back" {
  description = "The rollback sequence. Protect the image first, then pin it - a pin survives the next build, a parameter write does not."
  value = {
    list_candidates = "aws ec2 describe-images --owners self --filters Name=tag:SourceRecipe,Values=al2023-worker --query 'reverse(sort_by(Images,&CreationDate))[*].[ImageId,CreationDate,Tags[?Key==`SourceRecipeVersion`].Value|[0]]' --output table"
    protect_it      = "aws ec2 create-tags --resources <ami-id> --tags Key=Retain,Value=true"
    pin_it          = "terraform apply -var pinned_ami_id=<ami-id>   # the ASG refresh starts itself"
    stop_the_source = "aws imagebuilder update-image-pipeline --image-pipeline-arn ${module.worker_image.pipeline_arn} --status DISABLED"
  }
}

output "governance" {
  description = "The pipeline's posture, as data."
  value       = module.worker_image.governance
}
