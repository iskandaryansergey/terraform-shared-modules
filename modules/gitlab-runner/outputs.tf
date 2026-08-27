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

# Paste-ready checks for the things that actually go wrong.
output "verify_commands" {
  description = "Copy-paste checks: is the manager healthy, did the runner come online, is the fleet scaling."
  value = local.create ? {
    manager_logs   = "aws ssm start-session --target <manager-instance-id> --document-name AWS-StartInteractiveCommand --parameters command='sudo journalctl -u gitlab-runner -n 100 --no-pager'"
    bootstrap_log  = "aws ssm start-session --target <manager-instance-id> --document-name AWS-StartInteractiveCommand --parameters command='sudo cat /var/log/runner-bootstrap.log'"
    fleet_capacity = "aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${local.worker_asg_name} --query 'AutoScalingGroups[0].[DesiredCapacity,Instances[*].InstanceId]'"
    find_manager   = "aws ec2 describe-instances --filters Name=tag:Name,Values=${var.name}-manager Name=instance-state-name,Values=running --query 'Reservations[*].Instances[*].InstanceId' --output text"
  } : null
}

# Rendered from module inputs. The token is fetched from SSM at boot, so it
# appears in neither.

output "manager_user_data_preview" {
  description = "The rendered manager bootstrap script - the code that runs as root on the machine that controls your fleet. Sensitive because it embeds the rendered config; read it deliberately with `terraform output -raw manager_user_data_preview`."
  value       = local.manager_user_data
  sensitive   = true
}

output "manager_policy_statements" {
  description = "The manager's authorization model as data (sid/actions/resources/conditions) - what the fleet's only privileged role can actually do."
  value       = local.create ? local.manager_statements : null
}

output "network_contract" {
  description = <<-EOT
    What the fleet requires from YOUR network, as data rather than prose - hand it
    to whoever owns the VPC.

    This module creates no network resources, so nothing here is enforced except
    the manager-to-worker SSH rule, which is verified at plan time. Everything else
    is a prerequisite: a missing endpoint or egress rule fails as a hang, not as an
    error, because there is no public-internet path to fall back on.
  EOT
  value = {
    manager_security_group_ids = var.manager_security_group_ids
    worker_security_group_ids  = var.worker_security_group_ids

    required_egress = {
      manager = [
        "443 -> your GitLab (Direct Connect / VPN / peered VPC)",
        "443 -> VPC endpoints for: ec2, autoscaling, ssm, ssmmessages, ec2messages, ec2-instance-connect, logs, monitoring",
        "443 -> S3 gateway endpoint (package repos when not using a baked AMI)",
        "22  -> worker security group (VERIFIED by this module)",
        "53  -> your DNS resolver (UDP and TCP)",
      ]
      worker = [
        "443 -> your GitLab (git clone, artifact upload)",
        "443 -> your container registry and package mirrors",
        "443 -> VPC endpoints for: ssm, ssmmessages, ec2messages",
        "443 -> S3 gateway endpoint",
        "53  -> your DNS resolver (UDP and TCP)",
      ]
    }

    required_ingress = {
      manager = ["none - operator access is via SSM Session Manager, outbound-initiated"]
      worker  = ["22 from the manager security group ONLY - never a CIDR"]
    }

    required_vpc_endpoints = {
      interface = [
        "ec2", "autoscaling", "ssm", "ssmmessages", "ec2messages",
        "ec2-instance-connect", "logs", "monitoring",
      ]
      gateway = ["s3"]
      note    = "Interface endpoints need private DNS enabled, or the instances resolve the public name and - with no internet path - hang instead of erroring."
    }

    ssh_rule_verified = var.verify_manager_to_worker_ssh_rule
  }
}
