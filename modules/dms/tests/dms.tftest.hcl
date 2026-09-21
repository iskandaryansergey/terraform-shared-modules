# Mocked plan tests.
#
# These prove the graph shape, the rendered task settings JSON, the IAM policy
# documents, every validation and precondition, and the governance and contract
# outputs.
#
# What they cannot prove is that a migration works. DMS failures live at
# runtime: a source without supplemental logging, a firewall that drops the
# replication instance's ENI, a task that stops at 3am. output.source_prerequisites
# and output.network_contract exist because Terraform cannot check any of it -
# and neither can this file.

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
# Graph shape
# ---------------------------------------------------------------------------

run "creates_the_expected_resource_set" {
  command = plan

  assert {
    condition     = length(aws_dms_replication_subnet_group.this) == 1
    error_message = "expected one replication subnet group."
  }

  assert {
    condition     = length(aws_dms_replication_instance.this) == 1
    error_message = "provisioned is the default compute mode, so expected one replication instance."
  }

  assert {
    condition     = length(aws_dms_replication_config.this) == 0
    error_message = "provisioned mode must not create a serverless replication config."
  }

  assert {
    condition     = length(aws_dms_endpoint.this) == 2 && length(aws_dms_replication_task.this) == 1
    error_message = "expected two endpoints and one task."
  }

  assert {
    condition     = length(aws_iam_role.endpoint_secret) == 2
    error_message = "expected one secret-reading role per endpoint that uses Secrets Manager, scoped to that secret alone."
  }

  assert {
    condition     = length(aws_iam_role.dms_vpc) == 0 && length(aws_iam_role.dms_cloudwatch_logs) == 0
    error_message = "the account-wide DMS roles must not be created by default; their names are fixed and a second module instance would collide."
  }
}

run "create_false_makes_nothing" {
  command = plan

  variables {
    create = false
  }

  assert {
    condition = alltrue([
      length(aws_dms_replication_subnet_group.this) == 0,
      length(aws_dms_replication_instance.this) == 0,
      length(aws_dms_endpoint.this) == 0,
      length(aws_dms_replication_task.this) == 0,
      length(aws_iam_role.endpoint_secret) == 0,
    ])
    error_message = "create = false must plan to nothing at all."
  }

  assert {
    condition = alltrue([
      output.governance == null,
      output.network_contract == null,
      output.verify_commands == null,
      output.account_prerequisites == null,
      length(output.endpoint_arns) == 0,
      length(output.source_prerequisites) == 0,
      output.log_group_name == null,
    ])
    error_message = "create = false must leave every output null or empty."
  }
}

run "module_creates_no_network_resources" {
  command = plan

  # BYO network. If a future change adds a security group or an endpoint here,
  # this fails and the decision becomes explicit.
  assert {
    condition     = length(output.network_contract.required_ingress) > 0
    error_message = "the contract must state what the databases have to allow, since the module cannot open it."
  }

  assert {
    condition = length([
      for n in output.network_contract.notes : n if can(regex("route to BOTH databases", n))
    ]) == 1
    error_message = "the contract must say the replication instance needs a route to both databases - that is the most common first-run failure."
  }
}

# ---------------------------------------------------------------------------
# Credentials: the module's headline refusal
# ---------------------------------------------------------------------------

run "a_plaintext_credential_is_rejected" {
  command = plan

  variables {
    endpoints = {
      source-db = {
        role        = "source"
        engine      = "postgres"
        server_name = "src.example.com"
        port        = 5432
        username    = "dms"
        password    = "hunter2"
        ssl_mode    = "require"
      }
    }
    tasks                    = {}
    allow_insecure_transport = true
  }

  # The precondition refuses it, and the advisory check says the same thing in
  # a plan a reviewer reads. Both have to fire.
  expect_failures = [
    aws_dms_replication_subnet_group.this,
    check.credentials_are_not_in_state,
  ]
}

run "a_plaintext_credential_is_allowed_when_acknowledged" {
  command = plan

  variables {
    endpoints = {
      source-db = {
        role        = "source"
        engine      = "postgres"
        server_name = "src.example.com"
        port        = 5432
        username    = "dms"
        password    = "hunter2"
        ssl_mode    = "require"
      }
    }
    tasks                       = {}
    allow_plaintext_credentials = true
    allow_insecure_transport    = true
  }

  assert {
    condition = length(output.governance.endpoints_with_plaintext_credentials) == 1 && contains(
      output.governance.endpoints_with_plaintext_credentials, "source-db"
    )
    error_message = "governance must name every endpoint whose credential is sitting in state."
  }

  # Acknowledged is not the same as fine: the warning stays.
  expect_failures = [check.credentials_are_not_in_state]
}

