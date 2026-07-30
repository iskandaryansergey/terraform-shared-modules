# mocked. Vault/plan/selection shape is a pure function of inputs.

mock_provider "aws" {
  mock_resource "aws_backup_vault" {
    defaults = { arn = "arn:aws:backup:us-east-1:123456789012:backup-vault:mock" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_resource "aws_backup_plan" {
    defaults = { arn = "arn:aws:backup:us-east-1:123456789012:backup-plan:mock" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
}

variables {
  vault_name = "app-backup"
  plans = {
    daily = {
      rules = {
        daily = {
          schedule          = "cron(0 5 * * ? *)"
          delete_after_days = 35
        }
      }
      selections = {
        tagged = { selection_tags = [{ key = "Backup", value = "true" }] }
      }
    }
  }
}

# ============================================================================
# HAPPY PATH
# ============================================================================

# --- secure defaults: vault + role + plan + selection -----------------------
run "defaults" {
  command = apply

  assert {
    condition = alltrue([
      length(aws_backup_vault.this) == 1,
      length(aws_iam_role.backup) == 1,
      length(aws_iam_role_policy_attachment.backup) == 1,
      length(aws_iam_role_policy_attachment.restore) == 1,
      length(aws_backup_plan.this) == 1,
      length(aws_backup_selection.this) == 1,
      length(aws_backup_vault_lock_configuration.this) == 0,
      length(aws_backup_vault_notifications.this) == 0,
    ])
    error_message = "Defaults should build vault + role (2 policies) + plan + selection, no lock/notifications"
  }
}

# --- default role attaches the correct managed policy ARNs ------------------
run "default_role_policy_arns" {
  command = plan
  assert {
    condition = alltrue([
      aws_iam_role_policy_attachment.backup[0].policy_arn == "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup",
      aws_iam_role_policy_attachment.restore[0].policy_arn == "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores",
    ])
    error_message = "Created role must attach the AWS Backup + Restore managed policies"
  }
}

# --- rule wiring: schedule, target vault, lifecycle, tag selection ----------
run "rule_wiring" {
  command = apply

  assert {
    condition = alltrue([
      one(aws_backup_plan.this["daily"].rule).schedule == "cron(0 5 * * ? *)",
      one(aws_backup_plan.this["daily"].rule).target_vault_name == "app-backup",
      one(aws_backup_plan.this["daily"].rule).schedule_expression_timezone == "Etc/UTC",
      one(one(aws_backup_plan.this["daily"].rule).lifecycle).delete_after == 35,
      one(aws_backup_selection.this["daily/tagged"].selection_tag).key == "Backup",
    ])
    error_message = "Rule schedule/target/timezone/lifecycle and the tag selection must render"
  }
}

# --- multiple rules in one plan ---------------------------------------------
run "multiple_rules_one_plan" {
  command = apply

  variables {
    plans = {
      ops = {
        rules = {
          daily  = { schedule = "cron(0 5 * * ? *)", delete_after_days = 35 }
          weekly = { schedule = "cron(0 6 ? * 1 *)", delete_after_days = 90 }
        }
        selections = { all = { resources = ["*"] } }
      }
    }
  }

  assert {
    condition = alltrue([
      length(aws_backup_plan.this["ops"].rule) == 2,
      [for r in aws_backup_plan.this["ops"].rule : r.schedule if r.rule_name == "weekly"][0] == "cron(0 6 ? * 1 *)",
    ])
    error_message = "Both rules must render with their own schedule"
  }
}

# --- multiple plans + populated output maps ---------------------------------
run "multiple_plans_and_outputs" {
  command = apply

  variables {
    plans = {
      daily  = { rules = { d = { schedule = "cron(0 5 * * ? *)", delete_after_days = 35 } }, selections = { t = { selection_tags = [{ key = "Backup", value = "true" }] } } }
      hourly = { rules = { h = { schedule = "cron(0 * * * ? *)", delete_after_days = 7 } }, selections = { a = { resources = ["*"] } } }
    }
  }

  assert {
    condition = alltrue([
      length(aws_backup_plan.this) == 2,
      length(aws_backup_selection.this) == 2,
      length(output.plan_ids) == 2,
      contains(keys(output.plan_ids), "hourly"),
      output.vault_arn == "arn:aws:backup:us-east-1:123456789012:backup-vault:mock",
      output.vault_name == "app-backup",
    ])
    error_message = "Two plans -> two plans/selections and populated output maps"
  }
}

# --- multiple selections per plan (the key universality feature) ------------
run "multiple_selections_per_plan" {
  command = apply

  variables {
    plans = {
      daily = {
        rules = { d = { schedule = "cron(0 5 * * ? *)", delete_after_days = 35 } }
        selections = {
          by-tag = { selection_tags = [{ key = "Backup", value = "true" }] }
          by-arn = { resources = ["arn:aws:dynamodb:us-east-1:123456789012:table/x"] }
        }
      }
    }
  }

  assert {
    condition = alltrue([
      length(aws_backup_selection.this) == 2,
      contains(keys(aws_backup_selection.this), "daily/by-tag"),
      contains(keys(aws_backup_selection.this), "daily/by-arn"),
      aws_backup_selection.this["daily/by-arn"].name == "daily-by-arn",
      aws_backup_selection.this["daily/by-tag"].plan_id == aws_backup_selection.this["daily/by-arn"].plan_id,
    ])
    error_message = "Two selections under one plan should both render and share the plan_id"
  }
}

# --- start/completion windows + cold storage lifecycle + archive opt-in -----
run "lifecycle_and_windows_render" {
  command = apply

  variables {
    plans = {
      tiered = {
        rules = {
          d = {
            schedule                  = "cron(0 5 * * ? *)"
            start_window_minutes      = 120
            completion_window_minutes = 360
            cold_storage_after_days   = 30
            delete_after_days         = 120
            opt_in_to_archive         = true
          }
        }
        selections = { all = { resources = ["*"] } }
      }
    }
  }

  assert {
    condition = alltrue([
      one(aws_backup_plan.this["tiered"].rule).start_window == 120,
      one(aws_backup_plan.this["tiered"].rule).completion_window == 360,
      one(one(aws_backup_plan.this["tiered"].rule).lifecycle).cold_storage_after == 30,
      one(one(aws_backup_plan.this["tiered"].rule).lifecycle).delete_after == 120,
      one(one(aws_backup_plan.this["tiered"].rule).lifecycle).opt_in_to_archive_for_supported_resources == true,
    ])
    error_message = "Windows, cold+delete lifecycle, and archive opt-in must render"
  }
}

# --- recovery_point_tags merged with common_tags + user tags ----------------
run "recovery_point_tags_merge" {
  command = apply

  variables {
    tags = { Team = "payments" }
    plans = {
      daily = {
        rules      = { d = { schedule = "cron(0 5 * * ? *)", delete_after_days = 35, recovery_point_tags = { Class = "gold" } } }
        selections = { all = { resources = ["*"] } }
      }
    }
  }

  assert {
    condition = alltrue([
      one(aws_backup_plan.this["daily"].rule).recovery_point_tags["Class"] == "gold",
      one(aws_backup_plan.this["daily"].rule).recovery_point_tags["ManagedBy"] == "Terraform",
      one(aws_backup_plan.this["daily"].rule).recovery_point_tags["Team"] == "payments",
    ])
    error_message = "recovery_point_tags must merge common_tags (incl. user tags) with per-rule tags"
  }
}

# --- CMK + vault lock (compliance) + notifications --------------------------
run "cmk_lock_notify" {
  command = apply

  variables {
    kms_key_arn                 = "arn:aws:kms:us-east-1:123456789012:key/abc"
    notifications_sns_topic_arn = "arn:aws:sns:us-east-1:123456789012:backup-alerts"
    vault_lock = {
      enabled             = true
      min_retention_days  = 30
      max_retention_days  = 365
      changeable_for_days = 3
    }
  }

  assert {
    condition = alltrue([
      aws_backup_vault.this[0].kms_key_arn == "arn:aws:kms:us-east-1:123456789012:key/abc",
      length(aws_backup_vault_lock_configuration.this) == 1,
      aws_backup_vault_lock_configuration.this[0].min_retention_days == 30,
      aws_backup_vault_lock_configuration.this[0].changeable_for_days == 3,
      length(aws_backup_vault_notifications.this) == 1,
    ])
    error_message = "CMK, compliance-mode lock, and notifications should wire"
  }
}

# --- governance-mode lock: changeable/max 0 -> null -------------------------
run "vault_lock_governance_nulls" {
  command = apply

  variables {
    vault_lock = { enabled = true, min_retention_days = 30, max_retention_days = 0, changeable_for_days = 0 }
  }

  assert {
    condition = alltrue([
      length(aws_backup_vault_lock_configuration.this) == 1,
      aws_backup_vault_lock_configuration.this[0].max_retention_days == null,
      aws_backup_vault_lock_configuration.this[0].changeable_for_days == null,
    ])
    error_message = "Governance mode: max_retention_days=0 and changeable_for_days=0 must render as null"
  }
}

# --- force_destroy passthrough (empty kms -> AWS-managed key) ---------------
# kms_key_arn is optional+computed, so under mocks it's a generated value, not
# null; the empty-string -> null wiring is exercised by the cmk_lock_notify test.
run "force_destroy_passthrough" {
  command = apply

  variables { force_destroy = true }

  assert {
    condition     = aws_backup_vault.this[0].force_destroy == true
    error_message = "force_destroy must pass through to the vault"
  }
}

# --- custom notification event list -----------------------------------------
run "custom_notification_events" {
  command = apply

  variables {
    notifications_sns_topic_arn = "arn:aws:sns:us-east-1:123456789012:backup-alerts"
    notification_events         = ["BACKUP_JOB_STARTED", "BACKUP_JOB_COMPLETED"]
  }

  assert {
    condition = alltrue([
      length(aws_backup_vault_notifications.this) == 1,
      length(aws_backup_vault_notifications.this[0].backup_vault_events) == 2,
      contains(tolist(aws_backup_vault_notifications.this[0].backup_vault_events), "BACKUP_JOB_STARTED"),
    ])
    error_message = "Custom notification_events must render onto the vault notifications"
  }
}

# --- continuous backup (PITR) rule ------------------------------------------
run "continuous_backup" {
  command = apply

  variables {
    plans = {
      pitr = {
        rules = {
          continuous = {
            schedule                 = "cron(0 * * * ? *)"
            enable_continuous_backup = true
            delete_after_days        = 35
          }
        }
        selections = { all = { resources = ["*"] } }
      }
    }
  }

  assert {
    condition     = one(aws_backup_plan.this["pitr"].rule).enable_continuous_backup == true
    error_message = "enable_continuous_backup should render on the rule"
  }
}

# --- multiple cross-region copies + copy lifecycle --------------------------
run "multiple_copy_actions" {
  command = apply

  variables {
    plans = {
      dr = {
        rules = {
          daily = {
            schedule          = "cron(0 5 * * ? *)"
            delete_after_days = 35
            copy_actions = [
              { destination_vault_arn = "arn:aws:backup:us-west-2:123456789012:backup-vault:dr1", cold_storage_after_days = 30, delete_after_days = 200 },
              { destination_vault_arn = "arn:aws:backup:eu-west-1:123456789012:backup-vault:dr2", delete_after_days = 90 },
            ]
          }
        }
        selections = { all = { resources = ["*"] } }
      }
    }
  }

  assert {
    condition = alltrue([
      length(one(aws_backup_plan.this["dr"].rule).copy_action) == 2,
      [for c in one(aws_backup_plan.this["dr"].rule).copy_action : one(c.lifecycle).cold_storage_after if c.destination_vault_arn == "arn:aws:backup:us-west-2:123456789012:backup-vault:dr1"][0] == 30,
    ])
    error_message = "Both copy_actions render; copy lifecycle cold_storage_after applies"
  }
}

# --- condition-based selection (StringLike / StringNotEquals) ---------------
run "condition_selection" {
  command = apply

  variables {
    plans = {
      daily = {
        rules = { d = { schedule = "cron(0 5 * * ? *)", delete_after_days = 35 } }
        selections = {
          conditional = {
            conditions = [
              { test = "StringLike", key = "aws:ResourceTag/Environment", value = "prod*" },
              { test = "StringNotEquals", key = "aws:ResourceTag/Backup", value = "false" },
            ]
          }
        }
      }
    }
  }

  assert {
    condition = alltrue([
      length(one(aws_backup_selection.this["daily/conditional"].condition).string_like) == 1,
      length(one(aws_backup_selection.this["daily/conditional"].condition).string_not_equals) == 1,
      one(one(aws_backup_selection.this["daily/conditional"].condition).string_like).value == "prod*",
    ])
    error_message = "condition string_like/string_not_equals sub-blocks must render"
  }
}

# --- not_resources + multiple selection_tags (AND) --------------------------
run "not_resources_and_multi_tags" {
  command = apply

  variables {
    plans = {
      daily = {
        rules = { d = { schedule = "cron(0 5 * * ? *)", delete_after_days = 35 } }
        selections = {
          filtered = {
            resources     = ["*"]
            not_resources = ["arn:aws:dynamodb:us-east-1:123456789012:table/ephemeral"]
            selection_tags = [
              { key = "Backup", value = "true" },
              { key = "Env", value = "prod" },
            ]
          }
        }
      }
    }
  }

  assert {
    condition = alltrue([
      length(aws_backup_selection.this["daily/filtered"].selection_tag) == 2,
      length(aws_backup_selection.this["daily/filtered"].not_resources) == 1,
    ])
    error_message = "not_resources and multiple selection_tags must render"
  }
}

# --- advanced backup setting (Windows VSS) ----------------------------------
run "advanced_backup_setting" {
  command = apply

  variables {
    plans = {
      windows = {
        rules      = { d = { schedule = "cron(0 5 * * ? *)", delete_after_days = 35 } }
        selections = { all = { resources = ["*"] } }
        advanced_backup_settings = [
          { resource_type = "EC2", backup_options = { WindowsVSS = "enabled" } }
        ]
      }
    }
  }

  assert {
    condition     = one(aws_backup_plan.this["windows"].advanced_backup_setting).backup_options["WindowsVSS"] == "enabled"
    error_message = "advanced_backup_setting (Windows VSS) must render"
  }
}

# --- schedule timezone ------------------------------------------------------
run "schedule_timezone" {
  command = apply

  variables {
    plans = {
      tz = {
        rules      = { d = { schedule = "cron(0 5 * * ? *)", schedule_expression_timezone = "Europe/London", delete_after_days = 35 } }
        selections = { all = { resources = ["*"] } }
      }
    }
  }

  assert {
    condition     = one(aws_backup_plan.this["tz"].rule).schedule_expression_timezone == "Europe/London"
    error_message = "schedule_expression_timezone must render"
  }
}

# --- external (BYO) vault: plans target it, module makes no vault -----------
run "external_vault" {
  command = plan

  variables {
    create_vault = false
    vault_name   = "central-org-vault"
  }

  assert {
    condition = alltrue([
      length(aws_backup_vault.this) == 0,
      length(aws_backup_vault_lock_configuration.this) == 0,
      output.vault_name == "central-org-vault",
      output.vault_arn == null,
    ])
    error_message = "create_vault=false should make no vault and target the external name"
  }
}

# --- BYO role wired into the selection --------------------------------------
run "byo_role_wired" {
  command = plan

  variables {
    create_role = false
    role_arn    = "arn:aws:iam::123456789012:role/existing-backup"
  }

  assert {
    condition = alltrue([
      length(aws_iam_role.backup) == 0,
      aws_backup_selection.this["daily/tagged"].iam_role_arn == "arn:aws:iam::123456789012:role/existing-backup",
      output.role_arn == "arn:aws:iam::123456789012:role/existing-backup",
      output.role_name == null,
    ])
    error_message = "BYO role_arn must be wired into the selection and no role created"
  }
}

# --- IAM extras: permissions boundary + additional policy -------------------
run "iam_extras" {
  command = plan

  variables {
    role_permissions_boundary_arn = "arn:aws:iam::123456789012:policy/boundary"
    additional_policy_arns        = ["arn:aws:iam::123456789012:policy/extra"]
    attach_restore_policy         = false
  }

  assert {
    condition = alltrue([
      aws_iam_role.backup[0].permissions_boundary == "arn:aws:iam::123456789012:policy/boundary",
      length(aws_iam_role_policy_attachment.additional) == 1,
      length(aws_iam_role_policy_attachment.restore) == 0,
    ])
    error_message = "permissions boundary, additional policy, and restore opt-out must all wire"
  }
}

# --- vault access policy (cross-account copy destination) -------------------
run "vault_access_policy" {
  command = plan
  variables {
    vault_access_policy_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
  assert {
    condition     = length(aws_backup_vault_policy.this) == 1
    error_message = "vault_access_policy_json should create a vault policy"
  }
}

# --- create = false ---------------------------------------------------------
run "create_false" {
  command = plan
  variables { create = false }
  assert {
    condition = alltrue([
      length(aws_backup_vault.this) == 0,
      length(aws_backup_plan.this) == 0,
      length(aws_backup_selection.this) == 0,
      length(aws_iam_role.backup) == 0,
    ])
    error_message = "create=false builds nothing"
  }
}

# ============================================================================
# VALIDATION FAILURES
# ============================================================================

run "byo_without_arn_fails" {
  command = plan
  variables {
    create_role = false
    role_arn    = ""
  }
  expect_failures = [var.role_arn]
}

run "empty_rules_fails" {
  command = plan
  variables {
    plans = { p = { rules = {}, selections = { a = { resources = ["*"] } } } }
  }
  expect_failures = [var.plans]
}

run "null_rules_fails" {
  command = plan
  variables {
    plans = { p = { rules = null, selections = { a = { resources = ["*"] } } } }
  }
  expect_failures = [var.plans]
}

run "empty_selection_fails" {
  command = plan
  variables {
    plans = { p = { rules = { d = { schedule = "cron(0 5 * * ? *)" } }, selections = { a = {} } } }
  }
  expect_failures = [var.plans]
}

run "cold_before_delete_plus_90_fails" {
  command = plan
  variables {
    plans = {
      p = {
        rules      = { d = { schedule = "cron(0 5 * * ? *)", cold_storage_after_days = 30, delete_after_days = 60 } }
        selections = { a = { resources = ["*"] } }
      }
    }
  }
  expect_failures = [var.plans]
}

run "continuous_with_cold_fails" {
  command = plan
  variables {
    plans = {
      p = {
        rules      = { d = { schedule = "cron(0 5 * * ? *)", enable_continuous_backup = true, cold_storage_after_days = 30, delete_after_days = 130 } }
        selections = { a = { resources = ["*"] } }
      }
    }
  }
  expect_failures = [var.plans]
}

run "continuous_with_copy_fails" {
  command = plan
  variables {
    plans = {
      p = {
        rules = { d = {
          schedule                 = "cron(0 5 * * ? *)"
          enable_continuous_backup = true
          delete_after_days        = 35
          copy_actions             = [{ destination_vault_arn = "arn:aws:backup:us-west-2:123456789012:backup-vault:dr" }]
        } }
        selections = { a = { resources = ["*"] } }
      }
    }
  }
  expect_failures = [var.plans]
}

run "bad_schedule_fails" {
  command = plan
  variables {
    plans = { p = { rules = { d = { schedule = "every day" } }, selections = { a = { resources = ["*"] } } } }
  }
  expect_failures = [var.plans]
}

run "start_window_too_small_fails" {
  command = plan
  variables {
    plans = {
      p = {
        rules      = { d = { schedule = "cron(0 5 * * ? *)", start_window_minutes = 30 } }
        selections = { a = { resources = ["*"] } }
      }
    }
  }
  expect_failures = [var.plans]
}

run "pitr_retention_out_of_range_fails" {
  command = plan
  variables {
    plans = {
      p = {
        rules      = { d = { schedule = "cron(0 5 * * ? *)", enable_continuous_backup = true, delete_after_days = 100 } }
        selections = { a = { resources = ["*"] } }
      }
    }
  }
  expect_failures = [var.plans]
}

run "too_many_recovery_point_tags_fails" {
  command = plan
  variables {
    plans = {
      p = {
        rules = { d = {
          schedule            = "cron(0 5 * * ? *)"
          delete_after_days   = 35
          recovery_point_tags = { for i in range(46) : "k${i}" => "v" }
        } }
        selections = { a = { resources = ["*"] } }
      }
    }
  }
  expect_failures = [var.plans]
}

run "bad_condition_test_fails" {
  command = plan
  variables {
    plans = {
      p = {
        rules      = { d = { schedule = "cron(0 5 * * ? *)", delete_after_days = 35 } }
        selections = { a = { conditions = [{ test = "StringContains", key = "aws:ResourceTag/x", value = "y" }] } }
      }
    }
  }
  expect_failures = [var.plans]
}

run "bad_notification_event_fails" {
  command = plan
  variables {
    notification_events = ["JOB_EXPLODED"]
  }
  expect_failures = [var.notification_events]
}

run "bad_copy_arn_fails" {
  command = plan
  variables {
    plans = {
      p = {
        rules      = { d = { schedule = "cron(0 5 * * ? *)", delete_after_days = 35, copy_actions = [{ destination_vault_arn = "not-an-arn" }] } }
        selections = { a = { resources = ["*"] } }
      }
    }
  }
  expect_failures = [var.plans]
}

run "bad_vault_lock_grace_fails" {
  command = plan
  variables {
    vault_lock = { enabled = true, changeable_for_days = 1 }
  }
  expect_failures = [var.vault_lock]
}

run "vault_lock_retention_too_large_fails" {
  command = plan
  variables {
    vault_lock = { enabled = true, min_retention_days = 40000 }
  }
  expect_failures = [var.vault_lock]
}

run "bad_vault_name_fails" {
  command = plan
  variables {
    vault_name = "bad vault name!"
  }
  expect_failures = [var.vault_name]
}

# cold storage with no expiry ("keep forever") is a VALID AWS lifecycle - the
# cold+90 rule only applies when a delete IS set. This must NOT be rejected.
run "cold_storage_keep_forever_ok" {
  command = apply
  variables {
    plans = {
      archive = {
        rules = {
          weekly = {
            schedule                = "cron(0 6 ? * SUN *)"
            cold_storage_after_days = 30
            delete_after_days       = 0 # never expire
          }
        }
        selections = { all = { resources = ["*"] } }
      }
    }
  }
  assert {
    condition     = one(one(aws_backup_plan.this["archive"].rule).lifecycle).cold_storage_after == 30
    error_message = "cold storage with delete=0 (keep forever) should be allowed and render"
  }
}

run "null_selection_tag_key_fails" {
  command = plan
  variables {
    plans = {
      p = {
        rules      = { d = { schedule = "cron(0 5 * * ? *)", delete_after_days = 35 } }
        selections = { s = { selection_tags = [{ key = null, value = "x" }] } }
      }
    }
  }
  expect_failures = [var.plans]
}
