output "replication_instance_arn" {
  description = "ARN of the replication instance. null in serverless mode."
  value       = one(aws_dms_replication_instance.this[*].replication_instance_arn)
}

output "replication_instance_id" {
  description = "Identifier of the replication instance, which is also the CloudWatch dimension and the log group suffix."
  value       = one(aws_dms_replication_instance.this[*].replication_instance_id)
}

output "replication_instance_private_ips" {
  description = "Private IPs of the replication instance. These are what the source and target firewalls have to allow - for an on-prem source, this is the list your network team asks for."
  value       = try(aws_dms_replication_instance.this[0].replication_instance_private_ips, [])
}

output "replication_subnet_group_id" {
  description = "Identifier of the replication subnet group."
  value       = one(aws_dms_replication_subnet_group.this[*].replication_subnet_group_id)
}

output "serverless_replication_arns" {
  description = "ARN per serverless replication config, keyed by task name. Empty in provisioned mode."
  value       = { for k, r in aws_dms_replication_config.this : k => r.arn }
}

output "endpoint_arns" {
  description = "ARN per endpoint, keyed by the name you gave it. Includes S3 targets."
  value       = local.create ? local.endpoint_arns : {}
}

output "task_arns" {
  description = "ARN per replication task, keyed by the name you gave it. Empty in serverless mode."
  value       = { for k, t in aws_dms_replication_task.this : k => t.replication_task_arn }
}

output "task_ids" {
  description = "Full task identifier per task, which is what the CLI and the CloudWatch dimension use."
  value       = { for k, t in aws_dms_replication_task.this : k => t.replication_task_id }
}

output "certificate_arns" {
  description = "ARN per CA certificate this module uploaded, keyed by name. Endpoints reference these by certificate_key rather than by ARN."
  value       = { for k, c in aws_dms_certificate.this : k => c.certificate_arn }
}

output "endpoint_secret_role_arns" {
  description = "Role DMS assumes to read each endpoint's secret, keyed by endpoint. Supply your own with secret_access_role_arn to override."
  value       = local.create ? local.endpoint_secret_role_arns : {}
}

output "s3_target_role_arns" {
  description = "Role DMS assumes to write each S3 target, keyed by target."
  value       = local.create ? local.s3_target_role_arns : {}
}

output "log_group_name" {
  description = "CloudWatch log group DMS writes task logs to. Created here so retention applies before DMS writes; in serverless mode DMS names it after the replication config instead."
  value       = local.create && local.provisioned ? local.log_group_name : null
}

output "task_settings_json" {
  description = "The rendered replication task settings per task, as DMS receives them. Worth diffing in a change review: this is the JSON that decides whether validation runs, what happens to the target before the load, and how LOBs are handled."
  value       = local.create ? local.task_settings_json : {}
}

# ---------------------------------------------------------------------------
# Governance posture, as data
# ---------------------------------------------------------------------------
output "governance" {
  description = "The security and operational posture of this migration, as data rather than prose. Assert on it in tests, or diff it in a change review."
  value = !local.create ? null : {
    # Credentials and transport
    endpoints_with_plaintext_credentials = local.plaintext_endpoints
    endpoints_without_verified_tls       = local.insecure_endpoints
    endpoints_in_cleartext               = local.cleartext_endpoints
    endpoints_using_secrets_manager      = [for k, e in var.endpoints : k if e.secret_arn != ""]

    # Encryption
    customer_managed_key    = var.kms_key_arn != ""
    endpoints_without_cmk   = local.endpoints_without_cmk
    s3_targets_without_cmk  = local.s3_targets_without_cmk
    replication_storage_key = var.kms_key_arn != "" ? var.kms_key_arn : "aws-managed DMS key"

    # Compute
    compute_mode        = var.compute_mode
    multi_az            = local.provisioned ? var.multi_az : var.serverless.multi_az
    publicly_accessible = var.publicly_accessible
    engine_version      = var.engine_version != "" ? var.engine_version : "unpinned - AWS default"

    # Data handling. Every field here is computed from the MERGED task settings,
    # so a raw_overrides that disables validation shows up as disabled.
    tasks_deleting_target_data        = local.destructive_tasks
    tasks_without_validation          = local.unvalidated_tasks
    tasks_without_logging             = local.unlogged_tasks
    tasks_started_on_apply            = [for k, t in var.tasks : k if t.start]
    tasks_with_default_control_schema = local.tasks_with_default_control_schema
    tasks_with_truncating_lob_mode    = local.tasks_with_truncating_lob_mode
    tasks_with_raw_overrides = [
      for k, t in var.tasks : k if trimspace(t.settings.raw_overrides) != "{}"
    ]
    task_log_levels = { for k, t in var.tasks : k => t.settings.log_level }

    # Alerting. An unwatched CDC task is the failure mode this module is
    # shaped around.
    notifications_enabled = var.sns_topic_arn != ""
    alarms_enabled        = local.alarms_enabled
    # Serverless gets none of this module's observability, whatever the topic says.
    observability_covers_this_compute_mode = local.provisioned
    cdc_tasks                              = keys(local.cdc_tasks)
    log_retention_days                     = var.log_retention_days
  }
}

