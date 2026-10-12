# Everything is nullable = false. Every value that is rendered into the SQL
# runner script (targets, the scripts location) is validated against a pattern
# that cannot contain a quote or a shell metacharacter: the script is plain
# bash, and these values land inside it verbatim.
#
# Conditions are ternaries, can() or alltrue([for ...]). Never `x == "" || f(x)`:
# Terraform 1.9 evaluates both sides.

variable "create" {
  description = "Master switch. false plans and applies cleanly to nothing."
  type        = bool
  default     = true
  nullable    = false
}

variable "name" {
  description = "Name prefix for every resource. Use the same name as the dms module's migration."
  type        = string
  nullable    = false

  validation {
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
# Instance
# ---------------------------------------------------------------------------

variable "ami_id" {
  description = <<-EOT
    The AMI to run, used verbatim. The module never looks one up and passes no
    user data: in an isolated VPC the image has to arrive complete. It must
    carry the SSM agent, AWS CLI v2, python3, and the client for every target
    engine (psql, mysql or the MariaDB client, sqlplus), plus any CA bundle a
    target's ca_bundle_path names. A missing client fails the run with exit
    code 4 and says which.
  EOT
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.ami_id))
    error_message = "ami_id must be an AMI id, e.g. ami-0123456789abcdef0."
  }
}

variable "instance_type" {
  description = "Instance type. The bastion only runs database clients; the database does the work."
  type        = string
  default     = "t3.small"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*\\.[a-z0-9]+$", var.instance_type))
    error_message = "instance_type must look like t3.small."
  }
}

variable "running" {
  description = "false stops the instance and keeps it. Set false between migration waves: a stopped bastion costs its volume and nothing else, and has no session to open."
  type        = bool
  default     = true
  nullable    = false
}

variable "vpc_id" {
  description = "VPC the bastion runs in - the one DMS runs in, so it reaches what DMS reaches."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id))
    error_message = "vpc_id must be a VPC id."
  }
}

variable "subnet_id" {
  description = "Private subnet for the bastion. One of the DMS replication subnet group's subnets is the natural choice: its routes to the databases are already proven."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^subnet-[0-9a-f]{8,17}$", var.subnet_id))
    error_message = "subnet_id must be a subnet id."
  }
}

variable "root_volume_size_gb" {
  description = "Root volume size. Scripts are copied to /tmp for the length of one run and removed after."
  type        = number
  default     = 20
  nullable    = false

  validation {
    condition     = var.root_volume_size_gb >= 8 && var.root_volume_size_gb <= 1024
    error_message = "root_volume_size_gb must be between 8 and 1024."
  }
}

variable "kms_key_arn" {
  description = "Customer-managed key for the root volume and the run log group. Empty uses the AWS-managed keys. output.kms_key_policy_requirements says what the key policy must allow."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.kms_key_arn == "" ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN."
  }
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for the instance role."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.permissions_boundary_arn == "" ? true : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:policy/", var.permissions_boundary_arn))
    error_message = "permissions_boundary_arn must be an IAM policy ARN."
  }
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

variable "https_egress" {
  description = <<-EOT
    Where the bastion may reach on 443: the VPC endpoints' security group, and
    the S3 gateway endpoint's prefix list. Nothing else leaves on 443. The
    endpoints it needs are listed in output.network_contract.
  EOT
  type = object({
    security_group_ids = optional(list(string), [])
    prefix_list_ids    = optional(list(string), [])
    cidr_blocks        = optional(list(string), [])
  })
  default  = {}
  nullable = false

  validation {
    condition = alltrue(concat(
      [for id in var.https_egress.security_group_ids : can(regex("^sg-[0-9a-f]{8,17}$", id))],
      [for id in var.https_egress.prefix_list_ids : can(regex("^pl-[0-9a-f]{8,17}$", id))],
      [for c in var.https_egress.cidr_blocks : can(cidrhost(c, 0))],
    ))
    error_message = "https_egress holds security group ids (sg-), prefix list ids (pl-) and IPv4 CIDR blocks."
  }

  validation {
    condition     = length(var.https_egress.security_group_ids) + length(var.https_egress.prefix_list_ids) + length(var.https_egress.cidr_blocks) > 0
    error_message = "https_egress is empty, so the bastion cannot reach SSM, Secrets Manager or S3 and will never register. Give it at least the VPC endpoints' security group and the S3 prefix list."
  }
}

