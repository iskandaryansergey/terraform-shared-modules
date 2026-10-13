resource "aws_kms_key" "this" {
  for_each = local.create ? local.keys : {}

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

    precondition {
      condition     = var.iam_delegation ? true : length(local.deployers) > 0
      error_message = "iam_delegation = false needs a deployer (named in deployers, or detected): without the account delegation only principals named in the key policy can change it, and KMS refuses a policy that locks out the principal applying it."
    }

    precondition {
      condition     = (var.guardrails.protect_policy || var.guardrails.protect_aliases_and_rotation) ? length(local.exempt) > 0 : true
      error_message = "guardrails.protect_policy and protect_aliases_and_rotation deny everyone except deployers and break_glass, and there are none: the next apply could not change the policy or the aliases."
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
  key_id                             = aws_kms_key.this[each.key].key_id
  policy                             = local.final_policy[each.key].primary
  bypass_policy_lockout_safety_check = false

  lifecycle {
    precondition {
      condition     = length([for r in local.classified : r if r.rejected]) == 0
      error_message = "these consumer requirements are refused - a principal that is not an IAM ARN (\"*\" makes a key public), an action that is not a plain kms: action, or a management action no consumer needs: ${join("; ", [for r in local.classified : r.label if r.rejected])}."
    }

    precondition {
      condition     = length(local.duplicate_sids[each.key]) == 0
      error_message = "the policy for key ${each.key} repeats these statement Sids: ${join(", ", local.duplicate_sids[each.key])}. Rename the extra_statements or consumers that collide."
    }

    precondition {
      condition     = length(local.final_policy[each.key].primary) <= 32768
      error_message = "the policy for key ${each.key} is ${length(local.final_policy[each.key].primary)} characters with its consumer contracts; KMS allows 32768. Split the consumers across keys, or move statements into IAM policies."
    }

    precondition {
      condition     = can(regex(local.policy_charset_re, local.final_policy[each.key].primary))
      error_message = "the policy for key ${each.key} contains a character KMS rejects (it accepts tab, newline, carriage return and U+0020-U+00FF)."
    }
  }
}

resource "aws_kms_alias" "this" {
  for_each = local.create ? local.aliases : {}

  name          = each.value.name
  target_key_id = aws_kms_key.this[each.value.key].key_id
}
