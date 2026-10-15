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
  description = "Task identifier (name) per task, which the CLI filters on. Empty in serverless mode."
  value       = { for k, t in aws_dms_replication_task.this : k => t.replication_task_id }
}

output "task_resource_ids" {
  description = "Task resource ID per task - the last segment of the task ARN. CloudWatch publishes task metrics under this, as the ReplicationTaskIdentifier dimension, not under the task name."
  value       = local.task_resource_ids
}

output "validation_task_arns" {
  description = "ARN per validation-only task, keyed by the name you gave it. Empty in serverless mode, where validation_tasks are refused."
  value       = { for k, t in aws_dms_replication_task.validation : k => t.replication_task_arn }
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
    tasks_deleting_target_data = local.destructive_tasks
    # DO_NOTHING: the target schema must exist before these start. The module
    # runs no SQL; this is the fact the pipeline that does is gated on.
    tasks_expecting_a_prebuilt_target = local.tasks_expecting_a_prebuilt_target
    tasks_without_validation          = local.unvalidated_tasks
    tasks_whose_validation_cannot_run = local.tasks_whose_validation_cannot_run
    validation_only_tasks             = { for k, v in var.validation_tasks : k => "${v.mode} of ${v.task}" }
    validation_alarms_enabled         = local.validation_alarms_enabled
    tasks_without_logging             = local.unlogged_tasks
    tasks_started_on_apply            = [for k, t in var.tasks : k if t.start]
    tasks_with_default_control_schema = local.tasks_with_default_control_schema
    tasks_with_truncating_lob_mode    = local.tasks_with_truncating_lob_mode
    tasks_with_raw_overrides = [
      for k, t in var.tasks : k if trimspace(t.settings.raw_overrides) != "{}"
    ]
    # Keys in raw_overrides that DMS does not document and would drop silently.
    tasks_with_unknown_task_settings = local.tasks_with_unknown_task_settings
    # What DMS runs with, from the merged settings - raw_overrides can replace
    # LogComponents, so the typed log_level alone would certify the wrong thing.
    task_log_levels = local.task_log_severities

    # Decisions taken in code. A reviewer reads this list, not the plan output.
    acknowledged_checks = sort(var.acknowledged_checks)

    # Alerting. An unwatched CDC task is the failure mode this module is
    # shaped around.
    notifications_enabled = var.sns_topic_arn != ""
    alarms_enabled        = local.alarms_enabled
    # Serverless gets none of this module's observability, whatever the topic says.
    observability_covers_this_compute_mode = local.provisioned
    cdc_tasks                              = keys(local.cdc_tasks)
    log_retention_days                     = var.log_retention_days
    # false means log_retention_days is applied to nothing: serverless, or
    # create_log_group = false, or 0. Read this before trusting the number.
    log_group_managed_by_module = local.log_group_managed
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
      # server_name and port are optional on the secret path; without them the
      # firewall request names the endpoint and says what is missing.
      [for k, e in var.endpoints : (
        e.server_name != "" && e.port != 0
        ? "${e.role}: ${e.server_name}:${e.port} from the replication instance"
        : "${e.role} ${k}: host and port are in its secret - set server_name and port on the endpoint so this request can name them"
      )],
      ["443 -> the interface endpoints above"],
    )

    required_ingress = [
      "none on the replication instance - DMS connects outbound to both databases",
      "on the SOURCE and TARGET: allow the replication instance's private IPs (output.replication_instance_private_ips) on the database port",
    ]

    notes = [
      "Interface endpoints need private DNS enabled, or DMS resolves the public name and the task hangs instead of erroring.",
      "The interface endpoints' subnets must be the replication subnet group's subnets (AWS DMS VPC endpoint documentation).",
      "Secrets Manager from a private subnet: if the secretsmanager endpoint's private DNS does not resolve from this VPC (a centralised endpoint in a hub VPC, or custom dns_name_servers), add the extra connection attribute secretsManagerEndpointOverride=<endpoint DNS name> to every endpoint with a secret - AWS's documented procedure. Otherwise the connection test times out and reads like a database problem.",
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
  value = !local.create ? null : concat([
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
    ], local.has_redshift_target ? [{
      role    = "dms-access-for-endpoint"
      policy  = "arn:${local.partition}:iam::aws:policy/service-role/AmazonDMSRedshiftS3Role"
      created = var.create_account_service_roles
      why     = "A Redshift target stages its load in S3 through this role. The console creates it; the API does not. Missing: the endpoint applies and the load fails."
      }] : [], local.serverless || var.premigration_assessment.enabled ? [{
      role    = "AWSServiceRoleForDMSServerless"
      policy  = "service-linked (AWS managed)"
      created = false
      why     = "DMS creates this service-linked role the first time a serverless replication or a premigration assessment starts - if the principal starting it may call iam:CreateServiceLinkedRole. Under an SCP that denies it, create it once in advance: aws iam create-service-linked-role --aws-service-name dms.amazonaws.com"
  }] : [])
}

