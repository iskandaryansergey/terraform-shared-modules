output "keys" {
  description = "Every key in the set, by name (a key with generations appears once per generation, <key>-<generation>): { arn, id, aliases (alias/...), alias_arns, kind (symmetric, mac, sign, agreement, asymmetric_encrypt), spec, usage, origin (AWS_KMS, EXTERNAL), generation, active, multi_region, replica_arn (null without a replica), replica_alias_arns }. Pass arn to resources and to producing modules; producing modules hand it back in their requirements, which is how a requirement finds its key."
  value = !local.create ? {} : {
    for k, v in local.keys : k => {
      arn                = local.key_arn[k]
      id                 = local.key_id[k]
      aliases            = [for a in v.aliases : "alias/${a}"]
      alias_arns         = [for a in v.aliases : "arn:${local.partition}:kms:${local.region}:${local.account_id}:alias/${a}"]
      kind               = local.key_kind[k]
      spec               = v.spec
      usage              = v.usage
      origin             = v.origin
      generation         = v.generation
      active             = v.active
      multi_region       = v.multi_region
      replica_arn        = v.replicate ? local.replica_arns[k] : null
      replica_alias_arns = v.replicate ? [for a in v.aliases : "arn:${local.partition}:kms:${local.replica_region}:${local.account_id}:alias/${a}"] : []
    }
  }
}

output "key_arns" {
  description = "Key ARN by key name - the shape most resources and modules take. A key with generations is listed under its own name (the active generation) and under each <key>-<generation>."
  value       = !local.create ? {} : merge(local.key_arn, { for b, k in local.active_key : b => local.key_arn[k] })
}

output "key_ids" {
  description = "Key ID by key name; a key with generations also under its own name (the active generation)."
  value       = !local.create ? {} : merge(local.key_id, { for b, k in local.active_key : b => local.key_id[k] })
}

output "alias_arns" {
  description = "The first alias ARN of each key, by key name (a key with generations also under its own name: the active generation's). Known at plan, so a consumer can be wired before the key exists."
  value = !local.create ? {} : merge(
    { for k, v in local.keys : k => "arn:${local.partition}:kms:${local.region}:${local.account_id}:alias/${v.aliases[0]}" },
    { for b, k in local.active_key : b => "arn:${local.partition}:kms:${local.region}:${local.account_id}:alias/${local.keys[k].aliases[0]}" },
  )
}

output "generations" {
  description = "Keys with generations: { active = the active key's name, arn = its ARN, keys = every generation's name, oldest first }. Rotate a generation by appending one to keys[*].generations; the aliases and grants move to it, and the old key stays for decrypting and verifying until you remove it."
  value = !local.create ? {} : {
    for b, k in local.active_key : b => {
      active = k
      arn    = local.key_arn[k]
      keys   = [for n, v in local.keys : n if v.base == b]
    } if local.keys[k].generation != ""
  }
}

output "public_keys" {
  description = "PEM public key of each asymmetric key (signing, key agreement, asymmetric encryption), for verifiers outside AWS - a JWKS endpoint, a code-signing check."
  value       = !local.create ? {} : { for k, pk in data.aws_kms_public_key.this : k => pk.public_key_pem }
}

output "policies" {
  description = "The compiled policy of each key, as JSON, by key name: { primary, replica (null without a replica) } - what a reviewer reads to see who can do what. A new key's policy is known after apply on its first plan; later plans show the diff."
  value = !local.create ? {} : {
    for k, v in local.keys : k => {
      primary = local.final_policy[k].primary
      replica = v.replicate ? local.final_policy[k].replica : null
    }
  }
}

