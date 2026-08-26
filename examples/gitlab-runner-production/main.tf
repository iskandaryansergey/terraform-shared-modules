# PRODUCTION GitLab CI runner fleet.
#
# Every deviation from the module defaults here is deliberate and commented. The
# short version of the posture:
#   - token never enters Terraform state (SSM SecureString, written out of band)
#   - everything the manager runs is version-pinned and checksum-verified
#   - baked AMIs: fast cold starts, no boot-time package supply chain, stationary plans
#   - single-use workers, unprivileged jobs, no public IPs, CMK-encrypted disks
#   - a permissions boundary on both roles
#   - alarms that actually page, because silent CI failure is the likely failure
#   - Spot-first with a small on-demand floor so a Spot crunch can't stop all CI

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}

# ----------------------------------------------------------------------------
# CMK for the runner token and every EBS volume in the fleet.
# The AWS-managed key would leave the token decryptable by anything in the
# account holding kms:Decrypt on it; this key policy names only what needs it.
# ----------------------------------------------------------------------------
resource "aws_kms_key" "runners" {
  description             = "GitLab CI runner fleet - token + EBS encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  # The policy is INLINE, not a separate aws_kms_key_policy. A separate resource
  # is applied after the key, and the module's KMS-encrypted log group has fewer
  # dependencies than the roles - so it gets created while the key still has only
  # the default policy and fails with "Access denied. Check the permission of the
  # KMS key". Inline means the grants exist the moment the key does.
  #
  # The fleet roles are granted by ARN PATTERN rather than by referencing the
  # module's outputs: referencing them here would create a cycle, since the
  # module consumes this key.
  policy = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "runners" {
  name          = "alias/ci-runners"
  target_key_id = aws_kms_key.runners.key_id
}

data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  # The fleet's roles, matched by name pattern (the module names them
  # "<name>-manager" / "<name>-worker"). Pattern-matching instead of referencing
  # module.runners.*_role_arn is deliberate: the module consumes this key, so a
  # direct reference would be a dependency cycle.
  statement {
    sid       = "FleetUse"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = ["arn:${local.partition}:iam::${local.account_id}:role/ci-prod-*"]
    }
  }

  # A KMS-encrypted CloudWatch log group can't be created without this: the Logs
  # service does the encrypting, not the instance role. Scoped by encryption
  # context so the key can't be used for other accounts' log groups.
  statement {
    sid       = "CloudWatchLogs"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:*"]
    }
  }

  # EBS encryption is performed by the Auto Scaling service principal on the
  # ASG's behalf, not by the instance role - a classic thing to miss.
  statement {
    sid       = "AutoScalingEbs"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:CreateGrant", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"]
    }
  }
}

# ----------------------------------------------------------------------------
# Distributed cache. With single-use workers there's no local cache to reuse, so
# a shared S3 cache is usually the biggest CI speed win available.
#
# SECURITY NOTE, and the reason this is scoped the way it is: the runner uses
# this from the worker, which means job code inherits it. Write access to a
# SHARED cache is a cross-job poisoning primitive - a malicious job on one
# project can plant a payload that a trusted job on another project restores.
# Mitigations applied here:
#   - keys are namespaced per project, and the policy is scoped to that prefix
#   - no s3:DeleteObject: a job cannot evict another project's cache
# If you run genuinely untrusted pipelines, give them their own bucket (or their
# own fleet) instead of sharing this one.
# ----------------------------------------------------------------------------
data "aws_iam_policy_document" "cache" {
  count = var.cache_bucket != "" ? 1 : 0

  statement {
    sid       = "CacheObjects"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["arn:${local.partition}:s3:::${var.cache_bucket}/${var.cache_key_prefix}/*"]
  }
  statement {
    sid       = "CacheBucket"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${local.partition}:s3:::${var.cache_bucket}"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.cache_key_prefix}/*"]
    }
  }
}

resource "aws_iam_policy" "cache" {
  count = var.cache_bucket != "" ? 1 : 0

  name        = "ci-runners-cache"
  description = "GitLab runner distributed cache access"
  policy      = data.aws_iam_policy_document.cache[0].json
}