output "verify_commands" {
  description = "Copy-paste checks for what actually goes wrong, in the order you will need them. cdc_latency, validation_state, failed_tables, start_task and stop_task are maps keyed by task name, with the real task ARN or resource ID filled in. The cutover sequence is in RUNBOOK.md."
  value = !local.create ? null : {
    # Before anything: does DMS reach the databases at all. This is the check
    # that fails when the network contract was not met.
    test_connections   = local.provisioned ? "for e in ${join(" ", keys(var.endpoints))}; do aws dms test-connection --replication-instance-arn ${local.replication_instance_arn} --endpoint-arn $(aws dms describe-endpoints --filters Name=endpoint-id,Values=$e --query 'Endpoints[0].EndpointArn' --output text); done" : "serverless mode tests connections when the replication starts"
    connection_results = "aws dms describe-connections --filters Name=replication-instance-arn,Values=${local.replication_instance_arn} --query 'Connections[].[EndpointIdentifier,Status,LastFailureMessage]' --output table"

    task_status = local.provisioned ? "aws dms describe-replication-tasks --query 'ReplicationTasks[?starts_with(ReplicationTaskIdentifier, `${var.name}`)].[ReplicationTaskIdentifier,Status,ReplicationTaskStats.FullLoadProgressPercent,StopReason]' --output table" : "aws dms describe-replications --query 'Replications[].[ReplicationConfigIdentifier,Status,ReplicationStats]' --output table"

    # The number that decides whether you can cut over.
    # Per task, with the exact dimension set the metric is published under -
    # instance name plus task resource ID. Anything less returns no datapoints.
    cdc_latency = {
      for k, id in local.task_resource_ids : k => "aws cloudwatch get-metric-statistics --namespace AWS/DMS --metric-name CDCLatencyTarget --dimensions Name=ReplicationInstanceIdentifier,Value=${local.instance_id} Name=ReplicationTaskIdentifier,Value=${id} --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) --period 300 --statistics Average --query 'sort_by(Datapoints,&Timestamp)[-6:].[Timestamp,Average]' --output table"
    }

    # Validation is what turns "the task succeeded" into "the data matches".
    validation_state = { for k, t in merge(aws_dms_replication_task.this, aws_dms_replication_task.validation) : k => "aws dms describe-table-statistics --replication-task-arn ${t.replication_task_arn} --query 'TableStatistics[?ValidationState!=`Validated`].[SchemaName,TableName,ValidationState,ValidationFailedRecords]' --output table" }
    failed_tables    = { for k, t in aws_dms_replication_task.this : k => "aws dms describe-table-statistics --replication-task-arn ${t.replication_task_arn} --query 'TableStatistics[?TableState!=`Table completed`].[SchemaName,TableName,TableState,Inserts,Updates,Deletes]' --output table" }

    task_logs = local.provisioned ? "aws logs tail ${local.log_group_name} --since 1h --follow" : "aws logs describe-log-groups --log-group-name-prefix dms-serverless"

    # Run this after the first task starts. It answers two questions the module
    # cannot: whether DMS publishes the metric dimensions the alarms are built
    # on, and whether metrics reach CloudWatch at all from an isolated VPC.
    verify_endpoint_coverage = "aws cloudwatch list-metrics --namespace AWS/DMS --query 'Metrics[?MetricName==`CDCLatencyTarget`].Dimensions' --output json"

    # Run when you start a task. A CDC alarm on a task that has never run is
    # already in ALARM (no data is breaching), and an alarm only notifies on a
    # state change - so a task that stalls before its first datapoint would
    # say nothing. Setting OK here re-arms it: no data within 15 minutes turns
    # it back to ALARM, and that change notifies.
    arm_alarms = {
      for k, t in local.cdc_tasks : k => "aws cloudwatch set-alarm-state --alarm-name ${var.name}-${k}-cdc-latency-target --state-value OK --state-reason 'task started' && aws cloudwatch set-alarm-state --alarm-name ${var.name}-${k}-cdc-latency-source --state-value OK --state-reason 'task started'"
    }

    # Starting is a change-controlled act, which is why start = false is the
    # default and the command is handed over rather than run. A validation-only
    # task starts the same way (its ARN is in validation_task_arns).
    start_task = local.provisioned ? { for k, t in aws_dms_replication_task.this : k => "aws dms start-replication-task --replication-task-arn ${t.replication_task_arn} --start-replication-task-type start-replication" } : { for k, c in aws_dms_replication_config.this : k => "aws dms start-replication --replication-config-arn ${c.arn} --start-replication-type start-replication" }

    # The one that stops the bill after cutover.
    stop_task             = local.provisioned ? { for k, t in aws_dms_replication_task.this : k => "aws dms stop-replication-task --replication-task-arn ${t.replication_task_arn}" } : { for k, c in aws_dms_replication_config.this : k => "aws dms stop-replication --replication-config-arn ${c.arn}" }
    what_is_still_billing = "aws dms describe-replication-instances --query 'ReplicationInstances[].[ReplicationInstanceIdentifier,ReplicationInstanceClass,MultiAZ,ReplicationInstanceStatus]' --output table"
  }
}

