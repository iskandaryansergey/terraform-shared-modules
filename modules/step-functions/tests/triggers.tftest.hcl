# Schedules and EventBridge rules that start executions. Plan runs, mocked AWS.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  # The module reads the region from endpoint: v6 deprecates name and v5 has
  # no region attribute.
  mock_data "aws_region" {
    defaults = { endpoint = "ec2.eu-west-2.amazonaws.com" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/orders-eu-west-2-sfn" }
  }
  mock_resource "aws_sfn_state_machine" {
    defaults = {
      arn                       = "arn:aws:states:eu-west-2:111122223333:stateMachine:orders"
      state_machine_version_arn = "arn:aws:states:eu-west-2:111122223333:stateMachine:orders:4"
    }
  }
}

variables {
  name       = "orders"
  definition = file("tests/fixtures/orders.asl.json")
  integrations = {
    lambda_functions = ["arn:aws:lambda:eu-west-2:111122223333:function:reserve"]
    sqs_queues       = ["arn:aws:sqs:eu-west-2:111122223333:orders"]
  }
  alarms = { enabled = true, sns_topic_arn = "arn:aws:sns:eu-west-2:111122223333:alerts" }
  dlq    = "arn:aws:sqs:eu-west-2:111122223333:orders-starts-dlq"
}

run "a_schedule_starts_executions_through_a_scoped_role" {
  command = plan

  variables {
    schedules = { nightly = { expression = "cron(0 2 * * ? *)", timezone = "Europe/London", input = "{\"mode\":\"reconcile\"}", dead_letter_arn = var.dlq } }
  }

  assert {
    condition = alltrue([
      aws_scheduler_schedule.this["nightly"].name == "orders-nightly",
      aws_scheduler_schedule.this["nightly"].target[0].input == "{\"mode\":\"reconcile\"}",
      jsondecode(aws_iam_role.scheduler[0].assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceArn"] == "arn:aws:scheduler:eu-west-2:111122223333:schedule-group/default",
      jsonencode(jsondecode(aws_iam_role_policy.scheduler[0].policy).Statement[0].Resource) == jsonencode(["arn:aws:states:eu-west-2:111122223333:stateMachine:orders"]),
      jsonencode(jsondecode(aws_iam_role_policy.scheduler[0].policy).Statement[0].Action) == jsonencode(["states:StartExecution"]),
      !can(jsondecode(aws_iam_role_policy.scheduler[0].policy).Statement[0].Condition),
    ])
    error_message = "the schedule starts this state machine only, with its input, through a role trusted by this account's schedule group."
  }
}

run "an_event_rule_starts_executions_through_a_role_scoped_to_the_rule" {
  command = plan

  variables {
    event_rules = {
      uploaded = {
        event_pattern   = jsonencode({ source = ["aws.s3"], "detail-type" = ["Object Created"] })
        input_path      = "$.detail"
        dead_letter_arn = var.dlq
      }
      partner = {
        event_pattern   = jsonencode({ source = ["partner.orders"] })
        event_bus_name  = "partners"
        input_paths     = { id = "$.detail.id" }
        input_template  = "{\"orderId\": <id>}"
        dead_letter_arn = var.dlq
      }
    }
  }

  assert {
    condition = alltrue([
      aws_cloudwatch_event_rule.this["uploaded"].name == "orders-uploaded",
      aws_cloudwatch_event_target.this["uploaded"].input_path == "$.detail",
      aws_cloudwatch_event_target.this["partner"].event_bus_name == "partners",
      aws_cloudwatch_event_target.this["partner"].input_transformer[0].input_template == "{\"orderId\": <id>}",
      aws_cloudwatch_event_target.this["uploaded"].dead_letter_config[0].arn == var.dlq,
    ])
    error_message = "each rule matches its pattern on its bus and shapes the input as given."
  }

  assert {
    condition = alltrue([
      jsondecode(aws_iam_role.events[0].assume_role_policy).Statement[0].Principal.Service == "events.amazonaws.com",
      toset(jsondecode(aws_iam_role.events[0].assume_role_policy).Statement[0].Condition.ArnLike["aws:SourceArn"]) == toset([
        "arn:aws:events:eu-west-2:111122223333:rule/orders-uploaded",
        "arn:aws:events:eu-west-2:111122223333:rule/partners/orders-partner",
      ]),
      jsondecode(aws_iam_role.events[0].assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "111122223333",
    ])
    error_message = "the EventBridge role is trusted for these rules only - a custom bus's rule ARN includes the bus."
  }
}

run "triggers_on_an_alias_start_executions_there" {
  command = plan

  variables {
    publish     = true
    aliases     = { live = {} }
    event_rules = { uploaded = { event_pattern = jsonencode({ source = ["aws.s3"] }), alias = "live", dead_letter_arn = var.dlq } }
  }

  # Step Functions authorises a start on an alias against the unqualified
  # ARN; a grant on the alias ARN would never match.
  assert {
    condition = alltrue([
      jsonencode(jsondecode(aws_iam_role_policy.events[0].policy).Statement[0].Resource) == jsonencode(["arn:aws:states:eu-west-2:111122223333:stateMachine:orders"]),
      jsonencode(jsondecode(aws_iam_role_policy.events[0].policy).Statement[0].Condition["ForAnyValue:StringEquals"]["states:StateMachineQualifier"]) == jsonencode(["live"]),
    ])
    error_message = "a rule on an alias may start executions on the unqualified ARN, held to that alias by states:StateMachineQualifier."
  }
}

run "a_trigger_on_an_undeclared_alias_is_refused" {
  command = plan

  variables {
    schedules = { nightly = { expression = "rate(1 day)", alias = "live", dead_letter_arn = var.dlq } }
  }

  expect_failures = [aws_sfn_state_machine.this]
}

run "a_trigger_without_a_dead_letter_queue_warns" {
  command = plan

  variables {
    schedules = { nightly = { expression = "rate(1 day)" } }
  }

  expect_failures = [check.event_deliveries_are_kept]
}

run "a_bus_given_as_an_arn_is_rejected" {
  command = plan

  variables {
    event_rules = { partner = { event_pattern = "{}", event_bus_name = "arn:aws:events:eu-west-2:111122223333:event-bus/partners" } }
  }

  expect_failures = [var.event_rules]
}

run "input_path_with_a_template_is_rejected" {
  command = plan

  variables {
    event_rules = { partner = { event_pattern = "{}", input_path = "$.detail", input_template = "{}" } }
  }

  expect_failures = [var.event_rules]
}
