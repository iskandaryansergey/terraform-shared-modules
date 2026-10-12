# The hardening guards: a customer key that would be silently dropped when
# Performance Insights or the managed secret is turned on for an existing
# cluster, activity stream mode on aurora-mysql, the key policy requirements
# for activity stream consumers and the proxy, proxy TLS, and egress outside
# private address space.
#
# Plan runs first. The apply runs at the end build an existing cluster, and
# every run after them in this file plans against it.

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
# Activity streams
# ---------------------------------------------------------------------------

run "sync_activity_stream_on_mysql_is_refused" {
  command = plan

  variables {
    acknowledged_checks             = var.every_check
    engine                          = "aurora-mysql"
    engine_version                  = "8.0.mysql_aurora.3.08.0"
    enabled_cloudwatch_logs_exports = ["error"]
    activity_stream                 = { enabled = true, mode = "sync" }
  }

  expect_failures = [aws_rds_cluster.this]
}

run "async_activity_stream_on_mysql_is_accepted" {
  command = plan

  variables {
    acknowledged_checks             = var.every_check
    engine                          = "aurora-mysql"
    engine_version                  = "8.0.mysql_aurora.3.08.0"
    enabled_cloudwatch_logs_exports = ["error"]
    activity_stream                 = { enabled = true, mode = "async" }
  }

  assert {
    condition     = aws_rds_cluster_activity_stream.this[0].mode == "async"
    error_message = "async is the mode aurora-mysql supports."
  }
}

run "the_activity_stream_consumer_gets_an_encryption_context_condition" {
  command = plan

  variables {
    activity_stream = { enabled = true, mode = "async" }
  }

  assert {
    condition = length([
      for r in output.kms_key_policy_requirements : r
      if contains(keys(r.condition), "kms:EncryptionContext:aws:rds:dbc-id") && !contains(keys(r.condition), "kms:ViaService")
    ]) == 1
    error_message = "the consumer decrypts with KMS directly: its statement must condition on aws:rds:dbc-id, not on kms:ViaService."
  }

  assert {
    condition = length([
      for r in output.kms_key_policy_requirements : r
      if r.key == var.kms_key_arn && contains(keys(r.condition), "kms:ViaService") && r.principal == "the principal running terraform"
    ]) >= 1
    error_message = "RDS still uses the key through the service, so the terraform principal keeps its ViaService statement."
  }
}

# ---------------------------------------------------------------------------
# RDS Proxy
# ---------------------------------------------------------------------------

run "the_proxy_secret_key_is_in_the_key_policy_requirements" {
  command = plan

  variables {
    proxy = {
      enabled            = true
      secret_arns        = ["arn:aws:secretsmanager:eu-west-2:111122223333:secret:app-AbCdEf"]
      secret_kms_key_arn = "arn:aws:kms:eu-west-2:111122223333:key/99999999-2222-3333-4444-555555555555"
      ingress_rules      = { app = { referenced_security_group_id = "sg-0123456789abcdef0", description = "orders service" } }
      egress_rules       = { secrets = { referenced_security_group_id = "sg-0123456789abcdef5", port = 443, description = "Secrets Manager endpoint" } }
    }
  }

  assert {
    condition = length([
      for r in output.kms_key_policy_requirements : r
      if r.key == "arn:aws:kms:eu-west-2:111122223333:key/99999999-2222-3333-4444-555555555555"
      && contains(keys(r.condition), "kms:ViaService") && length(r.actions) == 1 && contains(r.actions, "kms:Decrypt")
    ]) == 1
    error_message = "the key owner must be told to let the proxy role decrypt its secrets through Secrets Manager."
  }
}

run "a_proxy_without_tls_warns" {
  command = plan

  variables {
    proxy = {
      enabled           = true
      use_master_secret = true
      require_tls       = false
      ingress_rules     = { app = { referenced_security_group_id = "sg-0123456789abcdef0", description = "orders service" } }
      egress_rules      = { secrets = { referenced_security_group_id = "sg-0123456789abcdef5", port = 443, description = "Secrets Manager endpoint" } }
    }
  }

  expect_failures = [check.the_proxy_requires_tls]
}

run "a_proxy_with_tls_does_not_warn" {
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
    condition     = aws_db_proxy.this[0].require_tls
    error_message = "require_tls defaults to true."
  }
}

# ---------------------------------------------------------------------------
# Egress
# ---------------------------------------------------------------------------

run "egress_to_a_public_range_warns" {
  command = plan

  variables {
    egress_rules = { partner = { cidr_ipv4 = "203.0.113.0/24", port = 443, description = "partner API" } }
  }

  expect_failures = [check.egress_stays_inside_private_address_space]
}

run "egress_inside_private_space_does_not_warn" {
  command = plan

  variables {
    egress_rules = { onprem = { cidr_ipv4 = "10.40.0.0/16", port = 443, description = "on-prem service" } }
  }

  assert {
    condition     = length(output.governance.egress_outside_private_ranges) == 0
    error_message = "a private destination is not reported."
  }
}

run "acknowledged_public_egress_is_reported_in_governance" {
  command = plan

  variables {
    acknowledged_checks = ["egress_stays_inside_private_address_space"]
    egress_rules        = { partner = { cidr_ipv4 = "203.0.113.0/24", port = 443, description = "partner API" } }
  }

  assert {
    condition     = output.governance.egress_outside_private_ranges == ["partner"]
    error_message = "governance lists the rule a reviewer has to explain."
  }
}

# ---------------------------------------------------------------------------
# A customer key dropped when a feature is turned on for an existing cluster
# ---------------------------------------------------------------------------

run "a_new_cluster_gets_both_keys" {
  command = plan

  # On a create the planned key is the configured one: no refusal.
  assert {
    condition = alltrue([
      aws_rds_cluster.this[0].performance_insights_kms_key_id == var.kms_key_arn,
      aws_rds_cluster.this[0].master_user_secret_kms_key_id == var.kms_key_arn,
    ])
    error_message = "a new cluster is created with the configured keys."
  }
}

# Builds the existing cluster: no Performance Insights and no managed secret,
# so AWS reports neither key.
run "an_existing_cluster_without_either_feature" {
  command = apply

  variables {
    acknowledged_checks          = var.every_check
    performance_insights_enabled = false
    manage_master_user_password  = false
    master_password              = "correct-horse-battery"
    allow_plaintext_credentials  = true
  }

  override_resource {
    target = aws_rds_cluster.this
    values = {
      performance_insights_kms_key_id = ""
      master_user_secret_kms_key_id   = ""
      master_user_secret              = []
    }
  }
}

run "turning_on_performance_insights_without_its_key_is_refused" {
  command = plan

  variables {
    acknowledged_checks          = var.every_check
    performance_insights_enabled = true
    manage_master_user_password  = false
    master_password              = "correct-horse-battery"
    allow_plaintext_credentials  = true
  }

  expect_failures = [aws_rds_cluster_instance.this]
}

run "turning_on_the_managed_secret_without_its_key_is_refused" {
  command = plan

  variables {
    acknowledged_checks          = var.every_check
    performance_insights_enabled = false
  }

  expect_failures = [aws_rds_cluster_instance.this]
}

run "turning_them_on_without_a_customer_key_is_allowed" {
  command = plan

  # No customer key configured: the AWS-managed key is what was asked for.
  variables {
    acknowledged_checks = var.every_check
    kms_key_arn         = ""
  }

  assert {
    condition     = aws_rds_cluster.this[0].performance_insights_enabled
    error_message = "with no customer key there is nothing to lose, so the plan goes ahead."
  }
}