output "premigration_assessment" {
  description = "Premigration assessment per task: the command that starts one, the one that reports its status, where the report lands, and what the operator running them needs. null unless premigration_assessment.enabled. Run it before starting a task; attach the report to the change record."
  value = !local.assessment_enabled ? null : {
    role_arn   = local.assessment_role_arn
    bucket     = var.premigration_assessment.bucket_name
    folder     = var.premigration_assessment.bucket_folder
    encryption = local.assessment_encryption

    operator_permissions = [
      "dms:StartReplicationTaskAssessmentRun, dms:DescribeReplicationTaskAssessmentRuns, dms:DescribeReplicationTaskIndividualAssessments on the tasks",
      "iam:PassRole on ${local.assessment_role_arn}",
      "s3:GetObject on the folder, to read the report",
      "iam:CreateServiceLinkedRole for dms.amazonaws.com, once per account, unless AWSServiceRoleForDMSServerless already exists",
    ]

    commands = {
      for k, t in aws_dms_replication_task.this : k => {
        start  = "aws dms start-replication-task-assessment-run --replication-task-arn ${t.replication_task_arn} --service-access-role-arn ${local.assessment_role_arn} --result-location-bucket ${var.premigration_assessment.bucket_name} --result-location-folder ${var.premigration_assessment.bucket_folder}/${var.name}/${k} --result-encryption-mode ${local.assessment_encryption}${var.premigration_assessment.kms_key_arn != "" ? " --result-kms-key-arn ${var.premigration_assessment.kms_key_arn}" : ""} --assessment-run-name ${var.name}-${k}-$(date -u +%Y%m%d%H%M%S)"
        status = "aws dms describe-replication-task-assessment-runs --filters Name=replication-task-arn,Values=${t.replication_task_arn} --query 'ReplicationTaskAssessmentRuns[].[AssessmentRunName,Status,ResultStatistic]' --output table"
        report = "s3://${var.premigration_assessment.bucket_name}/${var.premigration_assessment.bucket_folder}/${var.name}/${k}/"
      }
    }
  }
}

output "deployer_requirements" {
  description = "Permissions the principal running Terraform (the one that creates the tasks) needs beyond managing these resources. Null when there are none."
  value = !local.create || length(local.tasks_validating_s3) == 0 ? null : {
    s3_target_validation = {
      tasks = local.tasks_validating_s3
      why   = "S3 target validation runs Athena CTAS queries over the written parquet, once a day at 00:00 UTC, as the principal that created the task (DMS S3 validation documentation). Without these the validation state errors and the evidence it was meant to produce does not exist."
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          { Effect = "Allow", Action = ["athena:StartQueryExecution", "athena:GetQueryExecution", "athena:CreateWorkGroup"], Resource = "*" },
          { Effect = "Allow", Action = ["glue:CreateDatabase", "glue:DeleteDatabase", "glue:GetDatabase", "glue:GetTables", "glue:CreateTable", "glue:DeleteTable", "glue:GetTable"], Resource = "*" },
          { Effect = "Allow", Action = ["s3:GetBucketLocation", "s3:GetObject", "s3:ListBucketMultipartUploads", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"], Resource = "*" },
        ]
      })
    }
  }
}

