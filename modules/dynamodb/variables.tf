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
  description = "Table name."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-zA-Z0-9._-]{3,255}$", var.name))
    error_message = "name must be 3-255 chars: letters, numbers, dot, underscore, hyphen."
  }
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
  nullable    = false
}

# ============================================================================
# KEYS & ATTRIBUTES
# ============================================================================
# Declare each key attribute's TYPE once in `attributes` (name => S|N|B); keys
# and index keys reference those names. The module renders the attribute blocks,
# so you never repeat a type - and it validates that every key resolves.

variable "hash_key" {
  description = "Partition key attribute name (must be a key in `attributes`)."
  type        = string
  nullable    = false
}

variable "range_key" {
  description = "Optional sort key attribute name (must be a key in `attributes`)."
  type        = string
  default     = ""
  nullable    = false
}

variable "attributes" {
  description = "Key attributes used by the table and its indexes: name => type (S=string, N=number, B=binary). Only KEY attributes go here - DynamoDB is schemaless for everything else."
  type        = map(string)
  nullable    = false

  validation {
    condition     = length(var.attributes) > 0
    error_message = "Declare at least the hash_key attribute."
  }
  validation {
    # lazy ternary: a null element would crash contains() on eager 1.9 eval.
    condition     = alltrue([for k, t in var.attributes : contains(["S", "N", "B"], t == null ? "" : t)])
    error_message = "attributes values must be S, N, or B."
  }
}

# ============================================================================
# CAPACITY
# ============================================================================

variable "billing_mode" {
  description = "PAY_PER_REQUEST (on-demand; default, no capacity planning) or PROVISIONED (fixed/autoscaled capacity)."
  type        = string
  default     = "PAY_PER_REQUEST"
  nullable    = false

  validation {
    condition     = contains(["PAY_PER_REQUEST", "PROVISIONED"], var.billing_mode)
    error_message = "billing_mode must be PAY_PER_REQUEST or PROVISIONED."
  }
}

variable "read_capacity" {
  description = "Provisioned RCU for the table base (PROVISIONED only; ignored otherwise)."
  type        = number
  default     = 0
  nullable    = false
}

variable "write_capacity" {
  description = "Provisioned WCU for the table base (PROVISIONED only)."
  type        = number
  default     = 0
  nullable    = false
}

variable "max_read_request_units" {
  description = "On-demand read-unit cap for the table base - a FinOps guardrail against runaway on-demand spend. 0 = uncapped. PAY_PER_REQUEST only."
  type        = number
  default     = 0
  nullable    = false
}

variable "max_write_request_units" {
  description = "On-demand write-unit cap for the table base. 0 = uncapped. PAY_PER_REQUEST only."
  type        = number
  default     = 0
  nullable    = false
}

# ============================================================================
# INDEXES
# ============================================================================

variable "global_secondary_indexes" {
  description = <<-EOT
    GSIs (key = index name). hash_key/range_key reference `attributes`.
    projection_type: ALL | KEYS_ONLY | INCLUDE (INCLUDE needs non_key_attributes).
    read/write_capacity apply (and are required > 0) only under PROVISIONED.
    max_*_request_units are optional on-demand caps (PAY_PER_REQUEST only).
  EOT
  type = map(object({
    hash_key                = string
    range_key               = optional(string, "")
    projection_type         = optional(string, "ALL")
    non_key_attributes      = optional(list(string), [])
    read_capacity           = optional(number, 0)
    write_capacity          = optional(number, 0)
    max_read_request_units  = optional(number, 0)
    max_write_request_units = optional(number, 0)
  }))
  default  = {}
  nullable = false

  # index names have the same shape rule as table names.
  validation {
    condition     = alltrue([for k, g in var.global_secondary_indexes : can(regex("^[a-zA-Z0-9._-]{3,255}$", k))])
    error_message = "global_secondary_indexes names must be 3-255 chars: letters, numbers, dot, underscore, hyphen."
  }
  # a null/blank hash_key would crash key resolution before the friendly check.
  validation {
    condition     = alltrue([for k, g in var.global_secondary_indexes : g.hash_key != null && g.hash_key != ""])
    error_message = "global_secondary_indexes[*].hash_key must be set."
  }
  validation {
    condition     = alltrue([for k, g in var.global_secondary_indexes : contains(["ALL", "KEYS_ONLY", "INCLUDE"], g.projection_type)])
    error_message = "global_secondary_indexes[*].projection_type must be ALL, KEYS_ONLY, or INCLUDE."
  }
  validation {
    condition     = alltrue([for k, g in var.global_secondary_indexes : g.projection_type != "INCLUDE" || length(g.non_key_attributes) > 0])
    error_message = "GSIs with projection_type=INCLUDE require non_key_attributes."
  }
  validation {
    condition     = alltrue([for k, g in var.global_secondary_indexes : g.projection_type == "INCLUDE" || length(g.non_key_attributes) == 0])
    error_message = "non_key_attributes is only valid with projection_type=INCLUDE."
  }
}

