# The failure this file exists for: a CDC task stops, the target stops receiving
# changes, and nothing anywhere goes red. The source keeps taking writes, the
# gap grows, and it is found at cutover.
#
# Two defences. Event subscriptions catch the state change; the latency alarms
# catch the case where the task is technically running and falling behind. Both
# need an SNS topic - without one this file creates almost nothing.

resource "aws_cloudwatch_log_group" "tasks" {
  count = local.create && local.provisioned && var.create_log_group && var.log_retention_days > 0 ? 1 : 0

  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn != "" ? var.kms_key_arn : null
  skip_destroy      = var.log_group_skip_destroy
  tags              = local.common_tags

  lifecycle {
    precondition {
      # These logs carry row-level data at DEBUG severity, so require_cmk has to
      # mean this group too - not just the replication storage.
      condition     = var.require_cmk ? var.kms_key_arn != "" : true
      error_message = "require_cmk = true but kms_key_arn is empty, so DMS task logs - which contain row data and SQL at DEBUG severity - would sit under the AWS-managed CloudWatch Logs key."
    }
  }
}

resource "aws_dms_event_subscription" "instance" {
  count = local.create && local.provisioned && var.sns_topic_arn != "" && var.create_event_subscriptions ? 1 : 0

  name             = "${var.name}-instance"
  sns_topic_arn    = var.sns_topic_arn
  source_type      = "replication-instance"
  source_ids       = [aws_dms_replication_instance.this[0].replication_instance_id]
  event_categories = var.instance_event_categories
  enabled          = true

  tags = local.common_tags
}

resource "aws_dms_event_subscription" "task" {
  count = local.create && local.provisioned && var.sns_topic_arn != "" && var.create_event_subscriptions && length(var.tasks) > 0 ? 1 : 0

  name          = "${var.name}-tasks"
  sns_topic_arn = var.sns_topic_arn
  source_type   = "replication-task"
  source_ids    = concat([for k, t in aws_dms_replication_task.this : t.replication_task_id], [for k, t in aws_dms_replication_task.validation : t.replication_task_id])
  # "state change" is the one that fires when a task stops on its own.
  event_categories = var.task_event_categories
  enabled          = true

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Alarms
#
# treat_missing_data = "breaching" on the CDC alarms is deliberate and is the
# most important line in this file. A stopped task publishes NO latency
# datapoints at all, so the default ("missing") leaves the alarm in INSUFFICIENT
# DATA - green on a dashboard - for as long as the task stays down. Treating
# silence as breaching turns "no data" into the alert it actually is.
# ---------------------------------------------------------------------------

locals {
  cdc_tasks = {
    for k, t in var.tasks : k => t
    if contains(["cdc", "full-load-and-cdc"], t.migration_type)
  }

  alarms_enabled = local.create && local.provisioned && var.create_alarms && var.sns_topic_arn != ""

  free_storage_alarm_bytes = var.alarm_free_storage_bytes > 0 ? var.alarm_free_storage_bytes : ceil(var.allocated_storage_gb * 1073741824 * 0.15)
}

resource "aws_cloudwatch_metric_alarm" "cdc_latency_target" {
  for_each = local.alarms_enabled ? local.cdc_tasks : {}

  alarm_name        = "${var.name}-${each.key}-cdc-latency-target"
  alarm_description = "CDC changes are reaching the target more than ${var.alarm_cdc_latency_seconds}s late, or the task has stopped publishing metrics entirely."

  namespace           = "AWS/DMS"
  metric_name         = "CDCLatencyTarget"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.alarm_cdc_latency_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    ReplicationInstanceIdentifier = aws_dms_replication_instance.this[0].replication_instance_id
    # The task's resource ID (last segment of its ARN), not its name - DMS
    # publishes task metrics under it. With the name the alarm never gets a
    # datapoint and, missing data being breaching, sits in ALARM for good.
    ReplicationTaskIdentifier = local.task_resource_ids[each.key]
  }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]
  tags          = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "cdc_latency_source" {
  for_each = local.alarms_enabled ? local.cdc_tasks : {}

  alarm_name        = "${var.name}-${each.key}-cdc-latency-source"
  alarm_description = "DMS is reading changes from the source more than ${var.alarm_cdc_latency_seconds}s behind. Usually the source, not DMS: log contention, a long transaction, or an undersized instance."

  namespace           = "AWS/DMS"
  metric_name         = "CDCLatencySource"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.alarm_cdc_latency_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    ReplicationInstanceIdentifier = aws_dms_replication_instance.this[0].replication_instance_id
    # The task's resource ID (last segment of its ARN), not its name - DMS
    # publishes task metrics under it. With the name the alarm never gets a
    # datapoint and, missing data being breaching, sits in ALARM for good.
    ReplicationTaskIdentifier = local.task_resource_ids[each.key]
  }

  alarm_actions = [var.sns_topic_arn]
  tags          = local.common_tags
}

