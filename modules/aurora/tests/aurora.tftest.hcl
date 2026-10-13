# One file, the module's main paths: the default cluster, each engine and
# compute shape, bring-your-own, proxy, autoscaling, global roles, create =
# false, and a sample of the refusals and checks.
#
# Plan-only against mock_provider: no AWS account and no credentials. It
# proves what the module plans, not that AWS accepts it.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  # The module reads the region from endpoint: v6 deprecates name and v5 has
  # no region attribute.
  mock_data "aws_region" {
    defaults = { endpoint = "ec2.eu-west-2.amazonaws.com" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_resource "aws_rds_cluster" {
    defaults = {
      id  = "test-cluster"
      arn = "arn:aws:rds:eu-west-2:111122223333:cluster:test-cluster"
      master_user_secret = [{
        secret_arn    = "arn:aws:secretsmanager:eu-west-2:111122223333:secret:rds!cluster-abc"
        kms_key_id    = "arn:aws:kms:eu-west-2:111122223333:key/11111111-2222-3333-4444-555555555555"
        secret_status = "active"
      }]
      engine_lifecycle_support = "open-source-rds-extended-support-disabled"
    }
  }
  mock_resource "aws_rds_global_cluster" {
    defaults = {
      id  = "orders-global"
      arn = "arn:aws:rds::111122223333:global-cluster:orders-global"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/mock" }
  }
  # The proxy target validates target_group_name; AWS calls it "default".
  mock_resource "aws_db_proxy_default_target_group" {
    defaults = { name = "default" }
  }
}

# A fully configured cluster that trips no advisory check: terraform test
# fails a run on any check it does not expect.
variables {
  name = "test-cluster"

  tags = {
    Environment = "test"
    CostCentre  = "cc-1234"
    Owner       = "data-platform"
  }
  required_tag_keys = ["CostCentre", "Owner"]

  engine         = "aurora-postgresql"
  engine_version = "16.4"
  instance_class = "db.r7g.large"
  instances = {
    "1" = {}
    "2" = {}
  }

  database_name = "app"
  kms_key_arn   = "arn:aws:kms:eu-west-2:111122223333:key/11111111-2222-3333-4444-555555555555"

  vpc_id     = "vpc-0123456789abcdef0"
  subnet_ids = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1", "subnet-0123456789abcdef2"]
  ingress_rules = {
    app    = { referenced_security_group_id = "sg-0123456789abcdef0", description = "orders service" }
    onprem = { cidr_ipv4 = "10.20.0.0/16", description = "data centre via DX" }
  }

  enabled_cloudwatch_logs_exports = ["postgresql"]
  sns_topic_arn                   = "arn:aws:sns:eu-west-2:111122223333:db-alerts"

  # Runs that deviate from the baseline for another reason acknowledge every
  # check, so an incidental warning is not mistaken for the thing under test.
  every_check = [
    "cluster_survives_an_az", "instances_are_spread_across_azs", "somebody_hears_a_failover",
    "deleting_the_cluster_is_protected", "deleting_the_cluster_leaves_a_snapshot", "backups_cover_a_week",
    "query_level_metrics_exist", "database_logs_leave_the_instance", "log_retention_is_bounded",
    "tls_is_enforced_where_the_module_can_see", "the_module_controls_who_connects",
    "ingress_stays_inside_private_address_space", "egress_stays_inside_private_address_space", "something_can_connect", "credentials_are_not_in_state",
    "engine_version_is_exact", "minor_upgrades_do_not_fight_the_pin", "extended_support_matches_the_setting",
    "extended_support_is_a_decision", "auto_pause_has_an_engine_that_supports_it", "the_proxy_has_clients",
    "the_proxy_can_reach_secrets_manager", "the_proxy_can_decrypt_its_secrets", "the_proxy_requires_tls",
    "master_secret_key_is_the_one_configured", "performance_insights_key_is_the_one_configured",
    "activity_stream_key_is_the_one_configured", "database_insights_advanced_on_a_global_member",
    "major_upgrade_applies_immediately", "reader_autoscaling_has_a_reader",
    "mysql_log_exports_have_their_switches", "parameter_group_family_matches_the_engine",
    "iam_auth_failures_are_logged", "iam_auth_has_memory_headroom", "master_user_keeps_its_password",
    "audit_logs_are_retained",
  ]
}

# ---------------------------------------------------------------------------
# The default cluster
# ---------------------------------------------------------------------------

run "the_default_cluster_has_the_expected_resources" {
  command = plan

  assert {
    condition = alltrue([
      length(aws_rds_cluster.this) == 1,
      length(aws_rds_cluster_instance.this) == 2,
      length(aws_rds_global_cluster.this) == 0,
      length(aws_db_subnet_group.this) == 1,
      length(aws_security_group.this) == 1,
      length(aws_vpc_security_group_ingress_rule.this) == 2,
      length(aws_vpc_security_group_egress_rule.this) == 0,
      length(aws_rds_cluster_parameter_group.this) == 1,
      length(aws_db_parameter_group.this) == 1,
      length(aws_iam_role.monitoring) == 1,
      length(aws_cloudwatch_log_group.this) == 1,
    ])
    error_message = "a default cluster is one cluster, two instances, a subnet group, a security group with one rule per ingress_rules key and no egress, both parameter groups, the monitoring role and a log group per export."
  }

  assert {
    condition = alltrue([
      length(aws_db_proxy.this) == 0,
      length(aws_rds_cluster_activity_stream.this) == 0,
      length(aws_appautoscaling_target.readers) == 0,
      length(aws_rds_cluster_endpoint.this) == 0,
      length(aws_secretsmanager_secret_rotation.master) == 0,
    ])
    error_message = "proxy, activity stream, reader autoscaling, custom endpoints and a rotation schedule are opt-in."
  }

  assert {
    condition = alltrue([
      length(aws_cloudwatch_metric_alarm.writer_cpu) == 1,
      length(aws_cloudwatch_metric_alarm.reader_cpu) == 1,
      length(aws_cloudwatch_metric_alarm.replica_lag) == 1,
      length(aws_cloudwatch_metric_alarm.transaction_ids) == 1,
      length(aws_cloudwatch_metric_alarm.freeable_memory) == 2,
      length(aws_db_event_subscription.cluster) == 1,
      length(aws_db_event_subscription.instances) == 1,
    ])
    error_message = "the default alarms and both event subscriptions are created."
  }
}

run "the_default_cluster_is_secure" {
  command = plan

  assert {
    condition = alltrue([
      aws_rds_cluster.this[0].storage_encrypted,
      aws_rds_cluster.this[0].kms_key_id == var.kms_key_arn,
      aws_rds_cluster.this[0].deletion_protection,
      !aws_rds_cluster.this[0].skip_final_snapshot,
      aws_rds_cluster.this[0].manage_master_user_password,
      aws_rds_cluster.this[0].master_password == null,
    ])
    error_message = "encrypted with the given key, deletion-protected, a final snapshot, and the password held by RDS in Secrets Manager rather than in state."
  }

  assert {
    condition     = contains([for p in aws_rds_cluster_parameter_group.this[0].parameter : "${p.name}=${p.value}"], "rds.force_ssl=1")
    error_message = "TLS is enforced in the cluster parameter group."
  }

  assert {
    condition     = alltrue([for i in aws_rds_cluster_instance.this : !i.publicly_accessible])
    error_message = "no instance is publicly accessible."
  }
}

run "names_and_tags_follow_the_inputs" {
  command = plan

  assert {
    condition = alltrue([
      aws_rds_cluster.this[0].cluster_identifier == "test-cluster",
      aws_rds_cluster_instance.this["1"].identifier == "test-cluster-1",
      aws_rds_cluster_instance.this["2"].identifier == "test-cluster-2",
      aws_db_subnet_group.this[0].name == "test-cluster",
      aws_rds_cluster_parameter_group.this[0].name == "test-cluster-cluster-aurora-postgresql16",
      aws_rds_cluster_parameter_group.this[0].family == "aurora-postgresql16",
    ])
    error_message = "the cluster, instances, subnet group and parameter groups are named from name, the groups for the engine family."
  }

  assert {
    condition = alltrue([
      aws_rds_cluster.this[0].tags["CostCentre"] == "cc-1234",
      aws_rds_cluster.this[0].tags["ManagedBy"] == "Terraform",
      aws_rds_cluster_instance.this["1"].tags["Owner"] == "data-platform",
      aws_rds_cluster_instance.this["1"].tags["Name"] == "test-cluster-1",
    ])
    error_message = "caller tags and the module's own reach the cluster and its instances."
  }
}

# ---------------------------------------------------------------------------
# Engines and compute
# ---------------------------------------------------------------------------

run "aurora_mysql_gets_its_port_family_and_tls_parameter" {
  command = plan

  variables {
    engine                          = "aurora-mysql"
    engine_version                  = "8.0.mysql_aurora.3.08.0"
    enabled_cloudwatch_logs_exports = ["error"]
  }

  assert {
    condition = alltrue([
      aws_rds_cluster.this[0].port == 3306,
      aws_rds_cluster_parameter_group.this[0].family == "aurora-mysql8.0",
      contains([for p in aws_rds_cluster_parameter_group.this[0].parameter : "${p.name}=${p.value}"], "require_secure_transport=ON"),
    ])
    error_message = "aurora-mysql listens on 3306, uses the aurora-mysql8.0 family and enforces TLS with require_secure_transport."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.transaction_ids) == 0
    error_message = "transaction ID wraparound is a PostgreSQL alarm."
  }
}

run "serverless_v2_gets_a_scaling_range_and_acu_alarms" {
  command = plan

  variables {
    instance_class                     = "db.serverless"
    serverlessv2_scaling_configuration = { min_capacity = 0.5, max_capacity = 4 }
  }

  assert {
    condition = alltrue([
      aws_rds_cluster.this[0].serverlessv2_scaling_configuration[0].min_capacity == 0.5,
      aws_rds_cluster.this[0].serverlessv2_scaling_configuration[0].max_capacity == 4,
    ])
    error_message = "the scaling range reaches the cluster."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.acu_utilization) == 2 && length(aws_cloudwatch_metric_alarm.free_local_storage) == 0
    error_message = "serverless instances get an ACU alarm each and no local-storage alarm (AWS does not publish it for them)."
  }
}

