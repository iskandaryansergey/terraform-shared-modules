# Every variable here is nullable = false, and every variable that reaches a
# shell, a generated config file, or an AWS API carries a validation (R9).
#
# Two conventions worth knowing before you read further:
#
#   - Validations use nested ternaries or can(), never `x == "" || f(x)`, because
#     Terraform 1.9 evaluates both operands of || (R3). If you add one, test it
#     on 1.9.8, not just on current.
#
#   - There is deliberately NO raw-text escape hatch for config.toml or
#     fargate.toml (R1.4). The sibling EC2 module has one and it produced a new
#     finding in three consecutive audits, ending in root job execution on the
#     manager. Configuration is extended here by adding a typed input, which
#     costs a few lines and cannot be turned into a shell.

variable "create" {
  description = "Master switch. false plans and applies cleanly to nothing, which is what makes the offline template tests possible."
  type        = bool
  default     = true
  nullable    = false
}

variable "name" {
  description = "Fleet name. Prefixes every resource, so it is also the multi-fleet isolation boundary."
  type        = string
  nullable    = false

  validation {
    # 32 is not arbitrary. The binding constraint is EventBridge's 64-char rule
    # name: "${name}-runner-spot-interruption" is 58 chars at a 32-char name. The
    # CloudWatch alarm limit (255) and the IAM role limit (64) are both looser.
    condition     = can(regex("^[a-z][a-z0-9-]{1,31}$", var.name))
    error_message = "name must be 2-32 chars, lowercase alphanumeric or hyphen, starting with a letter."
  }
}

variable "tags" {
  description = "Tags applied to everything this module creates."
  type        = map(string)
  default     = {}
  nullable    = false

  validation {
    # Reaches every ECS, IAM, EC2 and CloudWatch call this module makes, so it is
    # an API-bound input and gets validated like one (R9).
    condition = alltrue([
      for k, v in var.tags :
      length(k) <= 128 && length(v) <= 256 && !startswith(lower(k), "aws:")
    ])
    error_message = "tags keys must be <= 128 chars, values <= 256 chars, and no key may use the reserved \"aws:\" prefix."
  }
}

# ---------------------------------------------------------------------------
# GitLab
# ---------------------------------------------------------------------------

variable "gitlab_url" {
  description = "GitLab instance URL, e.g. https://gitlab.com. A trailing slash is optional."
  type        = string
  default     = "https://gitlab.com"
  nullable    = false

  validation {
    # A POSITIVE grammar, not [^/]+. The sibling module used a negative class and
    # it accepted an embedded newline, userinfo (user:pass@host, which defeats
    # host parsing), and rejected legitimate subpath installs. This accepts a
    # host, an optional port, and an optional path prefix - and nothing else.
    condition = can(regex(
      "^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$",
      var.gitlab_url
    ))
    error_message = "gitlab_url must be https:// followed by a hostname, an optional :port, and an optional path prefix. No userinfo, no whitespace, no newlines."
  }
}

variable "runner_token_secret_arn" {
  description = <<-EOT
    ARN of a Secrets Manager secret holding the GitLab runner AUTHENTICATION token
    (the glrt- prefixed kind). This is the only way to supply the token, on purpose.

    There is no `runner_token` string input. Accepting one would put the token in
    Terraform state in cleartext, and in the sibling module that convenient path is
    the one both quick-starts and CI ended up using (R7). Here the safe path is the
    only path.

    The token reaches the container via the task definition's `secrets` block, so
    the task definition stores only this ARN. That matters: values in
    `environment` are readable by anyone holding ecs:DescribeTaskDefinition, which
    AWS does not allow you to scope to a single task definition.

    Create the runner in the GitLab UI or via POST /user/runners first - the
    registration-token workflow is deprecated and admins can disable it.

    Rotating the secret requires a new task launch: the value is resolved once, at
    task start. Set manager_force_new_deployment = true, or change
    manager_task_revision_trigger, to roll the manager onto the new value.
  EOT
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+$", var.runner_token_secret_arn))
    error_message = "runner_token_secret_arn must be a Secrets Manager secret ARN."
  }
}

variable "runner_token_kms_key_arn" {
  description = "CMK that encrypts runner_token_secret_arn. Empty means the AWS-managed key, which needs no extra grant. Supply this only for a customer-managed key - kms:Decrypt is added to the execution role only when it is set."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.runner_token_kms_key_arn == "" ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", var.runner_token_kms_key_arn))
    error_message = "runner_token_kms_key_arn must be a KMS key ARN, or empty for the AWS-managed key."
  }
}

# ---------------------------------------------------------------------------
# Network. BYO, as everywhere in this repo - no VPC, subnets or NAT here.
# ---------------------------------------------------------------------------

variable "vpc_id" {
  description = "VPC the manager and job tasks run in. They must share a VPC: the driver connects to the job task's private IPv4."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id))
    error_message = "vpc_id must be a vpc-* identifier."
  }
}

variable "manager_subnet_ids" {
  description = <<-EOT
    Private subnets for the manager task. Needs a NAT gateway or an egress proxy:
    the manager polls GitLab over the internet and no VPC endpoint can reach
    gitlab.com. PrivateLink only reaches AWS services.
  EOT
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.manager_subnet_ids) >= 1 && length(var.manager_subnet_ids) <= 16
    error_message = "manager_subnet_ids must contain 1-16 subnets (awsvpc caps networkConfiguration at 16)."
  }

  validation {
    condition     = alltrue([for s in var.manager_subnet_ids : can(regex("^subnet-[0-9a-f]{8,17}$", s))])
    error_message = "manager_subnet_ids entries must be subnet-* identifiers."
  }
}

