# Who can do what: roles, separation of duties, service presets. Assertions
# match statements by content, so renaming a Sid cannot make them pass.

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
}

# ---------------------------------------------------------------------------
# Roles
# ---------------------------------------------------------------------------

run "iam_delegation_is_the_account_root_with_kms_star" {
  command = plan

  assert {
    condition     = length([for s in jsondecode(output.policies["main"].primary).Statement : s if try(s.Principal.AWS, "") == "arn:aws:iam::111122223333:root" ? try(s.Action, "") == "kms:*" : false]) == 1
    error_message = "iam_delegation = true must give the account root kms:* once."
  }
}

run "without_iam_delegation_the_account_root_has_nothing" {
  command = plan

  variables {
    iam_delegation = false
  }

  assert {
    condition     = length([for s in jsondecode(output.policies["main"].primary).Statement : s if try(s.Principal.AWS, "") == "arn:aws:iam::111122223333:root"]) == 0
    error_message = "iam_delegation = false must not name the account root."
  }
}

run "deployers_and_break_glass_own_the_key" {
  command = plan

  variables {
    guardrails = { break_glass = ["arn:aws:iam::111122223333:role/break-glass"] }
    keys       = { main = { multi_region = true, replicate = true } }
  }

  assert {
    condition = alltrue([
      for p in ["arn:aws:iam::111122223333:role/workspace", "arn:aws:iam::111122223333:role/break-glass"] : length([
        for s in jsondecode(output.policies["main"].primary).Statement : s
        if contains(try(tolist(s.Principal.AWS), []), p) ? (contains(s.Action, "kms:PutKeyPolicy") ? (contains(s.Action, "kms:CreateGrant") ? contains(s.Action, "kms:ReplicateKey") : false) : false) : false
      ]) == 1
    ])
    error_message = "deployers and break-glass must change the policy, create the module's grants and replicate a multi-Region key."
  }
}

run "administrators_manage_but_cannot_grant_themselves_use" {
  command = plan

  variables {
    administrators = ["arn:aws:iam::111122223333:role/kms-admins"]
  }

  assert {
    condition = alltrue([
      for s in jsondecode(output.policies["main"].primary).Statement :
      !anytrue([for a in s.Action : contains(["kms:CreateGrant", "kms:PutKeyPolicy", "kms:Decrypt", "kms:Encrypt"], a) || strcontains(a, "*")])
      if contains(try(tolist(s.Principal.AWS), []), "arn:aws:iam::111122223333:role/kms-admins")
    ])
    error_message = "administrators must have no grants, no policy changes, no cryptographic use and no wildcards."
  }

  assert {
    condition = length([
      for s in jsondecode(output.policies["main"].primary).Statement : s
      if contains(try(tolist(s.Principal.AWS), []), "arn:aws:iam::111122223333:role/kms-admins") ? contains(s.Action, "kms:ScheduleKeyDeletion") : false
    ]) == 1
    error_message = "administrators still manage the key's lifecycle."
  }
}

run "administrators_can_change_policy_when_allowed" {
  command = plan

  variables {
    administrators                   = ["arn:aws:iam::111122223333:role/kms-admins"]
    administrators_can_change_policy = true
  }

  assert {
    condition = length([
      for s in jsondecode(output.policies["main"].primary).Statement : s
      if contains(try(tolist(s.Principal.AWS), []), "arn:aws:iam::111122223333:role/kms-admins") ? contains(s.Action, "kms:PutKeyPolicy") : false
    ]) == 1
    error_message = "administrators_can_change_policy must add kms:PutKeyPolicy, and only that switch."
  }
}

