# ============================================================================
# GENERAL
# ============================================================================

variable "create" {
  description = "Master switch. When false the module creates nothing."
  type        = bool
  default     = true
  nullable    = false
}

variable "name" {
  description = "Name for this runner fleet - prefixes every resource (e.g. \"ci-prod\" -> ci-prod-manager, ci-prod-workers)."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]{2,32}$", var.name))
    error_message = "name must be 2-32 chars: letters, numbers, hyphens."
  }
}

variable "tags" {
  description = "Tags applied to everything. Add your FinOps/cost-allocation keys here."
  type        = map(string)
  default     = {}
  nullable    = false
}

# ============================================================================
# NETWORK (bring your own - a VPC belongs to a landing-zone module, not here)
# ============================================================================

variable "vpc_id" {
  description = "VPC the fleet lives in."
  type        = string
  nullable    = false
}

variable "worker_subnet_ids" {
  description = "Private subnets for the ephemeral workers. Give it 3+ across different AZs - AZ spread is one of the biggest levers on Spot availability."
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.worker_subnet_ids) > 0
    error_message = "Provide at least one worker subnet (3+ across AZs recommended for Spot depth)."
  }
}

variable "manager_subnet_ids" {
  description = "Subnet(s) for the manager instance. Private + NAT is the secure default. Empty = reuse worker_subnet_ids."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "create_vpc_endpoints" {
  description = "Create interface endpoints for ssm/ssmmessages/ec2messages (+ a gateway endpoint for S3). Keeps agent and S3 traffic off the NAT gateway, which is usually the cheaper and more private option for a chatty CI fleet."
  type        = bool
  default     = false
  nullable    = false
}

# ============================================================================
# GITLAB CONNECTION
# ============================================================================

variable "gitlab_url" {
  description = "GitLab instance URL (SaaS or self-managed)."
  type        = string
  default     = "https://gitlab.com"
  nullable    = false

  validation {
    condition     = can(regex("^https://[^/]+/?$", var.gitlab_url))
    error_message = "gitlab_url must be an https:// URL."
  }
}

variable "runner_token" {
  description = <<-EOT
    GitLab runner AUTHENTICATION token (starts with "glrt-"). Create the runner in
    GitLab first (Settings -> CI/CD -> Runners -> New runner, or the API), then pass
    the token here - the module stores it in SSM Parameter Store as a SecureString
    and the manager fetches it at boot, so it never lands in user_data plaintext.

    Registration tokens are deprecated; this is the modern flow. Leave empty and set
    runner_token_ssm_parameter instead if the token is already in SSM (e.g. written
    by Vault or another pipeline).
  EOT
  type        = string
  default     = ""
  sensitive   = true
  nullable    = false

  validation {
    condition     = var.runner_token == "" || startswith(var.runner_token, "glrt-")
    error_message = "runner_token must be a runner authentication token starting with \"glrt-\"."
  }
}

variable "runner_token_ssm_parameter" {
  description = <<-EOT
    Name of an EXISTING SSM SecureString parameter holding the glrt- token. This is
    the RECOMMENDED path: passing runner_token instead writes the token into
    Terraform state in cleartext (`sensitive = true` hides it from CLI output, it
    does NOT remove it from state), so anyone who can read your state backend can
    register a runner and receive your jobs.

    Have Vault, another pipeline, or a one-off CLI call write the parameter, then
    point at it here. Exactly one of runner_token / runner_token_ssm_parameter must
    be set.
  EOT
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.runner_token_ssm_parameter == "" || can(regex("^/?[a-zA-Z0-9_.\\-/]+$", var.runner_token_ssm_parameter))
    error_message = "runner_token_ssm_parameter must be a valid SSM parameter name."
  }
  validation {
    condition     = (var.runner_token != "") != (var.runner_token_ssm_parameter != "")
    error_message = "Set exactly one of runner_token or runner_token_ssm_parameter (prefer the SSM parameter - it keeps the token out of Terraform state)."
  }
}