variable "job_subnet_ids" {
  description = <<-EOT
    Private subnets for job tasks. Prefer subnets that hold nothing else.

    This is a security boundary, not a preference. The Fargate driver calls
    ssh.InsecureIgnoreHostKey() - it does NOT verify the job task's SSH host key.
    Anything that can occupy the resolved private IP on port 22 before the real
    task receives the manager's SSH session, which carries the generated build
    script and with it CI_JOB_TOKEN and every job variable. Dedicated subnets plus
    the SG-to-SG rule this module creates are what contain that.
  EOT
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.job_subnet_ids) >= 1 && length(var.job_subnet_ids) <= 16
    error_message = "job_subnet_ids must contain 1-16 subnets (awsvpc caps networkConfiguration at 16)."
  }

  validation {
    condition     = alltrue([for s in var.job_subnet_ids : can(regex("^subnet-[0-9a-f]{8,17}$", s))])
    error_message = "job_subnet_ids entries must be subnet-* identifiers."
  }
}

variable "manager_egress_cidrs" {
  description = <<-EOT
    Where the manager may reach on 443, IN ADDITION to on_prem_cidrs and the
    fleet's own VPC endpoints.

    Defaults to the internet because reaching gitlab.com requires it. In an
    isolated estate set this to [] and put your GitLab in on_prem_cidrs instead -
    the module will then grant no internet egress at all.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
  nullable    = false

  validation {
    condition     = alltrue([for c in var.manager_egress_cidrs : can(cidrhost(c, 0))])
    error_message = "manager_egress_cidrs entries must be valid CIDR blocks."
  }
}

variable "job_egress_cidrs" {
  description = <<-EOT
    Where job tasks may reach on 443.

    The default is the public internet with private space carved OUT, because
    "0.0.0.0/0" is not "the internet" - it also covers 10/8, 172.16/12,
    192.168/16, and 100.64/10, which is the standard EKS secondary-CIDR / pod
    range. Those are reachable through your peers and transit gateways, on exactly
    the port your internal ALBs, EKS API and interface endpoints listen on, from a
    trusted internal source address.

    Computed from job_egress_exclude_cidrs rather than written out as a literal
    list, so it stays auditable. The sibling module's hand-maintained 30-entry
    literal was correct for RFC1918 and silently missed CGNAT - nobody could check
    it by eye.

    Empty means "use the computed default"; set it to override completely.
  EOT
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for c in var.job_egress_cidrs : can(cidrhost(c, 0))])
    error_message = "job_egress_cidrs entries must be valid CIDR blocks."
  }
}

variable "job_egress_exclude_cidrs" {
  description = <<-EOT
    Ranges carved out of the computed job egress default. Only used when
    job_egress_cidrs is empty.

    These four are chosen against a specific threat: address space that is
    reachable from this subnet through VPC peering, a transit gateway, or a
    Direct Connect, on the port your internal ALBs and interface endpoints
    listen on. That is what makes "0.0.0.0/0" dangerous, and it is what this
    list removes.

    Two ranges are DELIBERATELY not excluded, and it matters on this platform:

      169.254.0.0/16  link-local. Present here is INERT either way, and the
                      earlier claim that it was "load-bearing" was wrong twice
                      over: every rule in this set is TCP/443, while the ECS task
                      metadata and credential endpoint is HTTP on port 80 - and
                      security groups do not filter link-local traffic at all.
                      Kept out of the exclusion list only because excluding it
                      would spend a rule to change nothing.
      127.0.0.0/8     loopback. Egress rules never affect loopback traffic, so
                      excluding it costs a rule and buys nothing.

    Changing this list changes the rule count. See the note on the 60-rule
    security-group quota in the README before adding entries.
  EOT
  type        = list(string)
  default = [
    "10.0.0.0/8",     # RFC1918
    "172.16.0.0/12",  # RFC1918
    "192.168.0.0/16", # RFC1918
    "100.64.0.0/10",  # RFC6598 CGNAT - EKS pod CIDRs, TGW designs, Fargate itself
    "224.0.0.0/3",    # multicast + reserved; nothing in CI should dial these
  ]
  nullable = false

  validation {
    condition     = alltrue([for c in var.job_egress_exclude_cidrs : can(cidrhost(c, 0))])
    error_message = "job_egress_exclude_cidrs entries must be valid CIDR blocks."
  }
}

variable "job_extra_egress_rules" {
  description = <<-EOT
    Extra egress for job tasks - internal registries, package mirrors, artifact stores.

    Keyed by content, not by list position, so reordering this list is a no-op
    rather than destroying and recreating every rule. Duplicate entries collapse
    instead of crashing.
  EOT
  type = list(object({
    protocol    = string
    port        = number
    cidrs       = list(string)
    description = optional(string, "")
  }))
  default  = []
  nullable = false

  validation {
    condition     = alltrue([for r in var.job_extra_egress_rules : contains(["tcp", "udp"], r.protocol)])
    error_message = "job_extra_egress_rules[*].protocol must be tcp or udp."
  }

  validation {
    condition     = alltrue([for r in var.job_extra_egress_rules : r.port >= 1 && r.port <= 65535 && floor(r.port) == r.port])
    error_message = "job_extra_egress_rules[*].port must be an integer in 1-65535."
  }

  validation {
    condition = alltrue([
      for r in var.job_extra_egress_rules : alltrue([for c in r.cidrs : can(cidrhost(c, 0))])
    ])
    error_message = "job_extra_egress_rules[*].cidrs entries must be valid CIDR blocks."
  }

  validation {
    condition     = alltrue([for r in var.job_extra_egress_rules : length(r.cidrs) > 0])
    error_message = "job_extra_egress_rules[*].cidrs must be non-empty."
  }
}

