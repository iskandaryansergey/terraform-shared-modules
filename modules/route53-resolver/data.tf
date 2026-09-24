# Count-gated on create so `create = false` plans to nothing.

data "aws_partition" "current" {
  count = local.create ? 1 : 0
}

data "aws_region" "current" {
  count = local.create ? 1 : 0
}

data "aws_caller_identity" "current" {
  count = local.create ? 1 : 0
}

# Read to validate the subnets are in distinct AZs before AWS rejects it, and
# to name the AZs in the outputs - a resolver in one AZ is a single point of
# failure for every DNS query in the VPC.
data "aws_subnet" "resolver" {
  for_each = local.create ? toset(var.subnet_ids) : toset([])

  id = each.value
}
