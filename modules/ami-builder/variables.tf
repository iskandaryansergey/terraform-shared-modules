# Everything is nullable = false, and anything that reaches an AWS API or a
# document running as root gets a validation.
#
# Two rules if you add one:
#
#   - Ternaries, can(), or alltrue([for ...]). Never `x == "" || f(x)` - 1.9
#     evaluates both sides, so a throwing right-hand side crashes on the floor
#     version and passes on current. tests/lint_validations.py enforces it.
#
#   - Component documents are arbitrary root-level YAML, and that is the point
#     of the module, so the capability stays. What we can do is reject malformed
#     documents at plan time and ship a linter for the dangerous shapes.

variable "create" {
  description = "Master switch. false plans and applies cleanly to nothing."
  type        = bool
  default     = true
  nullable    = false
}

variable "name" {
  description = "Image name. Prefixes every resource and is the CloudWatch log group suffix, so it is also the multi-pipeline isolation boundary."
  type        = string
  nullable    = false

  validation {
    # 50 is the real ceiling: the AMI name becomes
    # "${name}-{{ imagebuilder:buildDate }}" against a 128-char limit.
    condition     = can(regex("^[a-z][a-z0-9-]{1,49}$", var.name))
    error_message = "name must be 2-50 chars, lowercase alphanumeric or hyphen, starting with a letter."
  }
}

variable "description" {
  description = "Human description carried onto the recipe, pipeline and distribution."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = length(var.description) <= 1024
    error_message = "description must be 1024 characters or fewer."
  }
}

variable "tags" {
  description = "Tags applied to every resource this module creates. Not the same as ami_tags (which land on the produced AMI) or build_resource_tags (which land on the transient build instance)."
  type        = map(string)
  default     = {}
  nullable    = false

  validation {
    condition = alltrue([
      for k, v in var.tags :
      length(k) <= 128 && length(v) <= 256 && !startswith(lower(k), "aws:")
    ])
    error_message = "tags keys must be <= 128 chars, values <= 256 chars, and no key may use the reserved \"aws:\" prefix."
  }
}

# ---------------------------------------------------------------------------
# Recipe
# ---------------------------------------------------------------------------

variable "parent_image" {
  description = <<-EOT
    Base image. Three accepted forms, in descending order of reproducibility:

      1. An AMI id            — "ami-0123456789abcdef0". Reproducible.
      2. An Image Builder ARN — "arn:aws:imagebuilder:eu-west-1:aws:image/amazon-linux-2023-x86/2024.5.20/1". Reproducible when fully versioned.
      3. An SSM parameter     — "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64". NOT reproducible.

    Forms 2-with-a-wildcard and 3 resolve to whatever is current at build time,
    so the same Terraform can produce different images on different days. Those
    require allow_unpinned_parent_image = true.
  EOT
  type        = string
  nullable    = false

  validation {
    condition = can(regex("^ami-[0-9a-f]{8,17}$", var.parent_image)) ? true : (
      can(regex("^arn:aws[a-z-]*:imagebuilder:", var.parent_image)) ? true : (
        startswith(var.parent_image, "/") ? true : false
      )
    )
    error_message = "parent_image must be an AMI id (ami-...), an Image Builder image ARN (arn:aws:imagebuilder:...), or an SSM parameter path starting with \"/\"."
  }
}

variable "allow_unpinned_parent_image" {
  description = "Permit a parent_image that resolves at build time (an SSM path, or an Image Builder ARN with an x.x.x wildcard). Leave false in production: an unpinned parent means the image you audited and the image you rebuild next month are not the same artifact."
  type        = bool
  default     = false
  nullable    = false
}

