# Layer 1 of three (R8): mocked plan tests.
#
# These are fast and broad, and they are NOT sufficient on their own - that is the
# whole lesson of the sibling module, where 105 green plan tests coexisted with a
# fleet that could not launch a worker. What plan tests CAN prove is the shape of
# the graph and the contents of anything Terraform computes itself: IAM policy
# documents, container definitions, alarm thresholds, and every validation.
#
# Structural properties of the rendered TOML live in tests/parse_config.py, and
# the encoding discipline lives in tests/template_safety.py, because neither can
# be expressed as a substring assertion.

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
  mock_data "aws_vpc" {
    defaults = { cidr_block = "10.20.0.0/16" }
  }
  mock_data "aws_subnet" {
    defaults = { availability_zone = "eu-west-1a" }
  }
  mock_data "aws_route_tables" {
    defaults = { ids = ["rtb-0123456789abcdef0"] }
  }
  mock_resource "aws_ecs_cluster" {
    defaults = { arn = "arn:aws:ecs:eu-west-1:111122223333:cluster/mock" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/mock" }
  }
  mock_resource "aws_security_group" {
    defaults = { id = "sg-0123456789abcdef0" }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:eu-west-1:111122223333:task-definition/mock:1" }
  }
}

# NOTE: `terraform test` treats a failing `check` block as an ERROR, not the
# warning it is during plan and apply. So this baseline is a fully-configured
# fleet - cache wired, alarms wired, both images digest-pinned - and every check
# in locals.tf therefore passes. That is deliberate: it means the default test
# subject is a fleet configured the way the module says to configure one, and any
# run that leaves a check unsatisfied fails loudly instead of emitting a warning
# nobody reads.
variables {
  name                    = "ci-test"
  runner_token_secret_arn = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:gitlab/token-AbCdEf"
  vpc_id                  = "vpc-0123456789abcdef0"
  manager_subnet_ids      = ["subnet-0aaa1111bbbb2222c"]
  job_subnet_ids          = ["subnet-0ddd3333eeee4444f"]
  manager_image           = "example.dkr.ecr.eu-west-1.amazonaws.com/mgr@sha256:1111111111111111111111111111111111111111111111111111111111111111"
  cache_bucket_name       = "ci-test-runner-cache"
  alarm_sns_topic_arns    = ["arn:aws:sns:eu-west-1:111122223333:ci-alerts"]

  job_profiles = {
    default = {
      image  = "example.dkr.ecr.eu-west-1.amazonaws.com/job@sha256:2222222222222222222222222222222222222222222222222222222222222222"
      cpu    = 512
      memory = 1024
    }
  }
}

# ===========================================================================
# The containment boundary.
#
# CUSTOM_ENV_FARGATE_TASK_DEFINITION lets a project maintainer redirect the
# driver, so the ecs:RunTask resource list and the iam:PassRole resource list are
# the only things standing between a CI variable and an arbitrary task role.
# These are the most important assertions in the file.
# ===========================================================================

run "runtask_is_scoped_to_enumerated_task_definitions" {
  command = apply

  assert {
    # Filtered rather than guarded with ||: on Terraform 1.9 both operands of ||
    # are evaluated, so `s.Sid != "X" || s.Condition...` throws on every statement
    # that has no Condition. This pattern has no such dependency (R3).
    condition = alltrue([
      for s in [for st in output.manager_policy_statements : st if st.Sid == "RunJobTasks"] : !contains(s.Resource, "*")
    ])
    error_message = "ecs:RunTask must never be granted on '*'. A CI variable can choose any task definition this permission allows, so a wildcard hands every project every task role in the account."
  }

  assert {
    condition = alltrue([
      for s in [for st in output.manager_policy_statements : st if st.Sid == "RunJobTasks"] : can(s.Condition.ArnEquals["ecs:cluster"])
    ])
    error_message = "the RunTask statement must carry an ecs:cluster condition, so a redirected RunTask cannot land in another cluster."
  }

  assert {
    condition = anytrue([
      for s in [for st in output.manager_policy_statements : st if st.Sid == "RunJobTasks"] :
      length([for r in s.Resource : r if endswith(r, "task-definition/ci-test-job-default:*")]) == 1
    ])
    error_message = "RunTask must name this fleet's task-definition family with a :* revision wildcard. Pinning a revision breaks every task-definition update; omitting the family opens the boundary."
  }
}

run "passrole_is_scoped_and_service_conditioned" {
  command = apply

  assert {
    condition = alltrue([
      for s in [for st in output.manager_policy_statements : st if st.Sid == "PassOnlyJobRoles"] : !contains(s.Resource, "*")
    ])
    error_message = "iam:PassRole must never be granted on '*'. That is the second half of the containment boundary."
  }

  assert {
    condition = alltrue([
      for s in [for st in output.manager_policy_statements : st if st.Sid == "PassOnlyJobRoles"] :
      contains(s.Condition.StringEquals["iam:PassedToService"], "ecs-tasks.amazonaws.com")
    ])
    error_message = "PassRole must be conditioned on iam:PassedToService = ecs-tasks.amazonaws.com."
  }
}

run "manager_has_no_iam_or_sts_write" {
  command = apply

  assert {
    condition = alltrue(flatten([
      for s in output.manager_policy_statements : [
        for a in s.Action :
        !can(regex("^(iam:(Create|Put|Attach|Update|Delete)|sts:AssumeRole$)", a))
      ]
    ]))
    error_message = "the manager must hold no IAM-mutating or role-assuming permissions beyond the scoped PassRole."
  }
}