run "reader_autoscaling_targets_the_cluster" {
  command = plan

  variables {
    reader_autoscaling = { enabled = true, min_capacity = 1, max_capacity = 3 }
  }

  assert {
    condition = alltrue([
      aws_appautoscaling_target.readers[0].resource_id == "cluster:test-cluster",
      aws_appautoscaling_target.readers[0].max_capacity == 3,
      length(aws_appautoscaling_policy.readers) == 1,
    ])
    error_message = "reader autoscaling scales this cluster's replica count with one target-tracking policy."
  }
}

# ---------------------------------------------------------------------------
# Bring your own
# ---------------------------------------------------------------------------

run "brought_network_and_parameter_groups_are_used_not_created" {
  command = plan

  variables {
    acknowledged_checks            = var.every_check
    create_db_subnet_group         = false
    db_subnet_group_name           = "corp-db"
    create_security_group          = false
    vpc_security_group_ids         = ["sg-0123456789abcdef9"]
    ingress_rules                  = {}
    create_cluster_parameter_group = false
    cluster_parameter_group_name   = "corp-cluster-pg"
    create_db_parameter_group      = false
    db_parameter_group_name        = "corp-instance-pg"
  }

  assert {
    condition = alltrue([
      length(aws_db_subnet_group.this) == 0,
      length(aws_security_group.this) == 0,
      length(aws_rds_cluster_parameter_group.this) == 0,
      length(aws_db_parameter_group.this) == 0,
    ])
    error_message = "with create_* = false the module creates none of these."
  }

  assert {
    condition = alltrue([
      aws_rds_cluster.this[0].db_subnet_group_name == "corp-db",
      aws_rds_cluster.this[0].db_cluster_parameter_group_name == "corp-cluster-pg",
      aws_rds_cluster_instance.this["1"].db_parameter_group_name == "corp-instance-pg",
      length(aws_rds_cluster.this[0].vpc_security_group_ids) == 1,
      contains(aws_rds_cluster.this[0].vpc_security_group_ids, "sg-0123456789abcdef9"),
    ])
    error_message = "the brought names and IDs reach the cluster and the instances."
  }
}