variable "create_vpc_endpoints" {
  description = <<-EOT
    Create the interface and gateway endpoints Fargate needs to pull images from a
    private ECR without traversing NAT.

    This does NOT remove the NAT requirement - the manager still has to reach
    gitlab.com. It reduces NAT data processing on image pulls, which is where the
    volume is.

    Partial endpoint sets fail SILENTLY: AWS routes to the public endpoint instead,
    which in a NAT-free subnet is a hang rather than an error. So this flag creates
    the whole set that Fargate platform 1.4.0+ requires (ecr.api, ecr.dkr, and the
    S3 GATEWAY endpoint - ECR stores layers in S3) or none of it.
  EOT
  type        = bool
  default     = false
  nullable    = false
}

variable "endpoint_private_dns" {
  description = <<-EOT
    Enable private DNS on the interface endpoints.

    Defaults to FALSE, unlike the AWS console. Enabling it rewrites resolution of
    those service names for the ENTIRE VPC, including instances outside this fleet
    whose security groups cannot reach the endpoints - they lose access silently.
    This module does not own the VPC, so it does not default to a VPC-wide change
    (R5: a control whose blast radius exceeds the module's ownership is not a
    control, it is a liability).

    Set true only when you own the VPC.
  EOT
  type        = bool
  default     = false
  nullable    = false
}

# ---------------------------------------------------------------------------
# Isolated / air-gapped operation
#
# The default shape of this module assumes GitLab is on the internet and the
# fleet reaches it through a NAT gateway. A fully isolated estate inverts that:
# GitLab is on-prem, reached over Direct Connect or VPN through RFC1918, and
# every AWS API must be reached through a VPC endpoint because there is no
# internet path at all.
#
# That is not a tuning difference. It changes which egress rules are correct,
# which endpoints are mandatory, and it makes the private-CA path load-bearing.
# So it is one explicit input rather than six subtle ones a caller has to get
# individually right.
# ---------------------------------------------------------------------------

variable "isolated" {
  description = <<-EOT
    Declare that this fleet has NO internet path - GitLab is reached over
    Direct Connect or VPN, and all AWS APIs are reached through VPC endpoints.

    Setting this changes required behaviour, and the module enforces the
    consequences rather than leaving them to you:

      - VPC endpoints must be reachable: either create_vpc_endpoints = true, or
        existing_endpoint_security_group_ids naming endpoints your platform team
        already owns. The module does not create VPCs, subnets, routing or NAT.
        README.md lists exactly which endpoint services are required - a missing
        one is a silent hang, because the agent falls back to the public DNS name
        and there is no route to it.
      - If the module DOES create them, endpoint_private_dns must be true. An
        interface endpoint with private DNS disabled serves only endpoint-specific
        names, and nothing redirects the ECS agent to them, so it resolves the
        public name and hangs - billed and useless.
      - gitlab_url must NOT be gitlab.com, and the on-prem GitLab CIDR must be
        reachable, so on_prem_cidrs is required.
      - job_egress_cidrs must be set explicitly. The built-in default carves RFC1918
        OUT, which would block `git clone` from an on-prem GitLab - the default is
        correct for an internet-facing fleet and wrong for yours.

    Leave false for an internet-facing fleet.
  EOT
  type        = bool
  default     = false
  nullable    = false
}

variable "on_prem_cidrs" {
  description = <<-EOT
    CIDRs reachable over Direct Connect or VPN that the fleet must talk to:
    the on-prem GitLab, internal container registries, package mirrors, artifact
    stores, internal CAs.

    Both tiers get TCP 443 to these. The manager needs GitLab; job tasks need it
    too, for `git clone` and artifact upload.

    Required when isolated = true. Keep it as narrow as your estate allows - this
    is the one place the module deliberately grants job tasks access to internal
    address space, so it is worth being specific rather than passing a /8.
  EOT
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for c in var.on_prem_cidrs : can(cidrhost(c, 0))])
    error_message = "on_prem_cidrs entries must be valid CIDR blocks."
  }

  validation {
    condition     = length(var.on_prem_cidrs) <= 40
    error_message = "on_prem_cidrs is capped at 40 entries: each one costs a rule on BOTH security groups, against a default quota of 60 per group."
  }
}

variable "existing_endpoint_security_group_ids" {
  description = <<-EOT
    Security groups of VPC endpoints that ALREADY EXIST in your VPC - the normal
    case in a managed estate, where endpoints belong to the landing zone rather
    than to a workload module.

    Both tiers get TCP 443 to these, by security-group reference rather than by
    CIDR, so the rule stays correct if the endpoints' addresses change.

    Use this INSTEAD of create_vpc_endpoints when your platform team owns the
    endpoints. See the prerequisites section in README.md for the exact list of
    endpoint services this module requires - getting that list wrong is a silent
    hang, not an error, because a missing endpoint falls back to the public name
    and there is no route to it.
  EOT
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for s in var.existing_endpoint_security_group_ids : can(regex("^sg-[0-9a-f]{8,17}$", s))])
    error_message = "existing_endpoint_security_group_ids entries must be sg-* identifiers."
  }

  validation {
    condition     = length(var.existing_endpoint_security_group_ids) <= 5
    error_message = "existing_endpoint_security_group_ids is capped at 5 - each costs a rule on both security groups."
  }
}

