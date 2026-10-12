# Everything is nullable = false, and anything that reaches an AWS API or lands
# in state gets a validation.
#
# Four rules if you add one:
#
#   - Ternaries, can(), or alltrue([for ...]). Never `x == "" || f(x)` - both
#     sides are evaluated. tests/lint_validations.py enforces it.
#
#   - A validation refers to its own variable only: the floor is Terraform 1.7,
#     which allows nothing else there. A rule that compares two inputs is a
#     precondition on aws_rds_cluster.this in main.tf.
#
#   - Empty string means "unset" for optional strings, 0 for optional numbers.
#     The resource maps the sentinel to null.
#
#   - Whether the module creates something is a boolean (create_*), never
#     "this ARN is empty". An ARN from a resource in the caller's own
#     configuration is unknown at plan time, and count cannot depend on it.
#
#   - Say in the description when changing the value replaces the cluster.
#     A replaced cluster is a new, empty database with the same name.

variable "create" {
  description = "Master switch. false plans and applies to nothing. On a live deployment that means a destroy: the instances go first, then deletion_protection stops the cluster delete."
  type        = bool
  default     = true
  nullable    = false
}

variable "name" {
  description = <<-EOT
    Cluster identifier, and the prefix of every other name this module creates
    ("<name>-<instance key>", "<name>-proxy", "<name>-writer-cpu" ...).
    Changing it replaces the cluster.
  EOT
  type        = string
  nullable    = false

  validation {
    # 41 + "-" + a 20-char instance key stays inside the 63-char RDS limit.
    condition     = can(regex("^[a-z][a-z0-9-]{1,40}$", var.name))
    error_message = "name must be 2-41 chars, lowercase alphanumeric or hyphen, starting with a letter."
  }

  validation {
    condition     = !endswith(var.name, "-") && !strcontains(var.name, "--")
    error_message = "name must not end with a hyphen or contain two consecutive hyphens - RDS rejects both."
  }
}

variable "tags" {
  description = "Tags applied to every resource this module creates. The module's own keys (ManagedBy, Module, DatabaseCluster) are merged last and cannot be overridden."
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

variable "required_tag_keys" {
  description = <<-EOT
    Tag keys that must be present and non-empty in var.tags, for estates where
    every billable resource has to be attributable (CostCentre, Owner,
    Environment ...). Empty enforces nothing.
  EOT
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for k in var.required_tag_keys : length(k) > 0 && length(k) <= 128])
    error_message = "required_tag_keys entries must be tag keys of 1-128 chars. Whether var.tags has them is checked at plan, on the cluster."
  }
}

variable "acknowledged_checks" {
  description = <<-EOT
    Advisory checks this caller has decided to live with, by name - for
    example "cluster_survives_an_az" on a single-instance dev cluster. An
    acknowledged check stops warning, in plans and in HCP Terraform health
    assessments, and is listed in output.governance so a reviewer still sees
    the decision. README "Advisory checks" lists the names.
  EOT
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for c in var.acknowledged_checks : contains([
        "cluster_survives_an_az", "instances_are_spread_across_azs", "somebody_hears_a_failover",
        "deleting_the_cluster_is_protected", "deleting_the_cluster_leaves_a_snapshot", "backups_cover_a_week",
        "query_level_metrics_exist", "database_logs_leave_the_instance", "log_retention_is_bounded",
        "tls_is_enforced_where_the_module_can_see", "the_module_controls_who_connects",
        "ingress_stays_inside_private_address_space", "egress_stays_inside_private_address_space", "something_can_connect", "engine_version_is_exact",
        "minor_upgrades_do_not_fight_the_pin", "extended_support_matches_the_setting",
        "extended_support_is_a_decision", "auto_pause_has_an_engine_that_supports_it", "the_proxy_has_clients", "credentials_are_not_in_state",
        "the_proxy_can_reach_secrets_manager", "the_proxy_can_decrypt_its_secrets", "the_proxy_requires_tls", "master_secret_key_is_the_one_configured",
        "performance_insights_key_is_the_one_configured", "activity_stream_key_is_the_one_configured", "database_insights_advanced_on_a_global_member",
        "major_upgrade_applies_immediately", "reader_autoscaling_has_a_reader", "mysql_log_exports_have_their_switches",
        "parameter_group_family_matches_the_engine", "iam_auth_failures_are_logged", "iam_auth_has_memory_headroom",
        "master_user_keeps_its_password", "audit_logs_are_retained",
      ], c)
    ])
    error_message = "acknowledged_checks names a check that does not exist. README \"Advisory checks\" lists them."
  }
}

# ---------------------------------------------------------------------------
# Engine
#
# Engine and version are required: both decide what the cluster is, and a
# default that changed between module versions would replace clusters.
# ---------------------------------------------------------------------------

variable "engine" {
  description = "aurora-postgresql or aurora-mysql. Changing it replaces the cluster."
  type        = string
  nullable    = false

  validation {
    condition     = contains(["aurora-postgresql", "aurora-mysql"], var.engine)
    error_message = "engine must be \"aurora-postgresql\" or \"aurora-mysql\"."
  }
}

variable "engine_version" {
  description = <<-EOT
    Engine version, exact: "17.9" for aurora-postgresql, or
    "8.0.mysql_aurora.3.10.4" for aurora-mysql. With the default
    auto_minor_version_upgrade = false this is the version that runs, and an
    upgrade is a change to this value that you review in a plan.

    A major-only version ("17", "8.0") is accepted but warned about: AWS picks
    the minor at create, and afterwards the provider re-sends the major-only
    value with every modification of the cluster, because it differs from the
    running minor. What AWS does with that is not documented.
  EOT
  type        = string
  nullable    = false

  validation {
    # Which shape belongs to which engine is a precondition on the cluster.
    condition     = can(regex("^([0-9]{2}(\\.[0-9]{1,2})?|8\\.[0-9](\\.mysql_aurora\\.[0-9]+\\.[0-9]+\\.[0-9]+)?)$", var.engine_version))
    error_message = "engine_version must look like \"17.9\" for aurora-postgresql, or \"8.0.mysql_aurora.3.10.4\" for aurora-mysql (major-only \"17\" or \"8.0\" is accepted with a warning). Aurora MySQL 2 (5.7) is past end of standard support."
  }
}

variable "parameter_group_family" {
  description = "Parameter group family for the module-created parameter groups. Empty derives it from engine and engine_version (aurora-postgresql17, aurora-mysql8.0)."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.parameter_group_family == "" ? true : can(regex("^aurora-(postgresql[0-9]{2}|mysql[0-9]\\.[0-9])$", var.parameter_group_family))
    error_message = "parameter_group_family must be empty or look like aurora-postgresql17 or aurora-mysql8.0."
  }
}

variable "auto_minor_version_upgrade" {
  description = <<-EOT
    Let AWS apply minor versions in the maintenance window. Default false: a
    version change is something you make in code and review in a plan. With it
    on, AWS moves the cluster past engine_version; raise engine_version to
    output.engine_version_actual after each maintenance window.
  EOT
  type        = bool
  default     = false
  nullable    = false
}

variable "allow_major_version_upgrade" {
  description = "Permit a plan that changes the major engine version. A major upgrade takes the cluster offline for its duration; this is the acknowledgement. Not for global database members - README \"Global database upgrades\"."
  type        = bool
  default     = false
  nullable    = false
}

variable "engine_lifecycle_support" {
  description = <<-EOT
    What happens when the major version reaches end of standard support.

    open-source-rds-extended-support-disabled (default): AWS upgrades the major
    version for you at end of support. No surprise charges, but an upgrade you
    did not schedule.

    open-source-rds-extended-support: the version keeps running and is billed
    per vCPU-hour on top of the instance price - at London rates about three
    quarters of an r7g's own price in years one and two, more than its whole
    price from year three. See COSTS.md.

    Creation-time only: AWS cannot change it on a running cluster, so later
    changes here are ignored. output.governance reports what the cluster
    actually has, and the extended_support_matches_the_setting check warns
    when the two differ.
  EOT
  type        = string
  default     = "open-source-rds-extended-support-disabled"
  nullable    = false

  validation {
    condition     = contains(["open-source-rds-extended-support", "open-source-rds-extended-support-disabled"], var.engine_lifecycle_support)
    error_message = "engine_lifecycle_support must be \"open-source-rds-extended-support\" or \"open-source-rds-extended-support-disabled\"."
  }
}

# ---------------------------------------------------------------------------
# Instances
#
# The cluster volume holds the data; instances are the compute that reads it.
# Each key becomes "<name>-<key>". Removing a key deletes that instance, not
# the data. Changing a key replaces that instance.
# ---------------------------------------------------------------------------

variable "instance_class" {
  description = <<-EOT
    Default instance class for every instance, overridable per instance.
    db.serverless gives a Serverless v2 instance, scaled by
    var.serverlessv2_scaling_configuration. This is the main cost line - see
    COSTS.md. Burstable classes (db.t4g.*) run out of CPU credits under
    sustained load and are for non-production only.
  EOT
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^db\\.(serverless|[a-z0-9-]+\\.[a-z0-9-]+)$", var.instance_class))
    error_message = "instance_class must look like db.r7g.large or be db.serverless."
  }
}