# ---------------------------------------------------------------------------
# What the SOURCE DATABASE has to do before any of this works
#
# None of it is reachable from Terraform, all of it fails at runtime rather than
# at apply, and every engine fails differently. So it is emitted as data - hand
# it to whoever owns the database.
# ---------------------------------------------------------------------------
output "source_prerequisites" {
  description = <<-EOT
    Per source engine, what the database owner has to change before CDC works.

    These are the failures that look like DMS problems and are not. A task whose
    source lacks supplemental logging connects, passes its test, runs the full
    load, and then either fails at CDC start or - worse - applies updates to the
    wrong rows.
  EOT
  value       = local.create ? local.source_prerequisites : {}
}

output "network_contract" {
  description = <<-EOT
    What the replication instance needs from YOUR network, as data.

    The module creates no network resources. In a VPC with no internet route a
    missing endpoint fails as a HANG or a connection timeout partway through a
    task, not as an error at apply.
  EOT
  value = !local.create ? null : {
    subnet_ids         = var.subnet_ids
    security_group_ids = var.security_group_ids

    required_interface_endpoints = local.required_interface_endpoints
    gateway_endpoints            = local.required_gateway_endpoints

    # Endpoints whose necessity depends on how DMS internally routes a call,
    # which cannot be determined from configuration. Cheap to add, and a hang
    # if they turn out to be needed and are missing.
    verify_in_your_account = [
      "monitoring (CloudWatch metrics) - if the replication instance publishes metrics through your VPC rather than service-side, its absence means the CDC latency alarms never receive a datapoint. Because those alarms treat missing data as breaching, they would sit in ALARM permanently rather than failing silently. Confirm with the verify_endpoint_coverage command before trusting them.",
      "s3 (gateway, free) - required for an S3 target, and harmless otherwise. Add it regardless: it costs nothing and removes a whole class of hang.",
    ]

    required_egress = concat(
      [for k, e in var.endpoints : "${e.role}: ${e.server_name != "" ? e.server_name : "<server_name unset>"}:${e.port != 0 ? e.port : 0} from the replication instance"],
      ["443 -> the interface endpoints above"],
    )

    required_ingress = [
      "none on the replication instance - DMS connects outbound to both databases",
      "on the SOURCE and TARGET: allow the replication instance's private IPs (output.replication_instance_private_ips) on the database port",
    ]

    notes = [
      "Interface endpoints need private DNS enabled, or DMS resolves the public name and the task hangs instead of erroring.",
      "The interface endpoints' own security groups must allow 443 INBOUND from the replication instance's security group. \"No ingress\" above refers to the replication instance, and is routinely misread as \"no ingress rules anywhere\".",
      "The replication instance needs a route to BOTH databases. A source in another VPC or on-premises means VPC peering, Transit Gateway, Cloud WAN or VPN - DMS has no other path.",
      "DNS: an on-premises source hostname must RESOLVE from inside the VPC. That means Route 53 Resolver outbound endpoints with forwarding rules to the on-prem resolvers, or a private hosted zone. A name that only resolves on-premises fails as a connection timeout that reads like a firewall problem.",
      "Return path: the on-premises side must route the VPC CIDR back over the same attachment. Asymmetric routing presents as a connection test that passes and a load that stalls part-way.",
      "Multi-AZ places an ENI in each subnet, so both AZs' subnets need the same routes - and the database-side firewall must allow BOTH addresses from output.replication_instance_private_ips, not just the first.",
      "This list is what the replication instance calls from inside your VPC. It deliberately does not include a dms endpoint: the instance is driven by the DMS control plane rather than calling it. Confirm against your own flow logs before signing off the VPC design - see the verify_endpoint_coverage command.",
    ]
  }
}

