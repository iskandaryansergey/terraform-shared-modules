# All count-gated on create so `create = false` plans to nothing. locals
# coalesce the results, because ARN strings still have to build in that case.

data "aws_partition" "current" {
  count = local.create ? 1 : 0
}

data "aws_region" "current" {
  count = local.create ? 1 : 0
}

data "aws_caller_identity" "current" {
  count = local.create ? 1 : 0
}

# Reading the parent at plan time is how we catch the mismatches that otherwise
# fail 20 minutes into a build, or - for the root device - don't fail at all and
# hand you an unencrypted image. Only possible with a concrete AMI id.
data "aws_ami" "parent" {
  count = local.create && var.verify_parent_image && local.parent_is_ami_id ? 1 : 0

  # No owners filter. An image-id filter is already exact, and pinning owners
  # breaks on an AMI shared in from another account.
  filter {
    name   = "image-id"
    values = [var.parent_image]
  }
}