output "notification_requirements" {
  description = "What sns_topic_arn's access policy must allow, as policy statements. The module subscribes DMS events, CloudWatch alarms and (serverless) an EventBridge rule to the topic but does not own it. A topic that denies them drops every notification while the subscriptions show active."
  value = !local.create || var.sns_topic_arn == "" ? null : {
    topic = var.sns_topic_arn
    topic_policy_statements = concat(
      length(aws_dms_event_subscription.instance) + length(aws_dms_event_subscription.task) == 0 ? [] : [{
        Sid       = "DmsEventSubscriptions"
        Effect    = "Allow"
        Principal = { Service = "dms.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = var.sns_topic_arn
        Condition = { ArnLike = { "aws:SourceArn" = "arn:${local.partition}:dms:${local.region}:${local.account_id}:es:*" } }
      }],
      local.alarms_enabled ? [{
        Sid       = "CloudWatchAlarms"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = var.sns_topic_arn
        Condition = { ArnLike = { "aws:SourceArn" = "arn:${local.partition}:cloudwatch:${local.region}:${local.account_id}:alarm:${var.name}-*" } }
      }] : [],
      length(aws_cloudwatch_event_rule.serverless_failures) == 0 ? [] : [{
        Sid       = "EventBridgeServerlessFailures"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = var.sns_topic_arn
        Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.serverless_failures[0].arn } }
      }],
    )
    encrypted_topic = var.sns_topic_kms_key_arn == "" ? "if the topic uses SSE-KMS with a customer key, set sns_topic_kms_key_arn: kms_key_policy_requirements then lists what the key must allow" : "see output.kms_key_policy_requirements for ${var.sns_topic_kms_key_arn}"
    test            = "aws sns publish --topic-arn ${var.sns_topic_arn} --subject 'dms ${var.name}: test' --message 'notification path test' - proves the subscription end, not the publishers above"
  }
}