variable "components" {
  description = <<-EOT
    Ordered build steps. AWSTOE runs every component's build phase in this order,
    then every component's test phase in this order.

    Each entry names EXACTLY ONE source:

      document = <yaml>   inline AWSTOE document, e.g. file("$${path.root}/c.yaml")
      bundled  = <name>   one of this module's shipped components (see below)
      uri      = <s3://>  a document already in S3
      arn      = <arn>    an existing component, including AWS-managed ones such as
                          arn:aws:imagebuilder:eu-west-1:aws:component/update-linux/1.0.2/1

    Bundled components available:
      amazon-linux-hardening   CIS-leaning baseline for AL2023
      install-docker           Docker CE + daemon hardening, for CI workers
      install-gitlab-runner    gitlab-runner + fleeting-plugin-aws, pinned
      verify-image             test-phase assertions (runs in the test phase only)

    parameters map to the component's declared AWSTOE parameters. Passing a
    parameter a component does not declare fails the build, not the plan.
  EOT
  type = list(object({
    name                  = string
    document              = optional(string, "")
    bundled               = optional(string, "")
    uri                   = optional(string, "")
    arn                   = optional(string, "")
    description           = optional(string, "")
    platform              = optional(string, "Linux")
    supported_os_versions = optional(list(string), [])
    parameters            = optional(map(string), {})
  }))
  nullable = false

  validation {
    condition     = length(var.components) >= 1
    error_message = "components must contain at least one entry; a recipe with no components cannot be created."
  }

  validation {
    condition     = length(var.components) <= 30
    error_message = "components must contain 30 entries or fewer; that is the Image Builder recipe limit."
  }

  validation {
    condition = alltrue([
      for c in var.components :
      length([for s in [c.document, c.bundled, c.uri, c.arn] : s if s != ""]) == 1
    ])
    error_message = "each components entry must set exactly one of document, bundled, uri, or arn."
  }

  validation {
    condition = alltrue([
      for c in var.components : can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,49}$", c.name))
    ])
    error_message = "each components entry name must be 2-50 chars, alphanumeric or hyphen, starting with a letter."
  }

  validation {
    condition     = length(distinct([for c in var.components : c.name])) == length(var.components)
    error_message = "components entry names must be unique; they become resource keys."
  }

  validation {
    condition = alltrue([
      for c in var.components :
      contains(["amazon-linux-hardening", "install-docker", "install-gitlab-runner", "verify-image"], c.bundled)
      if c.bundled != ""
    ])
    error_message = "components[*].bundled must be one of: amazon-linux-hardening, install-docker, install-gitlab-runner, verify-image."
  }

  validation {
    # Parse it now, or it fails 20 minutes into a build you've paid for.
    condition = alltrue([
      for c in var.components : can(yamldecode(c.document)) if c.document != ""
    ])
    error_message = "components[*].document must be valid YAML."
  }

  validation {
    # AWSTOE needs both keys. Checking here turns the most common component
    # mistake into a plan error instead of a build failure.
    condition = alltrue([
      for c in var.components :
      can(yamldecode(c.document).schemaVersion) && can(yamldecode(c.document).phases)
      if c.document != ""
    ])
    error_message = "components[*].document must be an AWSTOE document with top-level \"schemaVersion\" and \"phases\" keys."
  }

  validation {
    condition = alltrue([
      for c in var.components : startswith(c.uri, "s3://") if c.uri != ""
    ])
    error_message = "components[*].uri must be an s3:// URI."
  }

  validation {
    condition = alltrue([
      for c in var.components :
      can(regex("^arn:aws[a-z-]*:imagebuilder:[a-z0-9-]+:(aws|[0-9]{12}):component/", c.arn))
      if c.arn != ""
    ])
    error_message = "components[*].arn must be an Image Builder component ARN."
  }

  validation {
    condition = alltrue([
      for c in var.components : contains(["Linux", "Windows"], c.platform)
    ])
    error_message = "components[*].platform must be \"Linux\" or \"Windows\"."
  }

  validation {
    # AWSTOE substitutes {{ Param }} into the document text before bash sees it,
    # so a heredoc's quoting protects nothing here. A value with a newline can
    # close a heredoc early and run the following lines as root; an unquoted one
    # can run a command substitution outright.
    #
    # Parameter values are a lower-trust channel than the component list: the
    # examples wire them to root-module variables, so a CI variable whose job is
    # to bump a version number would otherwise be code execution in the
    # golden-image pipeline.
    #
    # The allowed set covers every legitimate bundled value, spaces included.
    condition = alltrue([
      for c in var.components : alltrue([
        for k, v in c.parameters : can(regex("^[A-Za-z0-9 ._:/=,+@-]*$", v))
      ])
    ])
    error_message = "components[*].parameters values may only contain letters, digits, space, and . _ : / = , + @ -. Newlines, quotes, backticks, $ and ; are refused because AWSTOE substitutes these into a document that runs as root."
  }

  validation {
    # RunnerVersion defaults to empty and the component hard-fails on it at step
    # one, four minutes in. bundled is a closed set of documents we can read, so
    # this belongs at plan time.
    condition = alltrue([
      for c in var.components :
      c.bundled != "install-gitlab-runner" ? true : (
        lookup(c.parameters, "RunnerVersion", "") != ""
      )
    ])
    error_message = "the install-gitlab-runner bundled component requires a RunnerVersion parameter; it refuses to run unpinned and would fail the build at its first step."
  }

  validation {
    condition = alltrue([
      for c in var.components :
      c.bundled != "install-gitlab-runner" ? true : (
        lookup(c.parameters, "RepoScriptSha256", "") != ""
      )
    ])
    error_message = "the install-gitlab-runner bundled component requires a RepoScriptSha256 parameter; it fetches a script that runs as root and refuses to execute it unverified."
  }
}

variable "working_directory" {
  description = "Directory AWSTOE uses for its own scratch space on the build instance."
  type        = string
  default     = "/tmp"
  nullable    = false

  validation {
    condition     = startswith(var.working_directory, "/")
    error_message = "working_directory must be an absolute path."
  }
}

variable "recipe_user_data" {
  description = "Extra cloud-init user data for the build instance, prepended to what Image Builder generates. Rarely needed, and it runs as root before any component does. Note that cloud-init persists this to /var/lib/cloud/instances/<id>/user-data.txt INSIDE the image, so it must never carry a secret - fetch those at build time with the build role instead."
  type        = string
  default     = ""
  nullable    = false
  sensitive   = true

  validation {
    condition     = length(var.recipe_user_data) <= 16384
    error_message = "recipe_user_data must be 16384 characters or fewer (the EC2 user-data limit before base64)."
  }
}

variable "uninstall_ssm_agent_after_build" {
  description = "Remove the SSM agent from the finished image. Leave false: the agent is how you get a shell on an instance launched from this AMI without opening SSH, and most fleets depend on it."
  type        = bool
  default     = false
  nullable    = false
}

# ---------------------------------------------------------------------------
# Storage and encryption
# ---------------------------------------------------------------------------

variable "root_volume_size_gb" {
  description = "Root volume size of the produced image. Must be at least as large as the parent image's root volume, or the build fails. Note this is also the default root volume of EVERY instance ever launched from this image, so it is a fleet cost, not a build cost: 30 vs 20 GB across 20 workers is about $17.60/month, far more than the pipeline itself."
  type        = number
  default     = 30
  nullable    = false

  validation {
    condition     = var.root_volume_size_gb >= 8 && var.root_volume_size_gb <= 16384
    error_message = "root_volume_size_gb must be between 8 and 16384."
  }
}

variable "root_volume_type" {
  description = "Root volume type. gp3 is cheaper than gp2 at every size and has a free 3000 IOPS / 125 MiBps baseline."
  type        = string
  default     = "gp3"
  nullable    = false

  validation {
    condition     = contains(["gp2", "gp3", "io1", "io2", "standard"], var.root_volume_type)
    error_message = "root_volume_type must be one of: gp2, gp3, io1, io2, standard."
  }
}

variable "root_volume_iops" {
  description = "Root volume IOPS. 3000 is the gp3 free baseline; above it you pay per IOPS-month on every volume built from this recipe."
  type        = number
  default     = 3000
  nullable    = false

  validation {
    condition     = var.root_volume_iops >= 100 && var.root_volume_iops <= 256000
    error_message = "root_volume_iops must be between 100 and 256000."
  }

  validation {
    # io1/io2 cap at 50 IOPS per GiB, and the defaults (30 GB, 3000 IOPS) are 2x
    # over that - fine at plan time, rejected at build time.
    condition = contains(["io1", "io2"], var.root_volume_type) ? (
      var.root_volume_iops <= var.root_volume_size_gb * 50
    ) : true
    error_message = "io1/io2 allow at most 50 IOPS per GiB, so root_volume_iops must be <= root_volume_size_gb * 50."
  }
}

