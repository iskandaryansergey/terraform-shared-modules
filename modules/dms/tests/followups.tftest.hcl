# The follow-ups from the 2026-10-12 review that were first deferred:
# notifications that can actually be delivered, serverless failures, account
# roles for Redshift and DMS Serverless, settings DMS would otherwise ignore
# (VALIDATOR_EXT, apply_error_max, execute_timeout), S3 targets (batch apply,
# Glue, validation as the deployer) and the operator steps around alarms.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { name = "eu-west-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  # The account-wide service roles exist; tests that need them missing
  # override this.
  mock_data "aws_iam_roles" {
    defaults = { names = ["dms-vpc-role", "dms-cloudwatch-logs-role"] }
  }
  mock_resource "aws_dms_replication_instance" {
    defaults = {
      replication_instance_arn = "arn:aws:dms:eu-west-1:111122223333:rep:MOCKINSTANCE"
      replication_instance_id  = "mock-instance"
    }
  }
  mock_resource "aws_dms_endpoint" {
    defaults = { endpoint_arn = "arn:aws:dms:eu-west-1:111122223333:endpoint:MOCKENDPOINT" }
  }
  mock_resource "aws_dms_s3_endpoint" {
    defaults = { endpoint_arn = "arn:aws:dms:eu-west-1:111122223333:endpoint:MOCKS3" }
  }
  mock_resource "aws_dms_certificate" {
    defaults = { certificate_arn = "arn:aws:dms:eu-west-1:111122223333:cert:MOCKCERT" }
  }
  mock_resource "aws_dms_replication_task" {
    defaults = {
      replication_task_arn = "arn:aws:dms:eu-west-1:111122223333:task:MOCKTASK"
      replication_task_id  = "mock-task"
    }
  }
  mock_resource "aws_dms_replication_config" {
    defaults = { arn = "arn:aws:dms:eu-west-1:111122223333:replication-config:MOCKCONFIG" }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = { arn = "arn:aws:events:eu-west-1:111122223333:rule/mock" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/mock" }
  }
}

# A fully configured migration, not a minimal one: terraform test treats a
# failing check as an error, so a minimal baseline would fail on the module's
# own advisory checks.
variables {
  name = "test-migration"

  subnet_ids         = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  security_group_ids = ["sg-0123456789abcdef0"]

  engine_version = "3.5.3"
  kms_key_arn    = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"

  certificates = {
    rds-ca = { pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----" }
  }

  endpoints = {
    source-db = {
      role               = "source"
      engine             = "postgres"
      server_name        = "src.example.com"
      port               = 5432
      database_name      = "app"
      secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf"
      secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
      ssl_mode           = "verify-full"
      certificate_key    = "rds-ca"
    }
    target-db = {
      role               = "target"
      engine             = "aurora-postgresql"
      server_name        = "tgt.example.com"
      port               = 5432
      database_name      = "app"
      secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:tgt-AbCdEf"
      secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
      ssl_mode           = "verify-full"
      certificate_key    = "rds-ca"
      postgres = {
        # Triggers off and foreign keys deferred for the duration of the load.
        after_connect_script = "SET session_replication_role = replica;"
      }
    }
  }

  tasks = {
    app = {
      source_endpoint = "source-db"
      target_endpoint = "target-db"
      migration_type  = "full-load-and-cdc"
      table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
    }
  }

  # 15% of the 50 GB default, so the storage alarm leaves room to react.
  alarm_free_storage_bytes = 8589934592

  sns_topic_arn = "arn:aws:sns:eu-west-1:111122223333:migrations"
}




# ---------------------------------------------------------------------------
# Settings DMS would otherwise ignore
# ---------------------------------------------------------------------------

run "the_validator_logs_under_the_id_dms_keeps" {
  command = plan

  assert {
    condition     = contains([for c in jsondecode(output.task_settings_json["app"]).Logging.LogComponents : c.Id], "VALIDATOR_EXT") && !contains([for c in jsondecode(output.task_settings_json["app"]).Logging.LogComponents : c.Id], "VALIDATOR")
    error_message = "the validator component is VALIDATOR_EXT; a component DMS drops plans a diff forever, and each applied diff stops the task."
  }
}

run "apply_error_max_escalates" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings        = { apply_error_max = 5 }
      }
    }
  }

  assert {
    condition     = jsondecode(output.task_settings_json["app"]).ErrorBehavior.ApplyErrorEscalationPolicy == "STOP_TASK" && jsondecode(output.task_settings_json["app"]).ErrorBehavior.ApplyErrorEscalationCount == 5
    error_message = "apply_error_max must stop the task when reached."
  }
}

