# The state machine, its role, logging, encryption, versions and contracts.
# Plan runs against a mocked AWS provider: it does not call
# ValidateStateMachineDefinition, so ASL errors are AWS's to find, not these
# tests'. mock_provider also does not report replacements.

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

# Configured so that no advisory check fires: terraform test fails a run on
# any check it does not expect.
variables {
  name       = "orders"
  definition = file("tests/fixtures/orders.asl.json")
  integrations = {
    lambda_functions = ["arn:aws:lambda:eu-west-2:111122223333:function:reserve"]
    sqs_queues       = ["arn:aws:sqs:eu-west-2:111122223333:orders"]
  }
  alarms = { enabled = true, sns_topic_arn = "arn:aws:sns:eu-west-2:111122223333:alerts" }
  tags   = { CostCentre = "cc-1234" }

  every_check = [
    "failures_reach_someone", "express_executions_leave_a_record", "log_retention_is_bounded",
    "execution_data_is_logged_deliberately", "the_definition_is_rendered", "every_arn_in_the_definition_is_granted",
    "event_deliveries_are_kept",
  ]
}

run "the_defaults_are_a_logged_standard_workflow" {
  command = plan

  assert {
    condition = alltrue([
      aws_sfn_state_machine.this[0].name == "orders",
      aws_sfn_state_machine.this[0].type == "STANDARD",
      aws_sfn_state_machine.this[0].publish == false,
      aws_sfn_state_machine.this[0].logging_configuration[0].level == "ERROR",
      aws_sfn_state_machine.this[0].logging_configuration[0].include_execution_data == false,
      aws_sfn_state_machine.this[0].logging_configuration[0].log_destination == "arn:aws:logs:eu-west-2:111122223333:log-group:/aws/vendedlogs/states/orders:*",
      aws_cloudwatch_log_group.this[0].name == "/aws/vendedlogs/states/orders",
      aws_cloudwatch_log_group.this[0].retention_in_days == 30,
      aws_sfn_state_machine.this[0].encryption_configuration[0].type == "AWS_OWNED_KEY",
      aws_sfn_state_machine.this[0].encryption_configuration[0].kms_key_id == null,
    ])
    error_message = "a STANDARD workflow logging errors (no execution data) to a vendedlogs group kept 30 days, on an explicit AWS-owned key - so removing a customer key switches back."
  }

  assert {
    condition     = jsonencode(aws_sfn_state_machine.this[0].tags) == jsonencode({ CostCentre = "cc-1234", ManagedBy = "Terraform", Module = "step-functions", StateMachine = "orders" })
    error_message = "caller tags plus the module's, merged last."
  }
}

# ---------------------------------------------------------------------------
# Role
# ---------------------------------------------------------------------------