output "coverage" {
  description = <<-EOT
    What happened to each consumer requirement. matched: compiled into a key
    policy, per key and region. unmatched: names a key outside this set.
    unaddressed: its key field is prose, not a key identifier. unresolved_roles:
    symbolic roles with no ARNs in principal_roles. without_principals: names
    nobody. not_machine_readable: prose-only. malformed: a condition without
    values or repeated. not_applicable: no key (a producer feature that is
    off). unreadable_consumers: not a list of requirements.
  EOT
  value = !local.create ? null : {
    matched = {
      for k, v in local.keys : k => {
        for which, reqs in local.requirements_by_key[k] : which => [for r in reqs : "${r.label}${r.purpose != "" ? ": ${r.purpose}" : ""}"]
      }
    }
    unmatched            = local.unmatched_requirements
    unaddressed          = local.unaddressed_requirements
    unresolved_roles     = local.unresolved_roles
    without_principals   = local.without_principals
    not_machine_readable = local.not_machine_readable
    malformed            = local.malformed
    not_applicable       = local.not_applicable
    unreadable_consumers = local.unreadable_consumers
  }
}

output "governance" {
  description = "The effective posture of the key set, for a change review: iam_delegation, deployers and deployers_source (named, detected, none), administrators_can_change_policy, guardrails (every setting, plus survives_terraform_destroy = false), per key (kind, purpose, rotation, deletion window, enabled, custom key store, service access, services, via_services, accounts, every role, required encryption context, consumers, grants, extra statement count, replica region, policy size) and acknowledged_checks."
  value = !local.create ? null : {
    iam_delegation                   = var.iam_delegation
    deployers                        = local.deployers
    deployers_source                 = local.deployers_source
    administrators_can_change_policy = var.administrators_can_change_policy
    guardrails = {
      organization_id                 = var.guardrails.organization_id
      trusted_accounts                = var.guardrails.trusted_accounts
      vpc_endpoint_ids                = var.guardrails.vpc_endpoint_ids
      replica_vpc_endpoint_ids        = var.guardrails.replica_vpc_endpoint_ids
      deletion_protection             = var.guardrails.deletion_protection
      min_deletion_window_days        = var.guardrails.min_deletion_window_days
      min_days_unused_before_deletion = var.guardrails.min_days_unused_before_deletion
      replica_deployers               = var.replica_deployers
      max_rotation_period_days        = var.guardrails.max_rotation_period_days
      protect_key_material            = var.guardrails.protect_key_material
      protect_tags                    = var.guardrails.protect_tags
      break_glass_requires_mfa        = var.guardrails.break_glass_requires_mfa
      protect_policy                  = var.guardrails.protect_policy
      protect_aliases_and_rotation    = var.guardrails.protect_aliases_and_rotation
      break_glass                     = local.break_glass
      survives_terraform_destroy      = false
    }
    keys = {
      for k, v in local.keys : k => {
        kind                       = local.key_kind[k]
        purpose                    = v.purpose
        rotation                   = local.rotates[k] ? "every ${v.rotation_period_days} days" : (local.key_kind[k] != "symmetric" ? "not supported for ${v.spec}" : (v.custom_store ? "not supported in a custom key store" : (v.external ? "not supported for imported key material" : "off")))
        deletion_window_days       = v.deletion_window_days
        enabled                    = v.enabled
        custom_key_store_id        = v.custom_key_store_id
        service_access             = v.service_access
        services                   = v.services
        via_services               = local.via_values[k].primary
        accounts                   = v.accounts
        administrators             = v.administrators
        users                      = v.users
        auditors                   = v.auditors
        encrypters                 = v.encrypters
        decrypters                 = v.decrypters
        grant_users                = v.grant_users
        require_encryption_context = v.require_encryption_context
        encryption_context_values  = v.encryption_context_values
        allowed_algorithms         = v.allowed_algorithms
        origin                     = v.origin
        key_custodians             = v.key_custodians
        generation                 = v.generation
        active                     = v.active
        consumers                  = distinct([for r in concat(local.requirements_by_key[k].primary, local.requirements_by_key[k].replica) : r.consumer])
        grants                     = keys(v.grants)
        extra_statements           = length(local.extra_statements[k])
        replica_region             = v.replicate ? local.replica_region : null
        policy_characters          = local.policy_sizes[k]
      }
    }
    acknowledged_checks = sort(var.acknowledged_checks)
  }
}

