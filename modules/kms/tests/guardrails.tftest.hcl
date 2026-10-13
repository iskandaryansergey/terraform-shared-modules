# Guardrails: every Deny statement's exact action list, principal and
# exemptions, and the checks around them.

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

mock_provider "aws" {
  alias = "replica"
  mock_data "aws_region" {
    defaults = { name = "eu-west-1" }
  }
}

variables {
  name      = "payments"
  deployers = ["arn:aws:iam::111122223333:role/workspace"]
  keys      = { main = {} }
  guardrails = {
    organization_id  = "o-abcdef1234"
    trusted_accounts = ["999988887777"]
    break_glass      = ["arn:aws:iam::111122223333:role/break-glass"]
  }
}

run "every_deny_names_everyone" {
  command = plan

  variables {
    guardrails = {
      organization_id              = "o-abcdef1234"
      vpc_endpoint_ids             = ["vpce-0123456789abcdef0"]
      min_deletion_window_days     = 30
      protect_policy               = true
      protect_aliases_and_rotation = true
    }
  }

  assert {
    condition     = alltrue([for s in jsondecode(output.policies["main"].primary).Statement : s.Principal == "*" if s.Effect == "Deny"])
    error_message = "every Deny uses Principal \"*\", the form AWS's data-perimeter policies use, so it also covers service principals."
  }

  assert {
    condition     = length([for s in jsondecode(output.policies["main"].primary).Statement : s if s.Effect == "Deny"]) == 7
    error_message = "all seven guardrail statements must be present when every guardrail is on."
  }
}

run "the_organization_perimeter_exempts_services_trusted_accounts_and_the_deployer" {
  command = plan

  variables {
    deployers = ["arn:aws:iam::555566667777:role/workspace"]
  }

  assert {
    condition = one([
      for s in jsondecode(output.policies["main"].primary).Statement : s
      if s.Effect == "Deny" ? (s.Action == "kms:*" ? try(s.Condition.BoolIfExists["aws:PrincipalIsAWSService"], "") == "false" : false) : false
      ]).Condition == {
      StringNotEqualsIfExists = { "aws:PrincipalOrgID" = "o-abcdef1234", "aws:PrincipalAccount" = ["999988887777", "555566667777"] }
      BoolIfExists            = { "aws:PrincipalIsAWSService" = "false" }
    }
    error_message = "the perimeter denies principals outside the organization except AWS services, trusted accounts and the deployer's account (else the next apply locks itself out)."
  }
}

run "the_confused_deputy_guard_honours_trusted_accounts" {
  command = plan

  assert {
    condition = one([
      for s in jsondecode(output.policies["main"].primary).Statement : s.Condition
      if s.Effect == "Deny" ? can(s.Condition.Null) : false
      ]) == {
      StringNotEqualsIfExists = { "aws:SourceOrgID" = "o-abcdef1234", "aws:SourceAccount" = ["999988887777"] }
      Null                    = { "aws:SourceAccount" = "false" }
      Bool                    = { "aws:PrincipalIsAWSService" = "true" }
    }
    error_message = "service principals acting for another organization are denied, unless for a trusted account."
  }
}

run "the_vpc_endpoint_perimeter_denies_only_direct_crypto" {
  command = plan

  variables {
    guardrails = {
      vpc_endpoint_ids               = ["vpce-0123456789abcdef0"]
      vpc_endpoint_exempt_principals = ["arn:aws:iam::111122223333:role/lambda-*"]
    }
    acknowledged_checks = ["keys_have_an_organization_perimeter"]
  }

  assert {
    condition = one([
      for s in jsondecode(output.policies["main"].primary).Statement : s
      if s.Effect == "Deny" ? can(s.Condition.StringNotEqualsIfExists["aws:SourceVpce"]) : false
      ]) == {
      Sid       = "DenyCryptoOutsideVpcEndpoints"
      Effect    = "Deny"
      Principal = "*"
      Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:GenerateMac", "kms:VerifyMac", "kms:Sign", "kms:Verify", "kms:DeriveSharedSecret"]
      Resource  = "*"
      Condition = {
        StringNotEqualsIfExists = { "aws:SourceVpce" = ["vpce-0123456789abcdef0"] }
        BoolIfExists            = { "aws:PrincipalIsAWSService" = "false", "aws:ViaAWSService" = "false" }
        ArnNotLikeIfExists      = { "aws:PrincipalArn" = ["arn:aws:iam::*:role/aws:ec2-infrastructure*", "arn:aws:iam::111122223333:role/lambda-*"] }
      }
    }
    error_message = "the endpoint perimeter must deny direct crypto only - never management, which would lock Terraform out - and exempt service calls, EBS and the named principals."
  }
}

