# Consumer contracts: how requirements are matched, compiled, reported and
# refused. Runs that match on key ARNs use command = apply, because a mocked
# ARN is only known after apply.

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
  target = aws_kms_key.this["data"]
  values = {
    arn    = "arn:aws:kms:eu-west-2:111122223333:key/mrk-0123456789abcdef0123456789abcdef"
    key_id = "mrk-0123456789abcdef0123456789abcdef"
  }
}

override_resource {
  target = aws_kms_key.this["logs"]
  values = {
    arn    = "arn:aws:kms:eu-west-2:111122223333:key/11111111-aaaa-bbbb-cccc-000000000002"
    key_id = "11111111-aaaa-bbbb-cccc-000000000002"
  }
}

variables {
  replica_region = "eu-west-1"
  name           = "payments"
  deployers      = ["arn:aws:iam::111122223333:role/workspace"]
  keys = {
    data = { multi_region = true, replicate = true }
    logs = { services = ["logs"] }
  }
}

# ---------------------------------------------------------------------------
# Compiled
# ---------------------------------------------------------------------------

run "a_requirement_compiles_into_the_key_it_names" {
  command = apply

  variables {
    consumers = {
      dms = [{
        key        = "arn:aws:kms:eu-west-2:111122223333:key/11111111-aaaa-bbbb-cccc-000000000002"
        sid        = "TaskLogs"
        purpose    = "task log group"
        principals = { services = ["logs.eu-west-2.amazonaws.com"], arns = [], roles = [] }
        actions    = ["kms:Encrypt", "kms:Decrypt"]
        conditions = [
          { test = "ArnEquals", variable = "kms:EncryptionContext:aws:logs:arn", values = ["arn:aws:logs:eu-west-2:111122223333:log-group:dms-tasks-x"] },
          { test = "StringEquals", variable = "aws:SourceAccount", values = ["111122223333"] },
        ]
      }]
    }
  }

  assert {
    condition = one([
      for s in jsondecode(output.policies["logs"].primary).Statement : s if try(s.Sid, "") == "ConsumerDms0TaskLogs"
      ]) == {
      Sid       = "ConsumerDms0TaskLogs"
      Effect    = "Allow"
      Principal = { Service = ["logs.eu-west-2.amazonaws.com"] }
      Action    = ["kms:Encrypt", "kms:Decrypt"]
      Resource  = "*"
      Condition = {
        ArnEquals    = { "kms:EncryptionContext:aws:logs:arn" = ["arn:aws:logs:eu-west-2:111122223333:log-group:dms-tasks-x"] }
        StringEquals = { "aws:SourceAccount" = ["111122223333"] }
      }
    }
    error_message = "the requirement must compile exactly: principal, actions, one condition block per test."
  }

  assert {
    condition     = length([for s in jsondecode(output.policies["data"].primary).Statement : s if startswith(try(s.Sid, ""), "Consumer")]) == 0
    error_message = "a requirement must not leak into another key's policy."
  }

  assert {
    condition     = jsonencode(output.coverage.matched["logs"].primary) == jsonencode(["dms[0] TaskLogs: task log group"])
    error_message = "coverage must list what matched where."
  }
}

run "roles_resolve_to_principals" {
  command = apply

  variables {
    principal_roles = { secret_readers = ["arn:aws:iam::111122223333:role/app", "arn:aws:iam::111122223333:role/proxy"] }
    consumers = {
      aurora = [
        {
          key        = "arn:aws:kms:eu-west-2:111122223333:key/mrk-0123456789abcdef0123456789abcdef"
          sid        = "Storage"
          principals = { services = [], arns = [], roles = ["deployer"] }
          actions    = ["kms:CreateGrant", "kms:DescribeKey"]
          conditions = [{ test = "StringEquals", variable = "kms:ViaService", values = ["rds.eu-west-2.amazonaws.com"] }]
        },
        {
          key        = "arn:aws:kms:eu-west-2:111122223333:key/mrk-0123456789abcdef0123456789abcdef"
          sid        = "SecretReaders"
          principals = { services = [], arns = [], roles = ["secret_readers"] }
          actions    = ["kms:Decrypt"]
          conditions = []
        },
      ]
    }
  }

  assert {
    condition     = one([for s in jsondecode(output.policies["data"].primary).Statement : s.Principal.AWS if try(s.Sid, "") == "ConsumerAurora0Storage"]) == ["arn:aws:iam::111122223333:role/workspace"]
    error_message = "deployer must resolve to var.deployers."
  }

  assert {
    condition     = toset(one([for s in jsondecode(output.policies["data"].primary).Statement : s.Principal.AWS if try(s.Sid, "") == "ConsumerAurora1SecretReaders"])) == toset(["arn:aws:iam::111122223333:role/app", "arn:aws:iam::111122223333:role/proxy"])
    error_message = "a mapped role must resolve to its ARNs."
  }
}

