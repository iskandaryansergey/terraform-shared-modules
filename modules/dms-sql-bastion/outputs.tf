output "instance_id" {
  description = "The bastion. Target of the run document and of Session Manager."
  value       = one(aws_instance.this[*].id)
}

output "security_group_id" {
  description = "The bastion's security group, for rules a database team adds on their side."
  value       = one(aws_security_group.this[*].id)
}

output "role_arn" {
  description = "The instance role. Key policies and bucket policies that name a principal name this."
  value       = one(aws_iam_role.this[*].arn)
}

output "run_document_name" {
  description = "The SSM Command document that runs a script."
  value       = one(aws_ssm_document.run_sql[*].name)
}

output "log_group_name" {
  description = "Where each run's output goes when the command enables CloudWatch output, as output.commands does."
  value       = one(aws_cloudwatch_log_group.runs[*].name)
}

output "commands" {
  description = "Filled-in commands: upload, check, run one script, run each runbook (and dry-run it), run a manifest, read the result. The console equivalent is Systems Manager, Run Command, document run_document_name."
  value = !local.create ? null : {
    upload = "sha256sum <file> && aws s3 cp <file> s3://${var.scripts.bucket_name}/${local.scripts_prefix}<key>"
    check_all = join(" ", [
      local.send_command, "--parameters Mode=check", local.send_command_tail,
    ])
    check = {
      for k, t in var.targets : k => join(" ", [local.send_command, "--parameters Mode=check,Target=${k}", local.send_command_tail])
    }
    run = {
      for k, t in var.targets : k => join(" ", [
        local.send_command, "--parameters Target=${k},ScriptKey=<key>,ExpectedSha256=<sha256>", local.send_command_tail,
      ])
    }
    runbook = {
      for k, r in var.runbooks : k => join(" ", [local.send_command, "--parameters Mode=runbook,Runbook=${k}", local.send_command_tail])
    }
    runbook_dry_run = {
      for k, r in var.runbooks : k => join(" ", [local.send_command, "--parameters Mode=runbook,Runbook=${k},DryRun=true", local.send_command_tail])
    }
    runbook_resume = {
      for k, r in var.runbooks : k => join(" ", [local.send_command, "--parameters Mode=runbook,Runbook=${k},StartAt=<step-name>", local.send_command_tail])
    }
    manifest = var.allow_s3_manifests ? join(" ", [
      local.send_command, "--parameters Mode=manifest,ManifestKey=<key>,ExpectedSha256=<manifest-sha256>", local.send_command_tail,
    ]) : null
    result  = "aws ssm get-command-invocation --instance-id ${aws_instance.this[0].id} --command-id <command-id> --query '[Status,ResponseCode,StandardOutputContent,StandardErrorContent]' --output text"
    logs    = "aws logs tail ${local.log_group_name} --follow"
    session = "aws ssm start-session --target ${aws_instance.this[0].id}"
  }
}

output "runbooks" {
  description = "Each runbook's steps in run order, as the runner will see them: what a reviewer approves in the plan."
  value = !local.create ? null : {
    for k, r in var.runbooks : k => {
      description = r.description
      steps = [
        for i, s in r.steps : format("%s: %s %s on %s%s",
          s.name != "" ? s.name : "step-${i + 1}",
          s.type != "" ? s.type : (endswith(s.script, ".sh") ? "shell" : "sql"),
          s.script, s.target,
          s.on_error == "continue" ? " (continue on error)" : "",
        )
      ]
    }
  }
}

output "network_contract" {
  description = "What the VPC has to provide. Without the interface endpoints the instance never registers with SSM and does not appear in Run Command at all."
  value = !local.create ? null : {
    interface_endpoints = compact([
      "com.amazonaws.${local.region}.ssm",
      "com.amazonaws.${local.region}.ssmmessages",
      "com.amazonaws.${local.region}.ec2messages",
      "com.amazonaws.${local.region}.secretsmanager",
      "com.amazonaws.${local.region}.logs",
      var.kms_key_arn != "" || length(local.secret_kms_keys) > 0 || var.scripts.kms_key_arn != "" ? "com.amazonaws.${local.region}.kms" : "",
    ])
    gateway_endpoints               = ["com.amazonaws.${local.region}.s3"]
    endpoint_security_group_ingress = "443 from the bastion's security group (output.security_group_id) on the interface endpoints' security group"
    database_ingress = {
      for k, t in var.targets : k => (
        t.security_group_id != "" ?
        (var.manage_target_ingress ? "added by this module on ${t.security_group_id}, port ${t.port}" : "request: ${t.security_group_id} ingress tcp/${t.port} from the bastion's security group") :
        "request: tcp/${t.port} to ${t.host} from the bastion's subnet, through every firewall between the VPC and ${join(", ", t.cidr_blocks)}"
      )
    }
  }
}

