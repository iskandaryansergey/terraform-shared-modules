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

  notify         = local.create && var.notifications.sns_topic_arn != ""
  notify_replica = local.create && var.notifications.replica_sns_topic_arn != "" && length(local.replicated_keys) > 0

  rule_tags = merge(var.tags, { ManagedBy = "Terraform", Module = "kms", KeySet = var.name })

  # One pattern per kind, filled with a region's key ARNs.
  native_pattern = {
    for which in keys(local.regions) : which => jsonencode({
      source        = ["aws.kms"]
      "detail-type" = local.native_events
      resources     = which == "primary" ? [for k, key in aws_kms_key.this : key.arn] : [for k, key in aws_kms_replica_key.this : key.arn]
    })
  }
  cloudtrail_pattern = {
    for which in keys(local.regions) : which => jsonencode({
      source        = ["aws.kms"]
      "detail-type" = ["AWS API Call via CloudTrail"]
      detail = {
        eventSource = ["kms.amazonaws.com"]
        eventName   = local.cloudtrail_events
        resources   = { ARN = which == "primary" ? [for k, key in aws_kms_key.this : key.arn] : [for k, key in aws_kms_replica_key.this : key.arn] }
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
}

resource "aws_cloudwatch_event_target" "cloudtrail" {
  count = length(aws_cloudwatch_event_rule.cloudtrail)

  rule      = aws_cloudwatch_event_rule.cloudtrail[0].name
  target_id = "sns"
  arn       = var.notifications.sns_topic_arn
}

resource "aws_cloudwatch_event_rule" "replica_native" {
  count    = local.notify_replica && length(local.native_events) > 0 ? 1 : 0
  provider = aws.replica

  name          = "${var.name}-kms-key-events"
  description   = "KMS key events for the ${var.name} key set's replicas"
  event_pattern = local.native_pattern.replica
  tags          = local.rule_tags
}

resource "aws_cloudwatch_event_target" "replica_native" {
  count    = length(aws_cloudwatch_event_rule.replica_native)
  provider = aws.replica

  rule      = aws_cloudwatch_event_rule.replica_native[0].name
  target_id = "sns"
  arn       = var.notifications.replica_sns_topic_arn
}

resource "aws_cloudwatch_event_rule" "replica_cloudtrail" {
  count    = local.notify_replica && length(local.cloudtrail_events) > 0 ? 1 : 0
  provider = aws.replica

  name          = "${var.name}-kms-key-changes"
  description   = "KMS calls on the ${var.name} key set's replicas (needs an active CloudTrail trail)"
  event_pattern = local.cloudtrail_pattern.replica
  tags          = local.rule_tags
}

resource "aws_cloudwatch_event_target" "replica_cloudtrail" {
  count    = length(aws_cloudwatch_event_rule.replica_cloudtrail)
  provider = aws.replica

  rule      = aws_cloudwatch_event_rule.replica_cloudtrail[0].name
  target_id = "sns"
  arn       = var.notifications.replica_sns_topic_arn
}