run "both_credential_paths_at_once_is_rejected" {
  command = plan

  variables {
    endpoints = {
      source-db = {
        role       = "source"
        engine     = "postgres"
        secret_arn = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf"
        username   = "dms"
        password   = "hunter2"
        ssl_mode   = "require"
      }
    }
    tasks = {}
  }

  expect_failures = [var.endpoints]
}

run "a_credential_hidden_in_extra_connection_attributes_is_rejected" {
  command = plan

  # This field is free text passed to the driver, stored in state, and returned
  # by the API. It is where a password goes when secret_arn feels like work.
  variables {
    endpoints = {
      source-db = {
        role                        = "source"
        engine                      = "oracle"
        secret_arn                  = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf"
        ssl_mode                    = "require"
        extra_connection_attributes = "addSupplementalLogging=Y;password=hunter2"
      }
    }
    tasks = {}
  }

  expect_failures = [var.endpoints]
}

run "the_secret_role_is_scoped_to_one_secret_and_trusts_the_regional_principal" {
  command = plan

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.endpoint_secret["source-db"].policy).Statement :
      length(s.Resource) == 1 if s.Sid == "ReadThisSecretOnly"
    ])
    error_message = "the secret-reading role must be scoped to exactly one secret."
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.endpoint_secret["source-db"].assume_role_policy).Statement :
      s if s.Principal.Service == "dms.eu-west-1.amazonaws.com"
    ]) == 1
    error_message = "the trust principal must be the REGIONAL dms principal; dms.amazonaws.com is refused by Secrets Manager and the endpoint then fails its connection test."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role.endpoint_secret["source-db"].assume_role_policy).Statement :
      s.Condition.StringEquals["aws:SourceAccount"] == "111122223333"
    ])
    error_message = "the trust policy needs a confused-deputy condition, or DMS in any account can assume this role."
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.endpoint_secret["source-db"].policy).Statement :
      s if s.Sid == "DecryptSecretWithCmk"
    ]) == 1
    error_message = "a CMK-encrypted secret needs kms:Decrypt as well as GetSecretValue."
  }
}

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

run "unverified_tls_is_rejected" {
  command = plan

  variables {
    endpoints = {
      source-db = {
        role       = "source"
        engine     = "postgres"
        secret_arn = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf"
        ssl_mode   = "require"
      }
    }
    tasks = {}
  }

  expect_failures = [aws_dms_replication_subnet_group.this]
}

run "verify_full_without_a_certificate_is_rejected" {
  command = plan

  # verify-full with no CA is a setting that reads as strict and verifies
  # nothing; DMS fails the connection test instead.
  variables {
    certificates = {}
    endpoints = {
      source-db = {
        role       = "source"
        engine     = "postgres"
        secret_arn = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf"
        ssl_mode   = "verify-full"
      }
    }
    tasks = {}
  }

  expect_failures = [var.endpoints]
}

run "a_certificate_key_must_name_a_real_certificate" {
  command = plan

  variables {
    endpoints = {
      source-db = {
        role            = "source"
        engine          = "postgres"
        secret_arn      = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf"
        ssl_mode        = "verify-full"
        certificate_key = "does-not-exist"
      }
    }
    tasks = {}
  }

  expect_failures = [var.endpoints]
}

run "a_module_created_certificate_reaches_the_endpoint" {
  # apply, not plan: the certificate ARN is computed, and only the mocked apply
  # fills it in.
  command = apply

  # Referencing the module's own certificate output from its input would be a
  # cycle, which is why endpoints take a key and the module resolves it.
  assert {
    condition     = aws_dms_endpoint.this["source-db"].certificate_arn != ""
    error_message = "an endpoint with certificate_key must receive the created certificate's ARN."
  }
}

# ---------------------------------------------------------------------------
# Task settings
#
# The module renders this JSON instead of taking it as a string, because DMS
# ignores keys it does not recognise and tells nobody.
# ---------------------------------------------------------------------------

run "task_settings_are_rendered_with_safe_defaults" {
  command = plan

  assert {
    condition     = jsondecode(output.task_settings_json["app"]).ValidationSettings.EnableValidation
    error_message = "validation must be on by default: without it \"the task succeeded\" means the rows were sent, not that they arrived."
  }

  assert {
    condition     = jsondecode(output.task_settings_json["app"]).Logging.EnableLogging
    error_message = "logging must be on by default."
  }

  assert {
    condition     = jsondecode(output.task_settings_json["app"]).ErrorBehavior.FailOnNoTablesCaptured
    error_message = "FailOnNoTablesCaptured must default true - it is the runtime half of the 'selection rule matched nothing' trap, where the task otherwise reports success."
  }

  assert {
    condition     = jsondecode(output.task_settings_json["app"]).FullLoadSettings.TargetTablePrepMode == "DO_NOTHING"
    error_message = "the default target prep mode must not delete anything in the target."
  }

  assert {
    condition = length([
      for c in jsondecode(output.task_settings_json["app"]).Logging.LogComponents :
      c if c.Id == "VALIDATOR"
    ]) == 1
    error_message = "the validator's own log component must be enabled, or a validation failure has no detail behind it."
  }
}

