# Count-gated on create so `create = false` plans to nothing. locals coalesce
# the results, because ARN strings still have to build in that case.
#
# The region is parsed from aws_region's endpoint (<service>.<region>.amazonaws.com):
# it is the one attribute both provider majors have without a deprecation
# warning - v6 deprecates name, and v5 has no region.

data "aws_partition" "current" {
  count = local.create ? 1 : 0
}

data "aws_region" "current" {
  count = local.create ? 1 : 0
}

data "aws_caller_identity" "current" {
  count = local.create ? 1 : 0
}
