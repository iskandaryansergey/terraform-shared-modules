# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

output "cluster_identifier" {
  description = "Cluster identifier (equal to var.name)."
  value       = one(aws_rds_cluster.this[*].id)
}

output "cluster_arn" {
  description = "Cluster ARN. Use it in IAM conditions and for AWS Backup selections."
  value       = one(aws_rds_cluster.this[*].arn)
}

output "cluster_resource_id" {
  description = "Cluster resource ID (cluster-XXXX). IAM database authentication policies name this, not the identifier - and a point-in-time restore of the cluster after it is deleted needs it."
  value       = one(aws_rds_cluster.this[*].cluster_resource_id)
}

output "cluster_endpoint" {
  description = "Writer endpoint. Follows the writer through a failover."
  value       = one(aws_rds_cluster.this[*].endpoint)
}

output "cluster_reader_endpoint" {
  description = "Reader endpoint, load-balanced across readers. With no readers it resolves to the writer."
  value       = one(aws_rds_cluster.this[*].reader_endpoint)
}

output "cluster_port" {
  description = "Database port."
  value       = one(aws_rds_cluster.this[*].port)
}

output "cluster_hosted_zone_id" {
  description = "Route 53 zone AWS hosts the endpoints in. RDS endpoints are not alias targets: a friendly name for the cluster is a CNAME to cluster_endpoint."
  value       = one(aws_rds_cluster.this[*].hosted_zone_id)
}

output "engine_version_actual" {
  description = "The engine version running, which differs from var.engine_version after a major-only pin or an automatic minor upgrade."
  value       = one(aws_rds_cluster.this[*].engine_version_actual)
}

output "master_user_secret_arn" {
  description = "Secrets Manager secret holding the master credentials, when RDS manages them. Grant secretsmanager:GetSecretValue on this, not on a wildcard."
  value       = local.create && local.manage_password ? local.managed_secret_arn : null
}

output "master_user_secret_kms_key_id" {
  description = "Key the master secret is encrypted with. A principal reading the secret needs kms:Decrypt on it too."
  value       = local.create && local.manage_password ? local.managed_secret_kms_key_id : null
}

output "global_cluster_identifier" {
  description = "Global cluster this cluster belongs to, or null. A secondary that takes this from the primary's module call is created after the primary cluster and its instances exist - the output waits for them."
  value       = local.create ? local.global_cluster_identifier : null

  # The global cluster alone exists before its primary does. A secondary
  # joining at that point fails, and on destroy the two are torn down
  # concurrently.
  depends_on = [aws_rds_cluster.this, aws_rds_cluster_instance.this]
}

output "global_cluster_arn" {
  description = "ARN of the global cluster, when this module created it."
  value       = one(aws_rds_global_cluster.this[*].arn)
}

# ---------------------------------------------------------------------------
# Instances and endpoints
# ---------------------------------------------------------------------------

output "instance_identifiers" {
  description = "Instance identifier per instance key."
  value       = { for k, i in aws_rds_cluster_instance.this : k => i.identifier }
}

output "instance_arns" {
  description = "Instance ARN per instance key."
  value       = { for k, i in aws_rds_cluster_instance.this : k => i.arn }
}

output "instance_endpoints" {
  description = "Instance endpoint per instance key. Connect to these only for instance-specific work; applications use the cluster endpoints."
  value       = { for k, i in aws_rds_cluster_instance.this : k => i.endpoint }
}

output "writer_instance_key" {
  description = "Key of the instance that is the writer as of the last refresh. It moves with every failover."
  value       = one([for k, i in aws_rds_cluster_instance.this : k if i.writer])
}

output "custom_endpoints" {
  description = "Custom endpoint address per custom_endpoints key."
  value       = { for k, e in aws_rds_cluster_endpoint.this : k => e.endpoint }
}

# ---------------------------------------------------------------------------
# Supporting resources - created or brought
# ---------------------------------------------------------------------------

output "security_group_id" {
  description = "The module-created database security group, or null. Add ingress with var.ingress_rules rather than outside the module, or the next apply will not know about it."
  value       = one(aws_security_group.this[*].id)
}

output "security_group_ids" {
  description = "Every security group on the cluster, created and brought."
  value       = local.create ? local.security_group_ids : []
}

