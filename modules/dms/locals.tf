locals {
  create = var.create

  common_tags = merge(var.tags, {
    "ManagedBy" = "Terraform"
    "Module"    = "dms"
    "Migration" = var.name
  })

  # Placeholders so ARN expressions still evaluate when create = false.
  partition  = coalesce(one(data.aws_partition.current[*].partition), "aws")
  region     = coalesce(one(data.aws_region.current[*].name), "us-east-1")
  account_id = coalesce(one(data.aws_caller_identity.current[*].account_id), "000000000000")

  acknowledged = toset(var.acknowledged_checks)

  # A Redshift target stages through S3 with the fixed-name account role
  # dms-access-for-endpoint, which the API path never creates for you.
  has_redshift_target = anytrue([for k, e in var.endpoints : e.engine == "redshift" && e.role == "target"])

  required_account_roles = concat(
    ["dms-vpc-role", "dms-cloudwatch-logs-role"],
    local.has_redshift_target ? ["dms-access-for-endpoint"] : [],
  )

  provisioned = var.compute_mode == "provisioned"
  serverless  = var.compute_mode == "serverless"

  # DMS Serverless supports a subset of DMS Standard ("AWS DMS Serverless
  # components", supported endpoints): no SAP ASE at all, Db2 as a source only,
  # and ("AWS DMS Serverless limitations") no SSL on Db2 endpoints. A
  # replication on any of these applies cleanly and fails at Testing
  # Connection. Endpoint keys with the reason, for the precondition's message.
  endpoints_unsupported_by_serverless = concat(
    [for k, e in var.endpoints : "${k} (SAP ASE is not supported by DMS Serverless)" if e.engine == "sybase"],
    [for k, e in var.endpoints : "${k} (Db2 is a source only on DMS Serverless)" if contains(["db2", "db2-zos"], e.engine) ? e.role == "target" : false],
    [for k, e in var.endpoints : "${k} (DMS Serverless does not support SSL on Db2 endpoints)" if contains(["db2", "db2-zos"], e.engine) ? e.ssl_mode != "none" : false],
  )

  # -------------------------------------------------------------------------
  # Endpoints
  # -------------------------------------------------------------------------

  # Endpoints DMS reads a secret for. An empty secret_access_role_arn means we
  # make the role, scoped to that one secret.
  #
  # This map is a for_each, so its keys must be known at plan. secret_arn is
  # often not: the secret is created in the same configuration, and a filter on
  # it fails the plan with "Invalid for_each argument" (and fails a second
  # destroy once the secrets are gone). An endpoint is on the secret path
  # exactly when it carries no username (the variable allows one credential
  # source and requires one), which is static configuration.
  endpoints_with_secret = {
    for k, e in var.endpoints : k => e
    if e.username == "" && e.secret_access_role_arn == ""
  }

  # S3 targets DMS writes through a role. Same deal: supply one or get one
  # scoped to the bucket and prefix.
  s3_targets_needing_role = {
    for k, s in var.s3_targets : k => s if s.service_access_role_arn == ""
  }

  endpoint_secret_role_arns = {
    for k, e in var.endpoints : k => (
      e.secret_access_role_arn != ""
      ? e.secret_access_role_arn
      : try(aws_iam_role.endpoint_secret[k].arn, "")
    )
    if e.secret_arn != ""
  }

  s3_target_role_arns = {
    for k, s in var.s3_targets : k => (
      s.service_access_role_arn != ""
      ? s.service_access_role_arn
      : try(aws_iam_role.s3_target[k].arn, "")
    )
  }

  # Tasks address every endpoint by the same key space, so the two maps must not
  # collide - checked on the replication instance.
  # A module-created certificate is addressed by key, because feeding this
  # module's own output back into its input would be a cycle.
  endpoint_certificate_arns = {
    for k, e in var.endpoints : k => (
      e.certificate_key != ""
      ? try(aws_dms_certificate.this[e.certificate_key].certificate_arn, "")
      : e.certificate_arn
    )
  }

  # Eight hex characters of the content digest, part of the certificate id so
  # a rotated CA is a new certificate rather than an in-place replacement.
  # Callers often pass certificates as sensitive; the digest is not.
  certificate_digests = {
    for k, c in var.certificates : k => substr(sha256("${try(nonsensitive(c.pem), c.pem)}${try(nonsensitive(c.wallet), c.wallet)}"), 0, 8)
  }

  endpoint_arns = merge(
    { for k, e in aws_dms_endpoint.this : k => e.endpoint_arn },
    { for k, s in aws_dms_s3_endpoint.this : k => s.endpoint_arn },
  )

  endpoint_keys = concat(keys(var.endpoints), keys(var.s3_targets))

  duplicate_endpoint_keys = [
    for k in distinct(local.endpoint_keys) : k
    if length([for j in local.endpoint_keys : j if j == k]) > 1
  ]

  # -------------------------------------------------------------------------
  # Security posture, computed once and reused by preconditions and outputs
  # -------------------------------------------------------------------------

  plaintext_endpoints = [
    for k, e in var.endpoints : k if e.username != "" || e.password != ""
  ]

  insecure_endpoints = [
    for k, e in var.endpoints : k if contains(["none", "require"], e.ssl_mode)
  ]

  # Oracle verifies against a wallet; a PEM-only certificate is the usual slip.
  # Endpoint keys only, but computed from certificates, which a caller often
  # passes as sensitive: unwrapped so the check can name them.
  oracle_endpoints_with_pem = try(nonsensitive(local.oracle_endpoints_with_pem_raw), local.oracle_endpoints_with_pem_raw)
  oracle_endpoints_with_pem_raw = [
    for k, e in var.endpoints : k
    if e.engine == "oracle" && e.ssl_mode == "verify-ca" && e.certificate_key != "" && try(var.certificates[e.certificate_key].wallet, "") == ""
  ]

  cleartext_endpoints = [
    for k, e in var.endpoints : k if e.ssl_mode == "none"
  ]

  # An endpoint with no key of its own falls back to the instance key, which
  # falls back to the AWS-managed DMS key.
  endpoints_without_cmk = [
    for k, e in var.endpoints : k
    if e.kms_key_arn == "" && var.kms_key_arn == ""
  ]

  s3_targets_without_cmk = [
    for k, s in var.s3_targets : k
    if s.encryption_mode != "SSE_KMS" || s.kms_key_arn == ""
  ]

  # Read from the MERGED settings, never from the typed input. raw_overrides is
  # merged over the base, so a gate that reads var.tasks[*].settings reports a
  # posture the task does not have - and governance then certifies it. That is
  # worse than having no gate, because it manufactures audit evidence.
  destructive_tasks = [
    for k, t in var.tasks : k
    if contains(["DROP_AND_CREATE", "TRUNCATE_BEFORE_LOAD"],
    try(local.task_settings_merged[k].FullLoadSettings.TargetTablePrepMode, "DO_NOTHING"))
  ]

  unvalidated_tasks = [
    for k, t in var.tasks : k
    if !try(local.task_settings_merged[k].ValidationSettings.EnableValidation, true)
  ]

  # Severity per task, from the MERGED settings: raw_overrides replaces
  # LogComponents wholesale, so the typed log_level is not what DMS runs with.
  task_log_severities = {
    for k, t in var.tasks : k => distinct([
      for c in try(local.task_settings_merged[k].Logging.LogComponents, []) : try(c.Severity, "LOGGER_SEVERITY_DEFAULT")
    ])
  }

  debug_logging_tasks = [
    for k, sev in local.task_log_severities : k
    if length(setintersection(toset(sev), toset(["LOGGER_SEVERITY_DEBUG", "LOGGER_SEVERITY_DETAILED_DEBUG"]))) > 0
  ]

  # Task IDs DMS uses in CloudWatch: the resource ID at the end of the task
  # ARN, not the task name.
  task_resource_ids = {
    for k, t in aws_dms_replication_task.this : k => element(split(":", t.replication_task_arn), 6)
  }

  unlogged_tasks = [
    for k, t in var.tasks : k
    if !try(local.task_settings_merged[k].Logging.EnableLogging, true)
  ]

  # Surfaced so a reviewer can see where DMS writes its exception rows, which
  # contain source data. Empty means the target's default schema.
  tasks_with_default_control_schema = [
    for k, t in var.tasks : k
    if try(local.task_settings_merged[k].ControlTablesSettings.ControlSchema, "") == ""
  ]

  # LIMITED silently truncates past LobMaxSize. In a banking record that is a
  # data defect nobody sees until a report disagrees with the source.
  tasks_with_truncating_lob_mode = [
    for k, t in var.tasks : k
    if try(local.task_settings_merged[k].TargetMetadata.LimitedSizeLobMode, false)
  ]

  # DMS does not support full LOB mode for an S3 target (INLINE is full LOB
  # mode with a threshold). Read from the merged settings.
  # "BatchApply is not supported for an S3 endpoint ... might result in loss of
  # data" (DMS S3 target documentation).
  tasks_with_batch_apply_to_s3 = [
    for k, t in var.tasks : k
    if contains(keys(var.s3_targets), t.target_endpoint) && try(local.task_settings_merged[k].TargetMetadata.BatchApplyEnabled, false)
  ]

  # S3 target validation runs Athena queries as the principal that created the
  # task - the Terraform role here, not the endpoint's role.
  tasks_validating_s3 = [
    for k, t in var.tasks : k
    if contains(keys(var.s3_targets), t.target_endpoint) && try(local.task_settings_merged[k].ValidationSettings.EnableValidation, false)
  ]

  tasks_with_full_lob_to_s3 = [
    for k, t in var.tasks : k
    if contains(keys(var.s3_targets), t.target_endpoint) && try(local.task_settings_merged[k].TargetMetadata.FullLobMode, false)
  ]

  # -------------------------------------------------------------------------
  # Data validation
  #
  # DMS validates only these engines (DMS user guide, "AWS DMS data
  # validation"); anywhere else EnableValidation = true is accepted and does
  # nothing, so a governance field that trusted the flag would certify a
  # reconciliation that never happens.
  # -------------------------------------------------------------------------

  validation_source_engines = ["oracle", "postgres", "aurora-postgresql", "mysql", "mariadb", "aurora", "sqlserver", "db2"]
  validation_target_engines = concat(local.validation_source_engines, ["redshift"])

  # An S3 target validates only from parquet, with a timestamp column and a
  # date partition that has a day component.
  s3_targets_validatable = {
    for k, s in var.s3_targets : k => (
      s.data_format == "parquet" && s.timestamp_column_name != "" && s.date_partition_enabled && strcontains(s.date_partition_sequence, "DD")
    )
  }

  task_validation_feasible = {
    for k, t in var.tasks : k => (
      contains(local.validation_source_engines, try(var.endpoints[t.source_endpoint].engine, "")) && (
        contains(keys(var.s3_targets), t.target_endpoint)
        ? try(local.s3_targets_validatable[t.target_endpoint], false)
        : contains(local.validation_target_engines, try(var.endpoints[t.target_endpoint].engine, ""))
      )
    )
  }

  tasks_whose_validation_cannot_run = [
    for k, t in var.tasks : k
    # A task naming a missing endpoint, or one in the wrong direction, is
    # refused on its own; it is not also reported here.
    if contains(concat(local.tasks_with_unknown_endpoints, local.tasks_with_wrong_direction), k) ? false : (try(local.task_settings_merged[k].ValidationSettings.EnableValidation, false) ? !local.task_validation_feasible[k] : false)
  ]

  validation_tasks_with_bad_parent = concat(
    [for k, v in var.validation_tasks : "${k} (cdc mode needs a parent that reads changes)" if v.mode == "cdc" && !contains(["cdc", "full-load-and-cdc"], try(var.tasks[v.task].migration_type, ""))],
    [for k, v in var.validation_tasks : "${k} (DMS cannot validate ${v.task}'s source or target)" if !try(local.task_validation_feasible[v.task], false)],
    [for k, v in var.validation_tasks : "${k} (same key as a task)" if contains(keys(var.tasks), k)],
  )

  # The parent's merged settings, made safe and turned into a validator: it
  # never prepares the target, whatever the parent does to it.
  validation_task_settings_json = {
    for k, v in var.validation_tasks : k => jsonencode(merge(try(local.task_settings_merged[v.task], {}), {
      FullLoadSettings = merge(try(local.task_settings_merged[v.task].FullLoadSettings, {}), {
        TargetTablePrepMode = "DO_NOTHING"
      })
      ValidationSettings = merge(try(local.task_settings_merged[v.task].ValidationSettings, {}), {
        EnableValidation     = true
        ValidationOnly       = true
        ThreadCount          = v.threads
        FailureMaxCount      = v.failure_max
        TableFailureMaxCount = v.table_failure_max
      })
    }))
  }

  # A task referring to an endpoint key that does not exist. Terraform would
  # otherwise report this as a confusing map lookup failure.
  tasks_with_unknown_endpoints = [
    for k, t in var.tasks : k
    if !contains(local.endpoint_keys, t.source_endpoint) || !contains(local.endpoint_keys, t.target_endpoint)
  ]

  # Direction has to line up: a task cannot read from a target-role endpoint.
  # An s3_targets key is not in var.endpoints, so try() would fall back to
  # "source" and wave it through - an S3 endpoint is target-only by construction.
  tasks_with_wrong_direction = [
    for k, t in var.tasks : k
    if contains(keys(var.s3_targets), t.source_endpoint) ||
    try(var.endpoints[t.source_endpoint].role, "source") != "source" ||
    try(var.endpoints[t.target_endpoint].role, "target") != "target"
  ]

  # -------------------------------------------------------------------------
  # Task settings
  #
  # DMS accepts this as JSON and ignores keys it does not recognise, without
  # error. So it is built here from typed inputs rather than handed over as a
  # string, and anything merged on top goes through tests/lint_task_settings.py.
  # -------------------------------------------------------------------------

  # The components worth having in the log. Everything else is noise until you
  # are debugging, and DEBUG on all of them fills a log group fast.
  #
  # VALIDATOR_EXT, not VALIDATOR: it is the id DMS stores and returns (AWS
  # "Saving task settings" example; the provider's acceptance-test settings
  # round-trip it). A component DMS drops would show as a diff on every plan,
  # and every applied diff stops a running task.
  log_components = ["SOURCE_UNLOAD", "SOURCE_CAPTURE", "TARGET_LOAD", "TARGET_APPLY", "TASK_MANAGER", "VALIDATOR_EXT"]

  task_settings_base = {
    for k, t in var.tasks : k => {
      TargetMetadata = {
        TargetSchema = ""
        SupportLobs  = t.settings.lob_mode != "NONE"
        # INLINE is FullLobMode plus a threshold: DMS only reads InlineLobMaxSize
        # when FullLobMode is true. Rendering INLINE with FullLobMode = false
        # made DMS drop the setting and fall back to default LOB handling.
        FullLobMode              = contains(["FULL", "INLINE"], t.settings.lob_mode)
        LobChunkSize             = t.settings.lob_chunk_size_kb
        LimitedSizeLobMode       = t.settings.lob_mode == "LIMITED"
        LobMaxSize               = t.settings.lob_mode == "LIMITED" ? t.settings.lob_max_size_kb : 0
        InlineLobMaxSize         = t.settings.lob_mode == "INLINE" ? t.settings.lob_max_size_kb : 0
        LoadMaxFileSize          = 0
        ParallelLoadThreads      = t.settings.parallel_load_threads
        ParallelLoadBufferSize   = 0
        BatchApplyEnabled        = t.settings.batch_apply_enabled
        TaskRecoveryTableEnabled = t.settings.task_recovery_table
      }

      FullLoadSettings = {
        TargetTablePrepMode             = t.settings.target_table_prep_mode
        CreatePkAfterFullLoad           = false
        StopTaskCachedChangesApplied    = t.settings.stop_after_full_load
        StopTaskCachedChangesNotApplied = t.settings.stop_before_cached_changes
        MaxFullLoadSubTasks             = t.settings.max_full_load_subtasks
        TransactionConsistencyTimeout   = t.settings.transaction_consistency_timeout
        CommitRate                      = t.settings.commit_rate
      }

      Logging = {
        EnableLogging = t.settings.logging_enabled
        LogComponents = [
          for c in local.log_components : {
            Id       = c
            Severity = t.settings.log_level
          }
        ]
      }

      ControlTablesSettings = {
        ControlSchema               = t.settings.control_schema
        HistoryTimeslotInMinutes    = 5
        StatusTableEnabled          = true
        SuspendedTablesTableEnabled = true
        HistoryTableEnabled         = true
      }

      # Validation is the audit evidence that the target matches the source, so
      # the knobs that decide whether it survives are typed rather than fixed.
      #
      # HandleCollationDiff matters on Oracle -> PostgreSQL specifically: if the
      # target's primary-key collation is not "C", sort order differs, validation
      # reports false mismatches, and at FailureMaxCount it SUSPENDS itself. The
      # evidence then quietly does not exist.
      ValidationSettings = merge(
        {
          EnableValidation     = t.settings.validation_enabled
          ThreadCount          = t.settings.validation_threads
          FailureMaxCount      = t.settings.validation_failure_max
          TableFailureMaxCount = t.settings.validation_table_failure_max
          HandleCollationDiff  = t.settings.handle_collation_diff
          ValidationOnly       = false
        },
        # Omitted unless asked for: from engine 3.5.4 DMS picks GROUP_LEVEL
        # itself on supported paths, and hardcoding ROW_LEVEL overrides that.
        t.settings.validation_mode != "" ? { ValidationMode = t.settings.validation_mode } : {},
      )

      # With batch apply on, a data or apply error under LOG_ERROR switches the
      # task to one-by-one apply for the rest of its life - CDC latency climbs
      # and nothing fails. SUSPEND_TABLE confines the damage to the one table,
      # as the DMS TargetMetadata documentation recommends.
      ErrorBehavior = {
        DataErrorPolicy               = t.settings.batch_apply_enabled ? "SUSPEND_TABLE" : "LOG_ERROR"
        DataTruncationErrorPolicy     = "LOG_ERROR"
        DataErrorEscalationPolicy     = "SUSPEND_TABLE"
        DataErrorEscalationCount      = 0
        TableErrorPolicy              = "SUSPEND_TABLE"
        TableErrorEscalationPolicy    = "STOP_TASK"
        TableErrorEscalationCount     = t.settings.table_error_max
        RecoverableErrorCount         = -1
        RecoverableErrorInterval      = 5
        RecoverableErrorThrottling    = true
        RecoverableErrorThrottlingMax = 1800
        ApplyErrorDeletePolicy        = t.settings.batch_apply_enabled ? "SUSPEND_TABLE" : "IGNORE_RECORD"
        ApplyErrorInsertPolicy        = t.settings.batch_apply_enabled ? "SUSPEND_TABLE" : "LOG_ERROR"
        ApplyErrorUpdatePolicy        = t.settings.batch_apply_enabled ? "SUSPEND_TABLE" : "LOG_ERROR"
        # apply_error_max only means something with a policy that acts on it:
        # under LOG_ERROR reaching the count changes nothing.
        ApplyErrorEscalationPolicy = t.settings.apply_error_max > 0 ? "STOP_TASK" : "LOG_ERROR"
        ApplyErrorEscalationCount  = t.settings.apply_error_max
        FullLoadIgnoreConflicts    = true
        # The runtime half of the "selection rule matched nothing" trap: without
        # this the task starts, captures no tables, and reports success.
        FailOnNoTablesCaptured               = true
        FailOnTransactionConsistencyBreached = t.settings.fail_on_open_transaction
      }

      ChangeProcessingDdlHandlingPolicy = {
        HandleSourceTableDropped   = true
        HandleSourceTableTruncated = true
        HandleSourceTableAltered   = true
      }
    }
  }

  task_settings_overrides = {
    for k, t in var.tasks : k => jsondecode(t.settings.raw_overrides)
  }

  # Every task-settings section and key the DMS user guide documents
  # ("Specifying task settings", one page per section). DMS ignores anything
  # else without a word, so raw_overrides is checked against this list at plan
  # (check raw_overrides_use_known_task_settings). An empty list means the
  # section's content is free-form (a list, a scalar, or undocumented keys).
  # tests/lint_task_settings.py carries the same list and fails when the two
  # drift - edit both, between the begin/end markers.
  # known_task_settings:begin
  known_task_settings = {
    TargetMetadata = [
      "TargetSchema", "SupportLobs", "FullLobMode", "LobChunkSize", "LimitedSizeLobMode",
      "LobMaxSize", "InlineLobMaxSize", "LoadMaxFileSize", "ParallelLoadThreads",
      "ParallelLoadBufferSize", "ParallelLoadQueuesPerThread", "ParallelApplyThreads",
      "ParallelApplyBufferSize", "ParallelApplyQueuesPerThread", "BatchApplyEnabled",
      "TaskRecoveryTableEnabled", "UseCsvNoSupValue", "CsvNoSupValue",
    ]
    FullLoadSettings = [
      "TargetTablePrepMode", "CreatePkAfterFullLoad", "StopTaskCachedChangesApplied",
      "StopTaskCachedChangesNotApplied", "MaxFullLoadSubTasks", "TransactionConsistencyTimeout",
      "CommitRate", "ParallelLoadThreads",
    ]
    Logging = [
      "EnableLogging", "EnableLogContext", "LogComponents", "CloudWatchLogGroup",
      "CloudWatchLogStream", "DeleteTaskLogs",
    ]
    ControlTablesSettings = [
      "ControlSchema", "HistoryTimeslotInMinutes", "StatusTableEnabled",
      "SuspendedTablesTableEnabled", "HistoryTableEnabled", "FullLoadExceptionTableEnabled",
      "CommitPositionTableEnabled",
    ]
    ValidationSettings = [
      "EnableValidation", "ValidationMode", "ThreadCount", "FailureMaxCount",
      "TableFailureMaxCount", "HandleCollationDiff", "ValidationOnly",
      "RecordFailureDelayInMinutes", "RecordSuspendDelayInMinutes",
      "RecordFailureDelayLimitInMinutes", "SkipLobColumns", "ValidationPartialLobSize",
      "ValidationQueryCdcDelaySeconds", "PartitionSize", "MaxKeyColumnSize",
    ]
    ResyncSettings = ["EnableResync", "ResyncSchedule", "MaxResyncTime", "ValidationTaskId"]
    ErrorBehavior = [
      "DataErrorPolicy", "DataTruncationErrorPolicy", "DataMaskingErrorPolicy",
      "DataErrorEscalationPolicy", "DataErrorEscalationCount", "TableErrorPolicy",
      "TableErrorEscalationPolicy", "TableErrorEscalationCount", "RecoverableErrorCount",
      "RecoverableErrorInterval", "RecoverableErrorThrottling", "RecoverableErrorThrottlingMax",
      "RecoverableErrorStopRetryAfterThrottlingMax", "ApplyErrorDeletePolicy",
      "ApplyErrorInsertPolicy", "ApplyErrorUpdatePolicy", "ApplyErrorEscalationPolicy",
      "ApplyErrorEscalationCount", "ApplyErrorFailOnTruncationDdl", "FullLoadIgnoreConflicts",
      "FailOnTransactionConsistencyBreached", "FailOnNoTablesCaptured", "EventErrorPolicy",
    ]
    ChangeProcessingTuning = [
      "BatchApplyPreserveTransaction", "BatchApplyTimeoutMin", "BatchApplyTimeoutMax",
      "BatchApplyMemoryLimit", "BatchSplitSize", "MinTransactionSize", "CommitTimeout",
      "MemoryLimitTotal", "MemoryKeepTime", "StatementCacheSize", "RecoveryTimeout",
    ]
    ChangeProcessingDdlHandlingPolicy = [
      "HandleSourceTableDropped", "HandleSourceTableTruncated", "HandleSourceTableAltered",
    ]
    StreamBufferSettings       = ["StreamBufferCount", "StreamBufferSizeInMB", "CtrlStreamBufferSizeInMB"]
    CharacterSetSettings       = ["CharacterReplacements", "CharacterSetSupport"]
    BeforeImageSettings        = ["EnableBeforeImage", "FieldName", "ColumnFilter"]
    LoopbackPreventionSettings = ["EnableLoopbackPrevention", "SourceSchema", "TargetSchema"]
    TTSettings = [
      "EnableTT", "TTS3Settings", "TTRecordSettings", "EncryptionMode",
      "ServerSideEncryptionKmsKeyId", "ServiceAccessRoleArn", "BucketName", "BucketFolder",
      "EnableDeletingFromS3OnTaskDelete", "EnableRawData", "RawDataFormat", "OperationsToLog",
      "MaxRecordSize",
    ]
    PostProcessingRules                 = []
    FailTaskWhenCleanTaskResourceFailed = []
  }
  # known_task_settings:end

  # -------------------------------------------------------------------------
  # Table mappings
  #
  # DMS rejects a malformed rule at task creation - after the plan was approved
  # - and applies some well-formed ones to nothing. The values below are the
  # DMS table-mapping documentation (selection, transformation and
  # table-settings rules); tests/lint_task_settings.py carries the same lists
  # and fails when they drift.
  # -------------------------------------------------------------------------

  # known_mapping_rules:begin
  known_mapping_rules = {
    rule_types        = ["selection", "transformation", "table-settings", "object-mapping"]
    selection_actions = ["include", "exclude", "explicit"]
    transformation_actions = [
      "add-column", "include-column", "remove-column", "rename", "convert-lowercase",
      "convert-uppercase", "add-prefix", "remove-prefix", "replace-prefix", "add-suffix",
      "remove-suffix", "replace-suffix", "define-primary-key", "change-data-type",
      "add-before-image-columns", "data-masking-digits-mask", "data-masking-digits-randomize",
      "data-masking-hash-mask",
    ]
    transformation_targets = ["schema", "table", "column", "table-tablespace", "index-tablespace"]
    column_only_actions = [
      "change-data-type", "data-masking-digits-mask", "data-masking-digits-randomize",
      "data-masking-hash-mask",
    ]
    parallel_load_types = ["partitions-auto", "subpartitions-auto", "partitions-list", "ranges", "none"]
    lob_modes           = ["limited", "unlimited", "none"]
  }
  # known_mapping_rules:end

  # The rules of every task, as objects only. Anything the validations on
  # var.tasks already refuse (not JSON, no rules array) comes out empty here so
  # nothing below can throw. try(), not a conditional: rules of different
  # shapes are a tuple with no single element type, and a conditional would
  # demand one. Every string field is read null-safe: a missing or null value
  # is "", and the rule is judged on that.
  mapping_rules = {
    for k, t in var.tasks : k => [
      for r in try([for r in jsondecode(t.table_mappings).rules : r if can(keys(r))], []) : {
        id           = try(trimspace(tostring(r["rule-id"])), "?")
        name         = try(trimspace(tostring(r["rule-name"])), "")
        type         = try(trimspace(tostring(r["rule-type"])), "")
        action       = try(trimspace(tostring(r["rule-action"])), "")
        target       = try(trimspace(tostring(r["rule-target"])), "")
        has_locator  = can(keys(r["object-locator"]))
        schema       = try(trimspace(tostring(r["object-locator"]["schema-name"])), "")
        table        = try(trimspace(tostring(r["object-locator"]["table-name"])), "")
        has_pl       = can(keys(r["parallel-load"]))
        pl_type      = try(trimspace(tostring(r["parallel-load"]["type"])), "")
        pl_cols      = can(r["parallel-load"]["columns"][0])
        pl_bounds    = can(r["parallel-load"]["boundaries"][0])
        pl_parts     = can(r["parallel-load"]["partitions"][0])
        pl_subparts  = can(r["parallel-load"]["subpartitions"][0])
        has_lob      = can(keys(r["lob-settings"]))
        lob_mode     = try(trimspace(tostring(r["lob-settings"]["mode"])), "limited")
        lob_max_size = try(tonumber(r["lob-settings"]["bulk-max-size"]), 0)
      }
    ]
  }

  # Nested ternaries throughout: the floor evaluates both operands of && and ||.
  mapping_problems_all = {
    for k, rules in local.mapping_rules : k => concat(
      [for r in rules : "rule ${r.id}: rule-id must be a numeric value" if !can(regex("^[0-9]+$", r.id))],
      [for r in rules : "rule ${r.id}: rule-name is required" if r.name == ""],
      [for r in rules : "rule ${r.id}: rule-type \"${r.type}\" is not one of ${join(", ", local.known_mapping_rules.rule_types)}" if !contains(local.known_mapping_rules.rule_types, r.type)],

      [for r in rules : "rule ${r.id}: a selection rule-action is include, exclude or explicit, not \"${r.action}\"" if r.type == "selection" ? !contains(local.known_mapping_rules.selection_actions, r.action) : false],
      [for r in rules : "rule ${r.id}: a selection rule needs object-locator.schema-name and table-name" if r.type == "selection" ? (r.schema == "" ? true : r.table == "") : false],
      [for r in rules : "rule ${r.id}: explicit selects one exact table, so % is not allowed in its names" if r.type == "selection" ? (r.action == "explicit" ? strcontains("${r.schema}${r.table}", "%") : false) : false],

      [for r in rules : "rule ${r.id}: transformation rule-action \"${r.action}\" is not one DMS documents" if r.type == "transformation" ? !contains(local.known_mapping_rules.transformation_actions, r.action) : false],
      [for r in rules : "rule ${r.id}: transformation rule-target must be one of ${join(", ", local.known_mapping_rules.transformation_targets)}, not \"${r.target}\"" if r.type == "transformation" ? !contains(local.known_mapping_rules.transformation_targets, r.target) : false],
      [for r in rules : "rule ${r.id}: a transformation needs an object-locator" if r.type == "transformation" ? !r.has_locator : false],
      [for r in rules : "rule ${r.id}: ${r.action} applies to rule-target column only" if r.type == "transformation" ? (contains(local.known_mapping_rules.column_only_actions, r.action) ? r.target != "column" : false) : false],
      [for r in rules : "rule ${r.id}: define-primary-key cannot use % in schema-name or table-name" if r.type == "transformation" ? (r.action == "define-primary-key" ? strcontains("${r.schema}${r.table}", "%") : false) : false],

      [for r in rules : "rule ${r.id}: table-settings need an exact schema-name and table-name, no %" if r.type == "table-settings" ? (strcontains("${r.schema}${r.table}", "%") ? true : (r.schema == "" ? true : r.table == "")) : false],
      [for r in rules : "rule ${r.id}: parallel-load.type \"${r.pl_type}\" is not one of ${join(", ", local.known_mapping_rules.parallel_load_types)}" if r.type == "table-settings" ? (r.has_pl ? !contains(local.known_mapping_rules.parallel_load_types, r.pl_type) : false) : false],
      [for r in rules : "rule ${r.id}: parallel-load type ranges needs columns and boundaries" if r.type == "table-settings" ? (r.pl_type == "ranges" ? (r.pl_cols ? !r.pl_bounds : true) : false) : false],
      [for r in rules : "rule ${r.id}: parallel-load type partitions-list needs partitions or subpartitions" if r.type == "table-settings" ? (r.pl_type == "partitions-list" ? (r.pl_parts ? false : !r.pl_subparts) : false) : false],
      [for r in rules : "rule ${r.id}: lob-settings.mode \"${r.lob_mode}\" is not limited, unlimited or none" if r.type == "table-settings" ? (r.has_lob ? !contains(local.known_mapping_rules.lob_modes, r.lob_mode) : false) : false],
      [for r in rules : "rule ${r.id}: lob-settings in limited mode (the default) need a non-zero bulk-max-size; zero is invalid and every LOB would be truncated to nothing" if r.type == "table-settings" ? (r.has_lob ? (r.lob_mode == "limited" ? r.lob_max_size <= 0 : false) : false) : false],

      length(distinct([for r in rules : r.name])) == length(rules) ? [] : ["rule-name values must be unique"],
      length([for r in rules : r if r.type == "selection"]) == 0 ? [] : (
        length([for r in rules : r if r.type == "selection" ? contains(["include", "explicit"], r.action) : false]) == 0
        ? ["every selection rule is an exclude, so nothing is included and the task migrates nothing"] : []
      ),
    )
  }

  mapping_problems = { for k, v in local.mapping_problems_all : k => v if length(v) > 0 }

  # Per task, the raw_overrides entries DMS would silently drop: unknown
  # sections, and unknown keys inside sections whose keys are documented.
  # Nested ternaries, not || - the floor evaluates both operands.
  tasks_with_unknown_task_settings = {
    for k, t in var.tasks : k => flatten([
      for section, body in local.task_settings_overrides[k] :
      !contains(keys(local.known_task_settings), section) ? ["${section} (unknown section)"] : (
        length(local.known_task_settings[section]) == 0 ? [] : (
          !can(keys(body)) ? ["${section} (expected an object)"] : [
            for key in keys(body) : "${section}.${key}"
            if !contains(local.known_task_settings[section], key)
          ]
        )
      )
    ])
    if length(flatten([
      for section, body in jsondecode(t.settings.raw_overrides) :
      !contains(keys(local.known_task_settings), section) ? [section] : (
        length(local.known_task_settings[section]) == 0 ? [] : (
          !can(keys(body)) ? [section] : [
            for key in keys(body) : key
            if !contains(local.known_task_settings[section], key)
          ]
        )
      )
    ])) > 0
  }

  # Merged one level deep, so overriding a single key inside TargetMetadata does
  # not discard the rest of the section. merge() throws on a list (LogComponents
  # is one), and the try() then takes the override wholesale.
  task_settings_merged = {
    for k, t in var.tasks : k => {
      for section in distinct(concat(
        keys(local.task_settings_base[k]),
        keys(local.task_settings_overrides[k]),
      )) :
      section => try(
        merge(local.task_settings_base[k][section], local.task_settings_overrides[k][section]),
        try(local.task_settings_overrides[k][section], local.task_settings_base[k][section]),
      )
    }
  }

  task_settings_json = {
    for k, t in var.tasks : k => jsonencode(local.task_settings_merged[k])
  }

  # -------------------------------------------------------------------------
  # Premigration assessment
  # -------------------------------------------------------------------------

  assessment_enabled     = local.create && local.provisioned && var.premigration_assessment.enabled
  create_assessment_role = local.assessment_enabled && var.premigration_assessment.create_role
  assessment_role_arn    = var.premigration_assessment.create_role ? try(aws_iam_role.assessment[0].arn, "") : var.premigration_assessment.role_arn
  assessment_encryption  = var.premigration_assessment.kms_key_arn != "" ? "SSE_KMS" : "SSE_S3"

  # -------------------------------------------------------------------------
  # Naming
  # -------------------------------------------------------------------------

  subnet_group_id = var.name
  instance_id     = var.name
  # DMS derives this from the replication instance id and creates it on first
  # task start, with no expiry.
  log_group_name = "dms-tasks-${local.instance_id}"

  replication_instance_arn = try(aws_dms_replication_instance.this[0].replication_instance_arn, "")

  # -------------------------------------------------------------------------
  # What the caller's source database has to do before CDC works
  #
  # None of this is reachable from Terraform, all of it fails at runtime rather
  # than at apply, and every engine fails differently. So it is emitted as data.
  # -------------------------------------------------------------------------

  source_engines = distinct([for k, e in var.endpoints : e.engine if e.role == "source"])

  engine_prerequisites = {
    oracle = [
      {
        what = "ARCHIVELOG mode, with archived logs retained longer than your longest expected outage"
        how  = "ALTER DATABASE ARCHIVELOG; and keep at least 24h of archives"
        why  = "CDC reads redo. Once an archived log is gone the task cannot resume and the full load starts again."
      },
      {
        what = "Database-level minimal supplemental logging, plus PRIMARY KEY logging on every migrated table - ALL COLUMNS logging on a table with neither a primary key nor a unique index"
        how  = "ALTER DATABASE ADD SUPPLEMENTAL LOG DATA; ALTER TABLE <t> ADD SUPPLEMENTAL LOG DATA (PRIMARY KEY) COLUMNS; for a keyless table: ALTER TABLE <t> ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;"
        why  = "Without it an UPDATE arrives with no way to identify the row, and DMS applies it to the wrong one or drops it."
      },
      {
        what = "Read access for the DMS user: CREATE SESSION, and SELECT on every migrated table (or SELECT ANY TABLE)"
        how  = "GRANT CREATE SESSION TO <dms_user>; GRANT SELECT ON <schema>.<table> TO <dms_user>; -- per table, or GRANT SELECT ANY TABLE TO <dms_user>;"
        why  = "The connection test does not read your tables. Without SELECT the task starts and the tables sit at 0 rows or go to error."
      },
      {
        what = "LogMiner grants for CDC: SELECT ANY TRANSACTION, SELECT on the V_$ views DMS reads, EXECUTE on DBMS_LOGMNR, and LOGMINING on 12c and later"
        how  = "GRANT SELECT ANY TRANSACTION TO <dms_user>; GRANT EXECUTE ON DBMS_LOGMNR TO <dms_user>; GRANT LOGMINING TO <dms_user>; plus the V_$ view grants listed in the DMS Oracle source documentation"
        why  = "LogMiner cannot start without them, and the task fails at first CDC read rather than at connection test."
      },
      {
        what = "EXECUTE on SYS.DBMS_CRYPTO, when validation is enabled"
        how  = "GRANT EXECUTE ON SYS.DBMS_CRYPTO TO <dms_user>;"
        why  = "DMS validates Oracle rows with DBMS_CRYPTO. Without it validation errors and the evidence it was meant to produce does not exist."
      },
    ]
    postgres = [
      {
        what = "wal_level = logical, max_replication_slots and max_wal_senders above the number of concurrent tasks"
        how  = "RDS: set rds.logical_replication = 1 in the parameter group and reboot. Self-managed: postgresql.conf."
        why  = "Without logical WAL there is no change stream at all; the task connects, then fails at CDC start."
      },
      {
        what = "A role with rds_superuser and rds_replication (RDS/Aurora) or REPLICATION (self-managed)"
        how  = "GRANT rds_superuser, rds_replication TO <dms_user>;"
        why  = "Creating the replication slot is a privileged operation, and DMS documents both roles for an RDS or Aurora source."
      },
      {
        what = "A primary key on every table captured by CDC"
        how  = "SELECT n.nspname, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind = 'r' AND n.nspname = '<schema>' AND NOT EXISTS (SELECT 1 FROM pg_constraint p WHERE p.conrelid = c.oid AND p.contype = 'p');"
        why  = "DMS ignores UPDATE and DELETE on a table without a primary key - silently. The full load is complete and the target diverges from the first change."
      },
      {
        what = "The heartbeat schema (postgres.heartbeat_schema, default awsdms), existing and writable by the DMS user"
        how  = "CREATE SCHEMA IF NOT EXISTS awsdms; GRANT USAGE, CREATE ON SCHEMA awsdms TO <dms_user>;"
        why  = "The heartbeat is what keeps the slot advancing on a quiet source. If DMS cannot create its table there, the heartbeat silently does not run and WAL accumulates."
      },
      {
        what = "A plan for the replication slot when the task stops"
        how  = "monitor pg_replication_slots; drop orphaned slots after a task is deleted"
        why  = "An inactive slot pins WAL forever. The source's disk fills, and that is an outage on the database you were migrating away from - not on DMS."
      },
    ]
    mysql = [
      {
        what = "binlog_format = ROW and binlog_row_image = FULL"
        how  = "RDS parameter group, then reboot"
        why  = "STATEMENT or MINIMAL binlogs cannot be replayed row by row; DMS silently migrates less than you think."
      },
      {
        what = "Binlog retention long enough to survive a stopped task"
        how  = "RDS: CALL mysql.rds_set_configuration('binlog retention hours', 24);"
        why  = "RDS purges binlogs aggressively by default. A task stopped overnight cannot resume."
      },
      {
        what = "REPLICATION CLIENT and REPLICATION SLAVE on the DMS user"
        how  = "GRANT REPLICATION CLIENT, REPLICATION SLAVE ON *.* TO '<dms_user>'@'%';"
        why  = "Full load works without them and CDC does not, so this surfaces only after the load succeeds."
      },
    ]
    sqlserver = [
      {
        what = "FULL recovery model and at least one full backup taken"
        how  = "ALTER DATABASE <db> SET RECOVERY FULL; BACKUP DATABASE <db> ...;"
        why  = "The transaction log is not readable for CDC under SIMPLE recovery."
      },
      {
        what = "MS-CDC enabled on the database and on each migrated table, or MS-REPLICATION"
        how  = "EXEC msdb.dbo.rds_cdc_enable_db '<db>'; then sys.sp_cdc_enable_table per table"
        why  = "Ongoing replication has no source of changes otherwise."
      },
    ]
    mariadb           = []
    aurora            = []
    aurora-postgresql = []
    db2               = []
    db2-zos           = []
    sybase            = []
    redshift          = []
  }

  # mariadb and aurora flavours share their upstream engine's requirements.
  engine_alias = {
    mariadb           = "mysql"
    aurora            = "mysql"
    aurora-postgresql = "postgres"
  }

  source_prerequisites = {
    for engine in local.source_engines :
    engine => lookup(local.engine_prerequisites, lookup(local.engine_alias, engine, engine), [])
  }

  # -------------------------------------------------------------------------
  # What the target has to have before the load
  #
  # DMS has no hook that runs a SQL script; the only in-service hook is
  # postgres_settings.after_connect_script, per connection. Schema, constraints
  # and the sequence reset are the pipeline's job. What this
  # module can do is say, as data, which tasks depend on that having happened.
  # -------------------------------------------------------------------------

  # DO_NOTHING means DMS creates nothing on the target, so the tables have to
  # exist already - and if they do not, the task suspends every table rather
  # than failing outright. Read from the MERGED settings, like every other
  # governance fact.
  tasks_expecting_a_prebuilt_target = [
    for k, t in var.tasks : k
    if try(local.task_settings_merged[k].FullLoadSettings.TargetTablePrepMode, "DO_NOTHING") == "DO_NOTHING"
  ]

  # A full load into a target whose triggers and foreign keys are live is the
  # other half of the same problem.
  postgres_targets_without_load_guard = [
    for k, e in var.endpoints : k
    if e.role == "target" && contains(["postgres", "aurora-postgresql"], e.engine)
    && e.postgres.after_connect_script == ""
  ]

  # -------------------------------------------------------------------------
  # Network prerequisites
  # -------------------------------------------------------------------------

  required_interface_endpoints = concat(
    # DMS reads the secret itself, from inside your VPC.
    length([for k, e in var.endpoints : k if e.secret_arn != ""]) > 0 ? ["secretsmanager"] : [],
    var.kms_key_arn != "" || length([for k, e in var.endpoints : k if e.kms_key_arn != ""]) > 0 ? ["kms"] : [],
    ["logs (for task logging)"],
    var.sns_topic_arn != "" ? ["sns (for event subscriptions)"] : [],
  )

  required_gateway_endpoints = length(var.s3_targets) > 0 ? [
    "s3 - free, and required: an S3 target writes through the gateway endpoint, not the interface one",
  ] : []
}
