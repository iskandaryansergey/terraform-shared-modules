# The failure this file exists for: the writer fails over, or runs out of local
# storage, or PostgreSQL creeps toward transaction ID wraparound, and nothing
# anywhere goes red.
#
# Everything here is switched by create_alarms and create_event_subscriptions -
# booleans, known at plan - and needs sns_topic_arn (a precondition on the
# cluster). A topic created in the same configuration is unknown at plan, and
# would make count unknown if it decided anything.

resource "aws_cloudwatch_log_group" "this" {
  for_each = local.create_log_groups ? local.log_group_names : {}

  name              = each.value
  retention_in_days = var.log_retention_days
  kms_key_id        = local.logs_kms_key_arn != "" ? local.logs_kms_key_arn : null
  log_group_class   = var.log_group_class
  skip_destroy      = var.log_group_skip_destroy

  tags = local.common_tags
}

resource "aws_db_event_subscription" "cluster" {
  count = local.events_enabled ? 1 : 0

  name             = "${var.name}-cluster"
  sns_topic        = var.sns_topic_arn
  source_type      = "db-cluster"
  source_ids       = [aws_rds_cluster.this[0].cluster_identifier]
  event_categories = var.cluster_event_categories
  enabled          = true

  tags = local.common_tags
}

# Only the instances in var.instances. Replicas added by reader autoscaling are
# named application-autoscaling-<uuid>, and a subscription takes explicit IDs
# only - there is no way to follow them by cluster. The reader CPU and replica
# lag alarms read cluster-level metrics, so those do include them.
resource "aws_db_event_subscription" "instances" {
  count = local.events_enabled && length(local.instances) > 0 ? 1 : 0

  name             = "${var.name}-instances"
  sns_topic        = var.sns_topic_arn
  source_type      = "db-instance"
  source_ids       = [for i in values(local.instances) : i.identifier]
  event_categories = var.instance_event_categories
  enabled          = true

  tags = local.common_tags

  depends_on = [aws_rds_cluster_instance.this]
}

# ---------------------------------------------------------------------------
# Alarms
#
# Aurora publishes most metrics three ways: per instance (DBInstanceIdentifier),
# per role (DBClusterIdentifier + Role), and per cluster. A cluster average hides
# a saturated writer behind idle readers, so CPU and connections read the
# WRITER role, and memory and local storage are per instance because either
# one running out takes down that instance alone.
#
# A global secondary has no writer: everything it runs is a READER. The
# writer-only alarms are not created there, and its CPU alarm reads the READER
# role instead.
#
# treat_missing_data = "breaching" on the main CPU alarm is deliberate. An
# instance that is down publishes nothing, and "missing" would show that as
# green. The one exception is a serverless cluster that pauses: paused
# publishes nothing too, and is fine.
# ---------------------------------------------------------------------------

locals {
  writer_dimensions = { DBClusterIdentifier = var.name, Role = "WRITER" }
  reader_dimensions = { DBClusterIdentifier = var.name, Role = "READER" }

  instance_alarms_enabled = local.alarms_enabled && length(local.instances) > 0
  writer_alarms_enabled   = local.instance_alarms_enabled && !local.is_secondary
  main_cpu_missing_data   = local.auto_pause ? "notBreaching" : "breaching"
}

resource "aws_cloudwatch_metric_alarm" "writer_cpu" {
  count = local.writer_alarms_enabled ? 1 : 0

  alarm_name        = "${var.name}-writer-cpu"
  alarm_description = "Writer CPU above ${var.alarm_cpu_percent}% for 15 minutes, or the writer has stopped publishing metrics. Every write and every query on the cluster endpoint is queued behind it."

  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.alarm_cpu_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = local.main_cpu_missing_data
  dimensions          = local.writer_dimensions

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]
  tags          = local.common_tags

  depends_on = [aws_rds_cluster_instance.this]
}