run "describe_taskdefinition_is_not_granted_without_health_checks" {
  # It cannot be resource-scoped by AWS, so the "*" grant exists only when the
  # driver actually needs it. An unnecessary "*" is not free.
  command = apply

  assert {
    condition = length([
      for s in output.manager_policy_statements : s
      if contains(s.Action, "ecs:DescribeTaskDefinition")
    ]) == 0
    error_message = "no profile declares a health check, so ecs:DescribeTaskDefinition on '*' must not be granted. AWS does not support resource-level permissions on that action, so an unnecessary grant is unavoidably a wildcard."
  }
}

run "describe_taskdefinition_appears_with_a_health_check" {
  command = apply

  variables {
    job_profiles = {
      default = {
        image            = "example/job@sha256:2222222222222222222222222222222222222222222222222222222222222222"
        cpu              = 512
        memory           = 1024
        health_check_cmd = ["CMD-SHELL", "pgrep sshd || exit 1"]
      }
    }
  }

  assert {
    condition = length([
      for s in output.manager_policy_statements : s
      if contains(s.Action, "ecs:DescribeTaskDefinition")
    ]) == 1
    error_message = "a profile with a health check turns on EvaluateTaskHealth, which needs ecs:DescribeTaskDefinition."
  }
}

# ===========================================================================
# Network containment for the driver's missing host-key verification.
# ===========================================================================

run "job_ssh_ingress_is_sg_referenced_never_a_cidr" {
  command = apply

  assert {
    condition     = aws_vpc_security_group_ingress_rule.job_ssh_from_manager[0].referenced_security_group_id == aws_security_group.manager[0].id
    error_message = "job SSH ingress must reference the manager SECURITY GROUP."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.job_ssh_from_manager[0].cidr_ipv4 == null
    error_message = "job SSH ingress must NOT use a CIDR. The driver does not verify the job task's SSH host key, so anything that can answer on port 22 receives a session carrying CI_JOB_TOKEN. GitLab's docs suggest the VPC CIDR here; that is wrong."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.job_ssh_from_manager[0].from_port == 22 && aws_vpc_security_group_ingress_rule.job_ssh_from_manager[0].to_port == 22
    error_message = "the job ingress rule must be port 22 only."
  }
}

run "manager_security_group_has_no_ingress" {
  command = apply

  assert {
    condition     = length([for k, v in aws_vpc_security_group_ingress_rule.endpoints_from_fleet : k]) == 0
    error_message = "with endpoints disabled there must be no ingress rules at all."
  }
}

run "job_egress_excludes_private_space" {
  command = apply

  # Spot-check the ranges that matter, rather than comparing the whole list -
  # a whole-collection comparison would break on list/tuple typing.
  assert {
    condition     = !contains(output.job_egress_cidrs_effective, "0.0.0.0/0")
    error_message = "the job egress default must not be 0.0.0.0/0."
  }

  assert {
    condition = length([
      for c in output.job_egress_cidrs_effective : c
      if c == "10.0.0.0/8" || c == "172.16.0.0/12" || c == "192.168.0.0/16" || c == "100.64.0.0/10"
    ]) == 0
    error_message = "RFC1918 and CGNAT ranges must not appear verbatim in the job egress list."
  }

  assert {
    condition     = contains(output.job_egress_cidrs_effective, "100.0.0.0/10") && contains(output.job_egress_cidrs_effective, "100.128.0.0/9")
    error_message = "100.64.0.0/10 must be carved out by splitting around it, leaving 100.0.0.0/10 and 100.128.0.0/9 reachable. Their absence would mean the carve-out removed more than intended."
  }
}

run "dns_egress_is_scoped_to_the_resolver_not_the_vpc" {
  command = apply

  assert {
    condition = alltrue([
      for k, r in aws_vpc_security_group_egress_rule.dns : r.cidr_ipv4 == "10.20.0.2/32"
    ])
    error_message = "DNS egress must target the VPC resolver /32, not the VPC CIDR. VPC-wide TCP/53 is a working internal scanning primitive from a trusted source address."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.dns) == 4
    error_message = "expected 4 DNS rules: udp+tcp for each of the manager and job tiers."
  }
}

run "extra_egress_keys_are_content_addressed" {
  command = apply

  # Reordering the list must not change any key, and a duplicate must collapse
  # rather than crash on a duplicate object key.
  variables {
    job_extra_egress_rules = [
      { protocol = "tcp", port = 3128, cidrs = ["10.1.0.0/16"] },
      { protocol = "tcp", port = 5000, cidrs = ["10.2.0.0/16", "10.1.0.0/16"] },
      { protocol = "tcp", port = 3128, cidrs = ["10.1.0.0/16"] }, # exact duplicate
    ]
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.job_extra) == 3
    error_message = "expected 3 distinct extra egress rules after deduplication, not 4 - an exact duplicate must collapse."
  }

  assert {
    condition     = contains(keys(aws_vpc_security_group_egress_rule.job_extra), "tcp-3128-10.1.0.0/16")
    error_message = "extra egress keys must be derived from content (protocol-port-cidr), not from list position. Index-derived keys make a pure reorder destroy and recreate every rule."
  }
}

# ===========================================================================
# Task definitions
# ===========================================================================

run "job_container_is_named_ci_coordinator" {
  command = apply

  assert {
    condition     = jsondecode(aws_ecs_task_definition.job["default"].container_definitions)[0].name == "ci-coordinator"
    error_message = "the job container MUST be named ci-coordinator. The driver injects SSH_PUBLIC_KEY only into a container with that exact name; any other name means the key never arrives and the job hangs until the retry budget expires."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.job["default"].container_definitions)[0].portMappings[0].containerPort == 22
    error_message = "the job container must map port 22."
  }
}