output "iam_policy_statements" {
  description = "The IAM half of each role, per key: { user, encrypter, decrypter, auditor, through_services (null without caller-path services), abac (any key of this set tagged with this key's name, so the policy survives a new generation) }, the statement a principal's own IAM policy needs when the key policy grants its account rather than the principal (iam_delegation, or keys[*].accounts for another account). Attach the one matching the principal's job."
  value = !local.create ? {} : {
    for k, v in local.keys : k => {
      user      = { Effect = "Allow", Action = concat(local.crypto_actions_by_kind[local.key_kind[k]].all, local.describe_actions[k]), Resource = local.key_arn[k] }
      encrypter = { Effect = "Allow", Action = concat(local.crypto_actions_by_kind[local.key_kind[k]].produce, local.describe_actions[k]), Resource = local.key_arn[k] }
      decrypter = { Effect = "Allow", Action = concat(local.crypto_actions_by_kind[local.key_kind[k]].consume, local.describe_actions[k]), Resource = local.key_arn[k] }
      auditor   = { Effect = "Allow", Action = local.audit_actions[k], Resource = local.key_arn[k] }
      through_services = length(local.via_values[k].primary) == 0 ? null : {
        Effect    = "Allow"
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
        Resource  = local.key_arn[k]
        Condition = { StringLike = { "kms:ViaService" = local.via_values[k].primary } }
      }
      # Attribute-based: any key of this set carrying this key's tags, so a
      # new generation needs no IAM change.
      abac = {
        Effect    = "Allow"
        Action    = concat(local.crypto_actions_by_kind[local.key_kind[k]].all, local.describe_actions[k])
        Resource  = "arn:${local.partition}:kms:*:${local.account_id}:key/*"
        Condition = { StringEquals = { "aws:ResourceTag/KeySet" = var.name, "aws:ResourceTag/Key" = k } }
      }
    }
  }
}

output "service_presets" {
  description = "Every service preset and what it compiles to in this key set's region: the statements of service-principal presets, the kms:ViaService names of caller-path ones, and the key kind each needs."
  value = {
    service_principal = local.preset_library.primary
    caller_path       = { for s, fs in local.via_service : s => [for f in fs : strcontains(f, "%s") ? format(f, local.region) : f] }
    key_kind          = merge({ for s in keys(local.via_service) : s => "SYMMETRIC_DEFAULT ENCRYPT_DECRYPT" }, { for s in keys(local.preset_library.primary) : s => try("${local.preset_spec[s].spec} ${local.preset_spec[s].usage}", "SYMMETRIC_DEFAULT ENCRYPT_DECRYPT") })
  }
}

output "organization_policy_snippets" {
  description = "Statements for the organization's management pipeline; this module applies none of them. scp: refuse lockout bypass anywhere, and keep these keys' deletion, disabling and policy changes to the deployers and break-glass. rcp: the organization perimeter for every key, so it need not live in each key policy (RCPs do not cover the management account, service-linked roles or AWS managed keys)."
  value = !local.create ? null : {
    scp = concat(
      [{
        Sid       = "DenyKmsLockoutBypass"
        Effect    = "Deny"
        Action    = ["kms:CreateKey", "kms:PutKeyPolicy"]
        Resource  = "*"
        Condition = { Bool = { "kms:BypassPolicyLockoutSafetyCheck" = "true" } }
      }],
      [for s in [{
        Sid       = "Protect${replace(title(replace(var.name, "-", " ")), " ", "")}Keys"
        Effect    = "Deny"
        Action    = ["kms:ScheduleKeyDeletion", "kms:DisableKey", "kms:PutKeyPolicy", "kms:ReplicateKey", "kms:UpdatePrimaryRegion"]
        Resource  = [for k in sort(keys(local.key_arn)) : local.key_arn[k]]
        Condition = { ArnNotLike = { "aws:PrincipalArn" = local.exempt } }
      }] : s if length(local.exempt) > 0],
    )
    rcp = [for s in [{
      Sid       = "EnforceOrgIdentitiesOnKms"
      Effect    = "Deny"
      Principal = "*"
      Action    = "kms:*"
      Resource  = "*"
      Condition = {
        StringNotEqualsIfExists = merge(
          { "aws:PrincipalOrgID" = var.guardrails.organization_id },
          length(var.guardrails.trusted_accounts) > 0 ? { "aws:PrincipalAccount" = var.guardrails.trusted_accounts } : {},
        )
        BoolIfExists = { "aws:PrincipalIsAWSService" = "false" }
      }
    }] : s if var.guardrails.organization_id != ""]
  }
}