# Validation. A mismatch, or validation suspending itself at FailureMaxCount,
# is the reconciliation evidence failing - quietly, unless something alarms.
# Silence is not breaching here: a task that validated everything and stopped
# publishes nothing, and that is the good outcome.
locals {
  validating_tasks = merge(
    { for k in keys(var.tasks) : "task:${k}" => { task_key = k, validation = false } if(try(local.task_settings_merged[k].ValidationSettings.EnableValidation, false) ? local.task_validation_feasible[k] : false) },
    { for k in keys(var.validation_tasks) : "validate:${k}" => { task_key = k, validation = true } },
  )

  validation_task_resource_ids = {
    for k, t in aws_dms_replication_task.validation : k => element(split(":", t.replication_task_arn), 6)
  }

  validation_alarms_enabled = local.alarms_enabled && var.create_validation_alarms
}

resource "aws_cloudwatch_metric_alarm" "validation_failed" {
  for_each = local.validation_alarms_enabled ? local.validating_tasks : {}

  alarm_name        = "${var.name}-${each.value.task_key}${each.value.validation ? "-validation" : ""}-validation-failed"
  alarm_description = "Rows in ${each.value.task_key} do not match between source and target (more than ${var.alarm_validation_failed_records}). The detail is in the control schema's awsdms_validation_failures table."

  namespace           = "AWS/DMS"
  metric_name         = "ValidationFailedOverallCount"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.alarm_validation_failed_records
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ReplicationInstanceIdentifier = aws_dms_replication_instance.this[0].replication_instance_id
    ReplicationTaskIdentifier     = each.value.validation ? local.validation_task_resource_ids[each.value.task_key] : local.task_resource_ids[each.value.task_key]
  }

  alarm_actions = [var.sns_topic_arn]
  tags          = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "validation_suspended" {
  for_each = local.validation_alarms_enabled ? local.validating_tasks : {}

  alarm_name        = "${var.name}-${each.value.task_key}${each.value.validation ? "-validation" : ""}-validation-suspended"
  alarm_description = "Validation of ${each.value.task_key} has suspended rows - it could not compare them, or hit its failure limit and stopped. The evidence for those rows does not exist."

  namespace           = "AWS/DMS"
  metric_name         = "ValidationSuspendedOverallCount"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ReplicationInstanceIdentifier = aws_dms_replication_instance.this[0].replication_instance_id
    ReplicationTaskIdentifier     = each.value.validation ? local.validation_task_resource_ids[each.value.task_key] : local.task_resource_ids[each.value.task_key]
  }

  alarm_actions = [var.sns_topic_arn]
  tags          = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "free_storage" {
  count = local.alarms_enabled ? 1 : 0

  alarm_name        = "${var.name}-free-storage"
  alarm_description = "Replication instance storage is running out. A full disk stops every task on this instance, and cached changes are lost."

  namespace           = "AWS/DMS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = local.free_storage_alarm_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    ReplicationInstanceIdentifier = aws_dms_replication_instance.this[0].replication_instance_id
  }

  alarm_actions = [var.sns_topic_arn]
  tags          = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "cpu" {
  count = local.alarms_enabled ? 1 : 0

  alarm_name        = "${var.name}-cpu"
  alarm_description = "Replication instance CPU is saturated, which shows up as growing CDC latency before it shows up as failure."

  namespace           = "AWS/DMS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.alarm_cpu_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ReplicationInstanceIdentifier = aws_dms_replication_instance.this[0].replication_instance_id
  }

  alarm_actions = [var.sns_topic_arn]
  tags          = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "freeable_memory" {
  count = local.alarms_enabled ? 1 : 0

  alarm_name        = "${var.name}-freeable-memory"
  alarm_description = "Replication instance memory is exhausted. DMS then swaps, and a full load that was going to take hours starts taking days."

  namespace           = "AWS/DMS"
  metric_name         = "FreeableMemory"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.alarm_freeable_memory_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ReplicationInstanceIdentifier = aws_dms_replication_instance.this[0].replication_instance_id
  }

  alarm_actions = [var.sns_topic_arn]
  tags          = local.common_tags
}

