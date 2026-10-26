locals {
  create = var.create

  # Module keys last, so a caller's tags cannot override them.
  module_tags = {
    "ManagedBy"    = "Terraform"
    "Module"       = "step-functions"
    "StateMachine" = var.name
  }
  common_tags = merge(var.tags, local.module_tags)

  # Placeholders so ARN expressions still evaluate when create = false.
  partition  = coalesce(one(data.aws_partition.current[*].partition), "aws")
  region     = try(split(".", one(data.aws_region.current[*].endpoint))[1], "us-east-1")
  account_id = coalesce(one(data.aws_caller_identity.current[*].account_id), "000000000000")

  acknowledged = toset(var.acknowledged_checks)

  # Built, not read from the resource: the role's policy names it before the
  # state machine exists, and reading it would be a cycle.
  state_machine_arn = "arn:${local.partition}:states:${local.region}:${local.account_id}:stateMachine:${var.name}"
  executions_arn    = "arn:${local.partition}:states:${local.region}:${local.account_id}:execution:${var.name}:*"
  is_express        = var.type == "EXPRESS"

  # -------------------------------------------------------------------------
  # Logging
  # -------------------------------------------------------------------------

  logging_on       = var.logging.level != "OFF"
  create_log_group = local.create && local.logging_on && var.logging.create_log_group
  log_group_name   = var.logging.create_log_group ? "/aws/vendedlogs/states/${var.name}" : var.logging.log_group_name
  log_group_arn    = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${local.log_group_name}"
  logs_kms_key_arn = var.logging.kms_key_arn != "" ? var.logging.kms_key_arn : var.kms_key_arn

  # -------------------------------------------------------------------------
  # Versions and aliases
  # -------------------------------------------------------------------------

  published_version_arn = one(aws_sfn_state_machine.this[*].state_machine_version_arn)
  alias_routing = {
    for k, a in var.aliases : k => [
      for r in a.routing : { version = r.version == "current" ? local.published_version_arn : r.version, weight = r.weight }
    ]
  }
  aliases_on_current = [for k, a in var.aliases : k if anytrue([for r in a.routing : r.version == "current"])]

  # An execution starts on the state machine ("") or on an alias. Lookups
  # fall back rather than index: an undeclared alias must reach the
  # precondition that names it, not throw "Invalid index" first.
  target_arn = {
    for k in concat([""], keys(var.aliases)) : k => (k == "" ? local.state_machine_arn : "${local.state_machine_arn}:${k}")
  }
  referenced_aliases = distinct(compact(concat(
    [for s in values(var.schedules) : s.alias],
    [for r in values(var.event_rules) : r.alias],
  )))
  unknown_aliases = [for a in local.referenced_aliases : a if !contains(keys(var.aliases), a)]

  # Step Functions authorises a start on an alias against the unqualified
  # state machine ARN; the alias is the states:StateMachineQualifier key. A
  # role for triggers that all name aliases is held to those aliases.
  schedule_qualifiers = distinct([for s in values(var.schedules) : s.alias])
  rule_qualifiers     = distinct([for r in values(var.event_rules) : r.alias])

  # -------------------------------------------------------------------------
  # What the definition says about itself. A plain search of the text:
  # nesting (Parallel, Map) does not hide anything from it.
  # -------------------------------------------------------------------------

  uses_sync_or_callback = can(regex("\\.(sync|waitForTaskToken)(:2)?\"", var.definition))
  uses_distributed_map  = can(regex("\"Mode\"\\s*:\\s*\"DISTRIBUTED\"", var.definition))

  # ARNs written in the definition, by service, against what integrations
  # grants. Only literal ARNs: one built at runtime (States.Format, JSONata)
  # is invisible here.
  definition_arns = distinct(regexall("arn:aws[a-z-]*:(?:lambda|sqs|sns|dynamodb|events|states):[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_./:-]+", var.definition))
  granted_arns = concat(
    var.integrations.lambda_functions, var.integrations.sqs_queues, var.integrations.sns_topics,
    var.integrations.dynamodb_read_tables, var.integrations.dynamodb_write_tables,
    var.integrations.event_buses, var.integrations.state_machines,
    flatten([for s in var.role.statements : s.resources if s.effect == "Allow"]),
  )
  # A grant covers its ARN and that ARN qualified (":alias", ":version", a
  # Distributed Map's "/label"); the state machine's own ARN is its business.
  ungranted_definition_arns = [
    for a in local.definition_arns : a
    if !anytrue([for g in concat(local.granted_arns, [local.state_machine_arn]) : a == g || startswith(a, "${g}:") || startswith(a, "${g}/")])
  ]

  # -------------------------------------------------------------------------
  # Role
  # -------------------------------------------------------------------------

  create_role = local.create && var.role.create
  role_name   = "${var.name}-${local.region}-sfn"
  role_arn    = var.role.create ? one(aws_iam_role.this[*].arn) : var.role.arn

  i = var.integrations

  # What the state machine needs from its role, as AWS documents it per
  # integration. One list for the module's policy and, with a brought role,
  # for output.role_requirements.
  role_statements = concat(
    length(local.i.lambda_functions) == 0 ? [] : [{
      sid       = "InvokeLambdaFunctions"
      actions   = ["lambda:InvokeFunction"]
      resources = flatten([for f in local.i.lambda_functions : [f, "${f}:*"]])
      condition = []
    }],
    length(local.i.sqs_queues) == 0 ? [] : [{
      sid       = "SendToQueues"
      actions   = ["sqs:SendMessage"]
      resources = local.i.sqs_queues
      condition = []
    }],
    length(local.i.sns_topics) == 0 ? [] : [{
      sid       = "PublishToTopics"
      actions   = ["sns:Publish"]
      resources = local.i.sns_topics
      condition = []
    }],
    length(local.i.dynamodb_read_tables) == 0 ? [] : [{
      sid       = "ReadTables"
      actions   = ["dynamodb:GetItem"]
      resources = local.i.dynamodb_read_tables
      condition = []
    }],
    length(local.i.dynamodb_write_tables) == 0 ? [] : [{
      sid       = "WriteTables"
      actions   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"]
      resources = local.i.dynamodb_write_tables
      condition = []
    }],
    length(local.i.event_buses) == 0 ? [] : [{
      sid       = "PutEvents"
      actions   = ["events:PutEvents"]
      resources = local.i.event_buses
      condition = []
    }],
    length(local.i.state_machines) == 0 ? [] : [
      {
        sid       = "StartChildStateMachines"
        actions   = ["states:StartExecution"]
        resources = local.i.state_machines
        condition = []
      },
      {
        # .sync: Step Functions follows the child execution.
        sid       = "FollowChildExecutions"
        actions   = ["states:DescribeExecution", "states:StopExecution"]
        resources = [for a in local.i.state_machines : "${replace(a, ":stateMachine:", ":execution:")}:*"]
        condition = []
      },
      {
        sid       = "ManagedRuleForChildExecutions"
        actions   = ["events:PutTargets", "events:PutRule", "events:DescribeRule"]
        resources = ["arn:${local.partition}:events:${local.region}:${local.account_id}:rule/StepFunctionsGetEventsForStepFunctionsExecutionRule"]
        condition = []
      },
    ],
    length(local.i.ecs_task_definitions) == 0 ? [] : concat(
      [
        {
          sid       = "RunEcsTasks"
          actions   = ["ecs:RunTask"]
          resources = [for t in local.i.ecs_task_definitions : "${t}:*"]
          condition = []
        },
        {
          # These two take no task-definition scope.
          sid       = "FollowEcsTasks"
          actions   = ["ecs:StopTask", "ecs:DescribeTasks"]
          resources = ["*"]
          condition = []
        },
        {
          sid       = "ManagedRuleForEcsTasks"
          actions   = ["events:PutTargets", "events:PutRule", "events:DescribeRule"]
          resources = ["arn:${local.partition}:events:${local.region}:${local.account_id}:rule/StepFunctionsGetEventsForECSTaskRule"]
          condition = []
        },
      ],
      length(local.i.ecs_pass_role_arns) == 0 ? [] : [{
        sid       = "PassEcsTaskRoles"
        actions   = ["iam:PassRole"]
        resources = local.i.ecs_pass_role_arns
        condition = [{ test = "StringEquals", variable = "iam:PassedToService", values = ["ecs-tasks.amazonaws.com"] }]
      }],
    ),
    !local.i.glue_job_runs ? [] : [{
      sid       = "RunGlueJobs"
      actions   = ["glue:StartJobRun", "glue:GetJobRun", "glue:GetJobRuns", "glue:BatchStopJobRun"]
      resources = ["*"]
      condition = []
    }],
    length(local.i.kms_key_arns) == 0 ? [] : [{
      sid       = "UseIntegrationKeys"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = local.i.kms_key_arns
      condition = []
    }],
    !var.distributed_map ? [] : [
      {
        sid       = "StartDistributedMapChildren"
        actions   = ["states:StartExecution"]
        resources = [local.state_machine_arn]
        condition = []
      },
      {
        sid       = "DescribeDistributedMapChildren"
        actions   = ["states:DescribeExecution"]
        resources = [local.executions_arn]
        condition = []
      },
    ],
    !local.logging_on ? [] : [{
      # Log delivery actions take no resource scope.
      sid = "DeliverLogs"
      actions = [
        "logs:CreateLogDelivery", "logs:CreateLogStream", "logs:GetLogDelivery", "logs:UpdateLogDelivery",
        "logs:DeleteLogDelivery", "logs:ListLogDeliveries", "logs:PutLogEvents", "logs:PutResourcePolicy",
        "logs:DescribeResourcePolicies", "logs:DescribeLogGroups",
      ]
      resources = ["*"]
      condition = []
    }],
    !var.tracing ? [] : [{
      sid       = "WriteTraces"
      actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
      resources = ["*"]
      condition = []
    }],
    var.kms_key_arn == "" ? [] : [{
      # The encryption context ties the key to this state machine. No
      # kms:ViaService: AWS warns it stops executions.
      sid       = "UseStateMachineKey"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [var.kms_key_arn]
      condition = [{ test = "StringEquals", variable = "kms:EncryptionContext:aws:states:stateMachineArn", values = [local.state_machine_arn] }]
    }],
    var.kms_key_arn == "" || !local.logging_on ? [] : [{
      sid       = "EncryptLogDeliveries"
      actions   = ["kms:GenerateDataKey"]
      resources = [var.kms_key_arn]
      condition = [{ test = "StringEquals", variable = "kms:EncryptionContext:SourceArn", values = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:*"] }]
    }],
  )

  role_policy_document = length(local.role_statements) == 0 ? "" : jsonencode({
    Version = "2012-10-17"
    Statement = [for s in local.role_statements : merge(
      { Sid = s.sid, Effect = "Allow", Action = s.actions, Resource = s.resources },
      length(s.condition) == 0 ? {} : {
        Condition = { for test in distinct([for c in s.condition : c.test]) : test => {
          for c in s.condition : c.variable => c.values if c.test == test
        } }
      },
    )]
  })

  caller_policy_document = length(var.role.statements) == 0 ? "" : jsonencode({
    Version = "2012-10-17"
    Statement = [for n, s in var.role.statements : merge(
      { Sid = s.sid != "" ? s.sid : "Statement${n + 1}", Effect = s.effect, Action = s.actions, Resource = s.resources },
      length(s.conditions) == 0 ? {} : {
        Condition = { for test in distinct([for c in s.conditions : c.test]) : test => {
          for c in s.conditions : c.variable => c.values if c.test == test
        } }
      },
    )]
  })

  # -------------------------------------------------------------------------
  # Triggers
  # -------------------------------------------------------------------------

  create_scheduler_role = local.create && length(var.schedules) > 0
  create_events_role    = local.create && length(var.event_rules) > 0
  # A rule on a custom bus has the bus in its ARN.
  event_rule_arns = {
    for k, r in var.event_rules : k => (
      r.event_bus_name == "default"
      ? "arn:${local.partition}:events:${local.region}:${local.account_id}:rule/${var.name}-${k}"
      : "arn:${local.partition}:events:${local.region}:${local.account_id}:rule/${r.event_bus_name}/${var.name}-${k}"
    )
  }
}
