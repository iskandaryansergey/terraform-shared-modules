# Keys: the minimal call, profiles and defaults, tags, custom key stores, and
# every input validation and key-level precondition - one run per rule, each
# input breaking exactly that rule.

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

variables {
  replica_region = "eu-west-1"
  name           = "payments"
}

# ---------------------------------------------------------------------------
# The minimal call
# ---------------------------------------------------------------------------

run "the_minimal_call_is_one_rotating_key_with_no_warnings" {
  command = plan

  assert {
    condition     = keys(aws_kms_key.this) == ["main"]
    error_message = "with keys unset, the set is one key called main."
  }

  assert {
    condition     = aws_kms_key.this["main"].enable_key_rotation == true && aws_kms_key.this["main"].rotation_period_in_days == 365 && aws_kms_key.this["main"].deletion_window_in_days == 30
    error_message = "the default key rotates yearly and waits 30 days before deletion."
  }

  assert {
    condition     = aws_kms_alias.this["payments-main"].name == "alias/payments-main"
    error_message = "the default alias is alias/<name>-<key>."
  }

  assert {
    condition     = output.governance.deployers_source == "detected"
    error_message = "with deployers unset, the deployer is detected."
  }

  assert {
    condition     = jsonencode(output.governance.deployers) == jsonencode(["arn:aws:iam::111122223333:role/hcp-terraform"])
    error_message = "the detected deployer is the role running the plan, so terraform destroy is exempt from deletion protection."
  }
}

run "named_deployers_skip_detection" {
  command = plan

  variables {
    deployers = ["arn:aws:iam::111122223333:role/workspace"]
  }

  assert {
    condition     = length(data.aws_iam_session_context.deployer) == 0 && output.governance.deployers_source == "named"
    error_message = "named deployers must not trigger the iam:GetRole lookup."
  }
}

run "without_detection_nobody_is_exempt_and_the_check_says_so" {
  command = plan

  variables {
    detect_deployer = false
  }

  expect_failures = [check.deletion_protection_has_an_exemption]

  assert {
    condition     = output.governance.deployers_source == "none" && length(output.governance.deployers) == 0
    error_message = "detect_deployer = false with no deployers leaves no deployer."
  }
}

# ---------------------------------------------------------------------------
# Profiles and defaults
# ---------------------------------------------------------------------------

run "key_defaults_apply_and_a_key_overrides_them" {
  command = plan

  variables {
    key_defaults = { rotation_period_days = 180, service_access = "named" }
    keys = {
      a = {}
      b = { rotation_period_days = 400, service_access = "account" }
    }
  }

  assert {
    condition     = aws_kms_key.this["a"].rotation_period_in_days == 180 && aws_kms_key.this["b"].rotation_period_in_days == 400
    error_message = "a key without its own value takes key_defaults; its own value wins."
  }

  assert {
    condition     = output.governance.keys["a"].service_access == "named" && output.governance.keys["b"].service_access == "account"
    error_message = "service_access follows the same precedence."
  }
}

run "purpose_profiles_set_the_kind_and_the_services" {
  command = plan

  variables {
    keys = {
      logs = { purpose = "logs" }
      sig  = { purpose = "signing" }
      mac  = { purpose = "mac" }
      data = { purpose = "database", services = ["s3"] }
    }
  }

  assert {
    condition     = contains(output.governance.keys["logs"].services, "logs")
    error_message = "the logs profile adds the logs preset."
  }

  assert {
    condition     = aws_kms_key.this["sig"].customer_master_key_spec == "ECC_NIST_P256" && aws_kms_key.this["sig"].key_usage == "SIGN_VERIFY"
    error_message = "the signing profile is an ECC_NIST_P256 signing key."
  }

  assert {
    condition     = aws_kms_key.this["mac"].customer_master_key_spec == "HMAC_256" && aws_kms_key.this["mac"].key_usage == "GENERATE_VERIFY_MAC"
    error_message = "the mac profile is an HMAC_256 key."
  }

  assert {
    condition     = toset(output.governance.keys["data"].services) == toset(["rds", "dms", "backup", "s3"])
    error_message = "a profile's presets and the key's own services are merged."
  }

  assert {
    condition     = aws_kms_key.this["sig"].enable_key_rotation == false && output.governance.keys["sig"].rotation == "not supported for ECC_NIST_P256"
    error_message = "only symmetric keys rotate; governance says why."
  }
}

