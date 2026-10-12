# The run document: the one thing an operator presses. Systems Manager, Run
# Command, pick this document, pick a Mode and its parameters, run on the
# bastion. Every value an operator can type is constrained here, because SSM
# substitutes it into the script as text.

resource "aws_ssm_document" "run_sql" {
  count = local.create ? 1 : 0

  name            = local.run_document_name
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"
  content         = local.run_document_content

  tags = local.common_tags

  lifecycle {
    precondition {
      # The SSM limit is 64 KB of document content.
      condition     = length(local.run_document_content) <= 64000
      error_message = "the run document is ${length(local.run_document_content)} bytes, over the 64 KB SSM limit. Move the largest runbooks to manifests in S3 (Mode=manifest)."
    }
  }
}

locals {
  run_document_content = jsonencode({
    schemaVersion = "2.2"
    description   = "Run SQL or shell scripts from s3://${var.scripts.bucket_name}/${local.scripts_prefix} against the ${var.name} migration databases: one script, a runbook, or a manifest."
    parameters = {
      Mode = {
        type          = "String"
        description   = "run: one script (Target, ScriptKey). runbook: a named runbook (Runbook). manifest: the steps in a JSON file in S3 (ManifestKey). check: connect to Target, or to every target when Target is empty, and change nothing."
        default       = "run"
        allowedValues = ["run", "runbook", "manifest", "check"]
      }
      Target = {
        type           = "String"
        description    = "Mode=run and Mode=check: the database. One of: ${join(", ", sort(keys(var.targets)))}."
        default        = ""
        allowedPattern = local.target_pattern
      }
      ScriptKey = {
        type           = "String"
        description    = "Mode=run: the script's key under s3://${var.scripts.bucket_name}/${local.scripts_prefix}. *.sh runs as a shell step (needs allow_shell_steps)."
        default        = ""
        allowedPattern = "^$|^[A-Za-z0-9][A-Za-z0-9._/-]{0,511}$"
      }
      ExpectedSha256 = {
        type           = "String"
        description    = "Optional. Mode=run: the script's SHA-256. Mode=manifest: the manifest's SHA-256. Any other content is refused."
        default        = ""
        allowedPattern = "^$|^[a-f0-9]{64}$"
      }
      Transaction = {
        type          = "String"
        description   = "Mode=run. auto: one transaction where the engine can roll it back (PostgreSQL, Oracle), statement by statement on MySQL. single: refused on MySQL. none: each statement commits."
        default       = "auto"
        allowedValues = ["auto", "single", "none"]
      }
      Variables = {
        type           = "String"
        description    = "Mode=run: script variables as name=value;name=value. psql --set, MySQL SET @name, SQL*Plus DEFINE. Values: letters, digits, space and _ . , : / @ + % -."
        default        = ""
        allowedPattern = "^$|^[A-Za-z_][A-Za-z0-9_]{0,63}=[A-Za-z0-9 _.,:/@+%-]{0,256}(;[A-Za-z_][A-Za-z0-9_]{0,63}=[A-Za-z0-9 _.,:/@+%-]{0,256}){0,19}$"
      }
      Runbook = {
        type           = "String"
        description    = length(var.runbooks) == 0 ? "Mode=runbook: no runbooks are configured." : "Mode=runbook: one of ${join(", ", sort(keys(var.runbooks)))}."
        default        = ""
        allowedPattern = local.runbook_pattern
      }
      ManifestKey = {
        type           = "String"
        description    = "Mode=manifest: the manifest's key under s3://${var.scripts.bucket_name}/${local.scripts_prefix}."
        default        = ""
        allowedPattern = "^$|^[A-Za-z0-9][A-Za-z0-9._/-]{0,511}$"
      }
      StartAt = {
        type           = "String"
        description    = "Mode=runbook and Mode=manifest: start from this step name, skipping the ones before it. How a failed run resumes."
        default        = ""
        allowedPattern = "^$|^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"
      }
      DryRun = {
        type          = "String"
        description   = "true: fetch and verify every script, connect to every target the steps use, execute nothing."
        default       = "false"
        allowedValues = ["false", "true"]
      }
      StepTimeoutSeconds = {
        type           = "String"
        description    = "Timeout for each step that sets none. 0: default_timeout_seconds (${var.default_timeout_seconds})."
        default        = "0"
        allowedPattern = "^[0-9]{1,6}$"
      }
      TimeoutSeconds = {
        type           = "String"
        description    = "The whole run. SSM stops the runner after this long, and the runner stops the step in flight."
        default        = tostring(var.run_timeout_seconds)
        allowedPattern = "^[0-9]{2,6}$"
      }
    }
    mainSteps = [{
      action       = "aws:runShellScript"
      name         = "run"
      precondition = { StringEquals = ["platformType", "Linux"] }
      inputs = {
        timeoutSeconds = "{{ TimeoutSeconds }}"
        runCommand     = split("\n", local.runner_script)
      }
    }]
  })
}

resource "aws_cloudwatch_log_group" "runs" {
  count = local.create ? 1 : 0

  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn != "" ? var.kms_key_arn : null

  tags = local.common_tags
}
