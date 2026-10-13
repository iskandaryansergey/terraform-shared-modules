variable "create" {
  description = "Master switch. false plans to nothing and leaves every output null or empty."
  type        = bool
  default     = true
  nullable    = false
}

variable "name" {
  description = "Name of the key set, e.g. the workload. Prefixes the default alias of every key (alias/<name>-<key>) and names the notification rules."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,40}$", var.name))
    error_message = "name must be 2-41 chars, lowercase alphanumeric or hyphen, starting with a letter."
  }
}

variable "tags" {
  description = "Tags for every resource the module creates. key_defaults.tags and each key's tags are merged over them; the module's own keys (ManagedBy, Module, KeySet, Key) always win."
  type        = map(string)
  default     = {}
  nullable    = false

  validation {
    condition     = alltrue([for k, v in var.tags : length(k) <= 128 && length(v) <= 256 && !startswith(lower(k), "aws:")])
    error_message = "tags keys must be <= 128 chars, values <= 256 chars, and no key may use the reserved \"aws:\" prefix."
  }
}

variable "required_tag_keys" {
  description = "Tag keys every key must carry with a non-empty value after merging (CostCentre, Owner...), for estates where every billable resource has to be attributable. Checked at plan on each key. Empty enforces nothing."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for k in var.required_tag_keys : length(k) > 0 && length(k) <= 128])
    error_message = "required_tag_keys entries must be tag keys of 1-128 chars."
  }
}

variable "acknowledged_checks" {
  description = <<-EOT
    Advisory checks this caller has decided to live with, by name. An
    acknowledged check stops warning and is listed in output.governance so a
    reviewer still sees the decision. Names: symmetric_keys_rotate,
    deletion_window_leaves_time_to_notice, every_requirement_found_its_key,
    every_principal_role_is_resolved, every_requirement_is_machine_readable,
    keys_have_an_organization_perimeter, deletion_protection_has_an_exemption,
    cloudtrail_events_need_a_trail, multi_region_keys_are_replicated,
    key_policies_leave_room_to_grow, strict_mode_keeps_services_named,
    replicas_have_their_vpc_endpoints.
  EOT
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([for c in var.acknowledged_checks : contains([
      "symmetric_keys_rotate",
      "deletion_window_leaves_time_to_notice",
      "every_requirement_found_its_key",
      "every_principal_role_is_resolved",
      "every_requirement_is_machine_readable",
      "keys_have_an_organization_perimeter",
      "deletion_protection_has_an_exemption",
      "cloudtrail_events_need_a_trail",
      "multi_region_keys_are_replicated",
      "key_policies_leave_room_to_grow",
      "strict_mode_keeps_services_named",
      "replicas_have_their_vpc_endpoints",
    ], c)])
    error_message = "acknowledged_checks names a check that does not exist: ${join(", ", var.acknowledged_checks)}. See this variable's description for the names."
  }
}

# ---------------------------------------------------------------------------
# Keys
# ---------------------------------------------------------------------------

