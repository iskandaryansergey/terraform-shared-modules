# The cluster is the one resource that exists whenever create = true, so the
# module-wide invariants live on it - a precondition on a resource with zero
# instances never runs.
#
# Everything that depends on the cluster (instances, endpoints, proxy target,
# role associations, activity stream, autoscaling, alarms) refers to it by
# cluster_identifier or local.cluster_arn, never by id or arn. Those two are
# unknown while a replacement is planned, and every dependent whose
# identifier argument is ForceNew would be planned for replacement too -
# Terraform would delete all the instances first, and only then would
# deletion_protection stop the cluster delete. Known names keep the
# dependents in place, so a plan that tries to replace the cluster fails at
# the cluster, with the instances still serving.

resource "aws_rds_global_cluster" "this" {
  count = local.create_global_cluster ? 1 : 0

  global_cluster_identifier = var.global_cluster_identifier
  engine                    = var.engine
  engine_version            = var.engine_version
  engine_lifecycle_support  = var.engine_lifecycle_support
  database_name             = var.database_name != "" ? var.database_name : null
  storage_encrypted         = true
  deletion_protection       = var.deletion_protection

  tags = merge(local.common_tags, { "Name" = var.global_cluster_identifier })

  lifecycle {
    # The provider upgrades a global cluster with major upgrades always
    # allowed, which would bypass allow_major_version_upgrade. Versions are
    # driven by the member clusters; a major upgrade of a global database is
    # an explicit modify-global-cluster - README "Global database upgrades".
    ignore_changes = [engine_version, engine_lifecycle_support]
  }
}

# The cluster's creation time, for the final snapshot name. plantimestamp()
# changes every plan; ignore_changes keeps the first value for the life of the
# cluster, so the name is unique without being a perpetual diff. The triggers
# are the inputs that replace the cluster: a new cluster gets a new time.
resource "terraform_data" "created_at" {
  count = local.create && var.final_snapshot_identifier == "" ? 1 : 0

  input = plantimestamp()
  triggers_replace = [
    var.name, var.engine, var.kms_key_arn, var.create_db_subnet_group, var.db_subnet_group_name,
  ]

  lifecycle {
    ignore_changes = [input]
  }
}

