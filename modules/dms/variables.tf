# Everything is nullable = false, and anything that reaches an AWS API or lands
# in state gets a validation.
#
# Two rules if you add one:
#
#   - Ternaries, can(), or alltrue([for ...]). Never `x == "" || f(x)` - 1.9
#     evaluates both sides. tests/lint_validations.py enforces it.
#
#   - DMS silently ignores what it does not understand. Unknown keys in task
#     settings, a table mapping with no selection rule, a misspelled transform:
#     all of these produce a task that runs, reports success, and moves nothing.
#     Validate the shape here rather than discovering it after a 6-hour load.

variable "create" {
  description = "Master switch. false plans and applies cleanly to nothing. The one read that still happens is the account_service_roles_exist lookup (iam:ListRoles): a check-scoped data source cannot be switched off, and a failed lookup is a warning, not an error."
  type        = bool
  default     = true
  nullable    = false
}

variable "name" {
  description = "Name prefix for every resource, and the isolation boundary between two migrations in one account."
  type        = string
  nullable    = false

  validation {
    # "dms-tasks-<name>" is the log group, and replication identifiers cap at 60.
    condition     = can(regex("^[a-z][a-z0-9-]{1,40}$", var.name))
    error_message = "name must be 2-41 chars, lowercase alphanumeric or hyphen, starting with a letter."
  }
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
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
# Compute
# ---------------------------------------------------------------------------

variable "acknowledged_checks" {
  description = "Advisory checks this caller has decided to live with, by name - for example \"replication_survives_an_az\" on a single-AZ dev migration. An acknowledged check stops warning in plans and HCP Terraform health assessments, and is listed in output.governance so a reviewer still sees the decision."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for c in var.acknowledged_checks : contains([
        "somebody_hears_a_failed_task",
        "serverless_replication_is_not_watched_by_this_module",
        "control_tables_have_their_own_schema",
        "debug_logging_is_temporary",
        "raw_overrides_use_known_task_settings",
        "the_full_load_is_not_fighting_the_targets_constraints",
        "the_storage_alarm_leaves_room_to_react",
        "cdc_tasks_are_validated",
        "tasks_write_logs",
        "log_retention_is_bounded",
        "replication_survives_an_az",
        "full_load_does_not_leave_the_meter_running",
        "engine_version_is_pinned",
        "credentials_are_not_in_state",
        "transport_is_verified",
        "minor_upgrades_do_not_fight_the_pin",
        "oracle_ssl_uses_a_wallet",
        "validation_is_claimed_where_it_cannot_run",
        "account_service_roles_exist",
      ], c)
    ])
    error_message = "acknowledged_checks names a check that does not exist. The check names are the check blocks in observability.tf, listed in the README."
  }
}

variable "compute_mode" {
  description = <<-EOT
    Where the replication runs.

    provisioned: a replication instance you size and pay for by the hour until
    you delete it. Supports every migration type and every task setting, and is
    the only mode with per-task control.

    serverless: DMS sizes capacity in DCUs between min and max. No instance to
    forget about, but tasks are not separate resources - one replication config
    is one migration - and several task settings are unavailable.
  EOT
  type        = string
  default     = "provisioned"
  nullable    = false

  validation {
    condition     = contains(["provisioned", "serverless"], var.compute_mode)
    error_message = "compute_mode must be \"provisioned\" or \"serverless\"."
  }
}

variable "instance_class" {
  description = "Replication instance class. Provisioned mode only. Sizing follows the source's change rate, not its total size - a t3 class cannot keep up with a busy OLTP source in CDC."
  type        = string
  default     = "dms.t3.medium"
  nullable    = false

  validation {
    condition     = can(regex("^dms\\.[a-z0-9]+\\.[a-z0-9]+$", var.instance_class))
    error_message = "instance_class must look like dms.t3.medium or dms.c5.large."
  }
}

variable "allocated_storage_gb" {
  description = "Storage for the replication instance. This holds cached changes and task logs, not the migrated data - but a CDC task whose target falls behind spills here, and a full disk stops the task."
  type        = number
  default     = 50
  nullable    = false

  validation {
    condition     = var.allocated_storage_gb >= 5 && var.allocated_storage_gb <= 6144
    error_message = "allocated_storage_gb must be between 5 and 6144."
  }
}

variable "engine_version" {
  description = "DMS engine version. Empty tracks whatever AWS defaults to, which moves under you - pin it for a migration you intend to repeat or audit."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.engine_version == "" ? true : can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.engine_version))
    error_message = "engine_version must be empty or look like 3.5.3."
  }
}

variable "multi_az" {
  description = "Run the replication instance across two AZs. Default true: a single-AZ instance that fails mid-load restarts the full load from zero, and mid-CDC it loses the cached changes. It doubles the instance cost - see COSTS.md before turning it off for a long migration."
  type        = bool
  default     = true
  nullable    = false
}

variable "availability_zone" {
  description = "Pin the replication instance to one AZ. Only meaningful when multi_az is false; worth setting to match the source or target's AZ, because cross-AZ traffic is billed both ways. Changing it on an existing instance REPLACES the instance, and DMS will not delete an instance that still has tasks - the tasks have to be replaced in the same apply (RUNBOOK section 6a). Decide it before the first apply."
  type        = string
  default     = ""
  nullable    = false
}

variable "auto_minor_version_upgrade" {
  description = "Let AWS apply minor engine upgrades in the maintenance window. Off by default because engine_version is pinned: with both, AWS moves the instance to a newer minor and every later plan tries to set the pinned one back, which DMS refuses. DMS minor versions do carry replication fixes - take them by raising engine_version, as a reviewed change outside a cutover window."
  type        = bool
  default     = false
  nullable    = false
}

variable "allow_major_version_upgrade" {
  description = "Permit a major engine version change. This restarts the instance and can change replication behaviour mid-migration."
  type        = bool
  default     = false
  nullable    = false
}

variable "apply_immediately" {
  description = "Apply instance changes now instead of in the maintenance window. Now means an outage in the middle of whatever is running - which during a cutover window is sometimes exactly right and usually not."
  type        = bool
  default     = false
  nullable    = false
}

variable "preferred_maintenance_window" {
  description = "Maintenance window in UTC, e.g. sun:03:00-sun:04:00. Empty lets AWS choose, which may land inside your cutover."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.preferred_maintenance_window == "" ? true : can(regex("^(mon|tue|wed|thu|fri|sat|sun):[0-9]{2}:[0-9]{2}-(mon|tue|wed|thu|fri|sat|sun):[0-9]{2}:[0-9]{2}$", var.preferred_maintenance_window))
    error_message = "preferred_maintenance_window must look like sun:03:00-sun:04:00, lowercase."
  }
}

