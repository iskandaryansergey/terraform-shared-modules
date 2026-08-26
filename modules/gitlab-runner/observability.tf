# Without this you learn CI is broken from a developer, not a page.
#
# The signal design matters more than the alarm count. A one-shot "bootstrap
# succeeded" metric can't tell "healthy" apart from "instance gone", so the
# manager publishes RunnerHealthy every 60s via a systemd timer and only reports
# BootstrapFailure when a boot actually fails. Alarms watch those, plus the ASG
# group metrics (which are explicitly enabled on both ASGs - they're opt-in, and
# an alarm on an unpublished metric is decoration).

resource "aws_cloudwatch_log_group" "manager" {
  count = local.create && var.log_retention_days > 0 ? 1 : 0

  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn != "" ? var.kms_key_arn : null
  tags              = local.common_tags
}

# The primary health signal: is gitlab-runner actually running? Missing data is
# breaching on purpose - no heartbeat means no manager, which means no CI.
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

# Bootstrap failure is a discrete event, so missing data here is the normal,
# healthy state - hence notBreaching.
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

# Belt to the heartbeat's braces: the ASG itself reporting no in-service manager.
resource "aws_cloudwatch_metric_alarm" "manager_absent" {
  count = local.create && var.create_alarms && var.manager_self_heal ? 1 : 0

  alarm_name        = "${var.name}-runner-manager-absent"
  alarm_description = "The ${var.name} manager ASG has no in-service instance."

  namespace   = "AWS/AutoScaling"
  metric_name = "GroupInServiceInstances"
  dimensions  = { AutoScalingGroupName = aws_autoscaling_group.manager[0].name }

  # Maximum, not Minimum: an instance refresh legitimately drops in-service to 0
  # for a few minutes. We want "was there EVER a manager in this window".
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

# Sustained pin at the ceiling: either a genuine capacity shortfall or a runaway
# pipeline. One is a throughput problem, the other is a bill.
resource "aws_cloudwatch_metric_alarm" "fleet_at_capacity" {
  count = local.create && var.create_alarms ? 1 : 0

  alarm_name        = "${var.name}-runner-fleet-at-capacity"
  alarm_description = "Worker fleet has been pinned at max_instances (${var.max_instances}) for 15 minutes - jobs are queueing, or something is scaling out of control."

  namespace  = "AWS/AutoScaling"
  dimensions = { AutoScalingGroupName = aws_autoscaling_group.workers[0].name }

  # Desired, not in-service: with max_use_count = 1 the fleet churns constantly,
  # so in-service dips below any ceiling-based threshold every minute while
  # DESIRED stays pinned - which is the condition we actually care about.
  # Threshold at max on small fleets and 90% above that, so a 1- or 2-instance
  # fleet doesn't sit permanently in alarm.
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

# The most common real stall: the manager asked for capacity and AWS won't give
# it (Spot exhaustion, subnet IPs gone, instance type unavailable). Pending
# instances are the DIRECT signal for that - no metric math, no two-series
# statistic mismatch, and it behaves the same on a 2-instance fleet as a 200-one.
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

# FINDING: the orphan condition. If the manager is gone but workers are still
# in service, those workers are scale-in protected with nothing to release them -
# they bill indefinitely and max_instance_lifetime cannot reclaim them.
#
# Expressed as metric math so it is a single alarm: workers present AND no
# heartbeat. `FILL(healthy, 0)` turns "no heartbeat datapoint" into 0 rather than
# a gap, which is what makes the product evaluate at all.
resource "aws_cloudwatch_metric_alarm" "orphaned_workers" {
  count = local.create && var.create_alarms ? 1 : 0

  alarm_name        = "${var.name}-runner-orphaned-workers"
  alarm_description = "Workers are running in ${var.name} but no manager is reporting healthy. These instances are scale-in protected and will bill indefinitely until protection is cleared - see the runbook in the module README."

  metric_query {
    id          = "orphans"
    expression  = "IF(FILL(healthy, 0) < 1, workers, 0)"
    label       = "Workers with no live manager"
    return_data = true
  }

  metric_query {
    id = "workers"
    metric {
      namespace   = "AWS/AutoScaling"
      metric_name = "GroupInServiceInstances"
      dimensions  = { AutoScalingGroupName = aws_autoscaling_group.workers[0].name }
      period      = 300
      stat        = "Maximum"
    }
  }

  metric_query {
    id = "healthy"
    metric {
      namespace   = local.alarm_namespace
      metric_name = "RunnerHealthy"
      dimensions  = { Fleet = var.name }
      period      = 300
      stat        = "Maximum"
    }
  }

  # Three windows: long enough to ride out a manager replacement, short enough
  # that an orphaned fleet doesn't bill all night.
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns
  tags          = local.common_tags
}
