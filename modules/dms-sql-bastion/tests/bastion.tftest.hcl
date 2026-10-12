# Plan-level tests with a mocked provider. The runner script itself is tested
# separately: render it, substitute the SSM parameters, and run it with stub
# clients (see README, "Testing the runner").

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { name = "eu-west-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_resource "aws_instance" {
    defaults = { id = "i-0123456789abcdef0" }
  }
  mock_resource "aws_security_group" {
    defaults = { id = "sg-0bbbbbbbbbbbbbbbb" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/mock" }
  }
}

variables {
  name      = "core-banking"
  ami_id    = "ami-0123456789abcdef0"
  vpc_id    = "vpc-0123456789abcdef0"
  subnet_id = "subnet-0123456789abcdef0"

  https_egress = {
    security_group_ids = ["sg-0eeeeeeeeeeeeeeee"]
    prefix_list_ids    = ["pl-0123456789abcdef0"]
  }

  scripts = {
    bucket_name = "core-banking-migration-scripts"
    prefix      = "migrations/"
  }

  targets = {
    aurora = {
      engine             = "aurora-postgresql"
      host               = "core.cluster-abc123.eu-west-1.rds.amazonaws.com"
      port               = 5432
      database           = "core"
      secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:core-migrator-AbCdEf"
      secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
      ca_bundle_path     = "/etc/pki/rds/global-bundle.pem"
      security_group_id  = "sg-0aaaaaaaaaaaaaaaa"
    }
    legacy = {
      engine      = "oracle"
      host        = "ora-core.corp.example"
      port        = 1521
      database    = "CORE.corp.example"
      secret_arn  = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:ora-migrator-AbCdEf"
      cidr_blocks = ["10.20.0.0/16"]
    }
  }
}

# ---------------------------------------------------------------------------
# The instance
# ---------------------------------------------------------------------------

run "the_instance_is_reachable_only_through_ssm" {
  command = plan

  assert {
    condition     = aws_instance.this[0].associate_public_ip_address == false
    error_message = "the bastion must not have a public address."
  }

  assert {
    condition     = aws_instance.this[0].metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required."
  }

  assert {
    condition     = aws_instance.this[0].root_block_device[0].encrypted == true
    error_message = "the root volume must be encrypted."
  }

  assert {
    condition     = aws_ec2_instance_state.this[0].state == "running"
    error_message = "running defaults to true."
  }
}

run "running_false_stops_the_instance" {
  command = plan

  variables {
    running = false
  }

  assert {
    condition     = aws_ec2_instance_state.this[0].state == "stopped"
    error_message = "running = false must stop the instance."
  }
}

run "create_false_plans_nothing" {
  command = plan

  variables {
    create = false
  }

  assert {
    condition     = length(aws_instance.this) == 0 && length(aws_ssm_document.run_sql) == 0 && length(aws_iam_role.this) == 0
    error_message = "create = false must plan nothing."
  }

  assert {
    condition     = output.commands == null && output.operator_policy_json == null
    error_message = "outputs must be null when nothing is created."
  }
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

run "egress_is_https_to_endpoints_and_the_database_ports" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.https) == 2
    error_message = "one HTTPS egress rule per endpoint security group and prefix list."
  }

  assert {
    condition = (
      aws_vpc_security_group_egress_rule.database["aurora-sg"].from_port == 5432 &&
      aws_vpc_security_group_egress_rule.database["aurora-sg"].referenced_security_group_id == "sg-0aaaaaaaaaaaaaaaa" &&
      aws_vpc_security_group_egress_rule.database["legacy-10.20.0.0/16"].from_port == 1521 &&
      aws_vpc_security_group_egress_rule.database["legacy-10.20.0.0/16"].cidr_ipv4 == "10.20.0.0/16"
    )
    error_message = "database egress must go to each target's security group or CIDR on its port."
  }

  assert {
    condition     = keys(aws_vpc_security_group_ingress_rule.target) == ["aurora"]
    error_message = "ingress is added only on targets with a security group."
  }
}

run "target_ingress_can_be_left_to_its_owner" {
  command = plan

  variables {
    manage_target_ingress = false
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.target) == 0
    error_message = "manage_target_ingress = false must not write on the database's security group."
  }

  assert {
    condition     = startswith(output.network_contract.database_ingress["aurora"], "request:")
    error_message = "the contract must then say which rule to request."
  }
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------

