# ---------------------------------------------------------------------------
# Module
# ---------------------------------------------------------------------------

variable "create" {
  description = "Create the state machine and everything around it. false plans nothing and leaves every output null."
  type        = bool
  default     = true
  nullable    = false
}

variable "name" {
  description = "State machine name, and the prefix of every other name the module creates (role, log group, rules, schedules, alarms). Changing it replaces the state machine and starts a new execution history. The module's role names add \"-<region>-sfn\" (and \"-<region>-events\", \"-<region>-schedule\" when used), and IAM allows 64 characters: keep name to about 40, or bring the role."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,80}$", var.name))
    error_message = "name must be 1-80 letters, digits, hyphens or underscores."
  }
}

variable "tags" {
  description = "Tags for every resource the module creates. The module adds ManagedBy, Module and StateMachine last, so they cannot be overridden."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "acknowledged_checks" {
  description = "Names of advisory checks whose warning is intended here (README, \"Advisory checks\"). An acknowledged check stays silent and is listed in output.governance."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([for c in var.acknowledged_checks : contains([
      "failures_reach_someone", "express_executions_leave_a_record", "log_retention_is_bounded",
      "execution_data_is_logged_deliberately", "the_definition_is_rendered", "every_arn_in_the_definition_is_granted",
      "event_deliveries_are_kept",
    ], c)])
    error_message = "acknowledged_checks names a check that does not exist. README \"Advisory checks\" lists them."
  }
}

# ---------------------------------------------------------------------------
# The state machine
# ---------------------------------------------------------------------------

variable "type" {
  description = "STANDARD: up to a year, exactly-once, full execution history, billed per state transition. EXPRESS: up to 5 minutes, at-least-once, no .sync or callback integrations, history only in CloudWatch Logs, billed per request and duration. Changing it replaces the state machine."
  type        = string
  default     = "STANDARD"
  nullable    = false

  validation {
    condition     = contains(["STANDARD", "EXPRESS"], var.type)
    error_message = "type must be STANDARD or EXPRESS."
  }
}

variable "definition" {
  description = <<-EOT
    The Amazon States Language definition, as JSON (render it with
    templatefile() or jsonencode()). The AWS provider sends it to
    ValidateStateMachineDefinition during plan, so a malformed definition
    fails the plan with AWS's own diagnostics - the deployer needs
    states:ValidateStateMachineDefinition (output.deployer_requirements).
    QueryLanguage JSONata is supported.

    The module does not read the definition to grant permissions: name what
    the states call in integrations. The every_arn_in_the_definition_is_granted
    check compares the two.
  EOT
  type        = string
  nullable    = false

  validation {
    condition     = can(jsondecode(var.definition)) ? (can(jsondecode(var.definition).StartAt) && can(jsondecode(var.definition).States)) : false
    error_message = "definition must be JSON with StartAt and States."
  }

  validation {
    condition     = length(var.definition) <= 1048576
    error_message = "definition is over the 1 MB Step Functions limit. Move large static data to S3 or a Distributed Map item reader."
  }
}

variable "publish" {
  description = "Publish a version on every definition or configuration change. Needed for aliases on \"current\". Versions are kept by Step Functions (up to 1000 per state machine)."
  type        = bool
  default     = false
  nullable    = false
}

variable "aliases" {
  description = <<-EOT
    Aliases, keyed by name, each routing to one or two versions.

      routing  list of { version, weight }, weights summing to 100.
               version is "current" (the version this apply published;
               needs publish) or a version ARN. Two entries are a canary:
               [{ version = "current", weight = 10 }, { version = "<arn>", weight = 90 }].

    Triggers and callers that name an alias start executions on it, so a
    release moves with the alias, not with each caller.
  EOT
  type = map(object({
    description = optional(string, "")
    routing = optional(list(object({
      version = string
      weight  = number
    })), [{ version = "current", weight = 100 }])
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for k in keys(var.aliases) : can(regex("^[A-Za-z0-9_-]{1,80}$", k)) && !can(regex("^[0-9]+$", k))])
    error_message = "aliases keys must be 1-80 letters, digits, hyphens or underscores, and not a number."
  }

  validation {
    condition = alltrue([for a in values(var.aliases) : alltrue([
      length(a.routing) >= 1 && length(a.routing) <= 2,
      sum(concat([0], [for r in a.routing : r.weight])) == 100,
      alltrue([for r in a.routing : r.weight >= 0 && r.weight <= 100 && floor(r.weight) == r.weight]),
      alltrue([for r in a.routing : r.version == "current" || can(regex("^arn:aws[a-z-]*:states:[a-z0-9-]+:[0-9]{12}:stateMachine:[A-Za-z0-9_-]+:[0-9]+$", r.version))]),
      length(distinct([for r in a.routing : r.version])) == length(a.routing),
    ])])
    error_message = "aliases[*].routing takes one or two distinct versions (\"current\" or a version ARN) with whole weights summing to 100."
  }
}

