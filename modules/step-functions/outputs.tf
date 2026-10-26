# ---------------------------------------------------------------------------
# Resources
# ---------------------------------------------------------------------------

output "state_machine_arn" {
  description = "State machine ARN: starts executions on the latest definition."
  value       = one(aws_sfn_state_machine.this[*].arn)
}

output "state_machine_name" {
  description = "State machine name."
  value       = one(aws_sfn_state_machine.this[*].name)
}

output "version_arn" {
  description = "The version this apply published, or null without publish."
  value       = var.publish ? local.published_version_arn : null
}

output "alias_arns" {
  description = "ARN per alias. Point callers and triggers at these to move releases with the alias."
  value       = { for k, a in aws_sfn_alias.this : k => a.arn }
}

output "role_arn" {
  description = "The execution role in use: the module's or the brought one."
  value       = local.create ? local.role_arn : null
}

output "role_name" {
  description = "Name of the module-created execution role, or null."
  value       = one(aws_iam_role.this[*].name)
}

output "log_group_name" {
  description = "The log group executions are logged to, or null with logging OFF."
  value       = local.create && local.logging_on ? local.log_group_name : null
}

output "log_group_arn" {
  description = "ARN of that log group (without the :* suffix)."
  value       = local.create && local.logging_on ? local.log_group_arn : null
}

output "schedule_arns" {
  description = "ARN per schedule."
  value       = { for k, s in aws_scheduler_schedule.this : k => s.arn }
}

output "event_rule_arns" {
  description = "ARN per EventBridge rule."
  value       = { for k, r in aws_cloudwatch_event_rule.this : k => r.arn }
}

output "alarm_arns" {
  description = "ARN per alarm."
  value       = { for k, a in aws_cloudwatch_metric_alarm.this : k => a.arn }
}

# ---------------------------------------------------------------------------
# Contracts
# ---------------------------------------------------------------------------

output "start_execution_policy_json" {
  description = "An IAM policy for callers in this account: start executions on the state machine and each alias (StartSyncExecution too for EXPRESS), follow and stop them, and read their data under the state machine's customer key. Attach it to the callers' roles; the module attaches it to nobody."
  value = !local.create ? null : jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "StartExecutions"
          Effect = "Allow"
          # The unqualified ARN covers starts on every alias and version: Step
          # Functions authorises those against it.
          Action   = local.is_express ? ["states:StartExecution", "states:StartSyncExecution"] : ["states:StartExecution"]
          Resource = [local.state_machine_arn]
        },
        {
          Sid      = "FollowExecutions"
          Effect   = "Allow"
          Action   = ["states:DescribeExecution", "states:StopExecution", "states:GetExecutionHistory"]
          Resource = [local.executions_arn]
        },
      ],
      var.kms_key_arn == "" ? [] : [{
        Sid      = "ReadEncryptedExecutions"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [var.kms_key_arn]
        Condition = {
          StringEquals = { "kms:EncryptionContext:aws:states:stateMachineArn" = local.state_machine_arn }
        }
      }],
    )
  })
}

output "deployer_requirements" {
  description = "What the principal running Terraform needs beyond creating the resources: the provider validates the definition with AWS during every plan, publishing needs its own action, the role is passed to Step Functions, and with a customer key every refresh decrypts the definition."
  value = !local.create ? null : concat(
    [{
      sid       = "ValidateDefinitionDuringPlan"
      actions   = ["states:ValidateStateMachineDefinition"]
      resources = ["*"]
    }],
    [{
      sid       = "PassExecutionRole"
      actions   = ["iam:PassRole"]
      resources = [local.role_arn]
    }],
    !var.publish ? [] : [{
      sid       = "PublishVersions"
      actions   = ["states:PublishStateMachineVersion"]
      resources = [local.state_machine_arn]
    }],
    var.kms_key_arn == "" ? [] : [{
      # Decrypt: the provider reads the state machine with DescribeStateMachine
      # after every create and on every refresh, which returns the definition.
      sid       = "UseStateMachineKey"
      actions   = ["kms:DescribeKey", "kms:GenerateDataKey", "kms:Decrypt"]
      resources = [var.kms_key_arn]
    }],
  )
}

output "role_requirements" {
  description = "What the execution role needs for the integrations and features configured here, as IAM statements { sid, actions, resources, condition }. With a brought role (role.create = false) the module attaches nothing: grant these on that role. role.statements are not included."
  value       = !local.create ? null : local.role_statements
}

