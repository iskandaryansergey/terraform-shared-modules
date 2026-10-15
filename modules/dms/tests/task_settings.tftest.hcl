# Task settings: the rendered JSON and what raw_overrides may add to it.
#
# The fixtures under tests/fixtures are what tests/lint_task_settings.py checks
# the rendered settings against. They are only evidence if they ARE what the
# module renders, so each one is compared, key for key, with the live output
# here. A change to the rendering fails this file until the fixture is updated;
# a fixture edited by hand fails it until the rendering agrees.
#
# raw_overrides is the one place a task setting can be misspelled, and DMS
# drops an unknown key without a word - so the module warns at plan.

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


run "the_limited_lob_fixture_is_what_the_module_renders" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings        = { lob_mode = "LIMITED" }
      }
    }
  }

  assert {
    condition     = jsondecode(output.task_settings_json["app"]) == jsondecode(file("${path.module}/tests/fixtures/task-settings-lob-limited.json"))
    error_message = "tests/fixtures/task-settings-lob-limited.json is not what the module renders for lob_mode = LIMITED. The linter checks the fixture, so a stale fixture certifies nothing; regenerate it from output.task_settings_json."
  }
}

run "the_full_lob_fixture_is_what_the_module_renders" {
  command = plan

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
    condition     = jsondecode(output.task_settings_json["app"]) == jsondecode(file("${path.module}/tests/fixtures/task-settings-lob-full.json"))
    error_message = "tests/fixtures/task-settings-lob-full.json is not what the module renders for lob_mode = FULL. The linter checks the fixture, so a stale fixture certifies nothing; regenerate it from output.task_settings_json."
  }
}

run "the_inline_lob_fixture_is_what_the_module_renders" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings        = { lob_mode = "INLINE" }
      }
    }
  }

  assert {
    condition     = jsondecode(output.task_settings_json["app"]) == jsondecode(file("${path.module}/tests/fixtures/task-settings-lob-inline.json"))
    error_message = "tests/fixtures/task-settings-lob-inline.json is not what the module renders for lob_mode = INLINE. The linter checks the fixture, so a stale fixture certifies nothing; regenerate it from output.task_settings_json."
  }
}

run "the_none_lob_fixture_is_what_the_module_renders" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings        = { lob_mode = "NONE" }
      }
    }
  }

  assert {
    condition     = jsondecode(output.task_settings_json["app"]) == jsondecode(file("${path.module}/tests/fixtures/task-settings-lob-none.json"))
    error_message = "tests/fixtures/task-settings-lob-none.json is not what the module renders for lob_mode = NONE. The linter checks the fixture, so a stale fixture certifies nothing; regenerate it from output.task_settings_json."
  }
}

# ---------------------------------------------------------------------------
# raw_overrides against the documented keys
# ---------------------------------------------------------------------------

run "a_misspelled_raw_override_key_warns" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings        = { raw_overrides = "{\"ValidationSettings\":{\"EnableValdiation\":true}}" }
      }
    }
  }

  expect_failures = [check.raw_overrides_use_known_task_settings]

  assert {
    condition     = output.governance.tasks_with_unknown_task_settings["app"] == ["ValidationSettings.EnableValdiation"]
    error_message = "governance must name the exact key DMS would drop."
  }
}

run "an_unknown_raw_override_section_warns" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings        = { raw_overrides = "{\"ValidationSetting\":{\"EnableValidation\":true}}" }
      }
    }
  }

  expect_failures = [check.raw_overrides_use_known_task_settings]

  assert {
    condition     = output.governance.tasks_with_unknown_task_settings["app"] == ["ValidationSetting (unknown section)"]
    error_message = "a misspelled section is the whole section silently dropped."
  }
}

# Documented keys the module does not type must pass without a sound, or the
# check is a tax on legitimate use rather than a trap for typos.
run "documented_but_untyped_settings_pass_silently" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings        = { raw_overrides = "{\"ChangeProcessingTuning\":{\"RecoveryTimeout\":30},\"LoopbackPreventionSettings\":{\"EnableLoopbackPrevention\":true,\"SourceSchema\":\"a\",\"TargetSchema\":\"b\"},\"ResyncSettings\":{\"EnableResync\":false},\"FailTaskWhenCleanTaskResourceFailed\":false,\"PostProcessingRules\":[],\"ErrorBehavior\":{\"DataMaskingErrorPolicy\":\"STOP_TASK\"}}" }
      }
    }
  }

  assert {
    condition     = output.governance.tasks_with_unknown_task_settings == {}
    error_message = "every key here is in the DMS documentation; none may be reported."
  }

  assert {
    condition     = jsondecode(output.task_settings_json["app"]).ChangeProcessingTuning.RecoveryTimeout == 30
    error_message = "a new section from raw_overrides must reach the rendered settings."
  }

  assert {
    condition     = jsondecode(output.task_settings_json["app"]).ErrorBehavior.DataMaskingErrorPolicy == "STOP_TASK"
    error_message = "a key added to an existing section must be merged into it, not replace it."
  }
}

