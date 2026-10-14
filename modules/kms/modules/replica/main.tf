locals {
  create = var.create && var.replicas != null
  keys   = local.create ? var.replicas.keys : {}

  # The two replica resources, one map: AWS-generated and imported material.
  replica_id  = { for k, v in local.keys : k => v.origin == "EXTERNAL" ? aws_kms_replica_external_key.this[k].key_id : aws_kms_replica_key.this[k].key_id }
  replica_arn = { for k, v in local.keys : k => v.origin == "EXTERNAL" ? aws_kms_replica_external_key.this[k].arn : aws_kms_replica_key.this[k].arn }

  aliases = merge([
    for k, v in local.keys : { for a in v.aliases : trimprefix(a, "alias/") => { key = k, name = a } }
  ]...)

  notify      = local.create ? var.sns_topic_arn != "" : false
  native      = local.notify ? var.replicas.notifications.native_pattern != "" : false
  cloudtrail  = local.notify ? var.replicas.notifications.cloudtrail_pattern != "" : false
  region      = one(data.aws_region.current[*].name)
  rule_tags   = local.create ? merge(var.tags, var.replicas.notifications.tags) : {}
  name_prefix = local.create ? var.replicas.key_set : ""
}

data "aws_region" "current" {
  count = local.create ? 1 : 0
}

resource "aws_kms_replica_key" "this" {
  for_each = { for k, v in local.keys : k => v if v.origin != "EXTERNAL" }

  primary_key_arn         = each.value.primary_key_arn
  description             = each.value.description
  enabled                 = each.value.enabled
  deletion_window_in_days = each.value.deletion_window_days

  policy                             = each.value.bootstrap_policy
  bypass_policy_lockout_safety_check = false

  tags = merge(var.tags, each.value.tags)

  lifecycle {
    # aws_kms_key_policy owns the live policy; this one only bootstraps.
    ignore_changes = [policy]

    precondition {
      condition     = length(merge(var.tags, each.value.tags)) <= 50
      error_message = "replica ${each.key} would carry ${length(merge(var.tags, each.value.tags))} tags; KMS allows 50."
    }

    precondition {
      condition     = local.region == var.replicas.region
      error_message = "this provider is in ${local.region}, but the key set's replicas are compiled for ${var.replicas.region} (the root module's replica_region): their policies name that region. Pass a provider for ${var.replicas.region}."
    }
  }
}

# A replica of imported material is created pending import: the custodians
# import the same material in this region, out of band.
resource "aws_kms_replica_external_key" "this" {
  for_each = { for k, v in local.keys : k => v if v.origin == "EXTERNAL" }

  primary_key_arn         = each.value.primary_key_arn
  description             = each.value.description
  enabled                 = each.value.enabled ? null : false
  deletion_window_in_days = each.value.deletion_window_days

  policy                             = each.value.bootstrap_policy
  bypass_policy_lockout_safety_check = false

  tags = merge(var.tags, each.value.tags)

  lifecycle {
    ignore_changes = [policy, valid_to]

    precondition {
      condition     = local.region == var.replicas.region
      error_message = "this provider is in ${local.region}, but the key set's replicas are compiled for ${var.replicas.region} (the root module's replica_region). Pass a provider for ${var.replicas.region}."
    }
  }
}

resource "aws_kms_key_policy" "this" {
  for_each = local.keys

  key_id                             = local.replica_id[each.key]
  policy                             = each.value.policy
  bypass_policy_lockout_safety_check = false
}

resource "aws_kms_alias" "this" {
  for_each = local.aliases

  name          = each.value.name
  target_key_id = local.replica_id[each.value.key]
}

resource "aws_cloudwatch_event_rule" "native" {
  count = local.native ? 1 : 0

  name          = "${local.name_prefix}-kms-key-events"
  description   = "KMS key events for the ${local.name_prefix} key set's replicas"
  event_pattern = var.replicas.notifications.native_pattern
  tags          = local.rule_tags

  lifecycle {
    precondition {
      condition     = length(var.replicas.notifications.native_pattern) <= 4096
      error_message = "the native event pattern is ${length(var.replicas.notifications.native_pattern)} characters; EventBridge allows 4096."
    }
  }
}

resource "aws_cloudwatch_event_target" "native" {
  count = length(aws_cloudwatch_event_rule.native)

  rule      = aws_cloudwatch_event_rule.native[0].name
  target_id = "sns"
  arn       = var.sns_topic_arn
}

resource "aws_cloudwatch_event_rule" "cloudtrail" {
  count = local.cloudtrail ? 1 : 0

  name          = "${local.name_prefix}-kms-key-changes"
  description   = "KMS calls on the ${local.name_prefix} key set's replicas (needs an active CloudTrail trail)"
  event_pattern = var.replicas.notifications.cloudtrail_pattern
  tags          = local.rule_tags

  lifecycle {
    precondition {
      condition     = length(var.replicas.notifications.cloudtrail_pattern) <= 4096
      error_message = "the CloudTrail event pattern is ${length(var.replicas.notifications.cloudtrail_pattern)} characters; EventBridge allows 4096."
    }
  }
}

resource "aws_cloudwatch_event_target" "cloudtrail" {
  count = length(aws_cloudwatch_event_rule.cloudtrail)

  rule      = aws_cloudwatch_event_rule.cloudtrail[0].name
  target_id = "sns"
  arn       = var.sns_topic_arn
}
