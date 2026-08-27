# Two rules govern this file.
#
# R4: a signal must mean what it claims. The sibling module's primary health
# metric was `systemctl is-active gitlab-runner`, which stays green through a
# revoked token, an unreachable GitLab, and a driver that cannot resolve a
# region - so it reported seven healthy alarms while launching zero workers.
#
# R5: never ship a control that cannot work. Every alarm below watches a metric
# that something actually publishes. Where no publisher exists - see the job
# pickup note at the bottom - there is a documented gap and a recipe, not an
# alarm on a metric that will never report.
#
# That is why failures and Spot interruptions are EventBridge rules rather than
# CloudWatch alarms: those are discrete events that ECS emits itself. Wrapping
# them in a custom metric would need a publisher this module does not run, and an
# alarm on an unpublished metric is decoration.

resource "aws_cloudwatch_log_group" "this" {
  count = local.create ? 1 : 0

  name = local.log_group_name
  # 0 means "never expire" to the provider, so ONE resource covers both cases.
  # This was previously two resources with the SAME name selected by a count
  # ternary: toggling retention across 0 made Terraform create one and destroy the
  # other with no dependency edge between them, which races into
  # ResourceAlreadyExists and destroys the CI log history either way.
  retention_in_days = var.log_retention_days > 0 ? var.log_retention_days : 0
  kms_key_id        = var.log_kms_key_arn != "" ? var.log_kms_key_arn : null
  tags              = local.common_tags
}

# ---------------------------------------------------------------------------
# The primary signal: is there a manager at all?
#
# Continuous, so missing data is breaching - no datapoints means no service,
# which means no CI. Contrast with the discrete alarms below.
#
# This is genuinely outcome-bearing on this platform, unlike a process check:
# the manager container's health check polls the runner's own metrics endpoint on
# :9252, so a runner whose HTTP stack has stopped serving fails the check, ECS
# replaces the task, and RunningTaskCount dips. A process that is up but wedged
# does not stay counted.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "manager_absent" {
  count = local.create && var.create_alarms ? 1 : 0

  alarm_name        = "${var.name}-runner-manager-absent"
  alarm_description = "The ${var.name} runner manager has no running task. Job pickup has stopped. Check the manager log stream in ${local.log_group_name} and the service's stopped-task reasons."

  namespace   = "ECS/ContainerInsights"
  metric_name = "RunningTaskCount"
  dimensions = {
    ClusterName = local.cluster_name
    ServiceName = aws_ecs_service.manager[0].name
  }

  # Maximum, not Minimum: a deployment legitimately drops the count to 0 for a
  # minute or two (deployment_maximum_percent is 100, so the old task drains
  # before the new one starts). We want "was there EVER a manager in this
  # window", not "was there always one".
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns
  tags          = local.common_tags

  lifecycle {
    precondition {
      # ECS/ContainerInsights is opt-in. An alarm on a metric nobody publishes is
      # worse than no alarm, because it sits in INSUFFICIENT_DATA looking
      # configured. Refuse the combination rather than ship a dead control (R5).
      condition     = var.enable_container_insights
      error_message = "create_alarms = true requires enable_container_insights = true: the manager-absent alarm reads ECS/ContainerInsights RunningTaskCount, which is not published unless Container Insights is enabled. Enable it, or set create_alarms = false."
    }
  }
}

