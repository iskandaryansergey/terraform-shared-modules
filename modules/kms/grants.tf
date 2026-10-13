locals {
  grants = merge([
    for k, v in local.keys : { for g, x in v.grants : "${k}/${g}" => merge(x, { key = k, name = g }) }
  ]...)
}

# Every argument forces a new grant: any change revokes and recreates it.
resource "aws_kms_grant" "this" {
  for_each = local.create ? local.grants : {}

  name               = each.value.name
  key_id             = aws_kms_key.this[each.value.key].key_id
  grantee_principal  = each.value.grantee_principal
  operations         = each.value.operations
  retiring_principal = each.value.retiring_principal != "" ? each.value.retiring_principal : null
  retire_on_delete   = each.value.retire_on_delete

  dynamic "constraints" {
    for_each = length(each.value.encryption_context_equals) + length(each.value.encryption_context_subset) > 0 ? [1] : []

    content {
      encryption_context_equals = length(each.value.encryption_context_equals) > 0 ? each.value.encryption_context_equals : null
      encryption_context_subset = length(each.value.encryption_context_subset) > 0 ? each.value.encryption_context_subset : null
    }
  }
}