run "an_alias_requirement_compiles_on_the_first_plan" {
  command = plan

  variables {
    consumers = {
      app = [{
        key        = "arn:aws:kms:eu-west-2:111122223333:alias/payments-logs"
        sid        = "Read"
        principals = { services = [], arns = ["arn:aws:iam::111122223333:role/app"], roles = [] }
        actions    = ["kms:Decrypt"]
        conditions = []
      }]
    }
  }

  assert {
    condition     = length([for s in jsondecode(output.policies["logs"].primary).Statement : s if try(s.Sid, "") == "ConsumerApp0Read"]) == 1
    error_message = "an alias ARN is known at plan, so its requirement compiles before the key exists."
  }
}

run "a_replica_requirement_compiles_into_the_replica_policy_only" {
  command = apply

  variables {
    consumers = {
      dr = [{
        key        = "arn:aws:kms:eu-west-1:111122223333:key/mrk-0123456789abcdef0123456789abcdef"
        sid        = "Restore"
        principals = { services = [], arns = ["arn:aws:iam::111122223333:role/dr-restore"], roles = [] }
        actions    = ["kms:Decrypt"]
        conditions = []
      }]
    }
  }

  assert {
    condition     = length([for s in jsondecode(output.policies["data"].replica).Statement : s if try(s.Sid, "") == "ConsumerDr0Restore"]) == 1
    error_message = "a requirement naming the replica must reach the replica's policy."
  }

  assert {
    condition     = length([for s in jsondecode(output.policies["data"].primary).Statement : s if try(s.Sid, "") == "ConsumerDr0Restore"]) == 0
    error_message = "and not the primary's."
  }
}

run "a_multi_region_key_id_is_an_identifier" {
  command = apply

  variables {
    consumers = {
      app = [{
        key        = "mrk-0123456789abcdef0123456789abcdef"
        sid        = "Read"
        principals = { services = [], arns = ["arn:aws:iam::111122223333:role/app"], roles = [] }
        actions    = ["kms:Decrypt"]
        conditions = []
      }]
    }
  }

  assert {
    condition     = length(output.coverage.unaddressed) == 0 && length(output.coverage.unmatched) == 0
    error_message = "an mrk- key ID must match, not be reported as prose."
  }
}

# ---------------------------------------------------------------------------
# Reported
# ---------------------------------------------------------------------------

run "a_requirement_for_another_key_set_is_unmatched" {
  command = apply

  variables {
    consumers = {
      app = [{
        key        = "arn:aws:kms:eu-west-2:111122223333:key/99999999-0000-0000-0000-000000000000"
        sid        = "Read"
        principals = { services = [], arns = ["arn:aws:iam::111122223333:role/app"], roles = [] }
        actions    = ["kms:Decrypt"]
        conditions = []
      }]
    }
  }

  expect_failures = [check.every_requirement_found_its_key]

  assert {
    condition     = length(output.coverage.unmatched) == 1
    error_message = "an unmatched requirement must be reported."
  }
}

run "a_prose_key_is_unaddressed" {
  command = apply

  variables {
    consumers = {
      ami = [{
        key        = "the key encrypting the notification topic"
        sid        = "Topic"
        principals = { services = ["events.amazonaws.com"], arns = [], roles = [] }
        actions    = ["kms:GenerateDataKey", "kms:Decrypt"]
        conditions = []
      }]
    }
  }

  expect_failures = [check.every_requirement_found_its_key]

  assert {
    condition     = length(output.coverage.unaddressed) == 1 && length(output.coverage.unmatched) == 0
    error_message = "a prose key is unaddressed, not unmatched."
  }
}