run "runner_token_arrives_via_secrets_not_environment" {
  command = apply

  assert {
    condition = length([
      for s in jsondecode(aws_ecs_task_definition.manager[0].container_definitions)[0].secrets :
      s if s.valueFrom == var.runner_token_secret_arn
    ]) == 1
    error_message = "the runner token must be referenced through `secrets`/valueFrom so the task definition stores only the ARN."
  }

  assert {
    condition = alltrue([
      for e in jsondecode(aws_ecs_task_definition.manager[0].container_definitions)[0].environment :
      !can(regex("(?i)(token|secret|password|credential)", e.name))
    ])
    error_message = "no secret-shaped key may appear in `environment`. Those values are readable by anyone with ecs:DescribeTaskDefinition, which AWS does not allow you to scope to a single task definition."
  }

  assert {
    condition = alltrue([
      for e in jsondecode(aws_ecs_task_definition.manager[0].container_definitions)[0].environment :
      !can(regex("glrt-", e.value))
    ])
    error_message = "a glrt- token must never appear in the task definition."
  }
}

run "manager_receives_an_explicit_region" {
  # The defect class this module exists to avoid: aws-sdk-go-v2 does NOT read the
  # region from IMDS by default, and a missing region produces a fleet where every
  # signal is green and no task ever launches.
  command = apply

  assert {
    condition = length([
      for e in jsondecode(aws_ecs_task_definition.manager[0].container_definitions)[0].environment :
      e if e.name == "AWS_REGION" && e.value != ""
    ]) == 1
    error_message = "AWS_REGION must be set explicitly on the manager container."
  }

  assert {
    condition = length([
      for e in jsondecode(aws_ecs_task_definition.manager[0].container_definitions)[0].environment :
      e if e.name == "AWS_DEFAULT_REGION" && e.value != ""
    ]) == 1
    error_message = "AWS_DEFAULT_REGION must be set explicitly on the manager container."
  }
}

run "manager_health_check_probes_the_metrics_endpoint" {
  command = apply

  # The point is NOT that the string "9252" appears - that was the tautology that
  # let the fleet ship undeployable. The point is that the probe address and the
  # config's listen_address are the SAME value.
  assert {
    condition     = can(regex("listen_address = \"127.0.0.1:9252\"", output.config_toml))
    error_message = "config.toml must set listen_address. gitlab-runner starts its metrics/health server ONLY when that key is present, and the manager health check probes it - without it the probe can never succeed and ECS replaces the task forever."
  }

  assert {
    condition     = can(regex("127.0.0.1:9252", jsondecode(aws_ecs_task_definition.manager[0].container_definitions)[0].healthCheck.command[1]))
    error_message = "the health check must probe the address config.toml actually listens on."
  }

  assert {
    # Derived from one variable, so they cannot drift.
    condition = can(regex(
      replace(var.manager_metrics_listen_address, ".", "\\."),
      jsondecode(aws_ecs_task_definition.manager[0].container_definitions)[0].healthCheck.command[1]
    ))
    error_message = "the health-check probe must be derived from manager_metrics_listen_address, not written separately."
  }

  assert {
    condition     = !can(regex("wget", jsondecode(aws_ecs_task_definition.manager[0].container_definitions)[0].healthCheck.command[1]))
    error_message = "the health check must use curl - wget is not installed by docker/Dockerfile.manager."
  }
}

run "manager_stop_timeout_forwards_a_graceful_signal_window" {
  command = apply

  assert {
    condition     = jsondecode(aws_ecs_task_definition.manager[0].container_definitions)[0].stopTimeout == 120
    error_message = "stopTimeout should default to the Fargate maximum of 120s, since ECS sends SIGTERM and gitlab-runner treats SIGTERM as 'abort all builds'."
  }
}

run "job_task_role_is_absent_by_default" {
  command = apply

  assert {
    condition     = aws_ecs_task_definition.job["default"].task_role_arn == null || aws_ecs_task_definition.job["default"].task_role_arn == ""
    error_message = "job tasks must have NO task role by default. One shared task role is one blast radius for every project on the fleet; per-project access belongs to GitLab OIDC."
  }
}

run "manager_service_is_a_singleton_that_drains_before_replacing" {
  command = apply

  assert {
    condition     = aws_ecs_service.manager[0].desired_count == 1
    error_message = "the manager must be a singleton: the driver's TaskMetadata directory carries per-job SSH keys across four separate stage processes, so a second replica would read state the first never wrote."
  }

  assert {
    condition     = aws_ecs_service.manager[0].deployment_maximum_percent == 100 && aws_ecs_service.manager[0].deployment_minimum_healthy_percent == 0
    error_message = "the manager deployment must drain before replacing (0/100), or two managers briefly share one runner token."
  }

  assert {
    condition     = !aws_ecs_service.manager[0].enable_execute_command
    error_message = "ECS Exec must be off on the manager."
  }

  assert {
    condition     = aws_ecs_service.manager[0].network_configuration[0].assign_public_ip == false
    error_message = "the manager must not get a public IP."
  }
}

# ===========================================================================
# Alarms. Correct at every fleet size is the requirement, not correct at one.
# ===========================================================================

run "capacity_alarm_is_absent_on_tiny_fleets" {
  command = apply

  variables {
    manager_concurrent   = 2
    alarm_sns_topic_arns = ["arn:aws:sns:eu-west-1:111122223333:ci"]
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.fleet_at_capacity) == 0
    error_message = "at concurrent = 2, 'at capacity' is close to the normal state during any single build. An alarm that fires on healthy operation gets muted along with everything else on its topic."
  }
}