variable "kms_key_arn" {
  description = <<-EOT
    CMK for the SSM token parameter and EBS volumes. Empty = AWS-managed keys, which
    means the token is decryptable by any principal in the account holding
    kms:Decrypt on the AWS-managed key - a CMK with a tight key policy is the
    stronger choice.

    NOTE: the key policy must allow the manager and worker roles to use the key; the
    module does not (and cannot safely) edit a key policy you own.
  EOT
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.kms_key_arn == "" || can(regex("^arn:aws[a-z-]*:kms:", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN."
  }
}

# ============================================================================
# AUTOSCALER BEHAVIOUR (the cost/throughput dials)
# ============================================================================

variable "max_instances" {
  description = "Hard ceiling on concurrent worker instances. This is your spend guardrail - always set it deliberately."
  type        = number
  default     = 10
  nullable    = false

  validation {
    condition     = var.max_instances >= 1 && var.max_instances <= 1000
    error_message = "max_instances must be 1-1000."
  }
}

variable "capacity_per_instance" {
  description = "Jobs each worker runs concurrently. 1 gives clean isolation (recommended for untrusted or multi-tenant CI); higher packs more jobs per VM and cuts cost."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.capacity_per_instance >= 1 && var.capacity_per_instance <= 100
    error_message = "capacity_per_instance must be 1-100."
  }
}

variable "max_use_count" {
  description = "How many jobs a worker serves before it's retired. 1 = fully ephemeral (best isolation, more boot churn); higher amortizes boot time. Pair a higher value with a baked AMI."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.max_use_count >= 1
    error_message = "max_use_count must be >= 1."
  }
  # Retiring a multi-slot worker after one job pays for capacity you never use.
  validation {
    condition     = var.capacity_per_instance == 1 || var.max_use_count >= var.capacity_per_instance
    error_message = "With capacity_per_instance > 1, max_use_count should be >= capacity_per_instance - otherwise the worker is retired before its other job slots are ever used."
  }
}

variable "autoscaling_policies" {
  description = <<-EOT
    Scaling policies, evaluated in order - the LAST matching period wins, so put the
    catch-all last. This is where scale-to-zero happens: a policy with idle_count = 0
    means no workers (and no compute cost) when nothing is queued.

      idle_count : warm instances kept ready for instant pickup (0 = scale to zero).
      idle_time  : how long an idle instance survives before termination.
      periods    : unix-cron windows the policy applies to (["* * * * *"] = always).
      timezone   : timezone the periods are evaluated in.
      scale_factor / scale_factor_limit : keep idle capacity proportional to
        in-use capacity, for bursty pipelines.

    The default keeps 1 warm worker on weekday working hours and scales to zero
    otherwise - a sane cost/latency starting point.
  EOT
  type = list(object({
    idle_count         = number
    idle_time          = optional(string, "20m0s")
    periods            = optional(list(string), ["* * * * *"])
    timezone           = optional(string, "UTC")
    scale_factor       = optional(number, 0)
    scale_factor_limit = optional(number, 0)
  }))
  default = [
    { idle_count = 1, idle_time = "20m0s", periods = ["* 8-18 * * mon-fri"] },
    { idle_count = 0, idle_time = "10m0s", periods = ["* * * * *"] },
  ]
  nullable = false

  validation {
    condition     = length(var.autoscaling_policies) > 0
    error_message = "Define at least one autoscaling policy."
  }
  validation {
    condition     = alltrue([for p in var.autoscaling_policies : p.idle_count >= 0])
    error_message = "autoscaling_policies[*].idle_count must be >= 0."
  }
  validation {
    condition     = alltrue([for p in var.autoscaling_policies : can(regex("^[0-9]+[hms]", p.idle_time))])
    error_message = "autoscaling_policies[*].idle_time must be a Go duration like \"20m0s\" or \"1h\"."
  }
  validation {
    condition     = alltrue([for p in var.autoscaling_policies : length(p.periods) > 0])
    error_message = "autoscaling_policies[*].periods must be non-empty (use [\"* * * * *\"] for always)."
  }
}

variable "scale_throttle" {
  description = "Rate-limit how fast new workers are provisioned - stops a huge pipeline from stampeding the EC2 API. limit = instances/sec, burst = bucket size. 0 = unthrottled."
  type = object({
    limit = optional(number, 0)
    burst = optional(number, 0)
  })
  default  = {}
  nullable = false
}

# ============================================================================
# WORKER FLEET (capacity + cost model)
# ============================================================================