run "an_unresolved_role_is_reported_and_compiles_nothing" {
  command = apply

  variables {
    consumers = {
      aurora = [{
        key        = "arn:aws:kms:eu-west-2:111122223333:key/mrk-0123456789abcdef0123456789abcdef"
        sid        = "SecretReaders"
        principals = { services = [], arns = [], roles = ["secret_readers"] }
        actions    = ["kms:Decrypt"]
        conditions = []
      }]
    }
  }

  expect_failures = [check.every_principal_role_is_resolved]

  assert {
    condition     = jsonencode(output.coverage.unresolved_roles) == jsonencode(["secret_readers (aurora[0] SecretReaders)"])
    error_message = "an unresolved role must be reported."
  }

  assert {
    condition     = length([for s in jsondecode(output.policies["data"].primary).Statement : s if startswith(try(s.Sid, ""), "Consumer")]) == 0
    error_message = "a requirement with no resolvable principal gets no statement."
  }
}

run "a_requirement_naming_nobody_is_reported" {
  command = apply

  variables {
    consumers = {
      dms = [{
        key        = "arn:aws:kms:eu-west-2:111122223333:key/11111111-aaaa-bbbb-cccc-000000000002"
        sid        = "Publishers"
        principals = { services = [], arns = [], roles = [] }
        actions    = ["kms:Decrypt"]
        conditions = []
      }]
    }
  }

  assert {
    condition     = jsonencode(output.coverage.without_principals) == jsonencode(["dms[0] Publishers"])
    error_message = "a requirement naming nobody must be reported."
  }

  assert {
    condition     = length([for s in jsondecode(output.policies["logs"].primary).Statement : s if startswith(try(s.Sid, ""), "Consumer")]) == 0
    error_message = "and compile nothing."
  }
}

run "a_prose_requirement_is_not_machine_readable" {
  command = apply

  variables {
    consumers = {
      legacy = [{
        key       = "arn:aws:kms:eu-west-2:111122223333:key/mrk-0123456789abcdef0123456789abcdef"
        principal = "the principal running terraform"
        actions   = ["kms:Decrypt"]
        why       = "old shape"
      }]
    }
  }

  expect_failures = [check.every_requirement_is_machine_readable]

  assert {
    condition     = jsonencode(output.coverage.not_machine_readable) == jsonencode(["legacy[0]: old shape"])
    error_message = "a prose requirement must be listed with its reason."
  }
}

run "a_condition_without_values_is_malformed" {
  command = apply

  variables {
    consumers = {
      app = [{
        key        = "arn:aws:kms:eu-west-2:111122223333:key/mrk-0123456789abcdef0123456789abcdef"
        sid        = "Read"
        principals = { services = [], arns = ["arn:aws:iam::111122223333:role/app"], roles = [] }
        actions    = ["kms:Decrypt"]
        conditions = [{ test = "StringEquals", variable = "aws:SourceArn", values = [] }]
      }]
    }
  }

  expect_failures = [check.every_requirement_is_machine_readable]

  assert {
    condition     = length(output.coverage.malformed) == 1
    error_message = "a condition without values must be reported as malformed."
  }

  assert {
    condition     = length([for s in jsondecode(output.policies["data"].primary).Statement : s if startswith(try(s.Sid, ""), "Consumer")]) == 0
    error_message = "dropping an empty condition would widen the grant; the requirement must not compile."
  }
}

run "a_repeated_condition_is_malformed" {
  command = apply

  variables {
    consumers = {
      app = [{
        key        = "arn:aws:kms:eu-west-2:111122223333:key/mrk-0123456789abcdef0123456789abcdef"
        sid        = "Read"
        principals = { services = [], arns = ["arn:aws:iam::111122223333:role/app"], roles = [] }
        actions    = ["kms:Decrypt"]
        conditions = [
          { test = "StringEquals", variable = "aws:SourceArn", values = ["a"] },
          { test = "StringEquals", variable = "aws:SourceArn", values = ["b"] },
        ]
      }]
    }
  }

  expect_failures = [check.every_requirement_is_machine_readable]

  assert {
    condition     = length(output.coverage.malformed) == 1
    error_message = "merging a repeated test and key would turn an AND into an OR; the requirement must not compile."
  }
}

run "a_consumer_that_is_not_a_requirement_list_is_reported" {
  command = apply

  variables {
    consumers = {
      dms    = "module.dms"
      aurora = { kms_key_arn = "x" }
    }
  }

  expect_failures = [check.every_requirement_is_machine_readable]

  assert {
    condition     = toset(output.coverage.unreadable_consumers) == toset(["dms", "aurora"])
    error_message = "a consumer that is not a list of requirements must be reported, not silently empty."
  }
}

