# Inline jsonencode rather than aws_iam_policy_document, so the policies are in
# the plan and assertable under mock_provider.
#
# Both roles are bring-your-own: create_monitoring_role = false and
# proxy.create_role = false skip them entirely, for landing zones where IAM is
# created centrally.

resource "aws_iam_role" "monitoring" {
  count = local.create_monitoring_role ? 1 : 0

  # IAM is global and cluster names are regional: a global database often has
  # the same name in both regions. The region keeps the two roles apart.
  name                 = "${var.name}-${local.region}-monitor"
  path                 = var.iam_role_path
  description          = "Enhanced Monitoring for Aurora cluster ${var.name}"
  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null

  # Confused deputy: only RDS acting for this account can assume it.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EnhancedMonitoring"
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })

  tags = local.common_tags
}

# What AmazonRDSEnhancedMonitoringRole grants, scoped to the one log group the
# agent writes in this region and account instead of every RDS* group. Both
# ARN forms of the group are listed, because CloudWatch Logs authorises some
# calls against "log-group:NAME" and others against "log-group:NAME:*".
resource "aws_iam_role_policy" "monitoring" {
  count = local.create_monitoring_role ? 1 : 0

  name = "enhanced-monitoring"
  role = aws_iam_role.monitoring[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "OsMetricsLogGroup"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:PutRetentionPolicy"]
        Resource = [
          "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:RDSOSMetrics",
          "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:RDSOSMetrics:*",
        ]
      },
      {
        Sid    = "OsMetricsLogStreams"
        Effect = "Allow"
        Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams", "logs:GetLogEvents"]
        Resource = [
          "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:RDSOSMetrics:log-stream:*",
        ]
      },
    ]
  })
}

resource "aws_iam_role" "proxy" {
  count = local.create_proxy_role ? 1 : 0

  name                 = "${var.name}-${local.region}-proxy"
  path                 = var.iam_role_path
  description          = "RDS Proxy for Aurora cluster ${var.name}: reads the database credentials"
  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null

  # No SourceAccount condition: RDS Proxy's documented trust policy has none,
  # and a condition the service does not send is a proxy that never starts.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "RdsProxy"
      Effect    = "Allow"
      Principal = { Service = "rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "proxy" {
  count = local.create_proxy_role ? 1 : 0

  name = "read-database-secret"
  role = aws_iam_role.proxy[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid      = "ReadDatabaseSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = local.proxy_secret_arns
      }],
      # An AWS-managed secret key grants this through its own key policy.
      # A customer key has to be named here.
      local.proxy_secret_kms_key_arn == "" ? [] : [{
        Sid      = "DecryptDatabaseSecret"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [local.proxy_secret_kms_key_arn]
        Condition = {
          StringEquals = { "kms:ViaService" = "secretsmanager.${local.region}.amazonaws.com" }
        }
      }],
    )
  })
}
