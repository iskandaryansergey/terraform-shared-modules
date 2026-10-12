# The features beyond the core migration: validation-only tasks and an
# honest validation posture, premigration assessments, acknowledged checks and
# the key policy contract.
#
# Plan runs first; the apply runs at the end need task ARNs.

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
# Validation-only tasks
# ---------------------------------------------------------------------------

run "a_validation_only_task_validates_and_never_prepares_the_target" {
  command = plan

  variables {
    validation_tasks = { app-check = { task = "app" } }
  }

  assert {
    condition = alltrue([
      jsondecode(aws_dms_replication_task.validation["app-check"].replication_task_settings).ValidationSettings.ValidationOnly,
      jsondecode(aws_dms_replication_task.validation["app-check"].replication_task_settings).ValidationSettings.EnableValidation,
      jsondecode(aws_dms_replication_task.validation["app-check"].replication_task_settings).FullLoadSettings.TargetTablePrepMode == "DO_NOTHING",
      aws_dms_replication_task.validation["app-check"].migration_type == "full-load",
      aws_dms_replication_task.validation["app-check"].table_mappings == aws_dms_replication_task.this["app"].table_mappings,
      aws_dms_replication_task.validation["app-check"].replication_task_id == "test-migration-app-check",
      !aws_dms_replication_task.validation["app-check"].start_replication_task,
    ])
    error_message = "a validation-only task compares with the parent's mappings, never touches the target, and is created stopped."
  }

  assert {
    condition = alltrue([
      !jsondecode(aws_dms_replication_task.this["app"].replication_task_settings).ValidationSettings.ValidationOnly,
      output.governance.validation_only_tasks == { app-check = "full-load of app" },
    ])
    error_message = "the migration task itself is unchanged, and governance lists the validator."
  }
}

run "regression_a_destructive_parent_does_not_make_a_destructive_validator" {
  command = plan

  variables {
    allow_destructive_target_prep = true
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings        = { target_table_prep_mode = "TRUNCATE_BEFORE_LOAD" }
      }
    }
    validation_tasks = { app-check = { task = "app", mode = "cdc" } }
  }

  assert {
    condition     = jsondecode(aws_dms_replication_task.validation["app-check"].replication_task_settings).FullLoadSettings.TargetTablePrepMode == "DO_NOTHING"
    error_message = "a validator inherits the parent's settings but must never truncate the target it is checking."
  }
}

run "a_validation_task_naming_no_task_is_rejected" {
  command = plan

  variables {
    validation_tasks = { orphan = { task = "missing" } }
  }

  expect_failures = [var.validation_tasks]
}

run "cdc_validation_of_a_full_load_task_is_refused" {
  command = plan

  variables {
    acknowledged_checks = ["full_load_does_not_leave_the_meter_running"]
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
      }
    }
    validation_tasks = { app-check = { task = "app", mode = "cdc" } }
  }

  expect_failures = [aws_dms_replication_subnet_group.this]
}

run "a_validation_task_key_colliding_with_a_task_is_refused" {
  command = plan

  variables {
    validation_tasks = { app = { task = "app" } }
  }

  expect_failures = [aws_dms_replication_subnet_group.this]
}

run "validation_tasks_are_refused_in_serverless_mode" {
  command = plan

  variables {
    compute_mode        = "serverless"
    acknowledged_checks = ["serverless_replication_is_not_watched_by_this_module"]
    validation_tasks    = { app-check = { task = "app" } }
  }

  expect_failures = [aws_dms_replication_subnet_group.this]
}