output "kms_key_policy_requirements" {
  description = "What each customer-managed key's policy has to allow for this migration to work. The module uses the keys but cannot write their policies - hand this to the key owner before the first apply. A missing CloudWatch Logs grant fails the log group create part way through the apply. Each entry carries the machine-readable fields sid, principals, actions, conditions (contract v2, compiled by modules/kms) alongside the prose fields."
  value = !local.create ? null : concat(
    # The services that publish to an SSE-KMS topic need the topic's key.
    # Without it SNS rejects the publish and nobody is told.
    var.sns_topic_kms_key_arn == "" ? [] : [{
      key = var.sns_topic_kms_key_arn
      principal = join(", ", concat(
        length(aws_dms_event_subscription.instance) + length(aws_dms_event_subscription.task) > 0 ? ["Service: dms.amazonaws.com"] : [],
        local.alarms_enabled ? ["Service: cloudwatch.amazonaws.com"] : [],
        length(aws_cloudwatch_event_rule.serverless_failures) > 0 ? ["Service: events.amazonaws.com"] : [],
      ))
      actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
      condition = {}
      why       = "the SNS topic is encrypted with this key; each service that publishes to it needs the key, or the notification is dropped."
      sid       = "SnsTopicPublishers"
      principals = {
        services = concat(
          length(aws_dms_event_subscription.instance) + length(aws_dms_event_subscription.task) > 0 ? ["dms.amazonaws.com"] : [],
          local.alarms_enabled ? ["cloudwatch.amazonaws.com"] : [],
          length(aws_cloudwatch_event_rule.serverless_failures) > 0 ? ["events.amazonaws.com"] : [],
        )
        arns  = []
        roles = []
      }
      conditions = []
      purpose    = "services publishing to the SSE-KMS SNS topic need the key, or notifications are dropped."
    }],
    var.kms_key_arn == "" ? [] : [{
      key       = var.kms_key_arn
      principal = "the principal running terraform"
      actions   = ["kms:CreateGrant", "kms:DescribeKey", "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*"]
      condition = { "kms:ViaService" = "dms.${local.region}.amazonaws.com" }
      why       = "DMS encrypts replication storage (cached changes, in-flight LOBs) and endpoint connection details with grants created on the caller's behalf."
      sid       = "ReplicationStorage"
      principals = {
        services = []
        arns     = []
        roles    = ["deployer"]
      }
      conditions = [{ test = "StringEquals", variable = "kms:ViaService", values = ["dms.${local.region}.amazonaws.com"] }]
      purpose    = "DMS encrypts replication storage and endpoint connection details through grants."
    }],
    [for key in distinct([for k, e in var.endpoints : e.kms_key_arn if e.kms_key_arn != "" && e.kms_key_arn != var.kms_key_arn]) : {
      key       = key
      principal = "the principal running terraform"
      actions   = ["kms:CreateGrant", "kms:DescribeKey", "kms:Encrypt", "kms:Decrypt"]
      condition = { "kms:ViaService" = "dms.${local.region}.amazonaws.com" }
      why       = "DMS encrypts the endpoint's connection details with this key."
      sid       = "EndpointConnection${substr(sha1(key), 0, 8)}"
      principals = {
        services = []
        arns     = []
        roles    = ["deployer"]
      }
      conditions = [{ test = "StringEquals", variable = "kms:ViaService", values = ["dms.${local.region}.amazonaws.com"] }]
      purpose    = "DMS encrypts endpoint connection details with this key."
    }],
    !(local.log_group_managed && var.kms_key_arn != "") ? [] : [{
      key       = var.kms_key_arn
      principal = "Service: logs.${local.region}.amazonaws.com"
      actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
      condition = { "ArnEquals kms:EncryptionContext:aws:logs:arn" = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${local.log_group_name}" }
      why       = "CloudWatch Logs encrypts the task log group with this key. Without the grant the log group create fails."
      sid       = "TaskLogGroup"
      principals = {
        services = ["logs.${local.region}.amazonaws.com"]
        arns     = []
        roles    = []
      }
      conditions = [{ test = "ArnEquals", variable = "kms:EncryptionContext:aws:logs:arn", values = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${local.log_group_name}"] }]
      purpose    = "CloudWatch Logs encrypts the task log group; without it the log group create fails."
    }],
    [for key in distinct([for k, e in var.endpoints : e.secret_kms_key_arn if e.secret_kms_key_arn != ""]) : {
      key       = key
      principal = join(", ", [for k, e in var.endpoints : local.endpoint_secret_role_arns[k] if e.secret_kms_key_arn == key])
      actions   = ["kms:Decrypt"]
      condition = { "kms:ViaService" = "secretsmanager.${local.region}.amazonaws.com" }
      why       = "DMS reads the endpoint secret through these roles. Needed in the key policy unless it delegates to IAM."
      sid       = "EndpointSecret${substr(sha1(key), 0, 8)}"
      principals = {
        services = []
        arns     = [for k, e in var.endpoints : local.endpoint_secret_role_arns[k] if e.secret_kms_key_arn == key]
        roles    = []
      }
      conditions = [{ test = "StringEquals", variable = "kms:ViaService", values = ["secretsmanager.${local.region}.amazonaws.com"] }]
      purpose    = "DMS reads the endpoint secrets through these roles."
    }],
    [for key in distinct([for k, s in var.s3_targets : s.kms_key_arn if s.encryption_mode == "SSE_KMS" && s.kms_key_arn != ""]) : {
      key       = key
      principal = join(", ", [for k, s in var.s3_targets : local.s3_target_role_arns[k] if s.kms_key_arn == key])
      actions   = ["kms:GenerateDataKey", "kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
      condition = { "kms:ViaService" = "s3.${local.region}.amazonaws.com" }
      why       = "DMS writes SSE-KMS objects to the target bucket through these roles."
      sid       = "S3Target${substr(sha1(key), 0, 8)}"
      principals = {
        services = []
        arns     = [for k, s in var.s3_targets : local.s3_target_role_arns[k] if s.kms_key_arn == key]
        roles    = []
      }
      conditions = [{ test = "StringEquals", variable = "kms:ViaService", values = ["s3.${local.region}.amazonaws.com"] }]
      purpose    = "DMS writes SSE-KMS objects to the target bucket through these roles."
    }],
    !local.assessment_enabled || var.premigration_assessment.kms_key_arn == "" ? [] : [{
      key       = var.premigration_assessment.kms_key_arn
      principal = local.assessment_role_arn
      actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
      condition = { "kms:ViaService" = "s3.${local.region}.amazonaws.com" }
      why       = "DMS writes the premigration assessment reports encrypted with this key."
      sid       = "PremigrationAssessment"
      principals = {
        services = []
        arns     = [local.assessment_role_arn]
        roles    = []
      }
      conditions = [{ test = "StringEquals", variable = "kms:ViaService", values = ["s3.${local.region}.amazonaws.com"] }]
      purpose    = "DMS writes the premigration assessment reports encrypted with this key."
    }],
  )
}