variable "root_volume_throughput" {
  description = "Root volume throughput in MiBps. 125 is the gp3 free baseline. Only meaningful for gp3."
  type        = number
  default     = 125
  nullable    = false

  validation {
    condition     = var.root_volume_throughput >= 125 && var.root_volume_throughput <= 1000
    error_message = "root_volume_throughput must be between 125 and 1000."
  }
}

variable "root_device_name" {
  description = "Root device name of the parent image. Leave empty to use /dev/xvda, which is correct for Amazon Linux. If this does not match the parent's actual root device, AWS silently drops the whole block device mapping — encryption and volume size included."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.root_device_name == "" ? true : startswith(var.root_device_name, "/dev/")
    error_message = "root_device_name must be empty or start with /dev/."
  }
}

variable "kms_key_arn" {
  description = "CMK for the snapshots produced in THIS region. Empty means the AWS-managed EBS key, which works but cannot be shared cross-account and cannot carry your own key policy. Snapshots are always encrypted regardless."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.kms_key_arn == "" ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.kms_key_arn))
    error_message = "kms_key_arn must be empty or a KMS key ARN."
  }
}

variable "additional_block_devices" {
  description = "Extra volumes to attach to the image. Each is encrypted with kms_key_arn, or the AWS-managed key when that is empty."
  type = list(object({
    device_name = string
    size_gb     = number
    volume_type = optional(string, "gp3")
    iops        = optional(number, 3000)
    throughput  = optional(number, 125)
    snapshot_id = optional(string, "")
  }))
  default  = []
  nullable = false

  validation {
    condition = alltrue([
      for d in var.additional_block_devices : startswith(d.device_name, "/dev/")
    ])
    error_message = "additional_block_devices[*].device_name must start with /dev/."
  }

  validation {
    condition = alltrue([
      for d in var.additional_block_devices : d.size_gb >= 1 && d.size_gb <= 16384
    ])
    error_message = "additional_block_devices[*].size_gb must be between 1 and 16384."
  }

  validation {
    condition = alltrue([
      for d in var.additional_block_devices :
      contains(["gp2", "gp3", "io1", "io2", "st1", "sc1", "standard"], d.volume_type)
    ])
    error_message = "additional_block_devices[*].volume_type must be a valid EBS volume type."
  }

  validation {
    # Otherwise any snapshot, a stranger's public one included, can be baked in
    # as a data volume with nothing to catch it - and verify-image scans with
    # find -xdev, so it won't look inside either.
    condition = alltrue([
      for d in var.additional_block_devices :
      d.snapshot_id == "" ? true : can(regex("^snap-[0-9a-f]{8,17}$", d.snapshot_id))
    ])
    error_message = "additional_block_devices[*].snapshot_id must be empty or a snapshot id like snap-0123456789abcdef0."
  }

  validation {
    # st1/sc1 have a 125 GB minimum - fine at plan time, rejected at build time.
    condition = alltrue([
      for d in var.additional_block_devices :
      contains(["st1", "sc1"], d.volume_type) ? d.size_gb >= 125 : true
    ])
    error_message = "st1 and sc1 volumes have a 125 GB minimum size."
  }
}

# ---------------------------------------------------------------------------
# Versioning
#
# Component and recipe versions are immutable. Edit a document without bumping
# the version and the API says no, which is the papercut everyone hits once.
# auto_version derives the version from the content so it can't happen.
# ---------------------------------------------------------------------------

variable "auto_version" {
  description = <<-EOT
    Derive component and recipe versions from a hash of their content.

    true (default): versions are content-addressed. Editing a document produces a
    new version automatically; re-applying unchanged content is a no-op. You
    cannot hit "version already exists with different content".

    false: you own component_version and recipe_version and must bump them by
    hand on every change. Human-readable and orderable, at the cost of the error
    above being reachable.
  EOT
  type        = bool
  default     = true
  nullable    = false
}

variable "version_major" {
  description = "Major version for components and the recipe. Under auto_version the minor and patch are derived from content; this is the part you control, for signalling a deliberate break."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.version_major >= 1 && var.version_major <= 999 && floor(var.version_major) == var.version_major
    error_message = "version_major must be a whole number between 1 and 999."
  }
}

variable "component_version" {
  description = "Explicit x.y.z version for every component this module creates. Required when auto_version = false, ignored otherwise."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.component_version == "" ? true : can(regex("^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$", var.component_version))
    error_message = "component_version must be empty or a three-part version like 1.2.3, each part 1-3 digits."
  }
}

variable "recipe_version" {
  description = "Explicit x.y.z version for the recipe. Required when auto_version = false, ignored otherwise."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.recipe_version == "" ? true : can(regex("^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$", var.recipe_version))
    error_message = "recipe_version must be empty or a three-part version like 1.2.3, each part 1-3 digits."
  }
}

variable "retain_component_versions" {
  description = "Keep component versions in AWS when Terraform stops managing them (skip_destroy). Default true, for audit: an AMI running in production was built from a specific component version, and deleting that version destroys the evidence of what went into it. Components cost nothing to keep. The trade-off is that terraform destroy leaves them behind."
  type        = bool
  default     = true
  nullable    = false
}

# ---------------------------------------------------------------------------
# Build infrastructure
# ---------------------------------------------------------------------------

variable "subnet_id" {
  description = "Subnet for the build instance. Private, with a route to the AWS APIs. In an isolated VPC that means interface endpoints — see output.network_contract for the list."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^subnet-[0-9a-f]{8,17}$", var.subnet_id))
    error_message = "subnet_id must be a subnet id like subnet-0123456789abcdef0."
  }
}