run "lob_mode_renders_the_matching_pair_of_flags" {
  command = plan

  # DMS expresses LOB handling through several flags that have to agree. FULL
  # with LimitedSizeLobMode left on is accepted and the behaviour is undefined.
  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings        = { lob_mode = "FULL" }
      }
    }
  }

  assert {
    condition = alltrue([
      jsondecode(output.task_settings_json["app"]).TargetMetadata.FullLobMode,
      !jsondecode(output.task_settings_json["app"]).TargetMetadata.LimitedSizeLobMode,
      jsondecode(output.task_settings_json["app"]).TargetMetadata.SupportLobs,
    ])
    error_message = "lob_mode = FULL must set FullLobMode and clear LimitedSizeLobMode; both on at once is undefined behaviour."
  }
}

run "raw_overrides_merge_one_level_deep" {
  command = plan

  # A shallow merge would replace the whole ValidationSettings block and quietly
  # drop EnableValidation with it.
  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings = {
          raw_overrides = "{\"ValidationSettings\":{\"ThreadCount\":12}}"
        }
      }
    }
  }

  assert {
    condition     = jsondecode(output.task_settings_json["app"]).ValidationSettings.ThreadCount == 12
    error_message = "a raw override must reach the rendered settings."
  }

  assert {
    condition     = jsondecode(output.task_settings_json["app"]).ValidationSettings.EnableValidation
    error_message = "overriding one key inside a section must not discard the rest of that section."
  }

  assert {
    condition     = jsondecode(output.task_settings_json["app"]).Logging.EnableLogging
    error_message = "overriding one section must not affect the others."
  }
}

run "table_mappings_without_a_selection_rule_are_rejected" {
  command = plan

  # The task would start, match nothing, and report success.
  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"transformation\",\"rule-id\":\"1\",\"rule-name\":\"lower\",\"rule-target\":\"table\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"convert-lowercase\"}]}"
      }
    }
  }

  expect_failures = [var.tasks]
}

run "duplicate_rule_ids_are_rejected" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"a\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"},{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"b\",\"object-locator\":{\"schema-name\":\"other\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
      }
    }
  }

  expect_failures = [var.tasks]
}

run "a_destructive_target_prep_mode_is_rejected" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings        = { target_table_prep_mode = "DROP_AND_CREATE" }
      }
    }
  }

  expect_failures = [
    aws_dms_replication_subnet_group.this,
    check.full_load_does_not_leave_the_meter_running,
  ]
}

run "a_destructive_prep_mode_is_allowed_when_acknowledged" {
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
  }

  assert {
    condition     = contains(output.governance.tasks_deleting_target_data, "app")
    error_message = "governance must name every task that deletes data in the target before loading."
  }
}

run "a_task_naming_an_endpoint_that_does_not_exist_is_rejected" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "typo-db"
        target_endpoint = "target-db"
        migration_type  = "full-load"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
      }
    }
  }

  expect_failures = [
    aws_dms_replication_subnet_group.this,
    check.full_load_does_not_leave_the_meter_running,
  ]
}

run "an_endpoint_used_in_the_wrong_direction_is_rejected" {
  command = plan

  # A target-role endpoint as a task's source fails at connection test, ten
  # minutes into an apply that looked fine.
  variables {
    tasks = {
      app = {
        source_endpoint = "target-db"
        target_endpoint = "target-db"
        migration_type  = "full-load"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
      }
    }
  }

  expect_failures = [
    aws_dms_replication_subnet_group.this,
    check.full_load_does_not_leave_the_meter_running,
  ]
}

run "a_cdc_start_point_on_a_full_load_task_is_rejected" {
  command = plan

  # It would be silently ignored: a full-load task never reads changes.
  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        cdc_start_time  = "2026-01-31T14:00:00Z"
      }
    }
  }

  expect_failures = [
    aws_dms_replication_subnet_group.this,
    check.full_load_does_not_leave_the_meter_running,
  ]
}

# ---------------------------------------------------------------------------
# Alerting: the failure this module is shaped around
# ---------------------------------------------------------------------------