# ---------------------------------------------------------------------------
# RDS Proxy
# ---------------------------------------------------------------------------

run "the_proxy_fronts_the_cluster_with_its_own_group" {
  command = plan

  variables {
    proxy = {
      enabled           = true
      use_master_secret = true
      ingress_rules     = { app = { referenced_security_group_id = "sg-0123456789abcdef0", description = "orders service" } }
      egress_rules      = { secrets = { referenced_security_group_id = "sg-0123456789abcdef5", port = 443, description = "Secrets Manager endpoint" } }
    }
  }

  assert {
    condition = alltrue([
      length(aws_db_proxy.this) == 1,
      length(aws_db_proxy_target.this) == 1,
      length(aws_db_proxy_endpoint.reader) == 1,
      length(aws_iam_role.proxy) == 1,
      length(aws_security_group.proxy) == 1,
      length(aws_vpc_security_group_egress_rule.proxy_to_cluster) == 1,
      length(aws_vpc_security_group_ingress_rule.from_proxy) == 1,
    ])
    error_message = "the proxy, its target, reader endpoint, role and security group, and the proxy-to-database rules in both groups."
  }

  assert {
    condition = alltrue([
      aws_db_proxy.this[0].engine_family == "POSTGRESQL",
      aws_db_proxy.this[0].require_tls,
      aws_db_proxy_target.this[0].db_cluster_identifier == "test-cluster",
    ])
    error_message = "a PostgreSQL proxy requiring TLS, targeting this cluster."
  }
}