variable "instances" {
  description = <<-EOT
    The cluster's instances, keyed by a short stable name. Required: the shape
    of the cluster is a decision, and a default that changed between module
    versions would add or remove instances. Every field overrides a module-wide
    default:

      instance_class                instance_class
      availability_zone             AWS spreads instances itself (empty)
      promotion_tier                1. Lower fails over first. It is failover
                                    order, not "which one is the writer" - see README
      ca_cert_identifier            ca_cert_identifier
      preferred_maintenance_window  preferred_maintenance_window, so deferred
                                    instance changes land in the cluster's
                                    window rather than one AWS picks at random
      tags                          merged over var.tags

    Empty is valid only for a headless global secondary - storage that
    replicates with no compute attached until you add some.
  EOT
  type = map(object({
    instance_class               = optional(string, "")
    availability_zone            = optional(string, "")
    promotion_tier               = optional(number, 1)
    ca_cert_identifier           = optional(string, "")
    preferred_maintenance_window = optional(string, "")
    tags                         = optional(map(string), {})
  }))
  nullable = false

  validation {
    condition     = alltrue([for k in keys(var.instances) : can(regex("^[a-z0-9][a-z0-9-]{0,19}$", k))])
    error_message = "instances keys must be 1-20 chars, lowercase alphanumeric or hyphen. They become part of the instance identifier."
  }

  validation {
    condition = alltrue([
      for i in values(var.instances) :
      i.instance_class == "" ? true : can(regex("^db\\.(serverless|[a-z0-9-]+\\.[a-z0-9-]+)$", i.instance_class))
    ])
    error_message = "instances[*].instance_class must be empty or look like db.r7g.large or db.serverless."
  }

  validation {
    condition     = alltrue([for i in values(var.instances) : i.promotion_tier >= 0 && i.promotion_tier <= 15 && floor(i.promotion_tier) == i.promotion_tier])
    error_message = "instances[*].promotion_tier must be a whole number from 0 to 15."
  }

  validation {
    condition = alltrue([
      for i in values(var.instances) :
      i.availability_zone == "" ? true : can(regex("^[a-z]{2,4}(-[a-z]+)+-[0-9][a-z]$", i.availability_zone))
    ])
    error_message = "instances[*].availability_zone must be empty or an AZ name like eu-west-2a."
  }

  validation {
    condition = alltrue([
      for i in values(var.instances) :
      i.preferred_maintenance_window == "" ? true : can(regex("^(mon|tue|wed|thu|fri|sat|sun):([01][0-9]|2[0-3]):[0-5][0-9]-(mon|tue|wed|thu|fri|sat|sun):([01][0-9]|2[0-3]):[0-5][0-9]$", i.preferred_maintenance_window))
    ])
    error_message = "instances[*].preferred_maintenance_window must be empty or look like sun:04:00-sun:05:00 (UTC)."
  }

  validation {
    condition = alltrue([
      for i in values(var.instances) :
      i.ca_cert_identifier == "" ? true : can(regex("^rds-ca-", i.ca_cert_identifier))
    ])
    error_message = "instances[*].ca_cert_identifier must be empty or an RDS CA identifier such as rds-ca-rsa2048-g1."
  }

  validation {
    condition = alltrue([
      for i in values(var.instances) : alltrue([
        for k, v in i.tags : length(k) <= 128 && length(v) <= 256 && !startswith(lower(k), "aws:")
      ])
    ])
    error_message = "instances[*].tags keys must be <= 128 chars, values <= 256 chars, and not use the \"aws:\" prefix."
  }
}

variable "serverlessv2_scaling_configuration" {
  description = <<-EOT
    Capacity range for db.serverless instances, in ACUs (1 ACU ~ 2 GiB RAM).
    Ignored when no instance is db.serverless.

    min_capacity = 0 lets an idle cluster pause after seconds_until_auto_pause
    and stop billing compute. The first connection after a pause waits roughly
    15 seconds while it resumes, so it is for dev and batch, not for anything
    with a latency budget. It needs aurora-postgresql 13.15/14.12/15.7/16.3+
    (every 17) or aurora-mysql 3.08+.

    max_capacity is the cost ceiling and the performance ceiling. The default
    of 4 ACU (about 8 GiB) suits development; size it for production.
  EOT
  type = object({
    min_capacity             = optional(number, 0.5)
    max_capacity             = optional(number, 4)
    seconds_until_auto_pause = optional(number, 3600)
  })
  default  = {}
  nullable = false

  validation {
    condition = (
      var.serverlessv2_scaling_configuration.min_capacity >= 0 &&
      var.serverlessv2_scaling_configuration.max_capacity >= 1 &&
      var.serverlessv2_scaling_configuration.max_capacity <= 256 &&
      var.serverlessv2_scaling_configuration.min_capacity <= var.serverlessv2_scaling_configuration.max_capacity
    )
    error_message = "serverlessv2_scaling_configuration needs 0 <= min_capacity <= max_capacity, and max_capacity between 1 and 256."
  }

  validation {
    condition = (
      floor(var.serverlessv2_scaling_configuration.min_capacity * 2) == var.serverlessv2_scaling_configuration.min_capacity * 2 &&
      floor(var.serverlessv2_scaling_configuration.max_capacity * 2) == var.serverlessv2_scaling_configuration.max_capacity * 2
    )
    error_message = "serverlessv2_scaling_configuration capacities move in steps of 0.5 ACU."
  }

  validation {
    condition     = var.serverlessv2_scaling_configuration.seconds_until_auto_pause >= 300 && var.serverlessv2_scaling_configuration.seconds_until_auto_pause <= 86400
    error_message = "serverlessv2_scaling_configuration.seconds_until_auto_pause must be between 300 and 86400."
  }
}

variable "ca_cert_identifier" {
  description = "Server certificate authority for every instance, overridable per instance. Clients that verify TLS (they should) need this CA's bundle."
  type        = string
  default     = "rds-ca-rsa2048-g1"
  nullable    = false

  validation {
    condition     = can(regex("^rds-ca-", var.ca_cert_identifier))
    error_message = "ca_cert_identifier must be an RDS CA identifier such as rds-ca-rsa2048-g1 or rds-ca-ecc384-g1."
  }
}

variable "publicly_accessible" {
  description = "Give instances a public address. Needs allow_public_access = true and public subnets as well - a database with a public address is one security group rule away from the internet."
  type        = bool
  default     = false
  nullable    = false
}

variable "allow_public_access" {
  description = "Acknowledge that publicly_accessible = true is intended."
  type        = bool
  default     = false
  nullable    = false
}

variable "apply_immediately" {
  description = <<-EOT
    Apply cluster and instance modifications now instead of in the maintenance
    window. Some of them restart instances. Default false keeps a plan from
    causing an outage at the moment of apply - at the price that a deferred
    change shows in every plan until the window applies it.
  EOT
  type        = bool
  default     = false
  nullable    = false
}

# ---------------------------------------------------------------------------
# Storage and encryption
#
# Storage encryption is always on. It cannot be turned on for an existing
# cluster, so a module that allowed it off would allow a mistake that can only
# be fixed by a restore.
# ---------------------------------------------------------------------------

variable "storage_type" {
  description = <<-EOT
    aurora (standard): you pay per I/O request.
    aurora-iopt1 (I/O-Optimized): no I/O charge, roughly 30% more on instances
    and 125% more on storage. Pays off when I/O is above about 25% of the
    cluster's bill. AWS lets you switch to I/O-Optimized once every 30 days.
  EOT
  type        = string
  default     = "aurora"
  nullable    = false

  validation {
    condition     = contains(["aurora", "aurora-iopt1"], var.storage_type)
    error_message = "storage_type must be \"aurora\" or \"aurora-iopt1\"."
  }
}

variable "kms_key_arn" {
  description = <<-EOT
    Customer-managed key for cluster storage, and the default for the master
    secret, Performance Insights, the log groups and the activity stream. Must
    be in the cluster's region. Empty uses the AWS-managed aws/rds key, which
    cannot be shared cross-account - so snapshots cannot be either. Changing it
    replaces the cluster.
  EOT
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.kms_key_arn == "" ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.kms_key_arn))
    error_message = "kms_key_arn must be empty or a KMS key ARN."
  }
}

variable "require_cmk" {
  description = "Refuse to plan unless storage, the master secret, Performance Insights, the exported logs and the activity stream all use a customer-managed key."
  type        = bool
  default     = false
  nullable    = false
}

# ---------------------------------------------------------------------------
# Credentials
#
# The default is an RDS-managed master secret: generated, rotated and stored in
# Secrets Manager by RDS, never in Terraform state. AWS does not support it for
# a global database, where the only alternative a Terraform 1.7 floor allows is
# a password you supply - stored in state, so it needs
# allow_plaintext_credentials.
# ---------------------------------------------------------------------------

variable "database_name" {
  description = "Database created with the cluster. Empty creates none (PostgreSQL still has \"postgres\"). Creation-time only: ignored on a restore or a secondary, and later changes are ignored."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.database_name == "" ? true : can(regex("^[A-Za-z][A-Za-z0-9_]{0,62}$", var.database_name))
    error_message = "database_name must be empty, or 1-63 chars of letters, digits and underscore starting with a letter."
  }
}

variable "master_username" {
  description = "Master user. Creation-time only: ignored on a restore or a secondary, where it comes from the source, and later changes are ignored rather than replacing the cluster."
  type        = string
  default     = "dbadmin"
  nullable    = false

  validation {
    # Aurora PostgreSQL allows 63 characters; the 16-character Aurora MySQL cap
    # is a precondition on the cluster.
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_]{0,62}$", var.master_username))
    error_message = "master_username must start with a letter and contain letters, digits and underscore: up to 16 chars on aurora-mysql, 63 on aurora-postgresql."
  }

  validation {
    condition     = !contains(["rdsadmin", "rdsrepladmin", "rdsproxyadmin", "rdstopmgr"], lower(var.master_username))
    error_message = "master_username must not be one of the accounts RDS reserves for itself (rdsadmin, rdsrepladmin, rdsproxyadmin, rdstopmgr)."
  }
}

variable "manage_master_user_password" {
  description = "Let RDS generate the master password and keep it in Secrets Manager, rotated every 7 days unless master_password_rotation says otherwise. The secret ARN is in output.connection. Not supported by AWS for global database members - set false there and use master_password."
  type        = bool
  default     = true
  nullable    = false
}

