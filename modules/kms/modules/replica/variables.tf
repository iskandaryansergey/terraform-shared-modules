variable "create" {
  description = "false plans nothing; every output is empty."
  type        = bool
  default     = true
  nullable    = false
}

variable "replicas" {
  description = "The root module's output.replicas, passed whole: module.kms.replicas, or the same value read through tfe_outputs from the primary's workspace. Null creates nothing. Its policies are compiled there - change them there."
  type = object({
    schema  = number
    key_set = string
    region  = string
    keys = map(object({
      primary_key_arn      = string
      origin               = string
      arn                  = string
      description          = string
      enabled              = bool
      deletion_window_days = number
      bootstrap_policy     = string
      policy               = string
      aliases              = list(string)
      tags                 = map(string)
    }))
    notifications = object({
      native_pattern     = string
      cloudtrail_pattern = string
      tags               = map(string)
    })
  })

  validation {
    condition     = var.replicas == null ? true : var.replicas.schema == 1
    error_message = "replicas comes from a kms module version this replica module does not read (schema ${try(var.replicas.schema, "?")}, expected 1). Use the replica module from the same kms version."
  }
}

variable "sns_topic_arn" {
  description = "An SNS topic in the replica region for the replicas' key events (EventBridge targets a topic in its own region). Empty: no rules. Which events comes from the root module's notifications.events. The topic policy must contain output.sns_topic_policy_requirement."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.sns_topic_arn == "" ? true : can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+(\\.fifo)?$", var.sns_topic_arn))
    error_message = "sns_topic_arn must be empty or an SNS topic ARN."
  }
}

variable "tags" {
  description = "Extra tags for the replicas and rules. The primary's tags, including the module's own, are applied after these and win."
  type        = map(string)
  default     = {}
  nullable    = false

  validation {
    condition     = alltrue([for k, v in var.tags : length(k) <= 128 && length(v) <= 256 && !startswith(lower(k), "aws:")])
    error_message = "tags keys must be <= 128 chars, values <= 256 chars, and no key may use the reserved \"aws:\" prefix."
  }
}