variable "publicly_accessible" {
  description = "Give the replication instance a public IP. This is a host holding credentials for both your source and your target database. Changing it on an existing instance REPLACES the instance, and DMS will not delete an instance that still has tasks - the tasks have to be replaced in the same apply (RUNBOOK section 6a)."
  type        = bool
  default     = false
  nullable    = false
}

variable "allow_public_replication_instance" {
  description = "Acknowledge publicly_accessible = true. Required, because the usual reason for reaching for it - the source is on-prem - is better served by VPN, Direct Connect, or a public source endpoint with the instance itself private."
  type        = bool
  default     = false
  nullable    = false
}

variable "network_type" {
  description = "IPV4 or DUAL. DUAL needs IPv6 CIDRs on the subnets."
  type        = string
  default     = "IPV4"
  nullable    = false

  validation {
    condition     = contains(["IPV4", "DUAL"], var.network_type)
    error_message = "network_type must be IPV4 or DUAL."
  }
}

variable "serverless" {
  description = "Capacity for compute_mode = \"serverless\". DCU is 2 GB of memory plus matching vCPU; DMS scales between the two bounds and bills per DCU-hour, including while idle waiting for changes."
  type = object({
    min_dcu                      = optional(number, 1)
    max_dcu                      = optional(number, 16)
    multi_az                     = optional(bool, true)
    availability_zone            = optional(string, "")
    preferred_maintenance_window = optional(string, "")
    dns_name_servers             = optional(string, "")
  })
  default  = {}
  nullable = false

  validation {
    condition     = contains([1, 2, 4, 8, 16, 32, 64, 128, 192, 384], var.serverless.min_dcu)
    error_message = "serverless.min_dcu must be one of 1, 2, 4, 8, 16, 32, 64, 128, 192, 384."
  }

  validation {
    condition     = contains([1, 2, 4, 8, 16, 32, 64, 128, 192, 384], var.serverless.max_dcu)
    error_message = "serverless.max_dcu must be one of 1, 2, 4, 8, 16, 32, 64, 128, 192, 384."
  }

  validation {
    condition     = var.serverless.max_dcu >= var.serverless.min_dcu
    error_message = "serverless.max_dcu must be greater than or equal to serverless.min_dcu."
  }
}

# ---------------------------------------------------------------------------
# Network (BYO)
# ---------------------------------------------------------------------------

variable "subnet_ids" {
  description = "Subnets for the replication subnet group. DMS requires at least two, in different AZs, and they must have a route to both the source and the target - see output.network_contract."
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "subnet_ids must contain at least two subnets; DMS requires two availability zones even for a single-AZ instance."
  }

  validation {
    condition = alltrue([
      for s in var.subnet_ids : can(regex("^subnet-[0-9a-f]{8,17}$", s))
    ])
    error_message = "subnet_ids entries must look like subnet-0123456789abcdef0."
  }
}

variable "security_group_ids" {
  description = "Security groups for the replication instance. Needs egress to the source and target ports, and to the AWS APIs it uses (Secrets Manager, KMS, CloudWatch Logs, and S3 for an S3 target). Nothing needs inbound."
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

# ---------------------------------------------------------------------------
# Encryption
# ---------------------------------------------------------------------------

variable "kms_key_arn" {
  description = "CMK for replication instance storage, which is where cached changes and unshipped LOBs sit. Empty uses the AWS-managed DMS key. Endpoints can override this per endpoint. Set it BEFORE the first apply: the key is immutable on the replication instance and on every endpoint that inherits it, and a replaced endpoint replaces every task that uses it - so changing it on a live migration replaces the instance, the endpoints and the tasks, and CDC starts over (RUNBOOK section 6a)."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.kms_key_arn == "" ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.kms_key_arn))
    error_message = "kms_key_arn must be empty or a KMS key ARN."
  }
}

variable "require_cmk" {
  description = "Refuse to plan unless the replication storage and every endpoint use a customer-managed key. Turn this on where policy forbids AWS-managed keys."
  type        = bool
  default     = false
  nullable    = false
}

# ---------------------------------------------------------------------------
# Endpoints
#
# Credentials are the whole security story here. username/password on a DMS
# endpoint are written to Terraform state in plaintext and sit in the API
# response forever, so the module refuses them unless you say otherwise. The
# supported path is a Secrets Manager secret plus a role DMS assumes to read it.
# ---------------------------------------------------------------------------

