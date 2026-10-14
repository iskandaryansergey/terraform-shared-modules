# Regulated-workload features: imported key material (BYOK), key generations
# for kinds that cannot rotate, attribute-based access, algorithm limits, the
# stricter guardrails, and the compliance snippets.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { name = "eu-west-2" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333", arn = "arn:aws:sts::111122223333:assumed-role/hcp-terraform/run-1" }
  }
  mock_data "aws_iam_session_context" {
    defaults = { issuer_arn = "arn:aws:iam::111122223333:role/hcp-terraform" }
  }
  mock_data "aws_kms_public_key" {
    defaults = { public_key_pem = "-----BEGIN PUBLIC KEY-----\nMOCK\n-----END PUBLIC KEY-----" }
  }
}

override_resource {
  target = aws_kms_external_key.this["byok"]
  values = {
    arn = "arn:aws:kms:eu-west-2:111122223333:key/mrk-00000000000000000000000000000001"
    id  = "mrk-00000000000000000000000000000001"
  }
}

override_resource {
  target = aws_kms_key.this["sig-2025"]
  values = {
    arn    = "arn:aws:kms:eu-west-2:111122223333:key/22222222-aaaa-4bbb-8ccc-000000002025"
    key_id = "22222222-aaaa-4bbb-8ccc-000000002025"
  }
}

override_resource {
  target = aws_kms_key.this["sig-2026"]
  values = {
    arn    = "arn:aws:kms:eu-west-2:111122223333:key/22222222-aaaa-4bbb-8ccc-000000002026"
    key_id = "22222222-aaaa-4bbb-8ccc-000000002026"
  }
}

variables {
  replica_region = "eu-west-1"
  name           = "payments"
  deployers      = ["arn:aws:iam::111122223333:role/workspace"]
}

# ---------------------------------------------------------------------------
# Imported key material
# ---------------------------------------------------------------------------

run "imported_material_makes_an_external_key" {
  command = apply

  variables {
    key_custodians = ["arn:aws:iam::111122223333:role/hsm-ceremony"]
    keys           = { byok = { origin = "EXTERNAL", multi_region = true, replicate = true } }
    notifications  = { sns_topic_arn = "arn:aws:sns:eu-west-2:111122223333:alerts" }
    guardrails     = { protect_key_material = true, break_glass = ["arn:aws:iam::111122223333:role/break-glass"] }
  }

  assert {
    condition     = length(aws_kms_key.this) == 0 && length(aws_kms_external_key.this) == 1
    error_message = "origin = EXTERNAL is an aws_kms_external_key, not an aws_kms_key."
  }

  assert {
    condition     = nonsensitive(aws_kms_external_key.this["byok"].key_material_base64 == null)
    error_message = "the material is imported out of band, never through state."
  }

  assert {
    condition     = aws_kms_key_policy.this["byok"].key_id == "mrk-00000000000000000000000000000001" && output.key_arns["byok"] == "arn:aws:kms:eu-west-2:111122223333:key/mrk-00000000000000000000000000000001"
    error_message = "the policy, aliases and outputs follow the external key."
  }

  assert {
    condition     = one([for s in jsondecode(output.policies["byok"].primary).Statement : s.Condition.StringEquals["kms:WrappingAlgorithm"] if try(s.Sid, "") == "KeyCustodiansImportParameters"]) == ["RSAES_OAEP_SHA_256", "RSA_AES_KEY_WRAP_SHA_256"]
    error_message = "custodians get import parameters for SHA-256 wrapping only - never RSAES_OAEP_SHA_1."
  }

  assert {
    condition     = jsonencode(one([for s in jsondecode(output.policies["byok"].primary).Statement : s.Action if try(s.Sid, "") == "KeyCustodians"])) == jsonencode(["kms:DescribeKey", "kms:ImportKeyMaterial", "kms:DeleteImportedKeyMaterial"])
    error_message = "custodians import and delete material, and nothing else."
  }

  assert {
    condition     = one([for s in jsondecode(output.policies["byok"].primary).Statement : s.Condition.ArnNotLike["aws:PrincipalArn"] if try(s.Sid, "") == "DenyKeyMaterialDeletion"]) == ["arn:aws:iam::111122223333:role/break-glass"]
    error_message = "deleting imported material is immediate and unrecoverable: only break-glass may."
  }

  assert {
    condition     = output.governance.keys["byok"].rotation == "not supported for imported key material" && output.replicas.keys["byok"].origin == "EXTERNAL"
    error_message = "imported material does not rotate, and its replica is an imported-material replica too."
  }
}

