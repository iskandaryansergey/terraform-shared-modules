resource "aws_ecs_cluster" "this" {
  count = local.create ? 1 : 0

  name = local.cluster_name

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enabled" : "disabled"
  }

  tags = local.common_tags
}

# The cluster's DEFAULT capacity provider strategy is the only lever that puts
# job tasks on Fargate Spot. The driver sets neither launchType nor
# capacityProviderStrategy on RunTask, so ECS falls back to this - which makes
# Spot a cluster-wide property. To offer both on-demand and Spot you need two
# fleets with two clusters, not two profiles.
resource "aws_ecs_cluster_capacity_providers" "this" {
  count = local.create ? 1 : 0

  cluster_name       = aws_ecs_cluster.this[0].name
  capacity_providers = distinct(concat([for s in var.capacity_provider_strategy : s.capacity_provider], ["FARGATE"]))

  dynamic "default_capacity_provider_strategy" {
    for_each = var.capacity_provider_strategy
    content {
      capacity_provider = default_capacity_provider_strategy.value.capacity_provider
      weight            = default_capacity_provider_strategy.value.weight
      base              = default_capacity_provider_strategy.value.base
    }
  }
}

# ---------------------------------------------------------------------------
# Manager task definition
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "manager" {
  count = local.create ? 1 : 0

  family                   = "${var.name}-manager"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.manager_cpu
  memory                   = var.manager_memory
  task_role_arn            = aws_iam_role.manager[0].arn
  execution_role_arn       = aws_iam_role.manager_execution[0].arn
  tags                     = local.common_tags

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "manager"
    image     = var.manager_image
    essential = true

    # ECS sends SIGTERM, and gitlab-runner treats SIGTERM as "abort all running
    # builds". The image's entrypoint traps it and forwards SIGQUIT instead, which
    # is the graceful signal. Fargate caps this at 120s, so jobs still running
    # after that die on redeploy - a platform limit, not a tuning choice.
    stopTimeout = var.manager_stop_timeout

    # The configs travel base64-encoded. That is not decoration: it means no
    # newline, quote, or shell metacharacter in any caller value can change the
    # structure of what lands on disk, because the transport is not a shell and
    # not a quoted string (R1). The entrypoint in the image decodes them.
    environment = [
      { name = "RUNNER_CONFIG_B64", value = base64encode(local.config_toml) },
      { name = "RUNNER_FARGATE_CONFIG_B64", value = base64encode(local.fargate_toml) },
      { name = "RUNNER_CA_PEM_B64", value = var.manager_ca_certificate_pem != "" ? base64encode(var.manager_ca_certificate_pem) : "" },
      # The driver resolves the region from its own config file, but the AWS SDK
      # in gitlab-runner's cache uploader does not - and aws-sdk-go-v2 does NOT
      # read the region from IMDS by default. Setting it explicitly here is the
      # fix for the class of bug where every signal stays green and nothing works.
      { name = "AWS_REGION", value = local.region },
      { name = "AWS_DEFAULT_REGION", value = local.region },
      # Changing this produces a new task definition revision and therefore a new
      # task. It exists because the runner token is resolved from Secrets Manager
      # once, at task start: changing the secret's VALUE yields no Terraform diff,
      # so without this there is no supported way to pick up a rotated token.
      { name = "RUNNER_TASK_REVISION_TRIGGER", value = var.manager_task_revision_trigger },
    ]

    # valueFrom, never environment. Values in `environment` are readable by anyone
    # holding ecs:DescribeTaskDefinition, and AWS does not let you scope that
    # action to a single task definition. The task definition stores only this ARN;
    # the execution role resolves it at launch (R7).
    secrets = [
      { name = "RUNNER_TOKEN", valueFrom = var.runner_token_secret_arn },
    ]

    # Root filesystem IS read-only. gitlab-runner writes .runner_system_id beside
    # config.toml and will not start if it cannot, so the config directory is a
    # writable volume - as are the driver's per-job metadata directory and /tmp.
    # Everything else stays read-only.
    readonlyRootFilesystem = true

    mountPoints = [
      { sourceVolume = "config", containerPath = "/etc/gitlab-runner", readOnly = false },
      { sourceVolume = "metadata", containerPath = "/opt/gitlab-runner/metadata", readOnly = false },
      { sourceVolume = "tmp", containerPath = "/tmp", readOnly = false },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = local.log_group_name
        "awslogs-region"        = local.region
        "awslogs-stream-prefix" = "manager"
      }
    }

    # Liveness that measures the OUTCOME, not the process. `systemctl is-active`
    # equivalents stay green through a revoked token, an unreachable GitLab, and a
    # driver that cannot resolve a region - which is precisely how the sibling
    # module reported seven healthy alarms while launching zero workers (R4).
    #
    # The runner's own metrics endpoint answering on :9252 means the process is up
    # AND its HTTP stack is serving; combined with the JobPickup alarm below, that
    # distinguishes "running" from "working".
    healthCheck = {
      # DERIVED from local.metrics_listen_address, the same value that becomes
      # config.toml's listen_address. Writing the probe separately is what made
      # the fleet undeployable: the probe named a port nothing listened on.
      command  = local.manager_health_command
      interval = 30
      timeout  = 5
      retries  = 3
      # Long enough to cover image pull + config decode + token substitution +
      # gitlab-runner binding its listener. Below this, ECS starts counting
      # failures before the runner can possibly answer.
      startPeriod = 120
    }
  }])

  volume {
    name = "config"
  }

  volume {
    name = "metadata"
  }

  volume {
    name = "tmp"
  }

  lifecycle {
    precondition {
      condition     = local.manager_memory_valid
      error_message = "manager_cpu = ${var.manager_cpu} does not accept manager_memory = ${var.manager_memory} MiB. Fargate allows only discrete pairs; valid memory for this CPU: ${join(", ", [for m in local.fargate_memory_for_cpu[var.manager_cpu] : tostring(m)])}."
    }
  }
}