# ---------------------------------------------------------------------------
# Job task capacity: the fleet is pinned at its ceiling.
#
# Checked at every fleet size, because this is the alarm the sibling got wrong.
# Threshold is concurrent + 1 against a cluster task count that includes the
# manager, so a fully-utilised fleet is NOT in alarm - full utilisation is the
# system working. It fires only when the fleet is at its ceiling with something
# beyond it, sustained for 15 minutes.
#
# At manager_concurrent = 1 or 2 the alarm is not created at all: with so few
# slots, "at the ceiling" is close to the normal state during any single build,
# and an alarm that fires on normal operation gets muted along with everything
# else sharing its topic.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "fleet_at_capacity" {
  count = local.create && var.create_alarms && var.manager_concurrent >= 3 ? 1 : 0

  alarm_name        = "${var.name}-runner-fleet-at-capacity"
  alarm_description = "The ${var.name} fleet has been at its ${var.manager_concurrent}-task ceiling for 15 minutes, so jobs are queueing. Either raise manager_concurrent, or check the account's Fargate vCPU quota - that is usually the real ceiling."

  # TaskCount, not RunningTaskCount. AWS publishes RunningTaskCount ONLY with the
  # dimension pair {ClusterName, ServiceName} - there is no ClusterName-only
  # variant - so the previous alarm read a series nobody emits and could not fire
  # at ANY fleet size. TaskCount{ClusterName} is the cluster-wide task count.
  namespace   = "ECS/ContainerInsights"
  metric_name = "TaskCount"
  dimensions  = { ClusterName = local.cluster_name }

  # Cluster tasks = job tasks + the one manager, so "every job slot busy" is
  # concurrent + 1. Threshold concurrent + 1 with GreaterThanThreshold therefore
  # fires only BEYOND full utilisation. The previous threshold of `concurrent`
  # fired at exactly full utilisation - the behaviour its own comment and the
  # README both claimed it avoided.
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.manager_concurrent + 1
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_sns_topic_arns
  tags          = local.common_tags
}

# ---------------------------------------------------------------------------
# Discrete events, routed straight from ECS.
#
# EventBridge rather than metrics because ECS already emits these and the event
# payload carries the diagnosis - stoppedReason names CannotPullContainerError,
# ResourceInitializationError, SpotInterruption and so on. A count would tell you
# something failed; the event tells you why.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "job_task_failed" {
  count = local.create && length(var.alarm_sns_topic_arns) > 0 ? 1 : 0

  name        = "${var.name}-runner-job-task-failed"
  description = "Job task stopped without completing cleanly in the ${var.name} fleet"

  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Task State Change"]
    detail = {
      clusterArn    = [aws_ecs_cluster.this[0].arn]
      lastStatus    = ["STOPPED"]
      stoppedReason = [{ anything-but = { prefix = "Task stopped by user" } }]
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "job_task_failed" {
  for_each = local.create && length(var.alarm_sns_topic_arns) > 0 ? toset(var.alarm_sns_topic_arns) : toset([])

  rule      = aws_cloudwatch_event_rule.job_task_failed[0].name
  target_id = "sns-${substr(sha256(each.value), 0, 12)}"
  arn       = each.value
}

# Spot interruption is its own rule because the response is different: nothing is
# broken, capacity was reclaimed, and the fix is `retry:` in .gitlab-ci.yml rather
# than an investigation. Only created when the fleet actually uses Spot - a rule
# that can never match is the EventBridge equivalent of a dead alarm.
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  count = local.create && local.uses_spot && length(var.alarm_sns_topic_arns) > 0 ? 1 : 0

  name        = "${var.name}-runner-spot-interruption"
  description = "Fargate Spot reclaimed a task in the ${var.name} fleet. The job died mid-run; GitLab-side retry: is the recovery."

  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Task State Change"]
    detail = {
      clusterArn = [aws_ecs_cluster.this[0].arn]
      stopCode   = ["SpotInterruption"]
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  for_each = local.create && local.uses_spot && length(var.alarm_sns_topic_arns) > 0 ? toset(var.alarm_sns_topic_arns) : toset([])

  rule      = aws_cloudwatch_event_rule.spot_interruption[0].name
  target_id = "sns-${substr(sha256(each.value), 0, 12)}"
  arn       = each.value
}

# ---------------------------------------------------------------------------
# The gap, stated rather than papered over (R6).
#
# None of the above proves that jobs are being PICKED UP. A revoked or rotated
# runner token, a GitLab-side 401, or an API throttle leaves the manager task
# running and serving /metrics, so manager_absent stays OK and no task ever
# stops - there is no failure event to route.
#
# gitlab-runner already exports the right signals on :9252
# (gitlab_runner_jobs, gitlab_runner_concurrent, gitlab_runner_errors_total), and
# this module configures that endpoint. Turning them into CloudWatch metrics
# needs something to scrape them, which means either a CloudWatch-agent sidecar
# with a prometheus source, or the runner's own EMF output. Both are real work
# and neither belongs behind an unconditional default.
#
# Rather than ship an alarm that cannot fire, the module exposes the endpoint and
# documents the recipe in README.md under "The job-pickup gap". If you run CI you
# care about, close it.
# ---------------------------------------------------------------------------