run "a_disabled_imported_key_is_sent_disabled" {
  command = plan

  variables {
    keys          = { byok = { origin = "EXTERNAL", enabled = false } }
    notifications = { sns_topic_arn = "arn:aws:sns:eu-west-2:111122223333:alerts" }
  }

  assert {
    condition     = aws_kms_external_key.this["byok"].enabled == false
    error_message = "enabled is only sent when false: a key pending import cannot be enabled, so true is left to KMS."
  }
}

run "imported_material_without_an_expiry_alarm_warns" {
  command = plan

  variables {
    keys = { byok = { origin = "EXTERNAL" } }
  }

  expect_failures = [check.imported_material_expiry_is_watched]
}

run "imported_material_is_symmetric_on_this_provider" {
  command = plan

  variables {
    keys = { byok = { origin = "EXTERNAL", purpose = "signing" } }
  }

  expect_failures = [var.keys]
}

run "origin_is_validated" {
  command = plan

  variables {
    keys = { main = { origin = "AWS_CLOUDHSM" } }
  }

  expect_failures = [var.keys]
}

# ---------------------------------------------------------------------------
# Generations
# ---------------------------------------------------------------------------

run "generations_are_keys_and_the_last_is_active" {
  command = apply

  variables {
    keys = { sig = {
      purpose     = "signing"
      generations = ["2025", "2026"]
      grants      = { verifier = { grantee_principal = "arn:aws:iam::111122223333:role/verifier", operations = ["Verify"] } }
    } }
  }

  assert {
    condition     = jsonencode(sort(keys(aws_kms_key.this))) == jsonencode(["sig-2025", "sig-2026"])
    error_message = "each generation is its own key, <key>-<generation>."
  }

  assert {
    condition     = jsonencode(sort(keys(aws_kms_alias.this))) == jsonencode(["payments-sig", "payments-sig-2025", "payments-sig-2026"])
    error_message = "the key's alias is the active generation's; every generation also has its own."
  }

  assert {
    condition     = aws_kms_alias.this["payments-sig"].target_key_id == "22222222-aaaa-4bbb-8ccc-000000002026"
    error_message = "the key's alias points at the last generation."
  }

  assert {
    condition     = output.key_arns["sig"] == output.key_arns["sig-2026"]
    error_message = "key_arns[\"<key>\"] is the active generation, so consumers need no change when a generation is added."
  }

  assert {
    condition     = jsonencode(keys(aws_kms_grant.this)) == jsonencode(["sig-2026/verifier"])
    error_message = "grants move to the active generation."
  }

  assert {
    condition     = output.generations["sig"].active == "sig-2026" && jsonencode(output.generations["sig"].keys) == jsonencode(["sig-2025", "sig-2026"])
    error_message = "output.generations lists the generations, oldest first, and the active one."
  }

  assert {
    condition     = aws_kms_key.this["sig-2025"].tags["Generation"] == "2025" && aws_kms_key.this["sig-2025"].is_enabled
    error_message = "an earlier generation is tagged and stays enabled, to verify what it signed."
  }

  assert {
    condition     = length(keys(output.public_keys)) == 2
    error_message = "every generation of a signing key publishes its public key: verifiers need the old ones."
  }
}

run "a_generation_name_cannot_collide_with_a_key" {
  command = plan

  variables {
    keys = { sig = { purpose = "signing", generations = ["2025"] }, sig-2025 = { purpose = "signing" } }
  }

  expect_failures = [var.keys]
}