variable "security_group_ids" {
  description = "Security groups for the build instance. Needs egress to the AWS APIs it uses and to wherever your components fetch from. No ingress is required — Image Builder drives the instance through SSM, outbound-initiated."
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.security_group_ids) >= 1 && length(var.security_group_ids) <= 5
    error_message = "security_group_ids must contain 1 to 5 entries."
  }

  validation {
    condition = alltrue([
      for s in var.security_group_ids : can(regex("^sg-[0-9a-f]{8,17}$", s))
    ])
    error_message = "security_group_ids entries must look like sg-0123456789abcdef0."
  }
}

variable "instance_types" {
  description = "Candidate instance types for the build. Image Builder selects one based on availability - the order here is NOT a priority, because the underlying API field is a set and Terraform discards list order before the request is sent. Must match the parent image's architecture: an arm64 parent with x86 types fails at instance launch, not at plan."
  type        = list(string)
  default     = ["m6i.large", "m6a.large", "m5.large"]
  nullable    = false

  validation {
    condition     = length(var.instance_types) >= 1 && length(var.instance_types) <= 10
    error_message = "instance_types must contain 1 to 10 entries."
  }

  validation {
    condition = alltrue([
      for t in var.instance_types : can(regex("^[a-z][a-z0-9-]*\\.[a-z0-9]+$", t))
    ])
    error_message = "instance_types entries must look like m6i.large."
  }
}

variable "build_instance_profile_name" {
  description = "Use an existing instance profile for the build instance instead of the one this module creates. Whatever this role can do, an arbitrary component document can do — so a shared profile widens the blast radius of every component you run."
  type        = string
  default     = ""
  nullable    = false
}

variable "key_pair_name" {
  description = "EC2 key pair for the build instance. Leave empty. A key pair is a standing SSH path onto a machine that holds the build role and your build secrets, and Image Builder does not need it — debugging goes through SSM with terminate_instance_on_failure = false."
  type        = string
  default     = ""
  nullable    = false
}

variable "terminate_instance_on_failure" {
  description = "Terminate the build instance when a build fails. Default true. Setting it false is the supported way to debug a failing component, but it leaves a running machine holding the build role and whatever the components fetched — treat it as a temporary, attended change."
  type        = bool
  default     = true
  nullable    = false
}

variable "imds_http_tokens" {
  description = "IMDS mode on the build instance. required = IMDSv2 only."
  type        = string
  default     = "required"
  nullable    = false

  validation {
    condition     = contains(["required", "optional"], var.imds_http_tokens)
    error_message = "imds_http_tokens must be \"required\" or \"optional\"."
  }
}

variable "imds_hop_limit" {
  description = "IMDS response hop limit on the build instance. 1 keeps credentials out of reach of a container running during the build. Raise to 2 only if a component genuinely needs the instance role from inside a container."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.imds_hop_limit >= 1 && var.imds_hop_limit <= 64
    error_message = "imds_hop_limit must be between 1 and 64."
  }
}

variable "build_resource_tags" {
  description = "Tags on the transient build instance and its volumes, as opposed to the Image Builder resources. Worth setting in an account with tag-based SCPs or cost allocation, because the build instance is otherwise anonymous."
  type        = map(string)
  default     = {}
  nullable    = false

  validation {
    condition = alltrue([
      for k, v in var.build_resource_tags :
      length(k) <= 128 && length(v) <= 256 && !startswith(lower(k), "aws:")
    ])
    error_message = "build_resource_tags keys must be <= 128 chars, values <= 256 chars, and no key may use the reserved \"aws:\" prefix."
  }
}

variable "instance_placement" {
  description = "Placement constraints for the build instance. tenancy = \"dedicated\" or a host_resource_group_arn is occasionally mandated for licensing; otherwise leave this empty."
  type = object({
    availability_zone       = optional(string, "")
    tenancy                 = optional(string, "")
    host_id                 = optional(string, "")
    host_resource_group_arn = optional(string, "")
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.instance_placement.tenancy == "" ? true : contains(["default", "dedicated", "host"], var.instance_placement.tenancy)
    error_message = "instance_placement.tenancy must be empty or one of: default, dedicated, host."
  }
}

# ---------------------------------------------------------------------------
# Build logging (BYO bucket)
# ---------------------------------------------------------------------------

variable "log_s3_bucket" {
  description = "Existing bucket for AWSTOE build logs. Required, because a build whose component output goes nowhere cannot be operated: the CloudWatch group carries the service log, not AWSTOE's stdout, and a failed build's instance is gone. The module does not create the bucket - in a regulated estate its policy, KMS key, retention and replication belong to whoever owns S3."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.log_s3_bucket))
    error_message = "log_s3_bucket must be a valid S3 bucket name."
  }
}

variable "log_s3_prefix" {
  description = "Key prefix for build logs. The build role is granted write access to this prefix only, so a broad prefix is a broad grant."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.log_s3_prefix == "" ? true : !startswith(var.log_s3_prefix, "/")
    error_message = "log_s3_prefix must not start with a slash; S3 keys are not paths."
  }
}

variable "log_retention_days" {
  description = "Retention on the /aws/imagebuilder/<name> log group. The module creates that group so the retention is set before Image Builder writes to it; left to Image Builder it defaults to never expiring. 0 means never expire."
  type        = number
  default     = 30
  nullable    = false

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be 0 or one of the retention periods CloudWatch Logs accepts."
  }
}

variable "components_call_kms" {
  description = "Set true only if a component document calls KMS itself. EBS snapshot encryption and SSM parameter decryption both happen service-side and need no KMS endpoint, so this defaults false - listing a kms interface endpoint unconditionally was ~$8/AZ/month of endpoint nobody needed. Affects output.network_contract only."
  type        = bool
  default     = false
  nullable    = false
}

variable "verify_parent_image" {
  description = "Read the parent image at plan time and refuse combinations that would otherwise fail mid-build: an arm64 parent with x86 instance_types (fails at instance launch), and a root_device_name that does not match the parent's actual root device (AWS silently discards the whole block device mapping, encryption included, and hands you a green build). Set false only if the parent AMI is not describable by this principal."
  type        = bool
  default     = true
  nullable    = false
}