run "a_spec_alone_picks_its_usage" {
  command = plan

  variables {
    keys = { mac = { spec = "HMAC_512" } }
  }

  assert {
    condition     = aws_kms_key.this["mac"].key_usage == "GENERATE_VERIFY_MAC"
    error_message = "an HMAC spec without a usage is a MAC key."
  }
}

run "module_tags_win_over_caller_tags" {
  command = plan

  variables {
    tags         = { Module = "spoofed", CostCentre = "cc-1" }
    key_defaults = { tags = { Owner = "platform" } }
    keys         = { main = { tags = { Owner = "payments" } } }
  }

  assert {
    condition     = aws_kms_key.this["main"].tags["Module"] == "kms" && aws_kms_key.this["main"].tags["Key"] == "main" && aws_kms_key.this["main"].tags["KeySet"] == "payments"
    error_message = "the module's own tags go last."
  }

  assert {
    condition     = aws_kms_key.this["main"].tags["CostCentre"] == "cc-1" && aws_kms_key.this["main"].tags["Owner"] == "payments"
    error_message = "caller tags arrive, a key's tags over key_defaults over the module's."
  }
}

run "required_tags_are_enforced" {
  command = plan

  variables {
    required_tag_keys = ["CostCentre"]
  }

  expect_failures = [aws_kms_key.this]
}

run "required_tags_pass_when_present" {
  command = plan

  variables {
    required_tag_keys = ["CostCentre"]
    tags              = { CostCentre = "cc-1" }
  }

  assert {
    condition     = aws_kms_key.this["main"].tags["CostCentre"] == "cc-1"
    error_message = "a present required tag passes."
  }
}

run "a_custom_key_store_key_does_not_rotate" {
  command = plan

  variables {
    keys = { hsm = { custom_key_store_id = "cks-0123456789abcdef0" } }
  }

  assert {
    condition     = aws_kms_key.this["hsm"].custom_key_store_id == "cks-0123456789abcdef0" && aws_kms_key.this["hsm"].enable_key_rotation == false
    error_message = "a custom key store key is created in the store and cannot rotate automatically."
  }

  assert {
    condition     = output.governance.keys["hsm"].rotation == "not supported in a custom key store"
    error_message = "governance must say why it does not rotate."
  }
}

run "grants_carry_their_constraints" {
  command = plan

  variables {
    keys = { main = { grants = {
      lambda = {
        grantee_principal         = "arn:aws:iam::111122223333:role/fn"
        operations                = ["Decrypt"]
        retiring_principal        = "arn:aws:iam::111122223333:role/ops"
        retire_on_delete          = true
        encryption_context_subset = { tenant = "acme" }
      }
    } } }
  }

  assert {
    condition     = aws_kms_grant.this["main/lambda"].grantee_principal == "arn:aws:iam::111122223333:role/fn" && aws_kms_grant.this["main/lambda"].retire_on_delete == true
    error_message = "a grant must reach its grantee, with retire_on_delete."
  }

  assert {
    condition     = jsonencode(one(aws_kms_grant.this["main/lambda"].constraints).encryption_context_subset) == jsonencode({ tenant = "acme" })
    error_message = "a grant's encryption context constraint must reach the grant."
  }

  assert {
    condition     = aws_kms_grant.this["main/lambda"].retiring_principal == "arn:aws:iam::111122223333:role/ops"
    error_message = "the retiring principal must reach the grant."
  }
}

run "a_purpose_keeps_its_usage_when_the_spec_allows_it" {
  command = plan

  variables {
    keys = { sig = { purpose = "signing", spec = "RSA_2048" }, enc = { spec = "RSA_2048" } }
  }

  assert {
    condition     = aws_kms_key.this["sig"].key_usage == "SIGN_VERIFY"
    error_message = "signing + RSA_2048 is a signing key: the purpose's usage wins when the spec allows it (fixing it later replaces the key)."
  }

  assert {
    condition     = aws_kms_key.this["enc"].key_usage == "ENCRYPT_DECRYPT"
    error_message = "a spec alone takes its natural usage."
  }
}