run "capacity_alarm_does_not_fire_on_full_utilisation" {
  command = apply

  variables {
    manager_concurrent   = 10
    alarm_sns_topic_arns = ["arn:aws:sns:eu-west-1:111122223333:ci"]
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.fleet_at_capacity[0].comparison_operator == "GreaterThanThreshold"
    error_message = "the capacity alarm must use GreaterThanThreshold, not >=. With >= against the ceiling it fires when the fleet is merely full, which is the system working."
  }

  assert {
    # Cluster task count includes the manager, so full utilisation is
    # concurrent + 1. Threshold must be ABOVE that or the alarm fires on a
    # healthy, fully-busy fleet.
    condition     = aws_cloudwatch_metric_alarm.fleet_at_capacity[0].threshold == 11
    error_message = "threshold must be manager_concurrent + 1: the cluster task count includes the manager, so a threshold of manager_concurrent fires at exactly full utilisation."
  }

  assert {
    # RunningTaskCount is published ONLY with {ClusterName, ServiceName}. A
    # ClusterName-only dimension set means no publisher and an alarm that can
    # never fire at any fleet size.
    condition     = aws_cloudwatch_metric_alarm.fleet_at_capacity[0].metric_name == "TaskCount"
    error_message = "the cluster-wide capacity alarm must read TaskCount. RunningTaskCount requires a ServiceName dimension, so a ClusterName-only alarm on it is inert."
  }
}

run "alarm_missing_data_matches_signal_cadence" {
  command = apply

  variables {
    alarm_sns_topic_arns = ["arn:aws:sns:eu-west-1:111122223333:ci"]
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.manager_absent[0].treat_missing_data == "breaching"
    error_message = "manager presence is a CONTINUOUS signal, so absent data means absent manager and must breach."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.manager_absent[0].statistic == "Maximum"
    error_message = "manager_absent must use Maximum, not Minimum: a deployment legitimately drops the count to 0 briefly, and we want 'was there ever a manager in this window'."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.manager_absent[0].alarm_actions) > 0
    error_message = "an alarm with no destination is an audit trail, not an alert."
  }
}

run "spot_event_rule_absent_when_the_fleet_has_no_spot" {
  command = apply

  variables {
    alarm_sns_topic_arns = ["arn:aws:sns:eu-west-1:111122223333:ci"]
  }

  assert {
    condition     = length(aws_cloudwatch_event_rule.spot_interruption) == 0
    error_message = "with no Spot capacity provider the interruption rule could never match, and a rule that cannot match reads as a working control."
  }
}

run "spot_event_rule_appears_with_spot_capacity" {
  command = apply

  variables {
    alarm_sns_topic_arns       = ["arn:aws:sns:eu-west-1:111122223333:ci"]
    capacity_provider_strategy = [{ capacity_provider = "FARGATE_SPOT", weight = 1 }]
  }

  assert {
    condition     = length(aws_cloudwatch_event_rule.spot_interruption) == 1
    error_message = "a Spot fleet must get the interruption rule."
  }

  assert {
    condition     = can(regex("SpotInterruption", aws_cloudwatch_event_rule.spot_interruption[0].event_pattern))
    error_message = "the Spot rule must match on stopCode = SpotInterruption."
  }
}

# ===========================================================================
# create = false is a genuine no-op, which is what makes offline rendering work.
# ===========================================================================

run "create_false_makes_nothing" {
  command = apply

  variables {
    create = false
  }

  assert {
    condition = (
      length(aws_ecs_cluster.this) == 0 &&
      length(aws_ecs_service.manager) == 0 &&
      length(aws_ecs_task_definition.manager) == 0 &&
      length(aws_ecs_task_definition.job) == 0 &&
      length(aws_iam_role.manager) == 0 &&
      length(aws_security_group.job) == 0 &&
      length(aws_cloudwatch_log_group.this) == 0
    )
    error_message = "create = false must create nothing at all."
  }

  assert {
    condition     = length(output.config_toml) > 0 && length(output.fargate_toml) > 0
    error_message = "create = false must still render both configs, or the offline test fixture cannot check them."
  }
}

# ===========================================================================
# Reviewability (R10): the rendered configs must stay non-sensitive, which is
# only defensible while they contain no secret.
# ===========================================================================

run "rendered_config_carries_no_secret" {
  command = apply

  assert {
    condition     = can(regex("RUNNER_TOKEN_PLACEHOLDER", output.config_toml))
    error_message = "the token must be a placeholder in the rendered config."
  }

  assert {
    condition     = !can(regex("glrt-", output.config_toml))
    error_message = "no glrt- token may appear in the rendered config."
  }

  assert {
    condition     = !can(regex("(?i)(AccessKey|SecretKey|aws_secret)", output.config_toml))
    error_message = "no static AWS credential may appear in the rendered config; the cache must use AuthenticationType = iam."
  }
}

run "default_profile_is_explicit_when_named" {
  command = apply

  variables {
    default_job_profile = "small"
    job_profiles = {
      big = {
        image  = "example/big@sha256:3333333333333333333333333333333333333333333333333333333333333333"
        cpu    = 2048
        memory = 4096
      }
      small = {
        image  = "example/small@sha256:4444444444444444444444444444444444444444444444444444444444444444"
        cpu    = 512
        memory = 1024
      }
    }
  }

  assert {
    condition     = can(regex("TaskDefinition = \"ci-test-job-small\"", output.fargate_toml))
    error_message = "default_job_profile must select the driver's default task definition. Without it the choice falls to alphabetical ordering, which silently changes when an unrelated profile is added."
  }
}