variable "worker_ami_id" {
  description = "AMI for workers. Needs Docker running and sshd (the fleeting plugin connects over SSH with an ephemeral EC2 Instance Connect key). Empty = latest Amazon Linux 2023 for the chosen architecture, with Docker installed via user_data. A baked AMI is strongly preferred in production - it cuts cold-start time, which matters when you scale from zero."
  type        = string
  default     = ""
  nullable    = false
}

variable "worker_ssh_username" {
  description = "OS user the manager connects as. ec2-user on Amazon Linux, ubuntu on Ubuntu."
  type        = string
  default     = "ec2-user"
  nullable    = false

  validation {
    # this lands in a shell command and in config.toml - keep it a plain username
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.worker_ssh_username))
    error_message = "worker_ssh_username must be a valid POSIX username (lowercase, no shell metacharacters)."
  }
}

variable "cpu_architecture" {
  description = "x86_64 or arm64. Graviton (arm64) is cheaper per vCPU - worth it if your toolchain supports it. Must match your instance types and AMI."
  type        = string
  default     = "x86_64"
  nullable    = false

  validation {
    condition     = contains(["x86_64", "arm64"], var.cpu_architecture)
    error_message = "cpu_architecture must be x86_64 or arm64."
  }
}

variable "worker_instance_types" {
  description = "Instance types the ASG may launch, in priority order. List 4+ across different families - pool diversification is the single biggest lever on Spot interruption rates. Must match cpu_architecture."
  type        = list(string)
  default     = ["m6i.large", "m6a.large", "m5.large", "m5a.large"]
  nullable    = false

  validation {
    condition     = length(var.worker_instance_types) > 0
    error_message = "Provide at least one worker instance type (4+ across families recommended for Spot depth)."
  }
  # Graviton families carry a 'g' after the generation digit (m7g, c6gn, t4g).
  # Mixing architectures plans cleanly and then fails EVERY launch at runtime,
  # which shows up 15 minutes later as a misleading capacity alarm.
  validation {
    condition = alltrue([
      for t in var.worker_instance_types :
      (var.cpu_architecture == "arm64") == can(regex("^[a-z]+[0-9]+[a-z]*g[a-z]*\\.", t))
    ])
    error_message = "worker_instance_types must all match cpu_architecture: Graviton types (m7g.*, c6gn.*, t4g.*) require arm64, everything else x86_64."
  }
}

variable "spot_enabled" {
  description = "Use Spot for the fleet. Ephemeral CI jobs are the textbook Spot workload; combined with scale-to-zero this is where the savings come from."
  type        = bool
  default     = true
  nullable    = false
}

variable "on_demand_base_capacity" {
  description = "Instances always on-demand before Spot kicks in. A small base (1-2) keeps CI alive through a Spot capacity crunch; 0 is cheapest."
  type        = number
  default     = 0
  nullable    = false

  validation {
    condition     = var.on_demand_base_capacity >= 0
    error_message = "on_demand_base_capacity must be >= 0."
  }
}

variable "on_demand_percentage_above_base" {
  description = "Percent of capacity ABOVE the base that's on-demand. 0 = all Spot above the base; 20 means a fifth on-demand as a cushion."
  type        = number
  default     = 0
  nullable    = false

  validation {
    condition     = var.on_demand_percentage_above_base >= 0 && var.on_demand_percentage_above_base <= 100
    error_message = "on_demand_percentage_above_base must be 0-100."
  }
}

variable "spot_allocation_strategy" {
  description = "How the ASG picks Spot pools. price-capacity-optimized is what AWS recommends (and what you want): cheapest among the pools with the deepest capacity. lowest-price has the highest interruption risk."
  type        = string
  default     = "price-capacity-optimized"
  nullable    = false

  validation {
    condition     = contains(["price-capacity-optimized", "capacity-optimized", "capacity-optimized-prioritized", "lowest-price", "diversified"], var.spot_allocation_strategy)
    error_message = "spot_allocation_strategy must be price-capacity-optimized, capacity-optimized, capacity-optimized-prioritized, lowest-price, or diversified."
  }
}

variable "capacity_rebalance" {
  description = "Let the ASG pre-emptively replace an instance when AWS signals a Spot rebalance recommendation, ahead of the 2-minute interruption notice. Good for a disposable fleet."
  type        = bool
  default     = true
  nullable    = false
}

