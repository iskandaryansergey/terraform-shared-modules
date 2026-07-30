# ============================================================================
# GENERAL
# ============================================================================

variable "create" {
  description = "Master switch. Everything in the module hangs off this - flip it to false and nothing gets created."
  type        = bool
  default     = true
  nullable    = false
}

variable "tags" {
  description = "Tags put on every resource the module makes."
  type        = map(string)
  default     = {}
  nullable    = false
}

# ============================================================================
# VAULT
# ============================================================================

variable "create_vault" {
  description = "Create the vault. Set false to point the plans at a vault you already have (central-vault setups) - then vault_name is the existing vault's name and the lock/notifications/policy knobs are ignored."
  type        = bool
  default     = true
  nullable    = false
}

variable "vault_name" {
  description = "Vault name. When create_vault is true it's the name we give the new vault; when false it's the existing vault the plans target."
  type        = string
  default     = "default-backup"
  nullable    = false

  validation {
    # AWS's real vault-name pattern.
    condition     = can(regex("^[a-zA-Z0-9_-]{2,50}$", var.vault_name))
    error_message = "vault_name must be 2-50 chars: letters, numbers, underscore, hyphen."
  }
}

variable "kms_key_arn" {
  description = "CMK for the vault. Leave empty to get the free AWS-managed backup key (still encrypted, just not your own key)."
  type        = string
  default     = ""
  nullable    = false
}

variable "force_destroy" {
  description = "Let Terraform delete the vault even if it still holds recovery points. Keep it false in prod - and note a Vault Lock overrides it anyway."
  type        = bool
  default     = false
  nullable    = false
}

variable "vault_lock" {
  description = <<-EOT
    Vault Lock (WORM). Once on, recovery points can't be deleted before
    min_retention_days.

    changeable_for_days is the mode switch: leave it 0 for governance mode (an
    admin can still lift the lock later), or set it >= 3 for compliance mode.
    Compliance mode is a one-way door - after the grace-period days elapse the
    lock is permanent and cannot be shortened or removed by anyone, AWS and the
    account root included. Try governance first.
  EOT
  type = object({
    enabled             = optional(bool, false)
    min_retention_days  = optional(number, 7)
    max_retention_days  = optional(number, 0) # 0 = no ceiling
    changeable_for_days = optional(number, 0) # 0 = governance; >= 3 = compliance
  })
  default  = {}
  nullable = false

  validation {
    condition     = !var.vault_lock.enabled || (var.vault_lock.min_retention_days >= 1 && var.vault_lock.min_retention_days <= 36500)
    error_message = "vault_lock.min_retention_days must be 1-36500 when enabled."
  }
  validation {
    condition     = var.vault_lock.max_retention_days >= 0 && var.vault_lock.max_retention_days <= 36500
    error_message = "vault_lock.max_retention_days must be 0 (unbounded) or 1-36500."
  }
  validation {
    condition     = var.vault_lock.max_retention_days == 0 || var.vault_lock.max_retention_days >= var.vault_lock.min_retention_days
    error_message = "vault_lock.max_retention_days must be 0 (unbounded) or >= min_retention_days."
  }
  validation {
    condition     = var.vault_lock.changeable_for_days == 0 || var.vault_lock.changeable_for_days >= 3
    error_message = "vault_lock.changeable_for_days must be 0 (governance) or >= 3 (AWS's 72h compliance cooling-off)."
  }
}

variable "vault_access_policy_json" {
  description = "Resource policy for the vault (empty = none). Mainly for the receiving end of a cross-account copy: let another account's Backup write into this vault."
  type        = string
  default     = ""
  nullable    = false
}

# ============================================================================
# IAM ROLE
# ============================================================================

variable "create_role" {
  description = "Create the service role Backup assumes. Set false and pass role_arn to reuse one you already have."
  type        = bool
  default     = true
  nullable    = false
}

variable "role_arn" {
  description = "Existing role ARN for AWS Backup (used when create_role = false)."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.create_role || var.role_arn != ""
    error_message = "Set role_arn when create_role = false."
  }
}