variable "extra_endpoint_services" {
  description = <<-EOT
    Additional interface endpoint short names, e.g. ["sts", "monitoring", "events"].

    The module already provisions what it needs for its own operation. Use this for
    what YOUR jobs need - an isolated estate typically wants at least `sts` (for
    OIDC / AssumeRoleWithWebIdentity from CI) and `monitoring` if jobs publish
    metrics. Names are the part after "com.amazonaws.<region>.".
  EOT
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for s in var.extra_endpoint_services : can(regex("^[a-z0-9][a-z0-9.-]{1,60}$", s))])
    error_message = "extra_endpoint_services entries must be endpoint service short names, e.g. \"sts\" or \"elasticfilesystem\"."
  }
}

variable "runner_clone_url" {
  description = <<-EOT
    Overrides the URL the runner hands jobs for `git clone`. Empty means jobs clone
    from gitlab_url.

    Needed when GitLab's external URL is not reachable from the fleet's network -
    the common isolated-estate case where GitLab is published at
    https://gitlab.example.com externally but reachable at an internal address, or
    is behind a reverse proxy on a different host than the API.
  EOT
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition = var.runner_clone_url == "" ? true : can(regex(
      "^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$",
      var.runner_clone_url
    ))
    error_message = "runner_clone_url must be an http(s) URL with a hostname, optional port and optional path, or empty."
  }
}

variable "cache_server_side_encryption" {
  description = "Server-side encryption for cache objects: \"\" (bucket default), \"AES256\", or \"aws:kms\". A regulated estate usually needs aws:kms with a CMK."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = contains(["", "AES256", "aws:kms"], var.cache_server_side_encryption)
    error_message = "cache_server_side_encryption must be \"\", \"AES256\", or \"aws:kms\"."
  }
}

variable "cache_kms_key_arn" {
  description = "CMK for cache objects. Only used when cache_server_side_encryption = \"aws:kms\". The manager task role needs kms:GenerateDataKey and kms:Decrypt on it, which this module adds."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.cache_kms_key_arn == "" ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", var.cache_kms_key_arn))
    error_message = "cache_kms_key_arn must be a KMS key ARN, or empty."
  }
}

# ---------------------------------------------------------------------------
# Manager task
# ---------------------------------------------------------------------------

variable "manager_image" {
  description = <<-EOT
    Container image for the manager. Must contain BOTH gitlab-runner and the Fargate
    custom-executor driver binary - no official image ships both, so you build this.

    Pin by digest in production. The module will not stop you using a tag, but an
    unpinned tag means the control plane's image is whatever the registry serves at
    task launch, with no review and no rollback target.
  EOT
  type        = string
  nullable    = false

  validation {
    condition     = length(var.manager_image) > 0 && !can(regex("[[:space:]\"'`$;|&<>]", var.manager_image))
    error_message = "manager_image must be non-empty and free of whitespace and shell metacharacters."
  }
}

variable "manager_cpu" {
  description = "Manager task CPU units. Validated against Fargate's discrete CPU/memory table together with manager_memory."
  type        = number
  default     = 512
  nullable    = false

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096, 8192, 16384], var.manager_cpu)
    error_message = "manager_cpu must be one of 256, 512, 1024, 2048, 4096, 8192, 16384."
  }
}

variable "manager_memory" {
  description = "Manager task memory in MiB. Fargate only accepts specific CPU/memory pairs; the combination is validated in locals, where both values are visible."
  type        = number
  default     = 1024
  nullable    = false

  validation {
    condition     = var.manager_memory >= 512 && var.manager_memory <= 122880 && floor(var.manager_memory) == var.manager_memory
    error_message = "manager_memory must be an integer between 512 and 122880 MiB."
  }
}

variable "manager_concurrent" {
  description = <<-EOT
    Global cap on simultaneous jobs. One job is exactly one Fargate task, so this is
    also the peak task count and therefore the number that caps your spend.

    Note the real ceiling is usually the account's Fargate vCPU quota (frequently 6
    per Region on newer accounts, raised automatically over time), not this value.
    Read the applied quota; do not assume.
  EOT
  type        = number
  default     = 10
  nullable    = false

  validation {
    condition     = var.manager_concurrent >= 1 && var.manager_concurrent <= 1000 && floor(var.manager_concurrent) == var.manager_concurrent
    error_message = "manager_concurrent must be an integer in 1-1000. GitLab Runner rejects 0."
  }
}

variable "manager_request_concurrency" {
  description = "How many job requests the manager makes to GitLab in parallel. 1 is the upstream default and is fine until the fleet is large."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.manager_request_concurrency >= 1 && var.manager_request_concurrency <= 100 && floor(var.manager_request_concurrency) == var.manager_request_concurrency
    error_message = "manager_request_concurrency must be an integer in 1-100."
  }
}

variable "manager_check_interval" {
  description = "Seconds between job-request polls. 0 means the upstream default of 3."
  type        = number
  default     = 3
  nullable    = false

  validation {
    condition     = var.manager_check_interval >= 0 && var.manager_check_interval <= 3600 && floor(var.manager_check_interval) == var.manager_check_interval
    error_message = "manager_check_interval must be an integer in 0-3600."
  }
}