variable "endpoints" {
  description = <<-EOT
    Database endpoints, keyed by a name you choose. Keys become endpoint ids and
    are what tasks refer to.

    Credentials, in order of preference:

      secret_arn = "arn:aws:secretsmanager:..."   the supported path. DMS reads
                   the secret itself, nothing lands in state, and rotation is
                   possible. The module creates the role DMS assumes unless you
                   supply secret_access_role_arn.

      username / password                          plaintext in state. Refused
                   unless allow_plaintext_credentials = true.

    ssl_mode defaults to verify-full, which DMS does not support on every
    engine: Oracle, Db2 and Db2 z/OS take none or verify-ca (Oracle with an
    Oracle wallet in certificates[*].wallet), SQL Server none, require or
    verify-full, SAP ASE none or verify-full, Redshift none. Set ssl_mode
    explicitly for those; an unsupported value is refused at plan. Anything
    below verify on a database carrying production data is a decision, not a
    default - see allow_insecure_transport.

    With secret_arn, the secret DMS reads holds host, port, username and
    password - give DMS its own database user and its own secret. The
    RDS/Aurora-managed master secret is not usable here. database_name is not
    in that secret and is sent from this variable - except for aurora, mysql
    and mariadb on the secret path, where the provider does not send it. For
    the MySQL family leave database_name empty: when DMS does receive it, it
    replicates every table into that one database.

    S3 targets are a different resource with a different shape; use s3_targets.
  EOT
  type = map(object({
    role   = string
    engine = string
    # With secret_arn set, server_name and port do NOT reach DMS - the secret
    # carries host and port. They are still worth filling in:
    # output.network_contract is built from them, and that is what the firewall
    # request is made of. database_name reaches DMS on both paths except for
    # the MySQL family on the secret path (see the description). Oracle needs
    # it (SID or service name) on either path.
    server_name   = optional(string, "")
    port          = optional(number, 0)
    database_name = optional(string, "")

    secret_arn             = optional(string, "")
    secret_access_role_arn = optional(string, "")
    secret_kms_key_arn     = optional(string, "")
    username               = optional(string, "")
    password               = optional(string, "")

    ssl_mode = optional(string, "verify-full")
    # A key from the certificates variable, resolved inside the module.
    # certificate_arn is for a CA that already exists in DMS. Referencing a
    # module-created certificate by ARN from here would be a dependency cycle,
    # which is why the key form exists.
    certificate_key = optional(string, "")
    certificate_arn = optional(string, "")
    # Immutable on the endpoint: changing it replaces the endpoint and every
    # task that uses it. Falls back to the module's kms_key_arn.
    kms_key_arn = optional(string, "")

    extra_connection_attributes = optional(string, "")

    # PostgreSQL knobs that change whether replication works at all.
    #
    # heartbeat_*, slot_name and capture_ddls are SOURCE-only - applied to a
    # target DMS would try to create a heartbeat table in the database you are
    # migrating into. The module only sends them when role = "source".
    #
    # after_connect_script and execute_timeout apply to either end, and the
    # target is where after_connect_script earns its keep: it runs on every
    # connection DMS opens, so "SET session_replication_role = replica;"
    # affects DMS's sessions only and nothing needs restoring afterwards. The
    # DMS database user needs the privilege to set it (superuser, or on RDS and
    # Aurora membership of rds_superuser).
    postgres = optional(object({
      heartbeat_enable             = optional(bool, true)
      heartbeat_frequency          = optional(number, 5)
      heartbeat_schema             = optional(string, "awsdms")
      capture_ddls                 = optional(bool, false)
      slot_name                    = optional(string, "")
      map_boolean_as_boolean       = optional(bool, true)
      fail_tasks_on_lob_truncation = optional(bool, true)
      after_connect_script         = optional(string, "")
      # Seconds. Sent as given: the provider sends 0 for an unset value rather
      # than leaving DMS's default (60), so the default is spelled out here.
      execute_timeout = optional(number, 60)
      # KB, target only. Same provider behaviour as execute_timeout: unset is
      # sent as 0, and DMS 3.5.x with MaxFileSize = 0 on a PostgreSQL target
      # keeps every table in "Before load" and never finishes the full load.
      # 32768 is the DMS default.
      max_file_size = optional(number, 32768)
    }), {})
  }))
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for k, e in var.endpoints : contains(["source", "target"], e.role)
    ])
    error_message = "endpoints[*].role must be \"source\" or \"target\"."
  }

  validation {
    condition = alltrue([
      for k, e in var.endpoints : can(regex("^[a-z][a-z0-9-]{1,50}$", k))
    ])
    error_message = "endpoints keys must be 2-51 chars, lowercase alphanumeric or hyphen, starting with a letter; they become endpoint ids."
  }

  validation {
    condition = alltrue([
      for k, e in var.endpoints : contains([
        "aurora", "aurora-postgresql", "mariadb", "mysql", "oracle", "postgres",
        "sqlserver", "db2", "db2-zos", "sybase", "redshift",
      ], e.engine)
    ])
    error_message = "endpoints[*].engine must be a relational engine DMS supports: aurora, aurora-postgresql, mariadb, mysql, oracle, postgres, sqlserver, db2, db2-zos, sybase, redshift. S3 targets go in s3_targets. docdb and neptune are not supported: the provider drops the Secrets Manager fields for them, so the endpoint would reach DMS with no credentials."
  }

  validation {
    # A credential source is required: endpoints_with_secret (a for_each) puts
    # every endpoint without a username on the secret path.
    condition = alltrue([
      for k, e in var.endpoints : e.secret_arn != "" ? true : e.username != ""
    ])
    error_message = "every endpoint needs a credential: secret_arn (supported) or username/password."
  }

  validation {
    # Exactly one credential source. Both set is ambiguous and DMS picks one.
    condition = alltrue([
      for k, e in var.endpoints :
      e.secret_arn != "" ? (e.username == "" && e.password == "") : true
    ])
    error_message = "an endpoint may not set both secret_arn and username/password. Secrets Manager is the supported path; drop the plaintext pair."
  }

  validation {
    condition = alltrue([
      for k, e in var.endpoints :
      e.secret_arn == "" ? true : can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:", e.secret_arn))
    ])
    error_message = "endpoints[*].secret_arn must be a Secrets Manager secret ARN."
  }

  validation {
    condition = alltrue([
      for k, e in var.endpoints :
      e.secret_access_role_arn == "" ? true : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/", e.secret_access_role_arn))
    ])
    error_message = "endpoints[*].secret_access_role_arn must be an IAM role ARN."
  }

  validation {
    # A secret encrypted with a CMK needs kms:Decrypt as well as
    # GetSecretValue, and the failure without it is an endpoint that tests
    # fine and a task that cannot start.
    condition = alltrue([
      for k, e in var.endpoints :
      e.secret_kms_key_arn == "" ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", e.secret_kms_key_arn))
    ])
    error_message = "endpoints[*].secret_kms_key_arn must be empty or a KMS key ARN. Set it when the secret is encrypted with a customer-managed key."
  }

  validation {
    condition = alltrue([
      for k, e in var.endpoints :
      contains(["none", "require", "verify-ca", "verify-full"], e.ssl_mode)
    ])
    error_message = "endpoints[*].ssl_mode must be none, require, verify-ca, or verify-full."
  }

  validation {
    # AWS DMS supports a different set of SSL modes per engine (the "Using SSL"
    # table in the DMS user guide). An unsupported mode fails at endpoint
    # create or connection test - on Oracle, verify-full is refused outright,
    # and the only escape left would be ssl_mode = "none".
    condition = alltrue([
      for k, e in var.endpoints : contains(lookup({
        aurora    = ["none", "verify-ca", "verify-full"]
        mariadb   = ["none", "verify-ca", "verify-full"]
        mysql     = ["none", "verify-ca", "verify-full"]
        sqlserver = ["none", "require", "verify-full"]
        oracle    = ["none", "verify-ca"]
        db2       = ["none", "verify-ca"]
        db2-zos   = ["none", "verify-ca"]
        sybase    = ["none", "verify-full"]
        redshift  = ["none"]
      }, e.engine, ["none", "require", "verify-ca", "verify-full"]), e.ssl_mode)
    ])
    error_message = "endpoints[*].ssl_mode is not supported by DMS for that engine. Oracle, db2 and db2-zos: none or verify-ca (Oracle with a wallet - certificates[*].wallet). MySQL, MariaDB and Aurora MySQL: none, verify-ca or verify-full. SQL Server: none, require or verify-full. SAP ASE (sybase): none or verify-full. Redshift: none (DMS reaches it through S3, already encrypted). PostgreSQL: any."
  }

  validation {
    # verify-ca and verify-full mean nothing without a CA to verify against.
    condition = alltrue([
      for k, e in var.endpoints :
      contains(["verify-ca", "verify-full"], e.ssl_mode) ? (e.certificate_arn != "" || e.certificate_key != "") : true
    ])
    error_message = "endpoints[*].ssl_mode of verify-ca or verify-full requires a CA: set certificate_key to one of the certificates entries, or certificate_arn to a CA already in DMS. Without one there is nothing to verify the server against and the connection test fails."
  }

  validation {
    condition = alltrue([
      for k, e in var.endpoints :
      e.certificate_key == "" || e.certificate_arn == ""
    ])
    error_message = "endpoints[*] may set certificate_key or certificate_arn, not both."
  }

  validation {
    # Cross-variable validation: the key has to name a certificate this module
    # is actually creating.
    condition = alltrue([
      for k, e in var.endpoints :
      e.certificate_key == "" ? true : contains(keys(var.certificates), e.certificate_key)
    ])
    error_message = "endpoints[*].certificate_key must name an entry in the certificates variable."
  }

  validation {
    # This field is free text that DMS passes to the driver, and it is a
    # well-worn place to hide a password. It is also stored in plain state.
    condition = alltrue([
      for k, e in var.endpoints :
      !can(regex("(?i)(password|pwd|secret|auth_?token)\\s*=", e.extra_connection_attributes))
    ])
    error_message = "endpoints[*].extra_connection_attributes looks like it carries a credential. That string is stored in Terraform state and returned by the DMS API in plaintext - put the credential in Secrets Manager and reference it with secret_arn."
  }

  validation {
    condition = alltrue([
      for k, e in var.endpoints :
      e.port == 0 ? true : (e.port >= 1 && e.port <= 65535)
    ])
    error_message = "endpoints[*].port must be between 1 and 65535."
  }

  validation {
    condition = alltrue([
      for k, e in var.endpoints :
      e.kms_key_arn == "" ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", e.kms_key_arn))
    ])
    error_message = "endpoints[*].kms_key_arn must be empty or a KMS key ARN."
  }

  validation {
    condition = alltrue([
      for k, e in var.endpoints :
      e.postgres.heartbeat_frequency >= 1 && e.postgres.heartbeat_frequency <= 1440
    ])
    error_message = "endpoints[*].postgres.heartbeat_frequency must be between 1 and 1440 minutes."
  }
}