run "an_acknowledged_unknown_key_is_quiet_and_listed" {
  command = plan

  variables {
    acknowledged_checks = ["raw_overrides_use_known_task_settings"]
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
        settings        = { raw_overrides = "{\"ValidationSettings\":{\"EnableValdiation\":true}}" }
      }
    }
  }

  assert {
    condition     = contains(output.governance.acknowledged_checks, "raw_overrides_use_known_task_settings")
    error_message = "the acknowledgement is listed for the reviewer."
  }

  assert {
    condition     = output.governance.tasks_with_unknown_task_settings["app"] == ["ValidationSettings.EnableValdiation"]
    error_message = "acknowledging silences the warning; governance still shows the key."
  }
}

# ---------------------------------------------------------------------------
# Table mappings against the DMS documentation. Each failing mapping is valid
# JSON with a rules array, a selection rule and unique rule-ids, so the only
# thing that can refuse it is the mapping gate on the subnet group.
# ---------------------------------------------------------------------------

run "every_documented_mapping_rule_shape_passes" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"},{\"rule-type\":\"selection\",\"rule-id\":\"2\",\"rule-name\":\"one\",\"rule-action\":\"explicit\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"exact\"}},{\"rule-type\":\"transformation\",\"rule-id\":\"3\",\"rule-name\":\"prefix\",\"rule-action\":\"add-prefix\",\"rule-target\":\"table\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"value\":\"x_\"},{\"rule-type\":\"transformation\",\"rule-id\":\"4\",\"rule-name\":\"pk\",\"rule-action\":\"define-primary-key\",\"rule-target\":\"table\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"exact\"},\"primary-key-def\":{\"name\":\"pk\",\"columns\":[\"id\"]}},{\"rule-type\":\"transformation\",\"rule-id\":\"5\",\"rule-name\":\"type\",\"rule-action\":\"change-data-type\",\"rule-target\":\"column\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"exact\",\"column-name\":\"c\"},\"data-type\":{\"type\":\"int8\"}},{\"rule-type\":\"table-settings\",\"rule-id\":\"6\",\"rule-name\":\"parallel\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"exact\"},\"parallel-load\":{\"type\":\"ranges\",\"columns\":[\"id\"],\"boundaries\":[[\"100\"]]}},{\"rule-type\":\"table-settings\",\"rule-id\":\"7\",\"rule-name\":\"lobs\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"other\"},\"lob-settings\":{\"mode\":\"unlimited\",\"bulk-max-size\":\"0\"}}]}"
      }
    }
  }

  assert {
    condition     = output.governance.tasks_expecting_a_prebuilt_target == ["app"]
    error_message = "a mapping made only of documented rule shapes must plan without a sound."
  }
}

run "an_unknown_rule_type_is_refused" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"},{\"rule-type\":\"selectin\",\"rule-id\":\"2\",\"rule-name\":\"b\",\"rule-action\":\"include\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"}}]}"
      }
    }
  }

  expect_failures = [aws_dms_replication_subnet_group.this]

}

run "a_non_numeric_rule_id_is_refused" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"one\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
      }
    }
  }

  expect_failures = [aws_dms_replication_subnet_group.this]

}

run "explicit_with_a_wildcard_is_refused" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"explicit\"}]}"
      }
    }
  }

  expect_failures = [aws_dms_replication_subnet_group.this]

}

run "a_misspelled_transformation_action_is_refused" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"},{\"rule-type\":\"transformation\",\"rule-id\":\"2\",\"rule-name\":\"b\",\"rule-action\":\"add-prefx\",\"rule-target\":\"table\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"value\":\"x_\"}]}"
      }
    }
  }

  expect_failures = [aws_dms_replication_subnet_group.this]

}

run "a_column_only_action_on_a_table_is_refused" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"},{\"rule-type\":\"transformation\",\"rule-id\":\"2\",\"rule-name\":\"b\",\"rule-action\":\"change-data-type\",\"rule-target\":\"table\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"t\"},\"data-type\":{\"type\":\"int8\"}}]}"
      }
    }
  }

  expect_failures = [aws_dms_replication_subnet_group.this]

}

run "table_settings_with_a_wildcard_are_refused" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"},{\"rule-type\":\"table-settings\",\"rule-id\":\"2\",\"rule-name\":\"b\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"parallel-load\":{\"type\":\"partitions-auto\"}}]}"
      }
    }
  }

  expect_failures = [aws_dms_replication_subnet_group.this]

}

run "limited_lob_settings_without_a_size_are_refused" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"},{\"rule-type\":\"table-settings\",\"rule-id\":\"2\",\"rule-name\":\"b\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"t\"},\"lob-settings\":{\"mode\":\"limited\"}}]}"
      }
    }
  }

  expect_failures = [aws_dms_replication_subnet_group.this]

}

run "an_exclude_only_mapping_is_refused" {
  command = plan

  variables {
    tasks = {
      app = {
        source_endpoint = "source-db"
        target_endpoint = "target-db"
        migration_type  = "full-load-and-cdc"
        table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"exclude\"}]}"
      }
    }
  }

  expect_failures = [aws_dms_replication_subnet_group.this]

}