run "a_stopped_cdc_task_is_alarmed_on" {
  command = plan

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.cdc_latency_target) == 1
    error_message = "a CDC task must get a target-latency alarm."
  }

  assert {
    # The whole point. A stopped task publishes NO datapoints, so the default
    # missing-data behaviour leaves the alarm green while the target drifts.
    condition     = aws_cloudwatch_metric_alarm.cdc_latency_target["app"].treat_missing_data == "breaching"
    error_message = "the CDC alarm must treat missing data as breaching: a stopped task stops publishing metrics entirely, and 'no data' is exactly the condition worth paging on."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.free_storage[0].treat_missing_data == "breaching"
    error_message = "a replication instance that stops reporting storage is not healthy."
  }

  assert {
    condition = alltrue([
      for c in var.task_event_categories : contains(var.task_event_categories, "state change")
    ])
    error_message = "the task event subscription must include \"state change\", which is what fires when a task stops on its own."
  }
}

run "a_full_load_only_task_gets_no_cdc_alarm" {
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
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.cdc_latency_target) == 0
    error_message = "a full-load task never publishes CDC latency, so an alarm on it would sit in INSUFFICIENT DATA forever."
  }

  expect_failures = [check.full_load_does_not_leave_the_meter_running]
}

run "without_a_topic_nothing_is_watching" {
  command = plan

  variables {
    sns_topic_arn = ""
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.cdc_latency_target) == 0 && length(aws_dms_event_subscription.task) == 0
    error_message = "with no topic there is nowhere to send an alert, so none are created."
  }

  assert {
    condition     = output.governance.notifications_enabled == false
    error_message = "governance must admit that nothing is watching."
  }

  expect_failures = [check.somebody_hears_a_failed_task]
}

run "the_task_log_group_has_retention" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_group.tasks[0].name == "dms-tasks-test-migration"
    error_message = "the log group name must match what DMS derives from the replication instance id, or retention applies to a different group than the one being written to."
  }

  assert {
    condition     = aws_cloudwatch_log_group.tasks[0].retention_in_days == 30
    error_message = "left to DMS this log group never expires."
  }
}

# ---------------------------------------------------------------------------
# Serverless
# ---------------------------------------------------------------------------

run "serverless_mode_swaps_the_compute_not_the_inputs" {
  command = plan

  variables {
    compute_mode = "serverless"
  }

  assert {
    condition     = length(aws_dms_replication_instance.this) == 0 && length(aws_dms_replication_task.this) == 0
    error_message = "serverless mode must create no replication instance and no task resources."
  }

  assert {
    condition     = length(aws_dms_replication_config.this) == 1
    error_message = "each task entry becomes one replication config in serverless mode."
  }

  assert {
    condition     = aws_dms_replication_config.this["app"].replication_type == "full-load-and-cdc"
    error_message = "the migration type must carry over unchanged."
  }

  assert {
    condition     = jsondecode(aws_dms_replication_config.this["app"].replication_settings).ValidationSettings.EnableValidation
    error_message = "serverless replications get the same rendered settings as provisioned tasks."
  }

  assert {
    condition     = output.governance.compute_mode == "serverless"
    error_message = "governance must report which compute mode is in play."
  }

  assert {
    condition     = output.governance.observability_covers_this_compute_mode == false
    error_message = "governance must admit that this module watches nothing in serverless mode."
  }

  # The module creates no alarms, no event subscriptions and no log group here,
  # and says so rather than letting an SNS topic imply coverage.
  expect_failures = [check.serverless_replication_is_not_watched_by_this_module]
}

# ---------------------------------------------------------------------------
# Contracts the caller has to satisfy
# ---------------------------------------------------------------------------

run "postgres_source_prerequisites_are_emitted" {
  command = plan

  # None of this is reachable from Terraform, and every one of them fails at
  # runtime rather than at apply.
  assert {
    condition     = length(output.source_prerequisites["postgres"]) >= 3
    error_message = "a PostgreSQL source has prerequisites - logical WAL, the replication role, and the slot - and they have to be handed to whoever owns the database."
  }

  assert {
    condition = length([
      for p in output.source_prerequisites["postgres"] : p if can(regex("wal_level", p.what))
    ]) >= 1
    error_message = "the PostgreSQL prerequisites must name logical WAL, without which CDC cannot start at all."
  }

  assert {
    condition = length([
      for p in output.source_prerequisites["postgres"] : p if can(regex("slot", p.what))
    ]) >= 1
    error_message = "the replication slot has to be named: an orphaned slot pins WAL and fills the source's disk, which is an outage on the database you were migrating away from."
  }
}

