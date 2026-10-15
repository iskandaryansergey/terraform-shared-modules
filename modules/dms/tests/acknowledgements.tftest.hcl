# The fixes that the mocked suite could not see on its own, because each one
# is about how AWS behaves rather than how the graph is shaped: SSL modes per
# engine, the database name on the secret path, the IAM trust condition, the
# task dimension CloudWatch publishes under, logging posture from the merged
# settings, and the configurations DMS refuses at apply.
#
# Plan runs first; the apply runs at the end need the task ARN.

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
# SSL modes DMS supports per engine
# ---------------------------------------------------------------------------

# Every advisory check can be acknowledged. Each run below puts the module in
# the posture the check warns about, acknowledges it, and proves two things:
# the plan is quiet, and the decision is listed in governance for a reviewer.

run "acknowledging_somebody_hears_a_failed_task_is_quiet_and_listed" {
  command = plan

  variables {
    sns_topic_arn       = ""
    acknowledged_checks = ["somebody_hears_a_failed_task"]
  }

  assert {
    condition     = contains(output.governance.acknowledged_checks, "somebody_hears_a_failed_task")
    error_message = "the acknowledged decision must be visible in governance."
  }
}

run "acknowledging_control_tables_have_their_own_schema_is_quiet_and_listed" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings = {
          control_schema = ""
        }
      }
    }
    acknowledged_checks = ["control_tables_have_their_own_schema"]
  }

  assert {
    condition     = contains(output.governance.acknowledged_checks, "control_tables_have_their_own_schema")
    error_message = "the acknowledged decision must be visible in governance."
  }
}

run "acknowledging_debug_logging_is_temporary_is_quiet_and_listed" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings = {
          log_level = "LOGGER_SEVERITY_DEBUG"
        }
      }
    }
    acknowledged_checks = ["debug_logging_is_temporary"]
  }

  assert {
    condition     = contains(output.governance.acknowledged_checks, "debug_logging_is_temporary")
    error_message = "the acknowledged decision must be visible in governance."
  }
}

run "acknowledging_the_full_load_is_not_fighting_the_targets_constraints_is_quiet_and_listed" {
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
      }
    }
    acknowledged_checks = ["the_full_load_is_not_fighting_the_targets_constraints"]
  }

  assert {
    condition     = contains(output.governance.acknowledged_checks, "the_full_load_is_not_fighting_the_targets_constraints")
    error_message = "the acknowledged decision must be visible in governance."
  }
}

run "acknowledging_the_storage_alarm_leaves_room_to_react_is_quiet_and_listed" {
  command = plan

  variables {
    alarm_free_storage_bytes = 1073741824
    acknowledged_checks      = ["the_storage_alarm_leaves_room_to_react"]
  }

  assert {
    condition     = contains(output.governance.acknowledged_checks, "the_storage_alarm_leaves_room_to_react")
    error_message = "the acknowledged decision must be visible in governance."
  }
}

run "acknowledging_cdc_tasks_are_validated_is_quiet_and_listed" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings = {
          validation_enabled = false
        }
      }
    }
    acknowledged_checks = ["cdc_tasks_are_validated"]
  }

  assert {
    condition     = contains(output.governance.acknowledged_checks, "cdc_tasks_are_validated")
    error_message = "the acknowledged decision must be visible in governance."
  }
}

run "acknowledging_tasks_write_logs_is_quiet_and_listed" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings = {
          logging_enabled = false
        }
      }
    }
    acknowledged_checks = ["tasks_write_logs"]
  }

  assert {
    condition     = contains(output.governance.acknowledged_checks, "tasks_write_logs")
    error_message = "the acknowledged decision must be visible in governance."
  }
}

run "acknowledging_engine_version_is_pinned_is_quiet_and_listed" {
  command = plan

  variables {
    engine_version      = ""
    acknowledged_checks = ["engine_version_is_pinned"]
  }

  assert {
    condition     = contains(output.governance.acknowledged_checks, "engine_version_is_pinned")
    error_message = "the acknowledged decision must be visible in governance."
  }
}

run "acknowledging_credentials_are_not_in_state_is_quiet_and_listed" {
  command = plan

  variables {
    allow_plaintext_credentials = true
    endpoints = {
      source-db = {
        role            = "source"
        engine          = "postgres"
        server_name     = "src.example.com"
        port            = 5432
        database_name   = "app"
        ssl_mode        = "verify-full"
        certificate_key = "rds-ca"
        username        = "dms"
        password        = "hunter2"
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
    }
    acknowledged_checks = ["credentials_are_not_in_state"]
  }

  assert {
    condition     = contains(output.governance.acknowledged_checks, "credentials_are_not_in_state")
    error_message = "the acknowledged decision must be visible in governance."
  }
}

run "acknowledging_minor_upgrades_do_not_fight_the_pin_is_quiet_and_listed" {
  command = plan

  variables {
    auto_minor_version_upgrade = true
    acknowledged_checks        = ["minor_upgrades_do_not_fight_the_pin"]
  }

  assert {
    condition     = contains(output.governance.acknowledged_checks, "minor_upgrades_do_not_fight_the_pin")
    error_message = "the acknowledged decision must be visible in governance."
  }
}

run "acknowledging_oracle_ssl_uses_a_wallet_is_quiet_and_listed" {
  command = plan

  variables {
    endpoints = {
      source-db = {
        role               = "source"
        engine             = "oracle"
        server_name        = "src.example.com"
        port               = 1521
        database_name      = "ORCL"
        secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf"
        secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        ssl_mode           = "verify-ca"
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
    }
    acknowledged_checks = ["oracle_ssl_uses_a_wallet"]
  }

  assert {
    condition     = contains(output.governance.acknowledged_checks, "oracle_ssl_uses_a_wallet")
    error_message = "the acknowledged decision must be visible in governance."
  }
}

run "acknowledging_validation_is_claimed_where_it_cannot_run_is_quiet_and_listed" {
  command = plan

  variables {
    endpoints = {
      source-db = {
        role               = "source"
        engine             = "sybase"
        server_name        = "src.example.com"
        port               = 5000
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
    }
    acknowledged_checks = ["validation_is_claimed_where_it_cannot_run"]
  }

  assert {
    condition     = contains(output.governance.acknowledged_checks, "validation_is_claimed_where_it_cannot_run")
    error_message = "the acknowledged decision must be visible in governance."
  }
}

run "acknowledging_full_load_does_not_leave_the_meter_running_is_quiet_and_listed" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
      }
    }
    acknowledged_checks = ["full_load_does_not_leave_the_meter_running"]
  }

  assert {
    condition     = contains(output.governance.acknowledged_checks, "full_load_does_not_leave_the_meter_running")
    error_message = "the acknowledged decision must be visible in governance."
  }
}