# On a primary or regional cluster: the readers, when there are any. On a
# global secondary: the only CPU alarm, and silence there is an outage.
resource "aws_cloudwatch_metric_alarm" "reader_cpu" {
  count = local.instance_alarms_enabled && (local.is_secondary ? true : local.has_readers) ? 1 : 0

  alarm_name        = "${var.name}-reader-cpu"
  alarm_description = local.is_secondary ? "Secondary-region CPU above ${var.alarm_cpu_percent}% for 15 minutes, or its instances have stopped publishing metrics." : "Average reader CPU above ${var.alarm_cpu_percent}% for 15 minutes. Reads on the reader endpoint slow down; with reader autoscaling this should have added a replica."

  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.alarm_cpu_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = local.is_secondary ? local.main_cpu_missing_data : "notBreaching"
  dimensions          = local.reader_dimensions

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = local.is_secondary ? [var.sns_topic_arn] : []
  tags          = local.common_tags

  depends_on = [aws_rds_cluster_instance.this]
}

resource "aws_cloudwatch_metric_alarm" "freeable_memory" {
  for_each = local.instance_alarms_enabled ? local.instances : {}

  alarm_name        = "${var.name}-${each.key}-freeable-memory"
  alarm_description = "${each.value.identifier} has less than ${floor(var.alarm_freeable_memory_bytes / 1048576)} MiB freeable memory. Aurora restarts an instance that runs out."

  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.alarm_freeable_memory_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { DBInstanceIdentifier = each.value.identifier }

  alarm_actions = [var.sns_topic_arn]
  tags          = local.common_tags

  depends_on = [aws_rds_cluster_instance.this]
}

# Not for db.serverless: AWS does not publish FreeLocalStorage for it, so the
# alarm would sit on no data forever.
resource "aws_cloudwatch_metric_alarm" "free_local_storage" {
  for_each = local.instance_alarms_enabled ? { for k, i in local.instances : k => i if i.instance_class != "db.serverless" } : {}

  alarm_name        = "${var.name}-${each.key}-free-local-storage"
  alarm_description = "${each.value.identifier} has less than ${floor(var.alarm_free_local_storage_bytes / 1073741824)} GiB local storage. It holds temp tables, sorts and logs; when it fills, queries that need it fail."

  namespace           = "AWS/RDS"
  metric_name         = "FreeLocalStorage"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.alarm_free_local_storage_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { DBInstanceIdentifier = each.value.identifier }

  alarm_actions = [var.sns_topic_arn]
  tags          = local.common_tags

  depends_on = [aws_rds_cluster_instance.this]
}

resource "aws_cloudwatch_metric_alarm" "replica_lag" {
  count = local.writer_alarms_enabled && local.has_readers ? 1 : 0

  alarm_name        = "${var.name}-replica-lag"
  alarm_description = "The slowest reader is more than ${var.alarm_replica_lag_ms} ms behind the writer. Reads on the reader endpoint return stale data."

  namespace           = "AWS/RDS"
  metric_name         = "AuroraReplicaLagMaximum"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = var.alarm_replica_lag_ms
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  # Published by the writer, about every reader.
  dimensions = local.writer_dimensions

  alarm_actions = [var.sns_topic_arn]
  tags          = local.common_tags

  depends_on = [aws_rds_cluster_instance.this]
}

resource "aws_cloudwatch_metric_alarm" "acu_utilization" {
  for_each = local.instance_alarms_enabled ? toset(local.serverless_instances) : toset([])

  alarm_name        = "${var.name}-${each.key}-acu-utilization"
  alarm_description = "${local.instances[each.key].identifier} is above ${var.alarm_acu_utilization_percent}% of max_capacity (${var.serverlessv2_scaling_configuration.max_capacity} ACU). At 100% it cannot scale further."

  namespace           = "AWS/RDS"
  metric_name         = "ACUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.alarm_acu_utilization_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { DBInstanceIdentifier = local.instances[each.key].identifier }

  alarm_actions = [var.sns_topic_arn]
  tags          = local.common_tags

  depends_on = [aws_rds_cluster_instance.this]
}