run "generation_names_are_validated" {
  command = plan

  variables {
    keys = { sig = { purpose = "signing", generations = ["2025", "2025"] } }
  }

  expect_failures = [var.keys]
}

# ---------------------------------------------------------------------------
# Attribute-based access and algorithms
# ---------------------------------------------------------------------------

run "context_values_isolate_tenants" {
  command = plan

  variables {
    keys = { data = {
      users                      = ["arn:aws:iam::111122223333:role/app"]
      require_encryption_context = ["tenant"]
      encryption_context_values  = { tenant = ["$${aws:PrincipalTag/tenant}"] }
    } }
  }

  assert {
    condition = one([for s in jsondecode(output.policies["data"].primary).Statement : s.Condition if try(s.Sid, "") == "Users"]) == {
      Null         = { "kms:EncryptionContext:tenant" = "false" }
      StringEquals = { "kms:EncryptionContext:tenant" = ["$${aws:PrincipalTag/tenant}"] }
    }
    error_message = "direct use must carry the tenant context, equal to the caller's own tenant tag."
  }

  assert {
    condition     = output.iam_policy_statements["data"].abac.Condition.StringEquals == { "aws:ResourceTag/KeySet" = "payments", "aws:ResourceTag/Key" = "data" }
    error_message = "the ABAC IAM statement grants by the module's tags, so it survives a new generation."
  }
}

run "algorithms_are_limited_by_key_kind" {
  command = plan

  variables {
    keys = {
      sig  = { purpose = "signing", allowed_algorithms = ["ECDSA_SHA_256"] }
      data = { allowed_algorithms = ["SYMMETRIC_DEFAULT"] }
    }
  }

  assert {
    condition = one([for s in jsondecode(output.policies["sig"].primary).Statement : s if try(s.Sid, "") == "DenyOtherAlgorithms"]) == {
      Sid       = "DenyOtherAlgorithms"
      Effect    = "Deny"
      Principal = "*"
      Action    = ["kms:Sign", "kms:Verify"]
      Resource  = "*"
      Condition = { StringNotEquals = { "kms:SigningAlgorithm" = ["ECDSA_SHA_256"] } }
    }
    error_message = "a signing key denies every other signing algorithm."
  }

  assert {
    condition     = !strcontains(output.policies["data"].primary, "DenyOtherAlgorithms")
    error_message = "a symmetric key has one algorithm: no statement."
  }
}

run "an_unknown_algorithm_is_refused" {
  command = plan

  variables {
    keys = { sig = { purpose = "signing", allowed_algorithms = ["ECDSA_SHA_1"] } }
  }

  expect_failures = [var.keys]
}

# ---------------------------------------------------------------------------
# Guardrails
# ---------------------------------------------------------------------------

run "the_stricter_guardrails" {
  command = plan

  variables {
    guardrails = {
      protect_tags             = true
      break_glass_requires_mfa = true
      max_rotation_period_days = 365
      break_glass              = ["arn:aws:iam::111122223333:role/break-glass"]
    }
  }

  assert {
    condition     = one([for s in jsondecode(output.policies["main"].primary).Statement : s.Condition.ArnNotLike["aws:PrincipalArn"] if try(s.Sid, "") == "DenyTagChanges"]) == ["arn:aws:iam::111122223333:role/workspace", "arn:aws:iam::111122223333:role/break-glass"]
    error_message = "tag changes are the owners' only: with ABAC, a tag is a grant."
  }

  assert {
    condition = one([for s in jsondecode(output.policies["main"].primary).Statement : s.Condition if try(s.Sid, "") == "DenyBreakGlassWithoutMfa"]) == {
      ArnLike      = { "aws:PrincipalArn" = ["arn:aws:iam::111122223333:role/break-glass"] }
      BoolIfExists = { "aws:MultiFactorAuthPresent" = "false" }
    }
    error_message = "break-glass does nothing without MFA."
  }

  assert {
    condition     = one([for s in jsondecode(output.policies["main"].primary).Statement : s.Condition if try(s.Sid, "") == "DenyLongerRotationPeriods"]) == { NumericGreaterThan = { "kms:RotationPeriodInDays" = "365" } }
    error_message = "nobody can stretch the cryptoperiod past the maximum."
  }
}

