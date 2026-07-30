locals {
  create = var.create

  common_tags = merge(var.tags, {
    "ManagedBy" = "Terraform"
    "Module"    = "aws-backup"
  })

  # the vault the plans target: the one we made, or the existing name passed in.
  vault_name = var.create_vault ? one(aws_backup_vault.this[*].name) : var.vault_name

  role_arn = var.create_role ? one(aws_iam_role.backup[*].arn) : var.role_arn

  # AWS lets a plan have many selections, so flatten plan -> selections into one
  # keyed map ("plan/selection"). Each entry remembers its plan for the plan_id.
  selections = merge([
    for p, plan in var.plans : {
      for sk, sel in plan.selections : "${p}/${sk}" => merge(sel, { plan = p, selection = sk })
    }
  ]...)
}