# ---------------------------------------------------------------------------
# What the states call
# ---------------------------------------------------------------------------

variable "integrations" {
  description = <<-EOT
    The resources the definition's Task states call, by service. Each list
    becomes the permissions AWS documents for that integration, on exactly
    those ARNs:

      lambda_functions      lambda:InvokeFunction on the function and on
                            <arn>:* (versions and aliases: an unqualified
                            ARN grants neither)
      sqs_queues            sqs:SendMessage
      sns_topics            sns:Publish
      dynamodb_read_tables  dynamodb:GetItem
      dynamodb_write_tables dynamodb:PutItem, UpdateItem, DeleteItem
      event_buses           events:PutEvents
      state_machines        states:StartExecution, and for .sync the
                            describe/stop and the managed EventBridge rule
      ecs_task_definitions  ecs:RunTask, StopTask, DescribeTasks and the
                            managed rule for .sync; ecs_pass_role_arns are
                            the task and execution roles it may pass
      glue_job_runs         glue:StartJobRun, GetJobRun(s), BatchStopJobRun
                            (true/false: Glue has no resource-level
                            permissions, so this is on "*")
      kms_key_arns          kms:Decrypt and GenerateDataKey, for encrypted
                            queues and topics above

    Anything else (aws-sdk integrations, HTTP tasks, Bedrock, ...) goes in
    role.statements.
  EOT
  type = object({
    lambda_functions      = optional(list(string), [])
    sqs_queues            = optional(list(string), [])
    sns_topics            = optional(list(string), [])
    dynamodb_read_tables  = optional(list(string), [])
    dynamodb_write_tables = optional(list(string), [])
    event_buses           = optional(list(string), [])
    state_machines        = optional(list(string), [])
    ecs_task_definitions  = optional(list(string), [])
    ecs_pass_role_arns    = optional(list(string), [])
    glue_job_runs         = optional(bool, false)
    kms_key_arns          = optional(list(string), [])
  })
  default  = {}
  nullable = false

  validation {
    condition = alltrue(concat(
      [for a in var.integrations.lambda_functions : can(regex("^arn:aws[a-z-]*:lambda:[a-z0-9-]+:[0-9]{12}:function:[A-Za-z0-9_-]+$", a))],
      [for a in var.integrations.sqs_queues : can(regex("^arn:aws[a-z-]*:sqs:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_.-]+$", a))],
      [for a in var.integrations.sns_topics : can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_.-]+$", a))],
      [for a in concat(var.integrations.dynamodb_read_tables, var.integrations.dynamodb_write_tables) : can(regex("^arn:aws[a-z-]*:dynamodb:[a-z0-9-]+:[0-9]{12}:table/[A-Za-z0-9_.-]+$", a))],
      [for a in var.integrations.event_buses : can(regex("^arn:aws[a-z-]*:events:[a-z0-9-]+:[0-9]{12}:event-bus/.+$", a))],
      [for a in var.integrations.state_machines : can(regex("^arn:aws[a-z-]*:states:[a-z0-9-]+:[0-9]{12}:stateMachine:[A-Za-z0-9_-]+$", a))],
      [for a in var.integrations.ecs_task_definitions : can(regex("^arn:aws[a-z-]*:ecs:[a-z0-9-]+:[0-9]{12}:task-definition/[A-Za-z0-9_-]+$", a))],
      [for a in var.integrations.ecs_pass_role_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+$", a))],
      [for a in var.integrations.kms_key_arns : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", a))],
    ))
    error_message = "integrations: each list takes ARNs of its kind - unqualified Lambda functions, SQS queues, SNS topics, DynamoDB tables, event buses, unqualified state machines, ECS task definition families (task-definition/<family>, any revision), IAM roles, KMS keys."
  }

  validation {
    condition     = length(var.integrations.ecs_task_definitions) > 0 ? true : length(var.integrations.ecs_pass_role_arns) == 0
    error_message = "integrations.ecs_pass_role_arns is for ECS tasks; without ecs_task_definitions it would grant iam:PassRole for nothing."
  }
}

variable "distributed_map" {
  description = "The definition uses a Distributed Map state: the role may start this state machine's child executions and describe them, the least privilege AWS documents. Its item reader and result writer buckets go in role.statements. STANDARD only: Express workflows do not support Distributed Map."
  type        = bool
  default     = false
  nullable    = false
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------

variable "role" {
  description = <<-EOT
    The execution role. By default the module creates "<name>-<region>-sfn",
    trusted by Step Functions for this account's state machines only, with
    the permissions for integrations, logging, tracing, encryption and
    Distributed Map, plus:

      statements           everything else the states call, as IAM statements.
      managed_policy_arns  managed policies to attach.

    arn brings an existing role instead (create = false); the module then
    attaches nothing and output.role_requirements lists what the role needs.
  EOT
  type = object({
    create                   = optional(bool, true)
    arn                      = optional(string, "")
    path                     = optional(string, "/")
    permissions_boundary_arn = optional(string, "")
    managed_policy_arns      = optional(list(string), [])
    statements = optional(list(object({
      sid       = optional(string, "")
      effect    = optional(string, "Allow")
      actions   = list(string)
      resources = list(string)
      conditions = optional(list(object({
        test     = string
        variable = string
        values   = list(string)
      })), [])
    })), [])
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.role.create ? var.role.arn == "" : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+", var.role.arn))
    error_message = "role.arn must be empty when role.create is true, and an IAM role ARN when it is false."
  }

  validation {
    condition     = var.role.create ? true : (length(var.role.statements) == 0 && length(var.role.managed_policy_arns) == 0)
    error_message = "role.statements and role.managed_policy_arns apply to the module's role; with a brought role they would be dropped. Put them on that role."
  }

  validation {
    condition     = can(regex("^/([A-Za-z0-9+=,.@_-]+/)*$", var.role.path))
    error_message = "role.path must start and end with / (for example /platform/workflows/)."
  }

  validation {
    condition     = var.role.permissions_boundary_arn == "" ? true : can(regex("^arn:aws[a-z-]*:iam::(aws|[0-9]{12}):policy/.+", var.role.permissions_boundary_arn))
    error_message = "role.permissions_boundary_arn must be empty or an IAM policy ARN."
  }

  validation {
    condition     = alltrue([for p in var.role.managed_policy_arns : can(regex("^arn:aws[a-z-]*:iam::(aws|[0-9]{12}):policy/.+", p))])
    error_message = "role.managed_policy_arns must be IAM policy ARNs."
  }

  validation {
    condition = alltrue([for s in var.role.statements : alltrue([
      contains(["Allow", "Deny"], s.effect),
      length(s.actions) > 0,
      length(s.resources) > 0,
      s.sid == "" ? true : can(regex("^[A-Za-z0-9]+$", s.sid)),
    ])])
    error_message = "role.statements: effect is Allow or Deny, actions and resources are not empty, and sid is alphanumeric."
  }

  validation {
    condition     = alltrue([for s in var.role.statements : s.effect == "Deny" ? true : !(contains(s.actions, "*") && contains(s.resources, "*"))])
    error_message = "role.statements grants \"*\" on \"*\". Name the actions, or the resources."
  }
}

# ---------------------------------------------------------------------------
# Logging, tracing, encryption
# ---------------------------------------------------------------------------

variable "logging" {
  description = <<-EOT
    Execution logs to CloudWatch Logs. The module creates
    /aws/vendedlogs/states/<name> (the vendedlogs prefix keeps the log
    group resource policy within its size limit as state machines multiply).

      level                   ALL, ERROR (default), FATAL or OFF. An EXPRESS
                              state machine has no other execution history.
      include_execution_data  log inputs and outputs. They may hold personal
                              or secret data; false by default.
      retention_days          0 keeps logs forever ($0.03 per GB-month).
      log_group_name          bring an existing group (create_log_group =
                              false).
  EOT
  type = object({
    level                  = optional(string, "ERROR")
    include_execution_data = optional(bool, false)
    create_log_group       = optional(bool, true)
    log_group_name         = optional(string, "")
    retention_days         = optional(number, 30)
    log_group_class        = optional(string, "STANDARD")
    kms_key_arn            = optional(string, "")
    skip_destroy           = optional(bool, false)
  })
  default  = {}
  nullable = false

  validation {
    condition     = contains(["ALL", "ERROR", "FATAL", "OFF"], var.logging.level)
    error_message = "logging.level must be ALL, ERROR, FATAL or OFF."
  }

  validation {
    condition     = var.logging.create_log_group ? var.logging.log_group_name == "" : can(regex("^[A-Za-z0-9._/#-]{1,512}$", var.logging.log_group_name))
    error_message = "logging.log_group_name is for a brought group (create_log_group = false): 1-512 of letters, digits . _ - / #."
  }

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.logging.retention_days)
    error_message = "logging.retention_days must be 0 or a retention period CloudWatch Logs accepts."
  }

  validation {
    condition     = contains(["STANDARD", "INFREQUENT_ACCESS"], var.logging.log_group_class)
    error_message = "logging.log_group_class must be STANDARD or INFREQUENT_ACCESS."
  }

  validation {
    condition     = var.logging.kms_key_arn == "" ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.logging.kms_key_arn))
    error_message = "logging.kms_key_arn must be empty or a KMS key ARN."
  }
}