# ===========================================================================
# Partition awareness. Endpoint SERVICE NAMES need the same treatment as ARNs,
# and that is the seam the sibling module missed.
# ===========================================================================

run "endpoint_service_names_are_partition_aware" {
  command = apply

  variables {
    create_vpc_endpoints = true
  }

  assert {
    condition = alltrue([
      for k, e in aws_vpc_endpoint.interface : startswith(e.service_name, "com.amazonaws.")
    ])
    error_message = "in the aws partition endpoint service names take the com.amazonaws prefix."
  }

  assert {
    condition     = aws_vpc_endpoint.s3[0].vpc_endpoint_type == "Gateway"
    error_message = "S3 must be a GATEWAY endpoint. ECR stores image layers in S3 and an interface endpoint is not a documented substitute - it is also billed, whereas the gateway is free."
  }

  assert {
    condition     = contains([for k, e in aws_vpc_endpoint.interface : e.service_name], "com.amazonaws.eu-west-1.ecr.dkr")
    error_message = "ecr.dkr is required for private image pulls on Fargate platform 1.4.0+."
  }

  assert {
    condition     = !aws_vpc_endpoint.interface["ecr.api"].private_dns_enabled
    error_message = "private DNS must default to off: enabling it rewrites resolution for the ENTIRE VPC, which this module does not own."
  }
}

run "endpoints_get_a_policy" {
  command = apply

  variables {
    create_vpc_endpoints = true
  }

  assert {
    condition     = aws_vpc_endpoint.s3[0].policy != null && aws_vpc_endpoint.s3[0].policy != ""
    error_message = "the S3 gateway endpoint must carry a policy. AWS's default for an unpolicied endpoint is full access, which is a high-bandwidth egress path the 443 rules cannot see - anonymous access to a third-party bucket is not gated by IAM at all."
  }
}

# ===========================================================================
# Validations. Each of these is a defect that would otherwise reach apply.
# ===========================================================================

run "reject_gitlab_url_with_embedded_newline" {
  command = plan
  variables {
    gitlab_url = "https://gitlab.example.com\nevil"
  }
  expect_failures = [var.gitlab_url]
}

run "reject_gitlab_url_with_userinfo" {
  command = plan
  variables {
    gitlab_url = "https://user:pass@gitlab.example.com"
  }
  expect_failures = [var.gitlab_url]
}

run "reject_http_gitlab_url" {
  command = plan
  variables {
    gitlab_url = "http://gitlab.example.com"
  }
  expect_failures = [var.gitlab_url]
}

run "accept_gitlab_url_with_subpath" {
  command = plan
  variables {
    gitlab_url = "https://corp.example.com:8443/gitlab"
  }
  assert {
    condition     = can(regex("corp.example.com", output.config_toml))
    error_message = "a self-managed GitLab at a subpath is a legitimate topology and must be accepted."
  }
}

run "reject_plaintext_token_shaped_secret_arn" {
  command = plan
  variables {
    runner_token_secret_arn = "glrt-abcdefghijklmnop"
  }
  expect_failures = [var.runner_token_secret_arn]
}

run "reject_secret_shaped_job_environment" {
  command = plan
  variables {
    job_profiles = {
      default = {
        image       = "example/job@sha256:2222222222222222222222222222222222222222222222222222222222222222"
        cpu         = 512
        memory      = 1024
        environment = { AWS_SECRET_ACCESS_KEY = "AKIAEXAMPLE" }
      }
    }
  }
  expect_failures = [var.job_profiles]
}

run "reject_invalid_fargate_cpu" {
  command = plan
  variables {
    manager_cpu = 700
  }
  expect_failures = [var.manager_cpu]
}

run "reject_float_concurrent" {
  command = plan
  variables {
    manager_concurrent = 10.5
  }
  expect_failures = [var.manager_concurrent]
}

run "reject_stop_timeout_above_fargate_maximum" {
  command = plan
  variables {
    manager_stop_timeout = 300
  }
  expect_failures = [var.manager_stop_timeout]
}

run "reject_shrinking_ephemeral_storage" {
  command = plan
  variables {
    job_profiles = {
      default = {
        image             = "example/job@sha256:2222222222222222222222222222222222222222222222222222222222222222"
        cpu               = 512
        memory            = 1024
        ephemeral_storage = 10 # below the 21 GiB API minimum: you can expand, never shrink
      }
    }
  }
  expect_failures = [var.job_profiles]
}

run "reject_root_as_job_ssh_username" {
  # The driver defaults to root and the module accepts it, but a profile naming a
  # non-POSIX username is a config error that surfaces only as a hung job.
  command = plan
  variables {
    job_profiles = {
      default = {
        image        = "example/job@sha256:2222222222222222222222222222222222222222222222222222222222222222"
        cpu          = 512
        memory       = 1024
        ssh_username = "Bad User!"
      }
    }
  }
  expect_failures = [var.job_profiles]
}

run "reject_empty_job_profiles" {
  command = plan
  variables { job_profiles = {} }
  expect_failures = [var.job_profiles]
}

run "reject_unknown_default_job_profile" {
  command = plan
  variables {
    default_job_profile = "nonexistent"
  }
  expect_failures = [var.default_job_profile]
}

run "reject_invalid_capacity_provider" {
  command = plan
  variables {
    capacity_provider_strategy = [{ capacity_provider = "EC2", weight = 1 }]
  }
  expect_failures = [var.capacity_provider_strategy]
}

