# Provisioned mode only. In serverless mode the same map becomes
# aws_dms_replication_config - see replication.tf.

resource "aws_dms_replication_task" "this" {
  for_each = local.create && local.provisioned ? var.tasks : {}

  replication_task_id      = "${var.name}-${each.key}"
  replication_instance_arn = aws_dms_replication_instance.this[0].replication_instance_arn
  migration_type           = each.value.migration_type

  source_endpoint_arn = local.endpoint_arns[each.value.source_endpoint]
  target_endpoint_arn = local.endpoint_arns[each.value.target_endpoint]

  table_mappings = each.value.table_mappings
  # Rendered from typed inputs in locals, because DMS ignores keys it does not
  # recognise here without saying so.
  replication_task_settings = local.task_settings_json[each.key]

  cdc_start_time     = each.value.cdc_start_time != "" ? each.value.cdc_start_time : null
  cdc_start_position = each.value.cdc_start_position != "" ? each.value.cdc_start_position : null

  # false leaves the task created and stopped, which is the right default: a
  # task that starts on apply begins writing to the target the moment the plan
  # is approved.
  start_replication_task = each.value.start

  tags = merge(local.common_tags, { "MigrationType" = each.value.migration_type })

  # Every precondition that used to live here is now on
  # aws_dms_replication_subnet_group: this resource has zero instances in
  # serverless mode, and a precondition on zero instances never runs - so the
  # destructive-target-prep gate was unenforceable for half the module.
}