variable "allow_plaintext_credentials" {
  description = "Permit username/password on an endpoint. They are written to Terraform state in plaintext and returned by the DMS API, so anyone with state access or dms:DescribeEndpoints holds your database credentials. The supported path is secret_arn."
  type        = bool
  default     = false
  nullable    = false
}

variable "allow_insecure_transport" {
  description = "Permit ssl_mode = \"none\" or \"require\" on an endpoint. \"none\" sends credentials and every migrated row in cleartext across your VPC; \"require\" encrypts but does not verify the server, so it does not survive a man in the middle."
  type        = bool
  default     = false
  nullable    = false
}

variable "s3_targets" {
  description = <<-EOT
    S3 target endpoints, keyed by name. Separate from endpoints because S3 is a
    different resource with a different shape.

    The bucket is yours. The module creates the role DMS assumes to write to it
    unless you supply service_access_role_arn, and scopes that role to the
    bucket and prefix given here.
  EOT
  type = map(object({
    bucket_name             = string
    bucket_folder           = optional(string, "")
    service_access_role_arn = optional(string, "")

    data_format      = optional(string, "parquet")
    compression_type = optional(string, "GZIP")
    parquet_version  = optional(string, "parquet-2-0")

    encryption_mode = optional(string, "SSE_KMS")
    kms_key_arn     = optional(string, "")

    date_partition_enabled  = optional(bool, true)
    date_partition_sequence = optional(string, "YYYYMMDD")
    # Empty: CDC files land beside the full load under the date partitions.
    # DMS refuses CdcPath together with date partitioning or Glue catalog
    # generation; it belongs with PreserveTransactions, which the module does
    # not expose.
    cdc_path = optional(string, "")

    include_op_for_full_load = optional(bool, true)
    timestamp_column_name    = optional(string, "dms_ingest_ts")
    glue_catalog_generation  = optional(bool, false)
  }))
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for k, s in var.s3_targets : can(regex("^[a-z][a-z0-9-]{1,50}$", k))
    ])
    error_message = "s3_targets keys must be 2-51 chars, lowercase alphanumeric or hyphen, starting with a letter."
  }

  validation {
    condition = alltrue([
      for k, s in var.s3_targets : can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", s.bucket_name))
    ])
    error_message = "s3_targets[*].bucket_name must be a valid S3 bucket name."
  }

  validation {
    condition = alltrue([
      for k, s in var.s3_targets : contains(["csv", "parquet"], s.data_format)
    ])
    error_message = "s3_targets[*].data_format must be csv or parquet. Parquet is typed and columnar; csv loses every type the source had."
  }

  validation {
    condition = alltrue([
      for k, s in var.s3_targets : contains(["SSE_S3", "SSE_KMS"], s.encryption_mode)
    ])
    error_message = "s3_targets[*].encryption_mode must be SSE_S3 or SSE_KMS."
  }

  validation {
    condition = alltrue([
      for k, s in var.s3_targets : contains(["NONE", "GZIP"], s.compression_type)
    ])
    error_message = "s3_targets[*].compression_type must be NONE or GZIP."
  }

  validation {
    condition = alltrue([
      for k, s in var.s3_targets : contains(["parquet-1-0", "parquet-2-0"], s.parquet_version)
    ])
    error_message = "s3_targets[*].parquet_version must be parquet-1-0 or parquet-2-0."
  }

  validation {
    condition = alltrue([
      for k, s in var.s3_targets : s.cdc_path == "" || !(s.date_partition_enabled || s.glue_catalog_generation)
    ])
    error_message = "s3_targets[*].cdc_path cannot be combined with date_partition_enabled or glue_catalog_generation - DMS does not support either combination. Leave cdc_path empty."
  }

  validation {
    # SSE_KMS without a key means the AWS-managed S3 key, which cannot carry a
    # key policy of yours and cannot be shared cross-account.
    condition = alltrue([
      for k, s in var.s3_targets :
      s.kms_key_arn == "" ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", s.kms_key_arn))
    ])
    error_message = "s3_targets[*].kms_key_arn must be a KMS key ARN when set."
  }

  validation {
    condition = alltrue([
      for k, s in var.s3_targets :
      contains(["YYYYMMDD", "YYYYMMDDHH", "YYYYMM", "MMYYYYDD", "DDMMYYYY"], s.date_partition_sequence)
    ])
    error_message = "s3_targets[*].date_partition_sequence must be one of YYYYMMDD, YYYYMMDDHH, YYYYMM, MMYYYYDD, DDMMYYYY."
  }
}