variable "master_user_secret_kms_key_arn" {
  description = "Key for the RDS-managed master secret. Empty falls back to kms_key_arn, then to the AWS-managed aws/secretsmanager key - which a principal in another account cannot decrypt. AWS cannot change it once the secret exists, so later changes are ignored and the master_secret_key_is_the_one_configured check reports a mismatch."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.master_user_secret_kms_key_arn == "" ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.master_user_secret_kms_key_arn))
    error_message = "master_user_secret_kms_key_arn must be empty or a KMS key ARN."
  }
}

variable "master_password_rotation" {
  description = <<-EOT
    Rotation schedule for the RDS-managed master secret. Leave both
    schedule_expression and automatically_after_days unset to keep RDS's
    default of every 7 days.

      schedule_expression       "rate(30 days)" or "cron(0 3 ? * SUN *)" - pin
                                rotation into a change window
      automatically_after_days  1-1000, the alternative to an expression
      duration                  "3h": the window in which rotation may run
      rotate_immediately        rotate as soon as the schedule is applied

    Every client must re-read the secret after a rotation; one that caches the
    password at start-up fails at the next connection.
  EOT
  type = object({
    schedule_expression      = optional(string, "")
    automatically_after_days = optional(number, 0)
    duration                 = optional(string, "")
    rotate_immediately       = optional(bool, false)
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.master_password_rotation.schedule_expression == "" ? true : var.master_password_rotation.automatically_after_days == 0
    error_message = "master_password_rotation takes schedule_expression or automatically_after_days, not both."
  }

  validation {
    condition     = var.master_password_rotation.schedule_expression == "" ? true : can(regex("^(rate\\([0-9]+ (hours|days)\\)|cron\\(.+\\))$", var.master_password_rotation.schedule_expression))
    error_message = "master_password_rotation.schedule_expression must look like rate(30 days) or cron(0 3 ? * SUN *)."
  }

  validation {
    condition     = var.master_password_rotation.automatically_after_days == 0 ? true : (var.master_password_rotation.automatically_after_days >= 1 && var.master_password_rotation.automatically_after_days <= 1000)
    error_message = "master_password_rotation.automatically_after_days must be 0 (unset) or 1-1000."
  }

  validation {
    condition     = var.master_password_rotation.duration == "" ? true : can(regex("^([1-9]|1[0-9]|2[0-4])h$", var.master_password_rotation.duration))
    error_message = "master_password_rotation.duration must be empty or 1h to 24h."
  }
}

variable "master_password" {
  description = <<-EOT
    Static master password, with manage_master_user_password = false - the
    only credential path AWS supports for a global database primary. It is
    stored in Terraform state in plaintext, so it also needs
    allow_plaintext_credentials = true and a state backend whose readers you
    trust as you would the database's administrators. Pass it from a sensitive
    workspace variable, never from code.
  EOT
  type        = string
  default     = ""
  nullable    = false
  sensitive   = true

  validation {
    condition     = var.master_password == "" ? true : (length(var.master_password) >= 8 && length(var.master_password) <= 128 && !can(regex("[/@\" ]", var.master_password)))
    error_message = "master_password must be 8-128 chars and contain none of / @ \" or space."
  }
}

variable "allow_plaintext_credentials" {
  description = "Acknowledge that master_password is stored in Terraform state, and anyone who can read the state can read it."
  type        = bool
  default     = false
  nullable    = false
}

variable "iam_database_authentication_enabled" {
  description = "Allow database users to authenticate with short-lived IAM tokens instead of passwords. The database user still has to be granted rds_iam (PostgreSQL) or created with AWSAuthenticationPlugin (MySQL)."
  type        = bool
  default     = false
  nullable    = false
}

variable "iam_database_users" {
  description = <<-EOT
    Database users that log in with IAM tokens, keyed by the user name exactly
    as it exists in the engine (case-sensitive). For each, output
    iam_database_auth gives the rds-db:connect resource ARN, a ready-to-attach
    policy document, the token command and the SQL that creates the user.
    The module does not create the database user.

    connect_via:
      cluster  the client connects to the cluster endpoints with a token. Needs
               iam_database_authentication_enabled; the user is granted rds_iam
               (PostgreSQL) or created WITH AWSAuthenticationPlugin (MySQL).
      proxy    the client connects to the RDS Proxy with a token. Needs the
               proxy with iam_auth = "REQUIRED". The proxy logs in to the
               database with a password from proxy.secret_arns, so the user
               must NOT be an IAM user in the engine.

    The ARN contains the cluster's (or the proxy's) resource ID: a replaced
    or restored cluster, or a global secondary, needs its own policies.
  EOT
  type = map(object({
    connect_via = optional(string, "cluster")
  }))
  default  = {}
  nullable = false

  validation {
    # No "*" or "/": either would widen the dbuser ARN beyond one user.
    condition     = alltrue([for u in keys(var.iam_database_users) : can(regex("^[A-Za-z_][A-Za-z0-9_-]{0,62}$", u))])
    error_message = "iam_database_users keys must be database user names: a letter or underscore, then up to 62 letters, digits, underscores or hyphens."
  }

  validation {
    condition     = alltrue([for c in values(var.iam_database_users) : contains(["cluster", "proxy"], c.connect_via)])
    error_message = "iam_database_users[*].connect_via must be cluster or proxy."
  }
}

variable "create_iam_database_auth_policies" {
  description = "Create one customer-managed IAM policy per iam_database_users entry (\"<name>-<region>-dbuser-<user>\"), allowing rds-db:connect as that user only. false leaves the policy documents in output.iam_database_auth for an IAM team to create."
  type        = bool
  default     = false
  nullable    = false
}

# ---------------------------------------------------------------------------
# Restore
#
# Creation-time inputs. They, and the master user and database they imply,
# are in ignore_changes: setting or clearing one on a running cluster does
# nothing, rather than replacing it.
# ---------------------------------------------------------------------------

variable "snapshot_identifier" {
  description = "Create the cluster from this cluster snapshot: a name (including automated \"rds:...\" and AWS Backup \"awsbackup:...\" names) or an ARN, which a shared or cross-account snapshot needs. Credentials and database_name come from the snapshot. Creation-time only."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.snapshot_identifier == "" ? true : can(regex("^((rds:|awsbackup:)?[a-zA-Z][a-zA-Z0-9-]{0,254}|arn:aws[a-z-]*:rds:[a-z0-9-]+:[0-9]{12}:cluster-snapshot:.+)$", var.snapshot_identifier))
    error_message = "snapshot_identifier must be empty, a cluster snapshot name, or a cluster snapshot ARN."
  }
}

variable "restore_to_point_in_time" {
  description = <<-EOT
    Create the cluster as a point-in-time copy of another cluster. Name the
    source with source_cluster_identifier, or with source_cluster_resource_id
    (cluster-XXXX) for a cluster that has been deleted but whose automated
    backups were retained. Leave both empty to disable.

    Set exactly one of restore_to_time (RFC 3339 UTC) or
    use_latest_restorable_time. restore_type copy-on-write is fast and shares
    pages with the source until they change; full-copy is independent.
    Creation-time only.
  EOT
  type = object({
    source_cluster_identifier  = optional(string, "")
    source_cluster_resource_id = optional(string, "")
    restore_to_time            = optional(string, "")
    use_latest_restorable_time = optional(bool, false)
    restore_type               = optional(string, "full-copy")
  })
  default  = {}
  nullable = false

  validation {
    condition     = contains(["full-copy", "copy-on-write"], var.restore_to_point_in_time.restore_type)
    error_message = "restore_to_point_in_time.restore_type must be \"full-copy\" or \"copy-on-write\"."
  }

  validation {
    condition     = var.restore_to_point_in_time.source_cluster_identifier == "" ? true : var.restore_to_point_in_time.source_cluster_resource_id == ""
    error_message = "restore_to_point_in_time takes source_cluster_identifier or source_cluster_resource_id, not both."
  }

  validation {
    condition     = var.restore_to_point_in_time.source_cluster_resource_id == "" ? true : can(regex("^cluster-[A-Z0-9]+$", var.restore_to_point_in_time.source_cluster_resource_id))
    error_message = "restore_to_point_in_time.source_cluster_resource_id must look like cluster-ABCDEFGHIJKLMNOP."
  }

  validation {
    condition = (
      var.restore_to_point_in_time.source_cluster_identifier == "" && var.restore_to_point_in_time.source_cluster_resource_id == ""
      ? true
      : (var.restore_to_point_in_time.restore_to_time != "") != var.restore_to_point_in_time.use_latest_restorable_time
    )
    error_message = "restore_to_point_in_time needs exactly one of restore_to_time or use_latest_restorable_time."
  }

  validation {
    condition = (
      var.restore_to_point_in_time.restore_to_time == ""
      ? true
      : can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", var.restore_to_point_in_time.restore_to_time))
    )
    error_message = "restore_to_point_in_time.restore_to_time must be RFC 3339 UTC, like 2026-10-01T12:00:00Z."
  }
}

# ---------------------------------------------------------------------------
# Global database
# ---------------------------------------------------------------------------

variable "global_cluster_role" {
  description = <<-EOT
    none: a regional cluster.

    primary: the writable cluster of a global database. With
    create_global_cluster = true this module also creates the global cluster;
    false joins one that already exists. Needs master_password: AWS does not
    support the RDS-managed secret in a global database.

    secondary: a read-only replica in another region, joining
    global_cluster_identifier. It takes no credentials or database_name - they
    replicate - and needs kms_key_arn, because an encrypted cluster in a new
    region needs a key in that region.
  EOT
  type        = string
  default     = "none"
  nullable    = false

  validation {
    condition     = contains(["none", "primary", "secondary"], var.global_cluster_role)
    error_message = "global_cluster_role must be \"none\", \"primary\" or \"secondary\"."
  }
}