variable "local_secondary_indexes" {
  description = "LSIs (key = index name). Same partition key as the table; range_key references `attributes`. Must be defined at create time."
  type = map(object({
    range_key          = string
    projection_type    = optional(string, "ALL")
    non_key_attributes = optional(list(string), [])
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for k, l in var.local_secondary_indexes : can(regex("^[a-zA-Z0-9._-]{3,255}$", k))])
    error_message = "local_secondary_indexes names must be 3-255 chars: letters, numbers, dot, underscore, hyphen."
  }
  validation {
    condition     = alltrue([for k, l in var.local_secondary_indexes : l.range_key != null && l.range_key != ""])
    error_message = "local_secondary_indexes[*].range_key must be set."
  }
  validation {
    condition     = alltrue([for k, l in var.local_secondary_indexes : contains(["ALL", "KEYS_ONLY", "INCLUDE"], l.projection_type)])
    error_message = "local_secondary_indexes[*].projection_type must be ALL, KEYS_ONLY, or INCLUDE."
  }
  validation {
    condition     = alltrue([for k, l in var.local_secondary_indexes : l.projection_type != "INCLUDE" || length(l.non_key_attributes) > 0])
    error_message = "LSIs with projection_type=INCLUDE require non_key_attributes."
  }
  validation {
    condition     = alltrue([for k, l in var.local_secondary_indexes : l.projection_type == "INCLUDE" || length(l.non_key_attributes) == 0])
    error_message = "non_key_attributes is only valid with projection_type=INCLUDE."
  }
}

# ============================================================================
# DATA PROTECTION (secure-by-default)
# ============================================================================

variable "deletion_protection" {
  description = "Block table deletion via API/console until turned off. On by default for anything that holds real data. To `terraform destroy`, first set this to false and apply."
  type        = bool
  default     = true
  nullable    = false
}

variable "point_in_time_recovery" {
  description = "Continuous backups / PITR (35-day restore window). On by default - it's cheap insurance."
  type        = bool
  default     = true
  nullable    = false
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN for encryption at rest. Empty = the AWS-owned key (still encrypted, no extra cost). Set a CMK for key control / cross-account / audit."
  type        = string
  default     = ""
  nullable    = false
}

variable "table_class" {
  description = "STANDARD or STANDARD_INFREQUENT_ACCESS (cheaper storage, higher throughput cost - for cold data)."
  type        = string
  default     = "STANDARD"
  nullable    = false

  validation {
    condition     = contains(["STANDARD", "STANDARD_INFREQUENT_ACCESS"], var.table_class)
    error_message = "table_class must be STANDARD or STANDARD_INFREQUENT_ACCESS."
  }
}

variable "ttl_attribute" {
  description = "Attribute holding an epoch-seconds expiry; DynamoDB deletes expired items for free. Empty = TTL disabled. (No need to list it in `attributes` - it's not a key.)"
  type        = string
  default     = ""
  nullable    = false
}

# ============================================================================
# STREAMS
# ============================================================================

variable "stream_enabled" {
  description = "Enable DynamoDB Streams (change data capture for Lambda/Kinesis/global tables)."
  type        = bool
  default     = false
  nullable    = false
}

variable "stream_view_type" {
  description = "What the stream records: KEYS_ONLY | NEW_IMAGE | OLD_IMAGE | NEW_AND_OLD_IMAGES. Required when stream_enabled."
  type        = string
  default     = "NEW_AND_OLD_IMAGES"
  nullable    = false

  validation {
    condition     = contains(["KEYS_ONLY", "NEW_IMAGE", "OLD_IMAGE", "NEW_AND_OLD_IMAGES"], var.stream_view_type)
    error_message = "stream_view_type must be KEYS_ONLY, NEW_IMAGE, OLD_IMAGE, or NEW_AND_OLD_IMAGES."
  }
}

# ============================================================================
# GLOBAL TABLES (multi-region replicas)
# ============================================================================

variable "replicas" {
  description = <<-EOT
    Global-table replica regions (v2). Each replica lives in another region;
    requires stream_enabled = true with NEW_AND_OLD_IMAGES. Optionally give each
    a CMK ARN (required if the primary uses a CMK) and its own PITR toggle.
  EOT
  type = list(object({
    region_name            = string
    kms_key_arn            = optional(string)
    point_in_time_recovery = optional(bool, true)
    propagate_tags         = optional(bool, true)
  }))
  default  = []
  nullable = false
}

# ============================================================================
# OBSERVABILITY / MISC
# ============================================================================

variable "contributor_insights" {
  description = "Enable CloudWatch Contributor Insights (most-accessed keys / throttled keys). Extra cost."
  type        = bool
  default     = false
  nullable    = false
}

variable "resource_policy_json" {
  description = "Optional resource-based policy (JSON) for cross-account/least-privilege access to the table. Empty = none."
  type        = string
  default     = ""
  nullable    = false
}
