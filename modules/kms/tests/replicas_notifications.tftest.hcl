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

variables {
  replica_region = "eu-west-1"
  name           = "payments"
  deployers      = ["arn:aws:iam::111122223333:role/workspace"]
  keys = {
    data = { multi_region = true, replicate = true, services = ["logs", "rds"] }
    sig  = { purpose = "signing" }
  }
}

# ---------------------------------------------------------------------------
# Replicas
# ---------------------------------------------------------------------------

run "a_replica_is_compiled_for_its_region" {
  command = apply

  assert {
    condition     = output.replicas.region == "eu-west-1"
    error_message = "the blueprint is for replica_region."
  }

  assert {
    condition     = jsonencode(keys(output.replicas.keys)) == jsonencode(["data"])
    error_message = "only replicating keys are in the blueprint."
  }

  assert {
    condition = (
      output.replicas.keys["data"].primary_key_arn == "arn:aws:kms:eu-west-2:111122223333:key/mrk-0123456789abcdef0123456789abcdef" &&
      output.replicas.keys["data"].arn == "arn:aws:kms:eu-west-1:111122223333:key/mrk-0123456789abcdef0123456789abcdef" &&
      output.keys["data"].replica_arn == output.replicas.keys["data"].arn
    )
    error_message = "the replica ARN is the primary's key ID in the replica region, known before the replica exists."
  }

  assert {
    condition     = output.replicas.keys["data"].policy == output.policies["data"].replica && output.policies["sig"].replica == null
    error_message = "the blueprint carries the compiled replica policy; a key without a replica has none."
  }

  assert {
    condition     = jsonencode(output.replicas.keys["data"].aliases) == jsonencode(["alias/payments-data"]) && output.replicas.keys["data"].tags.Key == "data"
    error_message = "the replica gets the primary's aliases and tags."
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
    condition     = aws_kms_key_policy.this["data"].policy == output.policies["data"].primary
    error_message = "the primary's policy resource applies the primary's document."
  }
}

run "a_set_without_replicas_has_no_blueprint" {
  command = apply

  variables {
    keys = { data = {}, sig = { purpose = "signing" } }
  }

  assert {
    condition     = output.replicas == null
    error_message = "with nothing replicating there is nothing for modules/replica to create."
  }

  assert {
    condition     = output.keys["data"].replica_arn == null
    error_message = "a key that does not replicate has no replica ARN."
  }
}

run "a_replica_needs_a_replica_region" {
  command = plan

  variables {
    replica_region = ""
  }

  expect_failures = [aws_kms_key.this]
}

run "a_replica_in_the_primary_region_is_refused" {
  command = plan

  variables {
    replica_region = "eu-west-2"
  }

  expect_failures = [aws_kms_key.this]
}

run "replica_region_is_a_region_name" {
  command = plan

  variables {
    replica_region = "Ireland"
  }

  expect_failures = [var.replica_region]
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

run "replica_notification_patterns_match_the_replicas" {
  command = apply

  variables {
    notifications = { sns_topic_arn = "arn:aws:sns:eu-west-2:111122223333:alerts" }
  }

  assert {
    condition     = jsonencode(jsondecode(output.replicas.notifications.native_pattern).resources) == jsonencode(["arn:aws:kms:eu-west-1:111122223333:key/mrk-0123456789abcdef0123456789abcdef"])
    error_message = "the replica region's native rule must match the replicas, not the primaries."
  }

  assert {
    condition     = output.replicas.notifications.cloudtrail_pattern == "" && output.sns_topic_policy_requirement.Resource == "arn:aws:sns:eu-west-2:111122223333:alerts"
    error_message = "no CloudTrail events chosen, no CloudTrail pattern; the primary's topic requirement names the primary's topic."
  }
}

run "replication_events_are_matched_where_they_are_logged" {
  command = apply

  variables {
    notifications = {
      sns_topic_arn = "arn:aws:sns:eu-west-2:111122223333:alerts"
      events        = ["replication"]
    }
    acknowledged_checks = ["cloudtrail_events_need_a_trail"]
  }

  assert {
    condition     = jsonencode(jsondecode(aws_cloudwatch_event_rule.cloudtrail[0].event_pattern).detail.eventName) == jsonencode(["ReplicateKey", "UpdatePrimaryRegion"])
    error_message = "the primary region logs ReplicateKey and UpdatePrimaryRegion."
  }

  assert {
    condition     = jsonencode(jsondecode(output.replicas.notifications.cloudtrail_pattern).detail.eventName) == jsonencode(["UpdatePrimaryRegion"])
    error_message = "ReplicateKey is logged only in the primary's region: the replica region's rule must not wait for it."
  }
}

# ---------------------------------------------------------------------------
# Reporting outputs
# ---------------------------------------------------------------------------

run "the_cost_is_stated" {
  command = plan

  assert {
    condition     = output.cost.monthly_usd_before_rotation == 3 && output.cost.monthly_usd_upper_bound == 7
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

  assert {
    condition     = strcontains(output.verify_commands["data"].rotations, "list-key-rotations") && strcontains(output.verify_commands["data"].public, "check-no-public-access --region eu-west-2 --resource-type AWS::KMS::Key")
    error_message = "verify commands carry the rotation history (audit evidence) and an Access Analyzer public-access check."
  }
}