variable "global_cluster_identifier" {
  description = "Global cluster to create (primary with create_global_cluster) or join (secondary, or primary without). Required unless global_cluster_role is none."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.global_cluster_identifier == "" ? true : can(regex("^[a-z][a-z0-9-]{0,62}$", var.global_cluster_identifier))
    error_message = "global_cluster_identifier must be empty or 1-63 chars, lowercase alphanumeric or hyphen, starting with a letter."
  }

}

variable "create_global_cluster" {
  description = "With global_cluster_role = primary, create the global cluster here. false joins an existing one."
  type        = bool
  default     = true
  nullable    = false
}

variable "enable_global_write_forwarding" {
  description = "Let a secondary accept writes and forward them to the primary. Writes pay the cross-region round trip; reads stay local."
  type        = bool
  default     = false
  nullable    = false
}

# ---------------------------------------------------------------------------
# Network (create or bring your own)
#
# Two independent choices. Subnet group: create_db_subnet_group, or name an
# existing one. Security group: the module creates one with exactly the
# ingress in ingress_rules and no egress, and/or you supply
# vpc_security_group_ids.
# ---------------------------------------------------------------------------

variable "create_db_subnet_group" {
  description = "Create the DB subnet group from subnet_ids. false uses the existing group named in db_subnet_group_name. Switching between the two changes the cluster's subnet group, which replaces the cluster."
  type        = bool
  default     = true
  nullable    = false
}

variable "db_subnet_group_name" {
  description = <<-EOT
    With create_db_subnet_group = true: the name to give the group. Empty uses
    <name>. Set it to keep an existing group's name when adopting a cluster -
    the previous version of this module named it
    "<cluster_identifier>-subnet-group", and the cluster's subnet group name
    forces replacement of the cluster.

    With create_db_subnet_group = false: the existing group to use. Required.
  EOT
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.db_subnet_group_name == "" ? true : can(regex("^[a-z0-9][a-z0-9 ._-]{0,254}$", var.db_subnet_group_name))
    error_message = "db_subnet_group_name must be empty or a valid DB subnet group name (lowercase)."
  }

}

variable "subnet_ids" {
  description = "Private subnets in at least two AZs for the module-created subnet group, and the default for RDS Proxy. Changing them replaces the proxy (its subnets are fixed at creation); pin proxy.subnet_ids to avoid that."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for s in var.subnet_ids : can(regex("^subnet-[0-9a-f]{8,17}$", s))])
    error_message = "subnet_ids must be subnet IDs (subnet-xxxxxxxx)."
  }

  validation {
    condition     = length(distinct(var.subnet_ids)) == length(var.subnet_ids)
    error_message = "subnet_ids must not contain duplicates."
  }
}

variable "vpc_id" {
  description = "VPC for the module-created security groups. Required when create_security_group or proxy.create_security_group is true."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.vpc_id == "" ? true : can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id))
    error_message = "vpc_id must be empty or a VPC ID (vpc-xxxxxxxx)."
  }
}

variable "create_security_group" {
  description = "Create a security group with exactly the rules in ingress_rules and egress_rules. false leaves vpc_security_group_ids as the cluster's only groups, and this module's guards on them off."
  type        = bool
  default     = true
  nullable    = false
}

variable "vpc_security_group_ids" {
  description = "Existing security groups to attach, in addition to the module-created one when create_security_group is true."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for s in var.vpc_security_group_ids : can(regex("^sg-[0-9a-f]{8,17}$", s))])
    error_message = "vpc_security_group_ids must be security group IDs (sg-xxxxxxxx)."
  }

  validation {
    # With the module-created group the limit is 4 - a precondition on the cluster.
    condition     = length(var.vpc_security_group_ids) <= 5
    error_message = "vpc_security_group_ids can hold at most 5 groups - the RDS limit, counting the module-created one."
  }
}

variable "ingress_rules" {
  description = <<-EOT
    Who may connect to the database port, keyed by a stable label. Each rule
    names exactly one source:

      ingress_rules = {
        app    = { referenced_security_group_id = "sg-0123...", description = "orders service" }
        dms    = { referenced_security_group_id = "sg-0456...", description = "DMS replication" }
        onprem = { cidr_ipv4 = "10.20.0.0/16", description = "data centre via DX" }
      }

    The key is the rule's identity: reordering does nothing, renaming replaces
    one rule. 0.0.0.0/0 and ::/0 are refused. A peered VPC's group is
    "<account>/sg-...".
  EOT
  type = map(object({
    description                  = string
    cidr_ipv4                    = optional(string, "")
    cidr_ipv6                    = optional(string, "")
    referenced_security_group_id = optional(string, "")
    prefix_list_id               = optional(string, "")
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for k in keys(var.ingress_rules) : can(regex("^[a-z][a-z0-9-]{0,50}$", k))])
    error_message = "ingress_rules keys must be 1-51 chars, lowercase alphanumeric or hyphen, starting with a letter."
  }

  validation {
    condition = alltrue([
      for r in values(var.ingress_rules) :
      length([for s in [r.cidr_ipv4, r.cidr_ipv6, r.referenced_security_group_id, r.prefix_list_id] : s if s != ""]) == 1
    ])
    error_message = "each ingress_rules entry must set exactly one of cidr_ipv4, cidr_ipv6, referenced_security_group_id or prefix_list_id."
  }

  validation {
    condition = alltrue([
      for r in values(var.ingress_rules) : (
        (r.cidr_ipv4 == "" ? true : can(cidrhost(r.cidr_ipv4, 0)) && !endswith(r.cidr_ipv4, "/0")) &&
        (r.cidr_ipv6 == "" ? true : can(cidrhost(r.cidr_ipv6, 0)) && !endswith(r.cidr_ipv6, "/0")) &&
        (r.referenced_security_group_id == "" ? true : can(regex("^([0-9]{12}/)?sg-[0-9a-f]{8,17}$", r.referenced_security_group_id))) &&
        (r.prefix_list_id == "" ? true : can(regex("^pl-[0-9a-f]{8,17}$", r.prefix_list_id)))
      )
    ])
    error_message = "ingress_rules: cidr_ipv4 and cidr_ipv6 must be valid CIDRs other than /0, referenced_security_group_id an sg- ID (or account/sg- for a peered VPC), and prefix_list_id a pl- ID."
  }

  validation {
    condition     = alltrue([for r in values(var.ingress_rules) : length(r.description) > 0 && length(r.description) <= 255 && can(regex("^[a-zA-Z0-9. _\\-:/()#,@\\[\\]+=&;{}!$*]*$", r.description))])
    error_message = "ingress_rules[*].description is required, at most 255 chars, and limited to the characters EC2 accepts in a rule description."
  }
}

variable "egress_rules" {
  description = <<-EOT
    Outbound rules for the module-created database security group. Default
    none: a database initiates nothing on its own. Add rules only for
    integrations that call out - S3 import/export (the S3 prefix list on 443),
    Lambda or Bedrock via their interface endpoints. Same shape as
    ingress_rules plus the port.
  EOT
  type = map(object({
    description                  = string
    port                         = number
    protocol                     = optional(string, "tcp")
    cidr_ipv4                    = optional(string, "")
    cidr_ipv6                    = optional(string, "")
    referenced_security_group_id = optional(string, "")
    prefix_list_id               = optional(string, "")
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for k in keys(var.egress_rules) : can(regex("^[a-z][a-z0-9-]{0,50}$", k))])
    error_message = "egress_rules keys must be 1-51 chars, lowercase alphanumeric or hyphen, starting with a letter."
  }

  validation {
    condition = alltrue([
      for r in values(var.egress_rules) :
      length([for s in [r.cidr_ipv4, r.cidr_ipv6, r.referenced_security_group_id, r.prefix_list_id] : s if s != ""]) == 1
    ])
    error_message = "each egress_rules entry must set exactly one of cidr_ipv4, cidr_ipv6, referenced_security_group_id or prefix_list_id."
  }

  validation {
    condition = alltrue([
      for r in values(var.egress_rules) : (
        (r.cidr_ipv4 == "" ? true : can(cidrhost(r.cidr_ipv4, 0))) &&
        (r.cidr_ipv6 == "" ? true : can(cidrhost(r.cidr_ipv6, 0))) &&
        (r.referenced_security_group_id == "" ? true : can(regex("^([0-9]{12}/)?sg-[0-9a-f]{8,17}$", r.referenced_security_group_id))) &&
        (r.prefix_list_id == "" ? true : can(regex("^pl-[0-9a-f]{8,17}$", r.prefix_list_id)))
      )
    ])
    error_message = "egress_rules: cidr_ipv4 and cidr_ipv6 must be valid CIDRs, referenced_security_group_id an sg- ID, and prefix_list_id a pl- ID."
  }

  validation {
    condition     = alltrue([for r in values(var.egress_rules) : contains(["tcp", "udp"], r.protocol) && r.port >= 1 && r.port <= 65535])
    error_message = "egress_rules[*] needs protocol tcp or udp and a port from 1 to 65535. All-traffic rules are not offered."
  }

  validation {
    condition     = alltrue([for r in values(var.egress_rules) : length(r.description) > 0 && length(r.description) <= 255 && can(regex("^[a-zA-Z0-9. _\\-:/()#,@\\[\\]+=&;{}!$*]*$", r.description))])
    error_message = "egress_rules[*].description is required, at most 255 chars, and limited to the characters EC2 accepts in a rule description."
  }
}

variable "port" {
  description = "Database port. 0 uses the engine default (5432 or 3306)."
  type        = number
  default     = 0
  nullable    = false

  validation {
    condition     = var.port == 0 ? true : (var.port >= 1150 && var.port <= 65535)
    error_message = "port must be 0 (engine default) or between 1150 and 65535."
  }
}

variable "network_type" {
  description = "IPV4, or DUAL for IPv4 and IPv6. DUAL needs subnets with IPv6 CIDRs."
  type        = string
  default     = "IPV4"
  nullable    = false

  validation {
    condition     = contains(["IPV4", "DUAL"], var.network_type)
    error_message = "network_type must be \"IPV4\" or \"DUAL\"."
  }
}