run "oracle_source_prerequisites_name_supplemental_logging" {
  command = plan

  variables {
    endpoints = {
      source-db = {
        role               = "source"
        engine             = "oracle"
        server_name        = "src.example.com"
        port               = 1521
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
        secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:tgt-AbCdEf"
        secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        ssl_mode           = "verify-full"
        certificate_key    = "rds-ca"
        postgres           = { after_connect_script = "SET session_replication_role = replica;" }
      }
    }
  }

  assert {
    condition = length([
      for p in output.source_prerequisites["oracle"] : p
      if can(regex("SUPPLEMENTAL LOG", p.how))
    ]) >= 1
    error_message = "without supplemental logging an Oracle UPDATE arrives with no way to identify the row - the worst DMS failure, because it is silent and wrong rather than loud and stopped."
  }
}

run "aurora_flavours_inherit_the_upstream_engines_prerequisites" {
  command = plan

  # aurora-postgresql is a target here, so only the source engine appears.
  assert {
    condition     = contains(keys(output.source_prerequisites), "postgres")
    error_message = "prerequisites are keyed by source engine."
  }
}

run "the_account_wide_roles_are_named_but_not_created" {
  command = plan

  assert {
    condition     = length(output.account_prerequisites) == 2
    error_message = "dms-vpc-role and dms-cloudwatch-logs-role both have to be named: DMS does not work without them and the error when they are missing names neither."
  }

  assert {
    condition = alltrue([
      for r in output.account_prerequisites : r.created == false
    ])
    error_message = "account-wide roles must not be created by default; their names are fixed and a second module instance collides."
  }
}

run "the_account_roles_can_be_created_for_a_greenfield_account" {
  command = plan

  variables {
    create_account_service_roles = true
  }

  assert {
    condition     = aws_iam_role.dms_vpc[0].name == "dms-vpc-role"
    error_message = "the role name is fixed by DMS; a prefixed name does not work."
  }
}

# ---------------------------------------------------------------------------
# S3 targets
# ---------------------------------------------------------------------------

run "an_s3_target_role_is_scoped_to_the_prefix" {
  command = plan

  variables {
    s3_targets = {
      lake = {
        bucket_name     = "my-data-lake"
        bucket_folder   = "raw/sales"
        encryption_mode = "SSE_KMS"
        kms_key_arn     = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
      }
    }
    tasks = {}
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.s3_target["lake"].policy).Statement :
      s.Resource[0] == "arn:aws:s3:::my-data-lake/raw/sales/*" if s.Sid == "WriteMigratedObjects"
    ])
    error_message = "the S3 role must be scoped to the bucket_folder: an empty prefix grants the whole bucket, and in a shared lake that means this migration can overwrite another one's output."
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.s3_target["lake"].policy).Statement :
      s if s.Sid == "EncryptWithTargetKey"
    ]) == 1
    error_message = "an SSE-KMS bucket needs GenerateDataKey, or every object write 403s while the task reports it is running."
  }
}

run "endpoint_keys_must_not_collide_across_the_two_maps" {
  command = plan

  variables {
    s3_targets = {
      target-db = {
        bucket_name = "my-data-lake"
      }
    }
    tasks = {}
  }

  expect_failures = [aws_dms_replication_subnet_group.this]
}

# ---------------------------------------------------------------------------
# Compute posture
# ---------------------------------------------------------------------------

run "a_public_replication_instance_is_rejected" {
  command = plan

  variables {
    publicly_accessible = true
  }

  expect_failures = [aws_dms_replication_instance.this]
}

run "single_az_warns" {
  command = plan

  variables {
    multi_az = false
  }

  assert {
    condition     = output.governance.multi_az == false
    error_message = "governance must report the availability posture."
  }

  expect_failures = [check.replication_survives_an_az]
}

run "an_unpinned_engine_version_warns" {
  command = plan

  variables {
    engine_version = ""
  }

  assert {
    condition     = output.governance.engine_version == "unpinned - AWS default"
    error_message = "governance must say when the engine version floats."
  }

  expect_failures = [check.engine_version_is_pinned]
}

run "require_cmk_refuses_the_aws_managed_key" {
  command = plan

  variables {
    kms_key_arn = ""
    require_cmk = true
  }

  # All three: the instance's storage key, every endpoint's key, and the task
  # log group - which at DEBUG severity holds row data. require_cmk means all
  # of them.
  expect_failures = [
    aws_dms_replication_instance.this,
    aws_dms_endpoint.this,
    aws_cloudwatch_log_group.tasks,
  ]
}

# ---------------------------------------------------------------------------
# Audit regressions
#
# One run per finding. Each of these passed - or did not exist - while the
# thing it names was broken.
# ---------------------------------------------------------------------------

