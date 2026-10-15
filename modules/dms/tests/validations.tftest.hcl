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

# One failing-case run per variable whose validations had none. Each value
# trips exactly one validation of the named variable while every other input
# stays at the baseline, so expect_failures on the variable means that
# validation and nothing else.

run "alarm_cdc_latency_seconds_rejects_below_the_30_second_floor" {
  command = plan

  variables {
    alarm_cdc_latency_seconds = 10
  }

  expect_failures = [var.alarm_cdc_latency_seconds]
}

run "alarm_cpu_percent_rejects_zero" {
  command = plan

  variables {
    alarm_cpu_percent = 0
  }

  expect_failures = [var.alarm_cpu_percent]
}

run "alarm_free_storage_bytes_rejects_between_0_and_1_gib" {
  command = plan

  variables {
    alarm_free_storage_bytes = 1
  }

  expect_failures = [var.alarm_free_storage_bytes]
}

run "alarm_freeable_memory_bytes_rejects_under_128_mib" {
  command = plan

  variables {
    alarm_freeable_memory_bytes = 1
  }

  expect_failures = [var.alarm_freeable_memory_bytes]
}

run "alarm_validation_failed_records_rejects_negative" {
  command = plan

  variables {
    alarm_validation_failed_records = -1
  }

  expect_failures = [var.alarm_validation_failed_records]
}

run "allocated_storage_gb_rejects_under_the_5_gb_floor" {
  command = plan

  variables {
    allocated_storage_gb = 4
  }

  expect_failures = [var.allocated_storage_gb]
}

run "certificates_rejects_pem_and_wallet_both_set" {
  command = plan

  variables {
    certificates = {
      rds-ca = {
        pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"
      }
      bad = {
        pem    = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"
        wallet = "d2FsbGV0"
      }
    }
  }

  expect_failures = [var.certificates]
}

run "compute_mode_rejects_not_provisioned_or_serverless" {
  command = plan

  variables {
    compute_mode = "hybrid"
  }

  expect_failures = [var.compute_mode]
}

run "engine_version_rejects_not_x_y_z" {
  command = plan

  variables {
    engine_version = "3.5"
  }

  expect_failures = [var.engine_version]
}

run "instance_class_rejects_missing_the_dms_prefix" {
  command = plan

  variables {
    instance_class = "t3.medium"
  }

  expect_failures = [var.instance_class]
}

run "instance_event_categories_rejects_not_a_dms_instance_category" {
  command = plan

  variables {
    instance_event_categories = ["boom"]
  }

  expect_failures = [var.instance_event_categories]
}

run "kms_key_arn_rejects_not_a_kms_key_arn" {
  command = plan

  variables {
    kms_key_arn = "not-an-arn"
  }

  expect_failures = [var.kms_key_arn]
}

run "log_retention_days_rejects_not_a_cloudwatch_retention_period" {
  command = plan

  variables {
    log_retention_days = 31
  }

  expect_failures = [var.log_retention_days]
}

run "name_rejects_uppercase_and_underscore" {
  command = plan

  variables {
    name = "Bad_Name"
  }

  expect_failures = [var.name]
}

run "network_type_rejects_not_ipv4_or_dual" {
  command = plan

  variables {
    network_type = "IPV6"
  }

  expect_failures = [var.network_type]
}

run "permissions_boundary_arn_rejects_not_an_iam_policy_arn" {
  command = plan

  variables {
    permissions_boundary_arn = "boundary"
  }

  expect_failures = [var.permissions_boundary_arn]
}

run "preferred_maintenance_window_rejects_uppercase_day" {
  command = plan

  variables {
    preferred_maintenance_window = "Sun:03:00-sun:04:00"
  }

  expect_failures = [var.preferred_maintenance_window]
}

run "security_group_ids_rejects_empty" {
  command = plan

  variables {
    security_group_ids = []
  }

  expect_failures = [var.security_group_ids]
}

run "serverless_rejects_not_a_dcu_size" {
  command = plan

  variables {
    serverless = {
      min_dcu = 3
    }
  }

  expect_failures = [var.serverless]
}

run "sns_topic_arn_rejects_not_an_sns_topic_arn" {
  command = plan

  variables {
    sns_topic_arn = "alerts"
  }

  expect_failures = [var.sns_topic_arn]
}

run "sns_topic_kms_key_arn_rejects_not_a_kms_arn" {
  command = plan

  variables {
    sns_topic_kms_key_arn = "key"
  }

  expect_failures = [var.sns_topic_kms_key_arn]
}

run "subnet_ids_rejects_one_subnet" {
  command = plan

  variables {
    subnet_ids = ["subnet-0123456789abcdef0"]
  }

  expect_failures = [var.subnet_ids]
}

run "tags_rejects_a_reserved_aws_prefix" {
  command = plan

  variables {
    tags = {
      "aws:owner" = "x"
    }
  }

  expect_failures = [var.tags]
}

run "task_event_categories_rejects_not_a_dms_task_category" {
  command = plan

  variables {
    task_event_categories = ["boom"]
  }

  expect_failures = [var.task_event_categories]
}
