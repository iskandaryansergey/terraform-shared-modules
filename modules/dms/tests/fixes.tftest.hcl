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

  # The schema has to come from somewhere: DO_NOTHING means DMS creates nothing.
  sql_scripts = {
    pre_data = [
      { name = "01-schema", path = "sql/01-schema.sql", sha256 = "0000000000000000000000000000000000000000000000000000000000000001" },
    ]
    post_data = [
      { name = "02-indexes", path = "sql/02-indexes.sql", sha256 = "0000000000000000000000000000000000000000000000000000000000000002" },
      { name = "03-sequences", path = "sql/03-sequences.sql", sha256 = "0000000000000000000000000000000000000000000000000000000000000003" },
    ]
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

run "verify_full_on_an_oracle_source_is_rejected" {
  command = plan

  # DMS supports only none and verify-ca for Oracle.
  variables {
    certificates = {
      rds-ca        = { pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----" }
      oracle-wallet = { wallet = "b3JhY2xlLXdhbGxldA==" }
    }
    endpoints = {
      source-db = {
        role               = "source"
        engine             = "oracle"
        server_name        = "src.example.com"
        port               = 1521
        database_name      = "ORCLPDB1"
        secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf"
        secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        ssl_mode           = "verify-full"
        certificate_key    = "oracle-wallet"
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

  expect_failures = [var.endpoints]
}

run "verify_ca_with_a_wallet_on_an_oracle_source_is_accepted" {
  command = plan

  variables {
    certificates = {
      rds-ca        = { pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----" }
      oracle-wallet = { wallet = "b3JhY2xlLXdhbGxldA==" }
    }
    endpoints = {
      source-db = {
        role               = "source"
        engine             = "oracle"
        server_name        = "src.example.com"
        port               = 1521
        database_name      = "ORCLPDB1"
        secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf"
        secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        ssl_mode           = "verify-ca"
        certificate_key    = "oracle-wallet"
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
    condition     = aws_dms_endpoint.this["source-db"].ssl_mode == "verify-ca"
    error_message = "verify-ca with an Oracle wallet is the supported way to verify an Oracle source."
  }
}

run "an_oracle_source_verified_with_a_pem_warns" {
  command = plan

  variables {
    certificates = {
      rds-ca        = { pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----" }
      oracle-wallet = { wallet = "b3JhY2xlLXdhbGxldA==" }
    }
    endpoints = {
      source-db = {
        role               = "source"
        engine             = "oracle"
        server_name        = "src.example.com"
        port               = 1521
        database_name      = "ORCLPDB1"
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
        postgres           = { after_connect_script = "SET session_replication_role = replica;" }
      }
    }
  }

  expect_failures = [check.oracle_ssl_uses_a_wallet]
}

run "require_on_a_mysql_endpoint_is_rejected" {
  command = plan

  variables {
    endpoints = {
      source-db = {
        role       = "source"
        engine     = "mysql"
        secret_arn = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf"
        ssl_mode   = "require"
      }
    }
    tasks = {}
  }

  expect_failures = [var.endpoints]
}

run "verify_ca_on_a_sql_server_endpoint_is_rejected" {
  command = plan

  variables {
    endpoints = {
      source-db = {
        role            = "source"
        engine          = "sqlserver"
        secret_arn      = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf"
        ssl_mode        = "verify-ca"
        certificate_key = "rds-ca"
      }
    }
    tasks = {}
  }

  expect_failures = [var.endpoints]
}

# ---------------------------------------------------------------------------
# What reaches the API
# ---------------------------------------------------------------------------

run "the_database_name_reaches_dms_on_the_secret_path" {
  command = plan

  # The secret DMS reads carries host, port and credentials, not the database:
  # the provider sends database_name on the secret path too.
  assert {
    condition = alltrue([
      aws_dms_endpoint.this["source-db"].database_name == "app",
      aws_dms_endpoint.this["target-db"].database_name == "app",
      aws_dms_endpoint.this["source-db"].server_name == null,
      aws_dms_endpoint.this["source-db"].port == null,
    ])
    error_message = "database_name is sent with a secret; server_name and port still come from the secret."
  }
}

run "role_trust_follows_the_documented_source_arn" {
  command = plan

  variables {
    s3_targets = {
      lake = {
        bucket_name   = "migration-lake"
        bucket_folder = "orders"
        kms_key_arn   = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
      }
    }
  }

  assert {
    condition = alltrue([
      for r in [aws_iam_role.endpoint_secret["source-db"], aws_iam_role.s3_target["lake"]] :
      jsondecode(r.assume_role_policy).Statement[0].Condition.ArnLike["aws:SourceArn"] == "arn:aws:dms:eu-west-1:111122223333:*"
      && jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "111122223333"
    ])
    error_message = "the trust condition is any DMS resource in this account and region, as AWS documents it: DMS presents task or replication-config ARNs as well as endpoint ARNs."
  }
}

# ---------------------------------------------------------------------------
# Logging posture comes from the merged settings
# ---------------------------------------------------------------------------

run "debug_logging_through_raw_overrides_is_caught" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings = {
          raw_overrides = "{\"Logging\":{\"EnableLogging\":true,\"LogComponents\":[{\"Id\":\"SOURCE_UNLOAD\",\"Severity\":\"LOGGER_SEVERITY_DETAILED_DEBUG\"}]}}"
        }
      }
    }
  }

  assert {
    condition     = length(output.governance.task_log_levels["app"]) == 1 && contains(output.governance.task_log_levels["app"], "LOGGER_SEVERITY_DETAILED_DEBUG")
    error_message = "governance reports the severity DMS runs with, not the typed log_level the override replaced."
  }

  expect_failures = [check.debug_logging_is_temporary]
}

# ---------------------------------------------------------------------------
# Configurations DMS refuses at apply
# ---------------------------------------------------------------------------

run "full_lob_mode_into_s3_is_refused" {
  command = plan

  variables {
    s3_targets = {
      lake = {
        bucket_name   = "migration-lake"
        bucket_folder = "orders"
        kms_key_arn   = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
      }
    }
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "lake"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings        = { lob_mode = "FULL" }
      }
    }
  }

  expect_failures = [aws_dms_replication_subnet_group.this]
}

run "a_cdc_start_point_in_serverless_mode_is_refused" {
  command = plan

  variables {
    compute_mode = "serverless"
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        cdc_start_time  = "2026-10-01T00:00:00Z"
      }
    }
  }

  # Serverless also trips the "not watched by this module" check.
  expect_failures = [aws_dms_replication_subnet_group.this, check.serverless_replication_is_not_watched_by_this_module]
}

run "require_cmk_without_the_module_log_group_is_refused" {
  command = plan

  variables {
    require_cmk      = true
    create_log_group = false
  }

  expect_failures = [aws_dms_replication_subnet_group.this]
}

# ---------------------------------------------------------------------------
# Defaults that no longer trip the module's own checks
# ---------------------------------------------------------------------------

run "the_storage_alarm_follows_the_volume_by_default" {
  command = plan

  variables {
    alarm_free_storage_bytes = 0
    allocated_storage_gb     = 200
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.free_storage[0].threshold == ceil(200 * 1073741824 * 0.15)
    error_message = "with no threshold given, the alarm fires at 15% of the volume."
  }
}

run "the_log_group_survives_a_teardown_by_default" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_group.tasks[0].skip_destroy
    error_message = "destroying the migration must not delete the task logs its retention was set to keep."
  }
}