variable "certificates" {
  description = "CA certificates DMS uses to verify a server, keyed by name. Required for ssl_mode verify-ca and verify-full. Set exactly one of pem (PEM text) or wallet (base64 of an Oracle wallet, e.g. filebase64 of cwallet.sso). For RDS, pem is the regional or global RDS CA bundle; for an on-prem source it is whatever signed the database's certificate; an Oracle endpoint verifies against a wallet, not a PEM. Rotating a CA is editing pem or wallet under the same key: the module uploads the new certificate first, repoints every endpoint, then deletes the old one, in one apply (the certificate id carries a digest of the content)."
  type = map(object({
    pem    = optional(string, "")
    wallet = optional(string, "")
  }))
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for k, c in var.certificates :
      length([for s in [c.pem, c.wallet] : s if s != ""]) == 1
    ])
    error_message = "each certificates entry must set exactly one of pem (PEM text) or wallet (base64 Oracle wallet)."
  }

  validation {
    condition = alltrue([
      for k, c in var.certificates :
      c.pem == "" ? true : can(regex("-----BEGIN CERTIFICATE-----", c.pem))
    ])
    error_message = "certificates[*].pem must contain a PEM certificate block."
  }
}

# ---------------------------------------------------------------------------
# Tasks
#
# replication_task_settings is a JSON blob, and DMS ignores keys it does not
# recognise WITHOUT ERROR. A typo in "EnableValidation" is a task that runs,
# reports success, and validates nothing. So the module renders that JSON from
# typed inputs instead of taking it as a string, checks whatever raw_overrides
# adds on top against the documented keys at plan (check
# raw_overrides_use_known_task_settings), and tests/lint_task_settings.py
# checks the shipped JSON documents the same way.
# ---------------------------------------------------------------------------