variable "worker_disk_gb" {
  description = "Root volume size. Docker layer caches eat space - 50GB+ if you build images."
  type        = number
  default     = 50
  nullable    = false

  validation {
    condition     = var.worker_disk_gb >= 8
    error_message = "worker_disk_gb must be >= 8."
  }
}

variable "worker_disk_throughput" {
  description = "gp3 throughput (MB/s), 125-1000. Raise it for image-heavy builds; 125 is the free baseline. AWS also caps it at iops/4."
  type        = number
  default     = 125
  nullable    = false

  validation {
    condition     = var.worker_disk_throughput >= 125 && var.worker_disk_throughput <= 1000
    error_message = "worker_disk_throughput must be 125-1000 (gp3 limits)."
  }
}

variable "worker_disk_iops" {
  description = "gp3 IOPS, 3000-16000. 3000 is the free baseline. Must be at least 4x throughput."
  type        = number
  default     = 3000
  nullable    = false

  validation {
    condition     = var.worker_disk_iops >= 3000 && var.worker_disk_iops <= 16000
    error_message = "worker_disk_iops must be 3000-16000 (gp3 limits)."
  }
  validation {
    condition     = var.worker_disk_iops >= var.worker_disk_throughput * 4
    error_message = "gp3 requires iops >= throughput x 4; raise worker_disk_iops or lower worker_disk_throughput."
  }
}

variable "worker_user_data" {
  description = "Extra user_data for workers (runs after Docker setup when using the default AMI). Prefer baking things into an AMI instead - boot time is job latency here. Sensitive: user_data is readable via ec2:DescribeInstanceAttribute."
  type        = string
  default     = ""
  sensitive   = true
  nullable    = false
}

# ============================================================================
# MANAGER
# ============================================================================

variable "manager_instance_type" {
  description = "Manager size. It only orchestrates - a small burstable is plenty. t4g.* (Graviton) is cheaper; pair it with manager_ami_id or leave the AMI empty to auto-pick a matching one."
  type        = string
  default     = "t4g.small"
  nullable    = false
}

variable "manager_ami_id" {
  description = "AMI for the manager. Empty = latest Amazon Linux 2023 matching the manager instance type's architecture."
  type        = string
  default     = ""
  nullable    = false
}

variable "manager_self_heal" {
  description = "Run the manager in an ASG of exactly 1 so AWS replaces it automatically if the instance or AZ fails. The manager is stateless (the token lives in SSM), so replacement is seamless. Turning this off gives a plain instance whose failure pauses all CI."
  type        = bool
  default     = true
  nullable    = false
}

variable "manager_disk_gb" {
  description = "Manager root volume size."
  type        = number
  default     = 20
  nullable    = false
}

variable "gitlab_runner_version" {
  description = "gitlab-runner package version for the manager (e.g. \"17.9.0-1\"). Pinning is required unless allow_unpinned_artifacts = true - the manager re-runs its bootstrap on every replacement, so \"latest\" means the fleet's control plane can change under you without a code change."
  type        = string
  default     = ""
  nullable    = false

  validation {
    # this is interpolated into a package-manager command
    condition     = var.gitlab_runner_version == "" || can(regex("^[0-9][0-9a-zA-Z._~+-]*$", var.gitlab_runner_version))
    error_message = "gitlab_runner_version must be a package version string (no shell metacharacters)."
  }
  # `gitlab-runner fleeting install` landed in 16.11; an older pin bootstraps
  # most of the way and then dies at the plugin step.
  #
  # Nested ternaries, not `||`: Terraform < 1.10 evaluates BOTH operands of `||`,
  # so tonumber("") would throw on the empty-string case even though the
  # left-hand side already answered true.
  validation {
    condition = var.gitlab_runner_version == "" ? true : (
      try(tonumber(split(".", var.gitlab_runner_version)[0]), 0) > 16 ? true : (
        try(tonumber(split(".", var.gitlab_runner_version)[0]), 0) == 16
        ? try(tonumber(split(".", split("-", var.gitlab_runner_version)[0])[1]), 0) >= 11
        : false
      )
    )
    error_message = "gitlab_runner_version must be >= 16.11 (that's when `gitlab-runner fleeting install` was added)."
  }
}

