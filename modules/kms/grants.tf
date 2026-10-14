locals {
  grants = merge([
    for k, v in local.keys : { for g, x in v.grants : "${k}/${g}" => merge(x, { key = k, name = g }) }
  ]...)
}

# Every argument forces a new grant: any change revokes and recreates it.
resource "aws_kms_grant" "this" {
  for_each = local.create ? local.grants : {}

  name = each.value.name
  # Through the policy resource: on destroy the grant is revoked before the
  # policy is reset, while the deployer still holds RevokeGrant there.
  key_id             = aws_kms_key_policy.this[each.value.key].key_id
  grantee_principal  = each.value.grantee_principal
  operations         = each.value.operations
  retiring_principal = each.value.retiring_principal != "" ? each.value.retiring_principal : null
  retire_on_delete   = each.value.retire_on_delete

  lifecycle {
    precondition {
      condition     = alltrue([for o in each.value.operations : contains(local.grant_operations_by_kind[local.key_kind[each.value.key]], o)])
      error_message = "grant ${each.key}: ${join(", ", [for o in each.value.operations : o if !contains(local.grant_operations_by_kind[local.key_kind[each.value.key]], o)])} cannot be granted on a ${local.key_kind[each.value.key]} key. It takes: ${join(", ", local.grant_operations_by_kind[local.key_kind[each.value.key]])}."
    }

    precondition {
      condition     = length(each.value.encryption_context_equals) + length(each.value.encryption_context_subset) == 0 ? true : local.key_kind[each.value.key] == "symmetric"
      error_message = "grant ${each.key}: encryption context constraints apply only to symmetric keys."
    }
  }

  dynamic "constraints" {
    for_each = length(each.value.encryption_context_equals) + length(each.value.encryption_context_subset) > 0 ? [1] : []

    content {
      encryption_context_equals = length(each.value.encryption_context_equals) > 0 ? each.value.encryption_context_equals : null
      encryption_context_subset = length(each.value.encryption_context_subset) > 0 ? each.value.encryption_context_subset : null
    }
  }
}
