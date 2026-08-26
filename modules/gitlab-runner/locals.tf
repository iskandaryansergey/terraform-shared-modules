data "aws_vpc" "this" {
  count = local.create ? 1 : 0
  id    = var.vpc_id
}

# The route tables our worker subnets actually use - so the S3 gateway endpoint
# touches only our subnets' routing, never the whole VPC's.
#
# The plural data source (not the singular one keyed by subnet_id) on purpose:
# association.subnet-id only matches EXPLICIT associations, so a subnet left on
# the VPC's main route table returns nothing and the singular lookup hard-fails
# the plan. Very common layout.
# One lookup per subnet, each with a main-table fallback. The plural form filtered
# on association.subnet-id only matches EXPLICIT associations, so a shared table
# or a main-table subnet made a whole-VPC fallback fire - which rewrote routing
# for subnets this module doesn't own. Per-subnet resolution can't over-reach.
data "aws_route_tables" "worker" {
  for_each = local.create && var.create_vpc_endpoints ? toset(var.worker_subnet_ids) : toset([])

  vpc_id = var.vpc_id

  filter {
    name   = "association.subnet-id"
    values = [each.value]
  }
}

# An interface endpoint accepts at most one subnet per AZ, so collapse the worker
# subnets down to one per AZ before wiring them up.
data "aws_subnet" "workers" {
  for_each = local.create && var.create_vpc_endpoints ? toset(var.worker_subnet_ids) : toset([])
  id       = each.value
}

locals {
  create = var.create

  common_tags = merge(var.tags, {
    "ManagedBy" = "Terraform"
    "Module"    = "gitlab-runner"
  })

  # Per subnet: its explicit table if it has one, otherwise the VPC main table
  # (which is what that subnet is genuinely routed by). Only tables OUR subnets
  # actually use ever end up here.
  worker_route_table_ids = distinct(flatten([
    for subnet_id, rts in data.aws_route_tables.worker :
    length(rts.ids) > 0 ? rts.ids : compact([one(data.aws_vpc.this[*].main_route_table_id)])
  ]))

  # one subnet per AZ; an interface endpoint rejects two in the same AZ
  endpoint_subnet_ids = [
    for az, ids in { for id, s in data.aws_subnet.workers : s.availability_zone => id... } : ids[0]
  ]

  # Placeholders keep every ARN-building expression valid when create = false.
  partition  = coalesce(one(data.aws_partition.current[*].partition), "aws")
  region     = coalesce(one(data.aws_region.current[*].name), "us-east-1")
  account_id = coalesce(one(data.aws_caller_identity.current[*].account_id), "000000000000")

  manager_subnet_ids = length(var.manager_subnet_ids) > 0 ? var.manager_subnet_ids : var.worker_subnet_ids

  worker_asg_name = "${var.name}-workers"

  # A self-managed GitLab given as a private IP would be unreachable from workers,
  # because the default egress carves RFC1918 out. Detect it and open just it.
  gitlab_host         = replace(replace(var.gitlab_url, "https://", ""), "/", "")
  gitlab_is_private   = can(regex("^(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.)", local.gitlab_host))
  gitlab_private_cidr = local.gitlab_is_private ? "${local.gitlab_host}/32" : "0.0.0.0/32"
  log_group_name      = "/aws/gitlab-runner/${var.name}"
  alarm_namespace     = "GitLabRunner/${var.name}"

  # AMIs: fall back to Amazon Linux 2023 for the right architecture.
  worker_ami  = var.worker_ami_id != "" ? var.worker_ami_id : one(data.aws_ami.al2023_worker[*].id)
  manager_ami = var.manager_ami_id != "" ? var.manager_ami_id : one(data.aws_ami.al2023_manager[*].id)

  # manager architecture is inferred from its instance type (t4g/m7g/c7g/... = Graviton)
  manager_arch = can(regex("^[a-z]+[0-9]+g", var.manager_instance_type)) ? "arm64" : "x86_64"

  # Where the manager reads the token from: a parameter we create, or one you already have.
  token_ssm_parameter = var.runner_token_ssm_parameter != "" ? var.runner_token_ssm_parameter : "/${var.name}/gitlab-runner/token"
  create_token_param  = var.runner_token_ssm_parameter == "" && var.runner_token != ""

  # `concurrent` should equal the fleet's total job slots, or capacity goes unused.
  concurrent = var.max_instances * var.capacity_per_instance

  # Only workers built from the default AMI need Docker installed at boot; a baked
  # AMI is expected to already have it.
  worker_needs_docker_bootstrap = var.worker_ami_id == ""

  config_toml = templatefile("${path.module}/templates/config.toml.tftpl", {
    concurrent            = local.concurrent
    name                  = var.name
    gitlab_url            = var.gitlab_url
    docker_image          = var.docker_image
    docker_privileged     = var.docker_privileged
    docker_volumes        = var.docker_volumes
    runner_environment    = var.runner_environment
    plugin                = "aws:${var.fleeting_plugin_version != "" ? var.fleeting_plugin_version : "latest"}"
    asg_name              = local.worker_asg_name
    capacity_per_instance = var.capacity_per_instance
    max_use_count         = var.max_use_count
    max_instances         = var.max_instances
    ssh_username          = var.worker_ssh_username
    policies              = var.autoscaling_policies
    scale_throttle        = var.scale_throttle
    ready_command         = var.worker_ready_command
    extra_config          = var.extra_runner_config_toml
    metrics_listen        = var.metrics_listen_address
    allowed_images        = var.allowed_images
    allowed_services      = var.allowed_services
  })

  manager_user_data = templatefile("${path.module}/templates/manager-user-data.sh.tftpl", {
    region              = local.region
    token_ssm_parameter = local.token_ssm_parameter
    runner_version      = var.gitlab_runner_version
    config_toml         = local.config_toml
    repo_script_url     = var.package_repo_script_url
    plugin_sha256       = var.fleeting_plugin_sha256
    log_group           = local.log_group_name
    ship_logs           = var.log_retention_days > 0
    alarm_namespace     = local.alarm_namespace
    fleet_name          = var.name
    unpinned            = var.allow_unpinned_artifacts
    # Derived from the fleet name, so it's stable across plans (no perpetual
    # diff) but not a value a caller can guess and embed to break out.
    heredoc_nonce      = substr(sha256("${var.name}-config-heredoc"), 0, 12)
    repo_script_sha256 = var.package_repo_script_sha256
  })

  worker_user_data = templatefile("${path.module}/templates/worker-user-data.sh.tftpl", {
    install_docker = local.worker_needs_docker_bootstrap
    ssh_username   = var.worker_ssh_username
    extra          = var.worker_user_data
  })
}