variable "fleeting_plugin_version" {
  description = "AWS fleeting plugin version (e.g. \"1.1.0\"; see the plugin's releases page). This binary holds fleet-scaling and worker-SSH rights, so pinning is required unless allow_unpinned_artifacts = true."
  type        = string
  default     = ""
  nullable    = false

  validation {
    # this becomes part of the plugin reference in config.toml
    condition     = var.fleeting_plugin_version == "" || can(regex("^[0-9a-zA-Z._-]+$", var.fleeting_plugin_version))
    error_message = "fleeting_plugin_version must be a version string like \"1.1.0\" (or \"latest\")."
  }
}

variable "fleeting_plugin_sha256" {
  description = "Expected SHA-256 of the fleeting plugin binary. When set, the manager verifies it after install and refuses to start otherwise - closes the gap that `gitlab-runner fleeting install` pulls from a registry without integrity checking."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.fleeting_plugin_sha256 == "" || can(regex("^[a-fA-F0-9]{64}$", var.fleeting_plugin_sha256))
    error_message = "fleeting_plugin_sha256 must be a 64-character hex SHA-256 digest."
  }
}

variable "allow_unpinned_artifacts" {
  description = "Permit unpinned gitlab-runner / fleeting-plugin versions. Off by default on purpose: everything the manager fetches runs as root on every boot, so an unpinned upstream is a standing supply-chain exposure. Fine for a sandbox; deliberate opt-in for anything else."
  type        = bool
  default     = false
  nullable    = false

  # Both pinning checks live here rather than on the version variables themselves:
  # a validation on one referencing the other creates a dependency cycle.
  validation {
    condition     = var.allow_unpinned_artifacts || (var.gitlab_runner_version != "" && var.fleeting_plugin_version != "")
    error_message = "Pin gitlab_runner_version and fleeting_plugin_version, or set allow_unpinned_artifacts = true to accept fetching \"latest\" as root on every manager boot."
  }
  validation {
    condition     = var.allow_unpinned_artifacts || var.fleeting_plugin_version != "latest"
    error_message = "fleeting_plugin_version = \"latest\" requires allow_unpinned_artifacts = true - pin an exact version instead."
  }
}

variable "package_repo_script_url" {
  description = "URL of the gitlab-runner package-repo setup script. Override to point at an internal mirror you control, which is the better production answer than fetching from the public endpoint on every boot."
  type        = string
  default     = "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.rpm.sh"
  nullable    = false

  validation {
    # This value is interpolated into a root-context curl, so anchor the ENTIRE
    # string to URL-safe characters rather than just checking the scheme prefix.
    condition     = can(regex("^https://[A-Za-z0-9._~:/?#@!$&'()*+,;=%-]+$", var.package_repo_script_url))
    error_message = "package_repo_script_url must be an https:// URL containing only URL-safe characters (it is executed as root)."
  }
}

variable "worker_ready_command" {
  description = "Command the autoscaler runs on a new worker before sending it a job. Empty disables the check. The default waits for the Docker daemon - without it the plugin dispatches as soon as sshd answers, which on a cold worker is before Docker finishes installing."
  type        = string
  default     = "for i in $(seq 1 60); do docker info >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1"
  nullable    = false
}

# ============================================================================
# EXECUTOR (what jobs actually run in)
# ============================================================================

variable "docker_image" {
  description = "Default job image when .gitlab-ci.yml doesn't set one."
  type        = string
  default     = "docker:24.0"
  nullable    = false
}

variable "docker_privileged" {
  description = <<-EOT
    Run job containers privileged. OFF by default, and you should think hard before
    turning it on: a privileged container is a one-line escape to root on the worker
    VM, which means any job gets the worker's instance role and its network position.

    Docker-in-Docker image builds need it. If that's you, prefer a SEPARATE runner
    fleet for those jobs (its own tag, GitLab-protected, its own minimal IAM) rather
    than making every job on this fleet privileged. Rootless builders (BuildKit,
    Buildah) avoid the trade-off entirely.
  EOT
  type        = bool
  default     = false
  nullable    = false
}

variable "docker_volumes" {
  description = "Volumes mounted into every job container."
  type        = list(string)
  default     = ["/cache", "/certs/client"]
  nullable    = false
}