# ---------------------------------------------------------------------------
# Parameters
#
# The module creates a cluster and an instance parameter group unless told to
# use existing ones. Into its own cluster group it merges, lowest precedence
# first: recommended logging parameters, then your cluster_parameters, then
# the TLS parameter when enforce_tls is on. output.effective_parameters shows
# the result.
# ---------------------------------------------------------------------------

variable "create_cluster_parameter_group" {
  description = "Create the cluster parameter group. false uses cluster_parameter_group_name, which then gets none of enforce_tls, recommended_parameters or cluster_parameters - the module cannot write to it."
  type        = bool
  default     = true
  nullable    = false
}

variable "cluster_parameter_group_name" {
  description = "Existing cluster parameter group, with create_cluster_parameter_group = false. Must be empty otherwise: the module names its own groups after the family."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.cluster_parameter_group_name == "" ? true : can(regex("^[a-zA-Z][a-zA-Z0-9-]{0,254}$", var.cluster_parameter_group_name))
    error_message = "cluster_parameter_group_name must be empty or a valid parameter group name."
  }

}

variable "create_db_parameter_group" {
  description = "Create the instance parameter group from db_parameters. false uses db_parameter_group_name."
  type        = bool
  default     = true
  nullable    = false
}

variable "db_parameter_group_name" {
  description = "Existing instance parameter group, with create_db_parameter_group = false. Must be empty otherwise."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.db_parameter_group_name == "" ? true : can(regex("^[a-zA-Z][a-zA-Z0-9-]{0,254}$", var.db_parameter_group_name))
    error_message = "db_parameter_group_name must be empty or a valid parameter group name."
  }

}

variable "cluster_parameters" {
  description = <<-EOT
    Cluster parameters, keyed by parameter name:

      cluster_parameters = {
        shared_preload_libraries = { value = "pg_stat_statements,pg_cron" }
        "cron.database_name"     = { value = "app" }
      }

    apply_method defaults to pending-reboot, which every parameter accepts.
    "immediate" works only for dynamic parameters - AWS rejects it for static
    ones at apply time.
  EOT
  type = map(object({
    value        = string
    apply_method = optional(string, "pending-reboot")
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for p in values(var.cluster_parameters) : contains(["immediate", "pending-reboot"], p.apply_method)])
    error_message = "cluster_parameters[*].apply_method must be \"immediate\" or \"pending-reboot\"."
  }

  validation {
    condition     = alltrue([for k in keys(var.cluster_parameters) : can(regex("^[a-zA-Z0-9_.-]+$", k))])
    error_message = "cluster_parameters keys must be parameter names."
  }
}

variable "db_parameters" {
  description = "Instance parameters for the module-created instance parameter group. Same shape as cluster_parameters."
  type = map(object({
    value        = string
    apply_method = optional(string, "pending-reboot")
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for p in values(var.db_parameters) : contains(["immediate", "pending-reboot"], p.apply_method)])
    error_message = "db_parameters[*].apply_method must be \"immediate\" or \"pending-reboot\"."
  }

  validation {
    condition     = alltrue([for k in keys(var.db_parameters) : can(regex("^[a-zA-Z0-9_.-]+$", k))])
    error_message = "db_parameters keys must be parameter names."
  }
}

variable "enforce_tls" {
  description = "Refuse unencrypted client connections: rds.force_ssl = 1 (PostgreSQL) or require_secure_transport = ON (MySQL) in the module-created cluster parameter group. Turning it off needs allow_insecure_transport."
  type        = bool
  default     = true
  nullable    = false
}

variable "allow_insecure_transport" {
  description = "Acknowledge that enforce_tls = false lets clients send credentials and data in cleartext."
  type        = bool
  default     = false
  nullable    = false
}

variable "recommended_parameters" {
  description = <<-EOT
    Merge a small set of logging parameters into the module-created cluster
    group. They only add visibility; none of them change query behaviour.

      aurora-postgresql  log_min_duration_statement = 5000 (ms)
                         log_lock_waits = 1
                         log_autovacuum_min_duration = 10000 (ms)
      aurora-mysql       slow_query_log = 1, long_query_time = 5
                         log_output = FILE (needed for CloudWatch export)
                         innodb_print_all_deadlocks = 1

    cluster_parameters overrides any of them.
  EOT
  type        = bool
  default     = true
  nullable    = false
}

variable "audit_logging" {
  description = <<-EOT
    Database audit logging, written into the module-created cluster parameter
    group. Needs the engine's log export ("postgresql" or "audit") in
    enabled_cloudwatch_logs_exports, or the records rotate away on the
    instance.

    aurora-postgresql - pgAudit:
      pgaudit is appended to shared_preload_libraries (your own value in
      cluster_parameters is kept) and pgaudit.log set to pgaudit_log, all
      pending-reboot. After the writer reboots, run CREATE EXTENSION pgaudit;
      in each database - output.governance.audit_logging.engine_steps.
      pgaudit_log: comma-separated classes from none, all, ddl, function,
      misc, read, role, write; prefix with "-" to subtract (all,-misc).
      pgaudit_log_parameter = true also logs bind values - which may hold
      personal or card data.
      pgaudit_role: role for object-level auditing (rds_pgaudit), or "".

    aurora-mysql - Advanced Auditing:
      server_audit_logging = 1, server_audit_events = mysql_events, and
      server_audit_excl_users = mysql_excluded_users. Dynamic: applied
      without a restart. mysql_events from CONNECT, QUERY, QUERY_DCL,
      QUERY_DDL, QUERY_DML, TABLE.

    Values in cluster_parameters override the ones written here.
  EOT
  type = object({
    enabled               = optional(bool, false)
    pgaudit_log           = optional(string, "ddl,role")
    pgaudit_log_parameter = optional(bool, false)
    pgaudit_role          = optional(string, "")
    mysql_events          = optional(list(string), ["CONNECT", "QUERY_DCL", "QUERY_DDL"])
    mysql_excluded_users  = optional(list(string), [])
  })
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for c in split(",", var.audit_logging.pgaudit_log) : can(regex("^-?(none|all|ddl|function|misc|read|role|write)$", trimspace(c)))])
    error_message = "audit_logging.pgaudit_log must be a comma-separated list of none, all, ddl, function, misc, read, role, write, each optionally prefixed with \"-\"."
  }

  validation {
    condition     = length(var.audit_logging.mysql_events) > 0 && alltrue([for e in var.audit_logging.mysql_events : contains(["CONNECT", "QUERY", "QUERY_DCL", "QUERY_DDL", "QUERY_DML", "TABLE"], e)])
    error_message = "audit_logging.mysql_events must be a non-empty list of CONNECT, QUERY, QUERY_DCL, QUERY_DDL, QUERY_DML, TABLE (upper case)."
  }

  validation {
    condition     = alltrue([for u in var.audit_logging.mysql_excluded_users : can(regex("^[A-Za-z0-9_.@-]{1,32}$", u))]) && length(join(",", var.audit_logging.mysql_excluded_users)) <= 1024
    error_message = "audit_logging.mysql_excluded_users must be MySQL user names (up to 32 characters, no spaces or commas), 1024 characters in total."
  }

  validation {
    condition     = var.audit_logging.pgaudit_role == "" ? true : can(regex("^[A-Za-z_][A-Za-z0-9_]{0,62}$", var.audit_logging.pgaudit_role))
    error_message = "audit_logging.pgaudit_role must be empty or a role name."
  }
}

# ---------------------------------------------------------------------------
# Backup, maintenance and deletion
# ---------------------------------------------------------------------------

variable "backup_retention_days" {
  description = "Days of point-in-time recovery. Aurora always keeps at least 1. Backup storage up to the cluster's size is free; beyond that it is billed per GB-month."
  type        = number
  default     = 7
  nullable    = false

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 35 && floor(var.backup_retention_days) == var.backup_retention_days
    error_message = "backup_retention_days must be a whole number from 1 to 35."
  }
}

variable "preferred_backup_window" {
  description = "Daily backup window, UTC, at least 30 minutes, not overlapping the maintenance window. The default suits a European night; set it for the hours your traffic is lowest."
  type        = string
  default     = "02:00-03:00"
  nullable    = false

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9]$", var.preferred_backup_window))
    error_message = "preferred_backup_window must look like 02:00-03:00 (UTC)."
  }
}

variable "preferred_maintenance_window" {
  description = "Weekly maintenance window, UTC, for the cluster and - unless an instance overrides it - every instance. The default suits a European weekend; every cluster left on it is patched in the same hour, so stagger them across a fleet."
  type        = string
  default     = "sun:04:00-sun:05:00"
  nullable    = false

  validation {
    condition     = can(regex("^(mon|tue|wed|thu|fri|sat|sun):([01][0-9]|2[0-3]):[0-5][0-9]-(mon|tue|wed|thu|fri|sat|sun):([01][0-9]|2[0-3]):[0-5][0-9]$", var.preferred_maintenance_window))
    error_message = "preferred_maintenance_window must look like sun:04:00-sun:05:00 (UTC)."
  }
}

variable "backtrack_window_seconds" {
  description = "aurora-mysql only: rewind the cluster in place up to this many seconds without a restore. 0 disables. Creation-time to AWS: it cannot be enabled on a cluster created without it. Not available in every region, and incompatible with global databases. Billed per million change records stored."
  type        = number
  default     = 0
  nullable    = false

  validation {
    condition     = var.backtrack_window_seconds >= 0 && var.backtrack_window_seconds <= 259200
    error_message = "backtrack_window_seconds must be between 0 and 259200 (72 hours)."
  }

}

variable "deletion_protection" {
  description = "Refuse DeleteDBCluster, including from terraform destroy. To destroy: set false, apply, then destroy."
  type        = bool
  default     = true
  nullable    = false
}

