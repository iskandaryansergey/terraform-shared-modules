# Count-gated on create so `create = false` plans to nothing. locals coalesce
# the results, because ARN strings still have to build in that case.

data "aws_partition" "current" {
  count = local.create ? 1 : 0
}

data "aws_region" "current" {
  count = local.create ? 1 : 0
}

data "aws_caller_identity" "current" {
  count = local.create ? 1 : 0
}