variable "tasks" {
  description = <<-EOT
    Replication tasks, keyed by name. In provisioned mode each becomes an
    aws_dms_replication_task on the replication instance; in serverless mode
    each becomes its own aws_dms_replication_config, sized by the serverless
    variable. Alarms, event subscriptions, the log group, validation_tasks and
    premigration_assessment are provisioned only.

    source_endpoint and target_endpoint are keys from endpoints or s3_targets.

    start = false (the default) creates the task stopped. start = true starts
    it on apply, and the provider then RESUMES a stopped task after any later
    modification of it - set it back to false (or remove the task) once the
    task is stopped on purpose, for example after cutover.

    Applying ANY change to a running task (table_mappings, settings,
    migration_type, the CDC start point) stops it first - the API cannot
    modify a running task. With start = false it is then left stopped and the
    apply reports success. Do not apply while a task you started from the
    console or CLI is running; if you must, resume it afterwards
    (start-replication-task --start-replication-task-type resume-processing).

    cdc_start_time and cdc_start_position are refused in serverless mode: the
    replication config has no such argument.

    table_mappings is JSON, checked at plan against the DMS table-mapping
    documentation: rule types, selection and transformation actions and
    targets, object-locators, the table-settings shapes, numeric rule-ids and
    unique rule-names. It must contain at least one selection rule: a mapping
    with only transformation rules matches no tables, and the task then
    completes successfully having moved nothing. In table and schema names "%"
    matches any run of characters and "_" matches ANY single character, so an
    exclude on STG_% also drops STGX...; escape a literal underscore (on
    Oracle, with the selection rule's escape character).
  EOT
  type = map(object({
    source_endpoint = string
    target_endpoint = string
    migration_type  = string
    table_mappings  = string

    cdc_start_time     = optional(string, "")
    cdc_start_position = optional(string, "")
    start              = optional(bool, false)

    settings = optional(object({
      logging_enabled    = optional(bool, true)
      log_level          = optional(string, "LOGGER_SEVERITY_DEFAULT")
      validation_enabled = optional(bool, true)
      # 5 is the DMS default. Every extra thread is another concurrent query
      # against a source someone else operates.
      validation_threads = optional(number, 5)
      # Empty lets DMS choose - from engine 3.5.4 it selects GROUP_LEVEL itself
      # on Oracle/SQL Server to PostgreSQL, which is materially faster.
      validation_mode = optional(string, "")
      # Oracle -> PostgreSQL with a non-C primary-key collation reports false
      # mismatches without this, and suspends validation once it has enough of
      # them. Defaults true because that pairing is this module's main path.
      handle_collation_diff        = optional(bool, true)
      validation_failure_max       = optional(number, 10000)
      validation_table_failure_max = optional(number, 1000)

      # DO_NOTHING (the default) means DMS creates nothing on the target: the
      # schema has to exist before the task starts, and a table that does not
      # suspends itself rather than failing the task, which reads as a partial
      # success. governance.tasks_expecting_a_prebuilt_target lists the tasks
      # this applies to. Building that schema is the pipeline's job; this
      # module runs no SQL.
      target_table_prep_mode = optional(string, "DO_NOTHING")
      stop_after_full_load   = optional(bool, false)
      # Pauses a full-load-and-cdc task after the load and BEFORE the changes
      # cached during it are applied: the window to build the indexes CDC
      # needs (RUNBOOK section 4). Resume the task to continue.
      stop_before_cached_changes = optional(bool, false)
      # Oracle source with CDC: a transaction still open
      # transaction_consistency_timeout seconds after the task starts is
      # skipped by DMS, and its changes never reach the target. true fails the
      # task instead, so the start is retried rather than silently lossy.
      fail_on_open_transaction        = optional(bool, true)
      transaction_consistency_timeout = optional(number, 600)
      max_full_load_subtasks          = optional(number, 8)
      commit_rate                     = optional(number, 10000)

      lob_mode          = optional(string, "LIMITED")
      lob_max_size_kb   = optional(number, 32)
      lob_chunk_size_kb = optional(number, 64)

      batch_apply_enabled   = optional(bool, false)
      parallel_load_threads = optional(number, 0)

      # Named by default. DMS writes awsdms_apply_exceptions here - failing rows
      # with their data and SQL - and in the target's default schema that is
      # production data in an unscoped table. The schema must exist on the
      # target, or the migrating user must be able to create it - create it
      # together with the target schema, before the task starts.
      control_schema      = optional(string, "dms_control")
      task_recovery_table = optional(bool, false)
      apply_error_max     = optional(number, 0)
      table_error_max     = optional(number, 50)

      raw_overrides = optional(string, "{}")
    }), {})
  }))
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for k, t in var.tasks : can(regex("^[a-z][a-z0-9-]{1,50}$", k))
    ])
    error_message = "tasks keys must be 2-51 chars, lowercase alphanumeric or hyphen, starting with a letter; they become task ids."
  }

  validation {
    condition = alltrue([
      for k, t in var.tasks :
      contains(["full-load", "cdc", "full-load-and-cdc"], t.migration_type)
    ])
    error_message = "tasks[*].migration_type must be full-load, cdc, or full-load-and-cdc."
  }

  validation {
    condition = alltrue([
      for k, t in var.tasks : can(jsondecode(t.table_mappings))
    ])
    error_message = "tasks[*].table_mappings must be valid JSON."
  }

  validation {
    condition = alltrue([
      for k, t in var.tasks :
      can(jsondecode(t.table_mappings).rules) ? true : false
    ])
    error_message = "tasks[*].table_mappings must have a top-level \"rules\" array."
  }

  validation {
    # No selection rule means no table matches, and the task reports success.
    condition = alltrue([
      for k, t in var.tasks :
      can(jsondecode(t.table_mappings).rules) ? length([
        for r in jsondecode(t.table_mappings).rules :
        r if try(r["rule-type"], "") == "selection"
      ]) > 0 : false
    ])
    error_message = "tasks[*].table_mappings must contain at least one selection rule. A mapping with only transformation rules matches no tables, and the task completes successfully having migrated nothing."
  }

  validation {
    # DMS keys its own state by rule-id; duplicates silently drop rules.
    condition = alltrue([
      for k, t in var.tasks :
      can(jsondecode(t.table_mappings).rules) ? length(distinct([
        for r in jsondecode(t.table_mappings).rules : try(r["rule-id"], "")
      ])) == length(jsondecode(t.table_mappings).rules) : false
    ])
    error_message = "tasks[*].table_mappings rule-id values must be unique."
  }

  validation {
    condition = alltrue([
      for k, t in var.tasks :
      contains(["DO_NOTHING", "TRUNCATE_BEFORE_LOAD", "DROP_AND_CREATE"], t.settings.target_table_prep_mode)
    ])
    error_message = "tasks[*].settings.target_table_prep_mode must be DO_NOTHING, TRUNCATE_BEFORE_LOAD, or DROP_AND_CREATE."
  }

  validation {
    condition = alltrue([
      for k, t in var.tasks :
      contains(["LIMITED", "FULL", "INLINE", "NONE"], t.settings.lob_mode)
    ])
    error_message = "tasks[*].settings.lob_mode must be LIMITED, FULL, INLINE, or NONE."
  }

  validation {
    condition = alltrue([
      for k, t in var.tasks : !(t.settings.batch_apply_enabled && contains(["FULL", "INLINE"], t.settings.lob_mode))
    ])
    error_message = "tasks[*].settings.batch_apply_enabled requires lob_mode LIMITED or NONE - DMS supports batch apply with LOB columns only in limited LOB mode."
  }

  validation {
    condition = alltrue([
      for k, t in var.tasks :
      contains([
        "LOGGER_SEVERITY_ERROR", "LOGGER_SEVERITY_WARNING", "LOGGER_SEVERITY_INFO",
        "LOGGER_SEVERITY_DEFAULT", "LOGGER_SEVERITY_DEBUG", "LOGGER_SEVERITY_DETAILED_DEBUG",
      ], t.settings.log_level)
    ])
    error_message = "tasks[*].settings.log_level must be a DMS logger severity such as LOGGER_SEVERITY_DEFAULT."
  }

  validation {
    condition = alltrue([
      for k, t in var.tasks : can(jsondecode(t.settings.raw_overrides))
    ])
    error_message = "tasks[*].settings.raw_overrides must be valid JSON (use \"{}\" for none)."
  }

  validation {
    # "[]", "null" and "5" are valid JSON and are not mergeable. Without this
    # the plan dies inside locals on keys(), naming neither the task nor the
    # field.
    condition = alltrue([
      for k, t in var.tasks :
      can(jsondecode(t.settings.raw_overrides)) ? can(keys(jsondecode(t.settings.raw_overrides))) : false
    ])
    error_message = "tasks[*].settings.raw_overrides must be a JSON OBJECT (use \"{}\" for none); an array, number, string or null cannot be merged into task settings."
  }

  validation {
    condition = alltrue([
      for k, t in var.tasks :
      t.settings.validation_mode == "" ? true : contains(["ROW_LEVEL", "GROUP_LEVEL"], t.settings.validation_mode)
    ])
    error_message = "tasks[*].settings.validation_mode must be empty (let DMS choose), ROW_LEVEL, or GROUP_LEVEL."
  }

  validation {
    # AWS documents 50000 as the ceiling; above it the setting is rejected at
    # task start rather than at apply.
    condition = alltrue([
      for k, t in var.tasks : t.settings.commit_rate >= 1 && t.settings.commit_rate <= 50000
    ])
    error_message = "tasks[*].settings.commit_rate must be between 1 and 50000."
  }

  validation {
    # AWS: "Increasing the value for LobChunkSize above 64 kilobytes can cause
    # task failures."
    condition = alltrue([
      for k, t in var.tasks : t.settings.lob_chunk_size_kb >= 1 && t.settings.lob_chunk_size_kb <= 64
    ])
    error_message = "tasks[*].settings.lob_chunk_size_kb must be between 1 and 64; AWS documents task failures above 64 KB."
  }

  validation {
    condition = alltrue([
      for k, t in var.tasks : t.settings.validation_threads >= 1 && t.settings.validation_threads <= 128
    ])
    error_message = "tasks[*].settings.validation_threads must be between 1 and 128. Each thread is another concurrent query against the source."
  }

  validation {
    condition = alltrue([
      for k, t in var.tasks : t.settings.parallel_load_threads >= 0 && t.settings.parallel_load_threads <= 200
    ])
    error_message = "tasks[*].settings.parallel_load_threads must be between 0 and 200."
  }

  validation {
    # cdc_start_time and cdc_start_position are mutually exclusive, and DMS
    # takes the position if both arrive.
    condition = alltrue([
      for k, t in var.tasks :
      length([for s in [t.cdc_start_time, t.cdc_start_position] : s if s != ""]) <= 1
    ])
    error_message = "tasks[*] may set at most one of cdc_start_time and cdc_start_position."
  }

  validation {
    condition = alltrue([
      for k, t in var.tasks :
      t.cdc_start_time == "" ? true : can(formatdate("YYYY-MM-DD", t.cdc_start_time))
    ])
    error_message = "tasks[*].cdc_start_time must be an RFC3339 timestamp like 2026-01-31T14:00:00Z."
  }

  validation {
    condition = alltrue([
      for k, t in var.tasks :
      t.settings.lob_max_size_kb >= 1 && t.settings.lob_max_size_kb <= 102400
    ])
    error_message = "tasks[*].settings.lob_max_size_kb must be between 1 and 102400."
  }

  validation {
    condition = alltrue([
      for k, t in var.tasks :
      t.settings.max_full_load_subtasks >= 1 && t.settings.max_full_load_subtasks <= 49
    ])
    error_message = "tasks[*].settings.max_full_load_subtasks must be between 1 and 49."
  }

  validation {
    condition = alltrue([
      for k, t in var.tasks : !(t.settings.stop_after_full_load && t.settings.stop_before_cached_changes)
    ])
    error_message = "tasks[*].settings: set at most one of stop_after_full_load and stop_before_cached_changes - they stop the task at two different points after the full load."
  }

  validation {
    condition = alltrue([
      for k, t in var.tasks : t.settings.transaction_consistency_timeout >= 0
    ])
    error_message = "tasks[*].settings.transaction_consistency_timeout must be 0 or more seconds."
  }
}