run "aliases_are_addressed_by_name" {
  command = plan

  variables {
    keys = { old = {}, new = { aliases = ["payments-app"] } }
  }

  assert {
    condition     = aws_kms_alias.this["payments-app"].name == "alias/payments-app"
    error_message = "an alias is addressed by its name alone, so moving it to another key updates it in place."
  }
}

run "extra_statements_take_statements_of_any_shape" {
  command = plan

  variables {
    keys = { main = { extra_statements = jsonencode([
      { Effect = "Allow", Principal = { AWS = "arn:aws:iam::111122223333:role/a" }, Action = "kms:Decrypt", Resource = "*" },
      { Effect = "Allow", Principal = { AWS = "arn:aws:iam::111122223333:role/b" }, Action = ["kms:Encrypt"], Resource = "*", Condition = { Bool = { "aws:SecureTransport" = "true" } } },
    ]) } }
    acknowledged_checks = ["keys_have_an_organization_perimeter"]
  }

  assert {
    condition     = length(aws_kms_key.this) == 1
    error_message = "statements of different shapes, and without Sids, are a valid policy - neither a type error nor a duplicate Sid."
  }
}

run "a_disabled_signing_key_is_not_read_for_its_public_key" {
  command = plan

  variables {
    keys = { sig = { purpose = "signing", enabled = false } }
  }

  assert {
    condition     = length(data.aws_kms_public_key.this) == 0
    error_message = "GetPublicKey fails on a disabled key; reading it would break every plan."
  }
}

run "the_planning_identity_without_a_role_is_no_deployer" {
  command = plan

  override_data {
    target = data.aws_iam_session_context.deployer
    values = { issuer_arn = "arn:aws:sts::111122223333:federated-user/bob" }
  }

  variables {
    deployers           = []
    acknowledged_checks = ["deletion_protection_has_an_exemption"]
  }

  assert {
    condition     = output.governance.deployers_source == "none"
    error_message = "a federated-user session is not an IAM role: no deployer, and no crash."
  }
}

# ---------------------------------------------------------------------------
# Key-level preconditions
# ---------------------------------------------------------------------------

run "a_grant_operation_the_key_kind_cannot_take_is_refused" {
  command = plan
  variables {
    keys = { sig = { purpose = "signing", grants = { app = { grantee_principal = "arn:aws:iam::111122223333:role/app", operations = ["Decrypt"] } } } }
  }
  expect_failures = [aws_kms_grant.this]
}

run "a_context_constraint_on_a_signing_key_is_refused" {
  command = plan
  variables {
    keys = { sig = { purpose = "signing", grants = { app = { grantee_principal = "arn:aws:iam::111122223333:role/app", operations = ["Sign"], encryption_context_equals = { a = "b" } } } } }
  }
  expect_failures = [aws_kms_grant.this]
}

run "more_than_fifty_tags_are_refused" {
  command = plan
  variables {
    tags = { for i in range(47) : "t${i}" => "x" }
  }
  expect_failures = [aws_kms_key.this]
}

run "policy_protection_needs_named_deployers" {
  command = plan
  variables {
    deployers  = []
    guardrails = { protect_policy = true, break_glass = ["arn:aws:iam::111122223333:role/break-glass"] }
  }
  expect_failures = [aws_kms_key.this]
}

run "strict_mode_needs_named_deployers" {
  command = plan
  variables {
    deployers      = []
    iam_delegation = false
  }
  expect_failures = [aws_kms_key.this]
}

run "spec_and_usage_must_combine" {
  command = plan

  variables {
    keys = { bad = { spec = "HMAC_256", usage = "ENCRYPT_DECRYPT" } }
  }

  expect_failures = [aws_kms_key.this]
}

run "service_presets_need_a_symmetric_key" {
  command = plan

  variables {
    keys = { bad = { purpose = "signing", services = ["s3"] } }
  }

  expect_failures = [aws_kms_key.this]
}

run "dnssec_keys_live_in_us_east_1" {
  command = plan

  variables {
    keys = { zone = { purpose = "dnssec" } }
  }

  expect_failures = [aws_kms_key.this]
}

run "a_custom_key_store_key_is_symmetric" {
  command = plan

  variables {
    keys = { hsm = { custom_key_store_id = "cks-0123456789abcdef0", purpose = "signing" } }
  }

  expect_failures = [aws_kms_key.this]
}

