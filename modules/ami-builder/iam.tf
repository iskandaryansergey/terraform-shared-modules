# Components run as root on the build instance, so this role is the ceiling on
# what any of them can reach - yours, a colleague's, or an AWS-managed one.
# additional_build_policy_arns is a security review, not a convenience.

resource "aws_iam_role" "build" {
  count = local.create_build_role ? 1 : 0

  name        = local.build_role_name
  description = "Build instance role for the ${var.name} Image Builder pipeline"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
  tags                 = local.common_tags
}

# GetComponent plus the S3 reads AWSTOE needs to fetch documents. Mandatory.
resource "aws_iam_role_policy_attachment" "build_imagebuilder" {
  count = local.create_build_role ? 1 : 0

  role       = aws_iam_role.build[0].name
  policy_arn = "${local.managed_policy_prefix}/EC2InstanceProfileForImageBuilder"
}

# Image Builder drives the instance through SSM RunCommand. Not about operator
# access - without this nothing runs at all.
resource "aws_iam_role_policy_attachment" "build_ssm" {
  count = local.create_build_role ? 1 : 0

  role       = aws_iam_role.build[0].name
  policy_arn = "${local.managed_policy_prefix}/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "build" {
  count = local.create_build_role && length(local.build_policy_statements) > 0 ? 1 : 0

  name = "${var.name}-build"
  role = aws_iam_role.build[0].id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.build_policy_statements
  })
}

# for_each, not count: with count.index, removing a middle entry re-indexes and
# churns every attachment after it.
resource "aws_iam_role_policy_attachment" "build_additional" {
  for_each = local.create_build_role ? toset(var.additional_build_policy_arns) : toset([])

  role       = aws_iam_role.build[0].name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "build" {
  count = local.create_build_role ? 1 : 0

  name = local.build_profile_name
  role = aws_iam_role.build[0].name
  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Lifecycle policy role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "lifecycle" {
  count = local.create_lifecycle_role ? 1 : 0

  name        = local.lifecycle_role_name
  description = "Lifecycle policy execution role for the ${var.name} Image Builder pipeline"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "imagebuilder.amazonaws.com" }
      # Confused deputy: without these, any account's Image Builder principal
      # can assume the role.
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike = {
          "aws:SourceArn" = "arn:${local.partition}:imagebuilder:${local.region}:${local.account_id}:lifecycle-configuration/*"
        }
      }
    }]
  })

  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
  tags                 = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lifecycle" {
  count = local.create_lifecycle_role ? 1 : 0

  role       = aws_iam_role.lifecycle[0].name
  policy_arn = "${local.managed_policy_prefix}/service-role/EC2ImageBuilderLifecycleExecutionPolicy"
}
