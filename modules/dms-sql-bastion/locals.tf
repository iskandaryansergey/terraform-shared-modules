locals {
  create = var.create

  common_tags = merge(var.tags, {
    "ManagedBy" = "Terraform"
    "Module"    = "dms-sql-bastion"
    "Migration" = var.name
  })

  # Placeholders so ARN expressions still evaluate when create = false.
  partition  = coalesce(one(data.aws_partition.current[*].partition), "aws")
  region     = coalesce(one(data.aws_region.current[*].name), "us-east-1")
  account_id = coalesce(one(data.aws_caller_identity.current[*].account_id), "000000000000")

  # "" or "a/b/" - the script joins it to the key with nothing in between.
  scripts_prefix = var.scripts.prefix == "" ? "" : "${trimsuffix(var.scripts.prefix, "/")}/"

  engine_family = {
    postgres            = "postgres"
    "aurora-postgresql" = "postgres"
    mysql               = "mysql"
    mariadb             = "mysql"
    "aurora-mysql"      = "mysql"
    oracle              = "oracle"
  }

  # ssl_mode "" resolved per engine.
  targets = {
    for k, t in var.targets : k => merge(t, {
      family   = local.engine_family[t.engine]
      ssl_mode = t.ssl_mode != "" ? t.ssl_mode : (t.engine == "oracle" ? "none" : "verify-full")
    })
  }

  # Set by the runner itself; a target's env may not override them.
  reserved_env = [
    "PGPASSWORD", "PGUSER", "PGHOST", "PGPORT", "PGDATABASE", "PGSSLMODE", "PGSSLROOTCERT", "PGAPPNAME", "PGCONNECT_TIMEOUT",
    "DB_ENGINE", "DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD", "DB_SSL_MODE", "DB_CA_BUNDLE",
    "DB_MYSQL_DEFAULTS_FILE", "DMS_TARGET", "DMS_SCRIPTS_BUCKET", "DMS_SCRIPTS_PREFIX", "PATH", "HOME",
    "AWS_REGION", "AWS_DEFAULT_REGION",
  ]

  insecure_targets = [
    for k, t in local.targets : k
    if contains(["require", "disable"], t.ssl_mode)
  ]

  secret_arns     = distinct([for k, t in var.targets : t.secret_arn])
  secret_kms_keys = distinct([for k, t in var.targets : t.secret_kms_key_arn if t.secret_kms_key_arn != ""])

  # One egress rule per destination. Keys are stable strings so a reordered
  # list does not churn the rules.
  https_egress = merge(
    { for id in var.https_egress.security_group_ids : "https-${id}" => { security_group_id = id, prefix_list_id = null, cidr = null } },
    { for id in var.https_egress.prefix_list_ids : "https-${id}" => { security_group_id = null, prefix_list_id = id, cidr = null } },
    { for c in var.https_egress.cidr_blocks : "https-${c}" => { security_group_id = null, prefix_list_id = null, cidr = c } },
  )

  extra_egress = {
    for k, r in var.additional_egress_rules : k => merge(r, {
      security_group_id = r.security_group_id != "" ? r.security_group_id : null
      prefix_list_id    = r.prefix_list_id != "" ? r.prefix_list_id : null
      cidr              = r.cidr != "" ? r.cidr : null
    })
  }

  database_egress = merge(
    { for k, t in var.targets : "${k}-sg" => { port = t.port, security_group_id = t.security_group_id, cidr = null } if t.security_group_id != "" },
    merge([
      for k, t in var.targets : { for c in t.cidr_blocks : "${k}-${c}" => { port = t.port, security_group_id = null, cidr = c } }
    ]...),
  )

  target_ingress = var.manage_target_ingress ? {
    for k, t in var.targets : k => t if t.security_group_id != ""
  } : {}

  run_document_name = "${var.name}-run-sql"
  log_group_name    = "/dms-sql-bastion/${var.name}"

  # What the runner reads as config.json. Runbook steps keep their defaults
  # unresolved where the runner resolves them (type from the extension,
  # timeout from default_timeout_seconds), so a runbook and a manifest go
  # through the same code.
  runner_config = {
    scripts_bucket          = var.scripts.bucket_name
    scripts_prefix          = local.scripts_prefix
    default_timeout_seconds = var.default_timeout_seconds
    allow_shell_steps       = var.allow_shell_steps
    allow_s3_manifests      = var.allow_s3_manifests
    targets = {
      for k, t in local.targets : k => {
        family         = t.family
        host           = t.host
        port           = t.port
        database       = t.database
        secret_arn     = t.secret_arn
        ssl_mode       = t.ssl_mode
        ca_bundle_path = t.ca_bundle_path
        client_options = t.client_options
        env            = t.env
        variables      = t.variables
      }
    }
    runbooks = {
      for k, r in var.runbooks : k => {
        description = r.description
        steps = [
          for s in r.steps : merge(
            {
              target      = s.target
              script      = s.script
              transaction = s.transaction
              on_error    = s.on_error
              variables   = s.variables
            },
            s.name != "" ? { name = s.name } : {},
            s.sha256 != "" ? { sha256 = s.sha256 } : {},
            s.type != "" ? { type = s.type } : {},
            s.timeout_seconds != 0 ? { timeout_seconds = s.timeout_seconds } : {},
          )
        ]
      }
    }
  }

  runner_script = templatefile("${path.module}/scripts/launcher.sh.tftpl", {
    region      = local.region
    runner_py   = file("${path.module}/scripts/runner.py")
    config_json = jsonencode(local.runner_config)
  })

  send_command      = !local.create ? "" : "aws ssm send-command --document-name ${local.run_document_name} --instance-ids ${aws_instance.this[0].id}"
  send_command_tail = "--cloudwatch-output-config CloudWatchOutputEnabled=true,CloudWatchLogGroupName=${local.log_group_name} --query Command.CommandId --output text"

  # Every key as a regex alternation, for the document's allowedPattern.
  target_pattern  = "^$|^(${join("|", sort(keys(var.targets)))})$"
  runbook_pattern = length(var.runbooks) == 0 ? "^$" : "^$|^(${join("|", sort(keys(var.runbooks)))})$"
}
