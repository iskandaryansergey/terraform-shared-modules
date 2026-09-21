# Three kinds of role here, and they are not interchangeable:
#
#   endpoint_secret  - DMS assumes this to read one Secrets Manager secret.
#                      The trust principal is REGIONAL (dms.<region>.amazonaws.com);
#                      the plain dms.amazonaws.com principal is refused by
#                      Secrets Manager and the endpoint then fails its
#                      connection test with a permissions error naming neither.
#   s3_target        - DMS assumes this to write to your bucket.
#   account roles    - dms-vpc-role and friends. Fixed names, one set per
#                      account, off by default. See variables.

resource "aws_iam_role" "endpoint_secret" {
  for_each = local.create ? local.endpoints_with_secret : {}

  name        = "${var.name}-${each.key}-secret"
  description = "DMS reads the ${each.key} endpoint credential from Secrets Manager"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "dms.${local.region}.amazonaws.com" }
      # Confused deputy: without these, DMS in any account could assume it.
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike = {
          "aws:SourceArn" = "arn:${local.partition}:dms:${local.region}:${local.account_id}:endpoint:*"
        }
      }
    }]
  })

  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
  tags                 = local.common_tags
}

resource "aws_iam_role_policy" "endpoint_secret" {
  for_each = local.create ? local.endpoints_with_secret : {}

  name = "read-secret"
  role = aws_iam_role.endpoint_secret[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "ReadThisSecretOnly"
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
          Resource = [each.value.secret_arn]
        },
      ],
      each.value.secret_kms_key_arn != "" ? [
        {
          # A CMK-encrypted secret needs this too, and the error when it is
          # missing talks about the secret rather than the key.
          Sid      = "DecryptSecretWithCmk"
          Effect   = "Allow"
          Action   = ["kms:Decrypt"]
          Resource = [each.value.secret_kms_key_arn]
          Condition = {
            StringEquals = { "kms:ViaService" = "secretsmanager.${local.region}.amazonaws.com" }
          }
        },
      ] : [],
    )
  })
}

# ---------------------------------------------------------------------------
# S3 target access
# ---------------------------------------------------------------------------

resource "aws_iam_role" "s3_target" {
  for_each = local.create ? local.s3_targets_needing_role : {}

  name        = "${var.name}-${each.key}-s3"
  description = "DMS writes migrated data to the ${each.value.bucket_name} bucket"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      # Both principals: S3 target roles are documented with the global one and
      # the regional one appears in newer engine versions.
      Principal = { Service = ["dms.amazonaws.com", "dms.${local.region}.amazonaws.com"] }
      # SourceAccount alone lets ANY DMS endpoint in this account assume the
      # role - including one created by another team with dms:CreateEndpoint,
      # which is a far more common grant than iam:PassRole on this role.
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike = {
          "aws:SourceArn" = "arn:${local.partition}:dms:${local.region}:${local.account_id}:endpoint:*"
        }
      }
    }]
  })

  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
  tags                 = local.common_tags
}

resource "aws_iam_role_policy" "s3_target" {
  for_each = local.create ? local.s3_targets_needing_role : {}

  name = "write-target-bucket"
  role = aws_iam_role.s3_target[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          # Scoped to the folder when one is given. An empty bucket_folder
          # grants the whole bucket, which in a shared data lake means this
          # migration can overwrite another one's output.
          Sid    = "WriteMigratedObjects"
          Effect = "Allow"
          Action = [
            "s3:PutObject",
            "s3:DeleteObject",
            "s3:PutObjectTagging",
          ]
          Resource = [
            each.value.bucket_folder != ""
            ? "arn:${local.partition}:s3:::${each.value.bucket_name}/${trimsuffix(each.value.bucket_folder, "/")}/*"
            : "arn:${local.partition}:s3:::${each.value.bucket_name}/*"
          ]
        },
        {
          Sid      = "ListTargetBucket"
          Effect   = "Allow"
          Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
          Resource = ["arn:${local.partition}:s3:::${each.value.bucket_name}"]
        },
      ],
      each.value.encryption_mode == "SSE_KMS" && each.value.kms_key_arn != "" ? [
        {
          # SSE-KMS writes need GenerateDataKey on the bucket's key, not just
          # PutObject. Without it every object write 403s while the task
          # reports it is running.
          Sid      = "EncryptWithTargetKey"
          Effect   = "Allow"
          Action   = ["kms:GenerateDataKey", "kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
          Resource = [each.value.kms_key_arn]
        },
      ] : [],
    )
  })
}

# ---------------------------------------------------------------------------
# Account-wide service roles
#
# Fixed names, one set per account. Off by default because a second module
# instance creating dms-vpc-role fails with EntityAlreadyExists, and destroying
# either copy breaks every migration in the account.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "dms_vpc" {
  count = local.create && var.create_account_service_roles ? 1 : 0

  name        = "dms-vpc-role"
  description = "Account-wide role DMS uses to manage ENIs in your VPC"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "dms.amazonaws.com" }
    }]
  })

  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
  tags                 = local.common_tags
}

resource "aws_iam_role_policy_attachment" "dms_vpc" {
  count = local.create && var.create_account_service_roles ? 1 : 0

  role       = aws_iam_role.dms_vpc[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonDMSVPCManagementRole"
}

resource "aws_iam_role" "dms_cloudwatch_logs" {
  count = local.create && var.create_account_service_roles ? 1 : 0

  name        = "dms-cloudwatch-logs-role"
  description = "Account-wide role DMS uses to publish task logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "dms.amazonaws.com" }
    }]
  })

  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
  tags                 = local.common_tags
}

resource "aws_iam_role_policy_attachment" "dms_cloudwatch_logs" {
  count = local.create && var.create_account_service_roles ? 1 : 0

  role       = aws_iam_role.dms_cloudwatch_logs[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonDMSCloudWatchLogsRole"
}
