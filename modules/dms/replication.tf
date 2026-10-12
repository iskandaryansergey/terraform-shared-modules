# The subnet group exists in both compute modes and is the one resource that is
# always present, so module-wide invariants are checked here.
resource "aws_dms_replication_subnet_group" "this" {
  count = local.create ? 1 : 0

  replication_subnet_group_id          = local.subnet_group_id
  replication_subnet_group_description = "Subnet group for the ${var.name} migration"
  subnet_ids                           = var.subnet_ids

  tags = local.common_tags

  lifecycle {
    precondition {
      # Tasks address endpoints and S3 targets through one key space, so a
      # collision would silently resolve to whichever map won the merge.
      condition     = length(local.duplicate_endpoint_keys) == 0
      error_message = "these keys appear in both endpoints and s3_targets: ${join(", ", local.duplicate_endpoint_keys)}. Tasks look endpoints up by key, so the names have to be unique across both maps."
    }

    precondition {
      # dms-vpc-role, which the subnet group also needs, is looked up by the
      # account_service_roles_exist check in observability.tf.
      condition     = length(var.subnet_ids) >= 2
      error_message = "DMS needs at least two subnets in different availability zones, even for a single-AZ replication instance."
    }

    # Everything below is a MODULE-WIDE invariant and lives here on purpose.
    # A precondition on a resource with zero instances never runs, and both
    # aws_dms_replication_task and aws_dms_endpoint are empty in some valid
    # configuration - serverless mode and an S3-only migration respectively.
    # This subnet group is the one resource present in every mode.
    precondition {
      condition     = length(local.tasks_with_unknown_endpoints) == 0
      error_message = "these tasks name an endpoint that does not exist: ${join(", ", local.tasks_with_unknown_endpoints)}. source_endpoint and target_endpoint are keys from endpoints or s3_targets."
    }

    precondition {
      condition     = length(local.tasks_with_wrong_direction) == 0
      error_message = "these tasks use an endpoint in the wrong direction: ${join(", ", local.tasks_with_wrong_direction)}. An endpoint with role = \"target\" cannot be a task's source, and an S3 target is target-only by construction."
    }

    precondition {
      condition     = length(local.destructive_tasks) == 0 ? true : var.allow_destructive_target_prep
      error_message = "these tasks delete data in the target before loading: ${join(", ", local.destructive_tasks)}. TRUNCATE_BEFORE_LOAD empties the table; DROP_AND_CREATE also discards the indexes, constraints and grants the target had. Set allow_destructive_target_prep = true if the target is genuinely disposable. Note this reads the MERGED settings, so a raw_overrides cannot slip past it."
    }

    precondition {
      condition = length([
        for k, t in var.tasks : k
        if(t.cdc_start_time != "" || t.cdc_start_position != "") && !contains(["cdc", "full-load-and-cdc"], t.migration_type)
      ]) == 0
      error_message = "a task sets a CDC start point but its migration_type never reads changes, so the setting would be silently ignored."
    }

    precondition {
      condition     = var.premigration_assessment.enabled ? local.provisioned : true
      error_message = "premigration_assessment runs against a replication task, so it needs compute_mode = \"provisioned\". For serverless, use aws dms start-replication with --premigration-assessment-settings."
    }

    precondition {
      condition     = var.require_cmk && var.premigration_assessment.enabled ? var.premigration_assessment.kms_key_arn != "" : true
      error_message = "require_cmk = true but premigration_assessment.kms_key_arn is empty: the assessment reports, which describe the source schema and data types, would be encrypted with SSE_S3."
    }

    precondition {
      condition     = length(var.validation_tasks) == 0 ? true : local.provisioned
      error_message = "validation_tasks need compute_mode = \"provisioned\": a validation-only task runs on a replication instance."
    }

    precondition {
      condition     = length(local.validation_tasks_with_bad_parent) == 0
      error_message = "these validation tasks cannot run: ${join("; ", local.validation_tasks_with_bad_parent)}."
    }

    precondition {
      condition     = length(local.tasks_with_batch_apply_to_s3) == 0
      error_message = "these tasks enable batch apply into an S3 target: ${join(", ", local.tasks_with_batch_apply_to_s3)}. DMS does not support BatchApplyEnabled for S3 and documents that it can lose data. Set batch_apply_enabled = false for them."
    }

    precondition {
      condition     = length(local.tasks_with_full_lob_to_s3) == 0
      error_message = "these tasks write to an S3 target in full LOB mode: ${join(", ", local.tasks_with_full_lob_to_s3)}. DMS does not support full LOB mode (lob_mode FULL or INLINE) for S3. Use lob_mode = \"LIMITED\" with lob_max_size_kb above the largest LOB in the source."
    }

    precondition {
      # aws_dms_replication_config has no CDC start argument: the setting would
      # be dropped without a word.
      condition = local.serverless ? length([
        for k, t in var.tasks : k if t.cdc_start_time != "" || t.cdc_start_position != ""
      ]) == 0 : true
      error_message = "cdc_start_time and cdc_start_position are not supported in serverless mode - aws_dms_replication_config has no such argument, so the start point would be ignored. Start the replication with aws dms start-replication --cdc-start-position, or use compute_mode = \"provisioned\"."
    }

    precondition {
      # The log group is the one place require_cmk can reach task logs. Without
      # it DMS creates dms-tasks-<id> itself, with the AWS-managed key and no
      # expiry.
      condition     = var.require_cmk && local.provisioned ? (var.create_log_group ? var.log_retention_days > 0 : false) : true
      error_message = "require_cmk = true, but the module is not creating the task log group (create_log_group = false or log_retention_days = 0), so DMS would create dms-tasks-${local.instance_id} itself with the AWS-managed key. Let the module create it with a retention."
    }

    precondition {
      condition     = length(local.plaintext_endpoints) == 0 ? true : var.allow_plaintext_credentials
      error_message = "these endpoints carry a username/password pair: ${join(", ", local.plaintext_endpoints)}. Those values are written to Terraform state in plaintext and returned by the DMS API. Put the credential in Secrets Manager and set secret_arn, or set allow_plaintext_credentials = true to accept it."
    }

    precondition {
      condition     = length(local.insecure_endpoints) == 0 ? true : var.allow_insecure_transport
      error_message = "these endpoints do not verify the server certificate: ${join(", ", local.insecure_endpoints)}. Use verify-ca or verify-full (whichever DMS supports for the engine) with a certificate, or set allow_insecure_transport = true."
    }
  }
}