run "strict_mode_needs_a_deployer" {
  command = plan

  variables {
    iam_delegation      = false
    detect_deployer     = false
    acknowledged_checks = ["deletion_protection_has_an_exemption"]
  }

  expect_failures = [aws_kms_key.this]
}

run "policy_protection_needs_an_exemption" {
  command = plan

  variables {
    detect_deployer     = false
    guardrails          = { protect_policy = true }
    acknowledged_checks = ["deletion_protection_has_an_exemption"]
  }

  expect_failures = [aws_kms_key.this]
}

run "an_oversized_bootstrap_policy_is_refused" {
  command = plan

  variables {
    keys = {
      main = {
        extra_statements = "[{\"Sid\":\"Big\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::111122223333:root\"},\"Action\":\"kms:Decrypt\",\"Resource\":\"*\",\"Condition\":{\"StringEquals\":{\"aws:PrincipalTag/x\":\"${format("%33000s", "x")}\"}}}]"
      }
    }
    acknowledged_checks = ["key_policies_leave_room_to_grow", "keys_have_an_organization_perimeter"]
  }

  expect_failures = [aws_kms_key.this]
}

# ---------------------------------------------------------------------------
# Input validations: each input breaks exactly one rule
# ---------------------------------------------------------------------------

run "name_is_validated" {
  command = plan
  variables {
    name = "Payments"
  }
  expect_failures = [var.name]
}

run "tags_cannot_use_the_aws_prefix" {
  command = plan
  variables {
    tags = { "aws:owner" = "x" }
  }
  expect_failures = [var.tags]
}

run "required_tag_keys_are_tag_keys" {
  command = plan
  variables {
    required_tag_keys = [""]
  }
  expect_failures = [var.required_tag_keys]
}

run "acknowledged_checks_must_exist" {
  command = plan
  variables {
    acknowledged_checks = ["no_such_check"]
  }
  expect_failures = [var.acknowledged_checks]
}

run "keys_cannot_be_empty" {
  command = plan
  variables {
    keys = {}
  }
  expect_failures = [var.keys]
}

run "key_names_are_validated" {
  command = plan
  variables {
    keys = { Data = {} }
  }
  expect_failures = [var.keys]
}

run "purpose_is_validated" {
  command = plan
  variables {
    keys = { main = { purpose = "everything" } }
  }
  expect_failures = [var.keys]
}

run "spec_is_validated" {
  command = plan
  variables {
    keys = { main = { spec = "ML_DSA_65" } }
  }
  expect_failures = [var.keys]
}

run "usage_is_validated" {
  command = plan
  variables {
    keys = { main = { usage = "ENCRYPT" } }
  }
  expect_failures = [var.keys]
}

run "rotation_period_is_validated" {
  command = plan
  variables {
    keys = { main = { rotation_period_days = 30 } }
  }
  expect_failures = [var.keys]
}

run "deletion_window_is_validated" {
  command = plan
  variables {
    keys = { main = { deletion_window_days = 3 } }
  }
  expect_failures = [var.keys]
}

run "replicate_needs_multi_region" {
  command = plan
  variables {
    keys = { main = { replicate = true } }
  }
  expect_failures = [var.keys]
}

run "aliases_are_bare_names" {
  command = plan
  variables {
    keys = { main = { aliases = ["alias/payments"] } }
  }
  expect_failures = [var.keys]
}

run "a_default_alias_cannot_collide_with_a_named_one" {
  command = plan
  variables {
    keys = { db = {}, other = { aliases = ["payments-db"] } }
  }
  expect_failures = [var.keys]
}

run "key_tags_cannot_use_the_aws_prefix" {
  command = plan
  variables {
    keys = { main = { tags = { "aws:owner" = "x" } } }
  }
  expect_failures = [var.keys]
}

run "key_default_tags_cannot_use_the_aws_prefix" {
  command = plan
  variables {
    key_defaults = { tags = { "AWS:owner" = "x" } }
  }
  expect_failures = [var.key_defaults]
}

run "key_defaults_rotation_period_is_a_whole_number" {
  command = plan
  variables {
    key_defaults = { rotation_period_days = 100.5 }
  }
  expect_failures = [var.key_defaults]
}