output "db_subnet_group_name" {
  description = "DB subnet group in use, created or brought."
  value       = local.create ? local.db_subnet_group_name : null
}

output "cluster_parameter_group_name" {
  description = "Cluster parameter group in use, created or brought."
  value       = local.create ? local.cluster_parameter_group_name : null
}

output "db_parameter_group_name" {
  description = "Instance parameter group in use, created or brought."
  value       = local.create ? local.db_parameter_group_name : null
}

output "effective_parameters" {
  description = "What the module wrote into its own parameter groups after merging recommended, caller and TLS parameters. null for a brought group - the module does not know what is in it."
  value = !local.create ? null : {
    cluster  = local.create_cluster_parameter_group ? { for k, p in local.effective_cluster_parameters : k => p.value } : null
    instance = local.create_db_parameter_group ? { for k, p in var.db_parameters : k => p.value } : null
  }
}

output "monitoring_role_arn" {
  description = "Enhanced Monitoring role in use, created or brought. null when monitoring is off."
  value       = local.create ? local.monitoring_role_arn : null
}

output "log_group_names" {
  description = "CloudWatch log group per exported log type. They exist whether the module created them or RDS did."
  value       = local.create ? local.log_group_names : {}
}

output "log_group_arns" {
  description = "ARN of each module-created log group, per log type - for subscription filters and log-shipping policies."
  value       = { for k, g in aws_cloudwatch_log_group.this : k => g.arn }
}

output "alarm_arns" {
  description = "Alarm ARN by alarm name."
  value = merge(
    { for a in aws_cloudwatch_metric_alarm.writer_cpu : a.alarm_name => a.arn },
    { for a in aws_cloudwatch_metric_alarm.reader_cpu : a.alarm_name => a.arn },
    { for a in aws_cloudwatch_metric_alarm.freeable_memory : a.alarm_name => a.arn },
    { for a in aws_cloudwatch_metric_alarm.free_local_storage : a.alarm_name => a.arn },
    { for a in aws_cloudwatch_metric_alarm.replica_lag : a.alarm_name => a.arn },
    { for a in aws_cloudwatch_metric_alarm.acu_utilization : a.alarm_name => a.arn },
    { for a in aws_cloudwatch_metric_alarm.connections : a.alarm_name => a.arn },
    { for a in aws_cloudwatch_metric_alarm.transaction_ids : a.alarm_name => a.arn },
    { for a in aws_cloudwatch_metric_alarm.volume_bytes : a.alarm_name => a.arn },
    { for a in aws_cloudwatch_metric_alarm.global_rpo_lag : a.alarm_name => a.arn },
  )
}

output "activity_stream_kinesis_stream_name" {
  description = "Kinesis stream AWS created for the activity stream. Consumers decrypt records with the activity stream key."
  value       = one(aws_rds_cluster_activity_stream.this[*].kinesis_stream_name)
}

# ---------------------------------------------------------------------------
# RDS Proxy
# ---------------------------------------------------------------------------

output "proxy_arn" {
  description = "RDS Proxy ARN, or null."
  value       = one(aws_db_proxy.this[*].arn)
}

output "proxy_endpoint" {
  description = "Read/write proxy endpoint. Point applications here instead of the cluster endpoint to get pooling and faster failover."
  value       = one(aws_db_proxy.this[*].endpoint)
}

output "proxy_reader_endpoint" {
  description = "Read-only proxy endpoint, or null."
  value       = one(aws_db_proxy_endpoint.reader[*].endpoint)
}

output "proxy_role_arn" {
  description = "Role the proxy uses to read the secret, created or brought."
  value       = local.proxy_enabled ? local.proxy_role_arn : null
}

output "proxy_security_group_id" {
  description = "The module-created proxy security group, or null."
  value       = one(aws_security_group.proxy[*].id)
}

# ---------------------------------------------------------------------------
# Contracts
#
# What a consumer, a reviewer or the next team needs, as data. Each is null
# when create = false, and none is sensitive, so all of them reach another
# workspace through tfe_outputs' nonsensitive_values.
# ---------------------------------------------------------------------------