variable "log_s3_kms_key_arn" {
  description = "KMS key the build-log bucket is encrypted with, when it uses SSE-KMS with a customer-managed key. Without this the build role can PutObject but cannot GenerateDataKey on the bucket's key, so log delivery fails 403 while the build reports success. Distinct from kms_key_arn, which is the EBS snapshot key."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.log_s3_kms_key_arn == "" ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.log_s3_kms_key_arn))
    error_message = "log_s3_kms_key_arn must be empty or a KMS key ARN."
  }
}

variable "create_log_group" {
  description = "Create the /aws/imagebuilder/<name> log group so the retention below applies before Image Builder writes to it. Set false when the group already exists - a reused pipeline name, or an existing pipeline being brought under management - because Image Builder auto-creates it on first build and Terraform then fails with ResourceAlreadyExistsException."
  type        = bool
  default     = true
  nullable    = false
}

variable "sns_topic_arn" {
  description = "Topic Image Builder publishes build state changes to. If the topic is KMS-encrypted its key policy must allow imagebuilder.amazonaws.com to GenerateDataKey, or notifications are dropped silently."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.sns_topic_arn == "" ? true : can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:", var.sns_topic_arn))
    error_message = "sns_topic_arn must be empty or an SNS topic ARN."
  }
}

# ---------------------------------------------------------------------------
# Distribution
# ---------------------------------------------------------------------------

variable "distribution_regions" {
  description = "Regions to copy the AMI to, in addition to the build region. The build region is always included, because Image Builder requires the distribution configuration to cover it. Each extra region is a full snapshot copy: storage cost and cross-region transfer, per build."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for r in var.distribution_regions : can(regex("^[a-z]{2}-[a-z]+-[0-9]$", r))
    ])
    error_message = "distribution_regions entries must look like eu-west-1."
  }
}

variable "distribution_kms_key_arns" {
  description = "Per-region CMK for the distributed AMI, keyed by region. A cross-region copy is re-encrypted with a key in the TARGET region, so one ARN cannot serve every region — this is a map for that reason. Regions absent from the map use the AWS-managed EBS key there."
  type        = map(string)
  default     = {}
  nullable    = false

  validation {
    # Keys first, because they get interpolated into the regex below: a
    # metacharacter in a key would rewrite the pattern, and a typo'd key matches
    # no distribution region and contributes nothing.
    condition = alltrue([
      for r in keys(var.distribution_kms_key_arns) :
      can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", r))
    ])
    error_message = "distribution_kms_key_arns keys must be region names like eu-west-1."
  }

  validation {
    condition = alltrue([
      for r, k in var.distribution_kms_key_arns :
      can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", k)) ? startswith(k, "arn:aws") : false
    ])
    error_message = "distribution_kms_key_arns values must be KMS key ARNs."
  }

  validation {
    condition = alltrue([
      for r, k in var.distribution_kms_key_arns :
      length(split(":", k)) < 4 ? false : split(":", k)[3] == r
    ])
    error_message = "each distribution_kms_key_arns value must be a key in the region of its map key: a cross-region AMI copy is re-encrypted with a key in the TARGET region."
  }
}

variable "require_cmk" {
  description = "Refuse to plan unless every region the AMI is distributed to has a customer-managed key. Turn this on where policy forbids AWS-managed keys, and to catch the cross-account trap below early."
  type        = bool
  default     = false
  nullable    = false
}

variable "ami_name_prefix" {
  description = "Prefix for the produced AMI name. The build date is appended, since AMI names must be unique per account per region. Empty uses name."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.ami_name_prefix == "" ? true : can(regex("^[a-zA-Z0-9()\\[\\] ./_-]{1,100}$", var.ami_name_prefix))
    error_message = "ami_name_prefix must be empty or use only characters AWS allows in an AMI name, and be 100 chars or fewer."
  }
}

variable "ami_description" {
  description = "Description on the produced AMI. Empty falls back to description, then to a generated one. EC2 caps an AMI description at 255 characters, which is shorter than description allows."
  type        = string
  default     = ""
  nullable    = false

  validation {
    # description allows 1024 and falls through to here, so the resolved value
    # is checked again on the distribution config.
    condition     = length(var.ami_description) <= 255
    error_message = "ami_description must be 255 characters or fewer; that is EC2's limit for an AMI description, and exceeding it fails at the distribution step after the build has already run."
  }
}

variable "ami_tags" {
  description = "Tags on the produced AMI and its snapshots, as opposed to the Image Builder resources. These are what the lifecycle policy's exclusion rules and your own cost reports can select on, so they are worth populating."
  type        = map(string)
  default     = {}
  nullable    = false

  validation {
    condition = alltrue([
      for k, v in var.ami_tags :
      length(k) <= 128 && length(v) <= 256 && !startswith(lower(k), "aws:")
    ])
    error_message = "ami_tags keys must be <= 128 chars, values <= 256 chars, and no key may use the reserved \"aws:\" prefix."
  }
}

variable "target_account_ids" {
  description = "Accounts to distribute the AMI INTO — the AMI is copied and owned there, not merely shared. Each target account must hold the EC2ImageBuilderDistributionCrossAccountRole, and the AMI must be encrypted with a CMK those accounts can use: AWS-managed keys cannot be shared, so this requires distribution_kms_key_arns. Contrast with launch_permission, which shares an AMI this account keeps owning."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for a in var.target_account_ids : can(regex("^[0-9]{12}$", a))
    ])
    error_message = "target_account_ids entries must be 12-digit account ids."
  }
}