variable "runner_environment" {
  description = "Extra environment variables injected into every job (e.g. [\"DOCKER_DRIVER=overlay2\"]). Marked sensitive because this is a natural place to put a credential - and anything here reaches the launch template's user_data, which is readable by any principal with ec2:DescribeInstanceAttribute."
  type        = list(string)
  default     = []
  sensitive   = true
  nullable    = false
}

# ============================================================================
# SECURITY / HARDENING
# ============================================================================

variable "imds_hop_limit" {
  description = "IMDSv2 hop limit on workers. 1 (default) stops job CONTAINERS from reaching instance metadata and stealing the instance role - keep it there unless jobs genuinely need instance credentials."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.imds_hop_limit >= 1 && var.imds_hop_limit <= 64
    error_message = "imds_hop_limit must be 1-64."
  }
}

variable "manager_to_worker_ssh" {
  description = "Open TCP 22 on workers to the MANAGER's security group only. Required today: the AWS fleeting plugin connects over SSH with an ephemeral EC2 Instance Connect key (SSM tunnelling isn't supported upstream yet). Flip to false the day it is."
  type        = bool
  default     = true
  nullable    = false
}

variable "worker_egress_cidrs" {
  description = <<-EOT
    Where workers may reach on 443. The default is the public internet with RFC1918
    carved OUT - because "0.0.0.0/0" is not "the internet": it also covers 10/8,
    172.16/12, 192.168/16 and everything reachable through your peers and transit
    gateways, on exactly the port your internal ALBs, EKS API and interface
    endpoints listen on. CI jobs run attacker-influenceable code; don't hand them a
    trusted internal source address by default.

    Narrow it further to an allow-list or an egress proxy if you can. Set it back to
    ["0.0.0.0/0"] only if jobs genuinely need to call internal services.
  EOT
  type        = list(string)
  default = [
    "0.0.0.0/5", "8.0.0.0/7", "11.0.0.0/8", "12.0.0.0/6", "16.0.0.0/4",
    "32.0.0.0/3", "64.0.0.0/2", "128.0.0.0/3", "160.0.0.0/5", "168.0.0.0/6",
    "172.0.0.0/12", "172.32.0.0/11", "172.64.0.0/10", "172.128.0.0/9",
    "173.0.0.0/8", "174.0.0.0/7", "176.0.0.0/4", "192.0.0.0/9",
    "192.128.0.0/11", "192.160.0.0/13", "192.169.0.0/16", "192.170.0.0/15",
    "192.172.0.0/14", "192.176.0.0/12", "192.192.0.0/10", "193.0.0.0/8",
    "194.0.0.0/7", "196.0.0.0/6", "200.0.0.0/5", "208.0.0.0/4",
  ]
  nullable = false

  validation {
    condition     = length(var.worker_egress_cidrs) > 0
    error_message = "worker_egress_cidrs must not be empty (workers need to reach GitLab and registries)."
  }
  validation {
    condition     = alltrue([for c in var.worker_egress_cidrs : can(cidrhost(c, 0))])
    error_message = "worker_egress_cidrs entries must be valid CIDR blocks."
  }
}

variable "worker_extra_egress_rules" {
  description = <<-EOT
    Additional egress rules for workers, beyond 443 + DNS/NTP. Needed more often
    than you'd think: an internal registry on 5000, a proxy on 3128, apt over 80,
    a package mirror on 8080.

      [{ protocol = "tcp", port = 5000, cidrs = ["10.0.0.0/8"] }]
  EOT
  type = list(object({
    protocol = optional(string, "tcp")
    port     = number
    cidrs    = list(string)
  }))
  default  = []
  nullable = false

  validation {
    condition     = alltrue([for r in var.worker_extra_egress_rules : contains(["tcp", "udp"], r.protocol)])
    error_message = "worker_extra_egress_rules[*].protocol must be tcp or udp."
  }
  validation {
    condition     = alltrue([for r in var.worker_extra_egress_rules : r.port >= 1 && r.port <= 65535])
    error_message = "worker_extra_egress_rules[*].port must be 1-65535."
  }
  validation {
    condition     = alltrue([for r in var.worker_extra_egress_rules : length(r.cidrs) > 0])
    error_message = "worker_extra_egress_rules[*].cidrs must be non-empty."
  }
}