run "the_role_is_trusted_by_this_accounts_state_machines_only" {
  command = plan

  assert {
    condition = alltrue([
      aws_iam_role.this[0].name == "orders-eu-west-2-sfn",
      jsondecode(aws_iam_role.this[0].assume_role_policy).Statement[0].Principal.Service == "states.amazonaws.com",
      jsondecode(aws_iam_role.this[0].assume_role_policy).Statement[0].Condition.ArnLike["aws:SourceArn"] == "arn:aws:states:eu-west-2:111122223333:stateMachine:*",
      jsondecode(aws_iam_role.this[0].assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "111122223333",
    ])
    error_message = "the trust carries the documented confused-deputy conditions."
  }
}

run "integrations_grant_exactly_their_arns" {
  command = plan

  variables {
    integrations = {
      lambda_functions      = ["arn:aws:lambda:eu-west-2:111122223333:function:reserve"]
      sqs_queues            = ["arn:aws:sqs:eu-west-2:111122223333:orders"]
      sns_topics            = ["arn:aws:sns:eu-west-2:111122223333:orders-done"]
      dynamodb_read_tables  = ["arn:aws:dynamodb:eu-west-2:111122223333:table/prices"]
      dynamodb_write_tables = ["arn:aws:dynamodb:eu-west-2:111122223333:table/orders"]
      event_buses           = ["arn:aws:events:eu-west-2:111122223333:event-bus/orders"]
      kms_key_arns          = ["arn:aws:kms:eu-west-2:111122223333:key/22222222-2222-3333-4444-555555555555"]
    }
  }

  assert {
    condition = alltrue([for st in jsondecode(aws_iam_role_policy.this[0].policy).Statement :
      st.Sid == "InvokeLambdaFunctions" ? jsonencode([st.Action, st.Resource]) == jsonencode([["lambda:InvokeFunction"], ["arn:aws:lambda:eu-west-2:111122223333:function:reserve", "arn:aws:lambda:eu-west-2:111122223333:function:reserve:*"]]) :
      st.Sid == "SendToQueues" ? jsonencode([st.Action, st.Resource]) == jsonencode([["sqs:SendMessage"], ["arn:aws:sqs:eu-west-2:111122223333:orders"]]) :
      st.Sid == "PublishToTopics" ? jsonencode([st.Action, st.Resource]) == jsonencode([["sns:Publish"], ["arn:aws:sns:eu-west-2:111122223333:orders-done"]]) :
      st.Sid == "ReadTables" ? jsonencode([st.Action, st.Resource]) == jsonencode([["dynamodb:GetItem"], ["arn:aws:dynamodb:eu-west-2:111122223333:table/prices"]]) :
      st.Sid == "WriteTables" ? jsonencode([st.Action, st.Resource]) == jsonencode([["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"], ["arn:aws:dynamodb:eu-west-2:111122223333:table/orders"]]) :
      st.Sid == "PutEvents" ? jsonencode([st.Action, st.Resource]) == jsonencode([["events:PutEvents"], ["arn:aws:events:eu-west-2:111122223333:event-bus/orders"]]) :
      st.Sid == "UseIntegrationKeys" ? jsonencode([st.Action, st.Resource]) == jsonencode([["kms:Decrypt", "kms:GenerateDataKey"], ["arn:aws:kms:eu-west-2:111122223333:key/22222222-2222-3333-4444-555555555555"]]) :
      st.Sid == "DeliverLogs"
    ])
    error_message = "each integration grants AWS's documented actions on exactly its ARNs (Lambda also on <arn>:*); nothing else is in the policy."
  }

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.this[0].policy).Statement) == 8
    error_message = "seven integration statements and log delivery."
  }

  assert {
    condition     = toset(keys(output.governance.integrations)) == toset(["lambda_functions", "sqs_queues", "sns_topics", "dynamodb_read_tables", "dynamodb_write_tables", "event_buses", "kms_key_arns"])
    error_message = "governance lists the integrations in use and no empty ones."
  }
}

run "sync_integrations_get_their_managed_rules" {
  command = plan

  variables {
    integrations = {
      lambda_functions     = ["arn:aws:lambda:eu-west-2:111122223333:function:reserve"]
      sqs_queues           = ["arn:aws:sqs:eu-west-2:111122223333:orders"]
      state_machines       = ["arn:aws:states:eu-west-2:111122223333:stateMachine:payments"]
      ecs_task_definitions = ["arn:aws:ecs:eu-west-2:111122223333:task-definition/report"]
      ecs_pass_role_arns   = ["arn:aws:iam::111122223333:role/report-task"]
      glue_job_runs        = true
    }
  }

  assert {
    condition = alltrue([
      anytrue([for st in jsondecode(aws_iam_role_policy.this[0].policy).Statement : st.Sid == "FollowChildExecutions" ? jsonencode(st.Resource) == jsonencode(["arn:aws:states:eu-west-2:111122223333:execution:payments:*"]) : false]),
      anytrue([for st in jsondecode(aws_iam_role_policy.this[0].policy).Statement : st.Sid == "ManagedRuleForChildExecutions" ? jsonencode(st.Resource) == jsonencode(["arn:aws:events:eu-west-2:111122223333:rule/StepFunctionsGetEventsForStepFunctionsExecutionRule"]) : false]),
      anytrue([for st in jsondecode(aws_iam_role_policy.this[0].policy).Statement : st.Sid == "RunEcsTasks" ? jsonencode(st.Resource) == jsonencode(["arn:aws:ecs:eu-west-2:111122223333:task-definition/report:*"]) : false]),
      anytrue([for st in jsondecode(aws_iam_role_policy.this[0].policy).Statement : st.Sid == "ManagedRuleForEcsTasks" ? jsonencode(st.Resource) == jsonencode(["arn:aws:events:eu-west-2:111122223333:rule/StepFunctionsGetEventsForECSTaskRule"]) : false]),
      anytrue([for st in jsondecode(aws_iam_role_policy.this[0].policy).Statement : st.Sid == "PassEcsTaskRoles" ? st.Condition.StringEquals["iam:PassedToService"] == ["ecs-tasks.amazonaws.com"] : false]),
      anytrue([for st in jsondecode(aws_iam_role_policy.this[0].policy).Statement : st.Sid == "RunGlueJobs" ? jsonencode(st.Resource) == jsonencode(["*"]) : false]),
    ])
    error_message = "child executions, ECS tasks and Glue jobs get the documented .sync permissions; PassRole only to ECS tasks."
  }
}