variable "skip_final_snapshot" {
  description = "Delete without a final snapshot. With the default false, deleting the cluster leaves a snapshot named final_snapshot_identifier, billed until you delete it."
  type        = bool
  default     = false
  nullable    = false
}

variable "final_snapshot_identifier" {
  description = "Name of the snapshot taken on delete. Empty uses \"<name>-final-<creation time>\", unique per cluster lifetime. A snapshot with that name must not already exist when the delete happens."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.final_snapshot_identifier == "" ? true : can(regex("^[a-zA-Z][a-zA-Z0-9-]{0,254}$", var.final_snapshot_identifier))
    error_message = "final_snapshot_identifier must be empty or start with a letter and contain only letters, digits and hyphens."
  }
}

variable "delete_automated_backups" {
  description = "Delete automated backups with the cluster. Default false keeps them for their retention period, so a deleted cluster can still be restored to a point in time - with restore_to_point_in_time.source_cluster_resource_id."
  type        = bool
  default     = false
  nullable    = false
}

variable "copy_tags_to_snapshot" {
  description = "Copy cluster tags to its snapshots, so they stay attributable on the bill."
  type        = bool
  default     = true
  nullable    = false
}

# ---------------------------------------------------------------------------
# Features
# ---------------------------------------------------------------------------

variable "enable_data_api" {
  description = "Enable the RDS Data API (enable_http_endpoint: HTTPS SQL with IAM and Secrets Manager auth). Callers then reach the database without network access to it - weigh that against the security groups."
  type        = bool
  default     = false
  nullable    = false
}

variable "enable_local_write_forwarding" {
  description = "Let reader instances accept writes and forward them to the writer (aurora-mysql 3.04+, aurora-postgresql 16.4+)."
  type        = bool
  default     = false
  nullable    = false
}

variable "cluster_iam_roles" {
  description = <<-EOT
    IAM roles to associate with the cluster for engine features, keyed by a
    stable label. The role must trust rds.amazonaws.com.

    aurora-postgresql names the feature each role is for: s3Import, s3Export,
    Lambda, SageMaker, Comprehend or Bedrock.

      cluster_iam_roles = {
        s3-export = { role_arn = "arn:aws:iam::111122223333:role/x", feature_name = "s3Export" }
      }

    aurora-mysql takes no feature name: leave it empty and point the
    aws_default_s3_role / aws_default_lambda_role cluster parameters at the
    role instead.

    These calls leave the VPC, so egress_rules and VPC endpoints have to allow
    them - see output.network_contract.
  EOT
  type = map(object({
    role_arn     = string
    feature_name = optional(string, "")
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for r in values(var.cluster_iam_roles) : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/", r.role_arn))])
    error_message = "cluster_iam_roles[*].role_arn must be an IAM role ARN."
  }

  validation {
    # Which engine needs a feature name is a precondition on the cluster.
    condition     = alltrue([for r in values(var.cluster_iam_roles) : contains(["", "s3Import", "s3Export", "Lambda", "SageMaker", "Comprehend", "Bedrock"], r.feature_name)])
    error_message = "cluster_iam_roles[*].feature_name must be one of s3Import, s3Export, Lambda, SageMaker, Comprehend, Bedrock on aurora-postgresql, and empty on aurora-mysql."
  }
}

variable "activity_stream" {
  description = <<-EOT
    Database Activity Streams: every statement pushed, encrypted, to a Kinesis
    stream AWS creates. For audit regimes that need it. It needs a
    customer-managed key (kms_key_arn falls back to the module key), is not
    available on burstable or serverless instances, and both the stream and
    whatever consumes it are billed. Changing the key or mode restarts the
    stream.
  EOT
  type = object({
    enabled     = optional(bool, false)
    mode        = optional(string, "async")
    kms_key_arn = optional(string, "")
  })
  default  = {}
  nullable = false

  validation {
    condition     = contains(["async", "sync"], var.activity_stream.mode)
    error_message = "activity_stream.mode must be \"async\" or \"sync\"."
  }

  validation {
    condition     = var.activity_stream.kms_key_arn == "" ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.activity_stream.kms_key_arn))
    error_message = "activity_stream.kms_key_arn must be empty or a KMS key ARN."
  }
}

variable "custom_endpoints" {
  description = <<-EOT
    Extra cluster endpoints, keyed by name ("<name>-<key>"). Members are
    instance keys from var.instances, not identifiers:

      custom_endpoints = {
        reporting = { type = "READER", static_members = ["3"] }
      }

    Set static_members or excluded_members, not both. With neither, the endpoint
    covers every instance of its type, including ones added later.
  EOT
  type = map(object({
    type             = optional(string, "READER")
    static_members   = optional(list(string), [])
    excluded_members = optional(list(string), [])
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for k in keys(var.custom_endpoints) : can(regex("^[a-z][a-z0-9-]{0,20}$", k))])
    error_message = "custom_endpoints keys must be 1-21 chars, lowercase alphanumeric or hyphen, starting with a letter."
  }

  validation {
    condition     = alltrue([for e in values(var.custom_endpoints) : contains(["READER", "ANY"], e.type)])
    error_message = "custom_endpoints[*].type must be \"READER\" or \"ANY\"."
  }

  validation {
    condition     = alltrue([for e in values(var.custom_endpoints) : length(e.static_members) == 0 ? true : length(e.excluded_members) == 0])
    error_message = "custom_endpoints entries set static_members or excluded_members, not both."
  }
}

variable "timeouts" {
  description = "Create, update and delete timeouts for the cluster and instances. A large restore or a major upgrade can outlast the provider's defaults."
  type = object({
    create = optional(string, "120m")
    update = optional(string, "120m")
    delete = optional(string, "120m")
  })
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for t in values(var.timeouts) : t != "" && can(regex("^([0-9]+h)?([0-9]+m)?([0-9]+s)?$", t))])
    error_message = "timeouts values must look like 90m, 2h, 1h30m or 3600s."
  }
}

# ---------------------------------------------------------------------------
# Reader autoscaling
# ---------------------------------------------------------------------------

variable "reader_autoscaling" {
  description = <<-EOT
    Application Auto Scaling of Aurora replicas on top of var.instances.
    Scaled replicas use the writer's instance class, are not in Terraform
    state, and have to be gone before the cluster can be deleted: set
    min_capacity and max_capacity to 0, apply, wait, then destroy. AWS acts
    only once the cluster has at least one reader, and does not support it on
    a global secondary. Scaled replicas get no per-instance alarms and no
    instance events; only the reader CPU and replica lag alarms, which read
    cluster-level metrics, include them.

    metric: RDSReaderAverageCPUUtilization (target_value is a percent) or
    RDSReaderAverageDatabaseConnections (target_value is a count).
  EOT
  type = object({
    enabled            = optional(bool, false)
    min_capacity       = optional(number, 1)
    max_capacity       = optional(number, 3)
    metric             = optional(string, "RDSReaderAverageCPUUtilization")
    target_value       = optional(number, 70)
    scale_in_cooldown  = optional(number, 300)
    scale_out_cooldown = optional(number, 300)
    disable_scale_in   = optional(bool, false)
  })
  default  = {}
  nullable = false

  validation {
    condition = (
      var.reader_autoscaling.min_capacity >= 0 &&
      var.reader_autoscaling.max_capacity >= 0 &&
      var.reader_autoscaling.max_capacity <= 15 &&
      var.reader_autoscaling.min_capacity <= var.reader_autoscaling.max_capacity
    )
    error_message = "reader_autoscaling needs 0 <= min_capacity <= max_capacity <= 15."
  }

  validation {
    condition     = contains(["RDSReaderAverageCPUUtilization", "RDSReaderAverageDatabaseConnections"], var.reader_autoscaling.metric)
    error_message = "reader_autoscaling.metric must be RDSReaderAverageCPUUtilization or RDSReaderAverageDatabaseConnections."
  }

  validation {
    condition     = var.reader_autoscaling.target_value > 0 && var.reader_autoscaling.scale_in_cooldown >= 0 && var.reader_autoscaling.scale_out_cooldown >= 0
    error_message = "reader_autoscaling.target_value must be positive and the cooldowns non-negative."
  }
}

# ---------------------------------------------------------------------------
# RDS Proxy
# ---------------------------------------------------------------------------

