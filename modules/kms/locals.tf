locals {
  create = var.create

  partition  = coalesce(one(data.aws_partition.current[*].partition), "aws")
  region     = coalesce(one(data.aws_region.current[*].name), "us-east-1")
  account_id = coalesce(one(data.aws_caller_identity.current[*].account_id), "000000000000")
  # Replicas are created by modules/replica, in a provider for this region;
  # this module only compiles what they need.
  replica_region = var.replica_region != "" ? var.replica_region : local.region
  regions        = { primary = local.region, replica = local.replica_region }

  acknowledged = toset(var.acknowledged_checks)
  root_arn     = "arn:${local.partition}:iam::${local.account_id}:root"
  # KMS rejects wildcards in principal ARNs.
  iam_arn_re = "^arn:aws[a-z-]*:iam::[0-9]{12}:(root|role/[^*?]+|user/[^*?]+)$"

  # -------------------------------------------------------------------------
  # Deployers: named, or the role running the plan
  # -------------------------------------------------------------------------

  # A federated-user or root session has no IAM role behind it: no deployer.
  detected_issuer   = one(data.aws_iam_session_context.deployer[*].issuer_arn)
  detected_deployer = can(regex(local.iam_arn_re, local.detected_issuer)) ? local.detected_issuer : null
  deployers         = length(var.deployers) > 0 ? var.deployers : compact([local.detected_deployer])
  deployers_source  = length(var.deployers) > 0 ? "named" : (local.detected_deployer != null ? "detected" : "none")
  deployer_accounts = distinct(compact([for p in local.deployers : try(regex("^arn:aws[a-z-]*:iam::([0-9]{12}):", p)[0], "")]))

  break_glass = var.guardrails.break_glass
  exempt      = distinct(concat(local.deployers, local.break_glass))
  # A disaster-recovery workspace's role owns the replicas, so the replicas'
  # guardrails exempt it too; the primary's do not.
  exempt_in = { primary = local.exempt, replica = distinct(concat(local.exempt, var.replica_deployers)) }

  # -------------------------------------------------------------------------
  # Keys, with profiles and defaults resolved
  # -------------------------------------------------------------------------

  profiles = {
    ""        = { services = [], spec = "SYMMETRIC_DEFAULT", usage = "ENCRYPT_DECRYPT" }
    logs      = { services = ["logs"], spec = "SYMMETRIC_DEFAULT", usage = "ENCRYPT_DECRYPT" }
    secrets   = { services = ["secretsmanager", "ssm"], spec = "SYMMETRIC_DEFAULT", usage = "ENCRYPT_DECRYPT" }
    database  = { services = ["rds", "dms", "backup"], spec = "SYMMETRIC_DEFAULT", usage = "ENCRYPT_DECRYPT" }
    storage   = { services = ["s3", "ebs", "efs", "backup"], spec = "SYMMETRIC_DEFAULT", usage = "ENCRYPT_DECRYPT" }
    messaging = { services = ["sns", "sqs", "cloudwatch-to-sns", "eventbridge-to-sns", "eventbridge-to-sqs", "sns-to-sqs"], spec = "SYMMETRIC_DEFAULT", usage = "ENCRYPT_DECRYPT" }
    signing   = { services = [], spec = "ECC_NIST_P256", usage = "SIGN_VERIFY" }
    mac       = { services = [], spec = "HMAC_256", usage = "GENERATE_VERIFY_MAC" }
    dnssec    = { services = ["route53-dnssec"], spec = "ECC_NIST_P256", usage = "SIGN_VERIFY" }
  }

  # A spec given without a usage takes the usage most specs are made for.
  usage_for_spec = {
    SYMMETRIC_DEFAULT = "ENCRYPT_DECRYPT", RSA_2048 = "ENCRYPT_DECRYPT", RSA_3072 = "ENCRYPT_DECRYPT", RSA_4096 = "ENCRYPT_DECRYPT",
    ECC_NIST_P256     = "SIGN_VERIFY", ECC_NIST_P384 = "SIGN_VERIFY", ECC_NIST_P521 = "SIGN_VERIFY", ECC_SECG_P256K1 = "SIGN_VERIFY",
    HMAC_224          = "GENERATE_VERIFY_MAC", HMAC_256 = "GENERATE_VERIFY_MAC", HMAC_384 = "GENERATE_VERIFY_MAC", HMAC_512 = "GENERATE_VERIFY_MAC",
    SM2               = "ENCRYPT_DECRYPT",
  }

  valid_usages = {
    SYMMETRIC_DEFAULT = ["ENCRYPT_DECRYPT"]
    RSA_2048          = ["ENCRYPT_DECRYPT", "SIGN_VERIFY"]
    RSA_3072          = ["ENCRYPT_DECRYPT", "SIGN_VERIFY"]
    RSA_4096          = ["ENCRYPT_DECRYPT", "SIGN_VERIFY"]
    ECC_NIST_P256     = ["SIGN_VERIFY", "KEY_AGREEMENT"]
    ECC_NIST_P384     = ["SIGN_VERIFY", "KEY_AGREEMENT"]
    ECC_NIST_P521     = ["SIGN_VERIFY", "KEY_AGREEMENT"]
    ECC_SECG_P256K1   = ["SIGN_VERIFY"]
    HMAC_224          = ["GENERATE_VERIFY_MAC"]
    HMAC_256          = ["GENERATE_VERIFY_MAC"]
    HMAC_384          = ["GENERATE_VERIFY_MAC"]
    HMAC_512          = ["GENERATE_VERIFY_MAC"]
    SM2               = ["ENCRYPT_DECRYPT", "SIGN_VERIFY", "KEY_AGREEMENT"]
  }

  # A key with generations becomes one key per generation, <key>-<generation>;
  # the last is active. Everything below works on these names.
  expanded_keys = merge([
    for k, v in var.keys : {
      for i, g in(length(v.generations) == 0 ? [""] : v.generations) : (g == "" ? k : "${k}-${g}") => merge(v, {
        base       = k
        generation = g
        active     = i == max(length(v.generations), 1) - 1
      })
    }
  ]...)

  keys = {
    for k, v in local.expanded_keys : k => merge(v, {
      spec = v.spec != "" ? v.spec : local.profiles[v.purpose].spec
      # A spec without a usage keeps the purpose's usage when the two combine
      # (signing + RSA_2048 is SIGN_VERIFY), else takes the spec's natural one.
      usage = v.usage != "" ? v.usage : (v.spec == "" ? local.profiles[v.purpose].usage : (
        (v.purpose != "" ? contains(lookup(local.valid_usages, v.spec, []), local.profiles[v.purpose].usage) : false)
        ? local.profiles[v.purpose].usage : lookup(local.usage_for_spec, v.spec, "")
      ))

      # The active key takes the key's aliases; every generation also has
      # its own, <name>-<key>-<generation>.
      aliases              = v.active ? concat(length(v.aliases) > 0 ? v.aliases : ["${var.name}-${v.base}"], v.generation != "" ? ["${var.name}-${k}"] : []) : ["${var.name}-${k}"]
      grants               = v.active ? v.grants : {}
      external             = v.origin == "EXTERNAL"
      key_custodians       = distinct(concat(var.key_custodians, v.key_custodians))
      services             = distinct(concat(local.profiles[v.purpose].services, v.services))
      rotation             = v.rotation != null ? v.rotation : var.key_defaults.rotation
      rotation_period_days = v.rotation_period_days != null ? v.rotation_period_days : var.key_defaults.rotation_period_days
      deletion_window_days = v.deletion_window_days != null ? v.deletion_window_days : var.key_defaults.deletion_window_days
      service_access       = v.service_access != null ? v.service_access : var.key_defaults.service_access

      administrators = distinct(concat(var.administrators, v.administrators))
      users          = distinct(concat(var.users, v.users))
      auditors       = distinct(concat(var.auditors, v.auditors))
      account_roots  = [for a in v.accounts : "arn:${local.partition}:iam::${a}:root"]
      custom_store   = v.custom_key_store_id != ""

      description = v.description != "" ? v.description : "${var.name} ${k}${v.purpose != "" ? " (${v.purpose})" : ""}, managed by Terraform"
    })
  }

  key_kind = {
    for k, v in local.keys : k => (
      v.spec == "SYMMETRIC_DEFAULT" ? "symmetric" :
      v.usage == "GENERATE_VERIFY_MAC" ? "mac" :
      v.usage == "SIGN_VERIFY" ? "sign" :
      v.usage == "KEY_AGREEMENT" ? "agreement" : "asymmetric_encrypt"
    )
  }

  # Automatic rotation exists for symmetric keys with AWS-generated material
  # outside custom key stores, and nowhere else.
  rotates = { for k, v in local.keys : k => v.rotation ? (local.key_kind[k] == "symmetric" ? !(v.custom_store || v.external) : false) : false }

  # The active key of each key with generations.
  active_key = { for k, v in local.keys : v.base => k if v.active }

  # The two key resources, one map: AWS-generated material and imported.
  key_arn = !local.create ? {} : { for k, v in local.keys : k => v.external ? aws_kms_external_key.this[k].arn : aws_kms_key.this[k].arn }
  key_id  = !local.create ? {} : { for k, v in local.keys : k => v.external ? aws_kms_external_key.this[k].id : aws_kms_key.this[k].key_id }

  replicated_keys = { for k, v in local.keys : k => v if v.replicate }

  # A multi-Region replica keeps its primary's key ID, so its ARN is known as
  # soon as the primary exists - before modules/replica creates it.
  replica_arns = !local.create ? {} : {
    for k, v in local.replicated_keys : k => "arn:${local.partition}:kms:${local.replica_region}:${local.account_id}:key/${local.key_id[k]}"
  }

  key_tags = {
    for k, v in local.keys : k => merge(var.tags, var.key_defaults.tags, v.tags, {
      ManagedBy = "Terraform"
      Module    = "kms"
      KeySet    = var.name
      Key       = k
    }, { for g in compact([v.generation]) : "Generation" => g })
  }

  # Keyed by alias name alone (unique, validated), so moving an alias to
  # another key in the set updates it in place instead of recreating it.
  aliases = merge([
    for k, v in local.keys : { for a in v.aliases : a => { key = k, name = "alias/${a}" } }
  ]...)

  # -------------------------------------------------------------------------
  # Action sets
  # -------------------------------------------------------------------------

  # The AWS default policy's administrator list, written out; its wildcards
  # (Create*, Put*...) would also grant every operation KMS adds later.
  manage_actions = [
    "kms:DescribeKey", "kms:EnableKey", "kms:DisableKey", "kms:EnableKeyRotation", "kms:DisableKeyRotation",
    "kms:GetKeyPolicy", "kms:GetKeyRotationStatus", "kms:GetPublicKey", "kms:ListAliases", "kms:ListGrants",
    "kms:ListKeyPolicies", "kms:ListKeyRotations", "kms:ListResourceTags", "kms:ListRetirableGrants",
    "kms:CreateAlias", "kms:UpdateAlias", "kms:DeleteAlias", "kms:UpdateKeyDescription", "kms:RevokeGrant",
    "kms:TagResource", "kms:UntagResource", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion", "kms:RotateKeyOnDemand",
  ]
  multi_region_actions = ["kms:ReplicateKey", "kms:UpdatePrimaryRegion"]

  # Deployers and break-glass also change the policy, create the module's
  # grants and replicate multi-Region keys; administrators do none of these
  # (PutKeyPolicy only with administrators_can_change_policy). ReplicateKey
  # takes a caller-chosen policy for the copy, so it is as strong as
  # PutKeyPolicy over the key material.
  owner_actions = { for k, v in local.keys : k => concat(local.manage_actions, ["kms:PutKeyPolicy", "kms:CreateGrant"], v.multi_region ? local.multi_region_actions : []) }
  admin_actions = { for k, v in local.keys : k => concat(local.manage_actions, var.administrators_can_change_policy ? ["kms:PutKeyPolicy"] : []) }

  audit_actions = {
    for k, v in local.keys : k => concat(
      ["kms:DescribeKey", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus", "kms:ListAliases", "kms:ListGrants", "kms:ListKeyPolicies", "kms:ListKeyRotations", "kms:ListResourceTags"],
      contains(["sign", "agreement", "asymmetric_encrypt"], local.key_kind[k]) ? ["kms:GetPublicKey"] : [],
    )
  }

  # Cryptographic actions by key kind: all of them, the producing half, the
  # consuming half. Describe actions are kept apart because they carry no
  # encryption context.
  crypto_actions_by_kind = {
    symmetric          = { all = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*"], produce = ["kms:Encrypt", "kms:GenerateDataKey*"], consume = ["kms:Decrypt"] }
    asymmetric_encrypt = { all = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*"], produce = ["kms:Encrypt"], consume = ["kms:Decrypt"] }
    sign               = { all = ["kms:Sign", "kms:Verify"], produce = ["kms:Sign"], consume = ["kms:Verify"] }
    mac                = { all = ["kms:GenerateMac", "kms:VerifyMac"], produce = ["kms:GenerateMac"], consume = ["kms:VerifyMac"] }
    agreement          = { all = ["kms:DeriveSharedSecret"], produce = ["kms:DeriveSharedSecret"], consume = ["kms:DeriveSharedSecret"] }
  }
  describe_actions = {
    for k, v in local.keys : k => contains(["sign", "agreement", "asymmetric_encrypt"], local.key_kind[k]) ? ["kms:DescribeKey", "kms:GetPublicKey"] : ["kms:DescribeKey"]
  }

  grant_for_resource_actions = ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"]

  all_crypto_actions = [
    "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:GenerateMac", "kms:VerifyMac",
    "kms:Sign", "kms:Verify", "kms:DeriveSharedSecret",
  ]

  # A consumer never needs to manage a key; a requirement asking for one of
  # these is refused.
  management_only_actions = [
    "kms:PutKeyPolicy", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion", "kms:DisableKey", "kms:EnableKey",
    "kms:DisableKeyRotation", "kms:EnableKeyRotation", "kms:RotateKeyOnDemand", "kms:CreateAlias", "kms:UpdateAlias",
    "kms:DeleteAlias", "kms:TagResource", "kms:UntagResource", "kms:UpdateKeyDescription", "kms:ReplicateKey",
    "kms:UpdatePrimaryRegion", "kms:ImportKeyMaterial", "kms:DeleteImportedKeyMaterial", "kms:CreateKey",
  ]

  # Encryption context on direct use: required keys as Null conditions, and
  # allowed values as StringEquals (tenant isolation, policy variables).
  # Symmetric keys only: the others take no context.
  context_condition = {
    for k, v in local.keys : k => merge(
      (local.key_kind[k] == "symmetric" ? length(v.require_encryption_context) > 0 : false) ? { Null = { for c in v.require_encryption_context : "kms:EncryptionContext:${c}" => "false" } } : {},
      (local.key_kind[k] == "symmetric" ? length(v.encryption_context_values) > 0 : false) ? { StringEquals = { for c, vals in v.encryption_context_values : "kms:EncryptionContext:${c}" => vals } } : {},
    )
  }

  # -------------------------------------------------------------------------
  # Role statements
  # -------------------------------------------------------------------------

  role_statements = {
    for k, v in local.keys : k => concat(
      [for s in [{
        Sid = "EnableIamPolicies", Effect = "Allow", Principal = { AWS = local.root_arn }, Action = "kms:*", Resource = "*"
      }] : s if var.iam_delegation],
      [for s in [{
        Sid = "Deployers", Effect = "Allow", Principal = { AWS = local.deployers }, Action = local.owner_actions[k], Resource = "*"
      }] : s if length(local.deployers) > 0],
      [for s in [{
        Sid = "BreakGlass", Effect = "Allow", Principal = { AWS = local.break_glass }, Action = local.owner_actions[k], Resource = "*"
      }] : s if length(local.break_glass) > 0],
      [for s in [{
        Sid = "Administrators", Effect = "Allow", Principal = { AWS = v.administrators }, Action = local.admin_actions[k], Resource = "*"
      }] : s if length(v.administrators) > 0],
      [for s in [{
        Sid = "Auditors", Effect = "Allow", Principal = { AWS = v.auditors }, Action = local.audit_actions[k], Resource = "*"
      }] : s if length(v.auditors) > 0],
      [for s in [merge(
        { Sid = "Users", Effect = "Allow", Principal = { AWS = v.users }, Action = local.crypto_actions_by_kind[local.key_kind[k]].all, Resource = "*" },
        length(local.context_condition[k]) > 0 ? { Condition = local.context_condition[k] } : {},
      )] : s if length(v.users) > 0],
      [for s in [merge(
        { Sid = "Encrypters", Effect = "Allow", Principal = { AWS = v.encrypters }, Action = local.crypto_actions_by_kind[local.key_kind[k]].produce, Resource = "*" },
        length(local.context_condition[k]) > 0 ? { Condition = local.context_condition[k] } : {},
      )] : s if length(v.encrypters) > 0],
      [for s in [merge(
        { Sid = "Decrypters", Effect = "Allow", Principal = { AWS = v.decrypters }, Action = local.crypto_actions_by_kind[local.key_kind[k]].consume, Resource = "*" },
        length(local.context_condition[k]) > 0 ? { Condition = local.context_condition[k] } : {},
      )] : s if length(v.decrypters) > 0],
      [for s in [{
        Sid       = "Describe"
        Effect    = "Allow"
        Principal = { AWS = distinct(concat(v.users, v.encrypters, v.decrypters, v.grant_users)) }
        Action    = local.describe_actions[k]
        Resource  = "*"
      }] : s if length(concat(v.users, v.encrypters, v.decrypters, v.grant_users)) > 0],
      [for s in [{
        Sid       = "GrantsForAwsResources"
        Effect    = "Allow"
        Principal = { AWS = distinct(concat(v.users, v.grant_users)) }
        Action    = local.grant_for_resource_actions
        Resource  = "*"
        Condition = { Bool = { "kms:GrantIsForAWSResource" = "true" } }
      }] : s if local.key_kind[k] == "symmetric" ? length(concat(v.users, v.grant_users)) > 0 : false],
      # Other accounts get use and resource grants; their own IAM policies
      # decide which of their principals actually may.
      [for s in [
        {
          Sid       = "OtherAccounts"
          Effect    = "Allow"
          Principal = { AWS = v.account_roots }
          Action    = concat(local.crypto_actions_by_kind[local.key_kind[k]].all, local.describe_actions[k])
          Resource  = "*"
        },
        {
          Sid       = "OtherAccountsGrantsForAwsResources"
          Effect    = "Allow"
          Principal = { AWS = v.account_roots }
          Action    = local.grant_for_resource_actions
          Resource  = "*"
          Condition = { Bool = { "kms:GrantIsForAWSResource" = "true" } }
        },
      ] : s if length(v.account_roots) == 0 ? false : (s.Sid == "OtherAccounts" ? true : local.key_kind[k] == "symmetric")],
      # Imported material: custodians fetch import parameters (with a SHA-256
      # wrapping only) and import or delete the material.
      [for s in [
        {
          Sid       = "KeyCustodiansImportParameters"
          Effect    = "Allow"
          Principal = { AWS = v.key_custodians }
          Action    = "kms:GetParametersForImport"
          Resource  = "*"
          Condition = { StringEquals = { "kms:WrappingAlgorithm" = ["RSAES_OAEP_SHA_256", "RSA_AES_KEY_WRAP_SHA_256"] } }
        },
        {
          Sid       = "KeyCustodians"
          Effect    = "Allow"
          Principal = { AWS = v.key_custodians }
          Action    = ["kms:DescribeKey", "kms:ImportKeyMaterial", "kms:DeleteImportedKeyMaterial"]
          Resource  = "*"
        },
      ] : s if v.external ? length(v.key_custodians) > 0 : false],
    )
  }

  # -------------------------------------------------------------------------
  # Service presets, per region
  #
  # Service principals only where the service calls KMS as itself; everything
  # else calls with the caller's identity through a forward access session,
  # where kms:ViaService applies - never on a Service principal statement.
  # -------------------------------------------------------------------------

  via_service = {
    s3               = ["s3.%s.amazonaws.com"]
    secretsmanager   = ["secretsmanager.%s.amazonaws.com"]
    rds              = ["rds.%s.amazonaws.com"]
    dms              = ["dms.%s.amazonaws.com"]
    ebs              = ["ec2.%s.amazonaws.com"]
    backup           = ["backup.*.amazonaws.com"] # cross-Region copies call from the destination
    ssm              = ["ssm.%s.amazonaws.com"]
    dynamodb         = ["dynamodb.*.amazonaws.com"] # global tables replicate across Regions
    efs              = ["elasticfilesystem.%s.amazonaws.com"]
    ecr              = ["ecr.%s.amazonaws.com"]
    lambda           = ["lambda.%s.amazonaws.com"]
    kinesis          = ["kinesis.%s.amazonaws.com"]
    firehose         = ["firehose.%s.amazonaws.com"]
    elasticache      = ["elasticache.%s.amazonaws.com", "dax.%s.amazonaws.com"]
    sns              = ["sns.%s.amazonaws.com"]
    sqs              = ["sqs.%s.amazonaws.com"]
    states           = ["states.%s.amazonaws.com"]
    mgn              = ["mgn.%s.amazonaws.com"]
    fsx              = ["fsx.%s.amazonaws.com"]
    glue             = ["glue.%s.amazonaws.com"]
    athena           = ["athena.%s.amazonaws.com"]
    redshift         = ["redshift.%s.amazonaws.com", "redshift-serverless.%s.amazonaws.com"]
    opensearch       = ["es.%s.amazonaws.com", "aoss.%s.amazonaws.com"]
    sagemaker        = ["sagemaker.%s.amazonaws.com"]
    msk              = ["kafka.%s.amazonaws.com"]
    mwaa             = ["airflow.%s.amazonaws.com"]
    mq               = ["mq.%s.amazonaws.com"]
    memorydb         = ["memorydb.%s.amazonaws.com"]
    docdb-elastic    = ["docdb-elastic.%s.amazonaws.com"]
    codeartifact     = ["codeartifact.%s.amazonaws.com"]
    directoryservice = ["directoryservice.%s.amazonaws.com"]
    storagegateway   = ["storagegateway.%s.amazonaws.com"]
    connect          = ["connect.%s.amazonaws.com"]
    workspaces       = ["workspaces.%s.amazonaws.com"]
    xray             = ["xray.%s.amazonaws.com"]
    securitylake     = ["securitylake.%s.amazonaws.com"]
    s3tables         = ["s3tables.%s.amazonaws.com"]
  }

  # Service principals publishing to an encrypted SNS topic or SQS queue.
  # EventBridge to SNS rejects aws:Source* conditions in the key policy.
  source_presets = {
    "cloudwatch-to-sns"  = { principal = "cloudwatch.amazonaws.com", actions = ["kms:GenerateDataKey*", "kms:Decrypt"], scoped = true }
    "eventbridge-to-sns" = { principal = "events.amazonaws.com", actions = ["kms:GenerateDataKey*", "kms:Decrypt"], scoped = false }
    "dms-events-to-sns"  = { principal = "dms.amazonaws.com", actions = ["kms:GenerateDataKey*", "kms:Decrypt"], scoped = true }
    "rds-events-to-sns"  = { principal = "events.rds.amazonaws.com", actions = ["kms:GenerateDataKey*", "kms:Decrypt"], scoped = true }
    "s3-events-to-sns"   = { principal = "s3.amazonaws.com", actions = ["kms:GenerateDataKey*", "kms:Decrypt"], scoped = true }
    "eventbridge-to-sqs" = { principal = "events.amazonaws.com", actions = ["kms:GenerateDataKey", "kms:Decrypt"], scoped = true }
    "s3-events-to-sqs"   = { principal = "s3.amazonaws.com", actions = ["kms:GenerateDataKey", "kms:Decrypt"], scoped = true }
    "sns-to-sqs"         = { principal = "sns.amazonaws.com", actions = ["kms:GenerateDataKey", "kms:Decrypt"], scoped = true }
    # SES receiving mail (to S3/SNS) and publishing to an encrypted topic
    # calls KMS as itself, not through a caller's forward access session.
    ses = { principal = "ses.amazonaws.com", actions = ["kms:GenerateDataKey*", "kms:Decrypt"], scoped = true }
  }

  autoscaling_slr = "arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"

  # Every statement-bearing preset, per region.
  preset_library = {
    for which, r in local.regions : which => merge(
      {
        logs = [{
          Sid       = "ServiceLogs"
          Effect    = "Allow"
          Principal = { Service = "logs.${r}.amazonaws.com" }
          Action    = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
          Resource  = "*"
          Condition = { ArnLike = { "kms:EncryptionContext:aws:logs:arn" = "arn:${local.partition}:logs:${r}:${local.account_id}:log-group:*" } }
        }]
        cloudtrail = [
          {
            Sid       = "ServiceCloudTrailEncrypt"
            Effect    = "Allow"
            Principal = { Service = "cloudtrail.amazonaws.com" }
            Action    = "kms:GenerateDataKey*"
            Resource  = "*"
            Condition = {
              StringLike   = { "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:${local.partition}:cloudtrail:*:*:trail/*" }
              StringEquals = { "aws:SourceAccount" = local.account_id }
            }
          },
          {
            Sid       = "ServiceCloudTrailDescribe"
            Effect    = "Allow"
            Principal = { Service = "cloudtrail.amazonaws.com" }
            Action    = ["kms:DescribeKey", "kms:Decrypt"]
            Resource  = "*"
            Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
          },
        ]
        eventbridge-bus = [
          {
            Sid       = "ServiceEventBridgeBusDescribe"
            Effect    = "Allow"
            Principal = { Service = "events.amazonaws.com" }
            Action    = "kms:DescribeKey"
            Resource  = "*"
          },
          {
            Sid       = "ServiceEventBridgeBus"
            Effect    = "Allow"
            Principal = { Service = "events.amazonaws.com" }
            Action    = ["kms:GenerateDataKey", "kms:Decrypt"]
            Resource  = "*"
            Condition = {
              ArnLike      = { "kms:EncryptionContext:aws:events:event-bus:arn" = "arn:${local.partition}:events:${r}:${local.account_id}:event-bus/*" }
              StringEquals = { "aws:SourceAccount" = local.account_id }
            }
          },
        ]
        route53-dnssec = [
          {
            Sid       = "ServiceRoute53Dnssec"
            Effect    = "Allow"
            Principal = { Service = "dnssec-route53.amazonaws.com" }
            Action    = ["kms:DescribeKey", "kms:GetPublicKey", "kms:Sign"]
            Resource  = "*"
            Condition = {
              StringEquals = { "aws:SourceAccount" = local.account_id }
              ArnLike      = { "aws:SourceArn" = "arn:${local.partition}:route53:::hostedzone/*" }
            }
          },
          {
            Sid       = "ServiceRoute53DnssecGrants"
            Effect    = "Allow"
            Principal = { Service = "dnssec-route53.amazonaws.com" }
            Action    = "kms:CreateGrant"
            Resource  = "*"
            Condition = { Bool = { "kms:GrantIsForAWSResource" = "true" } }
          },
        ]
        autoscaling-ebs = [
          {
            Sid       = "ServiceLinkedAutoScaling"
            Effect    = "Allow"
            Principal = { AWS = local.autoscaling_slr }
            Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
            Resource  = "*"
          },
          {
            Sid       = "ServiceLinkedAutoScalingGrants"
            Effect    = "Allow"
            Principal = { AWS = local.autoscaling_slr }
            Action    = "kms:CreateGrant"
            Resource  = "*"
            Condition = { Bool = { "kms:GrantIsForAWSResource" = "true" } }
          },
        ]
      },
      {
        for name, p in local.source_presets : name => [merge(
          {
            Sid       = "Source${replace(title(replace(name, "-", " ")), " ", "")}"
            Effect    = "Allow"
            Principal = { Service = p.principal }
            Action    = p.actions
            Resource  = "*"
          },
          p.scoped ? { Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } } } : {},
        )]
      },
    )
  }

  # Presets that need a specific key kind; the rest need SYMMETRIC_DEFAULT.
  preset_spec = { "route53-dnssec" = { spec = "ECC_NIST_P256", usage = "SIGN_VERIFY" } }

  via_values = {
    for k, v in local.keys : k => {
      for which, r in local.regions : which => distinct(concat(
        flatten([for s in v.services : [for f in lookup(local.via_service, s, []) : strcontains(f, "%s") ? format(f, r) : f]]),
        [for f in v.via_services : strcontains(f, "%s") ? format(f, r) : f],
      ))
    }
  }

  # Who may use a key through its caller-path services: "account" is the AWS
  # managed key pattern (any principal of these accounts, only through those
  # services); "named" keeps it to the key's own principals.
  through_principals = {
    for k, v in local.keys : k => v.service_access == "account" ? ["*"] : distinct(concat(
      v.users, v.encrypters, v.decrypters, local.deployers, v.account_roots,
    ))
  }

  preset_statements = {
    for k, v in local.keys : k => {
      for which, r in local.regions : which => concat(
        flatten([for s in v.services : lookup(local.preset_library[which], s, [])]),
        [for s in [
          {
            Sid       = "ThroughServices"
            Effect    = "Allow"
            Principal = { AWS = local.through_principals[k] }
            Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
            Resource  = "*"
            Condition = {
              StringEquals = { "kms:CallerAccount" = distinct(concat([local.account_id], v.accounts)) }
              StringLike   = { "kms:ViaService" = local.via_values[k][which] }
            }
          },
          {
            Sid       = "ThroughServicesGrants"
            Effect    = "Allow"
            Principal = { AWS = local.through_principals[k] }
            Action    = local.grant_for_resource_actions
            Resource  = "*"
            Condition = {
              StringEquals = { "kms:CallerAccount" = distinct(concat([local.account_id], v.accounts)) }
              StringLike   = { "kms:ViaService" = local.via_values[k][which] }
              Bool         = { "kms:GrantIsForAWSResource" = "true" }
            }
          },
        ] : s if length(local.via_values[k][which]) > 0 && length(local.through_principals[k]) > 0],
      )
    }
  }

  # Decoded from "[]" when empty: a ternary between [] and the decoded tuple
  # is a type error for any list of two or more statements.
  extra_statements = { for k, v in local.keys : k => jsondecode(v.extra_statements == "" ? "[]" : v.extra_statements) }

  # -------------------------------------------------------------------------
  # Consumer contracts
  # -------------------------------------------------------------------------

  principal_roles = merge({ deployer = local.deployers }, var.principal_roles)

  # A consumer must be a list of objects with a key field; anything else (a
  # module object passed whole, a string) is reported, not silently empty.
  consumer_readable = {
    for c in keys(var.consumers) : c => can(concat(var.consumers[c], [])) ? alltrue([for r in var.consumers[c] : can(r.key)]) : false
  }
  unreadable_consumers = [for c, ok in local.consumer_readable : c if !ok]

  requirements = flatten([
    for c in keys(var.consumers) : local.consumer_readable[c] ? [
      for i, r in var.consumers[c] : {
        consumer   = c
        index      = i
        key        = try(tostring(r.key), "")
        sid        = try(tostring(r.sid), "")
        services   = try([for s in r.principals.services : tostring(s)], [])
        arns       = try([for s in r.principals.arns : tostring(s)], [])
        roles      = try([for s in r.principals.roles : tostring(s)], [])
        actions    = try([for s in r.actions : tostring(s)], [])
        conditions = try([for x in r.conditions : { test = tostring(x.test), variable = tostring(x.variable), values = [for y in x.values : tostring(y)] }], [])
        purpose    = try(tostring(r.purpose), try(tostring(r.why), ""))
        machine    = can(r.principals) && can(r.sid) && (can(concat(r.actions, [])) ? length(r.actions) > 0 : false)
        # A field present with the wrong shape (a string where a list belongs)
        # would otherwise compile to an empty list.
        misshapen = !can(concat(try(r.actions, []), [])) || anytrue([
          for f in ["services", "arns", "roles"] : !can(concat(try(r.principals[f], []), []))
        ]) || !can(concat(try(r.conditions, []), []))
        label = "${c}[${i}]${try(" ${tostring(r.sid)}", "")}"
      }
    ] : []
  ])

  # A requirement whose key is empty belongs to a feature the producer has off.
  not_applicable = [for r in local.requirements : r.label if r.key == ""]

  grant_actions = ["kms:creategrant", "kms:listgrants", "kms:revokegrant"]

  # Classified whatever the key: on a first plan the key ARNs are unknown,
  # and a refusal must still stop the plan before any key is created.
  classified = [
    for r in local.requirements : merge(r, {
      applicable = r.key != ""
      # Action names are case-insensitive and may end in *: compared as
      # patterns, so kms:Put* or kms:putkeypolicy count as PutKeyPolicy.
      patterns = [for a in r.actions : "^${replace(lower(a), "*", ".*")}$"]
    })
  ]

  classified_full = [
    for r in local.classified : merge(r, {
      aws              = distinct(concat(r.arns, flatten([for role in r.roles : lookup(local.principal_roles, role, [])])))
      unresolved_roles = [for role in r.roles : role if length(lookup(local.principal_roles, role, [])) == 0]
      # Refused at plan: a public principal, a principal that is no IAM ARN,
      # or an action that is not a plain kms: action, kms:*, or one that
      # covers a management action no consumer needs.
      rejected = r.machine ? (
        anytrue([for a in r.arns : !can(regex(local.iam_arn_re, a))]) ||
        anytrue([for s in r.services : !can(regex("^[a-z0-9.-]+\\.amazonaws\\.com(\\.cn)?$", s))]) ||
        anytrue([for a in r.actions : !can(regex("^kms:[A-Za-z]+\\*?$", a))]) ||
        anytrue([for p in r.patterns : anytrue([for m in local.management_only_actions : can(regex(p, lower(m)))])])
      ) : false
      # Not compiled: a condition without values, the same test and key twice
      # (merging them would turn an AND into an OR), or a field of the wrong
      # shape.
      malformed = r.machine ? (
        r.misshapen ||
        anytrue([for c in r.conditions : length(c.values) == 0 || c.test == "" || c.variable == ""]) ||
        length(r.conditions) != length(distinct([for c in r.conditions : "${c.test}|${c.variable}"]))
      ) : r.misshapen
      # Grant actions with neither kms:ViaService nor kms:GrantIsForAWSResource
      # would let the principal grant the key to anyone: they are compiled
      # into a second statement that only allows grants for AWS resources.
      grant_list = [for i, a in r.actions : a if anytrue([for g in local.grant_actions : can(regex(r.patterns[i], g))])]
      grants_scoped = anytrue([
        for c in r.conditions : contains(["kms:viaservice", "kms:grantisforawsresource"], lower(c.variable))
      ])
    })
  ]

  machine = [for r in local.classified_full : r if r.applicable && r.machine && !r.rejected && !r.malformed]

  key_match_ids = {
    for k, v in local.keys : k => {
      primary = concat(
        [for a in v.aliases : "arn:${local.partition}:kms:${local.region}:${local.account_id}:alias/${a}"],
        [for a in v.aliases : "alias/${a}"],
        local.create ? [local.key_arn[k], local.key_id[k]] : [],
      )
      replica = !v.replicate ? [] : concat(
        [for a in v.aliases : "arn:${local.partition}:kms:${local.replica_region}:${local.account_id}:alias/${a}"],
        local.create ? [local.replica_arns[k]] : [],
      )
    }
  }

  requirements_by_key = {
    for k, v in local.keys : k => {
      for which in keys(local.regions) : which => [for r in local.machine : r if contains(local.key_match_ids[k][which], r.key)]
    }
  }

  contract_statements = {
    for k, v in local.keys : k => {
      for which in keys(local.regions) : which => [
        for s in flatten([
          for r in local.requirements_by_key[k][which] : [
            for part in(r.grants_scoped || length(r.grant_list) == 0 ? [
              { suffix = "", actions = r.actions, grants_only = false },
              ] : [
              { suffix = "", actions = [for a in r.actions : a if !contains(r.grant_list, a)], grants_only = false },
              { suffix = "Grants", actions = r.grant_list, grants_only = true },
              ]) : merge(
              {
                Sid    = "Consumer${replace(title(replace(r.consumer, "/[-_]/", " ")), " ", "")}${r.index}${replace(r.sid, "/[^A-Za-z0-9]/", "")}${part.suffix}"
                Effect = "Allow"
                Principal = merge(
                  length(r.services) > 0 ? { Service = r.services } : {},
                  length(r.aws) > 0 ? { AWS = r.aws } : {},
                )
                Action   = part.actions
                Resource = "*"
              },
              length(r.conditions) + (part.grants_only ? 1 : 0) > 0 ? {
                Condition = merge(
                  { for t in distinct([for c in r.conditions : c.test]) : t => { for c in r.conditions : c.variable => c.values if c.test == t } },
                  part.grants_only ? {
                    Bool = merge(
                      { for c in r.conditions : c.variable => c.values if c.test == "Bool" },
                      { "kms:GrantIsForAWSResource" = "true" },
                    )
                  } : {},
                )
              } : {},
            ) if length(part.actions) > 0
          ] if length(r.services) + length(r.aws) > 0
        ]) : s
      ]
    }
  }

  # -------------------------------------------------------------------------
  # Guardrails
  # -------------------------------------------------------------------------

  org_exempt_accounts = distinct(concat(var.guardrails.trusted_accounts, local.deployer_accounts, [for p in var.replica_deployers : regex("^arn:aws[a-z-]*:iam::([0-9]{12}):", p)[0]]))
  vpce_ids            = { primary = var.guardrails.vpc_endpoint_ids, replica = var.guardrails.replica_vpc_endpoint_ids }

  guardrail_statements = {
    for which in keys(local.regions) : which => concat(
      [for s in [
        {
          Sid       = "DenyOutsideOrganization"
          Effect    = "Deny"
          Principal = "*"
          Action    = "kms:*"
          Resource  = "*"
          Condition = {
            StringNotEqualsIfExists = merge(
              { "aws:PrincipalOrgID" = var.guardrails.organization_id },
              length(local.org_exempt_accounts) > 0 ? { "aws:PrincipalAccount" = local.org_exempt_accounts } : {},
            )
            BoolIfExists = { "aws:PrincipalIsAWSService" = "false" }
          }
        },
        {
          Sid       = "DenyServicesActingForOtherOrganizations"
          Effect    = "Deny"
          Principal = "*"
          Action    = "kms:*"
          Resource  = "*"
          Condition = {
            StringNotEqualsIfExists = merge(
              { "aws:SourceOrgID" = var.guardrails.organization_id },
              length(var.guardrails.trusted_accounts) > 0 ? { "aws:SourceAccount" = var.guardrails.trusted_accounts } : {},
            )
            Null = { "aws:SourceAccount" = "false" }
            Bool = { "aws:PrincipalIsAWSService" = "true" }
          }
        },
      ] : s if var.guardrails.organization_id != ""],
      [for s in [{
        Sid       = "DenyCryptoOutsideVpcEndpoints"
        Effect    = "Deny"
        Principal = "*"
        Action    = local.all_crypto_actions
        Resource  = "*"
        Condition = {
          StringNotEqualsIfExists = { "aws:SourceVpce" = local.vpce_ids[which] }
          BoolIfExists            = { "aws:PrincipalIsAWSService" = "false", "aws:ViaAWSService" = "false" }
          # EBS decrypts with an instance identity role from the service network.
          # Service-linked roles (e.g. Auto Scaling's, for encrypted volumes)
          # call KMS directly from the service's network.
          ArnNotLikeIfExists = { "aws:PrincipalArn" = concat(["arn:${local.partition}:iam::*:role/aws:ec2-infrastructure*", "arn:${local.partition}:iam::*:role/aws-service-role/*"], var.guardrails.vpc_endpoint_exempt_principals) }
        }
      }] : s if length(local.vpce_ids[which]) > 0],
      [for s in [merge(
        { Sid = "DenyDeletionAndDisable", Effect = "Deny", Principal = "*", Action = ["kms:ScheduleKeyDeletion", "kms:DisableKey"], Resource = "*" },
        length(local.exempt_in[which]) > 0 ? { Condition = { ArnNotLike = { "aws:PrincipalArn" = local.exempt_in[which] } } } : {},
      )] : s if var.guardrails.deletion_protection],
      [for s in [{
        Sid       = "DenyShortDeletionWindow"
        Effect    = "Deny"
        Principal = "*"
        Action    = "kms:ScheduleKeyDeletion"
        Resource  = "*"
        Condition = { NumericLessThan = { "kms:ScheduleKeyDeletionPendingWindowInDays" = tostring(var.guardrails.min_deletion_window_days) } }
      }] : s if var.guardrails.min_deletion_window_days > 0],
      [for s in [{
        Sid       = "DenyLongerRotationPeriods"
        Effect    = "Deny"
        Principal = "*"
        Action    = "kms:EnableKeyRotation"
        Resource  = "*"
        Condition = { NumericGreaterThan = { "kms:RotationPeriodInDays" = tostring(var.guardrails.max_rotation_period_days) } }
      }] : s if var.guardrails.max_rotation_period_days > 0],
      [for s in [{
        Sid       = "DenyTagChanges"
        Effect    = "Deny"
        Principal = "*"
        Action    = ["kms:TagResource", "kms:UntagResource"]
        Resource  = "*"
        Condition = { ArnNotLike = { "aws:PrincipalArn" = local.exempt_in[which] } }
      }] : s if var.guardrails.protect_tags && length(local.exempt) > 0],
      [for s in [{
        Sid       = "DenyBreakGlassWithoutMfa"
        Effect    = "Deny"
        Principal = "*"
        Action    = "kms:*"
        Resource  = "*"
        Condition = {
          ArnLike      = { "aws:PrincipalArn" = local.break_glass }
          BoolIfExists = { "aws:MultiFactorAuthPresent" = "false" }
        }
      }] : s if var.guardrails.break_glass_requires_mfa && length(local.break_glass) > 0],
      [for s in [{
        Sid       = "DenyDeletionOfKeysInUse"
        Effect    = "Deny"
        Principal = "*"
        Action    = "kms:ScheduleKeyDeletion"
        Resource  = "*"
        Condition = { NumericLessThan = { "kms:TrailingDaysWithoutKeyUsage" = tostring(var.guardrails.min_days_unused_before_deletion) } }
      }] : s if var.guardrails.min_days_unused_before_deletion > 0],
      [for s in [{
        Sid       = "DenyPolicyChanges"
        Effect    = "Deny"
        Principal = "*"
        Action    = "kms:PutKeyPolicy"
        Resource  = "*"
        Condition = { ArnNotLike = { "aws:PrincipalArn" = local.exempt_in[which] } }
      }] : s if var.guardrails.protect_policy && length(local.exempt) > 0],
      [for s in [{
        Sid       = "DenyAliasAndRotationChanges"
        Effect    = "Deny"
        Principal = "*"
        Action    = ["kms:CreateAlias", "kms:UpdateAlias", "kms:DeleteAlias", "kms:DisableKeyRotation"]
        Resource  = "*"
        Condition = { ArnNotLike = { "aws:PrincipalArn" = local.exempt_in[which] } }
      }] : s if var.guardrails.protect_aliases_and_rotation && length(local.exempt) > 0],
    )
  }

  # Per key and region. A multi-Region key replicates only to replica_region
  # and is promoted only between its two regions: ReplicateKey sets the copy's
  # policy, so a copy elsewhere would escape every statement here. Owners of
  # the replicas (replica_deployers) replicate the key from the primary and
  # own the replica.
  key_region_statements = {
    for k, v in local.keys : k => {
      for which in keys(local.regions) : which => concat(
        [for s in [
          {
            Sid       = "DenyReplicationOutsideTheReplicaRegion"
            Effect    = "Deny"
            Principal = "*"
            Action    = "kms:ReplicateKey"
            Resource  = "*"
            Condition = { StringNotEquals = { "kms:ReplicaRegion" = [local.replica_region] } }
          },
          {
            Sid       = "DenyPromotionOutsideTheTwoRegions"
            Effect    = "Deny"
            Principal = "*"
            Action    = "kms:UpdatePrimaryRegion"
            Resource  = "*"
            Condition = { StringNotEquals = { "kms:PrimaryRegion" = distinct([local.region, local.replica_region]) } }
          },
        ] : s if v.multi_region ? var.replica_region != "" : false],
        [for s in [{
          Sid       = "DenyOtherAlgorithms"
          Effect    = "Deny"
          Principal = "*"
          Action    = local.algorithm_actions[local.key_kind[k]].actions
          Resource  = "*"
          Condition = { StringNotEquals = { (local.algorithm_actions[local.key_kind[k]].key) = v.allowed_algorithms } }
        }] : s if length(v.allowed_algorithms) > 0 ? local.algorithm_actions[local.key_kind[k]].key != "" : false],
        [for s in [merge(
          { Sid = "DenyKeyMaterialDeletion", Effect = "Deny", Principal = "*", Action = "kms:DeleteImportedKeyMaterial", Resource = "*" },
          length(local.break_glass) > 0 ? { Condition = { ArnNotLike = { "aws:PrincipalArn" = local.break_glass } } } : {},
        )] : s if v.external ? var.guardrails.protect_key_material : false],
        [for s in [{
          Sid       = "ReplicaDeployers"
          Effect    = "Allow"
          Principal = { AWS = var.replica_deployers }
          Action    = which == "primary" ? ["kms:DescribeKey", "kms:ReplicateKey"] : local.owner_actions[k]
          Resource  = "*"
        }] : s if v.replicate ? length(var.replica_deployers) > 0 : false],
      )
    }
  }

  # -------------------------------------------------------------------------
  # Documents
  #
  # bootstrap: what the key is created with - everything known before any
  # consumer exists. final: bootstrap plus the consumer contracts, owned by
  # aws_kms_key_policy.
  # -------------------------------------------------------------------------

  bootstrap_statements = {
    for k, v in local.keys : k => {
      for which in keys(local.regions) : which => concat(
        local.role_statements[k], local.key_region_statements[k][which], local.preset_statements[k][which], local.extra_statements[k], local.guardrail_statements[which],
      )
    }
  }

  final_statements = {
    for k, v in local.keys : k => {
      for which in keys(local.regions) : which => concat(
        local.role_statements[k], local.key_region_statements[k][which], local.preset_statements[k][which], local.contract_statements[k][which],
        local.extra_statements[k], local.guardrail_statements[which],
      )
    }
  }

  bootstrap_policy = {
    for k, v in local.keys : k => {
      for which in keys(local.regions) : which => jsonencode({ Version = "2012-10-17", Id = "${var.name}-${k}", Statement = local.bootstrap_statements[k][which] })
    }
  }

  final_policy = {
    for k, v in local.keys : k => {
      for which in keys(local.regions) : which => jsonencode({ Version = "2012-10-17", Id = "${var.name}-${k}", Statement = local.final_statements[k][which] })
    }
  }

  # Sid is optional; only repeated non-empty ones are a problem. Both regions:
  # the replica's policy carries its own consumer statements.
  duplicate_sids = {
    for k, v in local.keys : k => distinct(flatten([
      for which in keys(local.regions) : [
        for sid in distinct(compact([for s in local.final_statements[k][which] : try(s.Sid, "")])) : sid
        if length([for s in local.final_statements[k][which] : 1 if try(s.Sid, "") == sid]) > 1
      ]
    ]))
  }

  # The algorithm condition key and the operations it governs, per key kind.
  algorithm_actions = {
    symmetric          = { key = "", actions = [] }
    asymmetric_encrypt = { key = "kms:EncryptionAlgorithm", actions = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*"] }
    sign               = { key = "kms:SigningAlgorithm", actions = ["kms:Sign", "kms:Verify"] }
    mac                = { key = "kms:MacAlgorithm", actions = ["kms:GenerateMac", "kms:VerifyMac"] }
    agreement          = { key = "", actions = [] }
  }

  # What CreateGrant accepts per key kind.
  grant_operations_by_kind = {
    symmetric          = ["Decrypt", "Encrypt", "GenerateDataKey", "GenerateDataKeyWithoutPlaintext", "GenerateDataKeyPair", "GenerateDataKeyPairWithoutPlaintext", "ReEncryptFrom", "ReEncryptTo", "CreateGrant", "RetireGrant", "DescribeKey"]
    asymmetric_encrypt = ["Encrypt", "Decrypt", "ReEncryptFrom", "ReEncryptTo", "GetPublicKey", "CreateGrant", "RetireGrant", "DescribeKey"]
    sign               = ["Sign", "Verify", "GetPublicKey", "CreateGrant", "RetireGrant", "DescribeKey"]
    mac                = ["GenerateMac", "VerifyMac", "CreateGrant", "RetireGrant", "DescribeKey"]
    agreement          = ["DeriveSharedSecret", "GetPublicKey", "CreateGrant", "RetireGrant", "DescribeKey"]
  }

  # KMS accepts tab, newline, carriage return and U+0020 to U+00FF.
  policy_charset_re = "^[\\t\\n\\r\\x{20}-\\x{FF}]*$"
}
