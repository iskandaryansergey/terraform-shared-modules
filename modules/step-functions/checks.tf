# Warnings, not refusals: postures the module allows but a reviewer should see
# in the plan and in every HCP Terraform health assessment. Each is silent
# under create = false and once named in var.acknowledged_checks.

locals {
  ack_hint = "Acknowledge it with acknowledged_checks if this is intended."

  rules_without_dead_letter = concat(
    [for k, r in var.event_rules : "event rule ${k}" if r.dead_letter_arn == ""],
    [for k, s in var.schedules : "schedule ${k}" if s.dead_letter_arn == ""],
  )
}

check "failures_reach_someone" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "failures_reach_someone") ? true : var.alarms.enabled)
    error_message = "alarms.enabled is false: failed, timed-out and throttled executions tell nobody. ${local.ack_hint}"
  }
}

# Express executions keep no history in Step Functions: the logs are the only
# record that one ran, and of why it failed.
check "express_executions_leave_a_record" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "express_executions_leave_a_record") ? true : (!local.is_express ? true : contains(["ALL", "ERROR"], var.logging.level)))
    error_message = "an EXPRESS state machine with logging.level ${var.logging.level} leaves no record of its executions${var.logging.level == "FATAL" ? " beyond fatal ones" : ""}: Step Functions keeps no history for Express. Use ERROR or ALL. ${local.ack_hint}"
  }
}

check "log_retention_is_bounded" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "log_retention_is_bounded") ? true : (local.create_log_group ? var.logging.retention_days != 0 : true))
    error_message = "logging.retention_days = 0 keeps every log line forever; the log group is the cost that grows without bound. ${local.ack_hint}"
  }
}

check "execution_data_is_logged_deliberately" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "execution_data_is_logged_deliberately") ? true : !var.logging.include_execution_data)
    error_message = "logging.include_execution_data writes every state's input and output to CloudWatch Logs, where anyone with log access reads them, outside the state machine's key. ${local.ack_hint}"
  }
}

# templatefile() leaves ${...} alone only when it is escaped; one that reaches
# the definition is an unrendered placeholder, which AWS accepts as text.
check "the_definition_is_rendered" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "the_definition_is_rendered") ? true : !strcontains(var.definition, "$${"))
    error_message = "the definition contains \"$${\": a template placeholder that was not rendered. Pass it through templatefile() with every variable set. ${local.ack_hint}"
  }
}

check "every_arn_in_the_definition_is_granted" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "every_arn_in_the_definition_is_granted") ? true : (length(local.ungranted_definition_arns) == 0 && (local.uses_distributed_map ? var.distributed_map : true)))
    error_message = "the definition calls resources the role is not granted: ${join(", ", concat(local.ungranted_definition_arns, local.uses_distributed_map && !var.distributed_map ? ["a Distributed Map (set distributed_map = true)"] : []))}. Add them to integrations or role.statements, or the state fails at runtime with AccessDenied. ${local.ack_hint}"
  }
}

check "event_deliveries_are_kept" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "event_deliveries_are_kept") ? true : length(local.rules_without_dead_letter) == 0)
    error_message = "${join(", ", local.rules_without_dead_letter)} have no dead_letter_arn: an execution that cannot be started after the retries is dropped with no record. ${local.ack_hint}"
  }
}