output "compliance_snippets" {
  description = "Detective controls for the platform team, scoped to this set where the control allows; this module creates none of them. config_rules: AWS Config managed rules (name, source_identifier, input_parameters as JSON, the Security Hub control each backs). metric_filters: CloudWatch Logs filter patterns for the CloudTrail log group, each with the control it satisfies; pair each with an alarm."
  value = !local.create ? null : {
    config_rules = concat(
      [
        {
          name              = "${var.name}-kms-keys-not-scheduled-for-deletion"
          source_identifier = "KMS_CMK_NOT_SCHEDULED_FOR_DELETION"
          input_parameters  = jsonencode({ kmsKeyIds = join(",", [for k in sort(keys(local.key_id)) : local.key_id[k]]) })
          control           = "Security Hub KMS.3"
        },
        {
          name              = "${var.name}-kms-key-rotation-enabled"
          source_identifier = "CMK_BACKING_KEY_ROTATION_ENABLED"
          input_parameters  = "{}"
          control           = "Security Hub KMS.4 (account-wide: the rule takes no key list; imported, asymmetric and custom-store keys cannot comply)"
        },
      ],
      [for s in [{
        name              = "${var.name}-kms-keys-tagged"
        source_identifier = "REQUIRED_TAGS"
        input_parameters  = jsonencode({ for i, t in slice(var.required_tag_keys, 0, min(6, length(var.required_tag_keys))) : "tag${i + 1}Key" => t })
        control           = "required_tag_keys (scope the rule to AWS::KMS::Key; REQUIRED_TAGS takes six keys at most)"
      }] : s if length(var.required_tag_keys) > 0],
    )
    metric_filters = {
      key_disabled_or_scheduled_for_deletion = {
        pattern = "{ ($.eventSource = kms.amazonaws.com) && (($.eventName = DisableKey) || ($.eventName = ScheduleKeyDeletion)) }"
        control = "CIS AWS Foundations (v1.4+ 4.7), Security Hub CloudWatch.7"
      }
      key_used_while_pending_deletion = {
        pattern = "{ ($.eventSource = kms.amazonaws.com) && ($.errorCode = \"KMSInvalidStateException\") && ($.errorMessage = \"*pending deletion*\") }"
        control = "AWS KMS guide: alarm on use of a key pending deletion, before it is gone"
      }
    }
  }
}

output "cost" {
  description = "Monthly KMS storage cost of the set at list price ($1 per key and per replica, plus $1 for each of a key's first two rotations; requests are extra at $0.03 per 10,000 symmetric calls after 20,000 free). The upper bound is reached once every rotating key has rotated twice. AWS Price List, 2026-09-11; verify before quoting."
  value = !local.create ? null : {
    keys                        = length(local.keys)
    replicas                    = length(local.replicated_keys)
    monthly_usd_before_rotation = length(local.keys) + length(local.replicated_keys)
    monthly_usd_upper_bound     = sum(concat([0], [for k, v in local.keys : (local.rotates[k] ? 3 : 1) * (v.replicate ? 2 : 1)]))
    rotation_billing_capped     = "each rotating key (and replica) adds $1/month at its first and second rotation; later rotations are free"
    pending_deletion_charges    = "none: a key scheduled for deletion is not billed"
  }
}

