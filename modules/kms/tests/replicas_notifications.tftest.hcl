# Replicas, notifications and the reporting outputs.

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

override_resource {
  target = aws_kms_key.this["data"]
  values = {
    arn    = "arn:aws:kms:eu-west-2:111122223333:key/mrk-0123456789abcdef0123456789abcdef"
    key_id = "mrk-0123456789abcdef0123456789abcdef"
  }
}

override_resource {
  target = aws_kms_key.this["sig"]
  values = {
    arn    = "arn:aws:kms:eu-west-2:111122223333:key/22222222-aaaa-4bbb-8ccc-000000000002"
    key_id = "22222222-aaaa-4bbb-8ccc-000000000002"
  }
}

override_resource {
  target = aws_kms_replica_key.this["data"]
  values = {
    arn    = "arn:aws:kms:eu-west-1:111122223333:key/mrk-0123456789abcdef0123456789abcdef"
    key_id = "mrk-0123456789abcdef0123456789abcdef"
  }
}

variables {
  name      = "payments"
  deployers = ["arn:aws:iam::111122223333:role/workspace"]
  keys = {
    data = { multi_region = true, replicate = true, services = ["logs", "rds"] }
    sig  = { purpose = "signing" }
  }
}

# ---------------------------------------------------------------------------
# Replicas
# ---------------------------------------------------------------------------

run "a_replica_has_its_own_policy_aliases_and_region" {
  command = apply

  assert {
    condition     = aws_kms_replica_key.this["data"].primary_key_arn == "arn:aws:kms:eu-west-2:111122223333:key/mrk-0123456789abcdef0123456789abcdef"
    error_message = "the replica must point at its primary."
  }

  assert {
    condition     = keys(aws_kms_alias.replica) == ["data/payments-data"]
    error_message = "aliases are per region: only the replicated key gets replica aliases."
  }

  assert {
    condition     = one([for s in jsondecode(output.policies["data"].replica).Statement : s.Principal.Service if try(s.Sid, "") == "ServiceLogs"]) == "logs.eu-west-1.amazonaws.com"
    error_message = "a replica's presets name the replica's region."
  }

  assert {
    condition     = one([for s in jsondecode(output.policies["data"].replica).Statement : s.Condition.StringLike["kms:ViaService"] if try(s.Sid, "") == "ThroughServices"]) == ["rds.eu-west-1.amazonaws.com"]
    error_message = "caller-path services on a replica are the replica region's."
  }

  assert {
    condition     = output.keys["data"].replica_arn == "arn:aws:kms:eu-west-1:111122223333:key/mrk-0123456789abcdef0123456789abcdef" && output.policies["sig"].replica == null
    error_message = "output.keys carries the replica ARN; a key without a replica has no replica policy."
  }
}

run "a_replica_in_the_primary_region_is_refused" {
  command = plan

  override_data {
    target = data.aws_region.replica
    values = { name = "eu-west-2" }
  }

  expect_failures = [aws_kms_replica_key.this]
}

run "a_multi_region_key_without_a_replica_warns" {
  command = plan

  variables {
    keys = { data = { multi_region = true }, sig = { purpose = "signing" } }
  }

  expect_failures = [check.multi_region_keys_are_replicated]
}

# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------

run "the_default_events_need_no_trail" {
  command = apply

  variables {
    notifications = { sns_topic_arn = "arn:aws:sns:eu-west-2:111122223333:alerts" }
  }

  assert {
    condition     = length(aws_cloudwatch_event_rule.cloudtrail) == 0 && length(aws_cloudwatch_event_rule.native) == 1
    error_message = "by default only native KMS events are routed - they need no CloudTrail trail."
  }

  assert {
    condition = jsondecode(aws_cloudwatch_event_rule.native[0].event_pattern) == {
      source        = ["aws.kms"]
      "detail-type" = ["KMS CMK Deletion", "KMS CMK Rotation", "KMS Imported Key Material Expiration"]
      resources     = ["arn:aws:kms:eu-west-2:111122223333:key/mrk-0123456789abcdef0123456789abcdef", "arn:aws:kms:eu-west-2:111122223333:key/22222222-aaaa-4bbb-8ccc-000000000002"]
    }
    error_message = "the native rule must match this set's keys only, by their documented detail-types."
  }
}

