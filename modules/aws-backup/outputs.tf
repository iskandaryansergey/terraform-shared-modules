output "vault_arn" {
  description = "ARN of the vault (null when create_vault = false)."
  value       = one(aws_backup_vault.this[*].arn)
}

output "vault_name" {
  description = "Name of the vault the plans target (created or external)."
  value       = local.vault_name
}

output "vault_locked" {
  description = "Whether Vault Lock is configured on the vault we manage."
  value       = local.create && var.create_vault && var.vault_lock.enabled
}

output "role_arn" {
  description = "IAM role AWS Backup assumes (created or supplied)."
  value       = local.role_arn
}

output "role_name" {
  description = "Name of the created IAM role (null when using a BYO role) - handy for attaching more policies externally."
  value       = one(aws_iam_role.backup[*].name)
}

output "plan_ids" {
  description = "Map of plan name => backup plan ID."
  value       = { for k, p in aws_backup_plan.this : k => p.id }
}

output "plan_arns" {
  description = "Map of plan name => backup plan ARN."
  value       = { for k, p in aws_backup_plan.this : k => p.arn }
}

output "selection_ids" {
  description = "Map of \"plan/selection\" => backup selection ID."
  value       = { for k, s in aws_backup_selection.this : k => s.id }
}