run "auditors_read_and_nothing_else" {
  command = plan

  variables {
    auditors = ["arn:aws:iam::111122223333:role/security-audit"]
    keys     = { main = {}, sig = { purpose = "signing" } }
  }

  assert {
    condition = toset(one([
      for s in jsondecode(output.policies["main"].primary).Statement : s.Action
      if contains(try(tolist(s.Principal.AWS), []), "arn:aws:iam::111122223333:role/security-audit")
    ])) == toset(["kms:DescribeKey", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus", "kms:ListAliases", "kms:ListGrants", "kms:ListKeyPolicies", "kms:ListKeyRotations", "kms:ListResourceTags"])
    error_message = "auditors get exactly the read-only actions."
  }

  assert {
    condition = contains(one([
      for s in jsondecode(output.policies["sig"].primary).Statement : s.Action
      if contains(try(tolist(s.Principal.AWS), []), "arn:aws:iam::111122223333:role/security-audit")
    ]), "kms:GetPublicKey")
    error_message = "on an asymmetric key auditors also read the public key."
  }
}

run "users_encrypters_and_decrypters_split_the_crypto_actions" {
  command = plan

  variables {
    keys = {
      main = {
        users      = ["arn:aws:iam::111122223333:role/app"]
        encrypters = ["arn:aws:iam::111122223333:role/ingest"]
        decrypters = ["arn:aws:iam::111122223333:role/report"]
      }
      sig = {
        purpose    = "signing"
        encrypters = ["arn:aws:iam::111122223333:role/signer"]
        decrypters = ["arn:aws:iam::111122223333:role/verifier"]
      }
    }
  }

  assert {
    condition     = toset(one([for s in jsondecode(output.policies["main"].primary).Statement : s.Action if try(s.Sid, "") == "Users"])) == toset(["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*"])
    error_message = "users get every symmetric crypto action."
  }

  assert {
    condition     = toset(one([for s in jsondecode(output.policies["main"].primary).Statement : s.Action if try(s.Principal.AWS, []) == ["arn:aws:iam::111122223333:role/ingest"]])) == toset(["kms:Encrypt", "kms:GenerateDataKey*"])
    error_message = "encrypters produce only."
  }

  assert {
    condition     = toset(one([for s in jsondecode(output.policies["main"].primary).Statement : s.Action if try(s.Principal.AWS, []) == ["arn:aws:iam::111122223333:role/report"]])) == toset(["kms:Decrypt"])
    error_message = "decrypters consume only."
  }

  assert {
    condition = (
      toset(one([for s in jsondecode(output.policies["sig"].primary).Statement : s.Action if try(s.Principal.AWS, []) == ["arn:aws:iam::111122223333:role/signer"]])) == toset(["kms:Sign"]) &&
      toset(one([for s in jsondecode(output.policies["sig"].primary).Statement : s.Action if try(s.Principal.AWS, []) == ["arn:aws:iam::111122223333:role/verifier"]])) == toset(["kms:Verify"])
    )
    error_message = "on a signing key encrypters sign and decrypters verify."
  }

  assert {
    condition = length([
      for s in jsondecode(output.policies["main"].primary).Statement : s
      if try(s.Condition.Bool["kms:GrantIsForAWSResource"], "") == "true" ? contains(try(tolist(s.Principal.AWS), []), "arn:aws:iam::111122223333:role/app") : false
    ]) == 1
    error_message = "users create grants for AWS resources only."
  }

  assert {
    condition = length([
      for s in jsondecode(output.policies["main"].primary).Statement : s
      if toset(try(tolist(s.Principal.AWS), [])) == toset(["arn:aws:iam::111122223333:role/app", "arn:aws:iam::111122223333:role/ingest", "arn:aws:iam::111122223333:role/report"]) ? s.Action == ["kms:DescribeKey"] : false
    ]) == 1
    error_message = "everyone who uses the key can describe it, in one statement without conditions."
  }
}

run "required_encryption_context_binds_direct_use_only" {
  command = plan

  variables {
    keys = { main = { users = ["arn:aws:iam::111122223333:role/app"], require_encryption_context = ["tenant"] } }
  }

  assert {
    condition     = one([for s in jsondecode(output.policies["main"].primary).Statement : s.Condition.Null["kms:EncryptionContext:tenant"] if try(s.Sid, "") == "Users"]) == "false"
    error_message = "direct use must carry the tenant encryption context."
  }

  assert {
    condition     = length([for s in jsondecode(output.policies["main"].primary).Statement : s if can(s.Condition.Null) ? contains(s.Action, "kms:DescribeKey") : false]) == 0
    error_message = "DescribeKey carries no context, so it must not be bound to one."
  }
}

run "other_accounts_use_the_key_directly_and_through_services" {
  command = plan

  variables {
    keys       = { main = { accounts = ["444455556666"], services = ["s3"] } }
    guardrails = { organization_id = "o-abcdef1234" }
  }

  assert {
    condition = length([
      for s in jsondecode(output.policies["main"].primary).Statement : s
      if try(s.Principal.AWS, []) == ["arn:aws:iam::444455556666:root"] ? contains(s.Action, "kms:Decrypt") : false
    ]) == 1
    error_message = "another account's root must get the key's use actions."
  }

  assert {
    condition = toset(one([
      for s in jsondecode(output.policies["main"].primary).Statement : s.Condition.StringEquals["kms:CallerAccount"] if try(s.Sid, "") == "ThroughServices"
    ])) == toset(["111122223333", "444455556666"])
    error_message = "the service path must accept calls from the other account too."
  }
}

run "service_access_account_is_the_managed_key_pattern" {
  command = plan

  variables {
    keys = { main = { services = ["rds"] } }
  }

  assert {
    condition = one([
      for s in jsondecode(output.policies["main"].primary).Statement : s.Principal.AWS
      if try(s.Condition.StringLike["kms:ViaService"], []) == ["rds.eu-west-2.amazonaws.com"] ? !can(s.Condition.Bool) : false
    ]) == ["*"]
    error_message = "service_access = account lets any principal of the account use the key, only through its services."
  }
}

run "service_access_named_keeps_the_service_path_to_named_principals" {
  command = plan

  variables {
    keys = { main = { services = ["rds"], service_access = "named", users = ["arn:aws:iam::111122223333:role/app"] } }
  }

  assert {
    condition = toset(one([
      for s in jsondecode(output.policies["main"].primary).Statement : s.Principal.AWS
      if try(s.Condition.StringLike["kms:ViaService"], []) == ["rds.eu-west-2.amazonaws.com"] ? !can(s.Condition.Bool) : false
    ])) == toset(["arn:aws:iam::111122223333:role/app", "arn:aws:iam::111122223333:role/workspace"])
    error_message = "service_access = named names the users and the deployer - the deployer creates encrypted resources through the service."
  }
}

run "strict_mode_with_account_wide_services_warns" {
  command = plan

  variables {
    iam_delegation = false
    keys           = { main = { services = ["rds"] } }
  }

  expect_failures = [check.strict_mode_keeps_services_named]
}

# ---------------------------------------------------------------------------
# Service presets
# ---------------------------------------------------------------------------

run "every_caller_path_preset_names_the_documented_service" {
  command = plan

  assert {
    condition = output.service_presets.caller_path == {
      s3               = ["s3.eu-west-2.amazonaws.com"]
      secretsmanager   = ["secretsmanager.eu-west-2.amazonaws.com"]
      rds              = ["rds.eu-west-2.amazonaws.com"]
      dms              = ["dms.eu-west-2.amazonaws.com"]
      ebs              = ["ec2.eu-west-2.amazonaws.com"]
      backup           = ["backup.*.amazonaws.com"]
      ssm              = ["ssm.eu-west-2.amazonaws.com"]
      dynamodb         = ["dynamodb.*.amazonaws.com"]
      efs              = ["elasticfilesystem.eu-west-2.amazonaws.com"]
      ecr              = ["ecr.eu-west-2.amazonaws.com"]
      lambda           = ["lambda.eu-west-2.amazonaws.com"]
      kinesis          = ["kinesis.eu-west-2.amazonaws.com"]
      firehose         = ["firehose.eu-west-2.amazonaws.com"]
      elasticache      = ["elasticache.eu-west-2.amazonaws.com", "dax.eu-west-2.amazonaws.com"]
      sns              = ["sns.eu-west-2.amazonaws.com"]
      sqs              = ["sqs.eu-west-2.amazonaws.com"]
      states           = ["states.eu-west-2.amazonaws.com"]
      mgn              = ["mgn.eu-west-2.amazonaws.com"]
      fsx              = ["fsx.eu-west-2.amazonaws.com"]
      glue             = ["glue.eu-west-2.amazonaws.com"]
      athena           = ["athena.eu-west-2.amazonaws.com"]
      redshift         = ["redshift.eu-west-2.amazonaws.com", "redshift-serverless.eu-west-2.amazonaws.com"]
      opensearch       = ["es.eu-west-2.amazonaws.com", "aoss.eu-west-2.amazonaws.com"]
      sagemaker        = ["sagemaker.eu-west-2.amazonaws.com"]
      msk              = ["kafka.eu-west-2.amazonaws.com"]
      mwaa             = ["airflow.eu-west-2.amazonaws.com"]
      mq               = ["mq.eu-west-2.amazonaws.com"]
      memorydb         = ["memorydb.eu-west-2.amazonaws.com"]
      docdb-elastic    = ["docdb-elastic.eu-west-2.amazonaws.com"]
      codeartifact     = ["codeartifact.eu-west-2.amazonaws.com"]
      directoryservice = ["directoryservice.eu-west-2.amazonaws.com"]
      storagegateway   = ["storagegateway.eu-west-2.amazonaws.com"]
      ses              = ["ses.eu-west-2.amazonaws.com"]
      connect          = ["connect.eu-west-2.amazonaws.com"]
      workspaces       = ["workspaces.eu-west-2.amazonaws.com"]
      xray             = ["xray.eu-west-2.amazonaws.com"]
      securitylake     = ["securitylake.eu-west-2.amazonaws.com"]
      s3tables         = ["s3tables.eu-west-2.amazonaws.com"]
    }
    error_message = "a caller-path preset names the wrong kms:ViaService: ${jsonencode(output.service_presets.caller_path)}"
  }
}

run "every_service_principal_preset_names_the_documented_principal" {
  command = plan

  assert {
    condition = jsonencode({
      for name, stmts in output.service_presets.service_principal : name => distinct([for s in stmts : try(s.Principal.Service, s.Principal.AWS)])
      }) == jsonencode({
      logs                 = ["logs.eu-west-2.amazonaws.com"]
      cloudtrail           = ["cloudtrail.amazonaws.com"]
      eventbridge-bus      = ["events.amazonaws.com"]
      route53-dnssec       = ["dnssec-route53.amazonaws.com"]
      autoscaling-ebs      = ["arn:aws:iam::111122223333:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"]
      "cloudwatch-to-sns"  = ["cloudwatch.amazonaws.com"]
      "eventbridge-to-sns" = ["events.amazonaws.com"]
      "dms-events-to-sns"  = ["dms.amazonaws.com"]
      "rds-events-to-sns"  = ["events.rds.amazonaws.com"]
      "s3-events-to-sns"   = ["s3.amazonaws.com"]
      "eventbridge-to-sqs" = ["events.amazonaws.com"]
      "s3-events-to-sqs"   = ["s3.amazonaws.com"]
      "sns-to-sqs"         = ["sns.amazonaws.com"]
    })

    error_message = "a service-principal preset names the wrong principal: ${jsonencode({ for name, stmts in output.service_presets.service_principal : name => distinct([for s in stmts : try(s.Principal.Service, s.Principal.AWS)]) })}"
  }
}

run "every_service_principal_preset_is_scoped_as_documented" {
  command = plan

  assert {
    condition = jsonencode({
      for name, stmts in output.service_presets.service_principal : name => sort(distinct(flatten([for s in stmts : [for t, kv in try(s.Condition, {}) : [for key, val in kv : "${t}:${key}"]]])))
      }) == jsonencode({
      logs                 = ["ArnLike:kms:EncryptionContext:aws:logs:arn"]
      cloudtrail           = ["StringEquals:aws:SourceAccount", "StringLike:kms:EncryptionContext:aws:cloudtrail:arn"]
      eventbridge-bus      = ["ArnLike:kms:EncryptionContext:aws:events:event-bus:arn", "StringEquals:aws:SourceAccount"]
      route53-dnssec       = ["ArnLike:aws:SourceArn", "Bool:kms:GrantIsForAWSResource", "StringEquals:aws:SourceAccount"]
      autoscaling-ebs      = ["Bool:kms:GrantIsForAWSResource"]
      "cloudwatch-to-sns"  = ["StringEquals:aws:SourceAccount"]
      "eventbridge-to-sns" = []
      "dms-events-to-sns"  = ["StringEquals:aws:SourceAccount"]
      "rds-events-to-sns"  = ["StringEquals:aws:SourceAccount"]
      "s3-events-to-sns"   = ["StringEquals:aws:SourceAccount"]
      "eventbridge-to-sqs" = ["StringEquals:aws:SourceAccount"]
      "s3-events-to-sqs"   = ["StringEquals:aws:SourceAccount"]
      "sns-to-sqs"         = ["StringEquals:aws:SourceAccount"]
    })

    error_message = "a service-principal preset carries the wrong conditions (EventBridge to SNS must carry none): ${jsonencode({ for name, stmts in output.service_presets.service_principal : name => sort(distinct(flatten([for s in stmts : [for t, kv in try(s.Condition, {}) : [for key, val in kv : "${t}:${key}"]]]))) })}"
  }

  assert {
    condition     = !anytrue(flatten([for name, stmts in output.service_presets.service_principal : [for s in stmts : contains(flatten([for t, kv in try(s.Condition, {}) : keys(kv)]), "kms:ViaService")]]))
    error_message = "kms:ViaService only applies to calls a service makes for a caller; it never belongs on a service-principal statement."
  }
}

run "a_keys_presets_land_in_its_policy" {
  command = plan

  variables {
    keys = {
      main = {
        services     = ["logs", "cloudtrail", "cloudwatch-to-sns", "autoscaling-ebs", "rds", "glue"]
        via_services = ["custom.%s.amazonaws.com"]
      }
    }
  }

  assert {
    condition = alltrue([
      for name in ["logs", "cloudtrail", "cloudwatch-to-sns", "autoscaling-ebs"] : alltrue([
        for want in output.service_presets.service_principal[name] : contains(jsondecode(output.policies["main"].primary).Statement, want)
      ])
    ])
    error_message = "each service-principal preset of a key must appear verbatim in its policy."
  }

  assert {
    condition = toset(one([
      for s in jsondecode(output.policies["main"].primary).Statement : s.Condition.StringLike["kms:ViaService"] if try(s.Sid, "") == "ThroughServices"
    ])) == toset(["rds.eu-west-2.amazonaws.com", "glue.eu-west-2.amazonaws.com", "custom.eu-west-2.amazonaws.com"])
    error_message = "caller-path presets and via_services share one statement, with %s formatted to the region."
  }

  assert {
    condition = one([
      for s in jsondecode(output.policies["main"].primary).Statement : s.Condition.Bool["kms:GrantIsForAWSResource"] if try(s.Sid, "") == "ThroughServicesGrants"
    ]) == "true"
    error_message = "grants through services are for AWS resources only."
  }
}

run "the_bootstrap_policy_already_carries_the_presets" {
  command = plan

  variables {
    keys = { main = { services = ["logs"] } }
  }

  assert {
    condition     = contains(jsondecode(aws_kms_key.this["main"].policy).Statement, output.service_presets.service_principal["logs"][0])
    error_message = "CloudWatch Logs checks the key when a log group is created; its preset must be in the policy the key is created with."
  }
}

run "extra_statements_are_appended" {
  command = plan

  variables {
    keys                = { main = { extra_statements = "[{\"Sid\":\"Extra\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::111122223333:role/x\"},\"Action\":\"kms:Decrypt\",\"Resource\":\"*\"}]" } }
    acknowledged_checks = ["keys_have_an_organization_perimeter"]
  }

  assert {
    condition     = length([for s in jsondecode(output.policies["main"].primary).Statement : s if try(s.Principal.AWS, "") == "arn:aws:iam::111122223333:role/x"]) == 1
    error_message = "extra_statements must reach the policy."
  }
}