variable "tracing" {
  description = "X-Ray tracing of executions (billed per trace)."
  type        = bool
  default     = false
  nullable    = false
}

variable "kms_key_arn" {
  description = "Customer managed key that encrypts the state machine's definition and execution data at rest, and, unless logging.kms_key_arn is set, the log group. Empty: an AWS-owned key. output.kms_key_policy_requirements says what the key policy must allow."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.kms_key_arn == "" ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.kms_key_arn))
    error_message = "kms_key_arn must be empty or a KMS key ARN."
  }
}

variable "kms_data_key_reuse_period_seconds" {
  description = "How long Step Functions reuses a data key from kms_key_arn before asking KMS for a new one, 60-900 seconds. Shorter is more KMS requests (billed)."
  type        = number
  default     = 300
  nullable    = false

  validation {
    condition     = var.kms_data_key_reuse_period_seconds >= 60 && var.kms_data_key_reuse_period_seconds <= 900 && floor(var.kms_data_key_reuse_period_seconds) == var.kms_data_key_reuse_period_seconds
    error_message = "kms_data_key_reuse_period_seconds must be a whole number from 60 to 900."
  }
}

# ---------------------------------------------------------------------------
# What starts executions
# ---------------------------------------------------------------------------

variable "schedules" {
  description = <<-EOT
    EventBridge Scheduler schedules that start an execution, keyed by name.
    expression is rate(...), cron(...) or at(...); timezone an IANA name;
    input the execution input as JSON; alias starts it on that alias. The
    module creates one scheduler role, trusted only by this account's default
    schedule group. dead_letter_arn (SQS) keeps starts the scheduler could
    not deliver.
  EOT
  type = map(object({
    expression                   = string
    timezone                     = optional(string, "UTC")
    input                        = optional(string, "{}")
    enabled                      = optional(bool, true)
    description                  = optional(string, "")
    alias                        = optional(string, "")
    flexible_window_minutes      = optional(number, 0)
    maximum_retry_attempts       = optional(number, 185)
    maximum_event_age_in_seconds = optional(number, 86400)
    dead_letter_arn              = optional(string, "")
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for k in keys(var.schedules) : can(regex("^[A-Za-z0-9_.-]{1,40}$", k))])
    error_message = "schedules keys are 1-40 letters, digits, . _ or - (the schedule name is <name>-<key>)."
  }

  validation {
    condition     = alltrue([for s in values(var.schedules) : can(regex("^(rate\\(.+\\)|cron\\(.+\\)|at\\(.+\\))$", s.expression)) && can(jsondecode(s.input))])
    error_message = "schedules[*].expression must be rate(...), cron(...) or at(...), and input must be JSON."
  }

  validation {
    condition = alltrue([for s in values(var.schedules) : alltrue([
      s.flexible_window_minutes >= 0 && s.flexible_window_minutes <= 1440,
      s.maximum_retry_attempts >= 0 && s.maximum_retry_attempts <= 185,
      s.maximum_event_age_in_seconds >= 60 && s.maximum_event_age_in_seconds <= 86400,
      s.dead_letter_arn == "" ? true : can(regex("^arn:aws[a-z-]*:sqs:", s.dead_letter_arn)),
    ])])
    error_message = "schedules: flexible_window_minutes 0-1440, maximum_retry_attempts 0-185, maximum_event_age_in_seconds 60-86400, dead_letter_arn an SQS queue ARN."
  }
}

