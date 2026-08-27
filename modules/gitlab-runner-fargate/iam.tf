# IAM is where this platform concentrates its risk.
#
# The Fargate driver reads CUSTOM_ENV_FARGATE_TASK_DEFINITION, _SUBNET,
# _SECURITY_GROUP and CUSTOM_ENV_ROLE_ARN. GitLab Runner exposes every CI/CD
# variable to the stage executables with a CUSTOM_ENV_ prefix. So anyone who can
# set a CI/CD variable on a project using this runner can ask the manager to
# launch a DIFFERENT task definition - including one with a more privileged task
# role - or place the job in a different subnet or security group.
#
# GitLab documents this as a feature, and it is genuinely the cleanest answer to
# "image: is ignored". But it means the ecs:RunTask resource list and the
# iam:PassRole resource list below are the entire containment boundary. Neither
# may ever become a wildcard, and the test suite asserts that.
#
# WHY jsonencode() AND NOT aws_iam_policy_document:
# a data source is computed by the provider, so under mock_provider its output is
# a mock and any assertion about it tests the mock rather than the policy. Built
# this way the policy is a pure Terraform value: knowable at plan time, visible
# in a plan diff, and assertable in the test suite regardless of whether the
# provider is real (R8, R10).

locals {
  ecs_tasks_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Condition = {
        # The confused-deputy form AWS documents for ecs-tasks. Note aws:SourceArn
        # cannot name a specific cluster - AWS says to use the wildcard - so the
        # account condition is what is actually doing the work here.
        ArnLike      = { "aws:SourceArn" = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:*" }
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })

  # ---- the containment boundary -------------------------------------------
  #
  # Statements carry their conditions as a LIST of {test, variable, values}, not
  # as IAM's nested map. That is not cosmetic: a bare map makes every statement a
  # different object type (one has ArnEquals, another StringEquals, a third has
  # nothing), and Terraform then cannot unify the branches of the conditional
  # blocks below. A list is uniform by construction, so the policy composes from
  # optional pieces without type gymnastics - and it reads better as review
  # material, which is the point of exposing it as an output at all (R10).
  manager_statements_raw = concat(
    [
      {
        # Launch job tasks - scoped to this fleet's task definitions AND cluster.
        #
        # The ARNs are enumerated, never wildcarded, because a CI variable can
        # choose among whatever this allows. `family:*` is the correct shape:
        # RunTask requires either a specific revision or all revisions, and
        # pinning one here would break every task-definition update.
        sid      = "RunJobTasks"
        actions  = ["ecs:RunTask"]
        resource = [for k, family in local.job_family_names : "arn:${local.partition}:ecs:${local.region}:${local.account_id}:task-definition/${family}:*"]
        conditions = [
          { test = "ArnEquals", variable = "ecs:cluster", values = [local.cluster_arn] },
        ]
      },
      {
        # Inspect and stop the tasks it launched. Task UUIDs are random, so a
        # cluster-scoped ARN plus the cluster condition is the tightest form
        # available.
        sid      = "ManageJobTasks"
        actions  = ["ecs:DescribeTasks", "ecs:StopTask"]
        resource = ["arn:${local.partition}:ecs:${local.region}:${local.account_id}:task/${local.cluster_name}/*"]
        conditions = [
          { test = "ArnEquals", variable = "ecs:cluster", values = [local.cluster_arn] },
        ]
      },
      {
        # Hand the job roles to ECS. Second half of the containment boundary: a
        # redirected RunTask cannot acquire a role this list does not name.
        sid      = "PassOnlyJobRoles"
        actions  = ["iam:PassRole"]
        resource = concat([local.job_execution_role_arn], local.job_task_role_arns)
        conditions = [
          { test = "StringEquals", variable = "iam:PassedToService", values = ["ecs-tasks.amazonaws.com"] },
        ]
      },
      {
        # Enumerate tasks in this cluster. Needed to FIND orphans: a job task whose
        # manager died is never stopped by anything, keeps sshd alive with no
        # client, and bills indefinitely. DescribeTasks alone cannot find one,
        # because you need the ARN first. ListTasks takes the cluster as a
        # condition rather than a resource.
        sid      = "ListFleetTasks"
        actions  = ["ecs:ListTasks"]
        resource = ["*"]
        conditions = [
          { test = "ArnEquals", variable = "ecs:cluster", values = [local.cluster_arn] },
        ]
      },
      {
        # Publish the fleet's own metrics, scoped by namespace so the manager
        # cannot write over anything else's dashboards. PutMetricData does not
        # support resource-level permissions, hence the "*" plus a condition.
        sid      = "PublishFleetMetrics"
        actions  = ["cloudwatch:PutMetricData"]
        resource = ["*"]
        conditions = [
          { test = "StringEquals", variable = "cloudwatch:namespace", values = [local.alarm_namespace] },
        ]
      },
    ],
    # Granted ONLY when the driver actually needs it. AWS does not support
    # resource-level permissions on this action, so it must be "*" - and a "*"
    # grant that nothing needs is not free.
    local.any_profile_has_health_check ? [{
      sid        = "DescribeTaskDefinitionHasNoResourceLevelPerms"
      actions    = ["ecs:DescribeTaskDefinition"]
      resource   = ["*"]
      conditions = []
    }] : [],
    var.cache_bucket_name != "" ? [
      {
        # Object access to the cache prefix only. Deliberately not a broad
        # PutObject over a shared prefix: cache_path scopes the fleet, and the
        # fleet is the trust boundary. Two projects that must not poison each
        # other's cache belong on two fleets.
        sid        = "CacheObjects"
        actions    = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        resource   = ["arn:${local.partition}:s3:::${var.cache_bucket_name}/${var.cache_path != "" ? "${var.cache_path}/" : ""}*"]
        conditions = []
      },
      {
        sid      = "CacheBucket"
        actions  = ["s3:ListBucket", "s3:GetBucketLocation"]
        resource = ["arn:${local.partition}:s3:::${var.cache_bucket_name}"]
        conditions = [
          { test = "StringLike", variable = "s3:prefix", values = [var.cache_path != "" ? "${var.cache_path}/*" : "*"] },
        ]
      },
    ] : [],
    # SSE-KMS on cache objects needs both, on the manager TASK role - the manager
    # is what reads and writes cache objects and mints the pre-signed URLs.
    var.cache_bucket_name != "" && var.cache_kms_key_arn != "" ? [{
      sid        = "CacheEncryption"
      actions    = ["kms:GenerateDataKey", "kms:Decrypt"]
      resource   = [var.cache_kms_key_arn]
      conditions = []
    }] : [],
  )

  # Project the uniform internal shape into real IAM statements. Condition values
  # are always emitted as an array, which IAM accepts for every condition
  # operator - collapsing a single element to a scalar would read marginally
  # closer to the console's output and would make the expression type-unstable.
  manager_statements = [
    for s in local.manager_statements_raw : merge(
      {
        Sid      = s.sid
        Effect   = "Allow"
        Action   = s.actions
        Resource = s.resource
      },
      length(s.conditions) == 0 ? {} : {
        Condition = {
          for test in distinct([for c in s.conditions : c.test]) : test => {
            for c in s.conditions : c.variable => c.values
            if c.test == test
          }
        }
      },
    )
  ]

  manager_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.manager_statements
  })

  # Only the MANAGER's execution role may read the runner token. kms:Decrypt is
  # added only for a customer-managed key: the AWS-managed key needs no grant,
  # and a kms:Decrypt on an unused key is a grant that buys nothing.
  manager_execution_statements = concat(
    [{
      Sid      = "ReadRunnerToken"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [var.runner_token_secret_arn]
    }],
    var.runner_token_kms_key_arn != "" ? [{
      Sid      = "DecryptRunnerTokenCMK"
      Effect   = "Allow"
      Action   = ["kms:Decrypt"]
      Resource = [var.runner_token_kms_key_arn]
    }] : [],
  )

  manager_execution_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.manager_execution_statements
  })
}