run "the_role_reads_only_the_scripts_prefix_and_the_target_secrets" {
  command = plan

  assert {
    condition = contains(
      jsondecode(aws_iam_role_policy.this[0].policy).Statement[0].Resource,
      "arn:aws:s3:::core-banking-migration-scripts/migrations/*"
    )
    error_message = "the role must read the scripts prefix, and only it."
  }

  assert {
    condition = toset(jsondecode(aws_iam_role_policy.this[0].policy).Statement[2].Resource) == toset([
      "arn:aws:secretsmanager:eu-west-1:111122223333:secret:core-migrator-AbCdEf",
      "arn:aws:secretsmanager:eu-west-1:111122223333:secret:ora-migrator-AbCdEf",
    ])
    error_message = "the role must read exactly the target secrets."
  }

  assert {
    condition     = anytrue([for s in jsondecode(aws_iam_role_policy.this[0].policy).Statement : s.Sid == "DecryptTargetCredentials"])
    error_message = "a secret with a customer key needs kms:Decrypt through Secrets Manager."
  }
}

# ---------------------------------------------------------------------------
# The run document
# ---------------------------------------------------------------------------

run "the_document_constrains_every_parameter" {
  command = plan

  assert {
    condition     = jsondecode(aws_ssm_document.run_sql[0].content).parameters.Target.allowedPattern == "^$|^(aurora|legacy)$"
    error_message = "Target must be limited to the configured targets."
  }

  assert {
    condition = alltrue([
      for p, d in jsondecode(aws_ssm_document.run_sql[0].content).parameters :
      can(d.allowedValues) || can(d.allowedPattern)
    ])
    error_message = "every parameter is substituted into a shell script as text, so every one needs allowedValues or allowedPattern."
  }

  assert {
    condition     = jsondecode(aws_ssm_document.run_sql[0].content).parameters.TimeoutSeconds.default == "28800"
    error_message = "TimeoutSeconds defaults to run_timeout_seconds."
  }

  assert {
    condition     = jsondecode(aws_ssm_document.run_sql[0].content).parameters.Runbook.allowedPattern == "^$"
    error_message = "with no runbooks, Runbook accepts nothing."
  }
}

run "the_launcher_only_references_declared_parameters" {
  command = plan

  # SSM substitutes every double-brace token in the document, comments and
  # the embedded runner included, and rejects the document for an undeclared
  # one.
  assert {
    condition = alltrue([
      for m in regexall("\\{\\{ *([A-Za-z0-9]+) *\\}\\}", join("\n", jsondecode(aws_ssm_document.run_sql[0].content).mainSteps[0].inputs.runCommand)) :
      contains(keys(jsondecode(aws_ssm_document.run_sql[0].content).parameters), m[0])
    ])
    error_message = "the launcher or runner references a parameter the document does not declare."
  }

  assert {
    condition     = length(local.run_document_content) <= 64000
    error_message = "the document is over the SSM 64 KB limit."
  }
}

run "the_runner_config_carries_each_target" {
  command = plan

  assert {
    condition     = local.runner_config.targets["aurora"].host == "core.cluster-abc123.eu-west-1.rds.amazonaws.com" && local.runner_config.targets["legacy"].family == "oracle"
    error_message = "every target must reach the runner."
  }

  assert {
    condition     = local.runner_config.targets["aurora"].ssl_mode == "verify-full" && local.runner_config.targets["legacy"].ssl_mode == "none"
    error_message = "ssl_mode \"\" resolves to verify-full for PostgreSQL and none for Oracle."
  }

  assert {
    condition     = local.runner_config.scripts_prefix == "migrations/"
    error_message = "the scripts prefix is normalised to end in exactly one slash."
  }

  assert {
    condition     = strcontains(local.runner_script, "def normalize_step(") && strcontains(local.runner_script, "\"scripts_bucket\":\"core-banking-migration-scripts\"")
    error_message = "the launcher must embed the runner and its configuration."
  }
}

# ---------------------------------------------------------------------------
# Runbooks
# ---------------------------------------------------------------------------