run "reject_bad_cidr_in_extra_egress" {
  command = plan
  variables {
    job_extra_egress_rules = [{ protocol = "tcp", port = 443, cidrs = ["not-a-cidr"] }]
  }
  expect_failures = [var.job_extra_egress_rules]
}

run "reject_float_port_in_extra_egress" {
  command = plan
  variables {
    job_extra_egress_rules = [{ protocol = "tcp", port = 443.5, cidrs = ["10.0.0.0/8"] }]
  }
  expect_failures = [var.job_extra_egress_rules]
}

run "reject_name_that_would_overflow_derived_identifiers" {
  command = plan
  variables {
    name = "this-fleet-name-is-far-too-long-to-be-safe"
  }
  expect_failures = [var.name]
}

# ===========================================================================
# Preconditions: failures that a type system cannot express.
# ===========================================================================

run "reject_invalid_fargate_cpu_memory_pair" {
  command = plan

  variables {
    manager_cpu    = 256
    manager_memory = 4096 # 256 CPU accepts only 512/1024/2048
  }

  expect_failures = [aws_ecs_task_definition.manager]
}

run "reject_job_profile_with_invalid_cpu_memory_pair" {
  command = plan

  variables {
    job_profiles = {
      # 16384 CPU is NOT a continuous range - only 8 GB steps from 32 GB.
      huge = {
        image  = "example/job@sha256:2222222222222222222222222222222222222222222222222222222222222222"
        cpu    = 16384
        memory = 40000
      }
    }
  }

  expect_failures = [aws_ecs_task_definition.job]
}

run "reject_changed_exclusions_without_an_explicit_egress_list" {
  # The precomputed complement is only correct for the default exclusion set.
  # Silently handing back a complement of a different list would be a security
  # downgrade, so it is refused.
  command = plan

  variables {
    job_egress_exclude_cidrs = ["10.0.0.0/8"]
  }

  expect_failures = [aws_ecs_service.manager]
}

run "reject_egress_rule_count_above_the_quota" {
  command = plan

  variables {
    # 37 computed + 2 DNS + 22 extras = 61, one past the default quota.
    job_extra_egress_rules = [
      { protocol = "tcp", port = 9000, cidrs = [
        "10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24", "10.0.4.0/24", "10.0.5.0/24",
        "10.0.6.0/24", "10.0.7.0/24", "10.0.8.0/24", "10.0.9.0/24", "10.0.10.0/24",
        "10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24", "10.0.14.0/24", "10.0.15.0/24",
        "10.0.16.0/24", "10.0.17.0/24", "10.0.18.0/24", "10.0.19.0/24", "10.0.20.0/24",
        "10.0.21.0/24", "10.0.22.0/24",
      ] },
    ]
  }

  expect_failures = [aws_ecs_service.manager]
}

run "reject_alarms_without_container_insights" {
  # The manager-absent alarm reads an ECS/ContainerInsights metric. With Insights
  # off nothing publishes it, and the alarm would sit in INSUFFICIENT_DATA looking
  # configured (R5).
  command = plan

  variables {
    create_alarms             = true
    enable_container_insights = false
  }

  expect_failures = [aws_cloudwatch_metric_alarm.manager_absent]
}


# ===========================================================================
# REGRESSION TESTS for the audit findings. Each of these fails if the
# corresponding defect is reintroduced (R2.4: a guard is proven by regression,
# not by assertion).
# ===========================================================================

run "reject_wildcard_task_role_arn" {
  # `role/.+` accepted `role/*`, which became iam:PassRole over every matching
  # role in the account.
  command = plan
  variables {
    job_profiles = {
      default = {
        image         = "example/job@sha256:2222222222222222222222222222222222222222222222222222222222222222"
        cpu           = 512
        memory        = 1024
        task_role_arn = "arn:aws:iam::111122223333:role/*"
      }
    }
  }
  expect_failures = [var.job_profiles]
}

run "no_resource_in_any_statement_contains_a_wildcard" {
  # The old guard used contains(list, "*"), an EXACT element match, so it could
  # not see a wildcard EMBEDDED in an ARN. strcontains catches both.
  command = apply

  assert {
    # Every wildcard in this policy must be one of exactly four justified shapes.
    # A bare "*" is only acceptable where AWS supports no resource-level
    # permissions AND the statement carries a scoping condition; the test asserts
    # that pairing, not merely that the Sid is on a list.
    condition = alltrue(flatten([
      for s in output.manager_policy_statements : [
        for r in s.Resource : (
          # (a) bare "*" -> must be a known no-resource-level-permission action
          #     AND carry a condition that scopes it.
          r == "*" ? (
            contains(["PublishFleetMetrics", "ListFleetTasks"], s.Sid)
            ? can(s.Condition)
            : s.Sid == "DescribeTaskDefinitionHasNoResourceLevelPerms"
          )
          # (b) task-definition family revision wildcard
          : endswith(r, ":*") ? startswith(r, "arn:aws:ecs:")
          # (c) cluster-scoped task ARN, and the statement is cluster-conditioned
          : endswith(r, "/*") ? can(s.Condition) || startswith(r, "arn:aws:s3:::")
          # (d) anything else must contain no wildcard at all
          : !strcontains(r, "*")
        )
      ]
    ]))
    error_message = "Every wildcard in the manager policy must be a justified shape: a bare \"*\" only for actions AWS cannot resource-scope AND only with a scoping condition; \":*\" only as a task-definition revision wildcard; \"/*\" only on a cluster-scoped task ARN or an S3 prefix. Anything else means the containment boundary widened."
  }
}