# ---------------------------------------------------------------------------
# Provisioned: an instance you pay for by the hour until someone deletes it.
# ---------------------------------------------------------------------------
resource "aws_dms_replication_instance" "this" {
  count = local.create && local.provisioned ? 1 : 0

  replication_instance_id    = local.instance_id
  replication_instance_class = var.instance_class
  allocated_storage          = var.allocated_storage_gb

  engine_version              = var.engine_version != "" ? var.engine_version : null
  auto_minor_version_upgrade  = var.auto_minor_version_upgrade
  allow_major_version_upgrade = var.allow_major_version_upgrade
  apply_immediately           = var.apply_immediately

  multi_az          = var.multi_az
  availability_zone = !var.multi_az && var.availability_zone != "" ? var.availability_zone : null

  replication_subnet_group_id = aws_dms_replication_subnet_group.this[0].replication_subnet_group_id
  vpc_security_group_ids      = var.security_group_ids
  network_type                = var.network_type

  # A public replication instance holds credentials for both databases and
  # answers from the internet. The gate is in the precondition below.
  publicly_accessible = var.publicly_accessible

  preferred_maintenance_window = var.preferred_maintenance_window != "" ? var.preferred_maintenance_window : null

  # Cached changes and unshipped LOBs live on this volume, so it is migrating
  # data at rest even though nothing is "stored" here.
  kms_key_arn = var.kms_key_arn != "" ? var.kms_key_arn : null

  tags = local.common_tags

  lifecycle {
    precondition {
      condition     = var.publicly_accessible ? var.allow_public_replication_instance : true
      error_message = "publicly_accessible = true puts a host holding your source and target database credentials on the internet. If the source really is outside AWS, reach it over VPN or Direct Connect and keep this instance private. Set allow_public_replication_instance = true to accept it."
    }

    precondition {
      condition     = var.require_cmk ? var.kms_key_arn != "" : true
      error_message = "require_cmk = true but kms_key_arn is empty, so replication storage - which holds cached changes and in-flight LOBs - would use the AWS-managed DMS key."
    }

    precondition {
      # Falls back to AWS's choice otherwise, which can land mid-cutover.
      condition     = var.multi_az ? var.availability_zone == "" : true
      error_message = "availability_zone is only meaningful when multi_az is false; a multi-AZ instance places itself."
    }
  }
}

# ---------------------------------------------------------------------------
# Serverless: DMS sizes capacity between the DCU bounds. No instance to forget
# about, and no per-task resource - one replication config is one migration.
# ---------------------------------------------------------------------------
resource "aws_dms_replication_config" "this" {
  for_each = local.create && local.serverless ? var.tasks : {}

  replication_config_identifier = "${var.name}-${each.key}"
  replication_type              = each.value.migration_type
  source_endpoint_arn           = local.endpoint_arns[each.value.source_endpoint]
  target_endpoint_arn           = local.endpoint_arns[each.value.target_endpoint]
  table_mappings                = each.value.table_mappings
  replication_settings          = local.task_settings_json[each.key]

  start_replication = each.value.start

  compute_config {
    replication_subnet_group_id  = aws_dms_replication_subnet_group.this[0].replication_subnet_group_id
    vpc_security_group_ids       = var.security_group_ids
    min_capacity_units           = var.serverless.min_dcu
    max_capacity_units           = var.serverless.max_dcu
    multi_az                     = var.serverless.multi_az
    availability_zone            = !var.serverless.multi_az && var.serverless.availability_zone != "" ? var.serverless.availability_zone : null
    preferred_maintenance_window = var.serverless.preferred_maintenance_window != "" ? var.serverless.preferred_maintenance_window : null
    dns_name_servers             = var.serverless.dns_name_servers != "" ? var.serverless.dns_name_servers : null
    kms_key_id                   = var.kms_key_arn != "" ? var.kms_key_arn : null
  }

  tags = local.common_tags

  lifecycle {
    precondition {
      condition     = length(local.tasks_with_unknown_endpoints) == 0
      error_message = "these tasks name an endpoint that does not exist: ${join(", ", local.tasks_with_unknown_endpoints)}. source_endpoint and target_endpoint are keys from endpoints or s3_targets."
    }

    precondition {
      condition     = var.require_cmk ? var.kms_key_arn != "" : true
      error_message = "require_cmk = true but kms_key_arn is empty, so serverless replication storage would use the AWS-managed DMS key."
    }

    precondition {
      # Serverless scales down but never to zero, so an idle CDC replication
      # bills min_dcu around the clock waiting for changes.
      condition     = var.serverless.min_dcu <= var.serverless.max_dcu
      error_message = "serverless.min_dcu must not exceed serverless.max_dcu."
    }
  }
}
