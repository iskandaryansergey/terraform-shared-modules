# The instance role: register with SSM, read the scripts prefix, read the
# target secrets, write run output to its own log group. Nothing else.

resource "aws_iam_role" "this" {
  count = local.create ? 1 : 0

  name        = "${var.name}-sql-bastion"
  description = "dms-sql-bastion ${var.name}: runs migration SQL through SSM"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })

  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
  tags                 = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  count = local.create ? 1 : 0

  role       = aws_iam_role.this[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "this" {
  count = local.create ? 1 : 0

  name = "run-migration-sql"
  role = aws_iam_role.this[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "ReadScripts"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:GetObjectVersion"]
          Resource = ["arn:${local.partition}:s3:::${var.scripts.bucket_name}/${local.scripts_prefix}*"]
        },
        {
          # Without ListBucket a missing key reads as AccessDenied, which sends
          # people looking at IAM instead of at the key they typed.
          Sid       = "ListScripts"
          Effect    = "Allow"
          Action    = ["s3:ListBucket"]
          Resource  = ["arn:${local.partition}:s3:::${var.scripts.bucket_name}"]
          Condition = { StringLike = { "s3:prefix" = ["${local.scripts_prefix}*"] } }
        },
        {
          Sid      = "ReadTargetCredentials"
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue"]
          Resource = local.secret_arns
        },
        {
          Sid      = "WriteRunOutput"
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
          Resource = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${local.log_group_name}:*"]
        },
        {
          # The agent looks the group up before writing to it.
          Sid      = "FindRunLogGroup"
          Effect   = "Allow"
          Action   = ["logs:DescribeLogGroups"]
          Resource = ["*"]
        },
      ],
      length(local.secret_kms_keys) == 0 ? [] : [{
        Sid       = "DecryptTargetCredentials"
        Effect    = "Allow"
        Action    = ["kms:Decrypt"]
        Resource  = local.secret_kms_keys
        Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.${local.region}.amazonaws.com" } }
      }],
      var.scripts.kms_key_arn == "" ? [] : [{
        Sid       = "DecryptScripts"
        Effect    = "Allow"
        Action    = ["kms:Decrypt"]
        Resource  = [var.scripts.kms_key_arn]
        Condition = { StringEquals = { "kms:ViaService" = "s3.${local.region}.amazonaws.com" } }
      }],
    )
  })
}

resource "aws_iam_instance_profile" "this" {
  count = local.create ? 1 : 0

  name = "${var.name}-sql-bastion"
  role = aws_iam_role.this[0].name
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "additional" {
  for_each = local.create ? toset(var.additional_iam_policy_arns) : toset([])

  role       = aws_iam_role.this[0].name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "additional" {
  count = local.create && var.additional_iam_policy_json != "" ? 1 : 0

  name   = "additional"
  role   = aws_iam_role.this[0].id
  policy = var.additional_iam_policy_json
}
