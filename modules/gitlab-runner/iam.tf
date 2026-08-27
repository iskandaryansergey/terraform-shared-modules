# Gated on create so create = false makes no API calls, which is what lets CI
# render and parse the templates offline.
data "aws_partition" "current" {
  count = local.create ? 1 : 0
}

data "aws_region" "current" {
  count = local.create ? 1 : 0
}

data "aws_caller_identity" "current" {
  count = local.create ? 1 : 0
}

locals {
  boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
  ssm_core = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# No aws:SourceAccount condition: that key isn't in the request context when EC2
# assumes a role for an instance profile, so it would guard nothing and might
# deny every assume-role. Only this account can attach the instance profile.
data "aws_iam_policy_document" "ec2_assume" {
  count = local.create ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Manager role: drives the ASG and connects to workers. The only credentials in
# the fleet that can change capacity, so they stay off the workers.
resource "aws_iam_role" "manager" {
  count = local.create ? 1 : 0

  name                 = "${var.name}-manager"
  description          = "GitLab runner manager: drives the ${local.worker_asg_name} ASG via the fleeting plugin"
  assume_role_policy   = data.aws_iam_policy_document.ec2_assume[0].json
  permissions_boundary = local.boundary
  tags                 = local.common_tags
}

# Kept as data rather than inline in the policy document so the test suite can
# assert on it. The document below just serialises this.
locals {
  manager_statements = concat(
    [
      {
        # Instance protection is how the plugin stops the ASG terminating a
        # worker mid-job.
        sid        = "ManageWorkerFleet"
        actions    = ["autoscaling:SetDesiredCapacity", "autoscaling:SetInstanceProtection", "autoscaling:TerminateInstanceInAutoScalingGroup"]
        resources  = [one(aws_autoscaling_group.workers[*].arn)]
        conditions = []
      },
      {
        # These APIs don't accept resource-level scoping.
        sid        = "DiscoverFleet"
        actions    = ["autoscaling:DescribeAutoScalingGroups", "ec2:DescribeInstances", "ec2:DescribeSpotInstanceRequests"]
        resources  = ["*"]
        conditions = []
      },
      {
        # 60-second SSH key at job start, so there's no long-lived keypair.
        # Scoped to this fleet's instances and to the configured OS user. Note
        # that user is in the docker group, which is root-equivalent.
        sid       = "EphemeralWorkerAccess"
        actions   = ["ec2-instance-connect:SendSSHPublicKey"]
        resources = ["arn:${local.partition}:ec2:${local.region}:${local.account_id}:instance/*"]
        conditions = [
          { test = "StringEquals", variable = "ec2:ResourceTag/aws:autoscaling:groupName", values = [local.worker_asg_name] },
          { test = "StringEquals", variable = "ec2:osuser", values = [var.worker_ssh_username] },
        ]
      },
      {
        sid        = "ReadRunnerToken"
        actions    = ["ssm:GetParameter"]
        resources  = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter${startswith(local.token_ssm_parameter, "/") ? "" : "/"}${local.token_ssm_parameter}"]
        conditions = []
      },
      {
        # So an alarm can see a broken manager.
        sid       = "PublishBootstrapSignal"
        actions   = ["cloudwatch:PutMetricData"]
        resources = ["*"]
        conditions = [
          { test = "StringEquals", variable = "cloudwatch:namespace", values = [local.alarm_namespace] },
        ]
      },
    ],
    local.create && var.log_retention_days > 0 ? [{
      sid        = "ShipLogs"
      actions    = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      resources  = ["${coalesce(one(aws_cloudwatch_log_group.manager[*].arn), "arn:${local.partition}:logs:*:*:log-group:*")}:*"]
      conditions = []
    }] : [],
    var.kms_key_arn != "" ? [{
      sid        = "DecryptRunnerToken"
      actions    = ["kms:Decrypt"]
      resources  = [var.kms_key_arn]
      conditions = []
    }] : [],
  )
}

data "aws_iam_policy_document" "manager" {
  count = local.create ? 1 : 0

  dynamic "statement" {
    for_each = local.manager_statements
    content {
      sid       = statement.value.sid
      actions   = statement.value.actions
      resources = statement.value.resources

      dynamic "condition" {
        for_each = statement.value.conditions
        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_iam_role_policy" "manager" {
  count = local.create ? 1 : 0

  name   = "${var.name}-manager"
  role   = aws_iam_role.manager[0].id
  policy = data.aws_iam_policy_document.manager[0].json
}

# Session Manager, for debugging the manager.
resource "aws_iam_role_policy_attachment" "manager_ssm" {
  count = local.create ? 1 : 0

  role       = aws_iam_role.manager[0].name
  policy_arn = local.ssm_core
}

resource "aws_iam_role_policy_attachment" "manager_additional" {
  for_each = local.create ? toset(var.additional_manager_policy_arns) : toset([])

  role       = aws_iam_role.manager[0].name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "manager" {
  count = local.create ? 1 : 0

  name = "${var.name}-manager"
  role = aws_iam_role.manager[0].name
  tags = local.common_tags
}

# Worker role: no fleet-control permissions, since jobs run here. It does carry
# AmazonSSMManagedInstanceCore. Add job-specific access via
# additional_worker_policy_arns.
resource "aws_iam_role" "worker" {
  count = local.create ? 1 : 0

  name                 = "${var.name}-worker"
  description          = "GitLab runner ephemeral worker (job execution)"
  assume_role_policy   = data.aws_iam_policy_document.ec2_assume[0].json
  permissions_boundary = local.boundary
  tags                 = local.common_tags
}

resource "aws_iam_role_policy_attachment" "worker_ssm" {
  count = local.create ? 1 : 0

  role       = aws_iam_role.worker[0].name
  policy_arn = local.ssm_core
}

resource "aws_iam_role_policy_attachment" "worker_additional" {
  for_each = local.create ? toset(var.additional_worker_policy_arns) : toset([])

  role       = aws_iam_role.worker[0].name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "worker" {
  count = local.create ? 1 : 0

  name = "${var.name}-worker"
  role = aws_iam_role.worker[0].name
  tags = local.common_tags
}