output "verify_commands" {
  description = "Read-only checks to run from CloudShell after an apply, per key: policy, rotation status, rotation history (audit evidence of past rotations), state, aliases, grants, an IAM Access Analyzer public-access check of the live policy, and the replica's policy and state."
  value = !local.create ? {} : {
    for k, id in local.key_id : k => merge(
      {
        policy    = "aws kms get-key-policy --region ${local.region} --key-id ${id} --policy-name default --query Policy --output text"
        rotation  = "aws kms get-key-rotation-status --region ${local.region} --key-id ${id}"
        rotations = "aws kms list-key-rotations --region ${local.region} --key-id ${id} --output table"
        public    = "aws accessanalyzer check-no-public-access --region ${local.region} --resource-type AWS::KMS::Key --policy-document \"$(aws kms get-key-policy --region ${local.region} --key-id ${id} --policy-name default --query Policy --output text)\""
        state     = "aws kms describe-key --region ${local.region} --key-id ${id} --query 'KeyMetadata.[KeyState,KeySpec,KeyUsage,MultiRegion,DeletionDate]' --output table"
        aliases   = "aws kms list-aliases --region ${local.region} --key-id ${id} --query 'Aliases[].AliasName' --output text"
        grants    = "aws kms list-grants --region ${local.region} --key-id ${id} --query 'Grants[].[Name,GranteePrincipal,Operations]' --output table"
      },
      local.keys[k].replicate ? {
        replica_policy = "aws kms get-key-policy --region ${local.replica_region} --key-id ${id} --policy-name default --query Policy --output text"
        replica_state  = "aws kms describe-key --region ${local.replica_region} --key-id ${id} --query 'KeyMetadata.[KeyState,MultiRegionConfiguration.MultiRegionKeyType]' --output table"
      } : {},
    )
  }
}

output "sns_topic_policy_requirement" {
  description = "The statement the notification topic's access policy must contain for the EventBridge rules to publish. Null without notifications. An SSE-KMS topic's key also needs the eventbridge-to-sns preset. modules/replica emits its own for the replica region's topic."
  value = !local.create || length(aws_cloudwatch_event_rule.native) + length(aws_cloudwatch_event_rule.cloudtrail) == 0 ? null : {
    Sid       = "AllowKmsKeyEvents${replace(title(replace(var.name, "-", " ")), " ", "")}"
    Effect    = "Allow"
    Principal = { Service = "events.amazonaws.com" }
    Action    = "sns:Publish"
    Resource  = var.notifications.sns_topic_arn
    Condition = { ArnEquals = { "aws:SourceArn" = concat(aws_cloudwatch_event_rule.native[*].arn, aws_cloudwatch_event_rule.cloudtrail[*].arn) } }
  }
}

output "replicas" {
  description = "Everything modules/replica needs to create this set's replicas in replica_region: per key the primary ARN, the replica's compiled policy, aliases, tags and deletion window, and the notification patterns. Pass it whole: replicas = module.kms.replicas (or through tfe_outputs from a disaster-recovery workspace). Null when no key replicates."
  value       = local.replica_blueprint
}

output "contract_schema" {
  description = "The requirement shape this module compiles, for producing modules to emit as kms_key_policy_requirements. Version 2."
  value = {
    version = 2
    fields = {
      key        = "string: the key ARN, key ID or alias ARN the producer was given (either region)"
      sid        = "string: stable within the producer, letters and digits"
      principals = "object: services (service principals), arns (IAM ARNs, never \"*\"), roles (symbolic names resolved through principal_roles; \"deployer\" is built in)"
      actions    = "list(string): kms: actions a consumer uses - never kms:* or a management action"
      conditions = "list(object({ test, variable, values })): IAM condition operator, key, non-empty values; each test and key once"
      purpose    = "string: one line, why"
    }
  }
}