run "principals_cannot_be_wildcards" {
  command = plan
  variables {
    users = ["arn:aws:iam::111122223333:role/*"]
  }
  expect_failures = [var.users]
}

run "replica_deployers_are_role_arns" {
  command = plan
  variables {
    replica_deployers = ["arn:aws:sts::111122223333:assumed-role/dr/x"]
  }
  expect_failures = [var.replica_deployers]
}

run "aws_aliases_are_reserved" {
  command = plan
  variables {
    keys = { main = { aliases = ["aws/payments"] } }
  }
  expect_failures = [var.keys]
}

run "an_alias_belongs_to_one_key" {
  command = plan
  variables {
    keys = { a = { aliases = ["shared"] }, b = { aliases = ["shared"] } }
  }
  expect_failures = [var.keys]
}

run "services_must_be_known_presets" {
  command = plan
  variables {
    keys = { main = { services = ["everything"] } }
  }
  expect_failures = [var.keys]
}

run "via_services_are_kms_via_service_names" {
  command = plan
  variables {
    keys = { main = { via_services = ["glue"] } }
  }
  expect_failures = [var.keys]
}

run "service_access_is_validated" {
  command = plan
  variables {
    keys = { main = { service_access = "everyone" } }
  }
  expect_failures = [var.keys]
}

run "accounts_are_account_ids" {
  command = plan
  variables {
    keys = { main = { accounts = ["12345"] } }
  }
  expect_failures = [var.keys]
}

run "key_principals_are_not_session_arns" {
  command = plan
  variables {
    keys = { main = { users = ["arn:aws:sts::111122223333:assumed-role/app/session"] } }
  }
  expect_failures = [var.keys]
}

run "encryption_context_keys_are_validated" {
  command = plan
  variables {
    keys = { main = { require_encryption_context = ["tenant id"] } }
  }
  expect_failures = [var.keys]
}

run "custom_key_store_ids_are_validated" {
  command = plan
  variables {
    keys = { main = { custom_key_store_id = "store-1" } }
  }
  expect_failures = [var.keys]
}

run "an_external_key_needs_its_store" {
  command = plan
  variables {
    keys = { main = { xks_key_id = "ext-1" } }
  }
  expect_failures = [var.keys]
}

run "a_custom_key_store_key_is_single_region" {
  command = plan
  variables {
    keys = { main = { custom_key_store_id = "cks-0123456789abcdef0", multi_region = true } }
  }
  expect_failures = [var.keys]
}

run "grant_operations_are_validated" {
  command = plan
  variables {
    keys = { main = { grants = { app = { grantee_principal = "arn:aws:iam::111122223333:role/app", operations = ["DecryptEverything"] } } } }
  }
  expect_failures = [var.keys]
}

run "a_grant_has_one_kind_of_context_constraint" {
  command = plan
  variables {
    keys = { main = { grants = { app = {
      grantee_principal         = "arn:aws:iam::111122223333:role/app"
      operations                = ["Decrypt"]
      encryption_context_equals = { a = "1" }
      encryption_context_subset = { b = "2" }
    } } } }
  }
  expect_failures = [var.keys]
}

run "extra_statements_are_a_json_list" {
  command = plan
  variables {
    keys = { main = { extra_statements = "{\"Sid\":\"x\"}" } }
  }
  expect_failures = [var.keys]
}

run "key_defaults_rotation_period_is_validated" {
  command = plan
  variables {
    key_defaults = { rotation_period_days = 3000 }
  }
  expect_failures = [var.key_defaults]
}

run "key_defaults_deletion_window_is_validated" {
  command = plan
  variables {
    key_defaults = { deletion_window_days = 31 }
  }
  expect_failures = [var.key_defaults]
}

run "key_defaults_service_access_is_validated" {
  command = plan
  variables {
    key_defaults = { service_access = "all" }
  }
  expect_failures = [var.key_defaults]
}

run "deployers_are_role_arns" {
  command = plan
  variables {
    deployers = ["arn:aws:iam::111122223333:root"]
  }
  expect_failures = [var.deployers]
}

run "administrators_are_iam_arns" {
  command = plan
  variables {
    administrators = ["admins"]
  }
  expect_failures = [var.administrators]
}

run "users_are_iam_arns" {
  command = plan
  variables {
    users = ["*"]
  }
  expect_failures = [var.users]
}