# ---------------------------------------------------------------------------
# Job task definitions - one per profile.
#
# The container MUST be named ci-coordinator. The driver injects SSH_PUBLIC_KEY
# only into a container with that exact name; miss it and the key never arrives,
# sshd accepts nothing, and the job hangs until the driver's retry budget expires
# with no useful error. Hardcoded here rather than exposed, because there is no
# configuration in which a different name is correct.
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "job" {
  for_each = local.create ? var.job_profiles : {}

  family                   = local.job_family_names[each.key]
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.job_execution[0].arn

  # Empty means no task role at all, which is the recommended posture: one shared
  # task role is one blast radius for every project on the fleet. Per-project AWS
  # access belongs to GitLab ID tokens and sts:AssumeRoleWithWebIdentity.
  task_role_arn = each.value.task_role_arn != "" ? each.value.task_role_arn : null

  tags = merge(local.common_tags, { Profile = each.key })

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  dynamic "ephemeral_storage" {
    for_each = each.value.ephemeral_storage > 0 ? [each.value.ephemeral_storage] : []
    content {
      size_in_gib = ephemeral_storage.value
    }
  }

  container_definitions = jsonencode([{
    name      = "ci-coordinator"
    image     = each.value.image
    essential = true

    portMappings = [{ containerPort = 22, protocol = "tcp" }]

    # SSH_USERNAME is injected so the image and fargate.toml's [SSH].Username come
    # from the SAME module input and cannot disagree. A mismatch means the driver
    # authenticates as a user whose authorized_keys was never written, and the job
    # hangs with no useful error.
    environment = concat(
      [{ name = "SSH_USERNAME", value = each.value.ssh_username }],
      [for k, v in each.value.environment : { name = k, value = v }],
    )

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = local.log_group_name
        "awslogs-region"        = local.region
        "awslogs-stream-prefix" = "job-${each.key}"
      }
    }

    healthCheck = length(each.value.health_check_cmd) > 0 ? {
      command     = each.value.health_check_cmd
      interval    = 10
      timeout     = 5
      retries     = 3
      startPeriod = 30
    } : null
  }])

  lifecycle {
    precondition {
      condition     = length(local.invalid_job_profiles) == 0
      error_message = "These job_profiles have a CPU/memory pair Fargate does not accept: ${join(", ", local.invalid_job_profiles)}. Fargate allows only discrete pairs - note the 16384 CPU tier accepts only 32/40/.../120 GB in 8 GB steps, and is not a continuous range."
    }
  }
}

