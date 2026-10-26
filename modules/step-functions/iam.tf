# Roles. Inline jsonencode rather than aws_iam_policy_document, so the
# policies are in the plan and assertable under mock_provider.

resource "aws_iam_role" "this" {
  count = local.create_role ? 1 : 0

  # IAM is global and state machine names are regional: the region keeps two
  # deployments of one workflow apart.
  name                 = local.role_name
  path                 = var.role.path
  description          = "Execution role of Step Functions state machine ${var.name}"
  permissions_boundary = var.role.permissions_boundary_arn != "" ? var.role.permissions_boundary_arn : null

  # The confused-deputy conditions as the Step Functions documentation gives
  # them: this account's state machines in this region only.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "StepFunctions"
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        ArnLike      = { "aws:SourceArn" = "arn:${local.partition}:states:${local.region}:${local.account_id}:stateMachine:*" }
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })

  tags = local.common_tags
}

# What the module's features and the integrations need.
resource "aws_iam_role_policy" "this" {
  count = local.create_role && length(local.role_statements) > 0 ? 1 : 0

  name   = "module-features"
  role   = aws_iam_role.this[0].id
  policy = local.role_policy_document
}

# Everything else the states call, from role.statements.
resource "aws_iam_role_policy" "caller" {
  count = local.create_role && length(var.role.statements) > 0 ? 1 : 0

  name   = "definition-calls"
  role   = aws_iam_role.this[0].id
  policy = local.caller_policy_document
}

# Keyed by position, not by ARN: a policy created in the same root has an
# unknown ARN at plan, which for_each cannot take as a key.
resource "aws_iam_role_policy_attachment" "this" {
  for_each = local.create_role ? { for i, a in var.role.managed_policy_arns : tostring(i) => a } : {}

  role       = aws_iam_role.this[0].name
  policy_arn = each.value
}

# EventBridge Scheduler starts executions with this role, trusted for this
# account's default schedule group as the Scheduler documentation gives it.
resource "aws_iam_role" "scheduler" {
  count = local.create_scheduler_role ? 1 : 0

  name                 = "${var.name}-${local.region}-schedule"
  path                 = var.role.path
  description          = "EventBridge Scheduler starts Step Functions state machine ${var.name}"
  permissions_boundary = var.role.permissions_boundary_arn != "" ? var.role.permissions_boundary_arn : null

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "Scheduler"
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = local.account_id
          "aws:SourceArn"     = "arn:${local.partition}:scheduler:${local.region}:${local.account_id}:schedule-group/default"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "scheduler" {
  count = local.create_scheduler_role ? 1 : 0

  name = "start-executions"
  role = aws_iam_role.scheduler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [merge(
        { Sid = "StartExecutions", Effect = "Allow", Action = ["states:StartExecution"], Resource = [local.state_machine_arn] },
        contains(local.schedule_qualifiers, "") ? {} : {
          Condition = { "ForAnyValue:StringEquals" = { "states:StateMachineQualifier" = local.schedule_qualifiers } }
        },
      )],
      length(compact([for s in values(var.schedules) : s.dead_letter_arn])) == 0 ? [] : [{
        Sid      = "SendToDeadLetterQueues"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = distinct(compact([for s in values(var.schedules) : s.dead_letter_arn]))
      }],
    )
  })
}

# EventBridge rules start executions with this role. The EventBridge
# documentation gives the rule ARN as the SourceArn for rule targets.
resource "aws_iam_role" "events" {
  count = local.create_events_role ? 1 : 0

  name                 = "${var.name}-${local.region}-events"
  path                 = var.role.path
  description          = "EventBridge rules start Step Functions state machine ${var.name}"
  permissions_boundary = var.role.permissions_boundary_arn != "" ? var.role.permissions_boundary_arn : null

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EventBridgeRules"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        ArnLike      = { "aws:SourceArn" = values(local.event_rule_arns) }
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "events" {
  count = local.create_events_role ? 1 : 0

  name = "start-executions"
  role = aws_iam_role.events[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [merge(
      { Sid = "StartExecutions", Effect = "Allow", Action = ["states:StartExecution"], Resource = [local.state_machine_arn] },
      contains(local.rule_qualifiers, "") ? {} : {
        Condition = { "ForAnyValue:StringEquals" = { "states:StateMachineQualifier" = local.rule_qualifiers } }
      },
    )]
  })
}