run "a_requirement_without_a_key_is_not_applicable" {
  command = apply

  variables {
    consumers = {
      dms = [{
        key        = ""
        sid        = "SnsTopic"
        principals = { services = ["dms.amazonaws.com"], arns = [], roles = [] }
        actions    = ["kms:Decrypt"]
        conditions = []
      }]
    }
  }

  assert {
    condition     = jsonencode(output.coverage.not_applicable) == jsonencode(["dms[0] SnsTopic"])
    error_message = "a requirement with no key is a feature that is off, listed as such."
  }
}

# ---------------------------------------------------------------------------
# Refused
# ---------------------------------------------------------------------------

run "a_public_principal_is_refused" {
  command = plan

  variables {
    consumers = {
      evil = [{
        key        = "arn:aws:kms:eu-west-2:111122223333:key/mrk-0123456789abcdef0123456789abcdef"
        sid        = "Open"
        principals = { services = [], arns = ["*"], roles = [] }
        actions    = ["kms:Decrypt"]
        conditions = []
      }]
    }
  }

  expect_failures = [terraform_data.contract_refusals]
}

run "kms_star_is_refused" {
  command = plan

  variables {
    consumers = {
      evil = [{
        key        = "arn:aws:kms:eu-west-2:111122223333:key/mrk-0123456789abcdef0123456789abcdef"
        sid        = "All"
        principals = { services = [], arns = ["arn:aws:iam::111122223333:role/app"], roles = [] }
        actions    = ["kms:*"]
        conditions = []
      }]
    }
  }

  expect_failures = [terraform_data.contract_refusals]
}

run "a_management_action_is_refused" {
  command = plan

  variables {
    consumers = {
      evil = [{
        key        = "arn:aws:kms:eu-west-2:111122223333:key/mrk-0123456789abcdef0123456789abcdef"
        sid        = "Rewrite"
        principals = { services = [], arns = ["arn:aws:iam::111122223333:role/app"], roles = [] }
        actions    = ["kms:PutKeyPolicy"]
        conditions = []
      }]
    }
  }

  expect_failures = [terraform_data.contract_refusals]
}

run "a_non_kms_action_is_refused" {
  command = plan

  variables {
    consumers = {
      evil = [{
        key        = "arn:aws:kms:eu-west-2:111122223333:key/mrk-0123456789abcdef0123456789abcdef"
        sid        = "S3"
        principals = { services = [], arns = ["arn:aws:iam::111122223333:role/app"], roles = [] }
        actions    = ["s3:GetObject"]
        conditions = []
      }]
    }
  }

  expect_failures = [terraform_data.contract_refusals]
}

run "a_colliding_sid_is_refused" {
  command = plan

  variables {
    keys = {
      data = { multi_region = true, replicate = true, extra_statements = "[{\"Sid\":\"Deployers\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::111122223333:role/x\"},\"Action\":\"kms:Decrypt\",\"Resource\":\"*\"}]" }
      logs = { services = ["logs"] }
    }
    acknowledged_checks = ["keys_have_an_organization_perimeter"]
  }

  expect_failures = [aws_kms_key_policy.this]
}

# ---------------------------------------------------------------------------
# Refusals that pattern-match: IAM action names are case-insensitive and may
# end in *, so an exact-match list alone lets PutKeyPolicy through.
# ---------------------------------------------------------------------------

run "a_wildcard_covering_a_management_action_is_refused" {
  command = plan

  variables {
    consumers = {
      sneaky = [{
        key        = "arn:aws:kms:eu-west-2:111122223333:key/mrk-0123456789abcdef0123456789abcdef"
        sid        = "Put"
        principals = { services = [], arns = ["arn:aws:iam::111122223333:role/app"], roles = [] }
        actions    = ["kms:Decrypt", "kms:Put*"]
        conditions = []
      }]
    }
  }

  expect_failures = [terraform_data.contract_refusals]
}