output "connection" {
  description = "Everything a client needs to connect, with no secret in it. Hand this to the application or the DMS module."
  value = !local.create ? null : {
    host              = one(aws_rds_cluster.this[*].endpoint)
    reader_host       = one(aws_rds_cluster.this[*].reader_endpoint)
    proxy_host        = one(aws_db_proxy.this[*].endpoint)
    proxy_reader_host = one(aws_db_proxy_endpoint.reader[*].endpoint)
    port              = local.port
    proxy_port        = local.proxy_enabled ? local.default_port : null
    engine            = var.engine
    # What the cluster has, not what was asked for: both are creation-time and
    # ignored afterwards, and a restored or adopted cluster has its own.
    database            = one(aws_rds_cluster.this[*].database_name)
    username            = one(aws_rds_cluster.this[*].master_username)
    secret_arn          = local.manage_password ? local.managed_secret_arn : null
    secret_kms_key_arn  = local.manage_password ? local.managed_secret_kms_key_id : null
    ca_cert_identifiers = distinct([for i in values(local.instances) : i.ca_cert_identifier])
    tls_required        = local.tls_enforced
    iam_auth            = var.iam_database_authentication_enabled
    security_group_id   = one(aws_security_group.this[*].id)
  }
}

output "governance" {
  description = "The security, resilience and cost posture of this cluster, as data rather than prose. Assert on it in tests, or diff it in a change review."
  value = !local.create ? null : {
    # Credentials and transport
    credential_source                   = local.credential_source
    master_password_rotation            = local.create_rotation_schedule ? coalesce(var.master_password_rotation.schedule_expression, "every ${var.master_password_rotation.automatically_after_days} days") : (local.manage_password ? "rds default (every 7 days)" : "n/a")
    tls_enforced                        = local.tls_enforced ? "yes" : (var.enforce_tls ? "unknown - brought parameter group" : "no")
    iam_database_authentication_enabled = var.iam_database_authentication_enabled
    data_api_enabled                    = var.enable_data_api
    publicly_accessible                 = var.publicly_accessible

    # Network
    security_group_managed_by_module = var.create_security_group
    ingress_rules                    = keys(var.ingress_rules)
    ingress_outside_private_ranges   = local.non_private_ingress
    egress_rules                     = keys(var.egress_rules)
    subnet_group_managed_by_module   = var.create_db_subnet_group

    # Encryption
    storage_encrypted    = true
    customer_managed_key = var.kms_key_arn != ""
    purposes_without_cmk = local.purposes_without_cmk
    keys = {
      storage              = local.storage_kms_key_arn != "" ? local.storage_kms_key_arn : "aws-managed aws/rds"
      master_secret        = !local.manage_password ? "n/a" : (local.master_secret_kms_key_arn != "" ? local.master_secret_kms_key_arn : "aws-managed aws/secretsmanager")
      performance_insights = !var.performance_insights_enabled ? "n/a" : (local.performance_insights_kms_key != "" ? local.performance_insights_kms_key : "aws-managed aws/rds")
      log_groups           = !local.create_log_groups ? "n/a - not created by this module" : (local.logs_kms_key_arn != "" ? local.logs_kms_key_arn : "cloudwatch logs default")
      activity_stream      = !var.activity_stream.enabled ? "n/a" : local.activity_stream_kms_key_arn
    }

    # Resilience
    instances                 = { for k, i in local.instances : k => i.instance_class }
    instance_count            = length(local.instances)
    instances_share_one_az    = local.instances_share_one_az
    serverless_instances      = local.serverless_instances
    burstable_instances       = local.burstable_instances
    writer_selection          = "first instance to finish creating; promotion_tier orders failover"
    global_cluster_role       = var.global_cluster_role
    deletion_protection       = var.deletion_protection
    final_snapshot            = var.skip_final_snapshot ? "skipped" : local.final_snapshot_identifier
    backup_retention_days     = var.backup_retention_days
    automated_backups_on_drop = var.delete_automated_backups ? "deleted" : "retained"
    backtrack_window_seconds  = var.backtrack_window_seconds
    maintenance_window        = var.preferred_maintenance_window

    # Versions
    engine                     = var.engine
    engine_version             = var.engine_version
    auto_minor_version_upgrade = var.auto_minor_version_upgrade
    major_upgrade_permitted    = var.allow_major_version_upgrade
    # What the cluster has, not what was asked for: the setting cannot change
    # after creation.
    engine_lifecycle_support = coalesce(one(aws_rds_cluster.this[*].engine_lifecycle_support), var.engine_lifecycle_support)

    # Observability
    alarms_enabled               = local.alarms_enabled
    event_subscriptions_enabled  = local.events_enabled
    log_exports                  = var.enabled_cloudwatch_logs_exports
    log_retention_days           = local.create_log_groups ? var.log_retention_days : null
    log_group_class              = local.create_log_groups ? var.log_group_class : null
    enhanced_monitoring_interval = var.enhanced_monitoring_interval
    performance_insights_enabled = var.performance_insights_enabled
    database_insights_mode       = var.database_insights_mode
    activity_stream              = var.activity_stream.enabled ? var.activity_stream.mode : "off"

    # Decisions taken in code. A reviewer reads this list, not the plan output.
    acknowledged_checks = sort(var.acknowledged_checks)

    # Data leaving the cluster
    cluster_iam_roles        = keys(var.cluster_iam_roles)
    proxy_enabled            = var.proxy.enabled
    proxy_requires_tls       = var.proxy.enabled ? var.proxy.require_tls : null
    proxy_iam_auth           = var.proxy.enabled ? var.proxy.iam_auth : null
    proxy_uses_master_secret = var.proxy.enabled ? local.proxy_uses_master_secret : null
    proxy_debug_logging      = var.proxy.enabled ? var.proxy.debug_logging : null

    # Cost drivers - each is a line on the bill. COSTS.md prices them.
    cost_drivers = {
      instance_classes          = distinct([for i in values(local.instances) : i.instance_class])
      storage_type              = var.storage_type
      serverless_max_acu        = local.uses_serverless ? var.serverlessv2_scaling_configuration.max_capacity : 0
      serverless_auto_pause     = local.auto_pause
      reader_autoscaling_max    = var.reader_autoscaling.enabled ? var.reader_autoscaling.max_capacity : 0
      proxy                     = var.proxy.enabled
      performance_insights_days = var.performance_insights_enabled ? var.performance_insights_retention_days : 0
      database_insights         = var.database_insights_mode
      extended_support          = coalesce(one(aws_rds_cluster.this[*].engine_lifecycle_support), var.engine_lifecycle_support) == "open-source-rds-extended-support"
      backtrack                 = var.backtrack_window_seconds > 0
      activity_stream           = var.activity_stream.enabled
      log_exports               = var.enabled_cloudwatch_logs_exports
      log_group_class           = var.log_group_class
    }
  }
}

