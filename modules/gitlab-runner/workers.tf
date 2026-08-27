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

  # The ASG's mixed-instances overrides pick the type, which is
  # what gives Spot a wide pool.

  # The fleet needs no inbound access, and this runs untrusted CI code.
  network_interfaces {
    associate_public_ip_address = var.assign_public_ips
    security_groups             = var.worker_security_group_ids
    delete_on_termination       = true
  }

  # Otherwise a privileged job can `shutdown` and leave a stopped instance that
  # still bills and still holds a slot.
  instance_initiated_shutdown_behavior = "terminate"

  iam_instance_profile {
    arn = aws_iam_instance_profile.worker[0].arn
  }

  # IMDSv2 only. Hop limit 1 also stops job containers reaching metadata.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = var.imds_hop_limit
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = local.worker_root_device_resolved
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

    precondition {
      # A missing rule fails as a hung job rather than an error, so catch it at
      # plan time. See network-byo.tf.
      condition = !var.verify_manager_to_worker_ssh_rule || local.manager_to_worker_ssh_rule_exists
      error_message = join("", [
        "No rule permits TCP 22 from any manager security group to any worker security group. ",
        "The fleeting plugin reaches each worker over SSH with an ephemeral EC2 Instance Connect key; ",
        "without this rule it pushes a key, cannot connect, and every job hangs until the retry budget expires. ",
        "Create an ingress rule on a worker security group referencing a manager security group. ",
        local.worker_ingress_via_prefix_list
        ? "NOTE: a worker security group has a PREFIX-LIST rule, which this check cannot resolve - if that is how you grant it, set verify_manager_to_worker_ssh_rule = false."
        : "",
      ])
    }
  }
}

# No scaling policies and no target tracking: the runner manager owns
# desired_capacity and AWS must not second-guess it.
resource "aws_autoscaling_group" "workers" {
  count = local.create ? 1 : 0

  name                = local.worker_asg_name
  vpc_zone_identifier = var.worker_subnet_ids

  # Scale to zero when nothing is queued.
  min_size         = 0
  max_size         = var.max_instances
  desired_capacity = 0

  # The plugin clears protection per instance when it retires a worker.
  protect_from_scale_in = true
  capacity_rebalance    = var.capacity_rebalance

  # Protected instances block ASG deletion, so destroy wedges mid-job.
  force_delete = var.force_delete_workers

  # AZRebalance kills busy workers to even out AZs.
  suspended_processes = ["AZRebalance"]

  health_check_type         = "EC2"
  health_check_grace_period = 60
  default_instance_warmup   = 30

  # Opt-in. Without them GroupInServiceInstances is never published and three
  # alarms read nothing.
  metrics_granularity = "1Minute"
  enabled_metrics = [
    "GroupInServiceInstances", "GroupDesiredCapacity",
    "GroupTotalInstances", "GroupPendingInstances",
  ]

  # Note this does NOT reclaim orphaned workers: ASG-initiated replacement
  # respects scale-in protection, and every worker here is protected.
  max_instance_lifetime = var.worker_max_lifetime_seconds > 0 ? var.worker_max_lifetime_seconds : null

  mixed_instances_policy {
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.worker[0].id
        version            = aws_launch_template.worker[0].latest_version
      }

      # More families means more Spot pools and fewer interruptions.
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
    # The manager scales this at runtime.
    ignore_changes = [desired_capacity]

    precondition {
      condition     = var.max_instances >= var.on_demand_base_capacity
      error_message = "on_demand_base_capacity (${var.on_demand_base_capacity}) can't exceed max_instances (${var.max_instances})."
    }
  }
}
