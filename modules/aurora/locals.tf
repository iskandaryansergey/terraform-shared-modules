locals {
  create = var.create

  # Module keys last, so a caller's tags cannot override them.
  module_tags = {
    "ManagedBy"       = "Terraform"
    "Module"          = "aurora"
    "DatabaseCluster" = var.name
  }
  common_tags = merge(var.tags, local.module_tags)

  # Placeholders so ARN expressions still evaluate when create = false.
  partition  = coalesce(one(data.aws_partition.current[*].partition), "aws")
  region     = try(split(".", one(data.aws_region.current[*].endpoint))[1], "us-east-1")
  account_id = coalesce(one(data.aws_caller_identity.current[*].account_id), "000000000000")

  is_postgres = var.engine == "aurora-postgresql"

  # Validated in variables.tf, so the split always has the parts it needs. try()
  # because both sides of the ternary are evaluated.
  derived_family = (
    local.is_postgres
    ? try("aurora-postgresql${split(".", var.engine_version)[0]}", "")
    : try("aurora-mysql${join(".", slice(split(".", var.engine_version), 0, 2))}", "")
  )
  family = var.parameter_group_family != "" ? var.parameter_group_family : local.derived_family

  default_port = local.is_postgres ? 5432 : 3306
  port         = var.port != 0 ? var.port : local.default_port

  # Built from inputs rather than read from aws_rds_cluster.this, so that it
  # stays known while the cluster is being replaced - see main.tf.
  cluster_arn = "arn:${local.partition}:rds:${local.region}:${local.account_id}:cluster:${var.name}"

  # -------------------------------------------------------------------------
  # Global database and restore
  # -------------------------------------------------------------------------

  is_global    = var.global_cluster_role != "none"
  is_primary   = var.global_cluster_role == "primary"
  is_secondary = var.global_cluster_role == "secondary"

  # Without a name the global cluster is not planned at all, so the
  # precondition on the cluster reports the missing input - rather than the
  # provider rejecting an empty identifier with a message about its first
  # character.
  create_global_cluster = local.create && local.is_primary && var.create_global_cluster && var.global_cluster_identifier != ""

  global_cluster_identifier = (
    !local.is_global ? null
    : local.create_global_cluster ? one(aws_rds_global_cluster.this[*].id)
    : (var.global_cluster_identifier != "" ? var.global_cluster_identifier : null)
  )

  restore_from_snapshot = var.snapshot_identifier != ""
  restore_from_pitr = (
    var.restore_to_point_in_time.source_cluster_identifier != ""
    ? true
    : var.restore_to_point_in_time.source_cluster_resource_id != ""
  )

  # How the cluster gets its data. More than one is refused on the cluster.
  data_sources = compact([
    local.restore_from_snapshot ? "snapshot" : "",
    local.restore_from_pitr ? "point-in-time" : "",
    local.is_secondary ? "global-secondary" : "",
  ])

  # A restore or a secondary takes the master user and database from the
  # source. Sending them anyway is a perpetual diff on a ForceNew attribute.
  inherits_credentials = length(local.data_sources) > 0

  # Whether a password was supplied is not the secret; the password is. Without
  # nonsensitive() every output that mentions the credential path is tainted.
  password_supplied = nonsensitive(var.master_password != "")
  manage_password   = !local.is_secondary && var.manage_master_user_password
  static_password   = !local.inherits_credentials && !var.manage_master_user_password && local.password_supplied

  credential_source = (
    local.is_secondary ? "replicated from the global primary"
    : local.manage_password ? "rds-managed secret"
    : local.static_password ? "plaintext in terraform state"
    : local.restore_from_snapshot ? "inherited from snapshot"
    : local.restore_from_pitr ? "inherited from point-in-time source"
    : "none"
  )

  create_rotation_schedule = local.create && local.manage_password && (
    var.master_password_rotation.schedule_expression != "" ? true : var.master_password_rotation.automatically_after_days > 0
  )

  # "<name>-final" alone collides the second time a cluster of the same name is
  # deleted, and the delete fails - at the worst moment. The suffix is the
  # cluster's creation time, captured once.
  final_snapshot_identifier = (
    var.final_snapshot_identifier != "" ? var.final_snapshot_identifier
    : try("${var.name}-final-${formatdate("YYYYMMDDhhmm", one(terraform_data.created_at[*].output))}", "${var.name}-final")
  )

  # -------------------------------------------------------------------------
  # Encryption. Each purpose falls back to the module key, then to the
  # AWS-managed key for its service ("").
  # -------------------------------------------------------------------------

  storage_kms_key_arn          = var.kms_key_arn
  master_secret_kms_key_arn    = var.master_user_secret_kms_key_arn != "" ? var.master_user_secret_kms_key_arn : var.kms_key_arn
  performance_insights_kms_key = var.performance_insights_kms_key_arn != "" ? var.performance_insights_kms_key_arn : var.kms_key_arn
  logs_kms_key_arn             = var.cloudwatch_logs_kms_key_arn != "" ? var.cloudwatch_logs_kms_key_arn : var.kms_key_arn
  activity_stream_kms_key_arn  = var.activity_stream.kms_key_arn != "" ? var.activity_stream.kms_key_arn : var.kms_key_arn
  managed_secret_arn           = try(aws_rds_cluster.this[0].master_user_secret[0].secret_arn, "")
  managed_secret_kms_key_id    = try(aws_rds_cluster.this[0].master_user_secret[0].kms_key_id, "")
  create_log_groups            = local.create && var.create_log_groups
  activity_stream_enabled      = local.create && var.activity_stream.enabled

  # Keys and topics have to be in the cluster's region. An ARN from another
  # region fails at apply, after the groups and roles already exist - the
  # usual slip when a global secondary copies the primary's inputs.
  arns_in_another_region = [
    for a in compact([
      var.kms_key_arn, var.master_user_secret_kms_key_arn, var.performance_insights_kms_key_arn,
      var.cloudwatch_logs_kms_key_arn, var.activity_stream.kms_key_arn, var.sns_topic_arn, var.proxy.secret_kms_key_arn,
    ]) : a if !strcontains(a, ":${local.region}:")
  ]

  # -------------------------------------------------------------------------
  # Instances
  # -------------------------------------------------------------------------

  instances = {
    for k, i in var.instances : k => {
      identifier                   = "${var.name}-${k}"
      instance_class               = i.instance_class != "" ? i.instance_class : var.instance_class
      availability_zone            = i.availability_zone
      promotion_tier               = i.promotion_tier
      ca_cert_identifier           = i.ca_cert_identifier != "" ? i.ca_cert_identifier : var.ca_cert_identifier
      preferred_maintenance_window = i.preferred_maintenance_window != "" ? i.preferred_maintenance_window : var.preferred_maintenance_window
      tags                         = i.tags
    }
  }

  serverless_instances = [for k, i in local.instances : k if i.instance_class == "db.serverless"]
  burstable_instances  = [for k, i in local.instances : k if startswith(i.instance_class, "db.t")]
  uses_serverless      = length(local.serverless_instances) > 0
  auto_pause           = local.uses_serverless && var.serverlessv2_scaling_configuration.min_capacity == 0

  # Readers exist when there is more than one instance, or autoscaling keeps
  # at least one. Reader alarms and the AZ check key off this.
  has_readers = length(local.instances) > 1 ? true : (var.reader_autoscaling.enabled && var.reader_autoscaling.min_capacity > 0)

  pinned_azs = distinct([for i in values(local.instances) : i.availability_zone if i.availability_zone != ""])
  # Every instance pinned, all to the same AZ.
  instances_share_one_az = length(local.instances) > 1 && length(local.pinned_azs) == 1 && length([for i in values(local.instances) : i if i.availability_zone == ""]) == 0

  # The instance a failover should target to restore the intended layout: the
  # lowest promotion tier, then the first key.
  failover_order  = sort([for k, i in local.instances : format("%02d|%s", i.promotion_tier, k)])
  failover_target = length(local.failover_order) > 0 ? split("|", local.failover_order[0])[1] : ""

  monitoring_enabled     = var.enhanced_monitoring_interval > 0
  create_monitoring_role = local.create && local.monitoring_enabled && var.create_monitoring_role
  monitoring_role_arn = (
    !local.monitoring_enabled ? null
    : var.create_monitoring_role ? one(aws_iam_role.monitoring[*].arn)
    : var.monitoring_role_arn
  )

  custom_endpoint_unknown_members = flatten([
    for k, e in var.custom_endpoints : [
      for m in concat(e.static_members, e.excluded_members) : "${k}:${m}" if !contains(keys(var.instances), m)
    ]
  ])

  # -------------------------------------------------------------------------
  # Network
  # -------------------------------------------------------------------------

  create_subnet_group     = local.create && var.create_db_subnet_group
  subnet_group_to_create  = var.db_subnet_group_name != "" ? var.db_subnet_group_name : var.name
  db_subnet_group_name    = var.create_db_subnet_group ? one(aws_db_subnet_group.this[*].name) : var.db_subnet_group_name
  create_security_group   = local.create && var.create_security_group
  security_group_ids      = concat([for sg in aws_security_group.this : sg.id], var.vpc_security_group_ids)
  private_ipv4_pattern    = "^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.)"
  unique_local_v6_pattern = "^f[cd]"

  # Ingress from outside RFC 1918, CGNAT and IPv6 unique-local space. Valid in
  # a hybrid estate, but every one should be explainable.
  non_private_ingress = concat(
    [for k, r in var.ingress_rules : k if(r.cidr_ipv4 == "" ? false : !can(regex(local.private_ipv4_pattern, r.cidr_ipv4)))],
    [for k, r in var.ingress_rules : k if(r.cidr_ipv6 == "" ? false : !can(regex(local.unique_local_v6_pattern, lower(r.cidr_ipv6))))],
    [for k, r in var.proxy.ingress_rules : "proxy:${k}" if(r.cidr_ipv4 == "" ? false : !can(regex(local.private_ipv4_pattern, r.cidr_ipv4)))],
    [for k, r in var.proxy.ingress_rules : "proxy:${k}" if(r.cidr_ipv6 == "" ? false : !can(regex(local.unique_local_v6_pattern, lower(r.cidr_ipv6))))],
  )

  # -------------------------------------------------------------------------
  # Parameters. Lowest precedence first: recommended, caller, TLS.
  # -------------------------------------------------------------------------

  create_cluster_parameter_group = local.create && var.create_cluster_parameter_group
  create_db_parameter_group      = local.create && var.create_db_parameter_group

  cluster_parameter_group_name = var.create_cluster_parameter_group ? one(aws_rds_cluster_parameter_group.this[*].name) : var.cluster_parameter_group_name
  db_parameter_group_name      = var.create_db_parameter_group ? one(aws_db_parameter_group.this[*].name) : var.db_parameter_group_name

  # tomap() on both, or the conditional cannot unify two object types with
  # different attributes.
  recommended_cluster_parameters_by_engine = local.is_postgres ? tomap({
    log_min_duration_statement  = { value = "5000", apply_method = "immediate" }
    log_lock_waits              = { value = "1", apply_method = "immediate" }
    log_autovacuum_min_duration = { value = "10000", apply_method = "immediate" }
    }) : tomap({
    slow_query_log             = { value = "1", apply_method = "immediate" }
    long_query_time            = { value = "5", apply_method = "immediate" }
    log_output                 = { value = "FILE", apply_method = "immediate" }
    innodb_print_all_deadlocks = { value = "1", apply_method = "immediate" }
  })
  recommended_cluster_parameters = var.recommended_parameters ? local.recommended_cluster_parameters_by_engine : tomap({})

  tls_parameter_name  = local.is_postgres ? "rds.force_ssl" : "require_secure_transport"
  tls_parameter_value = local.is_postgres ? "1" : "ON"
  tls_parameter = var.enforce_tls ? tomap({
    (local.tls_parameter_name) = { value = local.tls_parameter_value, apply_method = "immediate" }
  }) : tomap({})

  # A caller value for the TLS parameter that disagrees with enforce_tls. It
  # would be silently overwritten, so it is refused instead. "1", "ON" and
  # "true" all mean on to the engine.
  tls_parameter_conflict = var.enforce_tls ? !contains(["1", "on", "true"], lower(try(var.cluster_parameters[local.tls_parameter_name].value, local.tls_parameter_value))) : false

  effective_cluster_parameters = merge(local.recommended_cluster_parameters, var.cluster_parameters, local.tls_parameter)

  # TLS is enforced only when the module writes the parameter group. A brought
  # group might enforce it; the module cannot tell.
  tls_enforced = var.enforce_tls && var.create_cluster_parameter_group

  # Aurora MySQL exports a log type whether or not the engine writes it: audit
  # and general need their switches, or the log group stays empty.
  mysql_exports_without_switch = local.is_postgres ? [] : compact([
    contains(var.enabled_cloudwatch_logs_exports, "audit") ? (try(local.effective_cluster_parameters["server_audit_logging"].value, "0") == "1" ? "" : "audit (server_audit_logging)") : "",
    contains(var.enabled_cloudwatch_logs_exports, "general") ? (try(local.effective_cluster_parameters["general_log"].value, "0") == "1" ? "" : "general (general_log)") : "",
  ])

  # -------------------------------------------------------------------------
  # RDS Proxy
  # -------------------------------------------------------------------------

  proxy_enabled               = local.create && var.proxy.enabled
  create_proxy_role           = local.proxy_enabled && var.proxy.create_role
  create_proxy_security_group = local.proxy_enabled && var.proxy.create_security_group
  proxy_engine_family         = local.is_postgres ? "POSTGRESQL" : "MYSQL"
  proxy_subnet_ids            = length(var.proxy.subnet_ids) > 0 ? var.proxy.subnet_ids : var.subnet_ids
  proxy_uses_master_secret    = length(var.proxy.secret_arns) == 0
  proxy_secret_arns           = local.proxy_uses_master_secret ? [local.managed_secret_arn] : var.proxy.secret_arns
  proxy_secret_kms_key_arn = (
    var.proxy.secret_kms_key_arn != "" ? var.proxy.secret_kms_key_arn
    : local.proxy_uses_master_secret ? local.master_secret_kms_key_arn
    : ""
  )
  proxy_role_arn           = var.proxy.create_role ? one(aws_iam_role.proxy[*].arn) : var.proxy.role_arn
  proxy_security_group_ids = var.proxy.create_security_group ? [for sg in aws_security_group.proxy : sg.id] : var.proxy.security_group_ids

  # -------------------------------------------------------------------------
  # Observability
  # -------------------------------------------------------------------------

  alarms_enabled = local.create && var.create_alarms
  events_enabled = local.create && var.create_event_subscriptions

  log_group_names = { for l in var.enabled_cloudwatch_logs_exports : l => "/aws/rds/cluster/${var.name}/${l}" }

  # -------------------------------------------------------------------------
  # Security posture, computed once and reused by preconditions and outputs
  # -------------------------------------------------------------------------

  # Every purpose that would fall back to an AWS-managed key. require_cmk
  # refuses the plan when this is non-empty.
  purposes_without_cmk = compact([
    local.storage_kms_key_arn == "" ? "storage" : "",
    local.manage_password ? (local.master_secret_kms_key_arn == "" ? "master secret" : "") : "",
    var.performance_insights_enabled ? (local.performance_insights_kms_key == "" ? "performance insights" : "") : "",
    length(var.enabled_cloudwatch_logs_exports) == 0 ? "" : (
      !var.create_log_groups ? "log groups (created by RDS, without a key)" : (local.logs_kms_key_arn == "" ? "log groups" : "")
    ),
    var.activity_stream.enabled ? (local.activity_stream_kms_key_arn == "" ? "activity stream" : "") : "",
  ])

  # A full minor pin with automatic minor upgrades: after AWS upgrades, the next
  # plan tries to go back. A major-only version does not have this problem.
  version_is_full_pin      = local.is_postgres ? strcontains(var.engine_version, ".") : strcontains(var.engine_version, "mysql_aurora")
  minor_upgrade_fights_pin = var.auto_minor_version_upgrade && local.version_is_full_pin

  # Scale-to-zero needs a recent minor. With a major-only version AWS picks a
  # recent one, so only an explicit old minor is flagged.
  auto_pause_minimum_minor = { "13" = 15, "14" = 12, "15" = 7, "16" = 3 }
  auto_pause_version_too_old = !local.auto_pause ? false : (
    local.is_postgres
    ? try(tonumber(split(".", var.engine_version)[1]) < lookup(local.auto_pause_minimum_minor, split(".", var.engine_version)[0], 0), false)
    : try(tonumber(join("", formatlist("%03d", slice(split(".", var.engine_version), 3, 5)))) < 3008, false)
  )

  # A family override that names another engine or major leaves the module's
  # parameter groups on the wrong family - found at apply, or at the next
  # major upgrade.
  family_mismatch = var.parameter_group_family == "" ? false : var.parameter_group_family != local.derived_family

  acknowledged = toset(var.acknowledged_checks)

  # -------------------------------------------------------------------------
  # Rules that compare two inputs. Terraform 1.7 allows a validation to read
  # only its own variable, so these are preconditions on the cluster - still
  # at plan, before anything is created.
  # -------------------------------------------------------------------------

  missing_required_tags = [for k in var.required_tag_keys : k if(contains(keys(var.tags), k) ? trimspace(var.tags[k]) == "" : true)]

  engine_version_matches_engine = (
    local.is_postgres
    ? can(regex("^[0-9]{2}(\\.[0-9]{1,2})?$", var.engine_version))
    : can(regex("^8\\.[0-9](\\.mysql_aurora\\.[0-9]+\\.[0-9]+\\.[0-9]+)?$", var.engine_version))
  )

  log_types_for_engine     = local.is_postgres ? ["postgresql", "iam-db-auth-error", "instance"] : ["audit", "error", "general", "slowquery", "iam-db-auth-error", "instance"]
  log_exports_wrong_engine = [for l in var.enabled_cloudwatch_logs_exports : l if !contains(local.log_types_for_engine, l)]

  iam_roles_wrong_feature = [
    for k, r in var.cluster_iam_roles : k
    if(local.is_postgres ? r.feature_name == "" : r.feature_name != "")
  ]
}