variable "validation_tasks" {
  description = <<-EOT
    Validation-only tasks, keyed by name: each compares the source and target
    of an existing entry in tasks without migrating anything, and is the
    reconciliation evidence for a change record - run a full-load one just
    before cutover to see how many rows differ at that moment.

    task     the key in tasks it validates. Endpoints and table_mappings are
             taken from it: AWS requires the same direction as the migration.
    mode     full-load (one pass, reports and stops) or cdc (validates the
             existing rows, then keeps re-validating changes). cdc needs the
             parent task to read changes.
    start    false leaves it created and stopped; start it when you need the
             answer.

    The task always renders TargetTablePrepMode = DO_NOTHING and
    ValidationOnly = true. ValidationOnly cannot change after a task is
    created, which is why this is its own map rather than a flag on tasks.
    Provisioned mode only.
  EOT
  type = map(object({
    task              = string
    mode              = optional(string, "full-load")
    start             = optional(bool, false)
    threads           = optional(number, 5)
    failure_max       = optional(number, 10000)
    table_failure_max = optional(number, 1000)
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for k, v in var.validation_tasks : can(regex("^[a-z][a-z0-9-]{1,50}$", k))])
    error_message = "validation_tasks keys must be 2-51 chars, lowercase alphanumeric or hyphen, starting with a letter; they become task ids."
  }

  validation {
    condition     = alltrue([for k, v in var.validation_tasks : contains(["full-load", "cdc"], v.mode)])
    error_message = "validation_tasks[*].mode must be full-load or cdc."
  }

  validation {
    condition     = alltrue([for k, v in var.validation_tasks : contains(keys(var.tasks), v.task)])
    error_message = "validation_tasks[*].task must be a key of tasks: a validation-only task reuses that task's endpoints and table mappings."
  }

  validation {
    condition = alltrue([
      for k, v in var.validation_tasks :
      v.threads >= 1 && v.threads <= 64 && v.failure_max >= 1 && v.table_failure_max >= 1
    ])
    error_message = "validation_tasks[*]: threads must be 1-64, failure_max and table_failure_max at least 1."
  }
}

variable "create_validation_alarms" {
  description = "Alarm on failed and suspended validation records for every task that validates, including validation_tasks. Needs sns_topic_arn and create_alarms."
  type        = bool
  default     = true
  nullable    = false
}

variable "alarm_validation_failed_records" {
  description = "Alarm when a task reports more failed validation records than this. 0 alarms on the first mismatch."
  type        = number
  default     = 0
  nullable    = false

  validation {
    condition     = var.alarm_validation_failed_records >= 0
    error_message = "alarm_validation_failed_records must be 0 or more."
  }
}

variable "premigration_assessment" {
  description = <<-EOT
    Premigration assessments: DMS checks a task against its source and target
    (unsupported types, LOBs without primary keys, missing privileges,
    supplemental logging...) and writes a report to S3, before any data moves.
    The report is change-record evidence.

    The provider has no resource for an assessment run, so the module creates
    the role DMS writes the report with and emits the exact command per task
    in output.premigration_assessment - your pipeline runs it as a gated step
    before a task is started. Results are always encrypted: SSE_KMS with
    kms_key_arn, else SSE_S3. Provisioned mode only.

    create_role = false uses role_arn (it must trust dms.amazonaws.com and be
    able to write the bucket and folder).
  EOT
  type = object({
    enabled       = optional(bool, false)
    bucket_name   = optional(string, "")
    bucket_folder = optional(string, "dms-assessments")
    kms_key_arn   = optional(string, "")
    create_role   = optional(bool, true)
    role_arn      = optional(string, "")
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.premigration_assessment.enabled ? can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.premigration_assessment.bucket_name)) : true
    error_message = "premigration_assessment.bucket_name must be an S3 bucket name when enabled."
  }

  validation {
    condition     = can(regex("^[A-Za-z0-9!_.'()-]+(/[A-Za-z0-9!_.'()-]+)*$", var.premigration_assessment.bucket_folder))
    error_message = "premigration_assessment.bucket_folder must be an S3 prefix with no leading or trailing slash and no wildcard - the role is scoped to it."
  }

  validation {
    condition     = var.premigration_assessment.kms_key_arn == "" ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.premigration_assessment.kms_key_arn))
    error_message = "premigration_assessment.kms_key_arn must be empty or a KMS key ARN."
  }

  validation {
    condition     = var.premigration_assessment.create_role ? var.premigration_assessment.role_arn == "" : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/", var.premigration_assessment.role_arn))
    error_message = "premigration_assessment: create_role = false needs role_arn (an IAM role ARN); create_role = true takes none."
  }
}