run "replicas_get_their_own_vpc_endpoints" {
  command = plan

  variables {
    keys = { main = { multi_region = true, replicate = true } }
    guardrails = {
      vpc_endpoint_ids         = ["vpce-0123456789abcdef0"]
      replica_vpc_endpoint_ids = ["vpce-0fedcba9876543210"]
    }
    acknowledged_checks = ["keys_have_an_organization_perimeter"]
  }

  assert {
    condition = one([
      for s in jsondecode(output.policies["main"].replica).Statement : s.Condition.StringNotEqualsIfExists["aws:SourceVpce"]
      if s.Effect == "Deny" ? can(s.Condition.StringNotEqualsIfExists["aws:SourceVpce"]) : false
    ]) == ["vpce-0fedcba9876543210"]
    error_message = "VPC endpoints are regional: the replica's policy must name the replica region's endpoints."
  }
}

run "a_replica_without_its_endpoints_warns" {
  command = plan

  variables {
    keys                = { main = { multi_region = true, replicate = true } }
    guardrails          = { vpc_endpoint_ids = ["vpce-0123456789abcdef0"] }
    acknowledged_checks = ["keys_have_an_organization_perimeter"]
  }

  expect_failures = [check.replicas_have_their_vpc_endpoints]
}

run "deletion_protection_exempts_exactly_deployers_and_break_glass" {
  command = plan

  assert {
    condition = one([
      for s in jsondecode(output.policies["main"].primary).Statement : s
      if s.Effect == "Deny" ? contains(try(tolist(s.Action), [s.Action]), "kms:DisableKey") : false
      ]) == {
      Sid       = "DenyDeletionAndDisable"
      Effect    = "Deny"
      Principal = "*"
      Action    = ["kms:ScheduleKeyDeletion", "kms:DisableKey"]
      Resource  = "*"
      Condition = { ArnNotLike = { "aws:PrincipalArn" = ["arn:aws:iam::111122223333:role/workspace", "arn:aws:iam::111122223333:role/break-glass"] } }
    }
    error_message = "deletion protection must deny deletion and disabling, and must not touch PutKeyPolicy (that would lock the policy out)."
  }
}

run "deletion_protection_can_be_turned_off" {
  command = plan

  variables {
    guardrails = { deletion_protection = false }
  }

  assert {
    condition     = length([for s in jsondecode(output.policies["main"].primary).Statement : s if s.Effect == "Deny"]) == 0
    error_message = "with every guardrail off there is no Deny."
  }
}

run "a_short_deletion_window_is_denied_to_everyone" {
  command = plan

  variables {
    guardrails = { min_deletion_window_days = 30 }
  }

  assert {
    condition = one([
      for s in jsondecode(output.policies["main"].primary).Statement : s
      if s.Effect == "Deny" ? can(s.Condition.NumericLessThan) : false
    ]).Condition == { NumericLessThan = { "kms:ScheduleKeyDeletionPendingWindowInDays" = "30" } }
    error_message = "a deletion scheduled with less than the minimum window must be denied, with no exemption."
  }
}