output "network_contract" {
  description = "What the network has to provide for this cluster to be reachable and its features to work. The module creates no VPC resources beyond its own security groups."
  value = !local.create ? null : {
    subnet_group = local.db_subnet_group_name
    # Empty for a brought subnet group: its subnets are not known here.
    subnet_ids         = var.create_db_subnet_group ? var.subnet_ids : []
    security_group_ids = local.security_group_ids
    database_port      = local.port
    proxy_port         = local.proxy_enabled ? local.default_port : null

    # Rules this module could not add because a group on one side is brought.
    rules_you_must_add = compact([
      local.proxy_enabled && !var.proxy.create_security_group && var.create_security_group ? "ingress_rules: allow the proxy's security groups (${join(", ", var.proxy.security_group_ids)}) on ${local.port}" : "",
      local.proxy_enabled && !var.create_security_group ? "on ${join(", ", var.vpc_security_group_ids)}: ingress from the proxy's security group on ${local.port}" : "",
      local.proxy_enabled && !var.proxy.create_security_group ? "on ${join(", ", var.proxy.security_group_ids)}: egress to the database on ${local.port}, egress on 443 to Secrets Manager, and ingress from clients on ${local.default_port}" : "",
    ])

    # Interface or gateway endpoints needed in an isolated VPC. Each line
    # names what needs it.
    vpc_endpoints = compact([
      local.proxy_enabled ? "com.amazonaws.${local.region}.secretsmanager (interface) - RDS Proxy reads the database secret from inside the VPC; the proxy needs egress to it on 443 (proxy.egress_rules)" : "",
      local.manage_password ? "com.amazonaws.${local.region}.secretsmanager (interface) - for clients in the VPC that fetch the master secret" : "",
      contains([for r in values(var.cluster_iam_roles) : r.feature_name], "s3Import") || contains([for r in values(var.cluster_iam_roles) : r.feature_name], "s3Export") ? "com.amazonaws.${local.region}.s3 (gateway) - s3Import/s3Export, plus egress_rules to the S3 prefix list on 443" : "",
      contains([for r in values(var.cluster_iam_roles) : r.feature_name], "Lambda") ? "com.amazonaws.${local.region}.lambda (interface) - Lambda invocation from the database, plus egress_rules to it on 443" : "",
      contains([for r in values(var.cluster_iam_roles) : r.feature_name], "Bedrock") ? "com.amazonaws.${local.region}.bedrock-runtime (interface) - Bedrock calls from the database, plus egress_rules to it on 443" : "",
      contains([for r in values(var.cluster_iam_roles) : r.feature_name], "SageMaker") ? "com.amazonaws.${local.region}.sagemaker.runtime (interface) - SageMaker calls from the database, plus egress_rules to it on 443" : "",
      contains([for r in values(var.cluster_iam_roles) : r.feature_name], "Comprehend") ? "com.amazonaws.${local.region}.comprehend (interface) - Comprehend calls from the database, plus egress_rules to it on 443" : "",
      !local.is_postgres && length(var.cluster_iam_roles) > 0 ? "com.amazonaws.${local.region}.s3 (gateway) and/or com.amazonaws.${local.region}.lambda (interface) - whichever the aurora-mysql roles are for, plus egress_rules to them on 443" : "",
      var.enable_data_api ? "com.amazonaws.${local.region}.rds-data (interface) - for Data API clients inside an isolated VPC" : "",
    ])

    notes = [
      "The database security group has no egress unless egress_rules adds it. Replication, backups, Enhanced Monitoring and Performance Insights do not use it.",
      "Clients verifying TLS need the bundle for ${join(", ", distinct([for i in values(local.instances) : i.ca_cert_identifier]))}: https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem holds every RDS CA.",
    ]
  }
}