run "pass_roles_without_ecs_tasks_are_rejected" {
  command = plan

  variables {
    integrations = { ecs_pass_role_arns = ["arn:aws:iam::111122223333:role/report-task"] }
  }

  expect_failures = [var.integrations]
}

run "the_code_policy_is_rendered_from_statements" {
  command = plan

  variables {
    role = {
      statements = [{
        actions    = ["bedrock:InvokeModel"]
        resources  = ["arn:aws:bedrock:eu-west-2::foundation-model/amazon.titan-text-express-v1"]
        conditions = [{ test = "StringEquals", variable = "aws:RequestedRegion", values = ["eu-west-2"] }]
      }]
    }
  }

  assert {
    condition = alltrue([
      aws_iam_role_policy.caller[0].name == "definition-calls",
      jsondecode(aws_iam_role_policy.caller[0].policy).Statement[0].Condition.StringEquals["aws:RequestedRegion"] == ["eu-west-2"],
    ])
    error_message = "role.statements become a second policy, conditions grouped by operator."
  }
}

run "a_brought_role_gets_nothing_and_is_told_what_it_needs" {
  command = plan

  variables {
    role = { create = false, arn = "arn:aws:iam::111122223333:role/platform/orders" }
  }

  assert {
    condition = alltrue([
      length(aws_iam_role.this) == 0,
      length(aws_iam_role_policy.this) == 0,
      aws_sfn_state_machine.this[0].role_arn == "arn:aws:iam::111122223333:role/platform/orders",
      anytrue([for s in output.role_requirements : s.sid == "InvokeLambdaFunctions"]),
    ])
    error_message = "with a brought role nothing is attached and role_requirements lists the grants."
  }
}

run "a_blanket_grant_is_rejected" {
  command = plan

  variables {
    role = { statements = [{ actions = ["*"], resources = ["*"] }] }
  }

  expect_failures = [var.role]
}

# ---------------------------------------------------------------------------
# The definition
# ---------------------------------------------------------------------------

run "a_definition_without_states_is_rejected" {
  command = plan

  variables {
    definition = jsonencode({ Comment = "nothing here" })
  }

  expect_failures = [var.definition]
}

run "an_ungranted_arn_in_the_definition_warns" {
  command = plan

  variables {
    integrations = { sqs_queues = ["arn:aws:sqs:eu-west-2:111122223333:orders"] }
  }

  expect_failures = [check.every_arn_in_the_definition_is_granted]
}

# A child whose name starts with the parent's is still a different machine.
run "a_child_named_like_the_parent_is_not_exempt" {
  command = plan

  variables {
    definition = jsonencode({
      StartAt = "Child"
      States = {
        Child = {
          Type       = "Task"
          Resource   = "arn:aws:states:::states:startExecution"
          Parameters = { StateMachineArn = "arn:aws:states:eu-west-2:111122223333:stateMachine:orders-child" }
          End        = true
        }
      }
    })
  }

  expect_failures = [check.every_arn_in_the_definition_is_granted]
}

run "a_child_called_through_its_alias_is_covered_by_its_grant" {
  command = plan

  variables {
    definition = jsonencode({
      StartAt = "Child"
      States = {
        Child = {
          Type       = "Task"
          Resource   = "arn:aws:states:::states:startExecution"
          Parameters = { StateMachineArn = "arn:aws:states:eu-west-2:111122223333:stateMachine:payments:live" }
          End        = true
        }
      }
    })
    integrations = { state_machines = ["arn:aws:states:eu-west-2:111122223333:stateMachine:payments"] }
  }

  assert {
    condition     = length(output.governance.ungranted_definition_arns) == 0
    error_message = "a grant on a state machine covers its aliases and versions."
  }
}