# ---------------------------------------------------------------------------
# Manager task role - what the gitlab-runner process itself can do.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "manager" {
  count = local.create ? 1 : 0

  name                 = "${var.name}-manager"
  assume_role_policy   = local.ecs_tasks_assume_role_policy
  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
  tags                 = local.common_tags
}

resource "aws_iam_role_policy" "manager" {
  count = local.create ? 1 : 0

  name   = "${var.name}-manager"
  role   = aws_iam_role.manager[0].id
  policy = local.manager_policy
}

resource "aws_iam_role_policy_attachment" "manager_additional" {
  for_each = local.create ? toset(var.additional_manager_policy_arns) : toset([])

  role       = aws_iam_role.manager[0].name
  policy_arn = each.value
}

# ---------------------------------------------------------------------------
# Execution roles - used by the Fargate agent, NOT by the container.
#
# AWS is explicit that these credentials "aren't directly accessible by the
# containers in the task". They cover ECR pulls, log delivery, and resolving
# `secrets`/valueFrom. Two separate roles so the job tier cannot resolve the
# runner token secret even by accident.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "manager_execution" {
  count = local.create ? 1 : 0

  name                 = "${var.name}-manager-execution"
  assume_role_policy   = local.ecs_tasks_assume_role_policy
  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
  tags                 = local.common_tags
}

resource "aws_iam_role" "job_execution" {
  count = local.create ? 1 : 0

  name                 = "${var.name}-job-execution"
  assume_role_policy   = local.ecs_tasks_assume_role_policy
  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
  tags                 = local.common_tags
}

# AmazonECSTaskExecutionRolePolicy grants ECR pull actions and
# logs:CreateLogStream/PutLogEvents on "*". It is AWS-controlled, so its contents
# can widen with no diff here. Stated plainly rather than glossed: this is an
# unpinned grant, accepted because the alternative is hand-maintaining an ECR
# action list, and it sits on the EXECUTION role - which the container cannot
# reach - rather than on a task role.
resource "aws_iam_role_policy_attachment" "manager_execution" {
  count = local.create ? 1 : 0

  role       = aws_iam_role.manager_execution[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "job_execution" {
  count = local.create ? 1 : 0

  role       = aws_iam_role.job_execution[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "manager_execution_secrets" {
  count = local.create ? 1 : 0

  name   = "${var.name}-manager-execution-secrets"
  role   = aws_iam_role.manager_execution[0].id
  policy = local.manager_execution_policy
}