# ---------------------------------------------------------------------------
# Scripts
# ---------------------------------------------------------------------------

variable "scripts" {
  description = <<-EOT
    Where the SQL scripts live. The bastion reads bucket_name/prefix/<key> and
    nothing else in the bucket. Turn versioning on for the bucket: the run log
    records the object version and SHA-256 of what ran, and with versioning that
    version can be fetched again later.
  EOT
  type = object({
    bucket_name = string
    prefix      = optional(string, "migrations")
    kms_key_arn = optional(string, "")
  })
  nullable = false

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.scripts.bucket_name))
    error_message = "scripts.bucket_name must be a valid S3 bucket name."
  }

  validation {
    condition     = var.scripts.prefix == "" ? true : (can(regex("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*/?$", var.scripts.prefix)) && !strcontains(var.scripts.prefix, ".."))
    error_message = "scripts.prefix must be a relative S3 prefix of letters, digits, dot, underscore, hyphen and slash, without \"..\"."
  }

  validation {
    condition     = var.scripts.kms_key_arn == "" ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.scripts.kms_key_arn))
    error_message = "scripts.kms_key_arn must be a KMS key ARN."
  }
}

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

variable "targets" {
  description = <<-EOT
    The databases scripts run against, keyed by a name you choose. The key is
    what an operator picks as the Target parameter of the run document.

    secret_arn holds the credential: a JSON secret with "username" and
    "password". Use the schema owner (the migrator), not the DMS user and not
    the RDS master. host, port and database come from here, not from the
    secret.

    ssl_mode:
      postgres family  verify-full (default), verify-ca, require, disable
      mysql family     verify-full (default), verify-ca, require, disable
      oracle           none (default) - the runner does not manage TCPS; use
                       Oracle native network encryption configured in the
                       AMI's sqlnet.ora
    verify-full and verify-ca need ca_bundle_path: a CA bundle baked into the
    AMI (for RDS and Aurora, the regional or global RDS bundle). require and
    disable are refused unless allow_insecure_transport.

    security_group_id: the database's security group. The module adds an
    ingress rule on it from the bastion, and an egress rule to it. For a
    database outside AWS set cidr_blocks instead (egress only).

    client_options: extra arguments for this target's client, appended as
    separate argv entries (never through a shell), e.g. ["--quiet"] for psql.
    env: extra environment for the client and for shell steps, e.g.
    { PGOPTIONS = "-c lock_timeout=30s" } or { NLS_LANG = "AMERICAN_AMERICA.AL32UTF8" }.
    variables: defaults for script variables on this target; a step's own
    variables override them (see runbooks).
  EOT
  type = map(object({
    engine     = string
    host       = string
    port       = number
    database   = string
    secret_arn = string

    secret_kms_key_arn = optional(string, "")
    ssl_mode           = optional(string, "")
    ca_bundle_path     = optional(string, "")

    security_group_id = optional(string, "")
    cidr_blocks       = optional(list(string), [])

    client_options = optional(list(string), [])
    env            = optional(map(string), {})
    variables      = optional(map(string), {})
  }))
  nullable = false

  validation {
    condition     = length(var.targets) > 0
    error_message = "targets is empty: the run document needs at least one database to offer."
  }

  validation {
    condition     = alltrue([for k, t in var.targets : can(regex("^[a-z][a-z0-9-]{0,30}$", k))])
    error_message = "targets keys must be 1-31 chars, lowercase alphanumeric or hyphen, starting with a letter."
  }

  validation {
    condition = alltrue([
      for k, t in var.targets : contains([
        "postgres", "aurora-postgresql", "mysql", "mariadb", "aurora-mysql", "oracle",
      ], t.engine)
    ])
    error_message = "targets[*].engine must be postgres, aurora-postgresql, mysql, mariadb, aurora-mysql or oracle."
  }

  validation {
    condition     = alltrue([for k, t in var.targets : can(regex("^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$", t.host))])
    error_message = "targets[*].host must be a hostname or IPv4 address."
  }

  validation {
    condition     = alltrue([for k, t in var.targets : t.port >= 1 && t.port <= 65535 && floor(t.port) == t.port])
    error_message = "targets[*].port must be an integer between 1 and 65535."
  }

  validation {
    # Oracle service names carry dots; nothing here may carry a quote.
    condition     = alltrue([for k, t in var.targets : can(regex("^[A-Za-z0-9_$#.-]{1,128}$", t.database))])
    error_message = "targets[*].database must be 1-128 chars of letters, digits, _ $ # . or -. For Oracle it is the service name."
  }

  validation {
    condition     = alltrue([for k, t in var.targets : can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+$", t.secret_arn))])
    error_message = "targets[*].secret_arn must be a Secrets Manager secret ARN."
  }

  validation {
    condition = alltrue([
      for k, t in var.targets :
      t.secret_kms_key_arn == "" ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", t.secret_kms_key_arn))
    ])
    error_message = "targets[*].secret_kms_key_arn must be a KMS key ARN."
  }

  validation {
    condition = alltrue([
      for k, t in var.targets :
      t.engine == "oracle" ? contains(["", "none"], t.ssl_mode) : contains(["", "verify-full", "verify-ca", "require", "disable"], t.ssl_mode)
    ])
    error_message = "targets[*].ssl_mode: oracle takes none; the postgres and mysql families take verify-full, verify-ca, require or disable."
  }

  validation {
    condition = alltrue([
      for k, t in var.targets :
      t.ca_bundle_path == "" ? true : can(regex("^/[A-Za-z0-9._/-]+$", t.ca_bundle_path))
    ])
    error_message = "targets[*].ca_bundle_path must be an absolute path on the AMI."
  }

  validation {
    # "" resolves to verify-full for these engines.
    condition = alltrue([
      for k, t in var.targets :
      t.engine != "oracle" && contains(["", "verify-full", "verify-ca"], t.ssl_mode) ? t.ca_bundle_path != "" : true
    ])
    error_message = "a target that verifies the server certificate (ssl_mode verify-full, the default, or verify-ca) needs ca_bundle_path: the CA bundle baked into the AMI."
  }

  validation {
    condition = alltrue([
      for k, t in var.targets :
      t.security_group_id == "" ? true : can(regex("^sg-[0-9a-f]{8,17}$", t.security_group_id))
    ])
    error_message = "targets[*].security_group_id must be a security group id."
  }

  validation {
    condition     = alltrue(flatten([for k, t in var.targets : [for c in t.cidr_blocks : can(cidrhost(c, 0))]]))
    error_message = "targets[*].cidr_blocks must be IPv4 CIDR blocks."
  }

  validation {
    condition     = alltrue([for k, t in var.targets : t.security_group_id != "" || length(t.cidr_blocks) > 0])
    error_message = "every target needs security_group_id or cidr_blocks: the bastion has no egress to a database it is not told about."
  }

  validation {
    # argv entries, never a shell - but no newline, so the run log stays one
    # line per argument.
    condition     = alltrue(flatten([for k, t in var.targets : [for o in t.client_options : can(regex("^[^\n\r]{1,256}$", o))]]))
    error_message = "targets[*].client_options entries must be 1-256 characters with no newline."
  }

  validation {
    condition = alltrue(flatten([for k, t in var.targets : [
      for n, v in t.env : can(regex("^[A-Z_][A-Z0-9_]{0,63}$", n)) && can(regex("^[^\n\r]{0,1000}$", v)) && !contains(local.reserved_env, n)
    ]]))
    error_message = "targets[*].env names must be upper-case identifiers, values must have no newline, and the module's own variables (PGPASSWORD, DB_PASSWORD, DB_USER, ...) cannot be overridden."
  }

  validation {
    condition = alltrue(flatten([for k, t in var.targets : [
      for n, v in t.variables : can(regex("^[A-Za-z_][A-Za-z0-9_]{0,63}$", n)) && can(regex("^[A-Za-z0-9 _.,:/@+%-]{0,256}$", v))
    ]]))
    error_message = "targets[*].variables: names are identifiers; values are letters, digits, space and _ . , : / @ + % - only (they land inside SQL)."
  }
}

variable "allow_insecure_transport" {
  description = "Permit ssl_mode require (encrypted, server not verified) or disable on a postgres or mysql family target."
  type        = bool
  default     = false
  nullable    = false
}

variable "manage_target_ingress" {
  description = "Add an ingress rule from the bastion on each target's security_group_id. false if the database's security group is owned elsewhere; output.network_contract then lists the rules to request."
  type        = bool
  default     = true
  nullable    = false
}

# ---------------------------------------------------------------------------
# Runs
# ---------------------------------------------------------------------------

variable "default_timeout_seconds" {
  description = "Timeout for a step that sets none. The runner stops the client when it expires, and the database rolls back the open transaction when the connection drops."
  type        = number
  default     = 3600
  nullable    = false

  validation {
    condition     = var.default_timeout_seconds >= 60 && var.default_timeout_seconds <= 172800
    error_message = "default_timeout_seconds must be between 60 and 172800 (48 h, the SSM maximum)."
  }
}

variable "log_retention_days" {
  description = "Retention for the run log group, where Run Command writes each run's output when the command asks for it (output.commands does)."
  type        = number
  default     = 365
  nullable    = false

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a value CloudWatch Logs accepts (1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653)."
  }
}

variable "run_timeout_seconds" {
  description = "Default TimeoutSeconds of the document: the whole run, every step of a runbook included. SSM stops the runner when it expires, and the runner stops the step in flight."
  type        = number
  default     = 28800
  nullable    = false

  validation {
    condition     = var.run_timeout_seconds >= 60 && var.run_timeout_seconds <= 172800
    error_message = "run_timeout_seconds must be between 60 and 172800 (48 h, the SSM maximum)."
  }
}

# ---------------------------------------------------------------------------
# Runbooks
# ---------------------------------------------------------------------------

variable "runbooks" {
  description = <<-EOT
    Named, ordered lists of steps, reviewed in the plan. An operator runs one
    with Mode=runbook, Runbook=<name>. Steps run in list order; a failing step
    stops the run unless its on_error is "continue" (the run then still ends
    failed). StartAt=<step name> resumes from a step; DryRun=true verifies
    every script's SHA-256 and connects to every target without executing.

    Each step:
      name            unique within the runbook; default step-<n>
      target          a targets key
      script          object key under scripts.prefix
      sha256          optional; the run refuses any other content
      type            "sql" (default) or "shell" (default for *.sh; needs
                      allow_shell_steps). A shell step runs with bash and
                      gets the connection in DB_HOST, DB_PORT, DB_NAME,
                      DB_USER, DB_PASSWORD, DB_SSL_MODE, DB_CA_BUNDLE (plus
                      PG* for PostgreSQL, DB_MYSQL_DEFAULTS_FILE for MySQL)
                      and its variables as environment.
      transaction     auto (default), single or none - see the document
      timeout_seconds default default_timeout_seconds
      on_error        "stop" (default) or "continue"
      variables       map of name => value. psql: --set (use :'name' in SQL).
                      MySQL: SET @name = 'value' before the script.
                      SQL*Plus: DEFINE (use &name in SQL).

    The same step shape is what a manifest in S3 holds (see
    allow_s3_manifests): {"description": "...", "steps": [ ... ]}.
  EOT
  type = map(object({
    description = optional(string, "")
    steps = list(object({
      name            = optional(string, "")
      target          = string
      script          = string
      sha256          = optional(string, "")
      type            = optional(string, "")
      transaction     = optional(string, "auto")
      timeout_seconds = optional(number, 0)
      on_error        = optional(string, "stop")
      variables       = optional(map(string), {})
    }))
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for k, r in var.runbooks : can(regex("^[a-z][a-z0-9-]{0,40}$", k))])
    error_message = "runbooks keys must be 1-41 chars, lowercase alphanumeric or hyphen, starting with a letter."
  }

  validation {
    condition     = alltrue([for k, r in var.runbooks : length(r.steps) > 0 && length(r.steps) <= 200])
    error_message = "every runbook needs 1 to 200 steps."
  }

  validation {
    condition     = alltrue([for k, r in var.runbooks : can(regex("^[^\n\r]{0,256}$", r.description))])
    error_message = "runbooks[*].description must be one line of at most 256 characters."
  }

  validation {
    condition = alltrue(flatten([for k, r in var.runbooks : [
      for s in r.steps : s.name == "" ? true : can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", s.name))
    ]]))
    error_message = "runbooks[*].steps[*].name must be 1-64 chars of letters, digits, . _ - starting with a letter or digit."
  }

  validation {
    condition = alltrue([for k, r in var.runbooks : length([
      for i, s in r.steps : (s.name != "" ? s.name : "step-${i + 1}")
      ]) == length(distinct([
        for i, s in r.steps : (s.name != "" ? s.name : "step-${i + 1}")
    ]))])
    error_message = "step names must be unique within a runbook: StartAt resumes by name."
  }

  validation {
    condition     = alltrue(flatten([for k, r in var.runbooks : [for s in r.steps : contains(keys(var.targets), s.target)]]))
    error_message = "every runbook step's target must be a targets key."
  }

  validation {
    condition = alltrue(flatten([for k, r in var.runbooks : [
      for s in r.steps : can(regex("^[A-Za-z0-9][A-Za-z0-9._/-]{0,511}$", s.script)) && !strcontains(s.script, "..")
    ]]))
    error_message = "runbooks[*].steps[*].script must be a relative object key (letters, digits, . _ / -), without \"..\"."
  }

  validation {
    condition = alltrue(flatten([for k, r in var.runbooks : [
      for s in r.steps : s.sha256 == "" ? true : can(regex("^[a-f0-9]{64}$", s.sha256))
    ]]))
    error_message = "runbooks[*].steps[*].sha256 must be 64 lowercase hex characters."
  }

  validation {
    condition     = alltrue(flatten([for k, r in var.runbooks : [for s in r.steps : contains(["", "sql", "shell"], s.type)]]))
    error_message = "runbooks[*].steps[*].type must be sql or shell."
  }

  validation {
    condition = alltrue(flatten([for k, r in var.runbooks : [
      for s in r.steps : (s.type == "shell" || (s.type == "" && endswith(s.script, ".sh"))) ? var.allow_shell_steps : true
    ]]))
    error_message = "a runbook has a shell step (type = \"shell\", or a .sh script) and allow_shell_steps is false."
  }

  validation {
    condition     = alltrue(flatten([for k, r in var.runbooks : [for s in r.steps : contains(["auto", "single", "none"], s.transaction)]]))
    error_message = "runbooks[*].steps[*].transaction must be auto, single or none."
  }

  validation {
    condition = alltrue(flatten([for k, r in var.runbooks : [
      for s in r.steps : s.transaction == "single" ? try(local.engine_family[var.targets[s.target].engine], "") != "mysql" : true
    ]]))
    error_message = "transaction = \"single\" on a MySQL-family target is refused: MySQL DDL commits implicitly and would not roll back."
  }

  validation {
    condition = alltrue(flatten([for k, r in var.runbooks : [
      for s in r.steps : s.timeout_seconds == 0 || (s.timeout_seconds >= 1 && s.timeout_seconds <= 172800 && floor(s.timeout_seconds) == s.timeout_seconds)
    ]]))
    error_message = "runbooks[*].steps[*].timeout_seconds must be 0 (use default_timeout_seconds) or an integer from 1 to 172800."
  }

  validation {
    condition     = alltrue(flatten([for k, r in var.runbooks : [for s in r.steps : contains(["stop", "continue"], s.on_error)]]))
    error_message = "runbooks[*].steps[*].on_error must be stop or continue."
  }

  validation {
    condition = alltrue(flatten([for k, r in var.runbooks : [for s in r.steps : [
      for n, v in s.variables : can(regex("^[A-Za-z_][A-Za-z0-9_]{0,63}$", n)) && can(regex("^[A-Za-z0-9 _.,:/@+%-]{0,256}$", v))
    ]]]))
    error_message = "runbooks[*].steps[*].variables: names are identifiers; values are letters, digits, space and _ . , : / @ + % - only (they land inside SQL)."
  }
}

variable "allow_s3_manifests" {
  description = "Permit Mode=manifest: an operator runs an ordered list of steps from a JSON file under scripts.prefix, without an apply. Same step shape and the same checks as a runbook. false means only runbooks reviewed in the plan can run more than one script."
  type        = bool
  default     = true
  nullable    = false
}

variable "allow_shell_steps" {
  description = "Permit steps of type shell: a bash script from the scripts prefix, run as root on the bastion with the target's credential in its environment. Use it for what SQL cannot do (pg_dump, pg_restore, a loop over schemas). Off by default, because a shell step can do anything the instance role can."
  type        = bool
  default     = false
  nullable    = false
}

# ---------------------------------------------------------------------------
# Extension points
# ---------------------------------------------------------------------------

variable "additional_security_group_ids" {
  description = "More security groups for the instance, e.g. one a platform team already maintains for reaching shared services."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for id in var.additional_security_group_ids : can(regex("^sg-[0-9a-f]{8,17}$", id))])
    error_message = "additional_security_group_ids must be security group ids."
  }
}