variable "launch_permission" {
  description = "Who may launch the AMI this account continues to own. Prefer organization_arns or organizational_unit_arns over user_ids: they follow org membership instead of drifting as accounts come and go. user_groups = [\"all\"] makes the AMI PUBLIC and is rejected below unless allow_public_ami is set."
  type = object({
    user_ids                 = optional(list(string), [])
    user_groups              = optional(list(string), [])
    organization_arns        = optional(list(string), [])
    organizational_unit_arns = optional(list(string), [])
  })
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for a in var.launch_permission.user_ids : can(regex("^[0-9]{12}$", a))
    ])
    error_message = "launch_permission.user_ids entries must be 12-digit account ids."
  }

  validation {
    condition = alltrue([
      for g in var.launch_permission.user_groups : g == "all"
    ])
    error_message = "launch_permission.user_groups only accepts \"all\", which makes the AMI public."
  }

  validation {
    condition = alltrue([
      for a in var.launch_permission.organization_arns :
      can(regex("^arn:aws[a-z-]*:organizations::[0-9]{12}:organization/o-[0-9a-z]{10,32}$", a))
    ])
    error_message = "launch_permission.organization_arns entries must be AWS Organizations organization ARNs; a typo, or another company's organization id, would otherwise be accepted silently."
  }

  validation {
    condition = alltrue([
      for a in var.launch_permission.organizational_unit_arns :
      can(regex("^arn:aws[a-z-]*:organizations::[0-9]{12}:ou/o-[0-9a-z]{10,32}/ou-[0-9a-z]{4,32}-[0-9a-z]{8,32}$", a))
    ])
    error_message = "launch_permission.organizational_unit_arns entries must be AWS Organizations OU ARNs."
  }
}

variable "allow_public_ami" {
  description = "Permit launch_permission.user_groups = [\"all\"]. This publishes the AMI to every AWS account on earth, including whatever your components baked into it. There is almost no case for it in a private estate."
  type        = bool
  default     = false
  nullable    = false
}

variable "ami_ssm_parameter_name" {
  description = <<-EOT
    SSM parameter Image Builder writes the new AMI id into after each successful
    build, in every distribution region. Empty disables it.

    This is the intended way for consumers to pick up the image. A launch
    template that resolves resolve:ssm:/this/parameter gets the current AMI
    without a Terraform run, which is what makes a scheduled pipeline useful
    rather than merely tidy.
  EOT
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.ami_ssm_parameter_name == "" ? true : startswith(var.ami_ssm_parameter_name, "/")
    error_message = "ami_ssm_parameter_name must be empty or an absolute SSM parameter path starting with /."
  }
}

variable "update_launch_template_ids" {
  description = "Launch templates whose AMI is rewritten to point at each new build, creating a new template version. Direct and immediate — and note that an ASG tracking $Latest will then use the new image on its next launch with no further action, which is either exactly what you want or a surprise."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for t in var.update_launch_template_ids : can(regex("^lt-[0-9a-f]{8,17}$", t))
    ])
    error_message = "update_launch_template_ids entries must be launch template ids like lt-0123456789abcdef0."
  }
}

variable "set_launch_template_default_version" {
  description = "Make the new version the launch template's default. Only meaningful with update_launch_template_ids. Leave false if consumers pin an explicit version deliberately."
  type        = bool
  default     = false
  nullable    = false
}

variable "fast_launch" {
  description = "Pre-provision snapshots so instances from this AMI start faster (Windows only in practice). Each pre-provisioned snapshot is billed, so target_resource_count is a direct cost."
  type = object({
    enabled               = optional(bool, false)
    max_parallel_launches = optional(number, 6)
    target_resource_count = optional(number, 5)
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.fast_launch.max_parallel_launches >= 1 && var.fast_launch.max_parallel_launches <= 10000
    error_message = "fast_launch.max_parallel_launches must be between 1 and 10000."
  }

  validation {
    condition     = var.fast_launch.target_resource_count >= 1 && var.fast_launch.target_resource_count <= 10000
    error_message = "fast_launch.target_resource_count must be between 1 and 10000."
  }

  validation {
    # Windows-only in practice. On a Linux image it buys nothing and bills
    # target_resource_count pre-provisioned snapshots per AMI - 5 by default, on
    # the one cost line that already grows without bound.
    condition = !var.fast_launch.enabled ? true : anytrue([
      for c in var.components : c.platform == "Windows"
    ])
    error_message = "fast_launch.enabled requires at least one Windows component: fast launch pre-provisions snapshots for Windows instance launches and does nothing for a Linux image except bill for them."
  }
}

# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------

variable "create_pipeline" {
  description = "Create the image pipeline. false gives you the recipe, infrastructure and distribution configurations without anything that builds on a schedule — useful when builds are triggered entirely from CI."
  type        = bool
  default     = true
  nullable    = false
}

variable "schedule_expression" {
  description = "Build schedule, as a 6-field AWS cron: cron(minute hour day-of-month month day-of-week year). Either day-of-month or day-of-week must be \"?\". Empty means the pipeline only runs when something invokes it. A monthly rebuild is the usual answer for a patching baseline."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.schedule_expression == "" ? true : can(regex("^(cron|rate)\\(.+\\)$", var.schedule_expression))
    error_message = "schedule_expression must be empty, or a cron(...) or rate(...) expression."
  }

  validation {
    # Image Builder wants 6 fields, EventBridge takes 5. Easy to get wrong by
    # copying a rule.
    condition     = can(regex("^cron\\(", var.schedule_expression)) ? length(split(" ", trimsuffix(trimprefix(var.schedule_expression, "cron("), ")"))) == 6 : true
    error_message = "a cron() schedule_expression must have 6 fields: minute hour day-of-month month day-of-week year. Image Builder rejects the 5-field EventBridge form."
  }
}

variable "schedule_timezone" {
  description = "IANA timezone the schedule is interpreted in, e.g. Europe/Dublin. Empty means UTC. Worth setting so a maintenance window does not drift by an hour twice a year."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.schedule_timezone == "" ? true : can(regex("^[A-Za-z]+/[A-Za-z_+-]+$", var.schedule_timezone))
    error_message = "schedule_timezone must be empty or an IANA name like Europe/Dublin."
  }
}

