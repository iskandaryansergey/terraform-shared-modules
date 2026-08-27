# R10: reviewability is a security property.
#
# The sibling module marked its rendered config sensitive - correctly, because it
# embedded caller secrets - and thereby made the highest-value review in the
# module impossible to do in a plan diff, while the README still advertised it.
#
# Here the rendered configs contain NO secret: the runner token is a placeholder
# substituted at container start from Secrets Manager, and there is no free-text
# input that could carry a credential. So both configs are non-sensitive and
# reviewable in a plan diff, on purpose. That property is asserted in the test
# suite so a future change cannot quietly reintroduce a secret into them.

output "cluster_name" {
  description = "ECS cluster holding the manager service and every job task."
  value       = local.create ? aws_ecs_cluster.this[0].name : ""
}

output "cluster_arn" {
  description = "ECS cluster ARN - the boundary the manager's ecs:RunTask permission is conditioned on."
  value       = local.create ? aws_ecs_cluster.this[0].arn : ""
}

output "manager_service_name" {
  description = "ECS service running the manager. Redeploy this to pick up a rotated runner token."
  value       = local.create ? aws_ecs_service.manager[0].name : ""
}

output "manager_role_arn" {
  description = "The fleet's only privileged identity: it holds ecs:RunTask and iam:PassRole for the job roles."
  value       = local.create ? aws_iam_role.manager[0].arn : ""
}

output "manager_policy_statements" {
  description = <<-EOT
    The manager's authorization model as reviewable data. Worth eyeballing in a
    plan diff: the RunTask resource list and the PassRole resource list are the
    fleet's entire containment boundary against a redirected task definition.

    Emitted from the same local the policy is built from, so this is the real
    authorization model rather than a summary of it.
  EOT
  value       = local.manager_statements
}

output "job_task_definition_arns" {
  description = <<-EOT
    Task definition ARNs by profile. This map is exactly what a pipeline may select
    with the FARGATE_TASK_DEFINITION CI/CD variable, and exactly what the manager's
    ecs:RunTask permission allows. Anything not here cannot be launched.
  EOT
  value       = local.create ? { for k, td in aws_ecs_task_definition.job : k => td.arn } : {}
}

output "job_security_group_id" {
  description = "Job task security group. Its only inbound rule is TCP 22 from the manager SG - the control that compensates for the driver not verifying SSH host keys."
  value       = local.create ? aws_security_group.job[0].id : ""
}

output "manager_security_group_id" {
  description = "Manager security group. No inbound rules at all."
  value       = local.create ? aws_security_group.manager[0].id : ""
}

output "config_toml" {
  description = "The rendered gitlab-runner config.toml. Contains no secret (the token is a placeholder), so review it in a plan diff."
  value       = local.config_toml
}

output "fargate_toml" {
  description = "The rendered Fargate driver config. Contains no secret, so review it in a plan diff."
  value       = local.fargate_toml
}

output "job_egress_cidrs_effective" {
  description = "The CIDRs job tasks may actually reach on 443, after the private-space carve-out. Compare against your internal ranges."
  value       = local.job_egress
}

output "job_egress_rule_count" {
  description = "Egress rules on the job security group. The default quota is 60; the precondition on the manager service refuses to plan above it."
  value       = local.job_egress_rule_count
}

output "log_group_name" {
  description = "CloudWatch log group carrying both manager and job task streams."
  value       = local.log_group_name
}

output "max_concurrent_jobs" {
  description = "Ceiling on simultaneous jobs, and therefore on peak Fargate task count. The account's Fargate vCPU quota is often the lower real ceiling."
  value       = var.manager_concurrent
}

output "verify_commands" {
  description = "Paste-ready checks for the things that go wrong on this platform."
  value = local.create ? {
    manager_running = "aws ecs describe-services --cluster ${local.cluster_name} --services ${aws_ecs_service.manager[0].name} --query 'services[0].{desired:desiredCount,running:runningCount,deployments:deployments[*].rolloutState}'"
    manager_logs    = "aws logs tail ${local.log_group_name} --log-stream-name-prefix manager --follow"
    stopped_reasons = "aws ecs list-tasks --cluster ${local.cluster_name} --desired-status STOPPED --query 'taskArns[:5]' --output text | xargs -r aws ecs describe-tasks --cluster ${local.cluster_name} --tasks --query 'tasks[*].{stopCode:stopCode,reason:stoppedReason,containers:containers[*].reason}'"
    # The quota that actually caps the fleet, and the one nobody checks.
    vcpu_quota = "aws service-quotas get-service-quota --service-code fargate --quota-code L-3032A538 --query 'Quota.Value'"
    # Confirms the region reached the process - the failure mode where every
    # signal stays green and no task ever launches.
    manager_env = "aws ecs describe-task-definition --task-definition ${aws_ecs_task_definition.manager[0].family} --query 'taskDefinition.containerDefinitions[0].{env:environment[?starts_with(name,`AWS_`)],secrets:secrets[*].name}'"

    # ORPHANS. The manager is the only thing that calls StopTask, and it is a
    # singleton designed to be replaced - so a job task whose manager died keeps
    # sshd alive with no client and bills until someone stops it. Fargate has no
    # task-level TTL, so this is detection, not prevention. Run it after any
    # manager redeploy that happened while jobs were in flight.
    orphans = "aws ecs list-tasks --cluster ${local.cluster_name} --desired-status RUNNING --query 'taskArns' --output text | tr '\\t' '\\n' | xargs -r -n50 aws ecs describe-tasks --cluster ${local.cluster_name} --tasks --query \"tasks[?group!='service:${aws_ecs_service.manager[0].name}'].{arn:taskArn,started:startedAt,group:group}\""

    stop_orphan = "aws ecs stop-task --cluster ${local.cluster_name} --reason 'orphaned: manager lost' --task <TASK_ARN>"

    # Confirms the metrics listener the manager health check depends on is really
    # configured. If this is empty the fleet cannot pass its own health check.
    listener = "echo ${local.metrics_listen_address}"
  } : {}
}

output "required_vpc_endpoints" {
  description = <<-EOT
    The endpoint services this fleet needs reachable. Provided as data because in
    a managed estate the endpoints belong to the landing zone, not to this module -
    hand this list to whoever owns the VPC.

    A missing endpoint is a SILENT HANG, not an error: the ECS agent falls back to
    the public DNS name and, with no internet path, waits. There is no diagnostic
    that names the missing endpoint.
  EOT
  value = {
    interface = local.interface_endpoint_services
    gateway   = ["s3"]
    note      = "Interface endpoints require private DNS enabled, or the ECS agent resolves the public name and never reaches them."
  }
}

output "isolated" {
  description = "Whether this fleet is declared to have no internet path."
  value       = var.isolated
}