variable "manager_stop_timeout" {
  description = <<-EOT
    Seconds ECS waits after SIGTERM before SIGKILL. Fargate caps this at 120.

    This is a real limit, not a tuning knob: ECS sends SIGTERM, and gitlab-runner
    treats SIGTERM as "abort all running builds". The module's entrypoint traps it
    and forwards SIGQUIT (graceful: finish running builds, accept no new ones), but
    any job still running after 120 seconds dies on redeploy regardless. Plan
    deployments around that; it cannot be fixed from Terraform.
  EOT
  type        = number
  default     = 120
  nullable    = false

  validation {
    condition     = var.manager_stop_timeout >= 2 && var.manager_stop_timeout <= 120 && floor(var.manager_stop_timeout) == var.manager_stop_timeout
    error_message = "manager_stop_timeout must be an integer in 2-120. Fargate rejects anything above 120."
  }
}

variable "manager_metrics_listen_address" {
  description = <<-EOT
    host:port for gitlab-runner's Prometheus/health HTTP server.

    This is load-bearing, not optional telemetry. GitLab Runner starts that server
    ONLY when listen_address is set - its documented default is "not defined" - and
    the manager container's ECS health check probes it. If the two ever disagree,
    the health check fails, ECS replaces the task forever, and `terraform apply`
    blocks on wait_for_steady_state and then fails.

    So the health check command is DERIVED from this value rather than written
    separately (see locals.tf). They cannot drift.

    Loopback by default: only the in-container health check needs to reach it, and
    the manager security group has no inbound rules. Change to 0.0.0.0:<port> only
    if you add a scraping sidecar, and note the port then needs an ingress rule.
  EOT
  type        = string
  default     = "127.0.0.1:9252"
  nullable    = false

  validation {
    condition     = can(regex("^([0-9]{1,3}(\\.[0-9]{1,3}){3}|\\[[0-9a-fA-F:]+\\]):[0-9]{1,5}$", var.manager_metrics_listen_address))
    error_message = "manager_metrics_listen_address must be host:port with a literal IPv4 or bracketed IPv6 address, e.g. 127.0.0.1:9252."
  }
}

variable "manager_ca_certificate_pem" {
  description = "PEM CA bundle for a self-managed GitLab with a private CA. Mounted where the runner image's entrypoint looks for it, so no image rebuild is needed. Empty disables it."
  type        = string
  default     = ""
  nullable    = false
  sensitive   = false # a CA certificate is public by construction

  validation {
    condition     = var.manager_ca_certificate_pem == "" ? true : can(regex("-----BEGIN CERTIFICATE-----", var.manager_ca_certificate_pem))
    error_message = "manager_ca_certificate_pem must contain a PEM certificate block, or be empty."
  }
}

# ---------------------------------------------------------------------------
# Job tasks
# ---------------------------------------------------------------------------