# ---------------------------------------------------------------------------
# Global database
# ---------------------------------------------------------------------------

run "a_global_primary_creates_the_global_cluster" {
  command = plan

  variables {
    acknowledged_checks         = var.every_check
    global_cluster_role         = "primary"
    global_cluster_identifier   = "orders-global"
    manage_master_user_password = false
    master_password             = "correct-horse-battery"
    allow_plaintext_credentials = true
  }

  assert {
    condition = alltrue([
      length(aws_rds_global_cluster.this) == 1,
      aws_rds_global_cluster.this[0].global_cluster_identifier == "orders-global",
      aws_rds_global_cluster.this[0].storage_encrypted,
    ])
    error_message = "a primary creates the encrypted global cluster."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.writer_cpu) == 1 && length(aws_cloudwatch_metric_alarm.global_rpo_lag) == 0
    error_message = "a primary has a writer; RPO lag is a secondary-region alarm."
  }
}

run "a_headless_secondary_has_no_writer_alarms" {
  command = plan

  variables {
    acknowledged_checks         = var.every_check
    global_cluster_role         = "secondary"
    global_cluster_identifier   = "orders-global"
    manage_master_user_password = false
    database_name               = ""
    instances                   = {}
  }

  assert {
    condition = alltrue([
      length(aws_rds_global_cluster.this) == 0,
      length(aws_rds_cluster_instance.this) == 0,
      aws_rds_cluster.this[0].global_cluster_identifier == "orders-global",
    ])
    error_message = "a headless secondary joins the global cluster with no instances and creates no global cluster of its own."
  }

  assert {
    condition = alltrue([
      length(aws_cloudwatch_metric_alarm.writer_cpu) == 0,
      length(aws_cloudwatch_metric_alarm.replica_lag) == 0,
      length(aws_cloudwatch_metric_alarm.global_rpo_lag) == 1,
    ])
    error_message = "a secondary has no writer, so no writer alarms - but it watches its RPO lag."
  }
}

