output "worker_asg_name" {
  description = "The ASG the runner manager scales."
  value       = module.runners.worker_asg_name
}

output "max_concurrent_jobs" {
  description = "Ceiling on simultaneous jobs - the number that caps your spend."
  value       = module.runners.max_concurrent_jobs
}

output "worker_role_arn" {
  description = "What jobs run as. Review anything you attach to this: it is the blast radius of a compromised pipeline."
  value       = module.runners.worker_role_arn
}

output "manager_role_arn" {
  description = "The fleet's only privileged identity."
  value       = module.runners.manager_role_arn
}

output "kms_key_arn" {
  description = "CMK protecting the runner token and every fleet volume."
  value       = aws_kms_key.runners.arn
}

output "manager_policy_statements" {
  description = "The manager's authorization model as data - worth eyeballing in a plan diff."
  value       = module.runners.manager_policy_statements
}

# NOTE: config_toml and manager_user_data_preview are deliberately NOT re-exported
# here. They embed runner_environment and extra_runner_config_toml verbatim, so
# re-exporting would widen the audience for anything secret-shaped in those. Read
# them from the module directly when you need to review them:
#   terraform output -raw config_toml
output "verify_commands" {
  description = "Paste-ready checks for manager health, bootstrap log, and fleet capacity."
  value       = module.runners.verify_commands
}

output "recommended_s3_endpoint_policy" {
  description = <<-EOT
    Suggested policy for the S3 GATEWAY endpoint serving these subnets. The module
    no longer creates endpoints, so this is guidance for whoever does.

    An endpoint policy is default-deny: anything omitted here silently stops
    working from these subnets. The AL2023 repo bucket is region-specific.
  EOT
  value       = var.cache_bucket == "" ? null : data.aws_iam_policy_document.s3_endpoint[0].json
}

output "network_contract" {
  description = "What the fleet requires from your VPC. Hand this to the network team - a missing endpoint hangs rather than errors."
  value       = module.runners.network_contract
}
