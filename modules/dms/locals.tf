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

  provisioned = var.compute_mode == "provisioned"
  serverless  = var.compute_mode == "serverless"

  # -------------------------------------------------------------------------
  # Endpoints
  # -------------------------------------------------------------------------

  # Endpoints DMS reads a secret for. An empty secret_access_role_arn means we
  # make the role, scoped to that one secret.
  endpoints_with_secret = {
    for k, e in var.endpoints : k => e
    if e.secret_arn != "" && e.secret_access_role_arn == ""
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
  log_components = ["SOURCE_UNLOAD", "SOURCE_CAPTURE", "TARGET_LOAD", "TARGET_APPLY", "TASK_MANAGER", "VALIDATOR"]

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
        StopTaskCachedChangesNotApplied = false
        MaxFullLoadSubTasks             = t.settings.max_full_load_subtasks
        TransactionConsistencyTimeout   = 600
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

      ErrorBehavior = {
        DataErrorPolicy               = "LOG_ERROR"
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
        ApplyErrorDeletePolicy        = "IGNORE_RECORD"
        ApplyErrorInsertPolicy        = "LOG_ERROR"
        ApplyErrorUpdatePolicy        = "LOG_ERROR"
        ApplyErrorEscalationPolicy    = "LOG_ERROR"
        ApplyErrorEscalationCount     = t.settings.apply_error_max
        FullLoadIgnoreConflicts       = true
        # The runtime half of the "selection rule matched nothing" trap: without
        # this the task starts, captures no tables, and reports success.
        FailOnNoTablesCaptured               = true
        FailOnTransactionConsistencyBreached = false
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
        what = "Database-level minimal supplemental logging, plus PRIMARY KEY logging on every migrated table"
        how  = "ALTER DATABASE ADD SUPPLEMENTAL LOG DATA; ALTER TABLE <t> ADD SUPPLEMENTAL LOG DATA (PRIMARY KEY) COLUMNS;"
        why  = "Without it an UPDATE arrives with no way to identify the row, and DMS applies it to the wrong one or drops it."
      },
      {
        what = "Grants for the DMS user: SELECT ANY TRANSACTION, SELECT on V_$ views, and EXECUTE on DBMS_LOGMNR"
        how  = "see the DMS Oracle source documentation for the exact grant list"
        why  = "LogMiner cannot start without them, and the task fails at first CDC read rather than at connection test."
      },
    ]
    postgres = [
      {
        what = "wal_level = logical, max_replication_slots and max_wal_senders above the number of concurrent tasks"
        how  = "RDS: set rds.logical_replication = 1 in the parameter group and reboot. Self-managed: postgresql.conf."
        why  = "Without logical WAL there is no change stream at all; the task connects, then fails at CDC start."
      },
      {
        what = "A role with rds_replication (RDS) or REPLICATION (self-managed)"
        how  = "GRANT rds_replication TO <dms_user>;"
        why  = "Creating the replication slot is a privileged operation."
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
    docdb             = []
    neptune           = []
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
  # Pre-data and post-data
  #
  # DMS has no hook that runs a SQL script. The only in-service hook is
  # postgres_settings.after_connect_script, which runs per connection rather
  # than per migration. So the module records the manifest and emits the
  # ordering; running it is the pipeline's job.
  # -------------------------------------------------------------------------

  pre_data_scripts = [
    for i, s in var.sql_scripts.pre_data : {
      order       = i + 1
      phase       = "pre_data"
      name        = s.name
      path        = s.path
      sha256      = s.sha256 != "" ? s.sha256 : (s.sql != "" ? sha256(s.sql) : "not supplied - use filesha256() so the change record can prove what ran")
      description = s.description
    }
  ]

  post_data_scripts = [
    for i, s in var.sql_scripts.post_data : {
      order       = i + 1
      phase       = "post_data"
      name        = s.name
      path        = s.path
      sha256      = s.sha256 != "" ? s.sha256 : (s.sql != "" ? sha256(s.sql) : "not supplied - use filesha256() so the change record can prove what ran")
      description = s.description
    }
  ]

  has_sql_scripts = length(local.pre_data_scripts) + length(local.post_data_scripts) > 0

  # DO_NOTHING means DMS creates nothing on the target. With no pre-data script
  # declared either, the tables have to already exist - and if they do not, the
  # task suspends every table rather than failing outright.
  tasks_assuming_a_prebuilt_target = [
    for k, t in var.tasks : k
    if try(local.task_settings_merged[k].FullLoadSettings.TargetTablePrepMode, "DO_NOTHING") == "DO_NOTHING"
    && length(local.pre_data_scripts) == 0
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
