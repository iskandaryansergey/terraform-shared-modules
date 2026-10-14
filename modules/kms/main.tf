resource "aws_kms_key" "this" {
  for_each = local.create ? { for k, v in local.keys : k => v if !v.external } : {}

  description              = each.value.description
  key_usage                = each.value.usage
  customer_master_key_spec = each.value.spec
  multi_region             = each.value.multi_region
  is_enabled               = each.value.enabled
  custom_key_store_id      = each.value.custom_key_store_id != "" ? each.value.custom_key_store_id : null
  xks_key_id               = each.value.xks_key_id != "" ? each.value.xks_key_id : null

  enable_key_rotation     = local.rotates[each.key]
  rotation_period_in_days = local.rotates[each.key] ? each.value.rotation_period_days : null
  deletion_window_in_days = each.value.deletion_window_days

  policy                             = local.bootstrap_policy[each.key].primary
  bypass_policy_lockout_safety_check = false

  tags = local.key_tags[each.key]

  lifecycle {
    # aws_kms_key_policy owns the live policy; this one only bootstraps.
    ignore_changes = [policy]

    precondition {
      condition     = contains(lookup(local.valid_usages, each.value.spec, []), each.value.usage)
      error_message = "key ${each.key}: spec ${each.value.spec} does not combine with usage ${each.value.usage}. SYMMETRIC_DEFAULT -> ENCRYPT_DECRYPT; HMAC_* -> GENERATE_VERIFY_MAC; RSA_* -> ENCRYPT_DECRYPT or SIGN_VERIFY; ECC_NIST_* -> SIGN_VERIFY or KEY_AGREEMENT; ECC_SECG_P256K1 -> SIGN_VERIFY; SM2 -> any. The provider does not check this; KMS refuses it at apply."
    }

    precondition {
      condition = alltrue([
        for s in each.value.services : contains(keys(local.preset_spec), s)
        ? (each.value.spec == local.preset_spec[s].spec && each.value.usage == local.preset_spec[s].usage)
        : each.value.spec == "SYMMETRIC_DEFAULT"
      ])
      error_message = "key ${each.key}: its services need a different key kind. route53-dnssec needs ECC_NIST_P256 with SIGN_VERIFY; every other preset needs SYMMETRIC_DEFAULT, the only kind AWS services encrypt with."
    }

    precondition {
      condition     = contains(each.value.services, "route53-dnssec") ? local.region == "us-east-1" : true
      error_message = "key ${each.key}: Route 53 DNSSEC uses key-signing keys in us-east-1 only; this provider is in ${local.region}."
    }

    precondition {
      condition     = each.value.custom_store ? (each.value.spec == "SYMMETRIC_DEFAULT" && !each.value.replicate) : true
      error_message = "key ${each.key}: a key in a custom key store must be SYMMETRIC_DEFAULT and cannot replicate."
    }

    # Named, not detected: the detected role is the plan's, and HCP Terraform
    # may apply as another role, which these settings would lock out.
    precondition {
      condition     = var.iam_delegation ? true : length(var.deployers) > 0
      error_message = "iam_delegation = false needs deployers named: without the account delegation only principals named in the key policy can change it, and KMS refuses a policy that locks out the principal applying it. A detected deployer is the plan's role; HCP Terraform can apply as another one."
    }

    precondition {
      condition     = (var.guardrails.protect_policy || var.guardrails.protect_aliases_and_rotation || var.guardrails.protect_tags) ? length(var.deployers) > 0 : true
      error_message = "guardrails.protect_policy, protect_aliases_and_rotation and protect_tags deny everyone except deployers and break_glass, so they need deployers named - the detected one is the plan's role, and an apply as another role would be locked out. List every role that applies (both, with separate plan and apply roles)."
    }

    precondition {
      condition     = (var.guardrails.max_rotation_period_days > 0 ? local.rotates[each.key] : false) ? each.value.rotation_period_days <= var.guardrails.max_rotation_period_days : true
      error_message = "key ${each.key} rotates every ${each.value.rotation_period_days} days, but guardrails.max_rotation_period_days denies more than ${var.guardrails.max_rotation_period_days}: the apply would deny itself."
    }

    precondition {
      condition     = length(local.key_tags[each.key]) <= 50
      error_message = "key ${each.key} would carry ${length(local.key_tags[each.key])} tags, including the module's 4; KMS allows 50."
    }

    precondition {
      condition     = alltrue([for t in var.required_tag_keys : try(local.key_tags[each.key][t], "") != ""])
      error_message = "key ${each.key} is missing required tags: ${join(", ", [for t in var.required_tag_keys : t if try(local.key_tags[each.key][t], "") == ""])}."
    }

    precondition {
      condition     = each.value.replicate ? (var.replica_region != "" && var.replica_region != local.region) : true
      error_message = "key ${each.key} replicates, but replica_region is ${var.replica_region == "" ? "empty" : "this key's own region, ${local.region}"}. Set replica_region to the disaster-recovery region, and create the replicas there with modules/replica."
    }

    precondition {
      condition     = length(local.bootstrap_policy[each.key].primary) <= 32768
      error_message = "the bootstrap policy for key ${each.key} is ${length(local.bootstrap_policy[each.key].primary)} characters; KMS allows 32768."
    }
  }
}