variable "event_rules" {
  description = <<-EOT
    EventBridge rules that start an execution for each matching event, keyed
    by name. event_pattern is the JSON pattern; event_bus_name the bus
    (default: the account's default bus). input_path or input_template
    shape the execution input (default: the whole event). The module creates
    one EventBridge role, allowed to start only this state machine.
    dead_letter_arn (SQS) keeps events EventBridge could not deliver.
  EOT
  type = map(object({
    event_pattern                = string
    event_bus_name               = optional(string, "default")
    description                  = optional(string, "")
    enabled                      = optional(bool, true)
    alias                        = optional(string, "")
    input_path                   = optional(string, "")
    input_paths                  = optional(map(string), {})
    input_template               = optional(string, "")
    maximum_retry_attempts       = optional(number, 185)
    maximum_event_age_in_seconds = optional(number, 86400)
    dead_letter_arn              = optional(string, "")
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for k in keys(var.event_rules) : can(regex("^[A-Za-z0-9_.-]{1,40}$", k))])
    error_message = "event_rules keys are 1-40 letters, digits, . _ or - (the rule name is <name>-<key>)."
  }

  validation {
    condition     = alltrue([for r in values(var.event_rules) : can(jsondecode(r.event_pattern))])
    error_message = "event_rules[*].event_pattern must be JSON."
  }

  validation {
    # A name: the rule ARN, which the EventBridge role's trust names, is
    # built from it.
    condition     = alltrue([for r in values(var.event_rules) : can(regex("^[A-Za-z0-9._-]{1,256}$", r.event_bus_name))])
    error_message = "event_rules[*].event_bus_name must be a bus name in this account, not an ARN."
  }

  validation {
    condition     = alltrue([for r in values(var.event_rules) : r.input_path == "" ? true : (r.input_template == "" && length(r.input_paths) == 0)])
    error_message = "event_rules: input_path and input_template (with input_paths) are alternatives."
  }

  validation {
    condition = alltrue([for r in values(var.event_rules) : alltrue([
      r.maximum_retry_attempts >= 0 && r.maximum_retry_attempts <= 185,
      r.maximum_event_age_in_seconds >= 60 && r.maximum_event_age_in_seconds <= 86400,
      r.dead_letter_arn == "" ? true : can(regex("^arn:aws[a-z-]*:sqs:", r.dead_letter_arn)),
    ])])
    error_message = "event_rules: maximum_retry_attempts 0-185, maximum_event_age_in_seconds 60-86400, dead_letter_arn an SQS queue ARN."
  }
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

variable "alarms" {
  description = <<-EOT
    CloudWatch alarms to sns_topic_arn (about $0.10 per alarm-month): failed,
    timed-out, aborted and throttled executions, and, with
    execution_time_threshold_seconds, executions running longer than that.
  EOT
  type = object({
    enabled                          = optional(bool, false)
    sns_topic_arn                    = optional(string, "")
    period_seconds                   = optional(number, 300)
    execution_time_threshold_seconds = optional(number, 0)
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.alarms.enabled ? can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+$", var.alarms.sns_topic_arn)) : true
    error_message = "alarms.enabled needs alarms.sns_topic_arn, a standard SNS topic ARN: an alarm with no action tells nobody."
  }

  validation {
    condition     = contains([60, 300, 900, 3600], var.alarms.period_seconds) && var.alarms.execution_time_threshold_seconds >= 0
    error_message = "alarms.period_seconds is 60, 300, 900 or 3600, and execution_time_threshold_seconds 0 (off) or more."
  }
}