output "kms_key_policy_requirements" {
  description = "What each customer-managed key's policy has to allow. Contract version 2, compiled by modules/kms: key, sid, principals = { services, arns, roles } (roles are symbolic: deployer runs Terraform, execution_readers are the callers of start_execution_policy_json), actions, conditions = [{ test, variable, values }] and purpose."
  value = !local.create ? null : concat(
    var.kms_key_arn == "" ? [] : concat(
      [
        {
          key        = var.kms_key_arn
          sid        = "StateMachineExecutionRole"
          principals = { services = [], arns = [local.role_arn], roles = [] }
          actions    = ["kms:Decrypt", "kms:GenerateDataKey"]
          conditions = [{ test = "StringEquals", variable = "kms:EncryptionContext:aws:states:stateMachineArn", values = [local.state_machine_arn] }]
          purpose    = "Executions read and write their data encrypted with this key."
        },
        {
          key        = var.kms_key_arn
          sid        = "StateMachineDeployer"
          principals = { services = [], arns = [], roles = ["deployer"] }
          actions    = ["kms:DescribeKey", "kms:GenerateDataKey", "kms:Decrypt"]
          conditions = []
          purpose    = "Creating and updating the state machine encrypts its definition with this key; every refresh decrypts it."
        },
        {
          key        = var.kms_key_arn
          sid        = "StateMachineReaders"
          principals = { services = [], arns = [], roles = ["execution_readers"] }
          actions    = ["kms:Decrypt"]
          conditions = [{ test = "StringEquals", variable = "kms:EncryptionContext:aws:states:stateMachineArn", values = [local.state_machine_arn] }]
          purpose    = "DescribeExecution, GetExecutionHistory and StartSyncExecution return decrypted data."
        },
      ],
      !local.logging_on ? [] : [{
        key        = var.kms_key_arn
        sid        = "StateMachineLogDelivery"
        principals = { services = ["delivery.logs.amazonaws.com"], arns = [], roles = [] }
        actions    = ["kms:Decrypt"]
        conditions = []
        purpose    = "Log delivery decrypts execution data to write it to CloudWatch Logs."
      }],
    ),
    !local.create_log_group || local.logs_kms_key_arn == "" ? [] : [{
      key        = local.logs_kms_key_arn
      sid        = "StateMachineLogGroup"
      principals = { services = ["logs.${local.region}.amazonaws.com"], arns = [], roles = [] }
      actions    = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
      conditions = [{ test = "ArnEquals", variable = "kms:EncryptionContext:aws:logs:arn", values = [local.log_group_arn] }]
      purpose    = "CloudWatch Logs encrypts the execution log group. Without it the log group create fails."
    }],
  )
}

output "governance" {
  description = "The posture of the state machine as data: assert on it in tests, or diff it in a change review."
  value = !local.create ? null : {
    type                      = var.type
    query_language            = try(jsondecode(var.definition).QueryLanguage, "JSONPath")
    role_managed_by_module    = var.role.create
    integrations              = { for k, v in var.integrations : k => v if(can(length(v)) ? length(v) > 0 : v == true) }
    distributed_map           = var.distributed_map
    logging_level             = var.logging.level
    include_execution_data    = var.logging.include_execution_data
    log_retention_days        = local.create_log_group ? var.logging.retention_days : null
    customer_managed_key      = var.kms_key_arn != ""
    logs_customer_key         = local.logs_kms_key_arn != ""
    tracing                   = var.tracing
    published                 = var.publish
    aliases                   = keys(var.aliases)
    schedules                 = keys(var.schedules)
    event_rules               = keys(var.event_rules)
    alarms                    = var.alarms.enabled
    acknowledged_checks       = sort(var.acknowledged_checks)
    ungranted_definition_arns = local.ungranted_definition_arns
  }
}

output "verify_commands" {
  description = "AWS CLI commands to run from CloudShell after an apply."
  value = !local.create ? null : {
    describe = "aws stepfunctions describe-state-machine --state-machine-arn ${local.state_machine_arn} --query '{Status:status,Type:type,Role:roleArn,Logging:loggingConfiguration.level,Encryption:encryptionConfiguration.type}'"
    start    = "aws stepfunctions ${local.is_express ? "start-sync-execution" : "start-execution"} --state-machine-arn ${local.state_machine_arn} --input '{}'"
    # ListExecutions does not support EXPRESS: its executions are in the logs.
    recent = local.is_express ? "aws logs filter-log-events --log-group-name ${local.log_group_name} --filter-pattern '{ $.type = \"ExecutionSucceeded\" || $.type = \"ExecutionFailed\" }' --max-items 10" : "aws stepfunctions list-executions --state-machine-arn ${local.state_machine_arn} --max-results 10 --query 'executions[].[name,status,startDate]' --output table"
    failed = local.is_express ? "aws logs filter-log-events --log-group-name ${local.log_group_name} --filter-pattern '{ $.type = \"ExecutionFailed\" }' --max-items 10" : "aws stepfunctions list-executions --state-machine-arn ${local.state_machine_arn} --status-filter FAILED --max-results 10 --output table"
    logs   = local.logging_on ? "aws logs tail ${local.log_group_name} --follow" : "logging is OFF"
  }
}
