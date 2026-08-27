locals {
  create = var.create

  common_tags = merge(var.tags, {
    "ManagedBy" = "Terraform"
    "Module"    = "gitlab-runner"
  })

  # Placeholders so ARN-building expressions still evaluate when create = false.
  partition  = coalesce(one(data.aws_partition.current[*].partition), "aws")
  region     = coalesce(one(data.aws_region.current[*].name), "us-east-1")
  account_id = coalesce(one(data.aws_caller_identity.current[*].account_id), "000000000000")

  manager_subnet_ids = length(var.manager_subnet_ids) > 0 ? var.manager_subnet_ids : var.worker_subnet_ids

  worker_asg_name = "${var.name}-workers"

  log_group_name  = "/aws/gitlab-runner/${var.name}"
  alarm_namespace = "GitLabRunner/${var.name}"

  # Must match the AMI's actual root device. If it doesn't, AWS silently drops the
  # whole block_device_mappings entry, encryption included.
  worker_root_device_resolved = (
    var.worker_root_device_name != "" ? var.worker_root_device_name
    : coalesce(one(data.aws_ami.al2023_worker[*].root_device_name), "/dev/xvda")
  )
  manager_root_device_resolved = (
    var.manager_root_device_name != "" ? var.manager_root_device_name
    : coalesce(one(data.aws_ami.al2023_manager[*].root_device_name), "/dev/xvda")
  )

  # Fall back to Amazon Linux 2023 for the right architecture.
  worker_ami  = var.worker_ami_id != "" ? var.worker_ami_id : one(data.aws_ami.al2023_worker[*].id)
  manager_ami = var.manager_ami_id != "" ? var.manager_ami_id : one(data.aws_ami.al2023_manager[*].id)

  # Graviton instance types end their generation with "g".
  manager_arch = can(regex("^[a-z]+[0-9]+g", var.manager_instance_type)) ? "arm64" : "x86_64"

  # Either a parameter we create, or one the caller already has.
  token_ssm_parameter = var.runner_token_ssm_parameter != "" ? var.runner_token_ssm_parameter : "/${var.name}/gitlab-runner/token"
  create_token_param  = var.runner_token_ssm_parameter == "" && var.runner_token != ""

  # Must match total job slots or the fleet has capacity it never uses.
  concurrent = var.max_instances * var.capacity_per_instance

  # A baked AMI is expected to ship Docker already.
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
    # Stable across plans so there's no perpetual diff. Not a secret: what stops
    # a breakout is the TFCFG_ validation on extra_runner_config_toml.
    heredoc_nonce      = substr(sha256("${var.name}-config-heredoc"), 0, 12)
    repo_script_sha256 = var.package_repo_script_sha256
  })

  worker_user_data = templatefile("${path.module}/templates/worker-user-data.sh.tftpl", {
    install_docker = local.worker_needs_docker_bootstrap
    ssh_username   = var.worker_ssh_username
    extra          = var.worker_user_data
  })
}