variable "manager_egress_cidrs" {
  description = "Where the manager may reach on 443 (GitLab + the AWS APIs it drives the fleet with). Narrow it to your GitLab and AWS endpoint ranges, or front it with a proxy."
  type        = list(string)
  default     = ["0.0.0.0/0"]
  nullable    = false

  validation {
    condition     = length(var.manager_egress_cidrs) > 0
    error_message = "manager_egress_cidrs must not be empty."
  }
}

variable "dns_egress_cidrs" {
  description = "Where DNS (and NTP) queries may go. Defaults to the VPC - the Amazon-provided resolver lives at VPC base + 2 and, like everything else, is subject to security-group egress rules. Without this nothing in the fleet can resolve a hostname, so nothing can bootstrap. Set to your resolver's CIDR if you use custom DNS."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "assign_public_ips" {
  description = "Assign public IPs to instances. Off by default and it should stay off - the fleet needs no inbound access, and a public IP on a machine running untrusted CI code is a gift. Leave false and use NAT or VPC endpoints for egress."
  type        = bool
  default     = false
  nullable    = false
}

variable "additional_worker_policy_arns" {
  description = "Extra IAM policies for the WORKER role - this is how jobs get AWS permissions (e.g. ECR pull, S3 cache)."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "additional_manager_policy_arns" {
  description = "Extra IAM policies for the MANAGER role."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for both created roles. Many orgs require one on every role."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.permissions_boundary_arn == "" || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:policy/", var.permissions_boundary_arn))
    error_message = "permissions_boundary_arn must be an IAM policy ARN."
  }
}

variable "force_delete_workers" {
  description = <<-EOT
    Let Terraform delete the worker ASG without waiting for instances to drain.

    Why this exists: workers are scale-in protected, and a protected instance
    blocks ASG deletion - so `terraform destroy` wedges while any job is running.
    Leave false in production (you don't want an apply killing live jobs); set it
    true for ephemeral/test fleets, or run the drain in the README first.
  EOT
  type        = bool
  default     = false
  nullable    = false
}

variable "detailed_monitoring" {
  description = "EC2 detailed (1-minute) monitoring. Off by default - it costs per instance and the fleet churns."
  type        = bool
  default     = false
  nullable    = false
}

# ============================================================================
# OBSERVABILITY - without this you find out CI is broken from a developer
# ============================================================================

variable "create_alarms" {
  description = "Create CloudWatch alarms for the failures that would otherwise be invisible: the manager going unhealthy, and the bootstrap failing (an EC2 health check only sees the hypervisor, so a manager whose gitlab-runner never started looks perfectly healthy forever)."
  type        = bool
  default     = true
  nullable    = false
}

variable "alarm_sns_topic_arns" {
  description = "SNS topics to notify on alarm. Empty means the alarms still exist and show state in the console, but nobody gets paged - wire a topic in production."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "log_retention_days" {
  description = "Retention for the manager's shipped logs (bootstrap + gitlab-runner journal). 0 disables log shipping entirely, which also removes your only forensic trail after an incident."
  type        = number
  default     = 30
  nullable    = false

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be 0 (off) or a value CloudWatch Logs accepts (1,3,5,7,14,30,60,90,...)."
  }
}

variable "worker_max_lifetime_seconds" {
  description = <<-EOT
    Hard ceiling on how long a worker may live. 0 disables; AWS requires >= 86400
    when set.

    IMPORTANT - read before relying on this: ASG-initiated replacement respects
    scale-in protection, and every worker in this fleet is protected. So this does
    NOT rotate the case you might expect it to - orphaned protected workers left
    behind by a dead manager are exactly what it cannot reclaim. It bounds the
    lifetime of UNPROTECTED instances only.

    For the orphan case, use the runner-orphaned-workers alarm this module creates
    and clear protection explicitly:
      aws autoscaling set-instance-protection --auto-scaling-group-name <asg> \
        --instance-ids <ids> --no-protected-from-scale-in
  EOT
  type        = number
  default     = 604800 # 7 days
  nullable    = false

  validation {
    condition     = var.worker_max_lifetime_seconds == 0 || var.worker_max_lifetime_seconds >= 86400
    error_message = "worker_max_lifetime_seconds must be 0 (disabled) or at least 86400 (AWS minimum)."
  }
}

variable "manager_instance_refresh" {
  description = "Automatically replace the running manager when its launch template changes. Off by default: a replacement kills every in-flight job, and with an unpinned AMI an unrelated `apply` can trigger one. Pin manager_ami_id before turning this on."
  type        = bool
  default     = false
  nullable    = false
}

variable "extra_runner_config_toml" {
  description = <<-EOT
    Raw TOML for anything the module doesn't model (S3 distributed cache, feature
    flags, custom docker settings). You own the correctness of what you put here.

    SCOPE: appended at the END of the file, so a table header is an ABSOLUTE path -
    "[runners.cache]" attaches to the runner. You MUST start with a table header;
    validation enforces it. A bare key would otherwise bind to whichever table was
    opened last (the final autoscaling policy) and silently corrupt it, and a
    top-level emission isn't an option either - "[runners.cache]" before
    "[[runners]]" is invalid TOML, because it makes `runners` a table and then the
    array-of-tables collides with it.

    Sensitive: cache credentials and similar commonly live here, and this reaches
    user_data, which is readable via ec2:DescribeInstanceAttribute.
  EOT
  type        = string
  default     = ""
  sensitive   = true
  nullable    = false

  validation {
    # Belt-and-braces: the bootstrap heredoc delimiter is name-derived and
    # unguessable, but reject the obvious literal anyway.
    condition     = !can(regex("(?m)^\\s*TFCFG_", var.extra_runner_config_toml))
    error_message = "extra_runner_config_toml must not contain a line starting with \"TFCFG_\" (that's the bootstrap heredoc delimiter prefix)."
  }
  # This is what removes the bare-key trap entirely: the first meaningful line
  # must open a table, so nothing can bind to the previous one by accident.
  validation {
    condition = var.extra_runner_config_toml == "" ? true : can(regex(
      "^\\s*(#[^\n]*\n|\\s*\n)*\\s*\\[", var.extra_runner_config_toml
    ))
    error_message = "extra_runner_config_toml must begin with a TOML table header (e.g. \"[runners.cache]\"). A bare key would attach to the last table in the generated config and silently corrupt it."
  }
}

