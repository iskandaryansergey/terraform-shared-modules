# Centralized, policy-driven backups: an (optional) encrypted, WORM-lockable
# vault, schedule-driven plans with lifecycle tiering and cross-region/account
# copy, and tag- or condition-based selection. Point it at its own vault or a
# central one; bring your own IAM role or let it build one.

data "aws_partition" "current" {}

# ----------------------------------------------------------------------------
# VAULT (+ optional WORM lock, notifications, resource policy)
# ----------------------------------------------------------------------------
resource "aws_backup_vault" "this" {
  count = local.create && var.create_vault ? 1 : 0

  name          = var.vault_name
  kms_key_arn   = var.kms_key_arn != "" ? var.kms_key_arn : null
  force_destroy = var.force_destroy
  tags          = local.common_tags
}

resource "aws_backup_vault_lock_configuration" "this" {
  count = local.create && var.create_vault && var.vault_lock.enabled ? 1 : 0

  backup_vault_name  = aws_backup_vault.this[0].name
  min_retention_days = var.vault_lock.min_retention_days
  max_retention_days = var.vault_lock.max_retention_days > 0 ? var.vault_lock.max_retention_days : null
  # omitting changeable_for_days is what picks governance mode; setting it (>=3)
  # picks compliance mode.
  changeable_for_days = var.vault_lock.changeable_for_days > 0 ? var.vault_lock.changeable_for_days : null
}

resource "aws_backup_vault_notifications" "this" {
  count = local.create && var.create_vault && var.notifications_sns_topic_arn != "" ? 1 : 0

  backup_vault_name   = aws_backup_vault.this[0].name
  sns_topic_arn       = var.notifications_sns_topic_arn
  backup_vault_events = var.notification_events
}

resource "aws_backup_vault_policy" "this" {
  count = local.create && var.create_vault && var.vault_access_policy_json != "" ? 1 : 0

  backup_vault_name = aws_backup_vault.this[0].name
  policy            = var.vault_access_policy_json
}

# ----------------------------------------------------------------------------
# IAM SERVICE ROLE (create or BYO)
# ----------------------------------------------------------------------------
data "aws_iam_policy_document" "assume" {
  count = local.create && var.create_role ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  count = local.create && var.create_role ? 1 : 0

  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.assume[0].json
  permissions_boundary = var.role_permissions_boundary_arn != "" ? var.role_permissions_boundary_arn : null
  tags                 = local.common_tags
}

# AWS-managed policies, partition-aware so this works in GovCloud/China too.
resource "aws_iam_role_policy_attachment" "backup" {
  count = local.create && var.create_role ? 1 : 0

  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "restore" {
  count = local.create && var.create_role && var.attach_restore_policy ? 1 : 0

  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

resource "aws_iam_role_policy_attachment" "additional" {
  for_each = local.create && var.create_role ? toset(var.additional_policy_arns) : toset([])

  role       = aws_iam_role.backup[0].name
  policy_arn = each.value
}

# ----------------------------------------------------------------------------
# PLANS
# ----------------------------------------------------------------------------
resource "aws_backup_plan" "this" {
  for_each = local.create ? var.plans : {}

  name = each.key

  dynamic "rule" {
    for_each = each.value.rules
    content {
      rule_name                    = rule.key
      target_vault_name            = local.vault_name
      schedule                     = rule.value.schedule
      schedule_expression_timezone = rule.value.schedule_expression_timezone
      start_window                 = rule.value.start_window_minutes
      completion_window            = rule.value.completion_window_minutes

      enable_continuous_backup = rule.value.enable_continuous_backup
      recovery_point_tags      = merge(local.common_tags, rule.value.recovery_point_tags)

      dynamic "lifecycle" {
        for_each = rule.value.cold_storage_after_days > 0 || rule.value.delete_after_days > 0 ? [1] : []
        content {
          cold_storage_after                        = rule.value.cold_storage_after_days > 0 ? rule.value.cold_storage_after_days : null
          delete_after                              = rule.value.delete_after_days > 0 ? rule.value.delete_after_days : null
          opt_in_to_archive_for_supported_resources = rule.value.opt_in_to_archive ? true : null
        }
      }

      dynamic "copy_action" {
        for_each = rule.value.copy_actions
        content {
          destination_vault_arn = copy_action.value.destination_vault_arn

          dynamic "lifecycle" {
            for_each = copy_action.value.cold_storage_after_days > 0 || copy_action.value.delete_after_days > 0 ? [1] : []
            content {
              cold_storage_after = copy_action.value.cold_storage_after_days > 0 ? copy_action.value.cold_storage_after_days : null
              delete_after       = copy_action.value.delete_after_days > 0 ? copy_action.value.delete_after_days : null
            }
          }
        }
      }
    }
  }

  dynamic "advanced_backup_setting" {
    for_each = each.value.advanced_backup_settings
    content {
      resource_type  = advanced_backup_setting.value.resource_type
      backup_options = advanced_backup_setting.value.backup_options
    }
  }

  tags = local.common_tags
}

# ----------------------------------------------------------------------------
# SELECTIONS (many per plan; tag-, condition- and/or ARN-based)
# ----------------------------------------------------------------------------
resource "aws_backup_selection" "this" {
  for_each = local.create ? local.selections : {}

  name          = "${each.value.plan}-${each.value.selection}"
  iam_role_arn  = local.role_arn
  plan_id       = aws_backup_plan.this[each.value.plan].id
  resources     = each.value.resources
  not_resources = each.value.not_resources

  dynamic "selection_tag" {
    for_each = { for i, t in each.value.selection_tags : i => t }
    content {
      type  = selection_tag.value.type
      key   = selection_tag.value.key
      value = selection_tag.value.value
    }
  }

  # richer matching lives in a single condition block with typed sub-blocks.
  dynamic "condition" {
    for_each = length(each.value.conditions) > 0 ? [each.value.conditions] : []
    content {
      dynamic "string_equals" {
        for_each = [for c in condition.value : c if c.test == "StringEquals"]
        content {
          key   = string_equals.value.key
          value = string_equals.value.value
        }
      }
      dynamic "string_like" {
        for_each = [for c in condition.value : c if c.test == "StringLike"]
        content {
          key   = string_like.value.key
          value = string_like.value.value
        }
      }
      dynamic "string_not_equals" {
        for_each = [for c in condition.value : c if c.test == "StringNotEquals"]
        content {
          key   = string_not_equals.value.key
          value = string_not_equals.value.value
        }
      }
      dynamic "string_not_like" {
        for_each = [for c in condition.value : c if c.test == "StringNotLike"]
        content {
          key   = string_not_like.value.key
          value = string_not_like.value.value
        }
      }
    }
  }
}