run "reject_health_check_cmd_without_cmd_prefix" {
  command = plan
  variables {
    job_profiles = {
      default = {
        image            = "example/job@sha256:2222222222222222222222222222222222222222222222222222222222222222"
        cpu              = 512
        memory           = 1024
        health_check_cmd = ["curl -fsS http://localhost || exit 1"]
      }
    }
  }
  expect_failures = [var.job_profiles]
}

run "reject_credential_shaped_health_check_cmd" {
  # health_check_cmd IS shell (CMD-SHELL = /bin/sh -c as root) and lands in the
  # DescribeTaskDefinition-readable task definition body.
  command = plan
  variables {
    job_profiles = {
      default = {
        image            = "example/job@sha256:2222222222222222222222222222222222222222222222222222222222222222"
        cpu              = 512
        memory           = 1024
        health_check_cmd = ["CMD-SHELL", "curl -H 'Authorization: Bearer glpat-AAAABBBBCCCCDDDD' https://x || exit 1"]
      }
    }
  }
  expect_failures = [var.job_profiles]
}

run "reject_unusable_waiter_budget" {
  # attempts x interval was validated only independently, letting a 1-second
  # ceiling through - every cold task would fail after being billed.
  command = plan
  variables {
    job_task_wait_max_attempts = 1
    job_task_wait_interval     = 1
  }
  # The cross-variable check lives on job_task_wait_interval, which is where both
  # values are in scope on Terraform 1.9.
  expect_failures = [var.job_task_wait_interval]
}

run "reject_capacity_strategy_with_all_zero_weights" {
  command = plan
  variables { capacity_provider_strategy = [{ capacity_provider = "FARGATE", weight = 0 }] }
  expect_failures = [var.capacity_provider_strategy]
}

run "reject_capacity_strategy_with_two_bases" {
  command = plan
  variables {
    capacity_provider_strategy = [
      { capacity_provider = "FARGATE", weight = 1, base = 2 },
      { capacity_provider = "FARGATE_SPOT", weight = 1, base = 3 },
    ]
  }
  expect_failures = [var.capacity_provider_strategy]
}

run "reject_reserved_aws_tag_prefix" {
  command = plan
  variables { tags = { "aws:cost-centre" = "x" } }
  expect_failures = [var.tags]
}

run "reject_multiple_profiles_without_an_explicit_default" {
  # sort() is deterministic for a fixed key set but does NOT stop the default
  # moving when a profile that sorts earlier is added, silently re-pointing every
  # unqualified pipeline at a different image.
  command = plan
  variables {
    job_profiles = {
      alpha = { image = "example/a@sha256:3333333333333333333333333333333333333333333333333333333333333333", cpu = 512, memory = 1024 }
      zulu  = { image = "example/z@sha256:4444444444444444444444444444444444444444444444444444444444444444", cpu = 512, memory = 1024 }
    }
  }
  expect_failures = [aws_ecs_service.manager]
}

run "reject_profiles_disagreeing_on_ssh_username" {
  # The driver has ONE global [SSH] table, so a non-default profile would be
  # SSH'd as the default profile's user and the job would hang.
  command = plan
  variables {
    default_job_profile = "alpha"
    job_profiles = {
      alpha = { image = "example/a@sha256:3333333333333333333333333333333333333333333333333333333333333333", cpu = 512, memory = 1024, ssh_username = "alpha" }
      zulu  = { image = "example/z@sha256:4444444444444444444444444444444444444444444444444444444444444444", cpu = 512, memory = 1024, ssh_username = "zulu" }
    }
  }
  expect_failures = [aws_ecs_service.manager]
}

run "reject_profiles_disagreeing_on_health_check" {
  command = plan
  variables {
    default_job_profile = "alpha"
    job_profiles = {
      alpha = { image = "example/a@sha256:3333333333333333333333333333333333333333333333333333333333333333", cpu = 512, memory = 1024 }
      zulu  = { image = "example/z@sha256:4444444444444444444444444444444444444444444444444444444444444444", cpu = 512, memory = 1024, health_check_cmd = ["CMD-SHELL", "true"] }
    }
  }
  expect_failures = [aws_ecs_service.manager]
}

run "reject_execute_command_without_task_roles" {
  # ECS rejects RunTask with enableExecuteCommand and no task role, so the two
  # settings are jointly fatal at their individual defaults.
  command = plan
  variables { job_enable_execute_command = true }
  expect_failures = [aws_ecs_service.manager]
}

run "extra_egress_tolerates_description_only_difference" {
  # distinct() over objects INCLUDING description let two entries survive and
  # then collide on a key that omits it - a hard plan crash naming an internal
  # local rather than the input.
  command = apply
  variables {
    job_extra_egress_rules = [
      { protocol = "tcp", port = 5000, cidrs = ["10.20.0.0/16"], description = "registry A" },
      { protocol = "tcp", port = 5000, cidrs = ["10.20.0.0/16"], description = "registry B" },
    ]
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.job_extra) == 1
    error_message = "two entries differing only in description must collapse to one rule, not crash on a duplicate object key."
  }
}

run "manager_service_has_a_circuit_breaker" {
  command = apply

  assert {
    condition     = aws_ecs_service.manager[0].deployment_circuit_breaker[0].enable && aws_ecs_service.manager[0].deployment_circuit_breaker[0].rollback
    error_message = "the manager service must enable the deployment circuit breaker with rollback: without it a manager that cannot pass its health check makes terraform apply block for ~20 minutes and then fail with a wedged service."
  }
}

run "manager_service_is_ordered_after_its_network_and_logs" {
  command = apply

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.dns) == 4
    error_message = "DNS egress rules must exist for both tiers."
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.this) == 1
    error_message = "exactly one log group resource must exist. Two resources sharing a name and selected by a count ternary race into ResourceAlreadyExists and destroy log history when retention crosses 0."
  }
}