variable "proxy" {
  description = <<-EOT
    RDS Proxy in front of the cluster: connection pooling, faster failover, and
    IAM auth for clients that cannot do it themselves. Billed per vCPU-hour of
    the cluster's instances (or per ACU for serverless), minimum 2 vCPU.

    Bring your own or let the module create each part:
      create_role            true creates a role that reads exactly the
                             secrets below; false uses role_arn
      secret_arns            the database users the proxy may log in as. Empty
                             means the master user, which needs
                             use_master_secret = true - every client would then
                             act with the master user's privileges
      create_security_group  true creates a group with ingress_rules and
                             egress_rules, plus egress to the database port;
                             false uses security_group_ids
      subnet_ids             empty uses var.subnet_ids

    The proxy reads Secrets Manager from inside the VPC: in an isolated VPC its
    group needs egress on 443 to the Secrets Manager endpoint - add it to
    egress_rules.

    iam_auth REQUIRED makes every client use IAM tokens; DISABLED lets clients
    use the database password from the secret.
  EOT
  type = object({
    enabled                      = optional(bool, false)
    require_tls                  = optional(bool, true)
    iam_auth                     = optional(string, "DISABLED")
    client_password_auth_type    = optional(string, "")
    idle_client_timeout          = optional(number, 1800)
    debug_logging                = optional(bool, false)
    max_connections_percent      = optional(number, 90)
    max_idle_connections_percent = optional(number, 50)
    connection_borrow_timeout    = optional(number, 120)
    session_pinning_filters      = optional(list(string), [])
    init_query                   = optional(string, "")
    create_reader_endpoint       = optional(bool, true)
    create_role                  = optional(bool, true)
    role_arn                     = optional(string, "")
    secret_arns                  = optional(list(string), [])
    use_master_secret            = optional(bool, false)
    secret_kms_key_arn           = optional(string, "")
    create_security_group        = optional(bool, true)
    security_group_ids           = optional(list(string), [])
    subnet_ids                   = optional(list(string), [])
    ingress_rules = optional(map(object({
      description                  = string
      cidr_ipv4                    = optional(string, "")
      cidr_ipv6                    = optional(string, "")
      referenced_security_group_id = optional(string, "")
      prefix_list_id               = optional(string, "")
    })), {})
    egress_rules = optional(map(object({
      description                  = string
      port                         = number
      protocol                     = optional(string, "tcp")
      cidr_ipv4                    = optional(string, "")
      cidr_ipv6                    = optional(string, "")
      referenced_security_group_id = optional(string, "")
      prefix_list_id               = optional(string, "")
    })), {})
  })
  default  = {}
  nullable = false

  validation {
    condition     = contains(["DISABLED", "REQUIRED"], var.proxy.iam_auth)
    error_message = "proxy.iam_auth must be \"DISABLED\" or \"REQUIRED\"."
  }

  validation {
    condition     = var.proxy.client_password_auth_type == "" ? true : contains(["MYSQL_NATIVE_PASSWORD", "MYSQL_CACHING_SHA2_PASSWORD", "POSTGRES_SCRAM_SHA_256", "POSTGRES_MD5"], var.proxy.client_password_auth_type)
    error_message = "proxy.client_password_auth_type must be empty or one of MYSQL_NATIVE_PASSWORD, MYSQL_CACHING_SHA2_PASSWORD, POSTGRES_SCRAM_SHA_256, POSTGRES_MD5."
  }

  validation {
    condition     = var.proxy.idle_client_timeout >= 1 && var.proxy.idle_client_timeout <= 28800
    error_message = "proxy.idle_client_timeout must be between 1 and 28800 seconds."
  }

  validation {
    condition = (
      var.proxy.max_connections_percent >= 1 && var.proxy.max_connections_percent <= 100 &&
      var.proxy.max_idle_connections_percent >= 0 && var.proxy.max_idle_connections_percent <= var.proxy.max_connections_percent &&
      var.proxy.connection_borrow_timeout >= 0 && var.proxy.connection_borrow_timeout <= 3600
    )
    error_message = "proxy needs 1 <= max_connections_percent <= 100, 0 <= max_idle_connections_percent <= max_connections_percent, and connection_borrow_timeout from 0 to 3600."
  }

  validation {
    condition     = alltrue([for f in var.proxy.session_pinning_filters : f == "EXCLUDE_VARIABLE_SETS"])
    error_message = "proxy.session_pinning_filters accepts only EXCLUDE_VARIABLE_SETS."
  }

  validation {
    condition = (
      (var.proxy.role_arn == "" ? true : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/", var.proxy.role_arn))) &&
      alltrue([for s in var.proxy.secret_arns : can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:", s))]) &&
      (var.proxy.secret_kms_key_arn == "" ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.proxy.secret_kms_key_arn))) &&
      alltrue([for s in var.proxy.security_group_ids : can(regex("^sg-[0-9a-f]{8,17}$", s))]) &&
      alltrue([for s in var.proxy.subnet_ids : can(regex("^subnet-[0-9a-f]{8,17}$", s))])
    )
    error_message = "proxy: role_arn must be an IAM role ARN, secret_arns Secrets Manager ARNs, secret_kms_key_arn a KMS key ARN, security_group_ids sg- IDs and subnet_ids subnet- IDs."
  }

  validation {
    condition     = var.proxy.create_role ? var.proxy.role_arn == "" : var.proxy.role_arn != ""
    error_message = "proxy.role_arn is required with proxy.create_role = false, and must be empty with true."
  }

  validation {
    condition     = var.proxy.create_security_group ? length(var.proxy.security_group_ids) == 0 : length(var.proxy.security_group_ids) > 0
    error_message = "proxy.security_group_ids is required with proxy.create_security_group = false, and must be empty with true."
  }

  validation {
    condition     = var.proxy.create_security_group ? true : length(var.proxy.ingress_rules) + length(var.proxy.egress_rules) == 0
    error_message = "proxy.ingress_rules and proxy.egress_rules go into the module-created proxy security group, and proxy.create_security_group = false, so they would be ignored. Add them to the groups in proxy.security_group_ids."
  }

  validation {
    condition = alltrue([
      for k, r in var.proxy.ingress_rules : (
        can(regex("^[a-z][a-z0-9-]{0,50}$", k)) &&
        length([for s in [r.cidr_ipv4, r.cidr_ipv6, r.referenced_security_group_id, r.prefix_list_id] : s if s != ""]) == 1 &&
        (r.cidr_ipv4 == "" ? true : can(cidrhost(r.cidr_ipv4, 0)) && !endswith(r.cidr_ipv4, "/0")) &&
        (r.cidr_ipv6 == "" ? true : can(cidrhost(r.cidr_ipv6, 0)) && !endswith(r.cidr_ipv6, "/0")) &&
        (r.referenced_security_group_id == "" ? true : can(regex("^([0-9]{12}/)?sg-[0-9a-f]{8,17}$", r.referenced_security_group_id))) &&
        (r.prefix_list_id == "" ? true : can(regex("^pl-[0-9a-f]{8,17}$", r.prefix_list_id))) &&
        length(r.description) > 0 && length(r.description) <= 255 && can(regex("^[a-zA-Z0-9. _\\-:/()#,@\\[\\]+=&;{}!$*]*$", r.description))
      )
    ])
    error_message = "proxy.ingress_rules follows the ingress_rules rules: lowercase keys, exactly one source each, no /0, and a description EC2 accepts."
  }

  validation {
    condition = alltrue([
      for k, r in var.proxy.egress_rules : (
        can(regex("^[a-z][a-z0-9-]{0,50}$", k)) &&
        length([for s in [r.cidr_ipv4, r.cidr_ipv6, r.referenced_security_group_id, r.prefix_list_id] : s if s != ""]) == 1 &&
        (r.cidr_ipv4 == "" ? true : can(cidrhost(r.cidr_ipv4, 0))) &&
        (r.cidr_ipv6 == "" ? true : can(cidrhost(r.cidr_ipv6, 0))) &&
        (r.referenced_security_group_id == "" ? true : can(regex("^([0-9]{12}/)?sg-[0-9a-f]{8,17}$", r.referenced_security_group_id))) &&
        (r.prefix_list_id == "" ? true : can(regex("^pl-[0-9a-f]{8,17}$", r.prefix_list_id))) &&
        contains(["tcp", "udp"], r.protocol) && r.port >= 1 && r.port <= 65535 &&
        length(r.description) > 0 && length(r.description) <= 255 && can(regex("^[a-zA-Z0-9. _\\-:/()#,@\\[\\]+=&;{}!$*]*$", r.description))
      )
    ])
    error_message = "proxy.egress_rules follows the egress_rules rules: lowercase keys, exactly one destination each, tcp or udp with a port, and a description EC2 accepts."
  }
}

# ---------------------------------------------------------------------------
# Observability
#
# create_alarms and create_event_subscriptions are on by default and need
# sns_topic_arn. Turning both off is a decision the somebody_hears_a_failover
# check makes visible.
# ---------------------------------------------------------------------------

variable "sns_topic_arn" {
  description = "Topic for alarms and RDS event subscriptions, in the cluster's region. Required while create_alarms or create_event_subscriptions is true. The topic policy must allow events.rds.amazonaws.com and cloudwatch.amazonaws.com to publish; see output.sns_topic_policy_requirement."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.sns_topic_arn == "" ? true : can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:", var.sns_topic_arn))
    error_message = "sns_topic_arn must be empty or an SNS topic ARN."
  }
}

variable "create_alarms" {
  description = "Create the CloudWatch alarms. Needs sns_topic_arn."
  type        = bool
  default     = true
  nullable    = false
}

variable "create_event_subscriptions" {
  description = "Subscribe sns_topic_arn to RDS events for the cluster and its instances. Needs sns_topic_arn."
  type        = bool
  default     = true
  nullable    = false
}

variable "cluster_event_categories" {
  description = "Cluster event categories to subscribe to."
  type        = list(string)
  default     = ["failover", "failure", "maintenance", "notification", "global-failover"]
  nullable    = false

  validation {
    condition     = alltrue([for c in var.cluster_event_categories : contains(["configuration change", "creation", "deletion", "failover", "failure", "global-failover", "maintenance", "migration", "notification", "serverless"], c)])
    error_message = "cluster_event_categories must be RDS db-cluster event categories: configuration change, creation, deletion, failover, failure, global-failover, maintenance, migration, notification, serverless."
  }
}

variable "instance_event_categories" {
  description = "Instance event categories to subscribe to."
  type        = list(string)
  default     = ["availability", "failover", "failure", "low storage", "maintenance", "recovery"]
  nullable    = false

  validation {
    condition     = alltrue([for c in var.instance_event_categories : contains(["availability", "backup", "configuration change", "creation", "deletion", "failover", "failure", "low storage", "maintenance", "notification", "read replica", "recovery", "restoration", "security", "security patching"], c)])
    error_message = "instance_event_categories must be RDS db-instance event categories."
  }
}

variable "alarm_cpu_percent" {
  description = "Writer CPU (reader CPU on a global secondary) above this for 15 minutes alarms. Readers alarm on the same threshold when there are any."
  type        = number
  default     = 80
  nullable    = false

  validation {
    condition     = var.alarm_cpu_percent > 0 && var.alarm_cpu_percent <= 100
    error_message = "alarm_cpu_percent must be between 1 and 100."
  }
}