variable "role_name" {
  description = "Name for the role we create (when create_role = true)."
  type        = string
  default     = "aws-backup-role"
  nullable    = false
}

variable "attach_restore_policy" {
  description = "Attach the AWS-managed Restore policy too. Turn it off for a backup-only role that isn't allowed to restore."
  type        = bool
  default     = true
  nullable    = false
}

variable "additional_policy_arns" {
  description = "Extra policy ARNs to attach to the created role - for scoped, customer-managed permissions on top of (or instead of) the AWS-managed ones."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "role_permissions_boundary_arn" {
  description = "Permissions boundary for the created role (empty = none). Plenty of orgs require one on every role."
  type        = string
  default     = ""
  nullable    = false
}

# ============================================================================
# NOTIFICATIONS
# ============================================================================

variable "notifications_sns_topic_arn" {
  description = "SNS topic for vault events (empty = off). Wire it up in prod so failed jobs aren't silent."
  type        = string
  default     = ""
  nullable    = false
}

variable "notification_events" {
  description = "Which vault events to publish. Defaults to the three failure events - that's usually all you want paging you."
  type        = list(string)
  default     = ["BACKUP_JOB_FAILED", "COPY_JOB_FAILED", "RESTORE_JOB_FAILED"]
  nullable    = false

  validation {
    condition = alltrue([for e in var.notification_events : contains([
      "BACKUP_JOB_STARTED", "BACKUP_JOB_COMPLETED", "BACKUP_JOB_SUCCESSFUL", "BACKUP_JOB_FAILED", "BACKUP_JOB_EXPIRED",
      "COPY_JOB_STARTED", "COPY_JOB_SUCCESSFUL", "COPY_JOB_FAILED",
      "RESTORE_JOB_STARTED", "RESTORE_JOB_COMPLETED", "RESTORE_JOB_SUCCESSFUL", "RESTORE_JOB_FAILED",
      "RECOVERY_POINT_MODIFIED", "BACKUP_PLAN_CREATED", "BACKUP_PLAN_MODIFIED",
    ], e)])
    error_message = "notification_events must be valid AWS BackupVaultEvents values."
  }
}

# ============================================================================
# PLANS + SELECTIONS
# ============================================================================

variable "plans" {
  description = <<-EOT
    Backup plans, keyed by plan name. Each plan is a set of rules plus one or
    more resource selections.

      rules (keyed by rule name):
        schedule                    cron/rate expr, e.g. "cron(0 5 * * ? *)".
        schedule_expression_timezone  timezone for the schedule (default UTC).
        start_window_minutes        must start within this window (AWS min 60).
        completion_window_minutes   must finish within this window.
        cold_storage_after_days     tier to cold storage after N days (0 = never).
        delete_after_days           expire after N days (0 = never). With cold
                                    set, this must be >= cold + 90 (AWS rule).
        opt_in_to_archive           opt in to archive tier for supported types.
        enable_continuous_backup    point-in-time restore (1-35 day window; no
                                    cold storage and no copies with it).
        recovery_point_tags         tags stamped on each recovery point.
        copy_actions                copies to other vaults (cross region/account).

      selections (keyed by selection name):
        resources / not_resources   ARNs to include / exclude (["*"] = all).
        selection_tags              simple tag equality (AND-ed).
        conditions                  richer matching - StringEquals / StringLike /
                                    StringNotEquals / StringNotLike. Keys use the
                                    "aws:ResourceTag/<Key>" form.

      advanced_backup_settings       e.g. Windows VSS: resource_type = "EC2",
                                     backup_options = { WindowsVSS = "enabled" }.
  EOT
  type = map(object({
    rules = map(object({
      schedule                     = string
      schedule_expression_timezone = optional(string, "Etc/UTC")
      start_window_minutes         = optional(number, 60)
      completion_window_minutes    = optional(number, 180)
      cold_storage_after_days      = optional(number, 0)
      delete_after_days            = optional(number, 0)
      opt_in_to_archive            = optional(bool, false)
      enable_continuous_backup     = optional(bool, false)
      recovery_point_tags          = optional(map(string), {})
      copy_actions = optional(list(object({
        destination_vault_arn   = string
        cold_storage_after_days = optional(number, 0)
        delete_after_days       = optional(number, 0)
      })), [])
    }))
    selections = optional(map(object({
      resources     = optional(list(string), [])
      not_resources = optional(list(string), [])
      selection_tags = optional(list(object({
        type  = optional(string, "STRINGEQUALS")
        key   = string
        value = string
      })), [])
      conditions = optional(list(object({
        test  = string # StringEquals | StringLike | StringNotEquals | StringNotLike
        key   = string # e.g. "aws:ResourceTag/Environment"
        value = string
      })), [])
    })), {})
    advanced_backup_settings = optional(list(object({
      resource_type  = string      # e.g. "EC2"
      backup_options = map(string) # e.g. { WindowsVSS = "enabled" }
    })), [])
  }))
  default  = {}
  nullable = false

  # ---- plan/rule shape -----------------------------------------------------

  validation {
    condition     = alltrue([for p, plan in var.plans : try(length(plan.rules), 0) > 0])
    error_message = "Each plan must define at least one rule."
  }
  validation {
    condition = alltrue([
      for p, plan in var.plans : alltrue([
        for rk, r in(plan.rules == null ? {} : plan.rules) :
        can(regex("^(cron|rate)\\(.+\\)$", r.schedule))
      ])
    ])
    error_message = "Each rule.schedule must be a cron(...) or rate(...) expression."
  }
  # AWS's real floor is a 60-minute start window. Completion window is measured
  # from when the job starts and has no documented minimum, so we don't couple them.
  validation {
    condition = alltrue([
      for p, plan in var.plans : alltrue([
        for rk, r in(plan.rules == null ? {} : plan.rules) :
        r.start_window_minutes >= 60
      ])
    ])
    error_message = "rule.start_window_minutes must be >= 60 (AWS minimum)."
  }
  validation {
    condition = alltrue([
      for p, plan in var.plans : alltrue([
        for rk, r in(plan.rules == null ? {} : plan.rules) :
        r.cold_storage_after_days >= 0 && r.delete_after_days >= 0 && r.start_window_minutes >= 0 && r.completion_window_minutes >= 0
      ])
    ])
    error_message = "rule day/window values must be >= 0."
  }

  # ---- lifecycle rules AWS enforces ---------------------------------------

  # cold storage has a 90-day floor, so when a delete IS set it must sit at least
  # 90 days past it. delete_after_days = 0 means "keep forever", which is fine.
  validation {
    condition = alltrue([
      for p, plan in var.plans : alltrue([
        for rk, r in(plan.rules == null ? {} : plan.rules) :
        r.cold_storage_after_days == 0 || r.delete_after_days == 0 || (r.delete_after_days >= r.cold_storage_after_days + 90)
      ])
    ])
    error_message = "When both cold_storage_after_days and delete_after_days are set, delete must be >= cold + 90."
  }
  # continuous backups top out at 35 days, so they can't tier to cold (90-day min)...
  validation {
    condition = alltrue([
      for p, plan in var.plans : alltrue([
        for rk, r in(plan.rules == null ? {} : plan.rules) :
        !r.enable_continuous_backup || r.cold_storage_after_days == 0
      ])
    ])
    error_message = "enable_continuous_backup can't be combined with cold_storage_after_days."
  }
  # ...and PITR recovery points can't be copied like snapshots.
  validation {
    condition = alltrue([
      for p, plan in var.plans : alltrue([
        for rk, r in(plan.rules == null ? {} : plan.rules) :
        !r.enable_continuous_backup || length(r.copy_actions) == 0
      ])
    ])
    error_message = "enable_continuous_backup can't be combined with copy_actions (PITR points aren't copyable)."
  }
  # if you turn on PITR, retention has to land in the 1-35 day window.
  validation {
    condition = alltrue([
      for p, plan in var.plans : alltrue([
        for rk, r in(plan.rules == null ? {} : plan.rules) :
        !r.enable_continuous_backup || (r.delete_after_days >= 1 && r.delete_after_days <= 35)
      ])
    ])
    error_message = "With enable_continuous_backup, delete_after_days must be 1-35 (the PITR window)."
  }
  # same cold+90 rule applies to each copy's own lifecycle (keep-forever ok).
  validation {
    condition = alltrue([
      for p, plan in var.plans : alltrue([
        for rk, r in(plan.rules == null ? {} : plan.rules) : alltrue([
          for c in r.copy_actions :
          c.cold_storage_after_days == 0 || c.delete_after_days == 0 || (c.delete_after_days >= c.cold_storage_after_days + 90)
        ])
      ])
    ])
    error_message = "copy_actions: when both cold_storage_after_days and delete_after_days are set, delete must be >= cold + 90."
  }
  validation {
    condition = alltrue([
      for p, plan in var.plans : alltrue([
        for rk, r in(plan.rules == null ? {} : plan.rules) : alltrue([
          for c in r.copy_actions : can(regex("^arn:aws[a-z-]*:backup:", c.destination_vault_arn))
        ])
      ])
    ])
    error_message = "copy_actions.destination_vault_arn must be a backup vault ARN (arn:aws:backup:...)."
  }
  # Backup fails a job if the plan's tags + the source resource's tags top 50.
  # We can only see our side, so guard the plan-side budget generously.
  validation {
    condition = alltrue([
      for p, plan in var.plans : alltrue([
        for rk, r in(plan.rules == null ? {} : plan.rules) :
        length(r.recovery_point_tags) <= 45
      ])
    ])
    error_message = "recovery_point_tags is capped well under AWS's 50-tag-per-recovery-point limit (source tags count too); keep it <= 45."
  }

  # ---- selection shape -----------------------------------------------------

  # a selection has to target something, or it protects nothing.
  validation {
    condition = alltrue([
      for p, plan in var.plans : alltrue([
        for sk, sel in plan.selections :
        length(sel.resources) > 0 || length(sel.selection_tags) > 0 || length(sel.conditions) > 0
      ])
    ])
    error_message = "Each selection must set resources, selection_tags, and/or conditions (otherwise nothing is selected)."
  }
  validation {
    condition = alltrue([
      for p, plan in var.plans : alltrue([
        for sk, sel in plan.selections : alltrue([
          for t in sel.selection_tags : contains(["STRINGEQUALS"], t.type)
        ])
      ])
    ])
    error_message = "selection_tags[*].type must be STRINGEQUALS (use conditions for richer matching)."
  }
  validation {
    condition = alltrue([
      for p, plan in var.plans : alltrue([
        for sk, sel in plan.selections : alltrue([
          for c in sel.conditions : contains(["StringEquals", "StringLike", "StringNotEquals", "StringNotLike"], c.test)
        ])
      ])
    ])
    error_message = "conditions[*].test must be StringEquals, StringLike, StringNotEquals, or StringNotLike."
  }
  # required tag/condition fields must actually be set (a friendly message beats
  # the raw provider "argument is required" on an explicit null/empty).
  validation {
    condition = alltrue([
      for p, plan in var.plans : alltrue([
        for sk, sel in plan.selections : alltrue([
          for t in sel.selection_tags : try(trimspace(t.key), "") != "" && t.value != null
        ])
      ])
    ])
    error_message = "selection_tags[*].key/value must be set."
  }
  validation {
    condition = alltrue([
      for p, plan in var.plans : alltrue([
        for sk, sel in plan.selections : alltrue([
          for c in sel.conditions : try(trimspace(c.key), "") != "" && c.value != null
        ])
      ])
    ])
    error_message = "conditions[*].key/value must be set."
  }
  validation {
    condition = alltrue([
      for p, plan in var.plans : alltrue([
        for a in plan.advanced_backup_settings : try(trimspace(a.resource_type), "") != "" && a.backup_options != null
      ])
    ])
    error_message = "advanced_backup_settings[*].resource_type/backup_options must be set."
  }
}