variable "additional_egress_rules" {
  description = "More egress from the bastion's own security group, keyed by a name you choose. Exactly one of security_group_id, prefix_list_id or cidr per rule."
  type = map(object({
    description       = optional(string, "")
    protocol          = optional(string, "tcp")
    from_port         = number
    to_port           = number
    security_group_id = optional(string, "")
    prefix_list_id    = optional(string, "")
    cidr              = optional(string, "")
  }))
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for k, r in var.additional_egress_rules :
      length(compact([r.security_group_id, r.prefix_list_id, r.cidr])) == 1
    ])
    error_message = "each additional_egress_rules entry needs exactly one of security_group_id, prefix_list_id or cidr."
  }

  validation {
    condition = alltrue([
      for k, r in var.additional_egress_rules :
      contains(["tcp", "udp"], r.protocol) && r.from_port >= 0 && r.to_port <= 65535 && r.from_port <= r.to_port
    ])
    error_message = "additional_egress_rules: protocol tcp or udp, 0 <= from_port <= to_port <= 65535."
  }

  validation {
    condition = alltrue([
      for k, r in var.additional_egress_rules :
      r.cidr == "" ? true : can(cidrhost(r.cidr, 0))
    ])
    error_message = "additional_egress_rules[*].cidr must be an IPv4 CIDR block."
  }
}

variable "additional_iam_policy_arns" {
  description = "Managed policies to attach to the instance role, e.g. read on a second bucket a shell step needs."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for a in var.additional_iam_policy_arns : can(regex("^arn:aws[a-z-]*:iam::([0-9]{12}|aws):policy/", a))])
    error_message = "additional_iam_policy_arns must be IAM policy ARNs."
  }
}

variable "additional_iam_policy_json" {
  description = "An inline policy document added to the instance role, for permissions specific to this migration."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.additional_iam_policy_json == "" ? true : can(jsondecode(var.additional_iam_policy_json).Statement)
    error_message = "additional_iam_policy_json must be an IAM policy document (JSON with a Statement)."
  }
}