resource "aws_cloudwatch_metric_alarm" "connections" {
  count = local.writer_alarms_enabled && var.alarm_connections > 0 ? 1 : 0

  alarm_name        = "${var.name}-writer-connections"
  alarm_description = "Writer connections above ${var.alarm_connections}. Past max_connections new connections are refused."

  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.alarm_connections
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = local.writer_dimensions

  alarm_actions = [var.sns_topic_arn]
  tags          = local.common_tags

  depends_on = [aws_rds_cluster_instance.this]
}

# Silent, late and expensive, in that order: wraparound gives no symptom until
# PostgreSQL refuses every write, and the fix is a vacuum that can take hours.
resource "aws_cloudwatch_metric_alarm" "transaction_ids" {
  count = local.writer_alarms_enabled && local.is_postgres ? 1 : 0

  alarm_name        = "${var.name}-transaction-id-age"
  alarm_description = "Oldest unvacuumed transaction ID is above ${var.alarm_transaction_ids}. At about 2.1 billion PostgreSQL stops accepting writes. Look for a long-running transaction, an abandoned replication slot or a blocked autovacuum."

  namespace           = "AWS/RDS"
  metric_name         = "MaximumUsedTransactionIDs"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.alarm_transaction_ids
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = local.writer_dimensions

  alarm_actions = [var.sns_topic_arn]
  tags          = local.common_tags

  depends_on = [aws_rds_cluster_instance.this]
}

resource "aws_cloudwatch_metric_alarm" "volume_bytes" {
  count = local.alarms_enabled && var.alarm_volume_bytes > 0 ? 1 : 0

  alarm_name        = "${var.name}-volume-size"
  alarm_description = "Cluster volume above ${floor(var.alarm_volume_bytes / 1073741824)} GiB. A cost tripwire: storage is billed per GB-month."

  namespace           = "AWS/RDS"
  metric_name         = "VolumeBytesUsed"
  statistic           = "Maximum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = var.alarm_volume_bytes
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { DBClusterIdentifier = var.name }

  alarm_actions = [var.sns_topic_arn]
  tags          = local.common_tags

  depends_on = [aws_rds_cluster.this]
}

# A secondary's whole purpose is the data it holds when the primary region is
# gone. AuroraGlobalDBRPOLag is how much it would not hold: committed
# transactions not yet stored here. Published only in the secondary region.
#
# A Metrics Insights query rather than fixed dimensions: AWS does not document
# whether this metric carries SourceRegion as well as DBClusterIdentifier, and
# an alarm on the wrong dimension set reads no data - permanently green. The
# query matches the cluster whichever set it is published with.
#
# Silence is breaching: a secondary that stops reporting lag is the case the
# alarm exists for. Not on a headless secondary, where AWS does not document
# whether the metric is published at all - there silence is left as
# INSUFFICIENT_DATA rather than a page that may never clear.
resource "aws_cloudwatch_metric_alarm" "global_rpo_lag" {
  count = local.alarms_enabled && local.is_secondary ? 1 : 0

  alarm_name        = "${var.name}-global-rpo-lag"
  alarm_description = "This secondary is more than ${var.alarm_global_rpo_lag_ms} ms behind the primary region for committed transactions, or has stopped reporting. That gap is what a regional failover loses."

  evaluation_periods  = 5
  threshold           = var.alarm_global_rpo_lag_ms
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = length(local.instances) > 0 ? "breaching" : "missing"

  metric_query {
    id          = "rpo_lag"
    expression  = "SELECT MAX(AuroraGlobalDBRPOLag) FROM \"AWS/RDS\" WHERE DBClusterIdentifier = '${var.name}'"
    period      = 60
    return_data = true
  }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]
  tags          = local.common_tags

  depends_on = [aws_rds_cluster.this]
}