run "apply_error_max_off_keeps_logging" {
  command = plan

  assert {
    condition     = jsondecode(output.task_settings_json["app"]).ErrorBehavior.ApplyErrorEscalationPolicy == "LOG_ERROR"
    error_message = "with apply_error_max = 0 nothing escalates."
  }
}

run "execute_timeout_is_dms_default_not_zero" {
  command = plan

  assert {
    condition     = aws_dms_endpoint.this["target-db"].postgres_settings[0].execute_timeout == 60
    error_message = "the provider sends 0 for an unset execute_timeout; the module must send DMS's own default."
  }
}

# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------

run "failover_is_notified_by_default" {
  command = plan

  assert {
    condition     = contains(aws_dms_event_subscription.instance[0].event_categories, "failover")
    error_message = "multi_az is the default; a failover must reach the topic."
  }
}

run "the_topic_policy_is_spelled_out" {
  command = plan

  assert {
    condition     = toset([for s in output.notification_requirements.topic_policy_statements : s.Sid]) == toset(["DmsEventSubscriptions", "CloudWatchAlarms"])
    error_message = "the topic policy must name every publisher the module wires to it."
  }

  assert {
    condition     = output.notification_requirements.topic_policy_statements[0].Principal.Service == "dms.amazonaws.com"
    error_message = "DMS event subscriptions publish as dms.amazonaws.com."
  }
}

run "an_encrypted_topic_lists_its_key_requirements" {
  command = plan

  variables {
    sns_topic_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/99999999-2222-3333-4444-555555555555"
  }

  assert {
    condition = anytrue([
      for r in output.kms_key_policy_requirements :
      r.key == "arn:aws:kms:eu-west-1:111122223333:key/99999999-2222-3333-4444-555555555555" && strcontains(r.principal, "dms.amazonaws.com") && strcontains(r.principal, "cloudwatch.amazonaws.com")
    ])
    error_message = "an SSE-KMS topic's key must let DMS and CloudWatch publish."
  }
}

run "re_arming_the_alarms_is_a_command" {
  command = plan

  assert {
    condition     = strcontains(output.verify_commands.arm_alarms["app"], "set-alarm-state --alarm-name test-migration-app-cdc-latency-target --state-value OK")
    error_message = "verify_commands must re-arm the CDC alarms at task start."
  }
}

run "serverless_failures_reach_the_topic" {
  command = apply

  variables {
    compute_mode        = "serverless"
    acknowledged_checks = ["serverless_replication_is_not_watched_by_this_module"]
  }

  assert {
    condition = jsondecode(aws_cloudwatch_event_rule.serverless_failures[0].event_pattern) == {
      source    = ["aws.dms"]
      resources = ["arn:aws:dms:eu-west-1:111122223333:replication-config:MOCKCONFIG"]
      detail    = { category = ["Failure"] }
    }
    error_message = "the rule must match this migration's replication failures."
  }

  assert {
    condition     = aws_cloudwatch_event_target.serverless_failures[0].arn == "arn:aws:sns:eu-west-1:111122223333:migrations"
    error_message = "failures must go to sns_topic_arn."
  }

  assert {
    condition     = contains([for s in output.notification_requirements.topic_policy_statements : s.Principal.Service], "events.amazonaws.com")
    error_message = "the topic policy must then let EventBridge publish."
  }

  assert {
    condition     = contains([for r in output.account_prerequisites : r.role], "AWSServiceRoleForDMSServerless")
    error_message = "serverless needs its service-linked role."
  }
}

# ---------------------------------------------------------------------------
# Account roles
# ---------------------------------------------------------------------------

run "a_redshift_target_needs_its_staging_role" {
  command = plan

  variables {
    allow_insecure_transport = true
    acknowledged_checks      = ["transport_is_verified"]
    endpoints = {
      source-db = {
        role               = "source"
        engine             = "postgres"
        server_name        = "src.example.com"
        port               = 5432
        database_name      = "app"
        secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf"
        secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        ssl_mode           = "verify-full"
        certificate_key    = "rds-ca"
      }
      dw = {
        role          = "target"
        engine        = "redshift"
        server_name   = "dw.example.com"
        port          = 5439
        database_name = "dw"
        secret_arn    = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:dw-AbCdEf"
        ssl_mode      = "none"
      }
    }
    tasks = {}
  }

  # The mocked account has the two base roles only.
  expect_failures = [check.account_service_roles_exist]

  assert {
    condition     = contains([for r in output.account_prerequisites : r.role], "dms-access-for-endpoint")
    error_message = "a Redshift target must list dms-access-for-endpoint."
  }
}