output "kms_key_policy_requirements" {
  description = "What each customer-managed key's policy has to allow for this module to work. condition is the policy Condition block, as JSON."
  value = !local.create ? null : [
    for r in concat(
      [
        {
          key       = var.kms_key_arn
          for       = "the root volume"
          principal = "the EC2 service for this account (aws:SourceAccount ${local.account_id}), or the account root delegating to IAM"
          actions   = ["kms:CreateGrant", "kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKeyWithoutPlainText", "kms:ReEncrypt*"]
          condition = ""
        },
        {
          key       = var.kms_key_arn
          for       = "the run log group"
          principal = "Service: logs.${local.region}.amazonaws.com"
          actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
          condition = jsonencode({ ArnEquals = { "kms:EncryptionContext:aws:logs:arn" = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${local.log_group_name}" } })
        },
        {
          key       = var.scripts.kms_key_arn
          for       = "the scripts bucket"
          principal = "the instance role (output.role_arn)"
          actions   = ["kms:Decrypt"]
          condition = jsonencode({ StringEquals = { "kms:ViaService" = "s3.${local.region}.amazonaws.com" } })
        },
      ],
      [for key in local.secret_kms_keys : {
        key       = key
        for       = "the target secrets"
        principal = "the instance role (output.role_arn)"
        actions   = ["kms:Decrypt"]
        condition = jsonencode({ StringEquals = { "kms:ViaService" = "secretsmanager.${local.region}.amazonaws.com" } })
      }],
    ) : r if r.key != ""
  ]
}

output "operator_policy_json" {
  description = "An IAM policy for the people who run scripts: upload to the scripts prefix, run this document on this instance only, read results, open a session. Attach it to their role; the module attaches it to nobody."
  value = !local.create ? null : jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "RunThisDocumentOnThisInstance"
          Effect = "Allow"
          Action = ["ssm:SendCommand"]
          Resource = [
            "arn:${local.partition}:ssm:${local.region}:${local.account_id}:document/${local.run_document_name}",
            "arn:${local.partition}:ec2:${local.region}:${local.account_id}:instance/${aws_instance.this[0].id}",
          ]
        },
        {
          Sid    = "OpenASessionOnThisInstance"
          Effect = "Allow"
          Action = ["ssm:StartSession"]
          Resource = [
            "arn:${local.partition}:ec2:${local.region}:${local.account_id}:instance/${aws_instance.this[0].id}",
            "arn:${local.partition}:ssm:${local.region}::document/SSM-SessionManagerRunShell",
          ]
        },
        {
          Sid      = "EndOwnSessions"
          Effect   = "Allow"
          Action   = ["ssm:TerminateSession", "ssm:ResumeSession"]
          Resource = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:session/$${aws:userid}-*"]
        },
        {
          Sid    = "ReadResults"
          Effect = "Allow"
          Action = [
            "ssm:GetCommandInvocation", "ssm:ListCommands", "ssm:ListCommandInvocations",
            "ssm:DescribeInstanceInformation", "ssm:DescribeDocument", "ssm:GetDocument", "ssm:ListDocuments",
            "ec2:DescribeInstances",
          ]
          Resource = ["*"]
        },
        {
          Sid      = "ReadRunLogs"
          Effect   = "Allow"
          Action   = ["logs:GetLogEvents", "logs:FilterLogEvents", "logs:DescribeLogStreams"]
          Resource = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${local.log_group_name}:*"]
        },
        {
          Sid      = "UploadScripts"
          Effect   = "Allow"
          Action   = ["s3:PutObject", "s3:GetObject", "s3:GetObjectVersion"]
          Resource = ["arn:${local.partition}:s3:::${var.scripts.bucket_name}/${local.scripts_prefix}*"]
        },
        {
          Sid       = "ListScripts"
          Effect    = "Allow"
          Action    = ["s3:ListBucket"]
          Resource  = ["arn:${local.partition}:s3:::${var.scripts.bucket_name}"]
          Condition = { StringLike = { "s3:prefix" = ["${local.scripts_prefix}*"] } }
        },
      ],
      var.scripts.kms_key_arn == "" ? [] : [{
        Sid       = "EncryptScripts"
        Effect    = "Allow"
        Action    = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource  = [var.scripts.kms_key_arn]
        Condition = { StringEquals = { "kms:ViaService" = "s3.${local.region}.amazonaws.com" } }
      }],
    )
  })
}
