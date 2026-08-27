data "aws_ami" "al2023_manager" {
  count = local.create && var.manager_ami_id == "" ? 1 : 0

  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-${local.manager_arch}"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

# SecureString in SSM rather than user_data, so it stays out of the launch
# template.
resource "aws_ssm_parameter" "token" {
  count = local.create && local.create_token_param ? 1 : 0

  name        = local.token_ssm_parameter
  description = "GitLab runner authentication token for ${var.name}"
  type        = "SecureString"
  key_id      = var.kms_key_arn != "" ? var.kms_key_arn : null
  value       = var.runner_token
  tags        = local.common_tags
}

resource "aws_launch_template" "manager" {
  count = local.create ? 1 : 0

  name_prefix   = "${var.name}-manager-"
  image_id      = local.manager_ami
  instance_type = var.manager_instance_type
  user_data     = base64encode(local.manager_user_data)
  ebs_optimized = true

  # ASG path only: aws_instance sets its own subnet, which AWS won't combine
  # with an LT network interface.
  dynamic "network_interfaces" {
    for_each = var.manager_self_heal ? [1] : []
    content {
      associate_public_ip_address = var.assign_public_ips
      security_groups             = var.manager_security_group_ids
      delete_on_termination       = true
    }
  }

  iam_instance_profile {
    arn = aws_iam_instance_profile.manager[0].arn
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = local.manager_root_device_resolved
    ebs {
      volume_size           = var.manager_disk_gb
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = var.kms_key_arn != "" ? var.kms_key_arn : null
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = var.detailed_monitoring
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "${var.name}-manager" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.common_tags, { Name = "${var.name}-manager" })
  }

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

# An ASG of one. No durable state on the manager, so if the instance or its AZ
# dies AWS builds another and CI resumes.
resource "aws_autoscaling_group" "manager" {
  count = local.create && var.manager_self_heal ? 1 : 0

  name                = "${var.name}-manager"
  vpc_zone_identifier = local.manager_subnet_ids

  min_size         = 1
  max_size         = 1
  desired_capacity = 1

  health_check_type         = "EC2"
  health_check_grace_period = 300

  # Opt-in, and manager_absent reads these.
  metrics_granularity = "1Minute"
  enabled_metrics     = ["GroupInServiceInstances", "GroupTotalInstances"]

  launch_template {
    id      = aws_launch_template.manager[0].id
    version = aws_launch_template.manager[0].latest_version
  }

  # Off by default: a refresh kills every in-flight job, and with an unpinned AMI
  # an unrelated apply would trigger one. Pin manager_ami_id first.
  dynamic "instance_refresh" {
    for_each = var.manager_instance_refresh ? [1] : []
    content {
      strategy = "Rolling"
      preferences {
        min_healthy_percentage = 0 # a fleet of one: replace it, don't try to keep it up
      }
    }
  }

  dynamic "tag" {
    for_each = merge(local.common_tags, { Name = "${var.name}-manager" })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  depends_on = [aws_iam_role_policy.manager, aws_ssm_parameter.token]
}

# Plain-instance alternative. Simpler, but a failure pauses all CI until someone
# notices. Dev and sandbox only.
resource "aws_instance" "manager" {
  count = local.create && !var.manager_self_heal ? 1 : 0

  # Set here rather than in the LT: subnet_id and an LT network_interfaces block
  # are mutually exclusive, so the LT omits the block on this path.
  subnet_id                   = local.manager_subnet_ids[0]
  vpc_security_group_ids      = var.manager_security_group_ids
  associate_public_ip_address = var.assign_public_ips

  launch_template {
    id      = aws_launch_template.manager[0].id
    version = aws_launch_template.manager[0].latest_version
  }

  tags = merge(local.common_tags, { Name = "${var.name}-manager" })

  depends_on = [aws_iam_role_policy.manager, aws_ssm_parameter.token]
}