variable "keys" {
  description = <<-EOT
    The key set, keyed by a short name. Each entry is one customer managed key:
    $1/month, plus $1/month for each of its first two rotations ($3 at most),
    plus the same per replica. The default is one symmetric key, "main".

    purpose            a profile: logs, secrets, database, storage, messaging
                       (service presets), signing (ECC_NIST_P256 SIGN_VERIFY),
                       mac (HMAC_256), dnssec (Route 53 DNSSEC key-signing key).
                       Its presets are added to services; spec and usage
                       override it.
    spec / usage       default SYMMETRIC_DEFAULT / ENCRYPT_DECRYPT, the only
                       kind AWS services use. Force a new key when changed.
    aliases            names without "alias/"; default ["<name>-<key>"].
    rotation, rotation_period_days, deletion_window_days, service_access
                       null takes key_defaults.
    multi_region       a multi-Region primary. Forces a new key when changed.
    replicate          a replica in the aws.replica provider's region.
    services           service presets (README "Service presets").
    via_services       extra caller-path services as kms:ViaService names,
                       "<service>.%s.amazonaws.com" (%s = the key's region).
    service_access     who may use the key through those services: "account"
                       (any principal in the account and in accounts, the AWS
                       managed key pattern) or "named" (users, encrypters,
                       decrypters, deployers and the accounts only).
    accounts           other AWS accounts (12-digit IDs) that may use the key;
                       their side needs an IAM policy (output.iam_policy_statements).
    administrators, users, auditors, encrypters, decrypters, grant_users
                       added to the module-level lists for this key.
    require_encryption_context
                       encryption context keys that direct use by users,
                       encrypters and decrypters must carry (symmetric keys).
    custom_key_store_id / xks_key_id
                       create the key in an existing CloudHSM or external key
                       store (symmetric, single-Region, no rotation).
    grants             explicit grants; any change recreates the grant.
    extra_statements   JSON list of policy statements, the escape hatch.
  EOT
  type = map(object({
    description                = optional(string, "")
    purpose                    = optional(string, "")
    spec                       = optional(string, "")
    usage                      = optional(string, "")
    aliases                    = optional(list(string), [])
    enabled                    = optional(bool, true)
    rotation                   = optional(bool)
    rotation_period_days       = optional(number)
    deletion_window_days       = optional(number)
    multi_region               = optional(bool, false)
    replicate                  = optional(bool, false)
    services                   = optional(list(string), [])
    via_services               = optional(list(string), [])
    service_access             = optional(string)
    accounts                   = optional(list(string), [])
    administrators             = optional(list(string), [])
    users                      = optional(list(string), [])
    auditors                   = optional(list(string), [])
    encrypters                 = optional(list(string), [])
    decrypters                 = optional(list(string), [])
    grant_users                = optional(list(string), [])
    require_encryption_context = optional(list(string), [])
    custom_key_store_id        = optional(string, "")
    xks_key_id                 = optional(string, "")
    grants = optional(map(object({
      grantee_principal         = string
      operations                = list(string)
      retiring_principal        = optional(string, "")
      retire_on_delete          = optional(bool, false)
      encryption_context_equals = optional(map(string), {})
      encryption_context_subset = optional(map(string), {})
    })), {})
    extra_statements = optional(string, "")
    tags             = optional(map(string), {})
  }))
  default  = { main = {} }
  nullable = false

  validation {
    condition     = length(var.keys) > 0
    error_message = "keys is empty. Name at least one key, or leave keys unset for one key called main."
  }

  validation {
    condition     = alltrue([for k, v in var.keys : can(regex("^[a-z][a-z0-9-]{0,30}$", k))])
    error_message = "keys names must be 1-31 chars, lowercase alphanumeric or hyphen, starting with a letter: ${join(", ", [for k, v in var.keys : k if !can(regex("^[a-z][a-z0-9-]{0,30}$", k))])}."
  }

  validation {
    condition     = alltrue([for k, v in var.keys : contains(["", "logs", "secrets", "database", "storage", "messaging", "signing", "mac", "dnssec"], v.purpose)])
    error_message = "keys[*].purpose must be one of logs, secrets, database, storage, messaging, signing, mac, dnssec (or empty): ${join(", ", [for k, v in var.keys : k if !contains(["", "logs", "secrets", "database", "storage", "messaging", "signing", "mac", "dnssec"], v.purpose)])}."
  }

  validation {
    condition = alltrue([for k, v in var.keys : contains([
      "", "SYMMETRIC_DEFAULT", "RSA_2048", "RSA_3072", "RSA_4096", "ECC_NIST_P256", "ECC_NIST_P384", "ECC_NIST_P521",
      "ECC_SECG_P256K1", "HMAC_224", "HMAC_256", "HMAC_384", "HMAC_512", "SM2",
    ], v.spec)])
    error_message = "keys[*].spec is not a KMS key spec the provider accepts."
  }

  validation {
    condition     = alltrue([for k, v in var.keys : contains(["", "ENCRYPT_DECRYPT", "SIGN_VERIFY", "GENERATE_VERIFY_MAC", "KEY_AGREEMENT"], v.usage)])
    error_message = "keys[*].usage must be ENCRYPT_DECRYPT, SIGN_VERIFY, GENERATE_VERIFY_MAC or KEY_AGREEMENT."
  }

  validation {
    condition     = alltrue([for k, v in var.keys : v.rotation_period_days == null ? true : (v.rotation_period_days >= 90 && v.rotation_period_days <= 2560 && floor(v.rotation_period_days) == v.rotation_period_days)])
    error_message = "keys[*].rotation_period_days must be a whole number of days from 90 to 2560: ${join(", ", [for k, v in var.keys : k if v.rotation_period_days == null ? false : !(v.rotation_period_days >= 90 && v.rotation_period_days <= 2560)])}."
  }

  validation {
    condition     = alltrue([for k, v in var.keys : v.deletion_window_days == null ? true : (v.deletion_window_days >= 7 && v.deletion_window_days <= 30 && floor(v.deletion_window_days) == v.deletion_window_days)])
    error_message = "keys[*].deletion_window_days must be a whole number of days from 7 to 30: ${join(", ", [for k, v in var.keys : k if v.deletion_window_days == null ? false : !(v.deletion_window_days >= 7 && v.deletion_window_days <= 30)])}."
  }

  validation {
    condition     = alltrue([for k, v in var.keys : v.replicate ? v.multi_region : true])
    error_message = "keys[*].replicate needs multi_region = true - only a multi-Region primary can have a replica: ${join(", ", [for k, v in var.keys : k if v.replicate && !v.multi_region])}."
  }

  validation {
    condition = alltrue(flatten([for k, v in var.keys : [
      for a in v.aliases : can(regex("^[0-9A-Za-z_/-]{1,250}$", a)) ? (!startswith(a, "aws/") && !startswith(a, "alias/")) : false
    ]]))
    error_message = "keys[*].aliases are names without the \"alias/\" prefix: letters, digits, _ / -, at most 250 chars, never starting with \"aws/\" (reserved for AWS managed keys)."
  }

  validation {
    condition     = length(flatten([for k, v in var.keys : v.aliases])) == length(distinct(flatten([for k, v in var.keys : v.aliases])))
    error_message = "keys[*].aliases: an alias name is used by more than one key. An alias points at exactly one key per region."
  }

  validation {
    condition = alltrue(flatten([for k, v in var.keys : [
      for s in v.services : contains([
        "logs", "cloudtrail", "eventbridge-bus", "route53-dnssec",
        "cloudwatch-to-sns", "eventbridge-to-sns", "dms-events-to-sns", "rds-events-to-sns", "s3-events-to-sns",
        "eventbridge-to-sqs", "s3-events-to-sqs", "sns-to-sqs",
        "autoscaling-ebs",
        "s3", "secretsmanager", "rds", "dms", "ebs", "backup", "ssm", "dynamodb", "efs", "ecr",
        "lambda", "kinesis", "firehose", "elasticache", "sns", "sqs", "states",
        "mgn", "fsx", "glue", "athena", "redshift", "opensearch", "sagemaker", "msk", "mwaa", "mq",
        "memorydb", "docdb-elastic", "codeartifact", "directoryservice", "storagegateway", "ses",
        "connect", "workspaces", "xray", "securitylake", "s3tables",
      ], s)
    ]]))
    error_message = "keys[*].services: unknown preset. output.service_presets lists every preset and what it grants."
  }

  validation {
    condition     = alltrue(flatten([for k, v in var.keys : [for s in v.via_services : can(regex("^[a-z0-9-]+\\.(%s|\\*|[a-z0-9-]+)\\.amazonaws\\.com$", s))]]))
    error_message = "keys[*].via_services entries are kms:ViaService names such as \"glue.%s.amazonaws.com\" (%s becomes the key's region) or \"backup.*.amazonaws.com\"."
  }

  validation {
    condition     = alltrue([for k, v in var.keys : v.service_access == null ? true : contains(["account", "named"], v.service_access)])
    error_message = "keys[*].service_access must be \"account\" or \"named\"."
  }

  validation {
    condition     = alltrue(flatten([for k, v in var.keys : [for a in v.accounts : can(regex("^[0-9]{12}$", a))]]))
    error_message = "keys[*].accounts must be 12-digit AWS account IDs."
  }

  validation {
    condition = alltrue(flatten([for k, v in var.keys : [
      for p in concat(v.administrators, v.users, v.auditors, v.encrypters, v.decrypters, v.grant_users) :
      can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(root|role/.+|user/.+)$", p))
    ]]))
    error_message = "keys[*] principals (administrators, users, auditors, encrypters, decrypters, grant_users) must be IAM role, user or account-root ARNs. Assumed-role session ARNs (arn:aws:sts::...) change with every session and do not belong in a key policy."
  }

  validation {
    condition     = alltrue(flatten([for k, v in var.keys : [for c in v.require_encryption_context : can(regex("^[A-Za-z0-9:_./-]{1,128}$", c))]]))
    error_message = "keys[*].require_encryption_context entries are encryption context key names (letters, digits, : _ . / -)."
  }

  validation {
    condition     = alltrue([for k, v in var.keys : v.custom_key_store_id == "" ? true : can(regex("^cks-[0-9a-f]{17}$", v.custom_key_store_id))])
    error_message = "keys[*].custom_key_store_id must be a custom key store ID (cks-...)."
  }

  validation {
    condition     = alltrue([for k, v in var.keys : v.xks_key_id == "" ? true : v.custom_key_store_id != ""])
    error_message = "keys[*].xks_key_id needs custom_key_store_id: the external key lives in an external key store."
  }

  validation {
    condition     = alltrue([for k, v in var.keys : v.custom_key_store_id == "" ? true : !v.multi_region])
    error_message = "keys[*]: a key in a custom key store cannot be multi-Region."
  }

  validation {
    condition = alltrue(flatten([for k, v in var.keys : [
      for g, x in v.grants : length(x.operations) > 0 && can(regex("^[0-9A-Za-z_:/-]{1,256}$", g)) && alltrue([for o in x.operations : contains([
        "Decrypt", "Encrypt", "GenerateDataKey", "GenerateDataKeyWithoutPlaintext", "ReEncryptFrom", "ReEncryptTo",
        "Sign", "Verify", "GetPublicKey", "CreateGrant", "RetireGrant", "DescribeKey",
        "GenerateDataKeyPair", "GenerateDataKeyPairWithoutPlaintext", "GenerateMac", "VerifyMac", "DeriveSharedSecret",
      ], o)])
    ]]))
    error_message = "keys[*].grants: operations must be non-empty KMS grant operations, and grant names 1-256 chars of letters, digits, _ : / -."
  }

  validation {
    condition = alltrue(flatten([for k, v in var.keys : [
      for g, x in v.grants : !(length(x.encryption_context_equals) > 0 && length(x.encryption_context_subset) > 0)
    ]]))
    error_message = "keys[*].grants: set encryption_context_equals or encryption_context_subset, not both."
  }

  validation {
    condition     = alltrue([for k, v in var.keys : v.extra_statements == "" ? true : can(tolist(jsondecode(v.extra_statements)))])
    error_message = "keys[*].extra_statements must be a JSON list of policy statements, e.g. jsonencode([{ Sid = \"...\", ... }])."
  }

  validation {
    condition     = alltrue([for k, v in var.keys : length(v.description) <= 8192])
    error_message = "keys[*].description must be at most 8192 characters."
  }
}

variable "key_defaults" {
  description = "Defaults for every key's rotation, rotation_period_days, deletion_window_days and service_access (a key's own non-null value wins), and tags merged under each key's tags."
  type = object({
    rotation             = optional(bool, true)
    rotation_period_days = optional(number, 365)
    deletion_window_days = optional(number, 30)
    service_access       = optional(string, "account")
    tags                 = optional(map(string), {})
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.key_defaults.rotation_period_days >= 90 && var.key_defaults.rotation_period_days <= 2560
    error_message = "key_defaults.rotation_period_days must be from 90 to 2560."
  }

  validation {
    condition     = var.key_defaults.deletion_window_days >= 7 && var.key_defaults.deletion_window_days <= 30
    error_message = "key_defaults.deletion_window_days must be from 7 to 30."
  }

  validation {
    condition     = contains(["account", "named"], var.key_defaults.service_access)
    error_message = "key_defaults.service_access must be \"account\" or \"named\"."
  }
}

# ---------------------------------------------------------------------------
# Who
# ---------------------------------------------------------------------------

variable "iam_delegation" {
  description = <<-EOT
    true (the AWS default) gives the account root kms:* in every key policy,
    which lets IAM policies in this account grant access to the keys. false
    removes it: only principals named in the key policy can use or manage the
    keys. With false, a deleted deployer and administrator with nobody else
    named make a key unmanageable without AWS Support - name break_glass too.
  EOT
  type        = bool
  default     = true
  nullable    = false
}

variable "deployers" {
  description = "IAM role ARNs that run Terraform for these keys (the HCP Terraform workspace role). They manage the keys and their policy, create the module's grants, and are exempt from the deletion and policy guardrails. Empty: the role running the plan is detected (detect_deployer)."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for p in var.deployers : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(role/.+|user/.+)$", p))])
    error_message = "deployers must be IAM role or user ARNs (not assumed-role session ARNs)."
  }
}

variable "detect_deployer" {
  description = "With deployers empty, use the role running the plan as the deployer (aws_iam_session_context; needs iam:GetRole). A different identity planning later shows as a policy change. false: no deployer unless named."
  type        = bool
  default     = true
  nullable    = false
}

variable "administrators" {
  description = "Key administrators for every key: describe, enable/disable, rotation, tags, aliases, deletion and its cancellation, revoking grants. No cryptographic use and no grants; policy changes only with administrators_can_change_policy. The actions are listed explicitly - the AWS default policy's wildcards grant every operation KMS adds later."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for p in var.administrators : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(root|role/.+|user/.+)$", p))])
    error_message = "administrators must be IAM role, user or account-root ARNs."
  }
}

