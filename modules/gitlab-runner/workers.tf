data "aws_ami" "al2023_worker" {
  count = local.create && var.worker_ami_id == "" ? 1 : 0

  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-${var.cpu_architecture}"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_launch_template" "worker" {
  count = local.create ? 1 : 0

  name_prefix   = "${var.name}-worker-"
  image_id      = local.worker_ami
  user_data     = base64encode(local.worker_user_data)
  ebs_optimized = true

  # instance_type is deliberately unset - the ASG's mixed-instances overrides
  # choose it, which is what gives Spot a wide pool to draw from.

  # A machine running untrusted CI code has no business holding a public IP; the
  # fleet needs no inbound access at all.
  network_interfaces {
    associate_public_ip_address = var.assign_public_ips
    security_groups             = [aws_security_group.worker[0].id]
    delete_on_termination       = true
  }

  # A privileged job could otherwise `shutdown` the host and leave a stopped,
  # still-billed, capacity-holding instance behind.
  instance_initiated_shutdown_behavior = "terminate"

  iam_instance_profile {
    arn = aws_iam_instance_profile.worker[0].arn
  }

  # IMDSv2 only. The hop limit of 1 also means job containers can't reach
  # metadata and grab the instance role.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = var.imds_hop_limit
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.worker_disk_gb
      volume_type           = "gp3"
      throughput            = var.worker_disk_throughput
      iops                  = var.worker_disk_iops
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
    tags          = merge(local.common_tags, { Name = "${var.name}-worker" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.common_tags, { Name = "${var.name}-worker" })
  }

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

# The fleet. Note what ISN'T here: no scaling policies, no target tracking. The
# runner manager owns desired_capacity; AWS must not second-guess it.
resource "aws_autoscaling_group" "workers" {
  count = local.create ? 1 : 0

  name                = local.worker_asg_name
  vpc_zone_identifier = var.worker_subnet_ids

  # Scale-to-zero: nothing queued, nothing running, nothing billed.
  min_size         = 0
  max_size         = var.max_instances
  desired_capacity = 0

  # The plugin protects individual instances while they hold a job.
  protect_from_scale_in = true
  capacity_rebalance    = var.capacity_rebalance

  # Protected instances block ASG deletion, so destroy wedges while a job runs.
  force_delete = var.force_delete_workers

  # AZRebalance would happily kill a busy worker to even out AZs.
  suspended_processes = ["AZRebalance"]

  health_check_type         = "EC2"
  health_check_grace_period = 60
  default_instance_warmup   = 30

  # Group metrics are opt-in. Without these CloudWatch never publishes
  # GroupInServiceInstances and any alarm on it is decoration.
  metrics_granularity = "1Minute"
  enabled_metrics = [
    "GroupInServiceInstances", "GroupDesiredCapacity",
    "GroupTotalInstances", "GroupPendingInstances",
  ]

  # Backstop: if the manager dies holding scale-in-protected workers they would
  # otherwise bill forever. AWS retires them at this age regardless.
  max_instance_lifetime = var.worker_max_lifetime_seconds > 0 ? var.worker_max_lifetime_seconds : null

  mixed_instances_policy {
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.worker[0].id
        version            = aws_launch_template.worker[0].latest_version
      }

      # More types across more families = more Spot pools = fewer interruptions.
      dynamic "override" {
        for_each = var.worker_instance_types
        content {
          instance_type = override.value
        }
      }
    }

    instances_distribution {
      on_demand_allocation_strategy            = "prioritized"
      on_demand_base_capacity                  = var.spot_enabled ? var.on_demand_base_capacity : 0
      on_demand_percentage_above_base_capacity = var.spot_enabled ? var.on_demand_percentage_above_base : 100
      spot_allocation_strategy                 = var.spot_allocation_strategy
    }
  }

  dynamic "tag" {
    for_each = merge(local.common_tags, { Name = "${var.name}-worker" })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    # The runner manager scales this at runtime; Terraform must not fight it.
    ignore_changes = [desired_capacity]

    precondition {
      condition     = var.max_instances >= var.on_demand_base_capacity
      error_message = "on_demand_base_capacity (${var.on_demand_base_capacity}) can't exceed max_instances (${var.max_instances})."
    }
  }
}
