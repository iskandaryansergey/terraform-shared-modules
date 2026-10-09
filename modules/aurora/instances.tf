# One resource, keyed by the caller's instance keys, so adding or removing an
# instance touches only that instance.
#
# Which instance becomes the writer: AWS makes the first one to finish creating
# the writer, and instances are created in parallel. promotion_tier orders
# failover, not initial placement. To put the writer on a given instance, fail
# over to it after apply - output.verify_commands.move_the_writer.

resource "aws_rds_cluster_instance" "this" {
  for_each = local.create ? local.instances : {}

  identifier = each.value.identifier
  # By name, not id: see main.tf. A cluster replacement must not plan these
  # for replacement too.
  cluster_identifier = aws_rds_cluster.this[0].cluster_identifier
  engine             = var.engine
  # engine_version is left to the cluster. Setting it here as well gives two
  # places for an upgrade to disagree.
  instance_class    = each.value.instance_class
  availability_zone = each.value.availability_zone != "" ? each.value.availability_zone : null
  promotion_tier    = each.value.promotion_tier

  db_subnet_group_name    = local.db_subnet_group_name
  db_parameter_group_name = local.db_parameter_group_name
  publicly_accessible     = var.publicly_accessible
  ca_cert_identifier      = each.value.ca_cert_identifier

  auto_minor_version_upgrade   = var.auto_minor_version_upgrade
  apply_immediately            = var.apply_immediately
  preferred_maintenance_window = each.value.preferred_maintenance_window

  monitoring_interval = var.enhanced_monitoring_interval
  monitoring_role_arn = local.monitoring_role_arn

  # The same values as the cluster. AWS applies a cluster-level setting to every
  # instance, so a per-instance difference would only ever be drift.
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_enabled ? var.performance_insights_retention_days : null
  performance_insights_kms_key_id       = var.performance_insights_enabled ? (local.performance_insights_kms_key != "" ? local.performance_insights_kms_key : null) : null

  copy_tags_to_snapshot = var.copy_tags_to_snapshot

  tags = merge(var.tags, each.value.tags, local.module_tags, { "Name" = each.value.identifier })

  timeouts {
    create = var.timeouts.create
    update = var.timeouts.update
    delete = var.timeouts.delete
  }

  lifecycle {
    # AWS fixes the Performance Insights key once it is set - see the
    # performance_insights_key_is_the_one_configured check.
    ignore_changes = [performance_insights_kms_key_id]
  }
}

resource "aws_rds_cluster_endpoint" "this" {
  for_each = local.create ? var.custom_endpoints : {}

  cluster_identifier          = aws_rds_cluster.this[0].cluster_identifier
  cluster_endpoint_identifier = "${var.name}-${each.key}"
  custom_endpoint_type        = each.value.type

  # Identifiers are built from keys rather than read from the instance
  # resources, so an unknown key reaches the precondition below instead of
  # failing as an invalid index first.
  static_members   = length(each.value.static_members) > 0 ? [for m in each.value.static_members : "${var.name}-${m}"] : null
  excluded_members = length(each.value.excluded_members) > 0 ? [for m in each.value.excluded_members : "${var.name}-${m}"] : null

  tags = merge(local.common_tags, { "Name" = "${var.name}-${each.key}" })

  depends_on = [aws_rds_cluster_instance.this]

  lifecycle {
    precondition {
      condition     = length(local.custom_endpoint_unknown_members) == 0
      error_message = "custom_endpoints name members that are not keys of var.instances (endpoint:member): ${join(", ", local.custom_endpoint_unknown_members)}."
    }
  }
}

# ---------------------------------------------------------------------------
# Reader autoscaling
#
# Scaled replicas are created by Application Auto Scaling, not Terraform. They
# use the writer's instance class and parameter group, and the cluster cannot
# be deleted until they are gone - set min_capacity and max_capacity to 0,
# apply, wait for the replicas to go, then destroy.
# ---------------------------------------------------------------------------

resource "aws_appautoscaling_target" "readers" {
  count = local.create && var.reader_autoscaling.enabled ? 1 : 0

  service_namespace  = "rds"
  scalable_dimension = "rds:cluster:ReadReplicaCount"
  resource_id        = "cluster:${aws_rds_cluster.this[0].cluster_identifier}"
  min_capacity       = var.reader_autoscaling.min_capacity
  max_capacity       = var.reader_autoscaling.max_capacity

  tags = local.common_tags

  # Scaling needs a writer to copy.
  depends_on = [aws_rds_cluster_instance.this]
}

resource "aws_appautoscaling_policy" "readers" {
  count = local.create && var.reader_autoscaling.enabled ? 1 : 0

  name               = "${var.name}-readers"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.readers[0].service_namespace
  scalable_dimension = aws_appautoscaling_target.readers[0].scalable_dimension
  resource_id        = aws_appautoscaling_target.readers[0].resource_id

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = var.reader_autoscaling.metric
    }
    target_value       = var.reader_autoscaling.target_value
    scale_in_cooldown  = var.reader_autoscaling.scale_in_cooldown
    scale_out_cooldown = var.reader_autoscaling.scale_out_cooldown
    disable_scale_in   = var.reader_autoscaling.disable_scale_in
  }
}