run "the_redshift_staging_role_can_be_created" {
  command = plan

  variables {
    allow_insecure_transport     = true
    acknowledged_checks          = ["transport_is_verified"]
    create_account_service_roles = true
    endpoints = {
      dw = {
        role          = "target"
        engine        = "redshift"
        server_name   = "dw.example.com"
        port          = 5439
        database_name = "dw"
        secret_arn    = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:dw-AbCdEf"
        ssl_mode      = "none"
      }
    }
    tasks = {}
  }

  assert {
    condition     = aws_iam_role.dms_access_for_endpoint[0].name == "dms-access-for-endpoint" && aws_iam_role_policy_attachment.dms_access_for_endpoint[0].policy_arn == "arn:aws:iam::aws:policy/service-role/AmazonDMSRedshiftS3Role"
    error_message = "create_account_service_roles must create the Redshift staging role."
  }
}

run "no_redshift_no_staging_role" {
  command = plan

  variables {
    create_account_service_roles = true
  }

  assert {
    condition     = length(aws_iam_role.dms_access_for_endpoint) == 0
    error_message = "the Redshift staging role is only for a Redshift target."
  }
}

# ---------------------------------------------------------------------------
# S3 targets
# ---------------------------------------------------------------------------

run "batch_apply_into_s3_is_refused" {
  command = plan

  variables {
    s3_targets = {
      lake = { bucket_name = "lake-bucket", kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555" }
    }
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "lake"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings        = { batch_apply_enabled = true }
      }
    }
  }

  expect_failures = [aws_dms_replication_subnet_group.this]
}

run "glue_catalog_generation_gets_its_permissions" {
  command = plan

  variables {
    s3_targets = {
      lake = { bucket_name = "lake-bucket", kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555", glue_catalog_generation = true }
      raw  = { bucket_name = "raw-bucket", kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555" }
    }
  }

  assert {
    condition     = contains([for s in jsondecode(aws_iam_role_policy.s3_target["lake"].policy).Statement : s.Sid], "GenerateGlueCatalog")
    error_message = "GlueCatalogGeneration needs Glue and Athena on the endpoint role."
  }

  assert {
    condition     = !contains([for s in jsondecode(aws_iam_role_policy.s3_target["raw"].policy).Statement : s.Sid], "GenerateGlueCatalog")
    error_message = "a target without Glue generation gets no Glue permissions."
  }
}

run "s3_validation_names_what_the_deployer_needs" {
  command = plan

  variables {
    s3_targets = {
      lake = { bucket_name = "lake-bucket", kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555" }
    }
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "lake"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
      }
    }
  }

  assert {
    condition     = output.deployer_requirements.s3_target_validation.tasks == ["app"] && strcontains(output.deployer_requirements.s3_target_validation.policy, "athena:StartQueryExecution")
    error_message = "S3 validation runs as the deployer; its permissions must be listed."
  }
}

run "no_s3_validation_no_deployer_requirements" {
  command = plan

  assert {
    condition     = output.deployer_requirements == null
    error_message = "nothing extra is needed without S3 validation."
  }
}

# ---------------------------------------------------------------------------
# Contracts
# ---------------------------------------------------------------------------

run "egress_without_a_host_says_so" {
  command = plan

  variables {
    endpoints = {
      source-db = {
        role               = "source"
        engine             = "postgres"
        database_name      = "app"
        secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf"
        secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        ssl_mode           = "verify-full"
        certificate_key    = "rds-ca"
      }
      target-db = {
        role               = "target"
        engine             = "aurora-postgresql"
        server_name        = "tgt.example.com"
        port               = 5432
        database_name      = "app"
        secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:tgt-AbCdEf"
        secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        ssl_mode           = "verify-full"
        certificate_key    = "rds-ca"
        postgres           = { after_connect_script = "SET session_replication_role = replica;" }
      }
    }
  }

  assert {
    condition     = contains(output.network_contract.required_egress, "target: tgt.example.com:5432 from the replication instance")
    error_message = "a known host and port is named."
  }

  assert {
    condition     = anytrue([for e in output.network_contract.required_egress : strcontains(e, "source source-db: host and port are in its secret")])
    error_message = "an endpoint without host and port must say what to fill in, not print :0."
  }
}

run "the_heartbeat_schema_is_a_prerequisite" {
  command = plan

  assert {
    condition     = anytrue([for p in output.source_prerequisites["postgres"] : strcontains(p.what, "heartbeat schema")])
    error_message = "the heartbeat schema must exist and be writable; the prerequisites must say so."
  }
}