# ---------------------------------------------------------------------------
# Checks
#
# Warnings, not refusals. Postures the module will let you have but a reviewer
# should see at plan time.
# ---------------------------------------------------------------------------

check "somebody_hears_a_failed_task" {
  assert {
    condition = contains(local.acknowledged, "somebody_hears_a_failed_task") ? true : (
      !local.create ? true : (length(var.tasks) == 0 ? true : var.sns_topic_arn != "")
    )
    error_message = "sns_topic_arn is empty, so no event subscription and no alarm exists. A DMS task that stops does not retry and does not report anywhere: the target simply stops receiving changes while the source keeps taking writes."
  }
}

# Serverless gets no alarms, no event subscriptions and no log group from this
# module - DMS event subscriptions only carry source types for replication
# instances and tasks, and neither exists in that mode. Supplying an SNS topic
# does not change it, so the check above would otherwise pass while nothing at
# all is watching.
check "serverless_replication_is_not_watched_by_this_module" {
  assert {
    condition = contains(local.acknowledged, "serverless_replication_is_not_watched_by_this_module") ? true : (
      !local.create ? true : local.provisioned
    )
    error_message = "compute_mode is \"serverless\", and this module creates no alarms, no event subscriptions and no log group for it - every observability resource here is instance-scoped. A serverless replication that stops is invisible. Build monitoring on the AWS/DMS ReplicationConfigIdentifier dimension yourself, or use compute_mode = \"provisioned\" where the module can watch it."
  }
}

# The exception rows DMS writes when a row fails to apply contain the source
# data and the statement. With no control schema they land in the target's
# default schema - inside a production database, in scope for its backups.
check "control_tables_have_their_own_schema" {
  assert {
    condition = contains(local.acknowledged, "control_tables_have_their_own_schema") ? true : (
      !local.create ? true : length(local.tasks_with_default_control_schema) == 0
    )
    error_message = "these tasks write DMS control tables into the target's DEFAULT schema: ${join(", ", local.tasks_with_default_control_schema)}. awsdms_apply_exceptions holds the failing row's data and SQL, so in a regulated target that is production data in an unscoped table. Set settings.control_schema."
  }
}

# Row-level logs are a copy of the data. In a bank that is a different
# classification of log group from an operational one.
check "debug_logging_is_temporary" {
  assert {
    condition = contains(local.acknowledged, "debug_logging_is_temporary") ? true : (
      !local.create ? true : length([
        for k, t in var.tasks : k
        if contains(local.debug_logging_tasks, k)
      ]) == 0
    )
    error_message = "these tasks log at DEBUG or DETAILED_DEBUG, which writes row-level data and SQL statements into CloudWatch Logs. Fine while diagnosing something; not a committed setting."
  }
}