run "auditors_are_iam_arns" {
  command = plan
  variables {
    auditors = ["arn:aws:sts::111122223333:assumed-role/audit/x"]
  }
  expect_failures = [var.auditors]
}

run "principal_role_names_are_identifiers" {
  command = plan
  variables {
    principal_roles = { "Secret-Readers" = ["arn:aws:iam::111122223333:role/app"] }
  }
  expect_failures = [var.principal_roles]
}

run "principal_role_values_are_iam_arns" {
  command = plan
  variables {
    principal_roles = { secret_readers = ["*"] }
  }
  expect_failures = [var.principal_roles]
}

run "consumers_are_a_named_map" {
  command = plan
  variables {
    consumers = { "DMS" = [] }
  }
  expect_failures = [var.consumers]
}

run "organization_id_is_validated" {
  command = plan
  variables {
    guardrails = { organization_id = "org-1" }
  }
  expect_failures = [var.guardrails]
}

run "trusted_accounts_are_account_ids" {
  command = plan
  variables {
    guardrails = { trusted_accounts = ["abc"] }
  }
  expect_failures = [var.guardrails]
}

run "vpc_endpoint_ids_are_validated" {
  command = plan
  variables {
    guardrails = { replica_vpc_endpoint_ids = ["endpoint-1"] }
  }
  expect_failures = [var.guardrails]
}

run "vpc_endpoint_exemptions_are_role_patterns" {
  command = plan
  variables {
    guardrails = { vpc_endpoint_exempt_principals = ["*"] }
  }
  expect_failures = [var.guardrails]
}

run "min_deletion_window_is_validated" {
  command = plan
  variables {
    guardrails = { min_deletion_window_days = 3 }
  }
  expect_failures = [var.guardrails]
}

run "break_glass_are_role_arns" {
  command = plan
  variables {
    guardrails = { break_glass = ["arn:aws:iam::111122223333:root"] }
  }
  expect_failures = [var.guardrails]
}

run "notification_topics_are_validated" {
  command = plan
  variables {
    notifications = { sns_topic_arn = "topic" }
  }
  expect_failures = [var.notifications]
}

run "notification_events_are_validated" {
  command = plan
  variables {
    notifications = { events = ["everything"] }
  }
  expect_failures = [var.notifications]
}

# ---------------------------------------------------------------------------
# create = false
# ---------------------------------------------------------------------------

run "create_false_plans_nothing_and_every_output_is_empty" {
  command = plan

  variables {
    create = false
    keys = {
      main = {
        multi_region = true
        replicate    = true
        grants       = { app = { grantee_principal = "arn:aws:iam::111122223333:role/app", operations = ["Decrypt"] } }
      }
      sig = { purpose = "signing" }
    }
    notifications = { sns_topic_arn = "arn:aws:sns:eu-west-2:111122223333:alerts", events = ["deletion", "disable"] }
  }

  assert {
    condition = (
      length(aws_kms_key.this) + length(aws_kms_key_policy.this) + length(aws_kms_alias.this) + length(aws_kms_grant.this) + length(terraform_data.contract_refusals) +
      length(aws_cloudwatch_event_rule.native) + length(aws_cloudwatch_event_rule.cloudtrail) +
      length(aws_cloudwatch_event_target.native) + length(aws_cloudwatch_event_target.cloudtrail)
    ) == 0
    error_message = "create = false must plan no resources."
  }

  assert {
    condition = (
      length(data.aws_partition.current) + length(data.aws_region.current) + length(data.aws_caller_identity.current) +
      length(data.aws_iam_session_context.deployer) + length(data.aws_kms_public_key.this)
    ) == 0
    error_message = "create = false must read no data sources."
  }

  assert {
    condition = (
      length(output.keys) + length(output.key_arns) + length(output.key_ids) + length(output.alias_arns) +
      length(output.public_keys) + length(output.policies) + length(output.iam_policy_statements) == 0
    )
    error_message = "create = false must leave the map outputs empty."
  }

  assert {
    condition = (
      output.coverage == null && output.governance == null && output.cost == null && length(output.verify_commands) == 0 &&
      output.sns_topic_policy_requirement == null && output.organization_policy_snippets == null && output.replicas == null
    )
    error_message = "create = false must leave the object outputs null (service_presets and contract_schema are static)."
  }
}