run "policy_and_alias_protection_exempt_the_owners" {
  command = plan

  variables {
    guardrails = {
      protect_policy               = true
      protect_aliases_and_rotation = true
      break_glass                  = ["arn:aws:iam::111122223333:role/break-glass"]
    }
  }

  assert {
    condition = one([
      for s in jsondecode(output.policies["main"].primary).Statement : s.Condition.ArnNotLike["aws:PrincipalArn"]
      if s.Effect == "Deny" ? s.Action == "kms:PutKeyPolicy" : false
    ]) == ["arn:aws:iam::111122223333:role/workspace", "arn:aws:iam::111122223333:role/break-glass"]
    error_message = "policy protection must exempt the deployers and break-glass, or the next apply cannot change the policy."
  }

  assert {
    condition = toset(one([
      for s in jsondecode(output.policies["main"].primary).Statement : s.Action
      if s.Effect == "Deny" ? contains(try(tolist(s.Action), []), "kms:UpdateAlias") : false
    ])) == toset(["kms:CreateAlias", "kms:UpdateAlias", "kms:DeleteAlias", "kms:DisableKeyRotation"])
    error_message = "alias protection must cover repointing aliases and turning rotation off."
  }
}

# ---------------------------------------------------------------------------
# The organization perimeter check
# ---------------------------------------------------------------------------

run "a_single_account_key_set_needs_no_perimeter" {
  command = plan

  variables {
    guardrails = {}
  }

  assert {
    condition     = output.governance.guardrails.organization_id == ""
    error_message = "a key set reachable only from its own account plans without the perimeter warning."
  }
}

run "a_key_reachable_from_another_account_warns_without_a_perimeter" {
  command = plan

  variables {
    guardrails = {}
    users      = ["arn:aws:iam::444455556666:role/partner"]
  }

  expect_failures = [check.keys_have_an_organization_perimeter]
}

# ---------------------------------------------------------------------------
# The examples' inputs plan with no refusal and no warning
# ---------------------------------------------------------------------------

run "the_minimal_call_plans_clean" {
  command = plan

  variables {
    deployers  = []
    keys       = { main = {} }
    guardrails = {}
  }

  assert {
    condition     = output.governance.deployers_source == "detected" && output.governance.guardrails.deletion_protection
    error_message = "the minimal call detects its deployer and keeps deletion protection on."
  }
}

run "the_strict_example_plans_clean" {
  command = plan

  variables {
    name            = "cardholder"
    iam_delegation  = false
    deployers       = ["arn:aws:iam::111122223333:role/workspace"]
    detect_deployer = false
    administrators  = ["arn:aws:iam::111122223333:role/security-admin"]
    auditors        = ["arn:aws:iam::111122223333:role/auditor"]
    key_defaults    = { service_access = "named", deletion_window_days = 30 }
    keys = {
      data = {
        purpose                    = "database"
        users                      = ["arn:aws:iam::111122223333:role/app"]
        require_encryption_context = ["tenant"]
      }
      ingest = {
        services   = ["s3"]
        encrypters = ["arn:aws:iam::111122223333:role/ingest"]
        decrypters = ["arn:aws:iam::111122223333:role/app"]
      }
    }
    guardrails = {
      organization_id              = "o-abcdef1234"
      vpc_endpoint_ids             = ["vpce-0123456789abcdef0"]
      min_deletion_window_days     = 30
      protect_policy               = true
      protect_aliases_and_rotation = true
      break_glass                  = ["arn:aws:iam::111122223333:role/break-glass"]
    }
    notifications = {
      sns_topic_arn = "arn:aws:sns:eu-west-2:111122223333:security"
      events        = ["deletion", "rotation", "schedule_deletion", "disable", "policy_change", "rotation_disabled", "alias_change"]
    }
    acknowledged_checks = ["cloudtrail_events_need_a_trail"]
    required_tag_keys   = ["DataClassification"]
    tags                = { DataClassification = "pci" }
  }

  assert {
    condition     = !strcontains(output.policies.data.primary, "EnableIamPolicies") && strcontains(output.policies.data.primary, "DenyCryptoOutsideVpcEndpoints")
    error_message = "the strict example has no account-root statement and keeps the VPC endpoint deny."
  }
}