# DO_NOTHING creates nothing on the target. If the schema is not there, DMS
# suspends every table rather than failing the task outright - so it looks like
# a partial success.
check "the_target_schema_comes_from_somewhere" {
  assert {
    condition = contains(local.acknowledged, "the_target_schema_comes_from_somewhere") ? true : (
      !local.create ? true : length(local.tasks_assuming_a_prebuilt_target) == 0
    )
    error_message = "these tasks use target_table_prep_mode = DO_NOTHING with no pre_data script declared: ${join(", ", local.tasks_assuming_a_prebuilt_target)}. DMS will not create the target schema, and a missing table suspends that table instead of failing the task - which reads as a partial success. Declare the DDL in sql_scripts.pre_data, or say explicitly that the schema is built elsewhere."
  }
}

# A full load into a target whose triggers and foreign keys are live is slow at
# best and wrong at worst.
check "the_full_load_is_not_fighting_the_targets_constraints" {
  assert {
    condition = contains(local.acknowledged, "the_full_load_is_not_fighting_the_targets_constraints") ? true : (
      !local.create ? true : length(local.postgres_targets_without_load_guard) == 0
    )
    error_message = "these PostgreSQL targets have no after_connect_script: ${join(", ", local.postgres_targets_without_load_guard)}. During a full load their triggers fire and their foreign keys reject rows that arrive parent-last. Set postgres.after_connect_script = \"SET session_replication_role = replica;\" nothing needs restoring afterwards because it applies to DMS connections only (the DMS user needs the privilege to set it), or confirm the target has no triggers or FKs yet because post_data builds them."
  }
}

# A static byte threshold against a volume whose size is a variable.
check "the_storage_alarm_leaves_room_to_react" {
  assert {
    condition = contains(local.acknowledged, "the_storage_alarm_leaves_room_to_react") ? true : (
      !local.create || !local.provisioned ? true : (
        local.free_storage_alarm_bytes >= var.allocated_storage_gb * 1073741824 * 0.15
      )
    )
    error_message = "alarm_free_storage_bytes (${local.free_storage_alarm_bytes}) is under 15% of allocated_storage_gb (${var.allocated_storage_gb} GB). Cached changes accumulate fast when a target or a WAN link stalls, and a full disk stops every task on the instance. Raise the threshold or the volume."
  }
}

check "cdc_tasks_are_validated" {
  assert {
    condition = contains(local.acknowledged, "cdc_tasks_are_validated") ? true : (
      !local.create ? true : length(local.unvalidated_tasks) == 0
    )
    error_message = "validation is off for: ${join(", ", local.unvalidated_tasks)}. DMS row validation is the only thing that compares source and target after the load; without it \"the task succeeded\" means the rows were sent, not that they arrived intact."
  }
}

check "tasks_write_logs" {
  assert {
    condition = contains(local.acknowledged, "tasks_write_logs") ? true : (
      !local.create ? true : length(local.unlogged_tasks) == 0
    )
    error_message = "logging is off for: ${join(", ", local.unlogged_tasks)}. A failed task's reason is one line in the console and the detail is in CloudWatch - without logs a failure mid-load cannot be diagnosed after the fact."
  }
}

check "log_retention_is_bounded" {
  assert {
    condition = contains(local.acknowledged, "log_retention_is_bounded") ? true : (
      !local.create ? true : (local.provisioned ? var.log_retention_days > 0 : true)
    )
    error_message = "log_retention_days is 0, so DMS task logs never expire. A chatty CDC task at DEBUG produces gigabytes, and this log group outlives the migration by default."
  }
}

check "replication_survives_an_az" {
  assert {
    condition = contains(local.acknowledged, "replication_survives_an_az") ? true : (
      !local.create ? true : (local.provisioned ? var.multi_az : var.serverless.multi_az)
    )
    error_message = "multi_az is false. A single-AZ replication instance that fails mid-load restarts the full load from the beginning, and mid-CDC it loses cached changes - which on a large source can mean days. It doubles the compute cost; see COSTS.md."
  }
}