run "regression_raw_overrides_cannot_hide_from_the_gates" {
  command = plan

  # The whole premise is that task settings are typed so a security-relevant key
  # cannot be silently wrong. raw_overrides is merged OVER the typed base, and
  # every gate used to read the typed input - so an override disabled validation
  # and logging, enabled DROP_AND_CREATE, and governance reported it all clean.
  variables {
    allow_destructive_target_prep = true
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings = {
          validation_enabled     = true
          logging_enabled        = true
          target_table_prep_mode = "DO_NOTHING"
          raw_overrides          = "{\"ValidationSettings\":{\"EnableValidation\":false},\"Logging\":{\"EnableLogging\":false},\"FullLoadSettings\":{\"TargetTablePrepMode\":\"DROP_AND_CREATE\"}}"
        }
      }
    }
  }

  assert {
    condition     = contains(output.governance.tasks_without_validation, "app")
    error_message = "governance must report the EFFECTIVE posture: an override that disables validation has to show up as disabled."
  }

  assert {
    condition     = contains(output.governance.tasks_without_logging, "app")
    error_message = "an override that disables logging has to show up in governance."
  }

  assert {
    condition     = contains(output.governance.tasks_deleting_target_data, "app")
    error_message = "an override that enables DROP_AND_CREATE has to show up in governance."
  }

  assert {
    condition     = contains(output.governance.tasks_with_raw_overrides, "app")
    error_message = "a reviewer has to be able to see which tasks carry a raw override at all."
  }

  # And the advisory checks have to fire on the merged result too.
  expect_failures = [
    check.cdc_tasks_are_validated,
    check.tasks_write_logs,
  ]
}

run "regression_an_override_cannot_defeat_the_destructive_prep_gate" {
  command = plan

  # Same shape, but without the acknowledgement. The hard gate must refuse it.
  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings = {
          raw_overrides = "{\"FullLoadSettings\":{\"TargetTablePrepMode\":\"DROP_AND_CREATE\"}}"
        }
      }
    }
  }

  expect_failures = [aws_dms_replication_subnet_group.this]
}

run "regression_serverless_enforces_the_same_invariants" {
  command = plan

  # These preconditions used to live on aws_dms_replication_task, which has zero
  # instances in serverless mode - so a precondition on it never ran, and
  # allow_destructive_target_prep protected nothing there.
  variables {
    compute_mode = "serverless"
    tasks = {
      app = {
        source_endpoint = "target-db"
        target_endpoint = "target-db"
        migration_type  = "full-load"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings        = { target_table_prep_mode = "DROP_AND_CREATE" }
      }
    }
  }

  # Serverless also warns that this module watches nothing there.
  expect_failures = [
    aws_dms_replication_subnet_group.this,
    check.serverless_replication_is_not_watched_by_this_module,
  ]
}

run "regression_inline_lob_mode_renders_a_setting_dms_reads" {
  command = plan

  # DMS only reads InlineLobMaxSize when FullLobMode is true. Rendering INLINE
  # with FullLobMode = false made DMS drop the setting and silently fall back to
  # default LOB handling - the exact trap this module exists to prevent.
  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings = {
          lob_mode        = "INLINE"
          lob_max_size_kb = 32
        }
      }
    }
  }

  assert {
    condition     = jsondecode(output.task_settings_json["app"]).TargetMetadata.FullLobMode
    error_message = "INLINE must set FullLobMode, or DMS ignores InlineLobMaxSize entirely."
  }

  assert {
    condition     = jsondecode(output.task_settings_json["app"]).TargetMetadata.InlineLobMaxSize == 32
    error_message = "the inline threshold must reach the rendered settings."
  }

  assert {
    condition     = jsondecode(output.task_settings_json["app"]).TargetMetadata.LimitedSizeLobMode == false
    error_message = "INLINE and LIMITED are mutually exclusive."
  }
}

run "regression_an_s3_target_cannot_be_a_task_source" {
  command = plan

  # An s3_targets key is absent from var.endpoints, so the direction guard's
  # try() fell back to "source" and waved it through. An S3 endpoint is
  # target-only by construction.
  variables {
    s3_targets = {
      lake = {
        bucket_name   = "my-data-lake"
        bucket_folder = "raw"
      }
    }
    tasks = {
      app = {
        source_endpoint = "lake"
        target_endpoint = "target-db"
        migration_type  = "full-load"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
      }
    }
  }

  expect_failures = [
    aws_dms_replication_subnet_group.this,
    check.full_load_does_not_leave_the_meter_running,
  ]
}