run "cloudtrail_events_are_opt_in_and_scoped_to_the_set" {
  command = apply

  variables {
    notifications = {
      sns_topic_arn = "arn:aws:sns:eu-west-2:111122223333:alerts"
      events        = ["schedule_deletion", "policy_change", "alias_change"]
    }
    acknowledged_checks = ["cloudtrail_events_need_a_trail"]
  }

  assert {
    condition = jsondecode(aws_cloudwatch_event_rule.cloudtrail[0].event_pattern) == {
      source        = ["aws.kms"]
      "detail-type" = ["AWS API Call via CloudTrail"]
      detail = {
        eventSource = ["kms.amazonaws.com"]
        eventName   = ["ScheduleKeyDeletion", "PutKeyPolicy", "CreateAlias", "UpdateAlias", "DeleteAlias"]
        resources   = { ARN = ["arn:aws:kms:eu-west-2:111122223333:key/mrk-0123456789abcdef0123456789abcdef", "arn:aws:kms:eu-west-2:111122223333:key/22222222-aaaa-4bbb-8ccc-000000000002"] }
      }
    }
    error_message = "the CloudTrail rule must match the chosen calls on this set's keys only."
  }

  assert {
    condition     = length(aws_cloudwatch_event_rule.native) == 0
    error_message = "with no native events chosen there is no native rule."
  }
}

run "cloudtrail_events_warn_until_a_trail_is_confirmed" {
  command = plan

  variables {
    notifications = { sns_topic_arn = "arn:aws:sns:eu-west-2:111122223333:alerts", events = ["disable"] }
  }

  expect_failures = [check.cloudtrail_events_need_a_trail]
}

run "replica_events_go_to_a_topic_in_the_replica_region" {
  command = apply

  variables {
    notifications = {
      sns_topic_arn         = "arn:aws:sns:eu-west-2:111122223333:alerts"
      replica_sns_topic_arn = "arn:aws:sns:eu-west-1:111122223333:alerts"
    }
  }

  assert {
    condition     = jsondecode(aws_cloudwatch_event_rule.replica_native[0].event_pattern).resources == ["arn:aws:kms:eu-west-1:111122223333:key/mrk-0123456789abcdef0123456789abcdef"]
    error_message = "the replica rule must match the replicas."
  }

  assert {
    condition     = aws_cloudwatch_event_target.replica_native[0].arn == "arn:aws:sns:eu-west-1:111122223333:alerts"
    error_message = "replica events go to the replica region's topic."
  }

  assert {
    condition     = output.sns_topic_policy_requirement.replica.Resource == "arn:aws:sns:eu-west-1:111122223333:alerts" && output.sns_topic_policy_requirement.primary.Principal.Service == "events.amazonaws.com"
    error_message = "each topic gets its own policy requirement."
  }
}

# ---------------------------------------------------------------------------
# Reporting outputs
# ---------------------------------------------------------------------------

run "the_cost_is_stated" {
  command = plan

  assert {
    condition     = output.cost.monthly_usd_first_year == 3 && output.cost.monthly_usd_upper_bound == 7
    error_message = "two keys and one replica: $3 before rotation; the rotating data key and its replica reach $3 each, the signing key stays at $1."
  }
}

run "signing_keys_publish_their_public_key" {
  command = apply

  assert {
    condition     = jsonencode(keys(output.public_keys)) == jsonencode(["sig"]) && startswith(output.public_keys["sig"], "-----BEGIN PUBLIC KEY-----")
    error_message = "only asymmetric keys publish a public key."
  }
}

run "iam_statements_match_the_key_policy_roles" {
  command = apply

  assert {
    condition     = jsonencode(output.iam_policy_statements["sig"].encrypter.Action) == jsonencode(["kms:Sign", "kms:DescribeKey", "kms:GetPublicKey"])
    error_message = "the IAM half of a signing key's encrypter signs and describes."
  }

  assert {
    condition     = jsonencode(output.iam_policy_statements["data"].through_services.Condition.StringLike["kms:ViaService"]) == jsonencode(["rds.eu-west-2.amazonaws.com"]) && output.iam_policy_statements["sig"].through_services == null
    error_message = "the through-services IAM statement exists only for keys with caller-path services."
  }
}

run "organization_snippets_protect_the_set" {
  command = apply

  variables {
    guardrails = { organization_id = "o-abcdef1234" }
  }

  assert {
    condition     = output.organization_policy_snippets.scp[0].Condition == { Bool = { "kms:BypassPolicyLockoutSafetyCheck" = "true" } }
    error_message = "the SCP must refuse the lockout bypass."
  }

  assert {
    condition     = toset(output.organization_policy_snippets.scp[1].Resource) == toset(values(output.key_arns)) && jsonencode(output.organization_policy_snippets.scp[1].Condition.ArnNotLike["aws:PrincipalArn"]) == jsonencode(["arn:aws:iam::111122223333:role/workspace"])
    error_message = "the SCP protects exactly this set's keys, exempting the deployers."
  }

  assert {
    condition     = output.organization_policy_snippets.rcp[0].Condition.StringNotEqualsIfExists["aws:PrincipalOrgID"] == "o-abcdef1234"
    error_message = "the RCP carries the organization perimeter."
  }
}

run "verify_commands_name_the_region_and_the_replica" {
  command = apply

  assert {
    condition     = strcontains(output.verify_commands["data"].policy, "--region eu-west-2") && strcontains(output.verify_commands["data"].replica_policy, "--region eu-west-1")
    error_message = "verify commands must name each key's region, including the replica's."
  }
}
