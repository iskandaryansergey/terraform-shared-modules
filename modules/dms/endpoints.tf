# Credentials are the reason this file is shaped the way it is.
#
# username/password on a DMS endpoint are stored in Terraform state in
# plaintext and returned by DescribeEndpoints to anyone with the API permission.
# The supported path is a Secrets Manager secret that DMS reads itself, through
# a role scoped to that one secret - see iam.tf.

resource "aws_dms_endpoint" "this" {
  for_each = local.create ? var.endpoints : {}

  endpoint_id   = each.key
  endpoint_type = each.value.role
  engine_name   = each.value.engine

  # With a secret, DMS takes the host, port and credential FROM the secret, and
  # the provider rejects those fields as conflicting. They stay in the variable
  # because output.network_contract still has to tell the network team which
  # host and port to open. The database name is NOT in the secret DMS reads
  # (host, port, username, password). The provider sends database_name on the
  # secret path for every engine EXCEPT the MySQL family (aurora, mysql,
  # mariadb), whose secret branch carries only the secret fields.
  server_name   = each.value.secret_arn == "" && each.value.server_name != "" ? each.value.server_name : null
  port          = each.value.secret_arn == "" && each.value.port != 0 ? each.value.port : null
  database_name = each.value.database_name != "" ? each.value.database_name : null

  secrets_manager_arn             = each.value.secret_arn != "" ? each.value.secret_arn : null
  secrets_manager_access_role_arn = each.value.secret_arn != "" ? local.endpoint_secret_role_arns[each.key] : null
  username                        = each.value.secret_arn == "" && each.value.username != "" ? each.value.username : null
  password                        = each.value.secret_arn == "" && each.value.password != "" ? each.value.password : null

  ssl_mode        = each.value.ssl_mode
  certificate_arn = local.endpoint_certificate_arns[each.key] != "" ? local.endpoint_certificate_arns[each.key] : null

  kms_key_arn = each.value.kms_key_arn != "" ? each.value.kms_key_arn : (var.kms_key_arn != "" ? var.kms_key_arn : null)

  extra_connection_attributes = each.value.extra_connection_attributes != "" ? each.value.extra_connection_attributes : null

  # PostgreSQL CDC only behaves with these. The heartbeat in particular keeps
  # the replication slot advancing on a quiet source, which is what stops WAL
  # accumulating on the database you are migrating away from.
  # Two shapes, because most of these are source-only. heartbeat_*, slot_name
  # and capture_ddls applied to a TARGET make DMS try to create a heartbeat
  # table in the database you are migrating into.
  dynamic "postgres_settings" {
    for_each = contains(["postgres", "aurora-postgresql"], each.value.engine) && each.value.role == "source" ? [1] : []

    content {
      heartbeat_enable             = each.value.postgres.heartbeat_enable
      heartbeat_frequency          = each.value.postgres.heartbeat_frequency
      heartbeat_schema             = each.value.postgres.heartbeat_schema
      capture_ddls                 = each.value.postgres.capture_ddls
      slot_name                    = each.value.postgres.slot_name != "" ? each.value.postgres.slot_name : null
      map_boolean_as_boolean       = each.value.postgres.map_boolean_as_boolean
      fail_tasks_on_lob_truncation = each.value.postgres.fail_tasks_on_lob_truncation
      after_connect_script         = each.value.postgres.after_connect_script != "" ? each.value.postgres.after_connect_script : null
      execute_timeout              = each.value.postgres.execute_timeout
    }
  }

  # Target side. after_connect_script is the one real pre-data hook DMS has: it
  # runs on every connection DMS opens to the target, which is where
  # "SET session_replication_role = replica" belongs - that is what stops
  # triggers firing and foreign keys rejecting rows that arrive parent-last
  # during a full load. Everything else that has to be true of the target before
  # the load - the schema itself - is your pipeline's job; this module runs no SQL.
  dynamic "postgres_settings" {
    for_each = contains(["postgres", "aurora-postgresql"], each.value.engine) && each.value.role == "target" ? [1] : []

    content {
      map_boolean_as_boolean       = each.value.postgres.map_boolean_as_boolean
      fail_tasks_on_lob_truncation = each.value.postgres.fail_tasks_on_lob_truncation
      after_connect_script         = each.value.postgres.after_connect_script != "" ? each.value.postgres.after_connect_script : null
      execute_timeout              = each.value.postgres.execute_timeout
      max_file_size                = each.value.postgres.max_file_size
    }
  }

  tags = merge(local.common_tags, { "EndpointRole" = each.value.role })

  # The role's ARN alone does not order the endpoint after the role's policy;
  # a task started on the first apply could reach for the secret before it is
  # readable.
  depends_on = [aws_iam_role_policy.endpoint_secret]

  lifecycle {
    # The provider (5.x) sends postgres_settings on create only - its update
    # path never reads them. Without this an edit to after_connect_script or
    # the heartbeat applies "successfully", changes nothing in DMS, and plans
    # the same diff forever. Replacing the endpoint is the only way the change
    # lands; the plan then also shows every task on it being replaced, which
    # is the true cost.
    replace_triggered_by = [terraform_data.postgres_settings[each.key]]

    # The credential and transport gates are module-wide and live on the subnet
    # group, which exists in every compute mode - a precondition here would not
    # run for an S3-only migration.
    precondition {
      condition     = var.require_cmk ? length(local.endpoints_without_cmk) == 0 : true
      error_message = "require_cmk = true but these endpoints resolve to the AWS-managed DMS key: ${join(", ", local.endpoints_without_cmk)}. Set kms_key_arn on the module or on the endpoint."
    }
  }
}