resource "aws_rds_cluster" "this" {
  count = local.create ? 1 : 0

  cluster_identifier       = var.name
  engine                   = var.engine
  engine_mode              = "provisioned"
  engine_version           = var.engine_version
  engine_lifecycle_support = var.engine_lifecycle_support

  allow_major_version_upgrade = var.allow_major_version_upgrade
  # A major upgrade fails part way unless the instances' new parameter group
  # is named on the cluster call. The family-named group makes this the new
  # one; the provider drops it from any modify that is not a major upgrade.
  db_instance_parameter_group_name = var.allow_major_version_upgrade ? local.db_parameter_group_name : null
  apply_immediately                = var.apply_immediately

  # Credentials. Null on a restore or a secondary - see local.inherits_credentials.
  database_name                 = local.inherits_credentials ? null : (var.database_name != "" ? var.database_name : null)
  master_username               = local.inherits_credentials ? null : var.master_username
  manage_master_user_password   = local.manage_password ? true : null
  master_user_secret_kms_key_id = local.manage_password ? (local.master_secret_kms_key_arn != "" ? local.master_secret_kms_key_arn : null) : null
  master_password               = local.static_password ? var.master_password : null

  iam_database_authentication_enabled = var.iam_database_authentication_enabled
  enable_http_endpoint                = var.enable_data_api
  enable_local_write_forwarding       = var.enable_local_write_forwarding

  # aurora-mysql associates roles without a feature name, which the
  # association resource cannot express - integrations.tf handles PostgreSQL.
  iam_roles = local.is_postgres ? null : [for r in values(var.cluster_iam_roles) : r.role_arn]

  # Network
  port                   = local.port
  db_subnet_group_name   = local.db_subnet_group_name
  vpc_security_group_ids = local.security_group_ids
  network_type           = var.network_type

  db_cluster_parameter_group_name = local.cluster_parameter_group_name

  # Storage
  storage_encrypted = true
  kms_key_id        = local.storage_kms_key_arn != "" ? local.storage_kms_key_arn : null
  storage_type      = var.storage_type

  # Backup and deletion
  backup_retention_period      = var.backup_retention_days
  preferred_backup_window      = var.preferred_backup_window
  preferred_maintenance_window = var.preferred_maintenance_window
  backtrack_window             = var.engine == "aurora-mysql" ? var.backtrack_window_seconds : null
  copy_tags_to_snapshot        = var.copy_tags_to_snapshot
  deletion_protection          = var.deletion_protection
  skip_final_snapshot          = var.skip_final_snapshot
  final_snapshot_identifier    = var.skip_final_snapshot ? null : local.final_snapshot_identifier
  delete_automated_backups     = var.delete_automated_backups

  # Where the data comes from
  snapshot_identifier = local.restore_from_snapshot ? var.snapshot_identifier : null

  dynamic "restore_to_point_in_time" {
    for_each = local.restore_from_pitr ? [var.restore_to_point_in_time] : []
    content {
      source_cluster_identifier  = restore_to_point_in_time.value.source_cluster_identifier != "" ? restore_to_point_in_time.value.source_cluster_identifier : null
      source_cluster_resource_id = restore_to_point_in_time.value.source_cluster_resource_id != "" ? restore_to_point_in_time.value.source_cluster_resource_id : null
      restore_type               = restore_to_point_in_time.value.restore_type
      restore_to_time            = restore_to_point_in_time.value.restore_to_time != "" ? restore_to_point_in_time.value.restore_to_time : null
      use_latest_restorable_time = restore_to_point_in_time.value.use_latest_restorable_time ? true : null
    }
  }

  global_cluster_identifier      = local.global_cluster_identifier
  enable_global_write_forwarding = local.is_secondary ? var.enable_global_write_forwarding : null

  # Observability. Performance Insights is set explicitly at the cluster, always:
  # the provider treats an unset value here as false rather than "whatever AWS
  # reports", so leaving it out is a plan that turns PI off cluster-wide the
  # first time AWS reports it on.
  enabled_cloudwatch_logs_exports       = var.enabled_cloudwatch_logs_exports
  database_insights_mode                = var.database_insights_mode
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_enabled ? var.performance_insights_retention_days : null
  performance_insights_kms_key_id       = var.performance_insights_enabled ? (local.performance_insights_kms_key != "" ? local.performance_insights_kms_key : null) : null

  dynamic "serverlessv2_scaling_configuration" {
    for_each = local.uses_serverless ? [var.serverlessv2_scaling_configuration] : []
    content {
      min_capacity             = serverlessv2_scaling_configuration.value.min_capacity
      max_capacity             = serverlessv2_scaling_configuration.value.max_capacity
      seconds_until_auto_pause = serverlessv2_scaling_configuration.value.min_capacity == 0 ? serverlessv2_scaling_configuration.value.seconds_until_auto_pause : null
    }
  }

  tags = merge(local.common_tags, { "Name" = var.name })

  timeouts {
    create = var.timeouts.create
    update = var.timeouts.update
    delete = var.timeouts.delete
  }

  # RDS creates /aws/rds/cluster/<name>/<type> itself on first write. Creating
  # the groups first is what makes retention and the key apply.
  depends_on = [aws_cloudwatch_log_group.this]

  lifecycle {
    # Creation-time inputs, to AWS or to this module. Changing one later would
    # either replace a running cluster or send a change AWS refuses:
    #   snapshot_identifier, restore_to_point_in_time  where the data came from
    #   replication_source_identifier, source_region   set by older modules
    #   master_username, database_name                 ForceNew; cleared by a
    #                                                  restore or a promotion
    #   engine_lifecycle_support                       no modify call exists
    #   master_user_secret_kms_key_id                  fixed once RDS owns the secret
    #   performance_insights_kms_key_id                fixed once set
    # checks.tf compares what the cluster has with what was asked for.
    ignore_changes = [
      snapshot_identifier,
      restore_to_point_in_time,
      replication_source_identifier,
      source_region,
      master_username,
      database_name,
      engine_lifecycle_support,
      master_user_secret_kms_key_id,
      performance_insights_kms_key_id,
    ]

    # -- Inputs that depend on each other ---------------------------------
    #
    # Validations on Terraform 1.7 can read only their own variable, so every
    # rule comparing two inputs is here. All of them are still plan-time.

    precondition {
      condition     = length(local.missing_required_tags) == 0
      error_message = "tags is missing these required keys, or has them empty: ${join(", ", local.missing_required_tags)} (required_tag_keys)."
    }

    precondition {
      condition     = local.engine_version_matches_engine
      error_message = "engine_version ${var.engine_version} is not a ${var.engine} version. aurora-postgresql takes \"17.9\"; aurora-mysql takes \"8.0.mysql_aurora.3.10.4\"."
    }

    precondition {
      condition     = local.is_postgres ? true : length(var.master_username) <= 16
      error_message = "master_username is ${length(var.master_username)} chars; aurora-mysql allows at most 16."
    }

    precondition {
      condition     = var.global_cluster_role == "none" ? true : var.global_cluster_identifier != ""
      error_message = "global_cluster_identifier is required when global_cluster_role is primary or secondary."
    }

    precondition {
      condition     = var.create_db_subnet_group ? true : var.db_subnet_group_name != ""
      error_message = "db_subnet_group_name is required with create_db_subnet_group = false."
    }

    precondition {
      condition     = length(var.vpc_security_group_ids) + (var.create_security_group ? 1 : 0) <= 5
      error_message = "vpc_security_group_ids plus the module-created group makes ${length(var.vpc_security_group_ids) + 1}; RDS allows 5 security groups on a cluster."
    }

    precondition {
      condition     = var.create_cluster_parameter_group ? var.cluster_parameter_group_name == "" : var.cluster_parameter_group_name != ""
      error_message = "cluster_parameter_group_name is required with create_cluster_parameter_group = false, and must be empty with true."
    }

    precondition {
      condition     = var.create_db_parameter_group ? var.db_parameter_group_name == "" : var.db_parameter_group_name != ""
      error_message = "db_parameter_group_name is required with create_db_parameter_group = false, and must be empty with true."
    }

    precondition {
      condition     = var.backtrack_window_seconds == 0 ? true : !local.is_postgres
      error_message = "backtrack_window_seconds is aurora-mysql only."
    }

    precondition {
      condition     = length(local.iam_roles_wrong_feature) == 0
      error_message = "cluster_iam_roles ${join(", ", local.iam_roles_wrong_feature)}: aurora-postgresql needs a feature_name (s3Import, s3Export, Lambda, SageMaker, Comprehend, Bedrock); aurora-mysql takes none."
    }

    precondition {
      condition     = length(local.log_exports_wrong_engine) == 0
      error_message = "enabled_cloudwatch_logs_exports holds log types ${var.engine} does not publish: ${join(", ", local.log_exports_wrong_engine)}. It publishes ${join(", ", local.log_types_for_engine)}."
    }

    precondition {
      condition     = var.create_monitoring_role ? var.monitoring_role_arn == "" : true
      error_message = "monitoring_role_arn is for a brought role: set create_monitoring_role = false with it."
    }

    # -- Network ----------------------------------------------------------

    precondition {
      condition     = var.create_db_subnet_group ? length(var.subnet_ids) >= 2 : true
      error_message = "the module creates the DB subnet group from subnet_ids, which needs at least two subnets in different AZs. Supply subnet_ids, or set create_db_subnet_group = false and name an existing group in db_subnet_group_name."
    }

    precondition {
      condition     = var.create_security_group ? var.vpc_id != "" : true
      error_message = "create_security_group = true needs vpc_id."
    }

    precondition {
      # With no group at all, RDS attaches the VPC's default security group.
      condition     = var.create_security_group ? true : length(var.vpc_security_group_ids) > 0
      error_message = "create_security_group = false and vpc_security_group_ids is empty, so RDS would attach the VPC default security group. Supply vpc_security_group_ids, or let the module create one."
    }

    precondition {
      # The rules are written into the module's group. Without it they would
      # be dropped, while governance went on listing them.
      condition     = var.create_security_group ? true : length(var.ingress_rules) + length(var.egress_rules) == 0
      error_message = "ingress_rules and egress_rules go into the module-created security group, and create_security_group = false, so they would be ignored. Add them to the groups in vpc_security_group_ids, or let the module create its group."
    }

    precondition {
      condition     = var.publicly_accessible ? var.allow_public_access : true
      error_message = "publicly_accessible = true gives every instance a public address. Set allow_public_access = true if that is intended."
    }

    precondition {
      condition     = length(local.arns_in_another_region) == 0
      error_message = "these ARNs are not in ${local.region}, the cluster's region: ${join(", ", local.arns_in_another_region)}. KMS keys and SNS topics have to be regional - a global secondary needs its own."
    }

    # -- Credentials ------------------------------------------------------

    precondition {
      condition     = length(local.data_sources) <= 1
      error_message = "the cluster can come from one source, but these are all set: ${join(", ", local.data_sources)}."
    }

    precondition {
      # Without this AWS rejects the create, after the subnet group, security
      # group and parameter groups already exist.
      condition = local.inherits_credentials ? true : (
        var.manage_master_user_password ? !local.password_supplied : local.password_supplied
      )
      error_message = "set exactly one credential source: manage_master_user_password = true (the default, with master_password empty), or manage_master_user_password = false with master_password."
    }

    precondition {
      condition     = local.static_password ? var.allow_plaintext_credentials : true
      error_message = "master_password is stored in Terraform state in plaintext, readable by anyone with state access. Use the default manage_master_user_password = true, or set allow_plaintext_credentials = true to accept it."
    }

    precondition {
      condition     = local.is_global ? !var.manage_master_user_password : true
      error_message = "AWS does not support the RDS-managed master secret for clusters in a global database. Set manage_master_user_password = false, and on the primary pass master_password (with allow_plaintext_credentials)."
    }

    precondition {
      condition     = var.enforce_tls ? true : var.allow_insecure_transport
      error_message = "enforce_tls = false lets clients connect without TLS, sending credentials and data in cleartext. Set allow_insecure_transport = true if that is intended."
    }

    precondition {
      condition     = !local.tls_parameter_conflict
      error_message = "cluster_parameters sets ${local.tls_parameter_name} to a value that turns TLS enforcement off, and enforce_tls owns that parameter. Remove it, or set enforce_tls = false (with allow_insecure_transport)."
    }

    # -- Encryption -------------------------------------------------------

    precondition {
      condition     = var.require_cmk ? length(local.purposes_without_cmk) == 0 : true
      error_message = "require_cmk = true, but these would use an AWS-managed key: ${join(", ", local.purposes_without_cmk)}. Set kms_key_arn, or the per-purpose key."
    }

    # -- Global database --------------------------------------------------

    precondition {
      condition     = local.is_secondary ? var.kms_key_arn != "" : true
      error_message = "a secondary in a new region needs kms_key_arn - a key in this region. The primary's key does not exist here."
    }

    precondition {
      condition     = local.is_secondary ? (var.database_name == "" ? !local.password_supplied : false) : true
      error_message = "a secondary replicates its database and credentials from the primary. Leave database_name and master_password empty."
    }

    precondition {
      # The provider rejects snapshot_identifier with global_cluster_identifier;
      # this says why, before anything is created.
      condition     = local.is_primary ? !local.inherits_credentials : true
      error_message = "a global primary cannot be created from a snapshot or a point-in-time restore here. Restore it as a regional cluster, then add it to a global cluster."
    }

    precondition {
      condition     = var.enable_global_write_forwarding ? local.is_secondary : true
      error_message = "enable_global_write_forwarding applies to a secondary only."
    }

    precondition {
      condition     = local.is_global ? !var.allow_major_version_upgrade : true
      error_message = "a global database's major version is upgraded on the global cluster (aws rds modify-global-cluster --allow-major-version-upgrade), not member by member. Leave allow_major_version_upgrade false here, upgrade the global cluster, then set engine_version to match in every region."
    }

    precondition {
      condition     = local.is_global ? var.backtrack_window_seconds == 0 : true
      error_message = "backtrack is not supported on a global database. Set backtrack_window_seconds = 0."
    }

    # -- Compute ----------------------------------------------------------

    precondition {
      # A headless secondary is storage with no compute, which is the one
      # place an empty instances map is a design rather than a mistake.
      condition     = length(var.instances) > 0 ? true : local.is_secondary
      error_message = "instances is empty, so the cluster would have no compute and nothing could connect. Only a global secondary can be headless."
    }

    precondition {
      condition     = var.reader_autoscaling.enabled ? !local.is_secondary : true
      error_message = "AWS does not support Aurora Auto Scaling on a global secondary. Size the secondary with var.instances."
    }

    precondition {
      condition     = var.database_insights_mode == "advanced" ? (var.performance_insights_enabled ? var.performance_insights_retention_days == 465 : false) : true
      error_message = "database_insights_mode = advanced needs performance_insights_enabled = true and performance_insights_retention_days = 465 (the API accepts no other value with advanced)."
    }

    precondition {
      condition     = var.activity_stream.enabled ? length(local.serverless_instances) == 0 && length(local.burstable_instances) == 0 : true
      error_message = "activity streams are not available on db.serverless or burstable (db.t*) instances: ${join(", ", concat(local.serverless_instances, local.burstable_instances))}."
    }

    # -- Observability ----------------------------------------------------

    precondition {
      # A topic decided by a resource in the caller's own configuration is
      # unknown here; the check then runs at apply, which is still before the
      # alarms are created.
      condition     = var.create_alarms || var.create_event_subscriptions ? var.sns_topic_arn != "" : true
      error_message = "create_alarms and create_event_subscriptions need sns_topic_arn. Supply a topic, or set both to false - the somebody_hears_a_failover check then says so in every plan."
    }

    precondition {
      condition     = local.monitoring_enabled && !var.create_monitoring_role ? var.monitoring_role_arn != "" : true
      error_message = "create_monitoring_role = false needs monitoring_role_arn while enhanced_monitoring_interval > 0."
    }

    # -- Proxy ------------------------------------------------------------

    precondition {
      condition     = var.proxy.enabled ? length(local.proxy_subnet_ids) >= 2 : true
      error_message = "proxy needs at least two subnets: set proxy.subnet_ids, or subnet_ids."
    }

    precondition {
      condition     = var.proxy.enabled && var.proxy.create_security_group ? var.vpc_id != "" : true
      error_message = "the module creates the proxy's security group, which needs vpc_id. Set vpc_id, or supply proxy.security_group_ids with proxy.create_security_group = false."
    }

    precondition {
      # With no secret of its own, the proxy logs every client in as the master
      # user. That is a decision, not a default.
      condition     = var.proxy.enabled && length(var.proxy.secret_arns) == 0 ? var.proxy.use_master_secret : true
      error_message = "proxy.secret_arns is empty, so the proxy would authenticate every client as the master user, with its privileges. Supply secrets for application users, or set proxy.use_master_secret = true to accept it."
    }

    precondition {
      condition     = var.proxy.enabled && length(var.proxy.secret_arns) == 0 ? local.manage_password : true
      error_message = "proxy.use_master_secret needs the RDS-managed master secret, and there is none (manage_master_user_password is false, or this is a global member). Supply proxy.secret_arns."
    }
  }
}
