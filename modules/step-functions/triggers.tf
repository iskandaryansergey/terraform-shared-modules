# What starts executions: EventBridge Scheduler schedules and EventBridge
# rules, each with its own role, each allowed to start only this state
# machine (or the alias it names).

resource "aws_scheduler_schedule" "this" {
  for_each = local.create ? var.schedules : {}

  name                         = "${var.name}-${each.key}"
  group_name                   = "default"
  description                  = each.value.description
  schedule_expression          = each.value.expression
  schedule_expression_timezone = each.value.timezone
  state                        = each.value.enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode                      = each.value.flexible_window_minutes > 0 ? "FLEXIBLE" : "OFF"
    maximum_window_in_minutes = each.value.flexible_window_minutes > 0 ? each.value.flexible_window_minutes : null
  }

  target {
    arn      = each.value.alias != "" ? try(aws_sfn_alias.this[each.value.alias].arn, aws_sfn_state_machine.this[0].arn) : aws_sfn_state_machine.this[0].arn
    role_arn = aws_iam_role.scheduler[0].arn
    input    = each.value.input

    retry_policy {
      maximum_retry_attempts       = each.value.maximum_retry_attempts
      maximum_event_age_in_seconds = each.value.maximum_event_age_in_seconds
    }

    dynamic "dead_letter_config" {
      for_each = each.value.dead_letter_arn != "" ? [1] : []
      content {
        arn = each.value.dead_letter_arn
      }
    }
  }

  depends_on = [aws_iam_role_policy.scheduler]
}

resource "aws_cloudwatch_event_rule" "this" {
  for_each = local.create ? var.event_rules : {}

  name           = "${var.name}-${each.key}"
  description    = each.value.description
  event_bus_name = each.value.event_bus_name
  event_pattern  = each.value.event_pattern
  state          = each.value.enabled ? "ENABLED" : "DISABLED"

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "this" {
  for_each = local.create ? var.event_rules : {}

  rule           = aws_cloudwatch_event_rule.this[each.key].name
  event_bus_name = each.value.event_bus_name
  target_id      = "state-machine"
  arn            = each.value.alias != "" ? try(aws_sfn_alias.this[each.value.alias].arn, aws_sfn_state_machine.this[0].arn) : aws_sfn_state_machine.this[0].arn
  role_arn       = aws_iam_role.events[0].arn
  input_path     = each.value.input_path != "" ? each.value.input_path : null

  dynamic "input_transformer" {
    for_each = each.value.input_template != "" ? [1] : []
    content {
      input_paths    = each.value.input_paths
      input_template = each.value.input_template
    }
  }

  retry_policy {
    maximum_retry_attempts       = each.value.maximum_retry_attempts
    maximum_event_age_in_seconds = each.value.maximum_event_age_in_seconds
  }

  dynamic "dead_letter_config" {
    for_each = each.value.dead_letter_arn != "" ? [1] : []
    content {
      arn = each.value.dead_letter_arn
    }
  }

  depends_on = [aws_iam_role_policy.events]
}