# Imported key material (origin = EXTERNAL). Created pending import: the
# custodians import the material out of band, so it never reaches state.
resource "aws_kms_external_key" "this" {
  for_each = local.create ? { for k, v in local.keys : k => v if v.external } : {}

  description             = each.value.description
  multi_region            = each.value.multi_region
  deletion_window_in_days = each.value.deletion_window_days
  # Computed: a key pending import cannot be enabled. Only an explicit
  # enabled = false is sent.
  enabled = each.value.enabled ? null : false

  policy                             = local.bootstrap_policy[each.key].primary
  bypass_policy_lockout_safety_check = false

  tags = local.key_tags[each.key]

  lifecycle {
    # The policy belongs to aws_kms_key_policy; valid_to is set by the
    # out-of-band import, and sending it back would re-import nothing.
    ignore_changes = [policy, valid_to]

    precondition {
      condition     = each.value.replicate ? (var.replica_region != "" && var.replica_region != local.region) : true
      error_message = "key ${each.key} replicates, but replica_region is ${var.replica_region == "" ? "empty" : "this key's own region, ${local.region}"}. Set replica_region to the disaster-recovery region, and create the replicas there with modules/replica."
    }

    precondition {
      condition     = var.iam_delegation ? true : length(var.deployers) > 0
      error_message = "iam_delegation = false needs deployers named: a detected deployer is the plan's role; HCP Terraform can apply as another one."
    }

    precondition {
      condition     = (var.guardrails.protect_policy || var.guardrails.protect_aliases_and_rotation || var.guardrails.protect_tags) ? length(var.deployers) > 0 : true
      error_message = "guardrails.protect_policy, protect_aliases_and_rotation and protect_tags need deployers named."
    }

    precondition {
      condition     = length(local.key_tags[each.key]) <= 50
      error_message = "key ${each.key} would carry ${length(local.key_tags[each.key])} tags, including the module's; KMS allows 50."
    }

    precondition {
      condition     = alltrue([for t in var.required_tag_keys : try(local.key_tags[each.key][t], "") != ""])
      error_message = "key ${each.key} is missing required tags: ${join(", ", [for t in var.required_tag_keys : t if try(local.key_tags[each.key][t], "") == ""])}."
    }

    precondition {
      condition     = length(local.bootstrap_policy[each.key].primary) <= 32768
      error_message = "the bootstrap policy for key ${each.key} is ${length(local.bootstrap_policy[each.key].primary)} characters; KMS allows 32768."
    }
  }
}

resource "aws_kms_key_policy" "this" {
  for_each = local.create ? local.keys : {}

  # The key ID, not the ARN: the provider reads the ID back, and an ARN here
  # shows as a change on every plan.
  key_id                             = local.key_id[each.key]
  policy                             = local.final_policy[each.key].primary
  bypass_policy_lockout_safety_check = false

  lifecycle {
    precondition {
      condition     = length(local.duplicate_sids[each.key]) == 0
      error_message = "the policy for key ${each.key} repeats these statement Sids: ${join(", ", local.duplicate_sids[each.key])}. Rename the extra_statements or consumers that collide."
    }

    precondition {
      condition     = length(local.final_policy[each.key].primary) <= 32768
      error_message = "the policy for key ${each.key} is ${length(local.final_policy[each.key].primary)} characters with its consumer contracts; KMS allows 32768. Split the consumers across keys, or move statements into IAM policies."
    }

    precondition {
      condition     = local.keys[each.key].replicate ? length(local.final_policy[each.key].replica) <= 32768 : true
      error_message = "the replica policy for key ${each.key} is ${length(local.final_policy[each.key].replica)} characters; KMS allows 32768."
    }

    precondition {
      condition     = can(regex(local.policy_charset_re, local.final_policy[each.key].primary))
      error_message = "the policy for key ${each.key} contains a character KMS rejects (it accepts tab, newline, carriage return and U+0020-U+00FF)."
    }
  }
}

resource "aws_kms_alias" "this" {
  for_each = local.create ? local.aliases : {}

  lifecycle {
    # A generation's alias <name>-<key>-<generation> could repeat another
    # key's; the map would silently keep one of them.
    precondition {
      condition     = length(flatten([for k, v in local.keys : v.aliases])) == length(local.aliases)
      error_message = "these aliases are used by more than one key, generations included: ${join(", ", [for a in distinct(flatten([for k, v in local.keys : v.aliases])) : a if length([for k, v in local.keys : 1 if contains(v.aliases, a)]) > 1])}."
    }
  }

  name = each.value.name
  # Through the policy resource, so on destroy the alias goes before the
  # policy is reset to the provider default, while the deployer still holds
  # DeleteAlias in the key policy.
  target_key_id = aws_kms_key_policy.this[each.value.key].key_id
}

# Refused consumer requirements stop the plan here, before any key exists.
# Not on the key itself: consumers take the key ARNs, so the key cannot
# depend on their requirements. Nothing depends on this resource either; a
# requirement unknown until apply (an ARN of a role created in the same run)
# is checked at apply, in parallel with the keys.
resource "terraform_data" "contract_refusals" {
  count = local.create ? 1 : 0

  lifecycle {
    precondition {
      condition     = length([for r in local.classified_full : r if r.rejected]) == 0
      error_message = "these consumer requirements are refused - a principal that is not an IAM ARN (\"*\" makes a key public), an action that is not a plain kms: action, or one covering a management action no consumer needs (kms:Put*, kms:putkeypolicy...): ${join("; ", [for r in local.classified_full : r.label if r.rejected])}."
    }
  }
}
