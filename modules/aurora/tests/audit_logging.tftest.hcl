# Audit logging: pgAudit on aurora-postgresql and Advanced Auditing on
# aurora-mysql, written into the module's cluster parameter group - the
# parameters, how shared_preload_libraries is composed, the refusals and the
# retention check. Plan-only.

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
    "iam_auth_failures_are_logged", "iam_auth_has_memory_headroom", "master_user_keeps_its_password", "audit_logs_are_retained",
  ]
}


# ---------------------------------------------------------------------------
# aurora-postgresql: pgAudit
# ---------------------------------------------------------------------------

run "audit_logging_is_off_by_default" {
  command = plan

  assert {
    condition = alltrue([
      !contains(keys(output.effective_parameters.cluster), "shared_preload_libraries"),
      !contains(keys(output.effective_parameters.cluster), "pgaudit.log"),
      output.governance.audit_logging == null,
    ])
    error_message = "audit logging is opt-in and writes nothing when off."
  }
}

run "pgaudit_is_preloaded_and_configured" {
  command = plan

  variables {
    audit_logging      = { enabled = true }
    log_retention_days = 365
  }

  assert {
    condition = alltrue([
      output.effective_parameters.cluster["shared_preload_libraries"] == "pgaudit",
      output.effective_parameters.cluster["pgaudit.log"] == "ddl,role",
      output.effective_parameters.cluster["pgaudit.log_parameter"] == "0",
    ])
    error_message = "pgaudit is preloaded and logs DDL and role changes, without bind values, by default."
  }

  assert {
    condition = contains(
      [for p in aws_rds_cluster_parameter_group.this[0].parameter : "${p.name}=${p.value}=${p.apply_method}"],
      "shared_preload_libraries=pgaudit=pending-reboot"
    )
    error_message = "shared_preload_libraries is static: it must be written with pending-reboot."
  }

  assert {
    condition     = output.governance.audit_logging.mechanism == "pgaudit" && length(output.governance.audit_logging.engine_steps) == 2
    error_message = "governance says how auditing works and what the DBA still has to run."
  }
}

run "pgaudit_keeps_the_callers_preload_libraries" {
  command = plan

  variables {
    audit_logging      = { enabled = true }
    log_retention_days = 365
    cluster_parameters = { shared_preload_libraries = { value = "pg_stat_statements, pg_cron" } }
  }

  assert {
    condition     = output.effective_parameters.cluster["shared_preload_libraries"] == "pg_stat_statements,pg_cron,pgaudit"
    error_message = "the caller's libraries are kept, in order, and pgaudit is appended."
  }
}

run "pgaudit_is_not_listed_twice" {
  command = plan

  variables {
    audit_logging      = { enabled = true }
    log_retention_days = 365
    cluster_parameters = { shared_preload_libraries = { value = "pgaudit,pg_cron" } }
  }

  assert {
    condition     = output.effective_parameters.cluster["shared_preload_libraries"] == "pgaudit,pg_cron"
    error_message = "a library the caller already lists is not appended again."
  }
}

run "the_callers_audit_parameters_win" {
  command = plan

  variables {
    audit_logging      = { enabled = true, pgaudit_role = "rds_pgaudit" }
    log_retention_days = 365
    cluster_parameters = { "pgaudit.log" = { value = "all,-misc" } }
  }

  assert {
    condition     = output.effective_parameters.cluster["pgaudit.log"] == "all,-misc" && output.effective_parameters.cluster["pgaudit.role"] == "rds_pgaudit"
    error_message = "cluster_parameters override the preset; pgaudit.role is written when set."
  }
}

run "audit_needs_the_postgresql_log_export" {
  command = plan

  variables {
    acknowledged_checks             = var.every_check
    audit_logging                   = { enabled = true }
    enabled_cloudwatch_logs_exports = []
  }

  expect_failures = [aws_rds_cluster.this]
}

run "audit_needs_the_module_parameter_group" {
  command = plan

  variables {
    acknowledged_checks            = var.every_check
    audit_logging                  = { enabled = true }
    log_retention_days             = 365
    create_cluster_parameter_group = false
    cluster_parameter_group_name   = "corp-aurora-postgresql16"
  }

  expect_failures = [aws_rds_cluster.this]
}

run "short_retention_for_audit_logs_warns" {
  command = plan

  variables {
    audit_logging      = { enabled = true }
    log_retention_days = 90
  }

  expect_failures = [check.audit_logs_are_retained]
}

run "an_unknown_pgaudit_class_is_rejected" {
  command = plan

  variables {
    audit_logging = { enabled = true, pgaudit_log = "ddl,everything" }
  }

  expect_failures = [var.audit_logging]
}

# ---------------------------------------------------------------------------
# aurora-mysql: Advanced Auditing
# ---------------------------------------------------------------------------

run "mysql_advanced_auditing_is_switched_on" {
  command = plan

  variables {
    engine                          = "aurora-mysql"
    engine_version                  = "8.0.mysql_aurora.3.08.0"
    enabled_cloudwatch_logs_exports = ["error", "audit"]
    log_retention_days              = 365
    audit_logging                   = { enabled = true, mysql_excluded_users = ["rdsadmin", "monitor"] }
  }

  assert {
    condition = alltrue([
      output.effective_parameters.cluster["server_audit_logging"] == "1",
      output.effective_parameters.cluster["server_audit_events"] == "CONNECT,QUERY_DCL,QUERY_DDL",
      output.effective_parameters.cluster["server_audit_excl_users"] == "rdsadmin,monitor",
      !contains(keys(output.effective_parameters.cluster), "shared_preload_libraries"),
    ])
    error_message = "Advanced Auditing is on with the configured events and exclusions, and nothing PostgreSQL-specific is written."
  }

  assert {
    condition = contains(
      [for p in aws_rds_cluster_parameter_group.this[0].parameter : "${p.name}=${p.apply_method}"],
      "server_audit_logging=immediate"
    )
    error_message = "the Advanced Auditing parameters are dynamic and apply immediately."
  }
}

run "mysql_audit_needs_the_audit_log_export" {
  command = plan

  variables {
    acknowledged_checks             = var.every_check
    engine                          = "aurora-mysql"
    engine_version                  = "8.0.mysql_aurora.3.08.0"
    enabled_cloudwatch_logs_exports = ["error"]
    audit_logging                   = { enabled = true }
  }

  expect_failures = [aws_rds_cluster.this]
}

run "lower_case_mysql_events_are_rejected" {
  command = plan

  variables {
    audit_logging = { enabled = true, mysql_events = ["connect"] }
  }

  expect_failures = [var.audit_logging]
}

run "an_audit_export_with_the_switch_set_to_on_does_not_warn" {
  command = plan

  # AWS documents ON; the check accepts it as well as 1.
  variables {
    engine                          = "aurora-mysql"
    engine_version                  = "8.0.mysql_aurora.3.08.0"
    enabled_cloudwatch_logs_exports = ["error", "audit"]
    cluster_parameters = {
      server_audit_logging = { value = "ON", apply_method = "immediate" }
      server_audit_events  = { value = "CONNECT", apply_method = "immediate" }
    }
  }

  assert {
    condition     = output.effective_parameters.cluster["server_audit_logging"] == "ON"
    error_message = "the caller's ON reaches the parameter group."
  }
}