variable "pipeline_execution_start_condition" {
  description = <<-EOT
    What a scheduled run does when nothing has changed.

    EXPRESSION_MATCH_AND_DEPENDENCY_UPDATES_AVAILABLE (default): build only when
    the parent image or a component actually changed. A nightly schedule then
    produces an AMI on the nights that matter and nothing on the others.

    EXPRESSION_MATCH_ONLY: build on every tick. A new AMI, new snapshots and new
    storage cost each time, whether or not anything changed.
  EOT
  type        = string
  default     = "EXPRESSION_MATCH_AND_DEPENDENCY_UPDATES_AVAILABLE"
  nullable    = false

  validation {
    condition     = contains(["EXPRESSION_MATCH_ONLY", "EXPRESSION_MATCH_AND_DEPENDENCY_UPDATES_AVAILABLE"], var.pipeline_execution_start_condition)
    error_message = "pipeline_execution_start_condition must be EXPRESSION_MATCH_ONLY or EXPRESSION_MATCH_AND_DEPENDENCY_UPDATES_AVAILABLE."
  }
}

variable "pipeline_status" {
  description = "Whether the pipeline may run. DISABLED keeps the configuration in place but stops scheduled and manual builds."
  type        = string
  default     = "ENABLED"
  nullable    = false

  validation {
    condition     = contains(["ENABLED", "DISABLED"], var.pipeline_status)
    error_message = "pipeline_status must be ENABLED or DISABLED."
  }
}

variable "enable_image_tests" {
  description = "Run the test phase of every component after the image is created. Leave true: this is the only gate between a broken build and an AMI your fleet will launch."
  type        = bool
  default     = true
  nullable    = false
}

variable "image_tests_timeout_minutes" {
  description = "Ceiling on the test phase, in minutes. The real cost of a generous value is not money (about $1.30 for a full 12 hours) - it is that this module's documented failure mode is a HANG, and 720 minutes means a hung build takes half a day to surface. On a monthly schedule that is one debugging attempt per cycle."
  type        = number
  default     = 120
  nullable    = false

  validation {
    condition     = var.image_tests_timeout_minutes >= 60 && var.image_tests_timeout_minutes <= 1440
    error_message = "image_tests_timeout_minutes must be between 60 and 1440."
  }
}

variable "enable_image_scanning" {
  description = <<-EOT
    Have Amazon Inspector scan the build instance for CVEs before the AMI is
    created, and fail the build on findings above your Inspector configuration.

    Default false, and not because it is optional in a governed estate — turn it
    on. It defaults off because it requires account-level Inspector EC2 scanning
    to be enabled, which this module cannot see or create. Setting this true
    without that prerequisite fails the build, so the module will not do it to
    you silently.
  EOT
  type        = bool
  default     = false
  nullable    = false
}

variable "enhanced_image_metadata_enabled" {
  description = "Collect the OS and package inventory of the produced image. This is what lets you answer \"which AMIs contain this package version\" later."
  type        = bool
  default     = true
  nullable    = false
}

variable "workflows" {
  description = "Custom build/test workflows, replacing Image Builder's default orchestration. Advanced and rarely needed; an empty list uses the AWS-managed workflows. Supplying any workflow requires workflow_execution_role_arn."
  type = list(object({
    name           = string
    type           = string
    document       = optional(string, "")
    uri            = optional(string, "")
    arn            = optional(string, "")
    on_failure     = optional(string, "ABORT")
    parallel_group = optional(string, "")
    parameters     = optional(map(string), {})
  }))
  default  = []
  nullable = false

  validation {
    condition = alltrue([
      for w in var.workflows : contains(["BUILD", "TEST", "DISTRIBUTION"], w.type)
    ])
    error_message = "workflows[*].type must be BUILD, TEST, or DISTRIBUTION."
  }

  validation {
    condition = alltrue([
      for w in var.workflows : contains(["CONTINUE", "ABORT"], w.on_failure)
    ])
    error_message = "workflows[*].on_failure must be CONTINUE or ABORT."
  }

  validation {
    condition = alltrue([
      for w in var.workflows :
      length([for s in [w.document, w.uri, w.arn] : s if s != ""]) == 1
    ])
    error_message = "each workflows entry must set exactly one of document, uri, or arn."
  }

  validation {
    condition = alltrue([
      for w in var.workflows : can(yamldecode(w.document)) if w.document != ""
    ])
    error_message = "workflows[*].document must be valid YAML."
  }

  validation {
    condition = alltrue([
      for w in var.workflows : can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,49}$", w.name))
    ])
    error_message = "workflows[*].name must be 2-50 chars, alphanumeric or hyphen, starting with a letter."
  }

  validation {
    condition     = length(distinct([for w in var.workflows : w.name])) == length(var.workflows)
    error_message = "workflows entry names must be unique."
  }
}

variable "workflow_execution_role_arn" {
  description = "Role Image Builder assumes to run custom workflows. Required when workflows is non-empty."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.workflow_execution_role_arn == "" ? true : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/", var.workflow_execution_role_arn))
    error_message = "workflow_execution_role_arn must be empty or an IAM role ARN."
  }
}

# ---------------------------------------------------------------------------
# Build on apply
# ---------------------------------------------------------------------------

variable "build_on_apply" {
  description = <<-EOT
    Build one image during terraform apply, in addition to the pipeline.

    This is the only way to get a concrete AMI id as a Terraform output, which
    makes it the right choice for bootstrapping something that cannot start
    without an image. The cost is that apply blocks for the whole build —
    typically 20-45 minutes — and a failed component fails the apply.

    For steady-state operation prefer the pipeline plus ami_ssm_parameter_name:
    consumers then track the image without Terraform being in the path.
  EOT
  type        = bool
  default     = false
  nullable    = false
}

variable "build_timeout" {
  description = "How long apply waits for a build_on_apply image before giving up. Must be at least image_tests_timeout_minutes, or Terraform can abandon an in-flight build and the next apply starts a second one concurrently against the same recipe. The build keeps running in AWS after Terraform stops waiting."
  type        = string
  default     = "180m"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]{1,3}(s|m|h)$", var.build_timeout))
    error_message = "build_timeout must look like 90m, 2h, or 600s."
  }
}

# ---------------------------------------------------------------------------
# Lifecycle (this is the one that controls the snapshot bill)
# ---------------------------------------------------------------------------

variable "create_lifecycle_policy" {
  description = "Create an Image Builder lifecycle policy. Without one, every AMI this pipeline has ever produced keeps its snapshots, and snapshot storage is billed per GB-month forever. A monthly pipeline over three years is 36 images that nothing ever removes."
  type        = bool
  default     = true
  nullable    = false
}