variable "alarm_freeable_memory_bytes" {
  description = "Any instance with less freeable memory than this alarms. Low memory means swapping, and on Aurora a restart."
  type        = number
  default     = 268435456
  nullable    = false

  validation {
    condition     = var.alarm_freeable_memory_bytes > 0
    error_message = "alarm_freeable_memory_bytes must be positive."
  }
}

variable "alarm_free_local_storage_bytes" {
  description = "Any provisioned instance with less local storage than this alarms. Local storage holds temp tables and sorts, not data - when it fills, queries fail. AWS does not publish it for db.serverless."
  type        = number
  default     = 2147483648
  nullable    = false

  validation {
    condition     = var.alarm_free_local_storage_bytes > 0
    error_message = "alarm_free_local_storage_bytes must be positive."
  }
}

variable "alarm_replica_lag_ms" {
  description = "Maximum replica lag across readers above this alarms. Aurora replicas normally lag by tens of milliseconds."
  type        = number
  default     = 2000
  nullable    = false

  validation {
    condition     = var.alarm_replica_lag_ms > 0
    error_message = "alarm_replica_lag_ms must be positive."
  }
}

variable "alarm_acu_utilization_percent" {
  description = "Serverless only: ACU utilisation of any db.serverless instance above this alarms. Sustained 100% means max_capacity is the bottleneck."
  type        = number
  default     = 90
  nullable    = false

  validation {
    condition     = var.alarm_acu_utilization_percent > 0 && var.alarm_acu_utilization_percent <= 100
    error_message = "alarm_acu_utilization_percent must be between 1 and 100."
  }
}

variable "alarm_connections" {
  description = "Writer connections above this alarms. 0 disables - the right number depends on max_connections, which depends on instance class."
  type        = number
  default     = 0
  nullable    = false

  validation {
    condition     = var.alarm_connections >= 0
    error_message = "alarm_connections must be 0 or positive."
  }
}

variable "alarm_transaction_ids" {
  description = "aurora-postgresql only: oldest unvacuumed transaction age above this alarms. At about 2.1 billion PostgreSQL stops accepting writes to prevent wraparound."
  type        = number
  default     = 1000000000
  nullable    = false

  validation {
    condition     = var.alarm_transaction_ids > 0 && var.alarm_transaction_ids < 2000000000
    error_message = "alarm_transaction_ids must be between 1 and 2000000000."
  }
}

variable "alarm_global_rpo_lag_ms" {
  description = "Global secondary only: committed transactions not yet stored in this region, in milliseconds. Above this alarms. It is the data a regional failover would lose; normally well under a second."
  type        = number
  default     = 10000
  nullable    = false

  validation {
    condition     = var.alarm_global_rpo_lag_ms > 0
    error_message = "alarm_global_rpo_lag_ms must be positive."
  }
}

variable "alarm_volume_bytes" {
  description = "Cluster volume above this alarms - a cost tripwire, since storage is billed per GB-month and never shrinks on older engines. 0 disables."
  type        = number
  default     = 0
  nullable    = false

  validation {
    condition     = var.alarm_volume_bytes >= 0
    error_message = "alarm_volume_bytes must be 0 or positive."
  }
}

variable "enabled_cloudwatch_logs_exports" {
  description = <<-EOT
    Engine logs to publish to CloudWatch Logs.
      aurora-postgresql: postgresql, iam-db-auth-error, instance
      aurora-mysql:      audit, error, general, slowquery, iam-db-auth-error, instance
    Empty publishes nothing, and the logs then age out on the instance after a
    few days. Ingestion is billed per GB; "general" and "audit" are the
    expensive ones, and on aurora-mysql they are empty unless general_log /
    server_audit_logging are switched on in cluster_parameters.
  EOT
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    # Which types belong to which engine is a precondition on the cluster.
    condition     = alltrue([for l in var.enabled_cloudwatch_logs_exports : contains(["postgresql", "audit", "error", "general", "slowquery", "iam-db-auth-error", "instance"], l)])
    error_message = "enabled_cloudwatch_logs_exports holds a log type Aurora does not publish. aurora-postgresql: postgresql, iam-db-auth-error, instance. aurora-mysql: audit, error, general, slowquery, iam-db-auth-error, instance."
  }

  validation {
    condition     = length(distinct(var.enabled_cloudwatch_logs_exports)) == length(var.enabled_cloudwatch_logs_exports)
    error_message = "enabled_cloudwatch_logs_exports must not contain duplicates."
  }
}

variable "create_log_groups" {
  description = "Create the log groups for enabled_cloudwatch_logs_exports, so retention and the key apply before RDS writes. false leaves RDS to create them - with no expiry and the default key - or uses groups that already exist. Turning it off, or dropping a log type, deletes the module's groups and the logs in them unless log_group_skip_destroy is on."
  type        = bool
  default     = true
  nullable    = false
}

variable "log_retention_days" {
  description = "Retention on the module-created log groups. 0 means never expire."
  type        = number
  default     = 30
  nullable    = false

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be 0 or one of the retention periods CloudWatch Logs accepts."
  }
}

variable "log_group_class" {
  description = "STANDARD, or INFREQUENT_ACCESS: about half the ingestion price, but no metric filters, subscription filters or Live Tail. Changing it replaces the log groups, and the logs in them."
  type        = string
  default     = "STANDARD"
  nullable    = false

  validation {
    condition     = contains(["STANDARD", "INFREQUENT_ACCESS"], var.log_group_class)
    error_message = "log_group_class must be \"STANDARD\" or \"INFREQUENT_ACCESS\"."
  }
}

variable "log_group_skip_destroy" {
  description = "Leave the module-created log groups, and the logs in them, in place when Terraform would delete them. For audit regimes where logs must outlive the cluster. A group left behind blocks a recreate of the same name until it is imported or deleted."
  type        = bool
  default     = false
  nullable    = false
}

variable "cloudwatch_logs_kms_key_arn" {
  description = "Key for the module-created log groups. Empty falls back to kms_key_arn. The key policy must allow the CloudWatch Logs service - see output.kms_key_policy_requirements."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.cloudwatch_logs_kms_key_arn == "" ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.cloudwatch_logs_kms_key_arn))
    error_message = "cloudwatch_logs_kms_key_arn must be empty or a KMS key ARN."
  }
}

variable "enhanced_monitoring_interval" {
  description = "Seconds between Enhanced Monitoring OS metrics (process list, per-core CPU, memory). 0 disables. Billed as CloudWatch Logs ingestion into RDSOSMetrics - small per instance, and the only view of the OS during an incident."
  type        = number
  default     = 60
  nullable    = false

  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.enhanced_monitoring_interval)
    error_message = "enhanced_monitoring_interval must be 0, 1, 5, 10, 15, 30 or 60."
  }
}

variable "create_monitoring_role" {
  description = "Create the Enhanced Monitoring role, \"<name>-<region>-monitor\", when enhanced_monitoring_interval > 0. false uses monitoring_role_arn - for landing zones where IAM is created centrally."
  type        = bool
  default     = true
  nullable    = false
}

variable "monitoring_role_arn" {
  description = "Existing role for Enhanced Monitoring, with create_monitoring_role = false."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.monitoring_role_arn == "" ? true : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/", var.monitoring_role_arn))
    error_message = "monitoring_role_arn must be empty or an IAM role ARN."
  }

}

variable "performance_insights_enabled" {
  description = "Performance Insights for the cluster and every instance - one setting, because AWS applies the cluster value to all instances. 7 days of retention are free."
  type        = bool
  default     = true
  nullable    = false
}

variable "performance_insights_retention_days" {
  description = "Performance Insights retention: 7 (free), a multiple of 31 up to 731, or exactly 465 for advanced Database Insights. Beyond 7 it is billed per vCPU-month."
  type        = number
  default     = 7
  nullable    = false

  validation {
    condition     = var.performance_insights_retention_days == 7 ? true : (var.performance_insights_retention_days == 731 ? true : (var.performance_insights_retention_days % 31 == 0 && var.performance_insights_retention_days >= 31 && var.performance_insights_retention_days <= 713))
    error_message = "performance_insights_retention_days must be 7, 731, or a multiple of 31 between 31 and 713."
  }
}

variable "performance_insights_kms_key_arn" {
  description = "Key for Performance Insights data, which includes SQL text. Empty falls back to kms_key_arn. AWS cannot change it once set, so later changes are ignored and the performance_insights_key_is_the_one_configured check reports a mismatch."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.performance_insights_kms_key_arn == "" ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.performance_insights_kms_key_arn))
    error_message = "performance_insights_kms_key_arn must be empty or a KMS key ARN."
  }
}

variable "database_insights_mode" {
  description = "standard, or advanced: fleet-level Database Insights with execution plans and 15 months of history. advanced needs performance_insights_enabled and performance_insights_retention_days of exactly 465, and is billed per vCPU-hour (per ACU-hour for serverless) - see COSTS.md."
  type        = string
  default     = "standard"
  nullable    = false

  validation {
    condition     = contains(["standard", "advanced"], var.database_insights_mode)
    error_message = "database_insights_mode must be \"standard\" or \"advanced\"."
  }
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------

variable "permissions_boundary_arn" {
  description = "Permissions boundary for every role this module creates. Landing zones that require one fail role creation at apply without it."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.permissions_boundary_arn == "" ? true : can(regex("^arn:aws[a-z-]*:iam::(aws|[0-9]{12}):policy/", var.permissions_boundary_arn))
    error_message = "permissions_boundary_arn must be empty or an IAM policy ARN."
  }
}

variable "iam_role_path" {
  description = "Path for every role this module creates, for organisations whose SCPs or boundaries select roles by path."
  type        = string
  default     = "/"
  nullable    = false

  validation {
    condition     = can(regex("^/([a-zA-Z0-9+=,.@_-]+/)*$", var.iam_role_path)) && length(var.iam_role_path) <= 512
    error_message = "iam_role_path must start and end with / (for example /platform/databases/)."
  }
}