variable "administrators_can_change_policy" {
  description = "Give administrators kms:PutKeyPolicy. Off by default: an administrator who can rewrite the policy can grant themselves decryption, so key custodians and key users stop being separate. Deployers and break_glass always can."
  type        = bool
  default     = false
  nullable    = false
}

variable "users" {
  description = "Key users for every key: cryptographic use matching each key's usage, and grants for AWS resources only (kms:GrantIsForAWSResource)."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for p in var.users : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(root|role/.+|user/.+)$", p))])
    error_message = "users must be IAM role, user or account-root ARNs."
  }
}

variable "auditors" {
  description = "Read-only access to every key for security tooling: DescribeKey, GetKeyPolicy, GetKeyRotationStatus, ListGrants, ListResourceTags, ListKeyRotations, ListKeyPolicies, ListAliases (GetPublicKey on asymmetric keys). GetKeyPolicy works only from this account."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for p in var.auditors : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(root|role/.+|user/.+)$", p))])
    error_message = "auditors must be IAM role, user or account-root ARNs."
  }
}

variable "principal_roles" {
  description = <<-EOT
    What the symbolic roles in consumer requirements mean here, as IAM ARNs.
    A producing module cannot know who runs Terraform or who reads a secret,
    so its requirements name a role ("deployer", "secret_readers") and this
    map resolves it. "deployer" defaults to the deployers. An unresolved role
    is covered by IAM delegation when iam_delegation = true, and reported in
    output.coverage either way.
  EOT
  type        = map(list(string))
  default     = {}
  nullable    = false

  validation {
    condition     = alltrue([for r, arns in var.principal_roles : can(regex("^[a-z][a-z0-9_]{0,40}$", r))])
    error_message = "principal_roles keys must be lowercase identifiers, e.g. deployer, secret_readers."
  }

  validation {
    condition     = alltrue(flatten([for r, arns in var.principal_roles : [for p in arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(root|role/.+|user/.+)$", p))]]))
    error_message = "principal_roles values must be IAM role, user or account-root ARNs."
  }
}

# ---------------------------------------------------------------------------
# Contracts
# ---------------------------------------------------------------------------

variable "consumers" {
  description = <<-EOT
    The kms_key_policy_requirements outputs of the modules that use these keys,
    keyed by a name for each (dms, aurora...). Each requirement is matched to a
    key by its "key" field (key ARN, key ID or alias ARN, in either region) and
    compiled into that key's policy. Requirements that would make a key public
    or let a consumer manage it are refused at plan; everything else that does
    not compile is listed in output.coverage. Schema: output.contract_schema.
  EOT
  type        = any
  default     = {}
  nullable    = false

  validation {
    condition     = can(keys(var.consumers)) ? alltrue([for c in keys(var.consumers) : can(regex("^[a-z][a-z0-9_-]{0,40}$", c))]) : false
    error_message = "consumers must be a map of requirement lists keyed by lowercase names, e.g. { dms = module.dms.kms_key_policy_requirements }."
  }
}

# ---------------------------------------------------------------------------
# Guardrails
# ---------------------------------------------------------------------------

variable "guardrails" {
  description = <<-EOT
    Deny statements added to every key policy, following the AWS data
    perimeter patterns with the exemptions AWS services need.

    organization_id           deny use by principals outside this AWS
                              Organization, other than trusted_accounts and the
                              deployers' accounts; deny service principals
                              acting for another organization (confused deputy).
    trusted_accounts          accounts outside the organization still allowed.
    vpc_endpoint_ids          deny direct cryptographic calls that do not come
                              through one of these KMS VPC endpoints. Calls AWS
                              services make for a caller, and EBS, are exempt.
    replica_vpc_endpoint_ids  the same for replicas (endpoints are regional).
    vpc_endpoint_exempt_principals
                              role ARN patterns allowed from outside the
                              endpoints (e.g. a Lambda outside the VPC).
    deletion_protection       deny ScheduleKeyDeletion and DisableKey except to
                              deployers and break_glass.
    min_deletion_window_days  deny scheduling a deletion with a shorter window,
                              to everyone. 0 is off.
    protect_policy            deny PutKeyPolicy except to deployers and
                              break_glass.
    protect_aliases_and_rotation
                              deny alias changes and turning rotation off except
                              to deployers and break_glass - repointing an alias
                              silently redirects encryption.
    break_glass               principals with full management, exempt from the
                              guardrails above.

    terraform destroy removes the policy before the key: the provider resets it
    to the default (account root, kms:*), so these denies protect a key while
    it is managed, not from its own workspace's destroy.
  EOT
  type = object({
    organization_id                = optional(string, "")
    trusted_accounts               = optional(list(string), [])
    vpc_endpoint_ids               = optional(list(string), [])
    replica_vpc_endpoint_ids       = optional(list(string), [])
    vpc_endpoint_exempt_principals = optional(list(string), [])
    deletion_protection            = optional(bool, true)
    min_deletion_window_days       = optional(number, 0)
    protect_policy                 = optional(bool, false)
    protect_aliases_and_rotation   = optional(bool, false)
    break_glass                    = optional(list(string), [])
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.guardrails.organization_id == "" ? true : can(regex("^o-[a-z0-9]{10,32}$", var.guardrails.organization_id))
    error_message = "guardrails.organization_id must be an AWS Organizations ID (o-...)."
  }

  validation {
    condition     = alltrue([for a in var.guardrails.trusted_accounts : can(regex("^[0-9]{12}$", a))])
    error_message = "guardrails.trusted_accounts must be 12-digit account IDs."
  }

  validation {
    condition     = alltrue([for v in concat(var.guardrails.vpc_endpoint_ids, var.guardrails.replica_vpc_endpoint_ids) : can(regex("^vpce-[0-9a-f]{8,17}$", v))])
    error_message = "guardrails.vpc_endpoint_ids and replica_vpc_endpoint_ids must be VPC endpoint IDs (vpce-...)."
  }

  validation {
    condition     = alltrue([for p in var.guardrails.vpc_endpoint_exempt_principals : can(regex("^arn:aws[a-z-]*:iam::([0-9]{12}|\\*):role/.+$", p))])
    error_message = "guardrails.vpc_endpoint_exempt_principals must be IAM role ARNs or ARN patterns (arn:aws:iam::<account>:role/...)."
  }

  validation {
    condition     = var.guardrails.min_deletion_window_days == 0 ? true : (var.guardrails.min_deletion_window_days >= 7 && var.guardrails.min_deletion_window_days <= 30)
    error_message = "guardrails.min_deletion_window_days must be 0 (off) or from 7 to 30."
  }

  validation {
    condition     = alltrue([for p in var.guardrails.break_glass : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(role/.+|user/.+)$", p))])
    error_message = "guardrails.break_glass must be IAM role or user ARNs."
  }
}

# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------

variable "notifications" {
  description = <<-EOT
    EventBridge rules that send this key set's events to an SNS topic in the
    same region.
    events: native KMS events, always delivered - deletion, rotation,
    import_expiry (the default) - and CloudTrail-based ones, which need an
    active trail in the account: schedule_deletion, cancel_deletion, disable,
    enable, policy_change, rotation_disabled, rotate_on_demand, grant_change,
    alias_change, tag_change, replication.
    replica_sns_topic_arn: a topic in the replica region, for the replicas'
    events (EventBridge targets a topic in its own region).
    The topic policies must let events.amazonaws.com publish: see
    output.sns_topic_policy_requirement.
  EOT
  type = object({
    sns_topic_arn         = optional(string, "")
    replica_sns_topic_arn = optional(string, "")
    events                = optional(list(string), ["deletion", "rotation", "import_expiry"])
  })
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for t in [var.notifications.sns_topic_arn, var.notifications.replica_sns_topic_arn] :
      t == "" ? true : can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+(\\.fifo)?$", t))
    ])
    error_message = "notifications.sns_topic_arn and replica_sns_topic_arn must be SNS topic ARNs."
  }

  validation {
    condition = alltrue([for e in var.notifications.events : contains([
      "deletion", "rotation", "import_expiry", "schedule_deletion", "cancel_deletion", "disable", "enable",
      "policy_change", "rotation_disabled", "rotate_on_demand", "grant_change", "alias_change", "tag_change", "replication",
    ], e)])
    error_message = "notifications.events has an unknown event; see this variable's description for the list."
  }
}
