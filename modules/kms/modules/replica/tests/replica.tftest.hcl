# modules/replica: creates what the root module compiled, in the replica
# region, and refuses a provider in any other region.

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { name = "eu-west-1" }
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
  replicas = {
    schema  = 1
    key_set = "payments"
    region  = "eu-west-1"
    keys = {
      data = {
        primary_key_arn      = "arn:aws:kms:eu-west-2:111122223333:key/mrk-0123456789abcdef0123456789abcdef"
        origin               = "AWS_KMS"
        arn                  = "arn:aws:kms:eu-west-1:111122223333:key/mrk-0123456789abcdef0123456789abcdef"
        description          = "payments data, managed by Terraform"
        enabled              = true
        deletion_window_days = 30
        bootstrap_policy     = "{\"Version\":\"2012-10-17\",\"Id\":\"bootstrap\",\"Statement\":[]}"
        policy               = "{\"Version\":\"2012-10-17\",\"Id\":\"final\",\"Statement\":[]}"
        aliases              = ["alias/payments-data", "alias/ledger"]
        tags                 = { Module = "kms", Key = "data" }
      }
    }
    notifications = {
      native_pattern     = "{\"source\":[\"aws.kms\"],\"resources\":[\"arn:aws:kms:eu-west-1:111122223333:key/mrk-0123456789abcdef0123456789abcdef\"]}"
      cloudtrail_pattern = ""
      tags               = { Module = "kms" }
    }
  }
}

run "the_replica_is_created_as_compiled" {
  command = apply

  variables {
    tags = { Module = "overridden", Team = "dr" }
  }

  assert {
    condition     = aws_kms_replica_key.this["data"].primary_key_arn == "arn:aws:kms:eu-west-2:111122223333:key/mrk-0123456789abcdef0123456789abcdef" && aws_kms_replica_key.this["data"].deletion_window_in_days == 30
    error_message = "the replica points at its primary, with the primary's deletion window."
  }

  assert {
    condition     = aws_kms_replica_key.this["data"].policy == var.replicas.keys["data"].bootstrap_policy && aws_kms_key_policy.this["data"].policy == var.replicas.keys["data"].policy
    error_message = "the key is created with the bootstrap policy, and the policy resource applies the compiled replica policy."
  }

  assert {
    condition     = aws_kms_replica_key.this["data"].tags.Module == "kms" && aws_kms_replica_key.this["data"].tags.Team == "dr"
    error_message = "the primary's tags win over extra tags, which are still added."
  }

  assert {
    condition     = jsonencode(sort(keys(aws_kms_alias.this))) == jsonencode(["ledger", "payments-data"])
    error_message = "every alias of the primary exists in the replica region."
  }

  assert {
    condition     = aws_kms_alias.this["ledger"].name == "alias/ledger"
    error_message = "an alias keeps its name."
  }

  assert {
    condition     = jsonencode(output.keys["data"].alias_arns) == jsonencode(["arn:aws:kms:eu-west-1:111122223333:alias/payments-data", "arn:aws:kms:eu-west-1:111122223333:alias/ledger"])
    error_message = "alias ARNs name the replica region."
  }

  assert {
    condition     = length(aws_cloudwatch_event_rule.native) + length(aws_cloudwatch_event_rule.cloudtrail) == 0 && output.sns_topic_policy_requirement == null
    error_message = "no topic, no rules."
  }
}

run "replica_events_go_to_the_replica_regions_topic" {
  command = apply

  variables {
    sns_topic_arn = "arn:aws:sns:eu-west-1:111122223333:alerts"
  }

  assert {
    condition     = aws_cloudwatch_event_rule.native[0].event_pattern == var.replicas.notifications.native_pattern && aws_cloudwatch_event_target.native[0].arn == "arn:aws:sns:eu-west-1:111122223333:alerts"
    error_message = "the native rule uses the compiled pattern and targets the replica region's topic."
  }

  assert {
    condition     = length(aws_cloudwatch_event_rule.cloudtrail) == 0
    error_message = "no CloudTrail pattern compiled, no CloudTrail rule."
  }

  assert {
    condition     = aws_cloudwatch_event_rule.native[0].name == "payments-kms-key-events"
    error_message = "rules are named after the key set."
  }

  assert {
    condition     = output.sns_topic_policy_requirement.Resource == "arn:aws:sns:eu-west-1:111122223333:alerts" && output.sns_topic_policy_requirement.Principal.Service == "events.amazonaws.com"
    error_message = "the topic requirement names the replica region's topic."
  }
}

run "a_provider_in_another_region_is_refused" {
  command = plan

  override_data {
    target = data.aws_region.current
    values = { name = "eu-west-2" }
  }

  expect_failures = [aws_kms_replica_key.this]
}

run "a_blueprint_from_another_version_is_refused" {
  command = plan

  variables {
    replicas = {
      schema        = 2
      key_set       = "payments"
      region        = "eu-west-1"
      keys          = {}
      notifications = { native_pattern = "", cloudtrail_pattern = "", tags = {} }
    }
  }

  expect_failures = [var.replicas]
}

run "null_replicas_create_nothing" {
  command = plan

  variables {
    replicas      = null
    sns_topic_arn = "arn:aws:sns:eu-west-1:111122223333:alerts"
  }

  assert {
    condition     = length(aws_kms_replica_key.this) + length(aws_kms_alias.this) + length(aws_cloudwatch_event_rule.native) + length(data.aws_region.current) == 0 && length(output.keys) == 0
    error_message = "null replicas (nothing replicates) plan nothing."
  }
}

run "create_false_plans_nothing" {
  command = plan

  variables {
    create = false
  }

  assert {
    condition     = length(aws_kms_replica_key.this) + length(aws_kms_key_policy.this) + length(aws_kms_alias.this) == 0 && output.verify_commands == {}
    error_message = "create = false plans nothing."
  }
}

run "imported_material_replicates_as_an_external_replica" {
  command = plan

  variables {
    replicas = {
      schema  = 1
      key_set = "payments"
      region  = "eu-west-1"
      keys = {
        byok = {
          primary_key_arn      = "arn:aws:kms:eu-west-2:111122223333:key/mrk-00000000000000000000000000000001"
          origin               = "EXTERNAL"
          arn                  = "arn:aws:kms:eu-west-1:111122223333:key/mrk-00000000000000000000000000000001"
          description          = "payments byok, managed by Terraform"
          enabled              = true
          deletion_window_days = 30
          bootstrap_policy     = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
          policy               = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
          aliases              = ["alias/payments-byok"]
          tags                 = { Key = "byok" }
        }
      }
      notifications = { native_pattern = "", cloudtrail_pattern = "", tags = {} }
    }
  }

  assert {
    condition     = length(aws_kms_replica_key.this) == 0 && length(aws_kms_replica_external_key.this) == 1
    error_message = "a replica of imported material is an aws_kms_replica_external_key, created pending import in this region."
  }

  assert {
    condition     = nonsensitive(aws_kms_replica_external_key.this["byok"].key_material_base64 == null)
    error_message = "the replica's material is imported out of band too, never through state."
  }
}