output "account_prerequisites" {
  description = "Account-wide IAM roles DMS requires, which this module does not create by default. Fixed names, one set per account - create them once in the landing zone."
  value = !local.create ? null : [
    {
      role    = "dms-vpc-role"
      policy  = "arn:${local.partition}:iam::aws:policy/service-role/AmazonDMSVPCManagementRole"
      created = var.create_account_service_roles
      why     = "DMS manages ENIs in your subnets through this. Missing: creating the replication subnet group fails, with an error naming neither the role nor the fix."
    },
    {
      role    = "dms-cloudwatch-logs-role"
      policy  = "arn:${local.partition}:iam::aws:policy/service-role/AmazonDMSCloudWatchLogsRole"
      created = var.create_account_service_roles
      why     = "Task logging needs it. Missing: tasks run, logging silently does nothing, and a failure has no detail behind it."
    },
  ]
}

# ---------------------------------------------------------------------------
# The migration as an ordered plan
#
# DMS owns one phase of three. This is the whole sequence, with the checksum of
# every script, so the change record can state what ran and in what order.
# ---------------------------------------------------------------------------
output "migration_plan" {
  description = "The full ordered migration: pre-data DDL, the DMS phases, post-data DDL, and the steps DMS cannot do. Hand this to whoever runs the pipeline; the module executes none of it."
  value = !local.create ? null : {
    phase_1_pre_data = {
      when    = "before the task is started, once"
      run_by  = "your pipeline - the module does not execute SQL"
      what    = "schemas, tables, types, sequences. The default target_table_prep_mode is DO_NOTHING, so DMS creates none of it."
      scripts = local.pre_data_scripts
      example = length(local.pre_data_scripts) > 0 ? "psql -h <target-host> -d <db> -v ON_ERROR_STOP=1 -f ${local.pre_data_scripts[0].path}" : "no pre_data scripts declared - see sql_scripts"
    }

    phase_2_load_and_cdc = {
      when   = "after pre-data completes"
      run_by = "DMS"
      what   = "full load, then change data capture until you stop it"
      start  = local.provisioned ? "aws dms start-replication-task --replication-task-arn <task-arn> --start-replication-task-type start-replication" : "aws dms start-replication --replication-config-arn <config-arn> --start-replication-type start-replication"
      # The one hook DMS does have, and what it is for.
      target_load_guard = {
        mechanism = "postgres_settings.after_connect_script on the TARGET endpoint"
        configured_on = [
          for k, e in var.endpoints : k
          if e.role == "target" && e.postgres.after_connect_script != ""
        ]
        suggested = "SET session_replication_role = replica;"
        why       = "runs on every connection DMS opens to the target, which is what stops triggers firing and foreign keys rejecting rows that arrive parent-last during a full load. Remember to put it back in post-data."
      }
    }

    phase_3_post_data = {
      when    = "after the full load completes and before cutover"
      run_by  = "your pipeline"
      what    = "indexes, foreign keys, constraints, triggers, grants - built after the data so the load is not paying for index maintenance, and so constraints are not rejecting rows that arrive out of order"
      scripts = local.post_data_scripts
      example = length(local.post_data_scripts) > 0 ? "psql -h <target-host> -d <db> -v ON_ERROR_STOP=1 -f ${local.post_data_scripts[0].path}" : "no post_data scripts declared - see sql_scripts"
    }

    phase_4_cutover = {
      when   = "after post-data, in the cutover window"
      run_by = "your pipeline, then a human"
      what = [
        "stop writes to the source",
        "wait for CDCLatencyTarget to reach ~0",
        "stop the forward task BEFORE the application writes anywhere",
        "reset sequences - DMS migrates rows, not sequence positions, and the first application insert otherwise fails on a duplicate key",
        "restore session_replication_role if after_connect_script changed it",
        "capture the evidence: table statistics, validation state, governance output",
        "repoint the application",
      ]
      detail = "see RUNBOOK.md section 6"
    }

    # Everything above, flattened, for a pipeline that wants one list.
    ordered_scripts = concat(local.pre_data_scripts, local.post_data_scripts)
  }
}