variable "allow_destructive_target_prep" {
  description = "Permit target_table_prep_mode = DROP_AND_CREATE or TRUNCATE_BEFORE_LOAD. Both delete data in the target before loading: DROP_AND_CREATE also discards indexes, constraints and grants the target already had, and DMS recreates only what it can infer from the source."
  type        = bool
  default     = false
  nullable    = false
}

# ---------------------------------------------------------------------------
# Observability
#
# A stopped CDC task is the failure that matters. The target stops receiving
# changes, nothing errors, dashboards stay green, and the gap is only discovered
# at cutover - by which point the source has moved on.
# ---------------------------------------------------------------------------

variable "sns_topic_arn" {
  description = "Topic for DMS event subscriptions and CloudWatch alarms. Empty disables both, which means a failed task tells nobody."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.sns_topic_arn == "" ? true : can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:", var.sns_topic_arn))
    error_message = "sns_topic_arn must be empty or an SNS topic ARN."
  }
}

variable "sns_topic_kms_key_arn" {
  description = "The customer-managed key the SNS topic is encrypted with, if any. The module does not use it; it lists what the key policy must allow in output.kms_key_policy_requirements, because a topic whose key DMS, CloudWatch and EventBridge cannot use drops every notification without an error anywhere."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.sns_topic_kms_key_arn == "" ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:(key|alias)/", var.sns_topic_kms_key_arn))
    error_message = "sns_topic_kms_key_arn must be a KMS key or alias ARN."
  }
}

variable "create_event_subscriptions" {
  description = "Subscribe to DMS instance and task events. No-op without sns_topic_arn."
  type        = bool
  default     = true
  nullable    = false
}

variable "instance_event_categories" {
  description = "Replication instance event categories to notify on."
  type        = list(string)
  # failover: multi_az defaults to true, and a failover mid-load is worth
  # knowing about.
  default  = ["failure", "low storage", "maintenance", "configuration change", "failover"]
  nullable = false

  validation {
    condition = alltrue([
      for c in var.instance_event_categories :
      contains(["low storage", "configuration change", "maintenance", "deletion", "creation", "failover", "failure"], c)
    ])
    error_message = "instance_event_categories entries must be DMS replication-instance categories: low storage, configuration change, maintenance, deletion, creation, failover, failure."
  }
}

variable "task_event_categories" {
  description = "Replication task event categories. \"state change\" is the one that catches a task stopping on its own."
  type        = list(string)
  default     = ["failure", "state change", "configuration change", "deletion"]
  nullable    = false

  validation {
    condition = alltrue([
      for c in var.task_event_categories :
      contains(["state change", "configuration change", "deletion", "creation", "failure"], c)
    ])
    error_message = "task_event_categories entries must be DMS replication-task categories: state change, configuration change, deletion, creation, failure."
  }
}

variable "create_alarms" {
  description = "Create the CloudWatch alarms that catch a migration going wrong quietly: CDC latency on both sides, instance storage, CPU, and memory. No-op without sns_topic_arn."
  type        = bool
  default     = true
  nullable    = false
}

variable "alarm_cdc_latency_seconds" {
  description = "Alarm when CDC latency to the target stays above this. Latency that grows without bound means the target will never catch up, and a cutover window sized on today's lag will not hold."
  type        = number
  default     = 300
  nullable    = false

  validation {
    condition     = var.alarm_cdc_latency_seconds >= 30 && var.alarm_cdc_latency_seconds <= 86400
    error_message = "alarm_cdc_latency_seconds must be between 30 and 86400."
  }
}

variable "alarm_free_storage_bytes" {
  description = "Alarm when the replication instance's free storage drops below this. A full disk stops every task on the instance. 0 (the default) means 15% of allocated_storage_gb, so the threshold follows the volume."
  type        = number
  default     = 0
  nullable    = false

  validation {
    condition     = var.alarm_free_storage_bytes == 0 ? true : var.alarm_free_storage_bytes >= 1073741824
    error_message = "alarm_free_storage_bytes must be 0 (15% of the volume) or at least 1 GiB."
  }
}

variable "alarm_cpu_percent" {
  description = "Alarm when replication instance CPU stays above this."
  type        = number
  default     = 80
  nullable    = false

  validation {
    condition     = var.alarm_cpu_percent > 0 && var.alarm_cpu_percent <= 100
    error_message = "alarm_cpu_percent must be between 1 and 100."
  }
}

variable "alarm_freeable_memory_bytes" {
  description = "Alarm when freeable memory on the replication instance drops below this. DMS swapping is the usual cause of a load that never finishes."
  type        = number
  default     = 536870912
  nullable    = false

  validation {
    condition     = var.alarm_freeable_memory_bytes >= 134217728
    error_message = "alarm_freeable_memory_bytes must be at least 128 MiB."
  }
}

variable "create_log_group" {
  description = "Create the dms-tasks-<name> log group so retention applies before DMS writes to it. Set false when the group already exists - DMS creates it on first task start with no expiry, and Terraform then fails with ResourceAlreadyExistsException."
  type        = bool
  default     = true
  nullable    = false
}

variable "log_group_skip_destroy" {
  description = "Keep the task log group, and the logs in it, when Terraform destroys the module - the teardown after cutover would otherwise delete the evidence the retention was set to keep. The group still expires its logs after log_retention_days."
  type        = bool
  default     = true
  nullable    = false
}

variable "log_retention_days" {
  description = "Retention on the task log group. Left to DMS these logs never expire, and a chatty CDC task at LOGGER_SEVERITY_DEBUG produces a lot of them. 0 means never expire."
  type        = number
  default     = 30
  nullable    = false

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be 0 or one of the retention periods CloudWatch Logs accepts."
  }
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------

variable "create_account_service_roles" {
  description = <<-EOT
    Create the account-wide DMS service roles: dms-vpc-role, dms-cloudwatch-logs-role.

    These have FIXED names, one set per account, and DMS will not work without
    them. Leave false and create them once in your landing zone - two modules
    both creating dms-vpc-role is an EntityAlreadyExists error on the second
    apply, and a destroy on either one breaks every migration in the account.

    output.account_prerequisites names what is required either way.
  EOT
  type        = bool
  default     = false
  nullable    = false
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for every role this module creates, except the account-wide dms-vpc-role and dms-cloudwatch-logs-role: those carry AWS-managed policies DMS needs in full."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.permissions_boundary_arn == "" ? true : can(regex("^arn:aws[a-z-]*:iam::(aws|[0-9]{12}):policy/", var.permissions_boundary_arn))
    error_message = "permissions_boundary_arn must be empty or an IAM policy ARN."
  }
}