run "a_pinned_version_with_automatic_minor_upgrades_warns" {
  command = plan

  variables {
    auto_minor_version_upgrade = true
  }

  expect_failures = [check.minor_upgrades_do_not_fight_the_pin]
}

# ---------------------------------------------------------------------------
# Once the task exists: the dimension CloudWatch publishes under
# ---------------------------------------------------------------------------

run "cdc_alarms_and_commands_use_the_task_resource_id" {
  command = apply

  assert {
    condition = alltrue([
      aws_cloudwatch_metric_alarm.cdc_latency_target["app"].dimensions["ReplicationTaskIdentifier"] == "MOCKTASK",
      aws_cloudwatch_metric_alarm.cdc_latency_source["app"].dimensions["ReplicationTaskIdentifier"] == "MOCKTASK",
      output.task_resource_ids["app"] == "MOCKTASK",
    ])
    error_message = "task metrics are published under the task's resource ID - the last segment of its ARN - not under its name."
  }

  assert {
    condition     = strcontains(output.verify_commands.cdc_latency["app"], "Name=ReplicationInstanceIdentifier,Value=test-migration Name=ReplicationTaskIdentifier,Value=MOCKTASK")
    error_message = "the latency command passes the full dimension set, or CloudWatch returns no datapoints."
  }

  assert {
    condition     = strcontains(output.verify_commands.stop_task["app"], "arn:aws:dms:eu-west-1:111122223333:task:MOCKTASK")
    error_message = "operator commands carry the real task ARN, not a placeholder."
  }
}