variable "lifecycle_deprecate_after_days" {
  description = "Age at which an AMI is deprecated. Deprecation is non-destructive: the AMI still launches, but it drops out of default console and API listings, which is what stops someone picking last year's image by accident."
  type        = number
  default     = 30
  nullable    = false

  validation {
    condition     = var.lifecycle_deprecate_after_days >= 1 && var.lifecycle_deprecate_after_days <= 3650
    error_message = "lifecycle_deprecate_after_days must be between 1 and 3650."
  }
}

variable "lifecycle_delete_after_days" {
  description = "Age at which an AMI and its snapshots are DELETED. 0 disables deletion entirely. The default is deliberately long rather than zero: a policy that deletes nothing costs nothing and saves nothing, and unbounded snapshot growth is the more common production failure. The exemptions below still apply, and lifecycle_exclude_recently_launched_days protects anything in use."
  type        = number
  default     = 365
  nullable    = false

  validation {
    condition     = var.lifecycle_delete_after_days == 0 ? true : var.lifecycle_delete_after_days >= 1 && var.lifecycle_delete_after_days <= 3650
    error_message = "lifecycle_delete_after_days must be 0, or between 1 and 3650."
  }

  validation {
    condition     = var.lifecycle_delete_after_days == 0 ? true : var.lifecycle_delete_after_days > var.lifecycle_deprecate_after_days
    error_message = "lifecycle_delete_after_days must be greater than lifecycle_deprecate_after_days, or an AMI would be deleted before it was ever deprecated."
  }
}

variable "lifecycle_retain_at_least" {
  description = "Never act on the newest N images, whatever their age. This is the backstop that stops an aggressive age rule from emptying the recipe entirely."
  type        = number
  default     = 3
  nullable    = false

  validation {
    condition     = var.lifecycle_retain_at_least >= 1 && var.lifecycle_retain_at_least <= 100
    error_message = "lifecycle_retain_at_least must be between 1 and 100."
  }
}

variable "lifecycle_exclude_recently_launched_days" {
  description = "Exempt AMIs launched within this many days. The point is that age is a poor proxy for \"in use\": a six-month-old image that something launched yesterday is load-bearing. 0 disables the exemption, which is not recommended alongside deletion."
  type        = number
  default     = 30
  nullable    = false

  validation {
    condition     = var.lifecycle_exclude_recently_launched_days >= 0 && var.lifecycle_exclude_recently_launched_days <= 365
    error_message = "lifecycle_exclude_recently_launched_days must be between 0 and 365."
  }
}

variable "lifecycle_exclude_tags" {
  description = "AMIs carrying all of these tags are never touched by the policy. The usual use is a break-glass marker such as { Retain = \"true\" } that an operator can apply to a specific image."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "lifecycle_execution_role_arn" {
  description = "Role the lifecycle policy assumes. Empty makes the module create one with the AWS-managed lifecycle policy attached."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.lifecycle_execution_role_arn == "" ? true : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/", var.lifecycle_execution_role_arn))
    error_message = "lifecycle_execution_role_arn must be empty or an IAM role ARN."
  }
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------

variable "additional_build_policy_arns" {
  description = "Extra policies for the build instance role — for components that pull from CodeArtifact, an internal ECR, or Secrets Manager. Scope these tightly: a component document is arbitrary root-level code, so this role's permissions are the ceiling on what a compromised or careless component can reach."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = length(var.additional_build_policy_arns) <= 8
    error_message = "additional_build_policy_arns must contain 8 entries or fewer: IAM's default quota is 10 managed policies per role and this module already attaches 2."
  }

  validation {
    condition = alltrue([
      for a in var.additional_build_policy_arns : can(regex("^arn:aws[a-z-]*:iam::(aws|[0-9]{12}):policy/", a))
    ])
    error_message = "additional_build_policy_arns entries must be IAM policy ARNs."
  }
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for every role this module creates. Where the platform mandates one, an unbounded role is a finding."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.permissions_boundary_arn == "" ? true : can(regex("^arn:aws[a-z-]*:iam::(aws|[0-9]{12}):policy/", var.permissions_boundary_arn))
    error_message = "permissions_boundary_arn must be empty or an IAM policy ARN."
  }
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

variable "create_event_rule" {
  description = "Route Image Builder state changes to sns_topic_arn through EventBridge. This is a different signal from the pipeline's own sns_topic_arn: the EventBridge event carries the failure reason, which is what you want at 3am. No-op when sns_topic_arn is empty."
  type        = bool
  default     = true
  nullable    = false
}

variable "event_dead_letter_queue_arn" {
  description = "SQS queue for build notifications EventBridge could not deliver. Worth setting: a publish rejected by the topic policy, or by the key policy of an encrypted topic, is discarded with nothing anywhere going red - so the first time you notice is a build that failed quietly weeks ago. The queue's policy must allow events.amazonaws.com to SendMessage."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.event_dead_letter_queue_arn == "" ? true : can(regex("^arn:aws[a-z-]*:sqs:[a-z0-9-]+:[0-9]{12}:", var.event_dead_letter_queue_arn))
    error_message = "event_dead_letter_queue_arn must be empty or an SQS queue ARN."
  }
}

variable "notify_on_states" {
  description = "Image states worth a notification. FAILED alone is the quiet choice; adding AVAILABLE gives you a record of every successful build."
  type        = list(string)
  default     = ["FAILED"]
  nullable    = false

  validation {
    condition = alltrue([
      for s in var.notify_on_states :
      contains(["PENDING", "CREATING", "BUILDING", "TESTING", "DISTRIBUTING", "INTEGRATING", "AVAILABLE", "CANCELLED", "FAILED", "DEPRECATED", "DELETED"], s)
    ])
    error_message = "notify_on_states entries must be Image Builder image states such as FAILED or AVAILABLE."
  }

  validation {
    condition     = length(var.notify_on_states) >= 1
    error_message = "notify_on_states must contain at least one state."
  }
}
