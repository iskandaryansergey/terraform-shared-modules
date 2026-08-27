# The manager publishes RunnerHealthy every 60s from a systemd timer, and
# BootstrapFailure only when a boot fails. ASG group metrics are enabled
# explicitly on both ASGs because they're opt-in and three alarms below read
# them.

resource "aws_cloudwatch_log_group" "manager" {
  count = local.create && var.log_retention_days > 0 ? 1 : 0

  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn != "" ? var.kms_key_arn : null
  tags              = local.common_tags
}

# Primary health signal. Missing data breaches: no heartbeat means no manager.
resource "aws_cloudwatch_metric_alarm" "runner_unhealthy" {
  count = local.create && var.create_alarms ? 1 : 0

  alarm_name        = "${var.name}-runner-unhealthy"
  alarm_description = "gitlab-runner is not running on the ${var.name} manager (or the manager is gone). CI job pickup has stopped."

  namespace   = local.alarm_namespace
  metric_name = "RunnerHealthy"
  dimensions  = { Fleet = var.name }

  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns
  tags          = local.common_tags
}

# Discrete event, so no data is the healthy state.
resource "aws_cloudwatch_metric_alarm" "bootstrap_failed" {
  count = local.create && var.create_alarms ? 1 : 0

  alarm_name        = "${var.name}-runner-bootstrap-failed"
  alarm_description = "A ${var.name} manager failed to bootstrap. The instance may be running but unconfigured - check /var/log/runner-bootstrap.log${var.log_retention_days > 0 ? " in ${local.log_group_name}" : " on the instance (log shipping is disabled)"}."

  namespace   = local.alarm_namespace
  metric_name = "BootstrapFailure"
  dimensions  = { Fleet = var.name }

  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_sns_topic_arns
  tags          = local.common_tags
}

# Second opinion on the heartbeat: the ASG reporting no in-service manager.
resource "aws_cloudwatch_metric_alarm" "manager_absent" {
  count = local.create && var.create_alarms && var.manager_self_heal ? 1 : 0

  alarm_name        = "${var.name}-runner-manager-absent"
  alarm_description = "The ${var.name} manager ASG has no in-service instance."

  namespace   = "AWS/AutoScaling"
  metric_name = "GroupInServiceInstances"
  dimensions  = { AutoScalingGroupName = aws_autoscaling_group.manager[0].name }

  # Maximum, not Minimum: an instance refresh drops in-service to 0 for a few
  # minutes. The question is whether there was ever a manager in the window.
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns
  tags          = local.common_tags
}

# Pinned at the ceiling: either jobs are queueing or something is scaling out of
# control.
resource "aws_cloudwatch_metric_alarm" "fleet_at_capacity" {
  count = local.create && var.create_alarms ? 1 : 0

  alarm_name        = "${var.name}-runner-fleet-at-capacity"
  alarm_description = "Worker fleet has been pinned at max_instances (${var.max_instances}) for 15 minutes - jobs are queueing, or something is scaling out of control."

  namespace  = "AWS/AutoScaling"
  dimensions = { AutoScalingGroupName = aws_autoscaling_group.workers[0].name }

  # Desired, not in-service. With max_use_count = 1 the fleet churns constantly
  # so in-service dips every minute, while desired stays pinned.
  # Threshold sits at max on small fleets so a 1-2 instance fleet isn't
  # permanently in alarm.
  metric_name         = "GroupDesiredCapacity"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.max_instances <= 3 ? var.max_instances : var.max_instances * 0.9
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_sns_topic_arns
  tags          = local.common_tags
}

# AWS won't give us capacity: Spot exhaustion, subnet IPs gone, instance type
# unavailable. Pending instances is the direct signal and behaves the same at any
# fleet size.
resource "aws_cloudwatch_metric_alarm" "capacity_shortfall" {
  count = local.create && var.create_alarms ? 1 : 0

  alarm_name        = "${var.name}-runner-capacity-shortfall"
  alarm_description = "The ${var.name} worker ASG has had instances stuck pending for 15 minutes - Spot capacity exhaustion, subnet IP exhaustion, or an unavailable instance type. Jobs are queueing."

  namespace   = "AWS/AutoScaling"
  metric_name = "GroupPendingInstances"
  dimensions  = { AutoScalingGroupName = aws_autoscaling_group.workers[0].name }

  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_sns_topic_arns
  tags          = local.common_tags
}

# Workers running with no live manager. They're scale-in protected with nothing
# left to release them, so they bill until someone intervenes.
#
# Composite rather than metric math: IF(FILL(healthy,0) < 1, workers, 0) clears
# itself once RunnerHealthy stops producing datapoints, which is exactly when the
# fleet has been orphaned longest. A composite has no fill semantics.
resource "aws_cloudwatch_metric_alarm" "workers_present" {
  count = local.create && var.create_alarms ? 1 : 0

  alarm_name        = "${var.name}-runner-workers-present"
  alarm_description = "Informational: the ${var.name} worker fleet is non-empty. Used only as an input to the orphaned-workers composite alarm."

  namespace   = "AWS/AutoScaling"
  metric_name = "GroupInServiceInstances"
  dimensions  = { AutoScalingGroupName = aws_autoscaling_group.workers[0].name }

  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  # No actions: input to the composite alarm below, not a page on its own.
  tags = local.common_tags
}

resource "aws_cloudwatch_composite_alarm" "orphaned_workers" {
  count = local.create && var.create_alarms ? 1 : 0

  alarm_name        = "${var.name}-runner-orphaned-workers"
  alarm_description = "Workers are running in ${var.name} while no manager is reporting healthy. They are scale-in protected and will bill indefinitely until protection is cleared - see the orphaned-workers runbook in the module README."

  alarm_rule = join(" AND ", [
    "ALARM(${aws_cloudwatch_metric_alarm.workers_present[0].alarm_name})",
    "ALARM(${aws_cloudwatch_metric_alarm.runner_unhealthy[0].alarm_name})",
  ])

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns
  tags          = local.common_tags
}
