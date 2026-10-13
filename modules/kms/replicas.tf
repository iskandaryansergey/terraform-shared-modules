resource "aws_kms_replica_key" "this" {
  for_each = local.create ? local.replicated_keys : {}
  provider = aws.replica

  primary_key_arn         = aws_kms_key.this[each.key].arn
  description             = each.value.description
  enabled                 = each.value.enabled
  deletion_window_in_days = each.value.deletion_window_days

  policy                             = local.bootstrap_policy[each.key].replica
  bypass_policy_lockout_safety_check = false

  tags = local.key_tags[each.key]

  lifecycle {
    ignore_changes = [policy]

    precondition {
      condition     = local.replica_region != local.region
      error_message = "key ${each.key} replicates, but the aws.replica provider is in ${local.region}, the primary's own region. Pass a provider for another region as aws.replica."
    }
  }
}

resource "aws_kms_key_policy" "replica" {
  for_each = local.create ? local.replicated_keys : {}
  provider = aws.replica

  key_id                             = aws_kms_replica_key.this[each.key].key_id
  policy                             = local.final_policy[each.key].replica
  bypass_policy_lockout_safety_check = false

  lifecycle {
    precondition {
      condition     = length(local.final_policy[each.key].replica) <= 32768
      error_message = "the replica policy for key ${each.key} is ${length(local.final_policy[each.key].replica)} characters; KMS allows 32768."
    }
  }
}

resource "aws_kms_alias" "replica" {
  for_each = local.create ? { for k, a in local.aliases : k => a if contains(keys(local.replicated_keys), a.key) } : {}
  provider = aws.replica

  name          = each.value.name
  target_key_id = aws_kms_replica_key.this[each.value.key].key_id
}