variable "allowed_images" {
  description = "Glob allow-list for job images (e.g. [\"my-registry.example.com/ci/*\"]). Empty = any image. Without this a job picks its own image, so a pinned, scanned base image is unenforceable."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "allowed_services" {
  description = "Glob allow-list for job `services:` containers. Empty = any service. Worth setting alongside allowed_images - services run with the same privileges as the job."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "package_repo_script_sha256" {
  description = "SHA-256 of the gitlab-runner package-repo setup script. When set the manager verifies it before executing; without it the script is executed as root unverified."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.package_repo_script_sha256 == "" || can(regex("^[a-fA-F0-9]{64}$", var.package_repo_script_sha256))
    error_message = "package_repo_script_sha256 must be a 64-character hex SHA-256 digest."
  }
}

variable "metrics_listen_address" {
  description = "Where gitlab-runner exposes Prometheus metrics. Loopback keeps it private but means only an on-host agent can scrape it; bind to the private IP if you scrape from elsewhere."
  type        = string
  default     = "127.0.0.1:9252"
  nullable    = false
}

variable "s3_endpoint_policy_json" {
  description = "Policy for the S3 gateway endpoint (only used with create_vpc_endpoints). Empty means full S3 access, which quietly bypasses the 443 egress restrictions - scope it to the buckets your jobs and AMI actually need."
  type        = string
  default     = ""
  nullable    = false
}

variable "endpoint_private_dns" {
  description = "Enable private DNS on the interface endpoints. NOTE: this rewrites resolution of ssm/ssmmessages/ec2messages for the ENTIRE VPC, including instances outside this fleet whose security groups can't reach the endpoints - they would lose SSM. Set false if you don't own the VPC."
  type        = bool
  default     = true
  nullable    = false
}

variable "vpc_endpoint_services" {
  description = "Interface endpoints to create. The default covers the SSM agent; add \"ec2\", \"autoscaling\", \"cloudwatch\", \"logs\", \"sts\" if you want the module's own control plane off NAT too (each carries an hourly cost per AZ)."
  type        = list(string)
  default     = ["ssm", "ssmmessages", "ec2messages"]
  nullable    = false
}