output "verify_commands" {
  description = "Copy-paste checks for what actually goes wrong, in the order you will need them. The cutover sequence is in RUNBOOK.md."
  value = !local.create ? null : {
    # Before anything: does DMS reach the databases at all. This is the check
    # that fails when the network contract was not met.
    test_connections   = local.provisioned ? "for e in ${join(" ", keys(var.endpoints))}; do aws dms test-connection --replication-instance-arn ${local.replication_instance_arn} --endpoint-arn $(aws dms describe-endpoints --filters Name=endpoint-id,Values=$e --query 'Endpoints[0].EndpointArn' --output text); done" : "serverless mode tests connections when the replication starts"
    connection_results = "aws dms describe-connections --filters Name=replication-instance-arn,Values=${local.replication_instance_arn} --query 'Connections[].[EndpointIdentifier,Status,LastFailureMessage]' --output table"

    task_status = local.provisioned ? "aws dms describe-replication-tasks --query 'ReplicationTasks[?starts_with(ReplicationTaskIdentifier, `${var.name}`)].[ReplicationTaskIdentifier,Status,ReplicationTaskStats.FullLoadProgressPercent,StopReason]' --output table" : "aws dms describe-replications --query 'Replications[].[ReplicationConfigIdentifier,Status,ReplicationStats]' --output table"

    # The number that decides whether you can cut over.
    cdc_latency = "aws cloudwatch get-metric-statistics --namespace AWS/DMS --metric-name CDCLatencyTarget --dimensions Name=ReplicationInstanceIdentifier,Value=${local.instance_id} --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) --period 300 --statistics Average --query 'sort_by(Datapoints,&Timestamp)[-6:].[Timestamp,Average]' --output table"

    # Validation is what turns "the task succeeded" into "the data matches".
    validation_state = "aws dms describe-table-statistics --replication-task-arn <task-arn> --query 'TableStatistics[?ValidationState!=`Validated`].[SchemaName,TableName,ValidationState,ValidationFailedRecords]' --output table"
    failed_tables    = "aws dms describe-table-statistics --replication-task-arn <task-arn> --query 'TableStatistics[?TableState!=`Table completed`].[SchemaName,TableName,TableState,Inserts,Updates,Deletes]' --output table"

    task_logs = local.provisioned ? "aws logs tail ${local.log_group_name} --since 1h --follow" : "aws logs describe-log-groups --log-group-name-prefix dms-serverless"

    # Run this after the first task starts. It answers two questions the module
    # cannot: whether DMS publishes the metric dimensions the alarms are built
    # on, and whether metrics reach CloudWatch at all from an isolated VPC.
    verify_endpoint_coverage = "aws cloudwatch list-metrics --namespace AWS/DMS --query 'Metrics[?MetricName==`CDCLatencyTarget`].Dimensions' --output json"

    # The one that stops the bill after cutover.
    stop_task             = local.provisioned ? "aws dms stop-replication-task --replication-task-arn <task-arn>" : "aws dms stop-replication --replication-config-arn <config-arn>"
    what_is_still_billing = "aws dms describe-replication-instances --query 'ReplicationInstances[].[ReplicationInstanceIdentifier,ReplicationInstanceClass,MultiAZ,ReplicationInstanceStatus]' --output table"
  }
}