# ---------------------------------------------------------------------------
# create = false
# ---------------------------------------------------------------------------

run "create_false_plans_nothing" {
  command = plan

  variables {
    create = false
  }

  assert {
    condition = alltrue([
      length(aws_rds_cluster.this) == 0,
      length(aws_rds_cluster_instance.this) == 0,
      length(aws_security_group.this) == 0,
      length(aws_iam_role.monitoring) == 0,
      length(aws_cloudwatch_metric_alarm.writer_cpu) == 0,
    ])
    error_message = "create = false must plan no resources."
  }

  assert {
    condition     = output.connection == null && output.governance == null && output.cluster_endpoint == null
    error_message = "create = false must leave the outputs null."
  }
}

# ---------------------------------------------------------------------------
# Contract outputs
# ---------------------------------------------------------------------------

run "the_contract_outputs_describe_the_cluster" {
  command = plan

  assert {
    condition = alltrue([
      output.connection.port == 5432,
      output.connection.engine == "aurora-postgresql",
      output.connection.tls_required,
    ])
    error_message = "connection carries the port, the engine and that TLS is required."
  }

  assert {
    condition = alltrue([
      output.governance.credential_source == "rds-managed secret",
      output.governance.tls_enforced == "yes",
      output.governance.deletion_protection,
      length(output.governance.purposes_without_cmk) == 0,
      output.governance.instance_count == 2,
      output.governance.master_password_rotation == "rds default (every 7 days)",
    ])
    error_message = "governance reports the managed secret, TLS, deletion protection, every purpose on the CMK and the instance count."
  }
}

run "a_rotation_schedule_replaces_the_rds_default" {
  command = plan

  variables {
    master_password_rotation = {
      automatically_after_days = 90
      duration                 = "3h"
    }
  }

  assert {
    condition = alltrue([
      length(aws_secretsmanager_secret_rotation.master) == 1,
      aws_secretsmanager_secret_rotation.master[0].rotation_rules[0].automatically_after_days == 90,
      aws_secretsmanager_secret_rotation.master[0].rotation_rules[0].duration == "3h",
      !aws_secretsmanager_secret_rotation.master[0].rotate_immediately,
    ])
    error_message = "the schedule is set on the RDS-managed secret, and applying it does not rotate the password."
  }

  assert {
    condition     = output.governance.master_password_rotation == "every 90 days"
    error_message = "governance reports the schedule that is applied."
  }
}

# ---------------------------------------------------------------------------
# A sample of what the module refuses
# ---------------------------------------------------------------------------

run "a_name_rds_cannot_use_is_rejected" {
  command = plan

  variables {
    name = "Orders_DB"
  }

  expect_failures = [var.name]
}

run "ingress_from_anywhere_is_rejected" {
  command = plan

  variables {
    ingress_rules = { anywhere = { cidr_ipv4 = "0.0.0.0/0", description = "everyone" } }
  }

  expect_failures = [var.ingress_rules]
}

run "a_plaintext_password_needs_its_acknowledgement" {
  command = plan

  variables {
    acknowledged_checks         = var.every_check
    manage_master_user_password = false
    master_password             = "correct-horse-battery"
  }

  expect_failures = [aws_rds_cluster.this]
}

run "a_public_cluster_needs_its_acknowledgement" {
  command = plan

  variables {
    acknowledged_checks = var.every_check
    publicly_accessible = true
  }

  expect_failures = [aws_rds_cluster.this]
}