run "validators_get_validation_alarms_but_no_latency_alarms" {
  command = plan

  variables {
    validation_tasks = { app-check = { task = "app" } }
  }

  assert {
    condition = alltrue([
      length(aws_cloudwatch_metric_alarm.cdc_latency_target) == 1,
      contains(keys(aws_cloudwatch_metric_alarm.validation_failed), "validate:app-check"),
      contains(keys(aws_cloudwatch_metric_alarm.validation_failed), "task:app"),
      length(aws_cloudwatch_metric_alarm.validation_suspended) == 2,
    ])
    error_message = "a validation-only task moves no data and publishes no latency: it gets validation alarms, never a breaching latency alarm."
  }

  assert {
    condition = alltrue([
      for a in values(aws_cloudwatch_metric_alarm.validation_failed) :
      a.treat_missing_data == "notBreaching" && a.metric_name == "ValidationFailedOverallCount"
    ])
    error_message = "a task that validated everything and stopped publishes nothing, and that is the good outcome."
  }
}

run "validation_on_an_engine_dms_cannot_validate_is_reported" {
  command = plan

  variables {
    endpoints = {
      source-db = {
        role            = "source"
        engine          = "sybase"
        server_name     = "src.example.com"
        port            = 5000
        database_name   = "app"
        secret_arn      = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf"
        ssl_mode        = "verify-full"
        certificate_key = "rds-ca"
      }
      target-db = {
        role            = "target"
        engine          = "aurora-postgresql"
        server_name     = "tgt.example.com"
        port            = 5432
        database_name   = "app"
        secret_arn      = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:tgt-AbCdEf"
        ssl_mode        = "verify-full"
        certificate_key = "rds-ca"
        postgres        = { after_connect_script = "SET session_replication_role = replica;" }
      }
    }
  }

  assert {
    condition     = output.governance.tasks_whose_validation_cannot_run == ["app"] && length(aws_cloudwatch_metric_alarm.validation_failed) == 0
    error_message = "DMS does not validate an SAP ASE source: governance says so, and no validation alarm is created for it."
  }

  expect_failures = [check.validation_is_claimed_where_it_cannot_run]
}

run "an_s3_target_partitioned_by_month_cannot_be_validated" {
  command = plan

  variables {
    s3_targets = {
      lake = {
        bucket_name             = "migration-lake"
        bucket_folder           = "orders"
        kms_key_arn             = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        date_partition_sequence = "YYYYMM"
      }
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

  expect_failures = [check.validation_is_claimed_where_it_cannot_run]
}

# ---------------------------------------------------------------------------
# Acknowledged checks
# ---------------------------------------------------------------------------

run "an_acknowledged_check_is_silent_and_recorded" {
  command = plan

  variables {
    multi_az            = false
    acknowledged_checks = ["replication_survives_an_az"]
  }

  assert {
    condition     = length(output.governance.acknowledged_checks) == 1 && contains(output.governance.acknowledged_checks, "replication_survives_an_az")
    error_message = "the acknowledgement is listed for the reviewer."
  }
}

run "an_unacknowledged_single_az_instance_warns" {
  command = plan

  variables {
    multi_az = false
  }

  expect_failures = [check.replication_survives_an_az]
}

run "acknowledging_a_check_that_does_not_exist_is_rejected" {
  command = plan

  variables {
    acknowledged_checks = ["no_such_check"]
  }

  expect_failures = [var.acknowledged_checks]
}

# ---------------------------------------------------------------------------
# Key policy requirements
# ---------------------------------------------------------------------------

run "the_key_owner_is_told_what_each_key_must_allow" {
  command = plan

  assert {
    condition = length([
      for r in output.kms_key_policy_requirements : r
      if r.principal == "Service: logs.eu-west-1.amazonaws.com"
      && contains(values(r.condition), "arn:aws:logs:eu-west-1:111122223333:log-group:dms-tasks-test-migration")
    ]) == 1
    error_message = "the log group's key needs a CloudWatch Logs grant scoped to this log group, or the create fails mid-apply."
  }

  assert {
    condition = length([
      for r in output.kms_key_policy_requirements : r
      if contains(keys(r.condition), "kms:ViaService") ? r.condition["kms:ViaService"] == "secretsmanager.eu-west-1.amazonaws.com" : false
    ]) == 1
    error_message = "the secret key appears once, for the roles that read the endpoint secrets."
  }
}

run "create_false_leaves_the_key_contract_null" {
  command = plan

  variables {
    create = false
  }

  assert {
    condition     = output.kms_key_policy_requirements == null && output.premigration_assessment == null
    error_message = "create = false produces no contracts."
  }
}

# ---------------------------------------------------------------------------
# Premigration assessment
# ---------------------------------------------------------------------------

run "the_assessment_role_is_scoped_to_its_prefix" {
  command = plan

  variables {
    premigration_assessment = {
      enabled     = true
      bucket_name = "migration-evidence"
      kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
    }
  }

  assert {
    condition = alltrue([
      jsondecode(aws_iam_role_policy.assessment[0].policy).Statement[0].Resource == ["arn:aws:s3:::migration-evidence/dms-assessments/*"],
      jsondecode(aws_iam_role_policy.assessment[0].policy).Statement[2].Condition.StringEquals["kms:ViaService"] == "s3.eu-west-1.amazonaws.com",
      jsondecode(aws_iam_role.assessment[0].assume_role_policy).Statement[0].Principal.Service == "dms.amazonaws.com",
    ])
    error_message = "the role writes only under its prefix, uses the key only through S3, and is assumed only by DMS."
  }
}

run "an_sse_s3_assessment_needs_no_key_statement" {
  command = plan

  variables {
    premigration_assessment = { enabled = true, bucket_name = "migration-evidence" }
  }

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.assessment[0].policy).Statement) == 2
    error_message = "with SSE_S3 there is no key to grant."
  }
}