run "a_qualified_lambda_of_a_granted_function_is_covered" {
  command = plan

  variables {
    definition = replace(file("tests/fixtures/orders.asl.json"), "function:reserve\"", "function:reserve:live\"")
  }

  assert {
    condition     = length(output.governance.ungranted_definition_arns) == 0
    error_message = "function:reserve:live is covered by the grant on function:reserve and :*."
  }
}

run "an_unrendered_placeholder_warns" {
  command = plan

  variables {
    definition = replace(file("tests/fixtures/orders.asl.json"), "Reserve, charge, notify.", "$${comment}")
  }

  expect_failures = [check.the_definition_is_rendered]
}

run "an_undeclared_distributed_map_warns" {
  command = plan

  variables {
    definition = jsonencode({
      StartAt = "Each"
      States = {
        Each = {
          Type          = "Map"
          ItemProcessor = { ProcessorConfig = { Mode = "DISTRIBUTED", ExecutionType = "EXPRESS" }, StartAt = "Done", States = { Done = { Type = "Succeed" } } }
          End           = true
        }
      }
    })
    integrations = {}
  }

  expect_failures = [check.every_arn_in_the_definition_is_granted]
}

run "a_distributed_map_may_start_and_describe_its_children" {
  command = plan

  variables {
    distributed_map = true
  }

  assert {
    condition = alltrue([
      anytrue([for st in jsondecode(aws_iam_role_policy.this[0].policy).Statement : st.Sid == "StartDistributedMapChildren" ? jsonencode(st.Resource) == jsonencode(["arn:aws:states:eu-west-2:111122223333:stateMachine:orders"]) : false]),
      anytrue([for st in jsondecode(aws_iam_role_policy.this[0].policy).Statement : st.Sid == "DescribeDistributedMapChildren" ? jsonencode(st.Resource) == jsonencode(["arn:aws:states:eu-west-2:111122223333:execution:orders:*"]) : false]),
    ])
    error_message = "the role starts its own child executions and describes them - the least privilege AWS documents."
  }
}

# ---------------------------------------------------------------------------
# Express
# ---------------------------------------------------------------------------

run "express_logs_errors_and_can_be_started_synchronously" {
  command = plan

  variables {
    type = "EXPRESS"
  }

  assert {
    condition = alltrue([
      aws_sfn_state_machine.this[0].type == "EXPRESS",
      contains(jsondecode(output.start_execution_policy_json).Statement[0].Action, "states:StartSyncExecution"),
      strcontains(output.verify_commands.start, "start-sync-execution"),
      strcontains(output.verify_commands.failed, "filter-log-events"),
    ])
    error_message = "an EXPRESS machine can be started synchronously, and its verify command does."
  }
}

run "express_with_a_sync_integration_is_refused" {
  command = plan

  variables {
    type       = "EXPRESS"
    definition = replace(file("tests/fixtures/orders.asl.json"), "arn:aws:states:::sqs:sendMessage", "arn:aws:states:::ecs:runTask.sync")
  }

  expect_failures = [aws_sfn_state_machine.this]
}

run "express_with_a_callback_is_refused" {
  command = plan

  variables {
    type       = "EXPRESS"
    definition = replace(file("tests/fixtures/orders.asl.json"), "arn:aws:states:::sqs:sendMessage", "arn:aws:states:::sqs:sendMessage.waitForTaskToken")
  }

  expect_failures = [aws_sfn_state_machine.this]
}

run "express_with_a_distributed_map_is_refused" {
  command = plan

  variables {
    type            = "EXPRESS"
    distributed_map = true
  }

  expect_failures = [aws_sfn_state_machine.this]
}

run "express_without_error_logs_warns" {
  command = plan

  variables {
    type    = "EXPRESS"
    logging = { level = "OFF" }
  }

  expect_failures = [check.express_executions_leave_a_record]
}

# ---------------------------------------------------------------------------
# Logging and encryption
# ---------------------------------------------------------------------------