run "regression_postgres_cdc_settings_do_not_reach_a_target" {
  command = plan

  # heartbeat_*, slot_name and capture_ddls are source-CDC settings. Applied to
  # a target, DMS tries to create a heartbeat table in the database you are
  # migrating INTO. Both shipped examples used an aurora-postgresql target.
  assert {
    condition     = length(aws_dms_endpoint.this["source-db"].postgres_settings) == 1
    error_message = "a postgres SOURCE must still get its CDC settings."
  }

  # A target now gets a postgres block too - but only the fields that mean
  # something on a target. The defect was source-only CDC settings reaching it.
  assert {
    condition     = aws_dms_endpoint.this["target-db"].postgres_settings[0].heartbeat_enable == null
    error_message = "a postgres TARGET must not receive heartbeat settings: DMS would try to create a heartbeat table in the database you are migrating into."
  }

  assert {
    condition     = aws_dms_endpoint.this["target-db"].postgres_settings[0].slot_name == null
    error_message = "a replication slot on a TARGET is meaningless."
  }

  assert {
    condition     = aws_dms_endpoint.this["target-db"].postgres_settings[0].after_connect_script == "SET session_replication_role = replica;"
    error_message = "after_connect_script is the one pre-data hook DMS has, and it must reach the target endpoint."
  }

  assert {
    condition     = aws_dms_endpoint.this["source-db"].postgres_settings[0].heartbeat_enable
    error_message = "a postgres SOURCE must still get its heartbeat, which is what keeps the replication slot advancing on a quiet source."
  }
}

run "regression_raw_overrides_must_be_an_object" {
  command = plan

  # "[]" is valid JSON and cannot be merged. Without this the plan died inside
  # locals on keys(), naming neither the task nor the field.
  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings        = { raw_overrides = "[]" }
      }
    }
  }

  expect_failures = [var.tasks]
}

run "regression_create_false_silences_the_advisory_checks" {
  command = plan

  # Checks are module-level and used to evaluate even with create = false, so a
  # switched-off module reported eight advisory failures on a config that
  # creates nothing.
  variables {
    create                      = false
    allow_plaintext_credentials = true
    allow_insecure_transport    = true
    sns_topic_arn               = ""
    engine_version              = ""
    multi_az                    = false
    endpoints = {
      source-db = {
        role     = "source"
        engine   = "postgres"
        username = "dms"
        password = "hunter2"
        ssl_mode = "none"
      }
    }
    tasks = {}
  }

  assert {
    condition     = output.governance == null
    error_message = "create = false must produce no posture at all, and no advisory noise with it."
  }
}

run "regression_the_s3_role_trust_is_scoped_to_dms_endpoints" {
  command = plan

  variables {
    s3_targets = {
      lake = {
        bucket_name   = "my-data-lake"
        bucket_folder = "raw/sales"
      }
    }
    tasks = {}
  }

  # SourceAccount alone let any DMS endpoint in the account assume this role -
  # and dms:CreateEndpoint is a far more common grant than iam:PassRole.
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role.s3_target["lake"].assume_role_policy).Statement :
      can(s.Condition.ArnLike["aws:SourceArn"])
    ])
    error_message = "the S3 target role's trust policy needs an aws:SourceArn condition, not just aws:SourceAccount."
  }
}

run "regression_validation_survives_an_oracle_to_postgres_collation_difference" {
  command = plan

  # With a non-C primary-key collation on the target, Oracle -> PostgreSQL
  # validation reports false mismatches and suspends itself once it has enough
  # of them. The evidence the change record depends on then does not exist.
  assert {
    condition     = jsondecode(output.task_settings_json["app"]).ValidationSettings.HandleCollationDiff
    error_message = "HandleCollationDiff must default true: it is what stops Oracle -> PostgreSQL validation suspending itself on a collation difference."
  }

  assert {
    condition     = !can(jsondecode(output.task_settings_json["app"]).ValidationSettings.ValidationMode)
    error_message = "ValidationMode must be omitted by default so DMS can select GROUP_LEVEL itself on supported paths; hardcoding ROW_LEVEL overrides that."
  }
}

run "regression_the_network_contract_covers_a_hybrid_isolated_vpc" {
  command = plan

  assert {
    condition = length([
      for n in output.network_contract.notes : n if can(regex("(?i)resolve from inside the VPC", n))
    ]) >= 1
    error_message = "an on-prem source hostname that only resolves on-premises is the most common first-run failure in this topology, and the contract is what the network team receives."
  }

  assert {
    condition = length([
      for n in output.network_contract.notes : n if can(regex("(?i)return path", n))
    ]) >= 1
    error_message = "asymmetric routing back from on-premises presents as a connection test that passes and a load that stalls - it belongs in the contract."
  }

  assert {
    condition = length([
      for n in output.network_contract.notes : n if can(regex("Cloud WAN", n))
    ]) >= 1
    error_message = "the contract must name Cloud WAN as a supported path, since that is how a hybrid estate reaches on-premises."
  }

  assert {
    condition     = length(output.network_contract.verify_in_your_account) >= 2
    error_message = "endpoints whose necessity cannot be determined from configuration must be listed as such, not asserted."
  }
}