run "a_brought_assessment_role_creates_nothing" {
  command = plan

  variables {
    premigration_assessment = {
      enabled     = true
      bucket_name = "migration-evidence"
      create_role = false
      role_arn    = "arn:aws:iam::111122223333:role/central-dms-assessment"
    }
  }

  assert {
    condition     = length(aws_iam_role.assessment) == 0 && output.premigration_assessment.role_arn == "arn:aws:iam::111122223333:role/central-dms-assessment"
    error_message = "a brought role is used, not created."
  }
}

run "enabling_the_assessment_without_a_bucket_is_rejected" {
  command = plan

  variables {
    premigration_assessment = { enabled = true }
  }

  expect_failures = [var.premigration_assessment]
}

run "require_cmk_refuses_sse_s3_assessment_reports" {
  command = plan

  variables {
    require_cmk             = true
    premigration_assessment = { enabled = true, bucket_name = "migration-evidence" }
  }

  expect_failures = [aws_dms_replication_subnet_group.this]
}

run "the_assessment_is_refused_in_serverless_mode" {
  command = plan

  variables {
    compute_mode            = "serverless"
    acknowledged_checks     = ["serverless_replication_is_not_watched_by_this_module"]
    premigration_assessment = { enabled = true, bucket_name = "migration-evidence" }
  }

  expect_failures = [aws_dms_replication_subnet_group.this]
}

run "the_assessment_command_always_encrypts_and_names_the_task" {
  command = apply

  variables {
    premigration_assessment = { enabled = true, bucket_name = "migration-evidence" }
    validation_tasks        = { app-check = { task = "app" } }
  }

  assert {
    condition = alltrue([
      strcontains(output.premigration_assessment.commands["app"].start, "--replication-task-arn arn:aws:dms:eu-west-1:111122223333:task:MOCKTASK"),
      strcontains(output.premigration_assessment.commands["app"].start, "--result-encryption-mode SSE_S3"),
      strcontains(output.premigration_assessment.commands["app"].start, "--result-location-folder dms-assessments/test-migration/app"),
      output.premigration_assessment.encryption == "SSE_S3",
    ])
    error_message = "the command names the task, writes under the migration's prefix, and never omits the encryption mode - AWS stores results unencrypted without it."
  }

  assert {
    condition     = output.validation_task_arns["app-check"] == "arn:aws:dms:eu-west-1:111122223333:task:MOCKTASK"
    error_message = "validation task ARNs are exposed for the operator commands."
  }
}