# ---------------------------------------------------------------------------
# Manager service
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "manager" {
  count = local.create ? 1 : 0

  name            = "${var.name}-manager"
  cluster         = aws_ecs_cluster.this[0].id
  task_definition = aws_ecs_task_definition.manager[0].arn

  # Exactly one. The driver's TaskMetadata directory has to persist across the
  # four separate stage processes, so a second replica sharing the same runner
  # token would hand `run` a metadata file `prepare` never wrote. Scale by adding
  # fleets with their own tokens, not by raising this.
  desired_count = 1

  # 0/100 rather than the default 100/200: two managers must never run at once
  # (see above), so the deployment drains before it starts the replacement. That
  # is a deliberate availability trade - there is a gap with no manager during
  # every deploy - and it is the correct one for a singleton holding a token.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  wait_for_steady_state  = true
  enable_execute_command = false
  propagate_tags         = "SERVICE"
  force_new_deployment   = var.manager_force_new_deployment
  tags                   = local.common_tags

  # Without this, a manager that cannot pass its health check makes `terraform
  # apply` block for the full ECS create timeout (~20 minutes) and then fail with
  # a wedged service. With it, ECS gives up in a few minutes and rolls back, and
  # the operator gets a deployment-failure reason instead of a timeout.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  capacity_provider_strategy {
    capacity_provider = var.manager_use_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }

  network_configuration {
    subnets          = var.manager_subnet_ids
    security_groups  = [aws_security_group.manager[0].id]
    assign_public_ip = false
  }

  # The IAM edges are required because the task definition references the ROLES,
  # not the POLICIES, so no implicit edge exists and a task could start before it
  # is authorised.
  #
  # The network and log-group edges are required for the same reason: the new-style
  # aws_vpc_security_group_*_rule resources create no attribute reference back into
  # the consumer, and the task definitions reference the log group by NAME string.
  # Without these, Terraform may create the service - and block on
  # wait_for_steady_state - before the manager can resolve DNS, reach GitLab, or
  # deliver logs. That is a race that passes in CI and fails intermittently in a
  # real estate.
  depends_on = [
    aws_iam_role_policy.manager,
    aws_iam_role_policy.manager_execution_secrets,
    aws_ecs_cluster_capacity_providers.this,
    aws_cloudwatch_log_group.this,
    aws_vpc_security_group_egress_rule.manager_https,
    aws_vpc_security_group_egress_rule.manager_on_prem,
    aws_vpc_security_group_egress_rule.manager_ssh_to_job,
    aws_vpc_security_group_egress_rule.dns,
    aws_vpc_security_group_egress_rule.fleet_to_endpoints,
    aws_vpc_security_group_egress_rule.fleet_to_existing_endpoints,
    aws_vpc_security_group_egress_rule.job_on_prem,
    aws_vpc_endpoint.interface,
    aws_vpc_endpoint.s3,
  ]

  lifecycle {
    precondition {
      # The 60-rule default quota is per security group, and the carve-out default
      # already spends 37 of it. Exceeding the quota fails PARTWAY THROUGH an
      # apply, leaving the SG in neither the old nor the new state, with an error
      # naming one arbitrary rule rather than the cause.
      condition     = local.job_egress_rule_count <= 60
      error_message = "The job security group would need ${local.job_egress_rule_count} egress rules, above the default quota of 60. The job_egress_cidrs carve-out costs ${length(local.job_egress)} rules on its own. Either request a quota increase, shorten job_egress_exclude_cidrs, or set job_egress_cidrs explicitly to a smaller list."
    }

    precondition {
      # A precomputed complement is only correct for the list it was computed
      # from. Handing a caller the complement of a DIFFERENT exclusion set would
      # be a silent security downgrade, so it is refused.
      condition     = local.exclusions_are_default || length(var.job_egress_cidrs) > 0
      error_message = "job_egress_exclude_cidrs was changed from its default, but job_egress_cidrs is empty. Terraform cannot compute a CIDR complement, so the built-in default only matches the built-in exclusion list. Set job_egress_cidrs explicitly (tests/egress_complement.py will compute it for you)."
    }

    precondition {
      # The manager tier had no rule budget at all: a caller pinning it to a
      # published IP range could plan 70+ rules and fail partway through an apply.
      condition     = local.manager_egress_rule_count <= 60
      error_message = "The manager security group would need ${local.manager_egress_rule_count} egress rules, above the default quota of 60. Shorten manager_egress_cidrs or on_prem_cidrs, or request a quota increase."
    }

    precondition {
      # An interface endpoint with private DNS disabled receives only
      # endpoint-specific DNS names, and nothing in this module redirects the ECS
      # agent to them - so it resolves the PUBLIC name. With no internet path that
      # is a hang, and the endpoints are billed while carrying no traffic. Refused
      # rather than warned about, because in an isolated estate it is fatal (R5).
      condition = !var.isolated || (
        (var.create_vpc_endpoints && var.endpoint_private_dns) ||
        length(var.existing_endpoint_security_group_ids) > 0
      )
      error_message = "isolated = true requires reachable VPC endpoints: either create_vpc_endpoints = true with endpoint_private_dns = true, or existing_endpoint_security_group_ids naming endpoints your landing zone already owns. This module does not create VPCs, subnets or routing - see the prerequisites section in README.md for the exact endpoint list it needs."
    }

    precondition {
      condition     = !var.isolated || length(var.on_prem_cidrs) > 0
      error_message = "isolated = true requires on_prem_cidrs - the fleet must be able to reach the on-prem GitLab, and there is no internet path to fall back on."
    }

    precondition {
      condition     = !var.isolated || var.gitlab_url != "https://gitlab.com"
      error_message = "isolated = true with gitlab_url = https://gitlab.com cannot work: there is no internet path to gitlab.com. Point gitlab_url at your on-prem GitLab."
    }

    precondition {
      # A shared task role passed to a job is one blast radius for every project.
      # ECS Exec additionally REQUIRES a task role, so the two settings are
      # jointly fatal at their individual defaults.
      condition = !var.job_enable_execute_command || alltrue([
        for _, p in var.job_profiles : p.task_role_arn != ""
      ])
      error_message = "job_enable_execute_command = true requires every job_profiles entry to set task_role_arn - ECS rejects RunTask with enableExecuteCommand and no task role. Reconsider enabling it at all: it runs commands as root in a container executing untrusted CI code."
    }

    precondition {
      # sort() gives a deterministic default for a fixed key set, but adding a
      # profile that sorts earlier silently re-points every pipeline that does not
      # set FARGATE_TASK_DEFINITION at a different image, size and SSH user.
      condition     = length(var.job_profiles) <= 1 || var.default_job_profile != ""
      error_message = "default_job_profile must be set explicitly when more than one job profile is defined. Otherwise the default is whichever key sorts first, and adding an unrelated profile silently changes which image every unqualified pipeline runs."
    }

    precondition {
      # The driver has ONE global [SSH] table and ONE global EvaluateTaskHealth, so
      # per-profile disagreement means the non-default profiles get the default
      # profile's values - and a wrong SSH user is a job that hangs until the
      # retry budget expires, with no useful error.
      condition     = length(distinct([for _, p in var.job_profiles : p.ssh_username])) <= 1
      error_message = "All job_profiles must agree on ssh_username. The Fargate driver has a single global [SSH] table, so a non-default profile would be SSH'd as the default profile's user and the job would hang."
    }

    precondition {
      condition = length(distinct([
        for _, p in var.job_profiles : length(p.health_check_cmd) > 0
      ])) <= 1
      error_message = "Either all job_profiles declare health_check_cmd or none do. The driver's EvaluateTaskHealth is global, so a mixed set means the driver waits for HEALTHY on a task that can never report it."
    }
  }
}