run "runbooks_reach_the_runner_in_order" {
  # apply: the commands output needs the (mocked) instance id.
  command = apply

  variables {
    runbooks = {
      pre-data = {
        description = "schema before the load"
        steps = [
          { name = "schemas", target = "aurora", script = "wave-1/pre/01-schemas.sql" },
          { name = "tables", target = "aurora", script = "wave-1/pre/02-tables.sql", sha256 = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08", timeout_seconds = 600 },
          { target = "legacy", script = "wave-1/pre/03-grants.sql", on_error = "continue", variables = { SCHEMA_NAME = "CORE" } },
        ]
      }
    }
  }

  assert {
    condition     = [for s in local.runner_config.runbooks["pre-data"].steps : s.script] == ["wave-1/pre/01-schemas.sql", "wave-1/pre/02-tables.sql", "wave-1/pre/03-grants.sql"]
    error_message = "steps must keep their order."
  }

  assert {
    condition     = local.runner_config.runbooks["pre-data"].steps[1].timeout_seconds == 600 && !can(local.runner_config.runbooks["pre-data"].steps[0].timeout_seconds)
    error_message = "unset optional step fields are left to the runner's defaults."
  }

  assert {
    condition     = jsondecode(aws_ssm_document.run_sql[0].content).parameters.Runbook.allowedPattern == "^$|^(pre-data)$"
    error_message = "Runbook must be limited to the configured runbooks."
  }

  assert {
    condition     = output.runbooks["pre-data"].steps[2] == "step-3: sql wave-1/pre/03-grants.sql on legacy (continue on error)"
    error_message = "output.runbooks must show each step as the runner will see it."
  }

  assert {
    condition     = strcontains(output.commands.runbook_dry_run["pre-data"], "Mode=runbook,Runbook=pre-data,DryRun=true")
    error_message = "the commands output must include the dry run."
  }
}

run "a_runbook_step_on_an_unknown_target_is_refused" {
  command = plan

  variables {
    runbooks = {
      pre-data = { steps = [{ target = "nope", script = "a.sql" }] }
    }
  }

  expect_failures = [var.runbooks]
}

run "duplicate_step_names_are_refused" {
  command = plan

  variables {
    runbooks = {
      pre-data = { steps = [
        { name = "a", target = "aurora", script = "a.sql" },
        { name = "a", target = "aurora", script = "b.sql" },
      ] }
    }
  }

  expect_failures = [var.runbooks]
}

run "a_shell_step_needs_allow_shell_steps" {
  command = plan

  variables {
    runbooks = {
      dump = { steps = [{ target = "aurora", script = "tools/dump.sh" }] }
    }
  }

  expect_failures = [var.runbooks]
}

run "a_shell_step_is_allowed_when_enabled" {
  command = plan

  variables {
    allow_shell_steps = true
    runbooks = {
      dump = { steps = [{ target = "aurora", script = "tools/dump.sh" }] }
    }
  }

  assert {
    condition     = local.runner_config.allow_shell_steps
    error_message = "allow_shell_steps must reach the runner."
  }

  assert {
    condition     = output.runbooks["dump"].steps[0] == "step-1: shell tools/dump.sh on aurora"
    error_message = "a .sh step is a shell step."
  }
}

run "a_quote_in_a_variable_is_refused" {
  command = plan

  variables {
    runbooks = {
      pre-data = { steps = [{ target = "aurora", script = "a.sql", variables = { X = "a'; DROP TABLE t; --" } }] }
    }
  }

  expect_failures = [var.runbooks]
}

run "single_transaction_on_mysql_is_refused" {
  command = plan

  variables {
    targets = {
      shop = {
        engine            = "mysql"
        host              = "shop.example"
        port              = 3306
        database          = "shop"
        secret_arn        = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:shop-AbCdEf"
        ca_bundle_path    = "/etc/pki/rds/global-bundle.pem"
        security_group_id = "sg-0aaaaaaaaaaaaaaaa"
      }
    }
    runbooks = {
      pre-data = { steps = [{ target = "shop", script = "a.sql", transaction = "single" }] }
    }
  }

  expect_failures = [var.runbooks]
}

# ---------------------------------------------------------------------------
# Extension points
# ---------------------------------------------------------------------------

run "extension_points_are_wired" {
  command = plan

  variables {
    additional_security_group_ids = ["sg-0ccccccccccccccc0"]
    additional_egress_rules = {
      ldap = { from_port = 636, to_port = 636, cidr = "10.30.0.0/24" }
    }
    additional_iam_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
    additional_iam_policy_json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::other/*\"}]}"
  }

  assert {
    condition     = contains(aws_instance.this[0].vpc_security_group_ids, "sg-0ccccccccccccccc0")
    error_message = "additional security groups must be on the instance."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.additional["ldap"].from_port == 636 && aws_vpc_security_group_egress_rule.additional["ldap"].cidr_ipv4 == "10.30.0.0/24"
    error_message = "additional egress rules must be created."
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.additional) == 1 && length(aws_iam_role_policy.additional) == 1
    error_message = "additional IAM policies must be attached."
  }
}

run "a_target_cannot_override_the_credential_environment" {
  command = plan

  variables {
    targets = {
      aurora = {
        engine            = "aurora-postgresql"
        host              = "core.example"
        port              = 5432
        database          = "core"
        secret_arn        = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:core-migrator-AbCdEf"
        ca_bundle_path    = "/etc/pki/rds/global-bundle.pem"
        security_group_id = "sg-0aaaaaaaaaaaaaaaa"
        env               = { PGPASSWORD = "x" }
      }
    }
  }

  expect_failures = [var.targets]
}

run "target_client_settings_reach_the_runner" {
  command = plan

  variables {
    targets = {
      aurora = {
        engine            = "aurora-postgresql"
        host              = "core.example"
        port              = 5432
        database          = "core"
        secret_arn        = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:core-migrator-AbCdEf"
        ca_bundle_path    = "/etc/pki/rds/global-bundle.pem"
        security_group_id = "sg-0aaaaaaaaaaaaaaaa"
        client_options    = ["--quiet"]
        env               = { PGOPTIONS = "-c lock_timeout=30s" }
        variables         = { app_schema = "core" }
      }
    }
  }

  assert {
    condition = (
      jsonencode(local.runner_config.targets["aurora"].client_options) == jsonencode(["--quiet"]) &&
      local.runner_config.targets["aurora"].env["PGOPTIONS"] == "-c lock_timeout=30s" &&
      local.runner_config.targets["aurora"].variables["app_schema"] == "core"
    )
    error_message = "client_options, env and variables must reach the runner."
  }
}

# ---------------------------------------------------------------------------
# Refusals
# ---------------------------------------------------------------------------

run "a_quote_in_a_host_is_refused" {
  command = plan

  variables {
    targets = {
      aurora = {
        engine            = "aurora-postgresql"
        host              = "x'; rm -rf / #"
        port              = 5432
        database          = "core"
        secret_arn        = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:core-migrator-AbCdEf"
        ca_bundle_path    = "/etc/pki/rds/global-bundle.pem"
        security_group_id = "sg-0aaaaaaaaaaaaaaaa"
      }
    }
  }

  expect_failures = [var.targets]
}

run "verify_full_without_a_ca_bundle_is_refused" {
  command = plan

  variables {
    targets = {
      aurora = {
        engine            = "aurora-postgresql"
        host              = "core.example"
        port              = 5432
        database          = "core"
        secret_arn        = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:core-migrator-AbCdEf"
        security_group_id = "sg-0aaaaaaaaaaaaaaaa"
      }
    }
  }

  expect_failures = [var.targets]
}

run "verify_full_on_oracle_is_refused" {
  command = plan

  variables {
    targets = {
      legacy = {
        engine      = "oracle"
        host        = "ora.example"
        port        = 1521
        database    = "CORE"
        secret_arn  = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:ora-migrator-AbCdEf"
        ssl_mode    = "verify-full"
        cidr_blocks = ["10.20.0.0/16"]
      }
    }
  }

  expect_failures = [var.targets]
}

run "a_target_with_no_route_is_refused" {
  command = plan

  variables {
    targets = {
      legacy = {
        engine     = "oracle"
        host       = "ora.example"
        port       = 1521
        database   = "CORE"
        secret_arn = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:ora-migrator-AbCdEf"
      }
    }
  }

  expect_failures = [var.targets]
}

run "unverified_transport_needs_a_decision" {
  command = plan

  variables {
    targets = {
      aurora = {
        engine            = "aurora-postgresql"
        host              = "core.example"
        port              = 5432
        database          = "core"
        secret_arn        = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:core-migrator-AbCdEf"
        ssl_mode          = "require"
        security_group_id = "sg-0aaaaaaaaaaaaaaaa"
      }
    }
  }

  expect_failures = [aws_instance.this]
}

run "unverified_transport_is_allowed_when_accepted" {
  command = plan

  variables {
    allow_insecure_transport = true
    targets = {
      aurora = {
        engine            = "aurora-postgresql"
        host              = "core.example"
        port              = 5432
        database          = "core"
        secret_arn        = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:core-migrator-AbCdEf"
        ssl_mode          = "require"
        security_group_id = "sg-0aaaaaaaaaaaaaaaa"
      }
    }
  }

  assert {
    condition     = length(aws_instance.this) == 1
    error_message = "allow_insecure_transport must let require through."
  }
}

run "no_https_egress_is_refused" {
  command = plan

  variables {
    https_egress = {}
  }

  expect_failures = [var.https_egress]
}

run "a_traversing_prefix_is_refused" {
  command = plan

  variables {
    scripts = {
      bucket_name = "core-banking-migration-scripts"
      prefix      = "migrations/../other"
    }
  }

  expect_failures = [var.scripts]
}