# ---------------------------------------------------------------------------
# Pre-data and post-data
#
# DMS owns the middle phase only. The module records the other two and emits the
# ordering; it deliberately runs none of it.
# ---------------------------------------------------------------------------

run "the_migration_plan_orders_all_three_phases" {
  command = plan

  assert {
    condition = alltrue([
      length(output.migration_plan.phase_1_pre_data.scripts) == 1,
      length(output.migration_plan.phase_3_post_data.scripts) == 2,
    ])
    error_message = "the plan must carry the pre-data and post-data scripts in their declared order."
  }

  assert {
    condition = alltrue([
      output.migration_plan.phase_1_pre_data.scripts[0].order == 1,
      output.migration_plan.phase_3_post_data.scripts[0].name == "02-indexes",
      output.migration_plan.phase_3_post_data.scripts[1].name == "03-sequences",
    ])
    error_message = "declared order is execution order: indexes before the sequence reset."
  }

  assert {
    condition = alltrue([
      for s in output.migration_plan.ordered_scripts : can(regex("^[0-9a-f]{64}$", s.sha256))
    ])
    error_message = "every script needs a checksum, or the change record cannot state which version ran."
  }

  assert {
    condition     = can(regex("psql", output.migration_plan.phase_1_pre_data.example))
    error_message = "the plan should hand the operator the invocation, not just the filename."
  }

  assert {
    condition     = can(regex("(?i)does not execute", output.migration_plan.phase_1_pre_data.run_by)) || can(regex("(?i)pipeline", output.migration_plan.phase_1_pre_data.run_by))
    error_message = "the plan must be explicit that the module runs none of this."
  }
}

run "the_load_guard_is_reported_where_it_is_configured" {
  command = plan

  # after_connect_script is the only pre-data hook DMS actually has.
  assert {
    condition     = contains(output.migration_plan.phase_2_load_and_cdc.target_load_guard.configured_on, "target-db")
    error_message = "the plan must name which target endpoints carry the load guard."
  }

  assert {
    condition     = can(regex("session_replication_role", output.migration_plan.phase_2_load_and_cdc.target_load_guard.suggested))
    error_message = "the suggested guard is what stops triggers firing and FKs rejecting rows during a full load."
  }
}

run "a_migration_with_no_schema_step_is_flagged" {
  command = plan

  # DO_NOTHING plus no pre-data means the target schema has to exist already,
  # and if it does not DMS suspends every table rather than failing the task.
  variables {
    sql_scripts = {}
  }

  expect_failures = [check.the_target_schema_comes_from_somewhere]
}

run "a_postgres_target_with_live_constraints_is_flagged" {
  command = plan

  variables {
    endpoints = {
      source-db = {
        role               = "source"
        engine             = "postgres"
        server_name        = "src.example.com"
        port               = 5432
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
        secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:tgt-AbCdEf"
        secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        ssl_mode           = "verify-full"
        certificate_key    = "rds-ca"
        # no after_connect_script
      }
    }
  }

  expect_failures = [check.the_full_load_is_not_fighting_the_targets_constraints]
}

run "a_destructive_statement_in_a_migration_script_is_rejected" {
  command = plan

  # Only checkable when the content is supplied, which is why sql is optional.
  variables {
    sql_scripts = {
      pre_data = [{
        name = "01-schema"
        path = "sql/01-schema.sql"
        sql  = "DROP SCHEMA app CASCADE;\nCREATE SCHEMA app;"
      }]
    }
  }

  expect_failures = [var.sql_scripts]
}

run "script_names_must_be_unique_because_they_are_the_audit_key" {
  command = plan

  variables {
    sql_scripts = {
      post_data = [
        { name = "02-indexes", path = "sql/a.sql" },
        { name = "02-indexes", path = "sql/b.sql" },
      ]
    }
  }

  expect_failures = [var.sql_scripts]
}

run "a_missing_checksum_is_called_out_rather_than_faked" {
  command = plan

  variables {
    sql_scripts = {
      pre_data = [{ name = "01-schema", path = "sql/01-schema.sql" }]
    }
  }

  assert {
    condition     = can(regex("not supplied", output.migration_plan.phase_1_pre_data.scripts[0].sha256))
    error_message = "a script with no checksum must say so, not present an empty string as if it were verified."
  }
}