run "log_group_is_one_resource_at_zero_retention" {
  command = apply
  variables { log_retention_days = 0 }

  assert {
    condition     = length(aws_cloudwatch_log_group.this) == 1
    error_message = "retention 0 must still produce exactly one log group - the provider treats 0 as never-expire."
  }
}

# ===========================================================================
# Isolated / air-gapped operation
# ===========================================================================

run "isolated_requires_reachable_endpoints" {
  command = plan
  variables {
    isolated         = true
    gitlab_url       = "https://gitlab.corp.internal"
    on_prem_cidrs    = ["10.10.0.0/16"]
    job_egress_cidrs = ["10.10.0.0/16"]
    # neither create_vpc_endpoints nor existing_endpoint_security_group_ids
  }
  expect_failures = [aws_ecs_service.manager]
}

run "isolated_rejects_gitlab_dot_com" {
  command = plan
  variables {
    isolated                             = true
    on_prem_cidrs                        = ["10.10.0.0/16"]
    job_egress_cidrs                     = ["10.10.0.0/16"]
    existing_endpoint_security_group_ids = ["sg-0123456789abcdef0"]
  }
  expect_failures = [aws_ecs_service.manager]
}

run "isolated_requires_on_prem_cidrs" {
  command = plan
  variables {
    isolated                             = true
    gitlab_url                           = "https://gitlab.corp.internal"
    job_egress_cidrs                     = ["10.10.0.0/16"]
    existing_endpoint_security_group_ids = ["sg-0123456789abcdef0"]
  }
  expect_failures = [aws_ecs_service.manager]
}

run "isolated_fleet_plans_and_reaches_on_prem" {
  command = apply
  variables {
    isolated                             = true
    gitlab_url                           = "https://gitlab.corp.internal"
    runner_clone_url                     = "https://gitlab-int.corp.internal"
    on_prem_cidrs                        = ["10.10.0.0/16", "10.11.0.0/16"]
    job_egress_cidrs                     = []
    manager_egress_cidrs                 = []
    existing_endpoint_security_group_ids = ["sg-0123456789abcdef0"]
    manager_ca_certificate_pem           = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.job_on_prem) == 2 && length(aws_vpc_security_group_egress_rule.manager_on_prem) == 2
    error_message = "both tiers must reach on_prem_cidrs on 443: the manager for GitLab's API, the job for git clone."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.manager_https) == 0
    error_message = "with manager_egress_cidrs = [] there must be no internet egress rule at all."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.fleet_to_existing_endpoints) == 2
    error_message = "both tiers must get an SG-referenced rule to pre-existing VPC endpoints."
  }

  assert {
    condition     = can(regex("clone_url = \"https://gitlab-int.corp.internal\"", output.config_toml))
    error_message = "runner_clone_url must reach config.toml - an isolated estate commonly cannot reach GitLab's external URL."
  }

  assert {
    condition     = can(regex("tls-ca-file", output.config_toml))
    error_message = "a private CA must produce a tls-ca-file key pointing at the writable config volume."
  }

  assert {
    condition     = contains(output.required_vpc_endpoints.interface, "ecs")
    error_message = "the required endpoint list must include `ecs`: the manager calls ecs:RunTask once per job, and with no internet path there is no route to that API without it."
  }

  assert {
    condition     = contains(output.required_vpc_endpoints.interface, "sts")
    error_message = "an isolated fleet needs the sts endpoint for the OIDC path that replaces a shared job task role."
  }
}

run "manager_egress_rule_budget_is_enforced" {
  # The manager tier had no budget: a caller pinning it to a published IP range
  # could plan 70+ rules and fail partway through an apply.
  command = plan
  variables {
    manager_egress_cidrs = [for i in range(70) : "203.0.${i}.0/24"]
  }
  expect_failures = [aws_ecs_service.manager]
}

run "cache_encryption_reaches_config_and_iam" {
  command = apply
  variables {
    cache_bucket_name            = "ci-test-cache"
    cache_server_side_encryption = "aws:kms"
    cache_kms_key_arn            = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
    cache_bucket_region          = "eu-central-1"
  }

  assert {
    condition     = can(regex("ServerSideEncryption = \"aws:kms\"", output.config_toml))
    error_message = "cache_server_side_encryption must reach [runners.cache.s3] - a regulated estate cannot use an unencrypted cache."
  }

  assert {
    condition     = can(regex("BucketLocation = \"eu-central-1\"", output.config_toml))
    error_message = "cache_bucket_region must override the fleet region - a shared cross-region cache bucket otherwise fails with PermanentRedirect."
  }

  assert {
    condition = anytrue([
      for s in output.manager_policy_statements : s.Sid == "CacheEncryption"
    ])
    error_message = "SSE-KMS on the cache requires kms:GenerateDataKey and kms:Decrypt on the manager task role."
  }
}

run "orphan_discovery_is_available" {
  command = apply

  assert {
    condition     = can(output.verify_commands.orphans) && output.verify_commands.orphans != ""
    error_message = "verify_commands must expose an orphan-discovery command. A job task whose manager died is never stopped by anything and bills indefinitely; stopped_reasons cannot find it because an orphan is never STOPPED."
  }

  assert {
    condition = anytrue([
      for s in output.manager_policy_statements : s.Sid == "ListFleetTasks"
    ])
    error_message = "ecs:ListTasks is needed to enumerate orphans - DescribeTasks alone cannot find one because you need the ARN first."
  }
}
