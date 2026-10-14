output "keys" {
  description = "Every replica, by key name: its ARN (the same key ID as the primary, in this region), ID and alias ARNs."
  value = {
    for k, v in local.keys : k => {
      arn        = local.replica_arn[k]
      id         = local.replica_id[k]
      alias_arns = [for a in local.keys[k].aliases : "${replace(local.keys[k].arn, "/:key/.*$/", ":")}${a}"]
    }
  }
}

output "key_arns" {
  description = "Replica ARN by key name."
  value       = local.replica_arn
}

output "sns_topic_policy_requirement" {
  description = "The statement the replica region's topic policy must contain for these rules to publish. Null without notifications."
  value = length(aws_cloudwatch_event_rule.native) + length(aws_cloudwatch_event_rule.cloudtrail) == 0 ? null : {
    Sid       = "AllowKmsReplicaKeyEvents${replace(title(replace(local.name_prefix, "-", " ")), " ", "")}"
    Effect    = "Allow"
    Principal = { Service = "events.amazonaws.com" }
    Action    = "sns:Publish"
    Resource  = var.sns_topic_arn
    Condition = { ArnEquals = { "aws:SourceArn" = concat(aws_cloudwatch_event_rule.native[*].arn, aws_cloudwatch_event_rule.cloudtrail[*].arn) } }
  }
}

output "verify_commands" {
  description = "Read-only checks to run from CloudShell after an apply."
  value = {
    for k, id in local.replica_id : k => {
      policy = "aws kms get-key-policy --region ${local.region} --key-id ${id} --policy-name default --query Policy --output text"
      state  = "aws kms describe-key --region ${local.region} --key-id ${id} --query 'KeyMetadata.[KeyState,MultiRegionConfiguration.MultiRegionKeyType]' --output table"
    }
  }
}