run "a_management_action_in_another_case_is_refused" {
  command = plan

  variables {
    consumers = {
      sneaky = [{
        key        = "arn:aws:kms:eu-west-2:111122223333:key/mrk-0123456789abcdef0123456789abcdef"
        sid        = "Put"
        principals = { services = [], arns = ["arn:aws:iam::111122223333:role/app"], roles = [] }
        actions    = ["kms:putkeypolicy"]
        conditions = []
      }]
    }
  }

  expect_failures = [terraform_data.contract_refusals]
}

run "a_refusal_stops_the_first_plan_before_any_key_exists" {
  command = plan

  # The key ARN this requirement names is unknown until apply; the refusal
  # must not wait for it.
  variables {
    consumers = {
      evil = [{
        key        = "arn:aws:kms:eu-west-2:111122223333:key/not-created-yet"
        sid        = "Open"
        principals = { services = [], arns = ["arn:aws:iam::111122223333:role/*"], roles = [] }
        actions    = ["kms:Decrypt"]
        conditions = []
      }]
    }
  }

  expect_failures = [terraform_data.contract_refusals]
}

run "unscoped_grant_actions_only_grant_for_aws_resources" {
  command = apply

  variables {
    consumers = {
      copy = [{
        key        = "arn:aws:kms:eu-west-2:111122223333:key/11111111-aaaa-bbbb-cccc-000000000002"
        sid        = "CrossAccount"
        principals = { services = [], arns = ["arn:aws:iam::444455556666:root"], roles = [] }
        actions    = ["kms:DescribeKey", "kms:CreateGrant", "kms:Decrypt"]
        conditions = []
      }]
    }
    acknowledged_checks = ["keys_have_an_organization_perimeter"]
  }

  assert {
    condition = jsonencode([for s in jsondecode(output.policies["logs"].primary).Statement : s if startswith(try(s.Sid, ""), "ConsumerCopy0")]) == jsonencode([
      { Action = ["kms:DescribeKey", "kms:Decrypt"], Effect = "Allow", Principal = { AWS = ["arn:aws:iam::444455556666:root"] }, Resource = "*", Sid = "ConsumerCopy0CrossAccount" },
      { Action = ["kms:CreateGrant"], Condition = { Bool = { "kms:GrantIsForAWSResource" = "true" } }, Effect = "Allow", Principal = { AWS = ["arn:aws:iam::444455556666:root"] }, Resource = "*", Sid = "ConsumerCopy0CrossAccountGrants" },
    ])
    error_message = "CreateGrant with neither kms:ViaService nor kms:GrantIsForAWSResource must land in its own statement that only allows grants for AWS resources - otherwise the principal could grant the key to anyone."
  }
}

run "grant_actions_scoped_to_a_service_stay_together" {
  command = apply

  variables {
    consumers = {
      rds = [{
        key        = "arn:aws:kms:eu-west-2:111122223333:key/11111111-aaaa-bbbb-cccc-000000000002"
        sid        = "Storage"
        principals = { services = [], arns = ["arn:aws:iam::111122223333:role/app"], roles = [] }
        actions    = ["kms:CreateGrant", "kms:Decrypt"]
        conditions = [{ test = "StringEquals", variable = "kms:ViaService", values = ["rds.eu-west-2.amazonaws.com"] }]
      }]
    }
  }

  assert {
    condition     = length([for s in jsondecode(output.policies["logs"].primary).Statement : s if startswith(try(s.Sid, ""), "ConsumerRds0")]) == 1
    error_message = "a grant through a named service (kms:ViaService) is already scoped and stays in one statement."
  }
}

run "a_string_where_a_list_belongs_is_malformed" {
  command = apply

  variables {
    consumers = {
      sloppy = [{
        key        = "arn:aws:kms:eu-west-2:111122223333:key/11111111-aaaa-bbbb-cccc-000000000002"
        sid        = "Read"
        principals = { services = [], arns = ["arn:aws:iam::111122223333:role/app"], roles = [] }
        actions    = "kms:Decrypt"
        conditions = []
      }]
    }
  }

  expect_failures = [check.every_requirement_is_machine_readable]

  assert {
    condition     = jsonencode(output.coverage.malformed) == jsonencode(["sloppy[0] Read"])
    error_message = "a string where actions must be a list is reported as malformed."
  }

  assert {
    condition     = length([for s in jsondecode(output.policies["logs"].primary).Statement : s if startswith(try(s.Sid, ""), "ConsumerSloppy")]) == 0
    error_message = "a malformed requirement compiles nothing - not a statement with Action = []."
  }
}
