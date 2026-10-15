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
      # Confused deputy: without these, DMS acting for another account could
      # assume it. The SourceArn is any DMS resource in this account and region,
      # as AWS documents it: DMS presents the endpoint, task or replication
      # config ARN depending on the operation, so narrowing it to endpoint:*
      # risks a denied AssumeRole at run time.
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike = {
          "aws:SourceArn" = "arn:${local.partition}:dms:${local.region}:${local.account_id}:*"
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
      # Confused deputy, as AWS documents it. Within the account, what stops
      # another team's endpoint using this role is iam:PassRole on it - grant
      # that narrowly.
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike = {
          "aws:SourceArn" = "arn:${local.partition}:dms:${local.region}:${local.account_id}:*"
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
      # GlueCatalogGeneration: the endpoint role creates the Glue tables and
      # runs Athena, as the DMS S3 target documentation lists. Without these
      # the load succeeds and the catalog never appears.
      # s3:GetObject is bucket-wide here, unlike the write statement above,
      # because that is the exact policy the DMS documentation gives for
      # GlueCatalogGeneration ("Using AWS Glue Data Catalog with an Amazon S3
      # target"): where Athena reads for the catalog is not documented to stay
      # inside bucket_folder, and narrowing it would fail as an empty catalog
      # with no error. A caller who needs it narrower brings their own role.
      each.value.glue_catalog_generation ? [
        {
          Sid    = "ReadForGlueCatalog"
          Effect = "Allow"
          Action = ["s3:GetObject", "s3:ListBucketMultipartUploads", "s3:ListMultipartUploadParts", "s3:AbortMultipartUpload"]
          Resource = [
            "arn:${local.partition}:s3:::${each.value.bucket_name}",
            "arn:${local.partition}:s3:::${each.value.bucket_name}/*",
          ]
        },
        {
          Sid    = "GenerateGlueCatalog"
          Effect = "Allow"
          Action = [
            "glue:CreateDatabase", "glue:GetDatabase", "glue:CreateTable", "glue:DeleteTable", "glue:UpdateTable", "glue:GetTable",
            "glue:BatchCreatePartition", "glue:CreatePartition", "glue:UpdatePartition", "glue:GetPartition", "glue:GetPartitions", "glue:BatchGetPartition",
          ]
          Resource = [
            "arn:${local.partition}:glue:${local.region}:${local.account_id}:catalog",
            "arn:${local.partition}:glue:${local.region}:${local.account_id}:database/*",
            "arn:${local.partition}:glue:${local.region}:${local.account_id}:table/*",
          ]
        },
        {
          Sid      = "QueryForGlueCatalog"
          Effect   = "Allow"
          Action   = ["athena:StartQueryExecution", "athena:GetQueryExecution", "athena:CreateWorkGroup"]
          Resource = ["arn:${local.partition}:athena:${local.region}:${local.account_id}:workgroup/glue_catalog_generation_for_task_*"]
        },
      ] : [],
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

  # No permissions_boundary: this role carries an AWS-managed policy DMS needs
  # in full, and a landing-zone boundary that does not grant the EC2 network
  # interface calls would cap it silently.
  tags = local.common_tags
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

  # No permissions_boundary, for the same reason as dms-vpc-role: a boundary
  # without logs:PutLogEvents on dms-tasks-* leaves the role in place and the
  # task logs empty.
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "dms_cloudwatch_logs" {
  count = local.create && var.create_account_service_roles ? 1 : 0

  role       = aws_iam_role.dms_cloudwatch_logs[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonDMSCloudWatchLogsRole"
}

# ---------------------------------------------------------------------------
# Premigration assessment
#
# The role DMS writes assessment reports with, scoped to one bucket prefix.
# Trust as AWS documents it, plus the account condition. No SourceArn: what DMS
# presents for an assessment run is not documented closely enough to pin, and
# a wrong condition fails the run with AccessDenied.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "assessment" {
  count = local.create_assessment_role ? 1 : 0

  name        = "${var.name}-assessment"
  description = "DMS writes premigration assessment reports for the ${var.name} migration"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "dms.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })

  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
  tags                 = local.common_tags
}

resource "aws_iam_role_policy" "assessment" {
  count = local.create_assessment_role ? 1 : 0

  name = "write-assessment-reports"
  role = aws_iam_role.assessment[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "WriteAssessmentReports"
          Effect   = "Allow"
          Action   = ["s3:PutObject", "s3:DeleteObject", "s3:GetObject", "s3:PutObjectTagging"]
          Resource = ["arn:${local.partition}:s3:::${var.premigration_assessment.bucket_name}/${var.premigration_assessment.bucket_folder}/*"]
        },
        {
          Sid      = "LocateAssessmentBucket"
          Effect   = "Allow"
          Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
          Resource = ["arn:${local.partition}:s3:::${var.premigration_assessment.bucket_name}"]
        },
      ],
      var.premigration_assessment.kms_key_arn == "" ? [] : [{
        Sid      = "EncryptAssessmentReports"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = [var.premigration_assessment.kms_key_arn]
        Condition = {
          StringEquals = { "kms:ViaService" = "s3.${local.region}.amazonaws.com" }
        }
      }],
    )
  })
}

# Redshift targets stage the load through S3 with this fixed-name role. The
# console creates it; the API, and so Terraform, does not.
resource "aws_iam_role" "dms_access_for_endpoint" {
  count = local.create && var.create_account_service_roles && local.has_redshift_target ? 1 : 0

  name        = "dms-access-for-endpoint"
  description = "Account-wide role DMS uses to stage Redshift loads through S3"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = ["dms.amazonaws.com", "redshift-serverless.amazonaws.com"] }
    }]
  })

  # No permissions_boundary, as for the other account-wide roles.
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "dms_access_for_endpoint" {
  count = length(aws_iam_role.dms_access_for_endpoint)

  role       = aws_iam_role.dms_access_for_endpoint[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonDMSRedshiftS3Role"
}
