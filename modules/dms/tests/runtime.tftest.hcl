# Runtime failures found by the 2026-10-12 review: configurations that plan
# and apply cleanly, then make a migration hang, lose rows, or run with no way
# to tell why. Each run pins the module's answer to one of them.

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
# postgres_settings changes replace the endpoint
# ---------------------------------------------------------------------------

run "postgres_settings_are_tracked_for_replacement" {
  command = plan

  assert {
    condition     = terraform_data.postgres_settings["target-db"].input != ""
    error_message = "a PostgreSQL endpoint must hash its settings, or an edit to after_connect_script changes nothing in DMS."
  }
}

run "a_source_only_knob_does_not_replace_a_target" {
  command = plan

  variables {
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
          after_connect_script = "SET session_replication_role = replica;"
          heartbeat_frequency  = 1
        }
      }
      # The same target with the default heartbeat.
      target-db2 = {
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
          after_connect_script = "SET session_replication_role = replica;"
        }
      }
    }
  }

  # The target never receives the heartbeat, so it must not change the hash.
  assert {
    condition     = terraform_data.postgres_settings["target-db"].input == terraform_data.postgres_settings["target-db2"].input
    error_message = "the target hash must cover only the fields sent to a target."
  }

  assert {
    condition     = terraform_data.postgres_settings["source-db"].input != terraform_data.postgres_settings["target-db"].input
    error_message = "source and target endpoints hash different field sets."
  }
}

run "an_after_connect_script_change_changes_the_hash" {
  command = plan

  variables {
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
          after_connect_script = "SET session_replication_role = replica;"
        }
      }
      target-db2 = {
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
          after_connect_script = "SET session_replication_role = replica; SET work_mem = '64MB';"
        }
      }
    }
  }

  assert {
    condition     = terraform_data.postgres_settings["target-db"].input != terraform_data.postgres_settings["target-db2"].input
    error_message = "an after_connect_script edit must change the hash, or the endpoint is never replaced and DMS keeps the old script."
  }
}

# ---------------------------------------------------------------------------
# Engines whose credentials the provider drops
# ---------------------------------------------------------------------------

run "docdb_is_refused" {
  command = plan

  # ssl_mode = "none" on purpose: with the default verify-full and no
  # certificate, the certificate validation would refuse this endpoint on its
  # own and the engine allowlist could be deleted without this run noticing.
  variables {
    endpoints = {
      source-db = {
        role       = "source"
        engine     = "docdb"
        secret_arn = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf"
        ssl_mode   = "none"
      }
    }
    tasks = {}
  }

  expect_failures = [var.endpoints]
}

# ---------------------------------------------------------------------------
# S3: CdcPath with date partitioning
# ---------------------------------------------------------------------------

run "s3_default_sends_no_cdc_path" {
  command = plan

  variables {
    s3_targets = {
      lake = {
        bucket_name = "lake-bucket"
        kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
      }
    }
  }

  assert {
    condition     = aws_dms_s3_endpoint.this["lake"].cdc_path == null
    error_message = "the default S3 target must not combine CdcPath with date partitioning."
  }
}

run "s3_cdc_path_with_date_partitioning_is_refused" {
  command = plan

  variables {
    s3_targets = {
      lake = {
        bucket_name = "lake-bucket"
        kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        cdc_path    = "cdc"
      }
    }
  }

  expect_failures = [var.s3_targets]
}

# ---------------------------------------------------------------------------
# Task settings
# ---------------------------------------------------------------------------

run "defaults_fail_on_a_dropped_open_transaction" {
  command = plan

  assert {
    condition     = jsondecode(output.task_settings_json["app"]).ErrorBehavior.FailOnTransactionConsistencyBreached == true
    error_message = "an Oracle transaction open past the timeout must fail the task, not be skipped."
  }

  assert {
    condition     = jsondecode(output.task_settings_json["app"]).FullLoadSettings.TransactionConsistencyTimeout == 600
    error_message = "TransactionConsistencyTimeout should default to 600."
  }

  assert {
    condition     = jsondecode(output.task_settings_json["app"]).FullLoadSettings.StopTaskCachedChangesNotApplied == false
    error_message = "a task must not pause before cached changes unless asked."
  }
}

run "stop_before_cached_changes_renders" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings        = { stop_before_cached_changes = true }
      }
    }
  }

  assert {
    condition     = jsondecode(output.task_settings_json["app"]).FullLoadSettings.StopTaskCachedChangesNotApplied == true
    error_message = "stop_before_cached_changes must render StopTaskCachedChangesNotApplied."
  }
}

run "both_stop_points_are_refused" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings        = { stop_before_cached_changes = true, stop_after_full_load = true }
      }
    }
  }

  expect_failures = [var.tasks]
}

run "batch_apply_suspends_the_table_instead_of_degrading" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings        = { batch_apply_enabled = true }
      }
    }
  }

  assert {
    condition = alltrue([
      for k in ["DataErrorPolicy", "ApplyErrorDeletePolicy", "ApplyErrorInsertPolicy", "ApplyErrorUpdatePolicy"] :
      jsondecode(output.task_settings_json["app"]).ErrorBehavior[k] == "SUSPEND_TABLE"
    ])
    error_message = "with batch apply, data and apply errors must suspend the table."
  }
}

run "batch_apply_keeps_default_policies_when_off" {
  command = plan

  assert {
    condition     = jsondecode(output.task_settings_json["app"]).ErrorBehavior.ApplyErrorDeletePolicy == "IGNORE_RECORD"
    error_message = "without batch apply the error policies must stay as they were."
  }
}

run "batch_apply_with_full_lob_is_refused" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings        = { batch_apply_enabled = true, lob_mode = "FULL" }
      }
    }
  }

  expect_failures = [var.tasks]
}

# ---------------------------------------------------------------------------
# Account-wide service roles
# ---------------------------------------------------------------------------

run "the_account_roles_carry_no_boundary" {
  command = plan

  variables {
    create_account_service_roles = true
    permissions_boundary_arn     = "arn:aws:iam::111122223333:policy/boundary"
  }

  assert {
    condition     = aws_iam_role.dms_vpc[0].permissions_boundary == null && aws_iam_role.dms_cloudwatch_logs[0].permissions_boundary == null
    error_message = "the AWS-managed service-role policies must not be capped by a landing-zone boundary."
  }

  assert {
    condition     = aws_iam_role.endpoint_secret["source-db"].permissions_boundary == "arn:aws:iam::111122223333:policy/boundary"
    error_message = "the module's own scoped roles still carry the boundary."
  }
}

# ---------------------------------------------------------------------------
# Source prerequisites name what causes "0 rows"
# ---------------------------------------------------------------------------

run "postgres_prerequisites_require_primary_keys" {
  command = plan

  assert {
    condition     = anytrue([for p in output.source_prerequisites["postgres"] : strcontains(p.what, "primary key")])
    error_message = "PostgreSQL CDC drops UPDATE and DELETE on keyless tables; the prerequisites must say so."
  }
}
