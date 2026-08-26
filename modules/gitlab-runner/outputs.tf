output "worker_asg_name" {
  description = "Name of the worker ASG (this is what the runner's fleeting plugin scales)."
  value       = one(aws_autoscaling_group.workers[*].name)
}

output "worker_asg_arn" {
  description = "ARN of the worker ASG."
  value       = one(aws_autoscaling_group.workers[*].arn)
}

output "manager_role_arn" {
  description = "IAM role the manager runs as (holds the fleet-control permissions)."
  value       = one(aws_iam_role.manager[*].arn)
}

output "worker_role_arn" {
  description = "IAM role jobs run as - attach job permissions here via additional_worker_policy_arns."
  value       = one(aws_iam_role.worker[*].arn)
}

output "worker_role_name" {
  description = "Name of the worker role, for attaching extra policies externally."
  value       = one(aws_iam_role.worker[*].name)
}

output "manager_security_group_id" {
  description = "Manager security group (no inbound rules)."
  value       = one(aws_security_group.manager[*].id)
}

output "worker_security_group_id" {
  description = "Worker security group (inbound: SSH from the manager only)."
  value       = one(aws_security_group.worker[*].id)
}

output "token_ssm_parameter" {
  description = "SSM parameter the manager reads the runner token from."
  value       = local.create ? local.token_ssm_parameter : null
}

output "max_concurrent_jobs" {
  description = "Ceiling on jobs this fleet can run at once (max_instances x capacity_per_instance) - the number that caps your spend."
  value       = local.concurrent
}

output "config_toml" {
  description = "The rendered config.toml, with the token left as a placeholder. Rendered even when create = false: it's a pure function of the inputs, which lets CI parse and assert on it with no AWS credentials. Sensitive because it embeds runner_environment and extra_runner_config_toml verbatim - use `terraform output -raw config_toml` to read it deliberately."
  value       = local.config_toml
  sensitive   = true
}

# Sanity-check the whole path in one command instead of guessing.
output "verify_commands" {
  description = "Copy-paste checks: is the manager healthy, did the runner come online, is the fleet scaling."
  value = local.create ? {
    manager_logs   = "aws ssm start-session --target <manager-instance-id> --document-name AWS-StartInteractiveCommand --parameters command='sudo journalctl -u gitlab-runner -n 100 --no-pager'"
    bootstrap_log  = "aws ssm start-session --target <manager-instance-id> --document-name AWS-StartInteractiveCommand --parameters command='sudo cat /var/log/runner-bootstrap.log'"
    fleet_capacity = "aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${local.worker_asg_name} --query 'AutoScalingGroups[0].[DesiredCapacity,Instances[*].InstanceId]'"
    find_manager   = "aws ec2 describe-instances --filters Name=tag:Name,Values=${var.name}-manager Name=instance-state-name,Values=running --query 'Reservations[*].Instances[*].InstanceId' --output text"
  } : null
}

# --- audit / review surfaces -------------------------------------------------
# Both are rendered from module inputs and contain no secrets: the token is
# fetched from SSM at boot and appears in neither.

output "manager_user_data_preview" {
  description = "The rendered manager bootstrap script - the code that runs as root on the machine that controls your fleet. Sensitive because it embeds the rendered config; read it deliberately with `terraform output -raw manager_user_data_preview`."
  value       = local.manager_user_data
  sensitive   = true
}

output "manager_policy_statements" {
  description = "The manager's authorization model as data (sid/actions/resources/conditions) - what the fleet's only privileged role can actually do."
  value       = local.create ? local.manager_statements : null
}