variable "job_profiles" {
  description = <<-EOT
    Job task definitions, keyed by profile name. Each becomes one ECS task
    definition that a pipeline can select with the FARGATE_TASK_DEFINITION CI/CD
    variable.

    Read this before adding a profile:

    A project maintainer who can set a CI/CD variable can choose ANY profile
    defined here - CUSTOM_ENV_FARGATE_TASK_DEFINITION overrides the driver's
    configured task definition. The module's ecs:RunTask policy is scoped to
    exactly these task-definition ARNs and nothing else, and iam:PassRole is scoped
    to exactly the roles these profiles use. Those two lists are the containment
    boundary. So:

      - Never put a profile here whose task_role_arn you would not hand to any
        pipeline that can reach this runner.
      - For per-project AWS access, leave task_role_arn empty and use GitLab ID
        tokens with sts:AssumeRoleWithWebIdentity instead. The ci-oidc module in
        this repo does that. One shared task role is one blast radius for every
        project on the fleet.

    `image` must contain sshd, the gitlab-runner binary (not just the helper - the
    runner invokes its own subcommands for artifacts and cache), git, git-lfs,
    ca-certificates, and your toolchain. `image:` in .gitlab-ci.yml is IGNORED on
    this platform; this is where the image is chosen.

    No DinD: Fargate forbids privileged containers, so image builds need Kaniko or
    rootless BuildKit baked into this image.
  EOT
  type = map(object({
    image             = string
    cpu               = number
    memory            = number
    ephemeral_storage = optional(number, 0) # 0 = Fargate default of 20 GiB
    task_role_arn     = optional(string, "")
    environment       = optional(map(string), {})
    ssh_username      = optional(string, "root")
    health_check_cmd  = optional(list(string), [])
  }))
  nullable = false

  validation {
    condition     = length(var.job_profiles) >= 1
    error_message = "job_profiles must define at least one profile - a runner with no job task definition cannot run anything."
  }

  validation {
    condition     = alltrue([for k, _ in var.job_profiles : can(regex("^[a-z][a-z0-9-]{0,29}$", k))])
    error_message = "job_profiles keys must be 1-30 chars, lowercase alphanumeric or hyphen, starting with a letter."
  }

  validation {
    condition = alltrue([
      for _, p in var.job_profiles :
      length(p.image) > 0 && !can(regex("[[:space:]\"'`$;|&<>]", p.image))
    ])
    error_message = "job_profiles[*].image must be non-empty and free of whitespace and shell metacharacters."
  }

  validation {
    condition     = alltrue([for _, p in var.job_profiles : contains([256, 512, 1024, 2048, 4096, 8192, 16384], p.cpu)])
    error_message = "job_profiles[*].cpu must be one of 256, 512, 1024, 2048, 4096, 8192, 16384."
  }

  validation {
    condition = alltrue([
      for _, p in var.job_profiles :
      p.memory >= 512 && p.memory <= 122880 && floor(p.memory) == p.memory
    ])
    error_message = "job_profiles[*].memory must be an integer between 512 and 122880 MiB."
  }

  validation {
    # 20 GiB is the Fargate default and also the minimum, but the API only accepts
    # 21-200 when the field is set at all - you can expand, never shrink. 0 means
    # "omit the block".
    condition = alltrue([
      for _, p in var.job_profiles :
      p.ephemeral_storage == 0 || (p.ephemeral_storage >= 21 && p.ephemeral_storage <= 200 && floor(p.ephemeral_storage) == p.ephemeral_storage)
    ])
    error_message = "job_profiles[*].ephemeral_storage must be 0 (Fargate default 20 GiB) or an integer 21-200 GiB. The container image itself consumes this space."
  }

  validation {
    # A POSITIVE grammar with no wildcard. `role/.+` accepted `role/*`, which
    # became iam:PassRole on every role in the account - and the regression test
    # written to catch that used contains(list, "*"), an EXACT element match, so
    # it could not see a wildcard embedded in an ARN. Both are fixed.
    condition = alltrue([
      for _, p in var.job_profiles :
      p.task_role_arn == "" ? true : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_-]+(/[A-Za-z0-9+=,.@_-]+)*$", p.task_role_arn))
    ])
    error_message = "job_profiles[*].task_role_arn must be a concrete IAM role ARN with no wildcard, or empty (recommended - use GitLab OIDC instead). A wildcard here becomes iam:PassRole over every matching role in the account."
  }

  validation {
    # This lands in fargate.toml AND is the SSH user the driver authenticates as.
    condition = alltrue([
      for _, p in var.job_profiles :
      can(regex("^[a-z_][a-z0-9_-]{0,31}$", p.ssh_username))
    ])
    error_message = "job_profiles[*].ssh_username must be a valid POSIX username."
  }

  validation {
    # health_check_cmd IS shell. ECS runs CMD-SHELL through /bin/sh -c as root in
    # the job container. It is also part of the task definition body, which is
    # readable by anyone holding ecs:DescribeTaskDefinition - an action AWS does
    # not let you scope to a single task definition. So it is hazard-ranked the
    # same as `environment` (R9.1), which is validated nine lines below.
    condition = alltrue([
      for _, p in var.job_profiles :
      length(p.health_check_cmd) == 0 ? true : contains(["CMD", "CMD-SHELL"], p.health_check_cmd[0])
    ])
    error_message = "job_profiles[*].health_check_cmd, when set, must begin with \"CMD\" or \"CMD-SHELL\" - that is the ECS contract, and anything else is silently never executed."
  }

  validation {
    condition = alltrue([
      for _, p in var.job_profiles : alltrue([
        for e in p.health_check_cmd :
        !can(regex("(?i)(glpat-|glrt-|AKIA|-----BEGIN|ghp_|npm_|Bearer [A-Za-z0-9._-]{8,})", e))
      ])
    ])
    error_message = "job_profiles[*].health_check_cmd must not contain credential-shaped material. The task definition body is readable via ecs:DescribeTaskDefinition, which cannot be scoped per task definition."
  }

  validation {
    condition = alltrue([
      for _, p in var.job_profiles : length(join("", p.health_check_cmd)) <= 1024
    ])
    error_message = "job_profiles[*].health_check_cmd must total 1024 characters or fewer."
  }

  validation {
    # Job task environment is NOT a place for secrets: values in `environment` are
    # readable by anyone with ecs:DescribeTaskDefinition, which AWS does not let you
    # scope to one task definition. Hazard-ranked the same as user_data (R9).
    condition = alltrue([
      for _, p in var.job_profiles : alltrue([
        for k, _ in p.environment :
        !can(regex("(?i)(secret|token|password|passwd|credential|private_key|apikey|api_key)", k))
      ])
    ])
    error_message = "job_profiles[*].environment keys must not look secret-shaped. Task definition environment is readable via ecs:DescribeTaskDefinition, which cannot be scoped per task definition. Use GitLab CI/CD variables or OIDC instead."
  }
}

variable "default_job_profile" {
  description = <<-EOT
    Which job_profiles entry the driver uses when a pipeline does not select one.

    Empty means the alphabetically first key, which is deterministic but arbitrary
    - so if you have more than one profile, name the one you mean. Every job that
    does not set FARGATE_TASK_DEFINITION lands here, so this is the profile that
    defines your default cost and your default toolchain.
  EOT
  type        = string
  default     = ""
  nullable    = false

  validation {
    # Cross-variable reference (a 1.9 feature, hence the required_version floor).
    # Both operands are safe under 1.9's eager || : contains() on a key list
    # cannot throw, so there is no lazy-evaluation dependency here (R3).
    condition     = var.default_job_profile == "" || contains(keys(var.job_profiles), var.default_job_profile)
    error_message = "default_job_profile must be empty or a key of job_profiles. Naming a profile that does not exist would silently point the driver at a task definition the manager has no permission to run."
  }
}