run "turning_tls_off_needs_its_acknowledgement" {
  command = plan

  variables {
    acknowledged_checks = var.every_check
    enforce_tls         = false
  }

  expect_failures = [aws_rds_cluster.this]
}

run "alarms_without_a_topic_are_refused" {
  command = plan

  variables {
    acknowledged_checks = var.every_check
    sns_topic_arn       = ""
  }

  expect_failures = [aws_rds_cluster.this]
}

# ---------------------------------------------------------------------------
# Advisory checks warn, and can be acknowledged
# ---------------------------------------------------------------------------

run "a_single_instance_warns" {
  command = plan

  variables {
    instances = { "1" = {} }
  }

  expect_failures = [check.cluster_survives_an_az]
}

run "an_acknowledged_check_is_silent" {
  command = plan

  variables {
    instances           = { "1" = {} }
    acknowledged_checks = ["cluster_survives_an_az"]
  }

  assert {
    condition     = contains(output.governance.acknowledged_checks, "cluster_survives_an_az")
    error_message = "the acknowledgement is recorded in governance for the reviewer."
  }
}

# ---------------------------------------------------------------------------
# Key policy contract, version 2
# ---------------------------------------------------------------------------

# Apply, not plan: the proxy role ARN and the cluster resource ID in the
# contract are unknown until the mock creates them. Last in the file, so no
# plan run inherits this state.
run "every_key_policy_requirement_is_machine_readable" {
  command = apply

  variables {
    acknowledged_checks = var.every_check
    activity_stream     = { enabled = true, mode = "async" }
    proxy = {
      enabled           = true
      use_master_secret = true
      ingress_rules     = { app = { referenced_security_group_id = "sg-0123456789abcdef0", description = "orders service" } }
      egress_rules      = { secrets = { referenced_security_group_id = "sg-0123456789abcdef5", port = 443, description = "Secrets Manager endpoint" } }
    }
  }

  assert {
    condition     = length(output.kms_key_policy_requirements) == 9
    error_message = "storage, master secret and its readers, Performance Insights and its readers, log groups, both activity stream statements and the proxy: every entry is in scope."
  }

  assert {
    condition = alltrue([
      for r in output.kms_key_policy_requirements :
      can(regex("^[A-Za-z0-9]+$", r.sid)) && can(tolist(r.principals.services)) && can(tolist(r.principals.arns)) && can(tolist(r.principals.roles))
      && length(r.actions) > 0 && can(tolist(r.conditions))
    ])
    error_message = "modules/kms compiles only entries with sid, principals.services/arns/roles, actions and conditions; anything else is reported as prose."
  }

  assert {
    condition     = length(distinct([for r in output.kms_key_policy_requirements : r.sid])) == length(output.kms_key_policy_requirements)
    error_message = "sids are unique: modules/kms builds statement Sids from them."
  }

  assert {
    condition = alltrue([
      for r in output.kms_key_policy_requirements :
      length(r.principals.services) + length(r.principals.arns) + length(r.principals.roles) > 0
      && alltrue([for c in r.conditions : length(c.values) > 0 && c.test != "" && c.variable != ""])
    ])
    error_message = "every entry names a principal, and every condition has a test, a variable and values."
  }

  assert {
    condition = alltrue([
      for r in output.kms_key_policy_requirements : !contains([for c in r.conditions : c.variable], "kms:ViaService")
      if length(r.principals.arns) + length(r.principals.roles) == 0
    ])
    error_message = "a service principal calls KMS itself; kms:ViaService on it would deny every call."
  }

  assert {
    condition = alltrue([
      for r in output.kms_key_policy_requirements : contains(r.principals.arns, aws_iam_role.proxy[0].arn) if r.sid == "ProxySecrets"
    ])
    error_message = "the proxy entry names the role the module created, not a symbolic role."
  }
}