output "kms_key_policy_requirements" {
  description = "What each customer-managed key's policy has to allow. The module uses the keys but cannot write their policies. Read it in the plan, before the first apply."
  value = !local.create ? null : concat(
    local.storage_kms_key_arn == "" ? [] : [{
      key       = local.storage_kms_key_arn
      principal = "the principal running terraform (and any principal restoring or copying snapshots)"
      actions   = ["kms:CreateGrant", "kms:DescribeKey", "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*"]
      condition = { "kms:ViaService" = "rds.${local.region}.amazonaws.com" }
      why       = "RDS encrypts the cluster volume, backups and snapshots through grants created on the caller's behalf."
    }],
    !local.manage_password ? [] : (local.master_secret_kms_key_arn == "" ? [] : [{
      key       = local.master_secret_kms_key_arn
      principal = "the principal running terraform, RDS, and every reader of the secret (applications, the proxy role, DMS)"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
      condition = { "kms:ViaService" = "secretsmanager.${local.region}.amazonaws.com" }
      why       = "RDS writes and rotates the master secret; readers decrypt it through Secrets Manager."
    }]),
    !var.performance_insights_enabled ? [] : (local.performance_insights_kms_key == "" ? [] : [{
      key       = local.performance_insights_kms_key
      principal = "the principal running terraform, and anyone using Performance Insights or Database Insights"
      actions   = ["kms:CreateGrant", "kms:DescribeKey", "kms:Decrypt", "kms:GenerateDataKey*"]
      condition = { "kms:ViaService" = "rds.${local.region}.amazonaws.com" }
      why       = "Performance Insights data includes SQL text and is encrypted with this key."
    }]),
    !local.create_log_groups || length(var.enabled_cloudwatch_logs_exports) == 0 ? [] : (local.logs_kms_key_arn == "" ? [] : [{
      key       = local.logs_kms_key_arn
      principal = "Service: logs.${local.region}.amazonaws.com"
      actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
      condition = { "ArnLike kms:EncryptionContext:aws:logs:arn" = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/rds/cluster/${var.name}/*" }
      why       = "CloudWatch Logs encrypts the exported database logs. Without this the log group create fails."
    }]),
    !var.activity_stream.enabled ? [] : [{
      key       = local.activity_stream_kms_key_arn
      principal = "the principal running terraform, and the activity stream consumer"
      actions   = ["kms:CreateGrant", "kms:DescribeKey", "kms:Decrypt", "kms:GenerateDataKey*"]
      condition = { "kms:ViaService" = "rds.${local.region}.amazonaws.com" }
      why       = "Activity stream records are encrypted with this key; the consumer decrypts each record."
    }],
  )
}

output "sns_topic_policy_requirement" {
  description = "What the topic's policy has to allow for alarms and events to arrive. If the topic is encrypted with a customer-managed key, that key has to allow the same principals kms:Decrypt and kms:GenerateDataKey*."
  value = !local.create || var.sns_topic_arn == "" ? null : {
    topic = var.sns_topic_arn
    statements = [
      {
        principal = "Service: events.rds.amazonaws.com"
        action    = "sns:Publish"
        condition = { "aws:SourceAccount" = local.account_id }
        why       = "RDS event subscriptions"
      },
      {
        principal = "Service: cloudwatch.amazonaws.com"
        action    = "sns:Publish"
        condition = { "ArnLike aws:SourceArn" = "arn:${local.partition}:cloudwatch:${local.region}:${local.account_id}:alarm:${var.name}-*" }
        why       = "CloudWatch alarms"
      },
    ]
  }
}

output "verify_commands" {
  description = "AWS CLI checks to run after apply - from CloudShell in the cluster's account and region, or any shell with read access. The connection checks need a host inside the VPC."
  value = !local.create ? null : {
    cluster_is_available        = "aws rds describe-db-clusters --db-cluster-identifier ${var.name} --query 'DBClusters[0].[Status,EngineVersion,MultiAZ,StorageEncrypted,DeletionProtection]'"
    writer_is_where_you_expect  = "aws rds describe-db-clusters --db-cluster-identifier ${var.name} --query 'DBClusters[0].DBClusterMembers[].[DBInstanceIdentifier,IsClusterWriter,PromotionTier]' --output table"
    move_the_writer             = local.failover_target != "" ? "aws rds failover-db-cluster --db-cluster-identifier ${var.name} --target-db-instance-identifier ${var.name}-${local.failover_target}    # lowest promotion_tier" : "no instances"
    parameters_are_applied      = "aws rds describe-db-clusters --db-cluster-identifier ${var.name} --query 'DBClusters[0].DBClusterMembers[].[DBInstanceIdentifier,DBClusterParameterGroupStatus]' --output table    # pending-reboot means a reboot is still owed"
    tls_is_enforced             = "aws rds describe-db-cluster-parameters --db-cluster-parameter-group-name ${coalesce(local.cluster_parameter_group_name, "<group>")} --query \"Parameters[?ParameterName=='${local.tls_parameter_name}'].[ParameterValue,ApplyType]\""
    plaintext_is_refused        = local.is_postgres ? "psql \"host=${coalesce(one(aws_rds_cluster.this[*].endpoint), "<endpoint>")} port=${local.port} sslmode=disable user=<user> dbname=postgres\"    # must fail with 'no pg_hba.conf entry ... no encryption'" : "mysql -h ${coalesce(one(aws_rds_cluster.this[*].endpoint), "<endpoint>")} -P ${local.port} --ssl-mode=DISABLED -u <user> -p    # must fail with 'Connections using insecure transport are prohibited'"
    master_secret               = local.manage_password ? "aws secretsmanager describe-secret --secret-id ${coalesce(local.managed_secret_arn, "<secret>")} --query '[RotationEnabled,RotationRules,NextRotationDate]'" : "no RDS-managed secret"
    extended_support_is_off     = "aws rds describe-db-clusters --db-cluster-identifier ${var.name} --query 'DBClusters[0].EngineLifecycleSupport'"
    alarms_have_a_target        = "aws cloudwatch describe-alarms --alarm-name-prefix ${var.name}- --query 'MetricAlarms[].[AlarmName,StateValue,length(AlarmActions)]' --output table"
    proxy_targets_are_available = local.proxy_enabled ? "aws rds describe-db-proxy-targets --db-proxy-name ${var.name}-proxy --query 'Targets[].[Endpoint,Role,TargetHealth.State,TargetHealth.Reason]' --output table" : "no proxy"
  }
}