variable "job_task_wait_max_attempts" {
  description = "Driver waiter attempts for a job task to reach RUNNING. Multiplied by job_task_wait_interval this is the ceiling before the job fails."
  type        = number
  default     = 100
  nullable    = false

  validation {
    condition     = var.job_task_wait_max_attempts >= 1 && var.job_task_wait_max_attempts <= 1000 && floor(var.job_task_wait_max_attempts) == var.job_task_wait_max_attempts
    error_message = "job_task_wait_max_attempts must be an integer in 1-1000."
  }
}

variable "job_task_wait_interval" {
  description = "Seconds between waiter attempts. Keep the product with job_task_wait_max_attempts comfortably above your worst-case image pull - billing starts at image pull, not at RUNNING."
  type        = number
  default     = 6
  nullable    = false

  validation {
    condition     = var.job_task_wait_interval >= 1 && var.job_task_wait_interval <= 60 && floor(var.job_task_wait_interval) == var.job_task_wait_interval
    error_message = "job_task_wait_interval must be an integer in 1-60."
  }

  validation {
    # attempts x interval is the only meaningful quantity, and validating the two
    # independently let a 1-second ceiling through. A cold Fargate task needs tens
    # of seconds to reach RUNNING - RunTask, ENI attach, then the image pull, which
    # is also when billing starts - so any product below ~120s fails every job
    # after paying for it.
    condition     = var.job_task_wait_max_attempts * var.job_task_wait_interval >= 120
    error_message = "job_task_wait_max_attempts * job_task_wait_interval must be at least 120 seconds. A cold Fargate task needs tens of seconds just to pull its image, and billing starts at the pull."
  }
}

variable "job_enable_execute_command" {
  description = <<-EOT
    Enable ECS Exec on job tasks. Defaults to false and should stay false.

    It runs commands as root in a container executing untrusted CI code, forces a
    task role to exist, requires the ssmmessages endpoint, and is incompatible with
    a read-only root filesystem. The driver's own documentation recommends against
    leaving it on.
  EOT
  type        = bool
  default     = false
  nullable    = false
}

# ---------------------------------------------------------------------------
# Capacity and cost
# ---------------------------------------------------------------------------

variable "capacity_provider_strategy" {
  description = <<-EOT
    Cluster default capacity provider strategy, as a map of provider name to weight,
    optionally with a base.

    This is the ONLY way to get Fargate Spot with this driver. The driver sets
    neither launchType nor capacityProviderStrategy on RunTask, so ECS falls back to
    the cluster's default - which means Spot is a cluster-wide property, not a
    per-job one. To offer both, run two fleets with different clusters.

    Spot semantics for CI: a two-minute SIGTERM warning, then the task is stopped
    with stopCode SpotInterruption. The job dies mid-run. Pair it with `retry:` in
    .gitlab-ci.yml and make jobs idempotent, or don't use Spot.
  EOT
  type = list(object({
    capacity_provider = string
    weight            = number
    base              = optional(number, 0)
  }))
  default  = [{ capacity_provider = "FARGATE", weight = 1 }]
  nullable = false

  validation {
    condition     = length(var.capacity_provider_strategy) >= 1
    error_message = "capacity_provider_strategy must contain at least one entry."
  }

  validation {
    condition = alltrue([
      for s in var.capacity_provider_strategy : contains(["FARGATE", "FARGATE_SPOT"], s.capacity_provider)
    ])
    error_message = "capacity_provider_strategy[*].capacity_provider must be FARGATE or FARGATE_SPOT."
  }

  validation {
    condition = alltrue([
      for s in var.capacity_provider_strategy :
      s.weight >= 0 && s.weight <= 1000 && floor(s.weight) == s.weight && s.base >= 0 && floor(s.base) == s.base
    ])
    error_message = "capacity_provider_strategy weights and bases must be non-negative integers (weight <= 1000)."
  }

  validation {
    # A strategy whose weights all sum to zero cannot place a task. ECS accepts
    # the shape and then fails at RunTask.
    condition     = length([for s in var.capacity_provider_strategy : s if s.weight > 0]) >= 1
    error_message = "capacity_provider_strategy must contain at least one entry with weight > 0, or no task can ever be placed."
  }

  validation {
    # ECS permits base > 0 on at most one provider in a strategy.
    condition     = length([for s in var.capacity_provider_strategy : s if s.base > 0]) <= 1
    error_message = "capacity_provider_strategy may set base > 0 on at most one provider - ECS rejects more than one."
  }

  validation {
    condition     = length(distinct([for s in var.capacity_provider_strategy : s.capacity_provider])) == length(var.capacity_provider_strategy)
    error_message = "capacity_provider_strategy must not name the same capacity provider twice."
  }
}

variable "manager_use_spot" {
  description = "Run the MANAGER on Fargate Spot. Defaults to false and should stay false: a Spot interruption on the manager aborts every in-flight job on the fleet, and the manager is a tiny fraction of the bill."
  type        = bool
  default     = false
  nullable    = false
}

# ---------------------------------------------------------------------------
# Distributed cache. Not optional in practice: job tasks are ephemeral, so
# cache_dir alone does nothing across jobs.
# ---------------------------------------------------------------------------

variable "manager_force_new_deployment" {
  description = <<-EOT
    Force a new manager deployment on every apply.

    This exists because the runner token is resolved from Secrets Manager once, at
    task start. Changing the secret's VALUE produces no Terraform diff, so a
    rotated token is not picked up until something else replaces the task. Set this
    true for one apply after rotating, or leave it true if you would rather every
    apply roll the manager.

    Note the manager is a singleton deployed 0/100, so a roll means a short gap
    with no manager and in-flight jobs longer than manager_stop_timeout are lost.
  EOT
  type        = bool
  default     = false
  nullable    = false
}

