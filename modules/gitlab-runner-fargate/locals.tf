data "aws_partition" "current" {
  count = var.create ? 1 : 0
}

data "aws_region" "current" {
  count = var.create ? 1 : 0
}

data "aws_caller_identity" "current" {
  count = var.create ? 1 : 0
}

data "aws_vpc" "this" {
  count = var.create ? 1 : 0
  id    = var.vpc_id
}

locals {
  create = var.create

  # Placeholders keep every ARN expression valid when create = false, which is
  # what lets the offline render fixture apply with no credentials (R8).
  partition  = one(data.aws_partition.current[*].partition) != null ? one(data.aws_partition.current[*].partition) : "aws"
  region     = one(data.aws_region.current[*].name) != null ? one(data.aws_region.current[*].name) : "us-east-1"
  account_id = one(data.aws_caller_identity.current[*].account_id) != null ? one(data.aws_caller_identity.current[*].account_id) : "000000000000"
  vpc_cidr   = one(data.aws_vpc.this[*].cidr_block) != null ? one(data.aws_vpc.this[*].cidr_block) : "10.0.0.0/16"

  common_tags = merge(var.tags, {
    ManagedBy = "terraform"
    Module    = "gitlab-runner-fargate"
    Fleet     = var.name
  })

  cluster_name    = "${var.name}-runners"
  log_group_name  = "/aws/gitlab-runner-fargate/${var.name}"
  alarm_namespace = "GitLabRunnerFargate/${var.name}"

  # Constructed rather than read back from the resource attribute. That keeps the
  # IAM policy a plan-time value - so it is fully visible in a plan diff and
  # assertable in tests - and it keeps the dependency edges shallow. The ARN
  # format for an ECS cluster is stable and account/region/name are all known.
  cluster_arn = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:cluster/${local.cluster_name}"

  # Same reasoning: the role name is ours, so the ARN is derivable without
  # waiting on the resource.
  job_execution_role_arn = "arn:${local.partition}:iam::${local.account_id}:role/${var.name}-job-execution"

  # -------------------------------------------------------------------------
  # Fargate CPU/memory pairs.
  #
  # These are discrete, not ranges. Verified against AWS's task-size table: 74
  # valid pairs in total, and this map reproduces all 74 exactly in both
  # directions - no valid pair rejected, no invalid pair accepted. Getting it
  # wrong produces an apply-time InvalidParameter naming neither variable, so it
  # is checked at plan time instead.
  # -------------------------------------------------------------------------
  fargate_memory_for_cpu = {
    256   = [512, 1024, 2048]
    512   = [1024, 2048, 3072, 4096]
    1024  = [2048, 3072, 4096, 5120, 6144, 7168, 8192]
    2048  = [for m in range(4, 17) : m * 1024] # 4-16 GB, 1 GB steps
    4096  = [for m in range(8, 31) : m * 1024] # 8-30 GB, 1 GB steps
    8192  = [for m in range(4, 16) : m * 4096] # 16-60 GB, 4 GB steps
    16384 = [for m in range(4, 16) : m * 8192] # 32-120 GB, 8 GB steps
  }

  manager_memory_valid = contains(local.fargate_memory_for_cpu[var.manager_cpu], var.manager_memory)

  invalid_job_profiles = [
    for k, p in var.job_profiles : k
    if !contains(local.fargate_memory_for_cpu[p.cpu], p.memory)
  ]

  # -------------------------------------------------------------------------
  # Job egress default: the public internet minus job_egress_exclude_cidrs.
  #
  # This literal is the complement of the DEFAULT exclusion set, computed with
  # Python's ipaddress module rather than assembled by hand. Terraform cannot
  # compute a CIDR complement, so the value is precomputed - and because a
  # precomputed value is exactly the kind of thing that silently drifts from the
  # list it claims to complement, tests/egress_complement.py recomputes it from
  # variables.tf and fails if the two disagree (R2, R8).
  #
  # 37 rules. The default security-group quota is 60 rules, so this spends 62%
  # of it before any job_extra_egress_rules. A precondition below refuses to
  # plan past the quota rather than failing halfway through an apply.
  # -------------------------------------------------------------------------
  computed_job_egress = [
    "0.0.0.0/5", "8.0.0.0/7", "11.0.0.0/8", "12.0.0.0/6", "16.0.0.0/4",
    "32.0.0.0/3", "64.0.0.0/3", "96.0.0.0/6", "100.0.0.0/10", "100.128.0.0/9",
    "101.0.0.0/8", "102.0.0.0/7", "104.0.0.0/5", "112.0.0.0/4", "128.0.0.0/3",
    "160.0.0.0/5", "168.0.0.0/6", "172.0.0.0/12", "172.32.0.0/11",
    "172.64.0.0/10", "172.128.0.0/9", "173.0.0.0/8", "174.0.0.0/7",
    "176.0.0.0/4", "192.0.0.0/9", "192.128.0.0/11", "192.160.0.0/13",
    "192.169.0.0/16", "192.170.0.0/15", "192.172.0.0/14", "192.176.0.0/12",
    "192.192.0.0/10", "193.0.0.0/8", "194.0.0.0/7", "196.0.0.0/6",
    "200.0.0.0/5", "208.0.0.0/4",
  ]

  # The literal above is only correct for the default exclusion set. If a caller
  # overrides job_egress_exclude_cidrs they must supply job_egress_cidrs too -
  # silently handing them a complement of a different list would be worse than
  # refusing. A precondition enforces that pairing.
  default_exclusions = [
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "224.0.0.0/3",
  ]
  exclusions_are_default = (
    length(var.job_egress_exclude_cidrs) == length(local.default_exclusions) &&
    length(setsubtract(var.job_egress_exclude_cidrs, local.default_exclusions)) == 0
  )

  # When isolated, [] means EXACTLY that: no general egress. Falling back to the
  # internet-minus-private-space default would be meaningless with no internet
  # path, and granting it would be worse than meaningless. On-prem reachability
  # comes from on_prem_cidrs and AWS reachability from the endpoint rules, so an
  # isolated fleet with no general egress is the correct, tightest posture - not a
  # misconfiguration.
  job_egress = var.isolated ? var.job_egress_cidrs : (
    length(var.job_egress_cidrs) > 0 ? var.job_egress_cidrs : local.computed_job_egress
  )

  # Content-addressed keys, so reordering the input list is a no-op.
  #
  # Deduplication happens on the KEY-BEARING fields only. Previously it used
  # distinct() over objects that included `description`, so two entries for the
  # same protocol/port/CIDR with different wording survived distinct() and then
  # collided on the key - a hard "Duplicate object key" plan failure whose error
  # named an internal local rather than the input. Two teams adding the same
  # registry with their own wording is an ordinary merge outcome.
  job_extra_egress_shapes = distinct(flatten([
    for rule in var.job_extra_egress_rules : [
      for c in rule.cidrs : {
        protocol = rule.protocol
        port     = rule.port
        cidr     = c
      }
    ]
  ]))

  # First description wins for any given shape. The `...` grouping is REQUIRED:
  # a plain for-expression building a map throws "Duplicate object key" the moment
  # two entries share a shape, which is exactly the crash being fixed here. This
  # collects every description per key and then takes the first.
  job_extra_egress_descriptions = {
    for key, descs in {
      for r in flatten([
        for rule in var.job_extra_egress_rules : [
          for c in rule.cidrs : {
            key         = "${rule.protocol}-${rule.port}-${c}"
            description = rule.description
          }
        ]
      ]) : r.key => r.description...
    } : key => descs[0]
  }

  job_extra_egress = {
    for s in local.job_extra_egress_shapes : "${s.protocol}-${s.port}-${s.cidr}" => {
      protocol    = s.protocol
      port        = s.port
      cidr        = s.cidr
      description = local.job_extra_egress_descriptions["${s.protocol}-${s.port}-${s.cidr}"]
    }
  }

  # Rule budget: the computed/explicit 443 set, plus extras, plus DNS (udp+tcp)
  # and the 443 rule to the endpoint SG when endpoints are enabled.
  job_egress_rule_count = (
    length(local.job_egress)
    + length(local.job_extra_egress)
    + length(var.on_prem_cidrs)
    + 2                                  # DNS: udp + tcp
    + (var.create_vpc_endpoints ? 1 : 0) # SG-referenced rule to the endpoint SG
  )

  # The manager tier needed its own budget: it had none, and a caller pinning the
  # manager to a published IP range could plan 70+ rules and fail mid-apply.
  manager_egress_rule_count = (
    length(var.manager_egress_cidrs)
    + length(var.on_prem_cidrs)
    + 1 # SSH to the job SG
    + 2 # DNS: udp + tcp
    + (var.create_vpc_endpoints ? 1 : 0)
    + length(var.existing_endpoint_security_group_ids)
  )

  # -------------------------------------------------------------------------
  # Endpoints. Fargate platform 1.4.0+ needs BOTH ECR interface endpoints AND
  # the S3 GATEWAY endpoint, because ECR stores layers in S3. A partial set does
  # not error - traffic silently falls back to the public endpoint, which in a
  # NAT-free subnet is a hang. So the set is fixed, not caller-configurable.
  # -------------------------------------------------------------------------
  interface_endpoint_services = distinct(concat(
    ["ecr.api", "ecr.dkr", "logs"],
    ["secretsmanager"], # the runner token is resolved by the execution role
    # The manager calls ecs:RunTask / DescribeTasks / StopTask once per job. With
    # no internet path there is NO route to that API without this endpoint, so the
    # fleet pulls images successfully and launches nothing. Included always: it is
    # cheap relative to being wrong, and it is required the moment NAT is absent.
    ["ecs"],
    # sts: the OIDC path (AssumeRoleWithWebIdentity) that replaces a shared job
    # task role, and some SDK credential-resolution paths.
    var.isolated ? ["sts"] : [],
    var.log_kms_key_arn != "" || var.runner_token_kms_key_arn != "" || var.cache_kms_key_arn != "" ? ["kms"] : [],
    var.job_enable_execute_command ? ["ssmmessages"] : [],
    var.extra_endpoint_services,
  ))

  # aws-cn prefixes endpoint service names. Every other constructed ARN in this
  # module goes through local.partition; this is the one place a service NAME
  # rather than an ARN needs the same treatment, and it is the seam the sibling
  # module missed.
  endpoint_service_prefix = local.partition == "aws-cn" ? "cn.com.amazonaws" : "com.amazonaws"

  # One subnet per AZ for interface endpoints: an endpoint accepts at most one
  # subnet per AZ, and job/manager subnet lists may contain several in the same
  # one. Map iteration is key-sorted and sort() fixes the member order, so this
  # is stable across plans rather than producing a perpetual diff.
  endpoint_subnet_ids = local.create ? [
    for az, ids in {
      for s in data.aws_subnet.endpoints : s.availability_zone => s.id...
    } : sort(ids)[0]
  ] : []

  # Route tables the S3 gateway endpoint attaches to. Resolved PER SUBNET, so it
  # cannot reach a table none of this fleet's subnets use.
  #
  # A subnet with no explicit association resolves to nothing here, and that is
  # deliberate: the fallback would be the VPC main route table, which is shared
  # with every other implicitly-associated subnet. The precondition on the S3
  # endpoint refuses that case instead of quietly rewriting a shared table.
  job_route_table_ids = local.create && var.create_vpc_endpoints ? distinct(flatten([
    for s in data.aws_route_tables.per_subnet : s.ids
  ])) : []

  any_subnet_uses_main_route_table = local.create && var.create_vpc_endpoints ? anytrue([
    for s in data.aws_route_tables.per_subnet : length(s.ids) == 0
  ]) : false

  # -------------------------------------------------------------------------
  # Job task definitions, and the ARNs the manager is allowed to run.
  #
  # This list IS the containment boundary. CUSTOM_ENV_FARGATE_TASK_DEFINITION
  # lets any project maintainer point the driver at a different task definition,
  # so ecs:RunTask must be scoped to exactly these ARNs and iam:PassRole to
  # exactly the roles they use. Never widen either to a wildcard.
  # -------------------------------------------------------------------------
  job_family_names = { for k, _ in var.job_profiles : k => "${var.name}-job-${k}" }

  job_task_role_arns = distinct([
    for _, p in var.job_profiles : p.task_role_arn if p.task_role_arn != ""
  ])

  # Explicit if named, alphabetically first otherwise. NOTE sort() gives a
  # deterministic answer for a FIXED key set; it does not stop the default moving
  # when a profile that sorts earlier is added. A validation therefore requires
  # default_job_profile once there is more than one profile.
  default_profile = var.default_job_profile != "" ? var.default_job_profile : sort(keys(var.job_profiles))[0]

  # ecs:DescribeTaskDefinition cannot be resource-scoped by AWS, so it is granted
  # only when the driver actually needs it - i.e. when some profile declares a
  # health check and EvaluateTaskHealth is therefore on.
  any_profile_has_health_check = anytrue([
    for _, p in var.job_profiles : length(p.health_check_cmd) > 0
  ])

  # Spot is a cluster-wide property here (the driver sets no per-task strategy),
  # so "does this fleet use Spot" is a question about the cluster default plus the
  # manager's own placement. Used to avoid creating an EventBridge rule that could
  # never match.
  uses_spot = var.manager_use_spot || anytrue([
    for s in var.capacity_provider_strategy : s.capacity_provider == "FARGATE_SPOT" && s.weight > 0
  ])

  # -------------------------------------------------------------------------
  # Rendered configuration.
  #
  # Both files go through templatefile with every caller string passed through
  # jsonencode() inside the template. There is no raw-text hatch (R1.4).
  # -------------------------------------------------------------------------
  # The runner must stay patient longer than the driver does, or it abandons the
  # job while the driver is still legitimately waiting for a cold task. The
  # driver's ceiling is attempts * interval; +300s covers the SSH retry budget
  # and the build script itself starting.
  prepare_exec_timeout = max(600, var.job_task_wait_max_attempts * var.job_task_wait_interval + 300)

  # The manager's health check probes gitlab-runner's metrics server, and that
  # server only exists if listen_address is set. Both the config value and the
  # probe are derived from ONE variable here so they cannot disagree - the defect
  # that made the fleet undeployable was exactly that disagreement.
  metrics_listen_address = var.manager_metrics_listen_address
  metrics_probe_url      = "http://${var.manager_metrics_listen_address}/metrics"

  # curl, not wget: curl is what docker/Dockerfile.manager actually installs.
  manager_health_command = ["CMD-SHELL", "curl -fsS -o /dev/null --max-time 3 ${local.metrics_probe_url} || exit 1"]

  cache_region_effective = var.cache_bucket_region != "" ? var.cache_bucket_region : local.region

  # On-prem reachability is granted to BOTH tiers: the manager needs GitLab's API,
  # and job tasks need it for git clone and artifact upload.
  on_prem_rule_count = length(var.on_prem_cidrs)

  # Template variable names deliberately match the Terraform variable names for
  # every number and bool, so tests/template_safety.py can verify each exemption
  # against variables.tf by name instead of taking the claim on trust (R2.3).
  config_toml = templatefile("${path.module}/templates/config.toml.tftpl", {
    manager_concurrent          = var.manager_concurrent
    manager_check_interval      = var.manager_check_interval
    manager_request_concurrency = var.manager_request_concurrency
    prepare_exec_timeout        = local.prepare_exec_timeout
    runner_name                 = var.name
    gitlab_url                  = var.gitlab_url
    driver_path                 = "/opt/gitlab-runner/fargate"
    driver_config_flag          = "--config"
    driver_config_path          = "/etc/gitlab-runner/fargate.toml"
    cache_enabled               = var.cache_bucket_name != ""
    cache_bucket                = var.cache_bucket_name
    cache_path                  = var.cache_path
    cache_region                = local.cache_region_effective
    listen_address              = local.metrics_listen_address
    clone_url                   = var.runner_clone_url
    cache_sse                   = var.cache_server_side_encryption
    cache_kms_key_arn           = var.cache_kms_key_arn
    tls_ca_file                 = var.manager_ca_certificate_pem != "" ? "/etc/gitlab-runner/certs/ca.crt" : ""
  })

  fargate_toml = templatefile("${path.module}/templates/fargate.toml.tftpl", {
    log_level                  = var.driver_log_level
    cluster                    = local.cluster_name
    region                     = local.region
    subnets                    = join(",", var.job_subnet_ids)
    security_group             = local.create ? aws_security_group.job[0].id : "sg-placeholder"
    task_definition            = local.job_family_names[local.default_profile]
    ssh_username               = var.job_profiles[local.default_profile].ssh_username
    job_enable_execute_command = var.job_enable_execute_command
    job_task_wait_max_attempts = var.job_task_wait_max_attempts
    job_task_wait_interval     = var.job_task_wait_interval
    metadata_directory         = "/opt/gitlab-runner/metadata"
    evaluate_task_health       = length(var.job_profiles[local.default_profile].health_check_cmd) > 0
  })
}