run "logging_off_creates_no_group_and_no_delivery_grant" {
  command = plan

  variables {
    logging = { level = "OFF" }
  }

  # The block stays, at OFF: the provider sends nothing when it is absent,
  # and the running state machine would keep logging to a deleted group.
  assert {
    condition = alltrue([
      length(aws_cloudwatch_log_group.this) == 0,
      aws_sfn_state_machine.this[0].logging_configuration[0].level == "OFF",
      aws_sfn_state_machine.this[0].logging_configuration[0].log_destination == null,
      !anytrue([for st in jsondecode(aws_iam_role_policy.this[0].policy).Statement : st.Sid == "DeliverLogs"]),
      output.log_group_name == null,
    ])
    error_message = "with logging OFF there is no log group, no logging block and no delivery grant."
  }
}

run "execution_data_in_logs_warns" {
  command = plan

  variables {
    logging = { level = "ALL", include_execution_data = true }
  }

  expect_failures = [check.execution_data_is_logged_deliberately]
}

run "execution_data_with_logging_off_is_refused" {
  command = plan

  variables {
    acknowledged_checks = var.every_check
    logging             = { level = "OFF", include_execution_data = true }
  }

  expect_failures = [aws_sfn_state_machine.this]
}

run "a_customer_key_encrypts_and_is_contracted" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:eu-west-2:111122223333:key/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition = alltrue([
      aws_sfn_state_machine.this[0].encryption_configuration[0].type == "CUSTOMER_MANAGED_KMS_KEY",
      aws_sfn_state_machine.this[0].encryption_configuration[0].kms_data_key_reuse_period_seconds == 300,
      aws_cloudwatch_log_group.this[0].kms_key_id == "arn:aws:kms:eu-west-2:111122223333:key/11111111-2222-3333-4444-555555555555",
    ])
    error_message = "the key encrypts the state machine, and the log group falls back to it."
  }

  assert {
    condition = alltrue([
      anytrue([for st in jsondecode(aws_iam_role_policy.this[0].policy).Statement :
        st.Sid != "UseStateMachineKey" ? false : st.Condition.StringEquals["kms:EncryptionContext:aws:states:stateMachineArn"] == ["arn:aws:states:eu-west-2:111122223333:stateMachine:orders"]
      ]),
      anytrue([for st in jsondecode(aws_iam_role_policy.this[0].policy).Statement :
        st.Sid != "EncryptLogDeliveries" ? false : st.Condition.StringEquals["kms:EncryptionContext:SourceArn"] == ["arn:aws:logs:eu-west-2:111122223333:*"]
      ]),
    ])
    error_message = "the role uses the key only for this state machine, and for log delivery only from CloudWatch Logs."
  }

  assert {
    condition = alltrue([
      toset([for r in output.kms_key_policy_requirements : r.sid]) == toset(["StateMachineExecutionRole", "StateMachineDeployer", "StateMachineReaders", "StateMachineLogDelivery", "StateMachineLogGroup"]),
      anytrue([for r in output.kms_key_policy_requirements : r.sid == "StateMachineLogDelivery" ? contains(r.principals.services, "delivery.logs.amazonaws.com") : false]),
      anytrue([for s in output.deployer_requirements : s.sid == "UseStateMachineKey" ? contains(s.actions, "kms:Decrypt") : false]),
      anytrue([for r in output.kms_key_policy_requirements : r.sid == "StateMachineDeployer" ? contains(r.actions, "kms:Decrypt") : false]),
      anytrue([for st in jsondecode(output.start_execution_policy_json).Statement : st.Sid == "ReadEncryptedExecutions"]),
    ])
    error_message = "the key contract covers the role, the deployer (who decrypts on every refresh), the readers, log delivery and the log group; callers get kms:Decrypt."
  }
}

# ---------------------------------------------------------------------------
# Versions and aliases
# ---------------------------------------------------------------------------