variable "manager_task_revision_trigger" {
  description = <<-EOT
    Opaque string mixed into the manager task definition. Changing it produces a
    new revision and therefore a new task, which is the other way to pick up a
    rotated runner token.

    Free-form on purpose - it never reaches a shell or a config file, only a task
    definition tag - so a timestamp or a ticket id is fine.
  EOT
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = length(var.manager_task_revision_trigger) <= 256
    error_message = "manager_task_revision_trigger must be 256 characters or fewer."
  }
}

variable "cache_bucket_region" {
  description = "Region of cache_bucket_name. Empty means the fleet's own region. Set this when several regional fleets share one cache bucket - pre-signed URLs against the wrong region fail with PermanentRedirect."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.cache_bucket_region == "" ? true : can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.cache_bucket_region))
    error_message = "cache_bucket_region must be an AWS region name, or empty for the fleet's region."
  }
}

variable "job_max_lifetime_seconds" {
  description = <<-EOT
    Advisory ceiling on how long a job task may run, surfaced in
    output.verify_commands.orphans so an operator can find strays.

    Why this exists: the manager is the only thing that calls StopTask, and it is a
    singleton that is designed to be replaced. A job task whose manager died mid-job
    keeps sshd alive with no client and BILLS until something stops it. Fargate has
    no task-level TTL, so the module cannot enforce this - it can only help you find
    them. 0 disables the output.
  EOT
  type        = number
  default     = 7200
  nullable    = false

  validation {
    condition     = var.job_max_lifetime_seconds >= 0 && var.job_max_lifetime_seconds <= 604800 && floor(var.job_max_lifetime_seconds) == var.job_max_lifetime_seconds
    error_message = "job_max_lifetime_seconds must be an integer in 0-604800."
  }
}

variable "cache_bucket_name" {
  description = "S3 bucket for the distributed cache. Empty disables caching entirely, which means every job re-downloads its dependencies. The module grants the MANAGER role access; job tasks need none, because the manager mints pre-signed URLs."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.cache_bucket_name == "" ? true : can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.cache_bucket_name))
    error_message = "cache_bucket_name must be a valid S3 bucket name, or empty."
  }
}

variable "cache_path" {
  description = "Key prefix inside cache_bucket_name. Lets several fleets share one bucket without colliding."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.cache_path == "" ? true : can(regex("^[A-Za-z0-9!_.*'()/-]{1,512}$", var.cache_path))
    error_message = "cache_path must be a safe S3 key prefix (no whitespace, no shell metacharacters)."
  }
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------

variable "permissions_boundary_arn" {
  description = "Permissions boundary applied to every role this module creates. Empty means none."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.permissions_boundary_arn == "" ? true : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:policy/.+$", var.permissions_boundary_arn))
    error_message = "permissions_boundary_arn must be an IAM policy ARN, or empty."
  }
}

variable "additional_manager_policy_arns" {
  description = "Extra managed policies for the manager task role. Review these: the manager holds ecs:RunTask and iam:PassRole for the job roles."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for a in var.additional_manager_policy_arns : can(regex("^arn:aws[a-z-]*:iam::(aws|[0-9]{12}):policy/.+$", a))])
    error_message = "additional_manager_policy_arns entries must be IAM policy ARNs."
  }
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the manager and job log groups. 0 keeps logs forever."
  type        = number
  default     = 30
  nullable    = false

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be 0 or a value CloudWatch Logs accepts."
  }
}

variable "log_kms_key_arn" {
  description = "CMK for the log groups. Empty uses the AWS-managed key. A CMK needs a key policy granting logs.<region>.amazonaws.com, scoped by the kms:EncryptionContext:aws:logs:arn condition."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.log_kms_key_arn == "" ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", var.log_kms_key_arn))
    error_message = "log_kms_key_arn must be a KMS key ARN, or empty."
  }
}

variable "create_alarms" {
  description = "Create CloudWatch alarms. See alarm_sns_topic_arns - alarms with no destination are an audit trail, not an alerting system."
  type        = bool
  default     = true
  nullable    = false
}

variable "alarm_sns_topic_arns" {
  description = "SNS topics for alarm actions. Empty means the alarms transition state and notify nobody, which a check block below will warn you about (R4: an alarm needs a destination)."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for a in var.alarm_sns_topic_arns : can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:.+$", a))])
    error_message = "alarm_sns_topic_arns entries must be SNS topic ARNs."
  }
}

variable "driver_log_level" {
  description = <<-EOT
    Fargate driver log level.

    Worth knowing: the custom executor forwards the driver's stderr into the JOB
    TRACE, so at info and below every developer running a pipeline sees the task
    ARN, the task's private IP, and the subnet and security-group IDs. That is
    information disclosure to anyone who can open a job log. "warn" is the default
    here for that reason; the sibling behaviour of leaking topology into job output
    is not something to inherit by accident.
  EOT
  type        = string
  default     = "warn"
  nullable    = false

  validation {
    condition     = contains(["debug", "info", "warn", "error", "fatal", "panic"], var.driver_log_level)
    error_message = "driver_log_level must be one of debug, info, warn, error, fatal, panic."
  }
}

variable "enable_container_insights" {
  description = "Enable ECS Container Insights on the cluster. Costs per metric but is the only per-task CPU/memory/storage visibility you get on Fargate."
  type        = bool
  default     = true
  nullable    = false
}