check "full_load_does_not_leave_the_meter_running" {
  assert {
    # A provisioned instance keeps billing after the one-off load finishes, and
    # nothing in DMS turns it off.
    condition = contains(local.acknowledged, "full_load_does_not_leave_the_meter_running") ? true : (
      !local.create ? true : (local.provisioned && length(var.tasks) > 0 ? anytrue([
        for k, t in var.tasks : contains(["cdc", "full-load-and-cdc"], t.migration_type)
      ]) : true)
    )
    error_message = "every task here is full-load only, on a provisioned instance. The load finishes, the instance keeps billing by the hour, and nothing in DMS stops it. Either plan the teardown now, or use compute_mode = \"serverless\"."
  }
}

check "engine_version_is_pinned" {
  assert {
    condition = contains(local.acknowledged, "engine_version_is_pinned") ? true : (
      !local.create ? true : (local.provisioned ? var.engine_version != "" : true)
    )
    error_message = "engine_version is empty, so AWS picks the default and moves it under you. DMS minor versions change replication behaviour; pin it for a migration you intend to repeat or audit."
  }
}

check "credentials_are_not_in_state" {
  assert {
    condition = contains(local.acknowledged, "credentials_are_not_in_state") ? true : (
      !local.create ? true : length(local.plaintext_endpoints) == 0
    )
    error_message = "these endpoints hold a plaintext credential in Terraform state: ${join(", ", local.plaintext_endpoints)}. Anyone with state access has your database. Move them to Secrets Manager."
  }
}

check "transport_is_verified" {
  assert {
    condition = contains(local.acknowledged, "transport_is_verified") ? true : (
      !local.create ? true : length(local.cleartext_endpoints) == 0
    )
    error_message = "these endpoints use ssl_mode = \"none\": ${join(", ", local.cleartext_endpoints)}. Credentials and every migrated row cross the network in cleartext."
  }
}

# A pinned engine_version with automatic minor upgrades: after AWS upgrades the
# instance, the next plan tries to move it back, and DMS refuses a downgrade.
check "minor_upgrades_do_not_fight_the_pin" {
  assert {
    condition = contains(local.acknowledged, "minor_upgrades_do_not_fight_the_pin") ? true : (
      !local.create ? true : (local.provisioned ? !(var.engine_version != "" && var.auto_minor_version_upgrade) : true)
    )
    error_message = "engine_version ${var.engine_version} is pinned and auto_minor_version_upgrade is on. After AWS applies a minor upgrade, every plan tries to set the old version back and the apply fails. Turn automatic upgrades off and move engine_version yourself, or raise it after each maintenance window."
  }
}

# Oracle SSL in DMS works from an Oracle wallet, not a PEM CA bundle.
check "oracle_ssl_uses_a_wallet" {
  assert {
    condition = contains(local.acknowledged, "oracle_ssl_uses_a_wallet") ? true : (
      !local.create ? true : length(local.oracle_endpoints_with_pem) == 0
    )
    error_message = "these Oracle endpoints verify TLS with a PEM certificate: ${join(", ", local.oracle_endpoints_with_pem)}. DMS expects an Oracle wallet for Oracle SSL - put it in certificates[*].wallet (base64 of cwallet.sso)."
  }
}

# EnableValidation on an engine DMS cannot validate is accepted and does
# nothing. Without this, governance would show a reconciliation that never ran.
check "validation_is_claimed_where_it_cannot_run" {
  assert {
    condition = contains(local.acknowledged, "validation_is_claimed_where_it_cannot_run") ? true : (
      !local.create ? true : length(local.tasks_whose_validation_cannot_run) == 0
    )
    error_message = "these tasks have validation on, but DMS cannot validate them: ${join(", ", local.tasks_whose_validation_cannot_run)}. DMS validates Oracle, PostgreSQL, MySQL/MariaDB/Aurora MySQL, SQL Server and Db2 LUW sources, the same targets plus Redshift, and S3 targets only as parquet with a timestamp column and a date partition by day. Reconcile another way, and turn validation off so governance does not report it."
  }
}