# The PostgreSQL settings each endpoint was created with, so a change to them
# replaces the endpoint (see the lifecycle above). Empty for other engines, so
# they never churn.
resource "terraform_data" "postgres_settings" {
  for_each = local.create ? var.endpoints : {}

  # Only the fields the matching dynamic block sends, so editing a source-only
  # knob on a target endpoint does not replace it.
  # Each branch is encoded on its own: a conditional over two object shapes
  # would convert both to a common type first.
  input = !contains(["postgres", "aurora-postgresql"], each.value.engine) ? "" : sha256(
    # max_file_size is target-only and left out of the source hash, so adding
    # the field does not replace existing source endpoints.
    each.value.role == "source" ? jsonencode({ for k, v in each.value.postgres : k => v if k != "max_file_size" }) : jsonencode({
      map_boolean_as_boolean       = each.value.postgres.map_boolean_as_boolean
      fail_tasks_on_lob_truncation = each.value.postgres.fail_tasks_on_lob_truncation
      after_connect_script         = each.value.postgres.after_connect_script
      execute_timeout              = each.value.postgres.execute_timeout
      max_file_size                = each.value.postgres.max_file_size
    })
  )
}

# ---------------------------------------------------------------------------
# S3 targets
#
# A separate resource with a separate shape. Parquet by default because CSV
# discards every type the source had, and the thing reading this later has to
# guess them back.
# ---------------------------------------------------------------------------
resource "aws_dms_s3_endpoint" "this" {
  for_each = local.create ? var.s3_targets : {}

  endpoint_id   = each.key
  endpoint_type = "target"

  bucket_name   = each.value.bucket_name
  bucket_folder = each.value.bucket_folder != "" ? each.value.bucket_folder : null

  service_access_role_arn = local.s3_target_role_arns[each.key]

  data_format      = each.value.data_format
  compression_type = each.value.compression_type
  parquet_version  = each.value.data_format == "parquet" ? each.value.parquet_version : null

  encryption_mode                   = each.value.encryption_mode
  server_side_encryption_kms_key_id = each.value.encryption_mode == "SSE_KMS" && each.value.kms_key_arn != "" ? each.value.kms_key_arn : null

  # Without partitioning, a CDC stream becomes one flat prefix that every
  # consumer has to scan in full.
  date_partition_enabled  = each.value.date_partition_enabled
  date_partition_sequence = each.value.date_partition_enabled ? each.value.date_partition_sequence : null
  cdc_path                = each.value.cdc_path != "" ? each.value.cdc_path : null

  # Which operation produced the row, and when it landed. Without both, a
  # downstream consumer cannot tell a delete from an absence.
  include_op_for_full_load = each.value.include_op_for_full_load
  timestamp_column_name    = each.value.timestamp_column_name != "" ? each.value.timestamp_column_name : null

  glue_catalog_generation = each.value.glue_catalog_generation

  tags = merge(local.common_tags, { "EndpointRole" = "target" })

  # Ordered after the policy, not just the role: the first write must not race it.
  depends_on = [aws_iam_role_policy.s3_target]

  lifecycle {
    precondition {
      condition     = var.require_cmk ? length(local.s3_targets_without_cmk) == 0 : true
      error_message = "require_cmk = true but these S3 targets are not encrypted with a customer-managed key: ${join(", ", local.s3_targets_without_cmk)}. Set encryption_mode = \"SSE_KMS\" and kms_key_arn."
    }
  }
}

# CA certificates for ssl_mode verify-ca and verify-full. For RDS this is the
# regional CA bundle; for an on-prem source, whatever signed its certificate.
# The PEM and the wallet are immutable on the certificate (the provider
# replaces it), and Terraform deletes the old certificate BEFORE it updates
# the endpoints that reference it. With a fixed id that is an in-use
# certificate being deleted mid-apply. So the id carries a digest of the
# content and the new certificate is created first: a CA rotation is then
# create new, repoint endpoints, delete old - in one apply.
resource "aws_dms_certificate" "this" {
  for_each = local.create ? var.certificates : {}

  certificate_id     = "${var.name}-${each.key}-${local.certificate_digests[each.key]}"
  certificate_pem    = each.value.pem != "" ? each.value.pem : null
  certificate_wallet = each.value.wallet != "" ? each.value.wallet : null

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}
