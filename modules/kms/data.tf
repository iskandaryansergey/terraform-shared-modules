# Count-gated on create so `create = false` plans to nothing. locals coalesce
# the results, because ARNs and conditions still have to build in that case.

data "aws_partition" "current" {
  count = local.create ? 1 : 0
}

data "aws_region" "current" {
  count = local.create ? 1 : 0
}

data "aws_caller_identity" "current" {
  count = local.create ? 1 : 0
}

data "aws_region" "replica" {
  count    = local.create && length(local.replicated_keys) > 0 ? 1 : 0
  provider = aws.replica
}

# The role behind the session running the plan (calls iam:GetRole).
data "aws_iam_session_context" "deployer" {
  count = local.create && var.detect_deployer && length(var.deployers) == 0 ? 1 : 0
  arn   = data.aws_caller_identity.current[0].arn
}

data "aws_kms_public_key" "this" {
  for_each = local.create ? { for k, v in local.keys : k => v if contains(["sign", "agreement", "asymmetric_encrypt"], local.key_kind[k]) } : {}
  key_id   = aws_kms_key.this[each.key].key_id
}