# Subnets the interface endpoints live in: the union of manager and job subnets,
# deduplicated to one per AZ in locals above.
data "aws_subnet" "endpoints" {
  for_each = local.create && var.create_vpc_endpoints ? toset(concat(var.manager_subnet_ids, var.job_subnet_ids)) : toset([])
  id       = each.value
}

# Per-subnet route-table lookup. aws_route_tables (plural) filtered by
# association returns an EMPTY list for an implicitly-associated subnet rather
# than the main table, which is exactly the signal we want: empty means "this
# subnet uses the shared main table" and the S3 endpoint's precondition refuses
# to proceed. The singular data source would silently hand back the main table.
data "aws_route_tables" "per_subnet" {
  for_each = local.create && var.create_vpc_endpoints ? toset(concat(var.manager_subnet_ids, var.job_subnet_ids)) : toset([])

  vpc_id = var.vpc_id

  filter {
    name   = "association.subnet-id"
    values = [each.value]
  }
}

# ---------------------------------------------------------------------------
# Plan-time checks. These warn rather than fail, because each describes a
# configuration that is legal and deployable but probably not what you meant.
# ---------------------------------------------------------------------------

check "alarms_have_a_destination" {
  assert {
    condition     = !var.create_alarms || length(var.alarm_sns_topic_arns) > 0
    error_message = "create_alarms = true with alarm_sns_topic_arns = [] creates alarms that change state and notify nobody. That is an audit trail, not an alerting system - wire an SNS topic."
  }
}

check "cache_is_configured" {
  assert {
    condition     = var.cache_bucket_name != ""
    error_message = "cache_bucket_name is empty, so there is no distributed cache. Job tasks are ephemeral, so every job will re-download all of its dependencies. Set a bucket unless this is a throwaway fleet."
  }
}

check "manager_image_is_pinned" {
  assert {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.manager_image))
    error_message = "manager_image is not pinned by digest. The manager holds ecs:RunTask and iam:PassRole for every job role; an unpinned tag means its image is whatever the registry serves at task launch, with no review and no rollback target."
  }
}

check "job_images_are_pinned" {
  assert {
    condition = alltrue([
      for _, p in var.job_profiles : can(regex("@sha256:[0-9a-f]{64}$", p.image))
    ])
    error_message = "One or more job_profiles images are not pinned by digest. Job images execute untrusted CI code; pin them so what ran is reconstructible."
  }
}

check "spot_manager_is_deliberate" {
  assert {
    condition     = !var.manager_use_spot
    error_message = "manager_use_spot = true puts the control plane on Spot. A single interruption aborts every in-flight job on the fleet, and the manager is a rounding error on the bill."
  }
}
