# Alarms on dimension StateMachineArn. Missing data is not breaching: a
# workflow that is not started is healthy. Keyed on inputs only.

locals {
  create_alarms = local.create && var.alarms.enabled

  alarm_definitions = merge(
    {
      executions_failed    = { metric = "ExecutionsFailed", statistic = "Sum", threshold = 1, description = "${var.name}: an execution failed." }
      executions_timed_out = { metric = "ExecutionsTimedOut", statistic = "Sum", threshold = 1, description = "${var.name}: an execution timed out." }
      executions_aborted   = { metric = "ExecutionsAborted", statistic = "Sum", threshold = 1, description = "${var.name}: an execution was aborted (stopped by a caller or a parent)." }
      execution_throttled  = { metric = "ExecutionThrottled", statistic = "Sum", threshold = 1, description = "${var.name}: state transitions or retries were throttled." }
    },
    var.alarms.execution_time_threshold_seconds == 0 ? {} : {
      execution_time = {
        metric      = "ExecutionTime"
        statistic   = "Maximum"
        threshold   = var.alarms.execution_time_threshold_seconds * 1000
        description = "${var.name}: an execution ran longer than ${var.alarms.execution_time_threshold_seconds} s."
      }
    },
  )
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.create_alarms ? local.alarm_definitions : {}

  alarm_name          = "${var.name}-${replace(each.key, "_", "-")}"
  alarm_description   = each.value.description
  namespace           = "AWS/States"
  metric_name         = each.value.metric
  statistic           = each.value.statistic
  dimensions          = { StateMachineArn = local.state_machine_arn }
  period              = var.alarms.period_seconds
  evaluation_periods  = 1
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarms.sns_topic_arn]
  ok_actions          = [var.alarms.sns_topic_arn]

  tags = local.common_tags
}
