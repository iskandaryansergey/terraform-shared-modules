resource "aws_cloudwatch_log_group" "this" {
  count = local.create_log_group ? 1 : 0

  name              = local.log_group_name
  retention_in_days = var.logging.retention_days
  kms_key_id        = local.logs_kms_key_arn != "" ? local.logs_kms_key_arn : null
  log_group_class   = var.logging.log_group_class
  skip_destroy      = var.logging.skip_destroy

  tags = local.common_tags
}