run "a_canary_alias_splits_between_the_new_and_an_old_version" {
  command = apply

  variables {
    publish = true
    aliases = {
      live   = {}
      canary = { routing = [{ version = "current", weight = 10 }, { version = "arn:aws:states:eu-west-2:111122223333:stateMachine:orders:3", weight = 90 }] }
    }
  }

  assert {
    condition = alltrue([
      aws_sfn_alias.this["live"].routing_configuration[0].state_machine_version_arn == "arn:aws:states:eu-west-2:111122223333:stateMachine:orders:4",
      aws_sfn_alias.this["live"].routing_configuration[0].weight == 100,
      length(aws_sfn_alias.this["canary"].routing_configuration) == 2,
      output.version_arn == "arn:aws:states:eu-west-2:111122223333:stateMachine:orders:4",
    ])
    error_message = "\"current\" is the version this apply published; a canary splits 10/90."
  }

  assert {
    condition     = jsonencode(jsondecode(output.start_execution_policy_json).Statement[0].Resource) == jsonencode(["arn:aws:states:eu-west-2:111122223333:stateMachine:orders"])
    error_message = "callers are granted the unqualified ARN, which Step Functions checks for starts on every alias."
  }

  assert {
    condition     = anytrue([for s in output.deployer_requirements : s.sid == "PublishVersions" ? contains(s.actions, "states:PublishStateMachineVersion") : false])
    error_message = "publishing needs states:PublishStateMachineVersion."
  }
}

run "an_alias_on_current_without_publish_is_refused" {
  command = plan

  variables {
    aliases = { live = {} }
  }

  expect_failures = [aws_sfn_state_machine.this]
}

run "weights_that_do_not_sum_to_100_are_rejected" {
  command = plan

  variables {
    aliases = { live = { routing = [{ version = "current", weight = 50 }] } }
  }

  expect_failures = [var.aliases]
}

# ---------------------------------------------------------------------------
# Switches and contracts
# ---------------------------------------------------------------------------

run "create_false_plans_nothing" {
  command = plan

  variables {
    create    = false
    schedules = { nightly = { expression = "rate(1 day)" } }
  }

  assert {
    condition = alltrue([
      length(aws_sfn_state_machine.this) == 0, length(aws_iam_role.this) == 0, length(aws_cloudwatch_log_group.this) == 0,
      length(aws_scheduler_schedule.this) == 0, length(aws_iam_role.scheduler) == 0, length(aws_cloudwatch_metric_alarm.this) == 0,
    ])
    error_message = "create = false plans no resource."
  }

  assert {
    condition = alltrue([
      output.state_machine_arn == null, output.role_arn == null, output.log_group_name == null,
      output.start_execution_policy_json == null, output.deployer_requirements == null, output.role_requirements == null,
      output.kms_key_policy_requirements == null, output.governance == null, output.verify_commands == null,
      length(output.alias_arns) == 0,
    ])
    error_message = "create = false leaves every output null or empty."
  }
}

run "the_deployer_needs_to_validate_definitions" {
  command = plan

  assert {
    condition     = anytrue([for s in output.deployer_requirements : s.sid == "ValidateDefinitionDuringPlan" ? contains(s.actions, "states:ValidateStateMachineDefinition") : false])
    error_message = "the provider validates the definition with AWS during plan, so the deployer needs that action."
  }
}

run "no_alarms_warns" {
  command = plan

  variables {
    alarms = {}
  }

  expect_failures = [check.failures_reach_someone]
}

run "the_alarms_watch_failures_on_this_state_machine" {
  command = plan

  variables {
    alarms = { enabled = true, sns_topic_arn = "arn:aws:sns:eu-west-2:111122223333:alerts", execution_time_threshold_seconds = 600 }
  }

  assert {
    condition = alltrue([
      toset(keys(aws_cloudwatch_metric_alarm.this)) == toset(["executions_failed", "executions_timed_out", "executions_aborted", "execution_throttled", "execution_time"]),
      aws_cloudwatch_metric_alarm.this["executions_failed"].dimensions["StateMachineArn"] == "arn:aws:states:eu-west-2:111122223333:stateMachine:orders",
      aws_cloudwatch_metric_alarm.this["executions_failed"].namespace == "AWS/States",
      aws_cloudwatch_metric_alarm.this["execution_time"].threshold == 600000,
      aws_cloudwatch_metric_alarm.this["executions_failed"].treat_missing_data == "notBreaching",
    ])
    error_message = "four failure alarms plus execution time, on this state machine's ARN; idle is healthy."
  }
}