run "a_rotation_period_over_the_maximum_is_refused" {
  command = plan

  variables {
    keys       = { main = { rotation_period_days = 730 } }
    guardrails = { max_rotation_period_days = 365 }
  }

  expect_failures = [aws_kms_key.this]
}

run "tag_protection_needs_named_deployers" {
  command = plan

  variables {
    deployers  = []
    guardrails = { protect_tags = true }
  }

  expect_failures = [aws_kms_key.this]
}

run "an_administrator_who_uses_the_key_warns" {
  command = plan

  variables {
    administrators = ["arn:aws:iam::111122223333:role/key-admin"]
    users          = ["arn:aws:iam::111122223333:role/key-admin"]
  }

  expect_failures = [check.duties_are_separated]
}

# ---------------------------------------------------------------------------
# Compliance snippets
# ---------------------------------------------------------------------------

run "compliance_snippets_are_scoped_to_the_set" {
  command = apply

  variables {
    keys              = { sig = { purpose = "signing", generations = ["2025", "2026"] } }
    required_tag_keys = ["Owner"]
    tags              = { Owner = "payments" }
  }

  assert {
    condition     = jsondecode(output.compliance_snippets.config_rules[0].input_parameters).kmsKeyIds == "22222222-aaaa-4bbb-8ccc-000000002025,22222222-aaaa-4bbb-8ccc-000000002026"
    error_message = "the not-scheduled-for-deletion rule lists exactly this set's keys."
  }

  assert {
    condition     = output.compliance_snippets.config_rules[2].source_identifier == "REQUIRED_TAGS" && jsondecode(output.compliance_snippets.config_rules[2].input_parameters) == { tag1Key = "Owner" }
    error_message = "required_tag_keys become a REQUIRED_TAGS rule."
  }

  assert {
    condition     = strcontains(output.compliance_snippets.metric_filters.key_disabled_or_scheduled_for_deletion.pattern, "ScheduleKeyDeletion")
    error_message = "the CIS filter matches scheduled deletion and disabling."
  }
}

run "the_regulated_example_plans_clean" {
  command = plan

  variables {
    name           = "ledger"
    key_custodians = ["arn:aws:iam::111122223333:role/hsm-ceremony"]
    keys = {
      data = {
        origin                     = "EXTERNAL"
        purpose                    = "database"
        users                      = ["arn:aws:iam::111122223333:role/app"]
        require_encryption_context = ["tenant"]
        encryption_context_values  = { tenant = ["$${aws:PrincipalTag/tenant}"] }
      }
      statements = {
        purpose            = "signing"
        generations        = ["2025", "2026"]
        allowed_algorithms = ["ECDSA_SHA_256"]
        encrypters         = ["arn:aws:iam::111122223333:role/app"]
      }
    }
    guardrails = {
      organization_id                 = "o-abcdef1234"
      min_deletion_window_days        = 30
      min_days_unused_before_deletion = 90
      protect_policy                  = true
      protect_aliases_and_rotation    = true
      protect_tags                    = true
      protect_key_material            = true
      break_glass                     = ["arn:aws:iam::111122223333:role/break-glass"]
      break_glass_requires_mfa        = true
    }
    notifications = {
      sns_topic_arn = "arn:aws:sns:eu-west-2:111122223333:alerts"
      events        = ["deletion", "rotation", "import_expiry", "schedule_deletion", "disable", "policy_change"]
    }
    acknowledged_checks = ["cloudtrail_events_need_a_trail"]
    required_tag_keys   = ["DataClassification"]
    tags                = { DataClassification = "confidential" }
  }

  assert {
    condition     = length(aws_kms_external_key.this) == 1 && length(aws_kms_key.this) == 2
    error_message = "the regulated example is one imported key and two signing generations."
  }
}
