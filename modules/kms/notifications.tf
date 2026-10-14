locals {
  native_event_types = {
    deletion      = "KMS CMK Deletion"
    rotation      = "KMS CMK Rotation"
    import_expiry = "KMS Imported Key Material Expiration"
  }
  cloudtrail_event_names = {
    schedule_deletion = ["ScheduleKeyDeletion"]
    cancel_deletion   = ["CancelKeyDeletion"]
    disable           = ["DisableKey"]
    enable            = ["EnableKey"]
    policy_change     = ["PutKeyPolicy"]
    rotation_disabled = ["DisableKeyRotation"]
    rotate_on_demand  = ["RotateKeyOnDemand"]
    grant_change      = ["CreateGrant", "RevokeGrant", "RetireGrant"]
    alias_change      = ["CreateAlias", "UpdateAlias", "DeleteAlias"]
    tag_change        = ["TagResource", "UntagResource"]
    replication       = ["ReplicateKey", "UpdatePrimaryRegion"]
  }

  native_events     = [for e in var.notifications.events : local.native_event_types[e] if contains(keys(local.native_event_types), e)]
  cloudtrail_events = distinct(flatten([for e in var.notifications.events : lookup(local.cloudtrail_event_names, e, [])]))

  notify = local.create && var.notifications.sns_topic_arn != ""

  rule_tags = merge(var.tags, { ManagedBy = "Terraform", Module = "kms", KeySet = var.name })

  # One pattern per kind, filled with a region's key ARNs.
  native_pattern = {
    for which in keys(local.regions) : which => jsonencode({
      source        = ["aws.kms"]
      "detail-type" = local.native_events
      resources     = which == "primary" ? [for k in sort(keys(local.key_arn)) : local.key_arn[k]] : values(local.replica_arns)
    })
  }
  cloudtrail_pattern = {
    for which in keys(local.regions) : which => jsonencode({
      source        = ["aws.kms"]
      "detail-type" = ["AWS API Call via CloudTrail"]
      detail = {
        eventSource = ["kms.amazonaws.com"]
        # ReplicateKey is logged in the primary's region only.
        eventName = which == "primary" ? local.cloudtrail_events : [for e in local.cloudtrail_events : e if e != "ReplicateKey"]
        resources = { ARN = which == "primary" ? [for k in sort(keys(local.key_arn)) : local.key_arn[k]] : values(local.replica_arns) }
      }
    })
  }
}

resource "aws_cloudwatch_event_rule" "native" {
  count = local.notify && length(local.native_events) > 0 ? 1 : 0

  name          = "${var.name}-kms-key-events"
  description   = "KMS key events for the ${var.name} key set"
  event_pattern = local.native_pattern.primary
  tags          = local.rule_tags

  lifecycle {
    precondition {
      condition     = length(local.native_pattern.primary) <= 4096
      error_message = "the native event pattern for this key set is ${length(local.native_pattern.primary)} characters; EventBridge allows 4096. Split the keys across key sets."
    }
  }
}

resource "aws_cloudwatch_event_target" "native" {
  count = length(aws_cloudwatch_event_rule.native)

  rule      = aws_cloudwatch_event_rule.native[0].name
  target_id = "sns"
  arn       = var.notifications.sns_topic_arn
}

resource "aws_cloudwatch_event_rule" "cloudtrail" {
  count = local.notify && length(local.cloudtrail_events) > 0 ? 1 : 0

  name          = "${var.name}-kms-key-changes"
  description   = "KMS calls on the ${var.name} key set (needs an active CloudTrail trail)"
  event_pattern = local.cloudtrail_pattern.primary
  tags          = local.rule_tags

  lifecycle {
    precondition {
      condition     = length(local.cloudtrail_pattern.primary) <= 4096
      error_message = "the cloudtrail event pattern for this key set is ${length(local.cloudtrail_pattern.primary)} characters; EventBridge allows 4096. Split the keys across key sets."
    }
  }
}

resource "aws_cloudwatch_event_target" "cloudtrail" {
  count = length(aws_cloudwatch_event_rule.cloudtrail)

  rule      = aws_cloudwatch_event_rule.cloudtrail[0].name
  target_id = "sns"
  arn       = var.notifications.sns_topic_arn
}