# Keep the gateway endpoint from becoming an unrestricted exfiltration channel.
data "aws_iam_policy_document" "s3_endpoint" {
  count = var.cache_bucket != "" ? 1 : 0

  statement {
    sid     = "CacheAndAmazonLinuxRepos"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
    resources = [
      "arn:${local.partition}:s3:::${var.cache_bucket}",
      "arn:${local.partition}:s3:::${var.cache_bucket}/*",
      # AL2023 package repos + the SSM agent's update bucket. An endpoint policy
      # is default-deny, so anything omitted here silently stops working from
      # these subnets. Adjust the repo bucket if your region differs.
      "arn:${local.partition}:s3:::al2023-repos-${var.aws_region}-de612dc2/*",
      "arn:${local.partition}:s3:::amazon-ssm-${var.aws_region}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

# ----------------------------------------------------------------------------
# The fleet
# ----------------------------------------------------------------------------
module "runners" {
  source = "../../modules/gitlab-runner"

  name       = "ci-prod"
  vpc_id     = var.vpc_id
  gitlab_url = var.gitlab_url

  worker_subnet_ids  = var.worker_subnet_ids
  manager_subnet_ids = var.manager_subnet_ids

  # Token lives in SSM already - it never passes through Terraform, so it never
  # lands in state.
  runner_token_ssm_parameter = var.runner_token_ssm_parameter

  kms_key_arn              = aws_kms_key.runners.arn
  permissions_boundary_arn = var.permissions_boundary_arn

  # ---- supply chain: pinned and verified -----------------------------------
  worker_ami_id           = var.worker_ami_id
  manager_ami_id          = var.manager_ami_id
  gitlab_runner_version   = var.gitlab_runner_version
  fleeting_plugin_version = var.fleeting_plugin_version
  fleeting_plugin_sha256  = var.fleeting_plugin_sha256
  # allow_unpinned_artifacts intentionally left false - the module refuses to
  # build unpinned unless you say so explicitly, which is the point.

  # ---- isolation ------------------------------------------------------------
  docker_privileged     = false # jobs get no route to worker root
  capacity_per_instance = 1     # one job per VM: no shared kernel between jobs
  max_use_count         = 1     # destroy the worker after every job
  imds_hop_limit        = 1     # containers can't reach the instance role

  # ---- capacity + cost ------------------------------------------------------
  max_instances = var.max_instances

  # Spot-first, with a small on-demand floor so a Spot capacity crunch degrades
  # throughput instead of stopping CI outright.
  spot_enabled                    = true
  on_demand_base_capacity         = 1
  on_demand_percentage_above_base = 0
  spot_allocation_strategy        = "price-capacity-optimized"
  capacity_rebalance              = true

  # Six types across four families - pool diversity is the real defence against
  # Spot interruption.
  worker_instance_types = [
    "m6i.xlarge", "m6a.xlarge", "m5.xlarge",
    "m5a.xlarge", "m6in.xlarge", "m5n.xlarge",
  ]
  worker_disk_gb         = 100 # image builds fill disks
  worker_disk_throughput = 250

  # A warm worker during working hours buys instant pickup; scale to zero
  # otherwise. Tune the window to where your engineers actually are.
  autoscaling_policies = [
    {
      idle_count = 2
      idle_time  = "20m0s"
      periods    = ["* 8-19 * * mon-fri"]
      timezone   = "Europe/London"
    },
    { idle_count = 0, idle_time = "5m0s", periods = ["* * * * *"] },
  ]

  # Don't let a 500-job pipeline stampede the EC2 API.
  scale_throttle = { limit = 5, burst = 20 }

  manager_instance_type = "t4g.small"
  manager_self_heal     = true
  # Safe to enable because the manager AMI is pinned: nothing but a deliberate
  # version bump will replace the instance.
  manager_instance_refresh = true

  # ---- network --------------------------------------------------------------
  assign_public_ips = false
  # Default worker egress already excludes RFC1918. Narrow further to a proxy or
  # an allow-list if your security team requires it.
  create_vpc_endpoints = true # S3 gateway + SSM endpoints keep traffic off NAT
  # An unscoped S3 gateway endpoint would bypass the 443 egress rules entirely.
  s3_endpoint_policy_json = var.cache_bucket == "" ? "" : data.aws_iam_policy_document.s3_endpoint[0].json

  # ---- observability --------------------------------------------------------
  create_alarms        = true
  alarm_sns_topic_arns = var.alarm_sns_topic_arns
  log_retention_days   = 90

  # ---- job permissions: the actual blast radius of a compromised job --------
  additional_worker_policy_arns = concat(
    var.job_policy_arns,
    var.cache_bucket != "" ? [aws_iam_policy.cache[0].arn] : [],
  )

  # ---- distributed cache ----------------------------------------------------
  # Path MUST be set and MUST match the IAM prefix below. Without it every cache
  # object key starts "project/<id>/..." while the grant is scoped to
  # "<prefix>/*", so every save and restore is AccessDenied - and GitLab logs
  # that as a warning, so pipelines just get quietly slower forever.
  extra_runner_config_toml = var.cache_bucket == "" ? "" : <<-EOT
      [runners.cache]
        Type = "s3"
        Path = "${var.cache_key_prefix}"
        Shared = true
        [runners.cache.s3]
          BucketName = "${var.cache_bucket}"
          BucketLocation = "${var.aws_region}"
          AuthenticationType = "iam"
  EOT

  tags = var.tags
}
