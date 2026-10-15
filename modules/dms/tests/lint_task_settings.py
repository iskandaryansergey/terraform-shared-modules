#!/usr/bin/env python3
"""Structural checks on DMS task settings and table mappings.

These exist because DMS accepts both as JSON and is silent about what it does
not understand:

  - An unknown key in replication_task_settings is IGNORED. No error, no
    warning, no event. "EnableValdiation": true is a task that validates
    nothing, and the only way to find out is to compare row counts by hand
    afterwards.

  - A table mapping with no selection rule matches no tables. The task starts,
    reports success, and migrates nothing.

  - Two rules sharing a rule-id: DMS keys its own state by that id, and one of
    them quietly does not exist.

None of the three is visible in a plan, in the console, or in a task's status.

Usage:
  lint_task_settings.py <file-or-dir> [...]     # *.json, auto-detected
  lint_task_settings.py --self-test

Exit 0 = clean, 1 = a finding, 2 = tool/usage error.
"""

from __future__ import annotations

import json
import re
import pathlib
import sys

findings: list[str] = []


def finding(label: str, msg: str) -> None:
    findings.append(f"{label}: {msg}")


# ---------------------------------------------------------------------------
# The settings DMS actually understands.
#
# Anything outside this map is silently dropped by the service, so an unknown
# key here is the finding - not a warning about strictness.
# ---------------------------------------------------------------------------
SETTINGS_SCHEMA: dict[str, set[str]] = {
    "TargetMetadata": {
        "TargetSchema", "SupportLobs", "FullLobMode", "LobChunkSize",
        "LimitedSizeLobMode", "LobMaxSize", "InlineLobMaxSize", "LoadMaxFileSize",
        "ParallelLoadThreads", "ParallelLoadBufferSize", "ParallelLoadQueuesPerThread",
        "ParallelApplyThreads", "ParallelApplyBufferSize", "ParallelApplyQueuesPerThread",
        "BatchApplyEnabled", "TaskRecoveryTableEnabled", "UseCsvNoSupValue",
        "CsvNoSupValue",
    },
    "FullLoadSettings": {
        "TargetTablePrepMode", "CreatePkAfterFullLoad", "StopTaskCachedChangesApplied",
        "StopTaskCachedChangesNotApplied", "MaxFullLoadSubTasks",
        "TransactionConsistencyTimeout", "CommitRate", "ParallelLoadThreads",
    },
    "Logging": {
        "EnableLogging", "EnableLogContext", "LogComponents", "CloudWatchLogGroup",
        "CloudWatchLogStream", "DeleteTaskLogs",
    },
    "ControlTablesSettings": {
        "ControlSchema", "HistoryTimeslotInMinutes", "StatusTableEnabled",
        "SuspendedTablesTableEnabled", "HistoryTableEnabled", "FullLoadExceptionTableEnabled",
        "CommitPositionTableEnabled",
    },
    "ValidationSettings": {
        "EnableValidation", "ValidationMode", "ThreadCount", "FailureMaxCount",
        "TableFailureMaxCount", "HandleCollationDiff", "ValidationOnly",
        "RecordFailureDelayInMinutes", "RecordSuspendDelayInMinutes",
        "RecordFailureDelayLimitInMinutes", "SkipLobColumns", "ValidationPartialLobSize",
        "ValidationQueryCdcDelaySeconds", "PartitionSize", "MaxKeyColumnSize",
    },
    "ResyncSettings": {"EnableResync", "ResyncSchedule", "MaxResyncTime", "ValidationTaskId"},
    "ErrorBehavior": {
        "DataErrorPolicy", "DataTruncationErrorPolicy", "DataMaskingErrorPolicy",
        "DataErrorEscalationPolicy",
        "DataErrorEscalationCount", "TableErrorPolicy", "TableErrorEscalationPolicy",
        "TableErrorEscalationCount", "RecoverableErrorCount", "RecoverableErrorInterval",
        "RecoverableErrorThrottling", "RecoverableErrorThrottlingMax",
        "RecoverableErrorStopRetryAfterThrottlingMax", "ApplyErrorDeletePolicy",
        "ApplyErrorInsertPolicy", "ApplyErrorUpdatePolicy", "ApplyErrorEscalationPolicy",
        "ApplyErrorEscalationCount", "ApplyErrorFailOnTruncationDdl",
        "FullLoadIgnoreConflicts", "FailOnTransactionConsistencyBreached",
        "FailOnNoTablesCaptured", "EventErrorPolicy",
    },
    "ChangeProcessingTuning": {
        "BatchApplyPreserveTransaction", "BatchApplyTimeoutMin", "BatchApplyTimeoutMax",
        "BatchApplyMemoryLimit", "BatchSplitSize", "MinTransactionSize", "CommitTimeout",
        "MemoryLimitTotal", "MemoryKeepTime", "StatementCacheSize", "RecoveryTimeout",
    },
    "ChangeProcessingDdlHandlingPolicy": {
        "HandleSourceTableDropped", "HandleSourceTableTruncated", "HandleSourceTableAltered",
    },
    "StreamBufferSettings": {"StreamBufferCount", "StreamBufferSizeInMB", "CtrlStreamBufferSizeInMB"},
    "CharacterSetSettings": {"CharacterReplacements", "CharacterSetSupport"},
    "BeforeImageSettings": {"EnableBeforeImage", "FieldName", "ColumnFilter"},
    "LoopbackPreventionSettings": {"EnableLoopbackPrevention", "SourceSchema", "TargetSchema"},
    "PostProcessingRules": set(),
    "FailTaskWhenCleanTaskResourceFailed": set(),
    "TTSettings": {
        "EnableTT", "TTS3Settings", "TTRecordSettings", "EncryptionMode",
        "ServerSideEncryptionKmsKeyId", "ServiceAccessRoleArn", "BucketName", "BucketFolder",
        "EnableDeletingFromS3OnTaskDelete", "EnableRawData", "RawDataFormat", "OperationsToLog",
        "MaxRecordSize",
    },
}
# The same list lives in locals.tf as known_task_settings, where the module's
# check reads it at plan. Two copies because HCL cannot import this file and
# this file must run without Terraform; lint_allowlist_drift() keeps them equal.

VALID_PREP_MODES = {"DO_NOTHING", "TRUNCATE_BEFORE_LOAD", "DROP_AND_CREATE"}
VALID_SEVERITIES = {
    "LOGGER_SEVERITY_ERROR", "LOGGER_SEVERITY_WARNING", "LOGGER_SEVERITY_INFO",
    "LOGGER_SEVERITY_DEFAULT", "LOGGER_SEVERITY_DEBUG", "LOGGER_SEVERITY_DETAILED_DEBUG",
}
VALID_LOG_COMPONENTS = {
    "SOURCE_UNLOAD", "SOURCE_CAPTURE", "TARGET_LOAD", "TARGET_APPLY", "TASK_MANAGER",
    "TABLES_MANAGER", "TRANSFORMATION", "IO", "PERFORMANCE", "SORTER", "REST_SERVER",
    "VALIDATOR", "VALIDATOR_EXT", "FILE_FACTORY", "FILE_TRANSFER", "METADATA_MANAGER",
    "COMMON", "ADDONS", "DATA_STRUCTURE", "COMMUNICATION", "DATA_RESYNC", "RESYNC_UNLOAD",
    "RESYNC_APPLY",
}


def lint_task_settings(doc: dict, label: str) -> None:
    for section, body in doc.items():
        if section not in SETTINGS_SCHEMA:
            finding(
                label,
                f"unknown settings section {section!r}. DMS ignores what it does not "
                f"recognise, so this does nothing at all.",
            )
            continue
        known = SETTINGS_SCHEMA[section]
        if not isinstance(body, dict) or not known:
            continue
        for key in body:
            if key not in known:
                finding(
                    label,
                    f"unknown key {section}.{key!r}. DMS drops it silently - check the "
                    f"spelling against the task settings reference.",
                )

    # ---- semantics, where a legal value is still the wrong one -------------
    validation = doc.get("ValidationSettings", {})
    if isinstance(validation, dict) and validation.get("EnableValidation") is False:
        finding(label, "ValidationSettings.EnableValidation is false: nothing compares "
                       "source and target after the load.")

    logging_ = doc.get("Logging", {})
    if isinstance(logging_, dict):
        if logging_.get("EnableLogging") is False:
            finding(label, "Logging.EnableLogging is false: a failed task leaves no detail behind.")
        for comp in logging_.get("LogComponents") or []:
            if not isinstance(comp, dict):
                finding(label, "Logging.LogComponents entries must be objects with Id and Severity.")
                continue
            if comp.get("Id") not in VALID_LOG_COMPONENTS:
                finding(label, f"unknown log component Id {comp.get('Id')!r}.")
            if comp.get("Severity") not in VALID_SEVERITIES:
                finding(label, f"invalid log severity {comp.get('Severity')!r}.")

    full = doc.get("FullLoadSettings", {})
    if isinstance(full, dict):
        prep = full.get("TargetTablePrepMode")
        if prep is not None and prep not in VALID_PREP_MODES:
            finding(label, f"FullLoadSettings.TargetTablePrepMode {prep!r} is not one of "
                           f"{sorted(VALID_PREP_MODES)}.")

    errors = doc.get("ErrorBehavior", {})
    if isinstance(errors, dict) and errors.get("FailOnNoTablesCaptured") is False:
        finding(label, "ErrorBehavior.FailOnNoTablesCaptured is false: a task whose "
                       "selection rules match nothing will report success.")

    meta = doc.get("TargetMetadata", {})
    if isinstance(meta, dict):
        if meta.get("FullLobMode") and meta.get("LimitedSizeLobMode"):
            finding(label, "TargetMetadata sets both FullLobMode and LimitedSizeLobMode. "
                           "DMS takes one of them and which one is not documented.")
        if meta.get("LimitedSizeLobMode") and meta.get("LobMaxSize", 0) in (0, None):
            finding(label, "TargetMetadata.LimitedSizeLobMode is on with LobMaxSize 0, which "
                           "truncates every LOB to nothing.")
        if meta.get("InlineLobMaxSize", 0) and not meta.get("FullLobMode"):
            finding(label, "TargetMetadata.InlineLobMaxSize is set while FullLobMode is false. "
                           "DMS only reads the inline threshold in full LOB mode, so this is "
                           "silently ignored and LOB handling falls back to the default.")


# ---------------------------------------------------------------------------
# Table mappings
# ---------------------------------------------------------------------------
# The DMS table-mapping documentation (selection, transformation and
# table-settings rules). The same lists live in locals.tf as
# known_mapping_rules, where the module's plan-time gate reads them;
# lint_mapping_rules_drift() keeps the two equal.
MAPPING_RULES: dict[str, set[str]] = {
    "rule_types": {"selection", "transformation", "table-settings", "object-mapping"},
    "selection_actions": {"include", "exclude", "explicit"},
    "transformation_actions": {
        "add-column", "include-column", "remove-column", "rename", "convert-lowercase",
        "convert-uppercase", "add-prefix", "remove-prefix", "replace-prefix", "add-suffix",
        "remove-suffix", "replace-suffix", "define-primary-key", "change-data-type",
        "add-before-image-columns", "data-masking-digits-mask",
        "data-masking-digits-randomize", "data-masking-hash-mask",
    },
    "transformation_targets": {"schema", "table", "column", "table-tablespace", "index-tablespace"},
    "column_only_actions": {
        "change-data-type", "data-masking-digits-mask", "data-masking-digits-randomize",
        "data-masking-hash-mask",
    },
    "parallel_load_types": {"partitions-auto", "subpartitions-auto", "partitions-list", "ranges", "none"},
    "lob_modes": {"limited", "unlimited", "none"},
}
VALID_RULE_TYPES = MAPPING_RULES["rule_types"]


def lint_table_mappings(doc: dict, label: str) -> None:
    rules = doc.get("rules")
    if not isinstance(rules, list):
        finding(label, "table mappings need a top-level \"rules\" array.")
        return
    if not rules:
        finding(label, "the rules array is empty, so the task matches no tables and "
                       "completes successfully having migrated nothing.")
        return

    seen_ids: set[str] = set()
    names: list[str] = []
    selections = 0

    def text(v: object) -> str:
        return "" if v is None else str(v).strip()

    for rule in rules:
        if not isinstance(rule, dict):
            finding(label, "every rule must be an object.")
            continue

        rid = text(rule.get("rule-id"))
        if rid == "":
            finding(label, "a rule has no rule-id.")
            rid = "?"
        elif not rid.isdigit():
            finding(label, f"rule {rid!r}: rule-id must be a numeric value.")
        elif rid in seen_ids:
            finding(label, f"rule-id {rid!r} is used more than once. DMS keys its state by "
                           f"rule-id, so one of these silently does not exist.")
        else:
            seen_ids.add(rid)

        rtype = text(rule.get("rule-type"))
        if rtype not in MAPPING_RULES["rule_types"]:
            finding(label, f"rule {rid!r}: rule-type {rtype!r} is not one of "
                           f"{sorted(MAPPING_RULES['rule_types'])}.")
            continue

        name = text(rule.get("rule-name"))
        if name == "":
            finding(label, f"rule {rid!r}: no rule-name. DMS requires one.")
        names.append(name)

        loc = rule.get("object-locator")
        has_locator = isinstance(loc, dict)
        schema = text(loc.get("schema-name")) if has_locator else ""
        table = text(loc.get("table-name")) if has_locator else ""
        action = text(rule.get("rule-action"))

        if rtype == "selection":
            selections += 1
            if action not in MAPPING_RULES["selection_actions"]:
                finding(label, f"rule {rid!r}: selection rule-action must be include, "
                               f"exclude or explicit, not {action!r}.")
            if schema == "" or table == "":
                finding(label, f"rule {rid!r}: selection rules need an object-locator with "
                               f"schema-name and table-name.")
            if action == "explicit" and "%" in schema + table:
                finding(label, f"rule {rid!r}: explicit selects one exact table, so % is not "
                               f"allowed in its names.")

        if rtype == "transformation":
            target = text(rule.get("rule-target"))
            if action not in MAPPING_RULES["transformation_actions"]:
                finding(label, f"rule {rid!r}: transformation rule-action {action!r} is not "
                               f"one DMS documents.")
            if target not in MAPPING_RULES["transformation_targets"]:
                finding(label, f"rule {rid!r}: transformation rule-target must be one of "
                               f"{sorted(MAPPING_RULES['transformation_targets'])}, not {target!r}.")
            if not has_locator:
                finding(label, f"rule {rid!r}: a transformation needs an object-locator.")
            if action in MAPPING_RULES["column_only_actions"] and target != "column":
                finding(label, f"rule {rid!r}: {action} applies to rule-target column only.")
            if action == "define-primary-key" and "%" in schema + table:
                finding(label, f"rule {rid!r}: define-primary-key cannot use % in schema-name "
                               f"or table-name.")

        if rtype == "table-settings":
            if schema == "" or table == "" or "%" in schema + table:
                finding(label, f"rule {rid!r}: table-settings need an exact schema-name and "
                               f"table-name, no %. DMS rejects the mapping otherwise.")
            pl = rule.get("parallel-load")
            if isinstance(pl, dict):
                pl_type = text(pl.get("type"))
                if pl_type not in MAPPING_RULES["parallel_load_types"]:
                    finding(label, f"rule {rid!r}: parallel-load.type {pl_type!r} is not one of "
                                   f"{sorted(MAPPING_RULES['parallel_load_types'])}.")
                if pl_type == "ranges" and not (pl.get("columns") and pl.get("boundaries")):
                    finding(label, f"rule {rid!r}: parallel-load type ranges needs columns and "
                                   f"boundaries.")
                if pl_type == "partitions-list" and not (pl.get("partitions") or pl.get("subpartitions")):
                    finding(label, f"rule {rid!r}: parallel-load type partitions-list needs "
                                   f"partitions or subpartitions.")
            lob = rule.get("lob-settings")
            if isinstance(lob, dict):
                mode = text(lob.get("mode")) or "limited"
                if mode not in MAPPING_RULES["lob_modes"]:
                    finding(label, f"rule {rid!r}: lob-settings.mode {mode!r} is not limited, "
                                   f"unlimited or none.")
                try:
                    bulk = float(lob.get("bulk-max-size", 0) or 0)
                except (TypeError, ValueError):
                    bulk = 0.0
                if mode == "limited" and bulk <= 0:
                    finding(label, f"rule {rid!r}: lob-settings in limited mode (the default) "
                                   f"need a non-zero bulk-max-size; zero is invalid.")

    if len(set(names)) != len(names):
        finding(label, "rule-name values must be unique.")

    if selections == 0:
        finding(label, "no selection rule. Transformation rules alone match no tables, and "
                       "the task completes successfully having migrated nothing.")

    # A rule that excludes everything and includes nothing is a working config
    # that moves no data - worth saying out loud.
    includes = [
        r for r in rules
        if isinstance(r, dict) and r.get("rule-type") == "selection"
        and r.get("rule-action") in {"include", "explicit"}
    ]
    if selections and not includes:
        finding(label, "every selection rule is an exclude. Nothing is included, so nothing "
                       "migrates.")


HCL_BEGIN = "# known_task_settings:begin"
HCL_END = "# known_task_settings:end"
HCL_MAP_BEGIN = "# known_mapping_rules:begin"
HCL_MAP_END = "# known_mapping_rules:end"


def parse_hcl_lists(text: str, begin: str, end: str) -> dict[str, set[str]] | None:
    """A map of string lists from locals.tf, between two marker comments.

    Only the shape the module writes is understood: `name = [ "k", ... ]`,
    one entry per name, string literals only. Anything else is reported as
    unparsable rather than guessed at.
    """
    if begin not in text or end not in text:
        return None
    block = text[text.index(begin):text.index(end)]
    out: dict[str, set[str]] = {}
    for m in re.finditer(r"^\s*([A-Za-z_]+)\s*=\s*\[(.*?)\]", block, re.S | re.M):
        out[m.group(1)] = set(re.findall(r'"([^"]+)"', m.group(2)))
    return out


def parse_hcl_known_settings(text: str) -> dict[str, set[str]] | None:
    return parse_hcl_lists(text, HCL_BEGIN, HCL_END)


def _compare_lists(hcl: dict[str, set[str]], py: dict[str, set[str]], hcl_name: str,
                   py_name: str, label: str) -> None:
    for key in sorted(set(hcl) | set(py)):
        if key not in hcl:
            finding(label, f"{hcl_name} lacks {key!r} that this linter knows; add it there.")
        elif key not in py:
            finding(label, f"{hcl_name} has {key!r} that this linter does not know; add it "
                           f"to {py_name}.")
        elif hcl[key] != py[key]:
            only_hcl = sorted(hcl[key] - py[key])
            only_py = sorted(py[key] - hcl[key])
            finding(label, f"{hcl_name}.{key} drifted from {py_name}: only in locals.tf "
                           f"{only_hcl}, only in this linter {only_py}.")


def lint_allowlist_drift(locals_text: str, label: str = "locals.tf") -> None:
    hcl = parse_hcl_known_settings(locals_text)
    if hcl is None:
        finding(label, f"no {HCL_BEGIN} / {HCL_END} markers around known_task_settings; "
                       "the module's plan-time check and this linter can no longer be "
                       "compared.")
        return
    _compare_lists(hcl, SETTINGS_SCHEMA, "known_task_settings", "SETTINGS_SCHEMA", label)


def lint_mapping_rules_drift(locals_text: str, label: str = "locals.tf") -> None:
    hcl = parse_hcl_lists(locals_text, HCL_MAP_BEGIN, HCL_MAP_END)
    if hcl is None:
        finding(label, f"no {HCL_MAP_BEGIN} / {HCL_MAP_END} markers around "
                       "known_mapping_rules; the module's plan-time gate and this linter "
                       "can no longer be compared.")
        return
    _compare_lists(hcl, MAPPING_RULES, "known_mapping_rules", "MAPPING_RULES", label)


def lint_file(path: pathlib.Path) -> None:
    try:
        doc = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        finding(path.name, f"not valid JSON: {exc}")
        return
    if not isinstance(doc, dict):
        finding(path.name, "document must be a JSON object at the top level.")
        return

    # Auto-detect. Table mappings have "rules"; settings have known sections.
    if "rules" in doc:
        lint_table_mappings(doc, path.name)
    elif any(k in SETTINGS_SCHEMA for k in doc):
        lint_task_settings(doc, path.name)
    else:
        finding(path.name, "does not look like DMS table mappings (no \"rules\") or task "
                           "settings (no recognised section).")


SELECT_ALL = {"rule-type": "selection", "rule-id": "1", "rule-name": "all",
              "rule-action": "include",
              "object-locator": {"schema-name": "s", "table-name": "%"}}

SELF_TEST_CASES = [
    ("a misspelled settings key", {"ValidationSettings": {"EnableValdiation": True}}),
    ("an unknown settings section", {"ValidationSetting": {"EnableValidation": True}}),
    ("validation switched off", {"ValidationSettings": {"EnableValidation": False}}),
    ("logging switched off", {"Logging": {"EnableLogging": False}}),
    ("a task that cannot fail on an empty capture",
     {"ErrorBehavior": {"FailOnNoTablesCaptured": False}}),
    ("contradictory LOB modes",
     {"TargetMetadata": {"FullLobMode": True, "LimitedSizeLobMode": True}}),
    ("limited LOB mode truncating everything",
     {"TargetMetadata": {"LimitedSizeLobMode": True, "LobMaxSize": 0}}),
    ("an invalid log severity",
     {"Logging": {"EnableLogging": True, "LogComponents": [{"Id": "TARGET_APPLY", "Severity": "LOUD"}]}}),
    ("an invalid target prep mode",
     {"FullLoadSettings": {"TargetTablePrepMode": "DROP_TABLES"}}),
    ("table mappings with no selection rule",
     {"rules": [{"rule-type": "transformation", "rule-id": "1", "rule-name": "1",
                 "rule-action": "convert-lowercase", "rule-target": "table",
                 "object-locator": {"schema-name": "%", "table-name": "%"}}]}),
    ("duplicate rule-ids",
     {"rules": [
         {"rule-type": "selection", "rule-id": "1", "rule-name": "a", "rule-action": "include",
          "object-locator": {"schema-name": "s", "table-name": "%"}},
         {"rule-type": "selection", "rule-id": "1", "rule-name": "b", "rule-action": "include",
          "object-locator": {"schema-name": "t", "table-name": "%"}},
     ]}),
    ("a selection rule with no object-locator",
     {"rules": [{"rule-type": "selection", "rule-id": "1", "rule-name": "a",
                 "rule-action": "include"}]}),
    ("only exclusions",
     {"rules": [{"rule-type": "selection", "rule-id": "1", "rule-name": "a",
                 "rule-action": "exclude",
                 "object-locator": {"schema-name": "s", "table-name": "%"}}]}),
    ("an empty rules array", {"rules": []}),
    ("a non-numeric rule-id",
     {"rules": [{"rule-type": "selection", "rule-id": "one", "rule-name": "a",
                 "rule-action": "include",
                 "object-locator": {"schema-name": "s", "table-name": "%"}}]}),
    ("explicit with a wildcard",
     {"rules": [{"rule-type": "selection", "rule-id": "1", "rule-name": "a",
                 "rule-action": "explicit",
                 "object-locator": {"schema-name": "s", "table-name": "t%"}}]}),
    ("a transformation action DMS does not document",
     {"rules": [SELECT_ALL, {"rule-type": "transformation", "rule-id": "2", "rule-name": "b",
                             "rule-action": "add-prefx", "rule-target": "table",
                             "object-locator": {"schema-name": "s", "table-name": "%"},
                             "value": "x_"}]}),
    ("a column-only action on a table target",
     {"rules": [SELECT_ALL, {"rule-type": "transformation", "rule-id": "2", "rule-name": "b",
                             "rule-action": "change-data-type", "rule-target": "table",
                             "object-locator": {"schema-name": "s", "table-name": "t"},
                             "data-type": {"type": "int8"}}]}),
    ("define-primary-key with a wildcard",
     {"rules": [SELECT_ALL, {"rule-type": "transformation", "rule-id": "2", "rule-name": "b",
                             "rule-action": "define-primary-key", "rule-target": "table",
                             "object-locator": {"schema-name": "s", "table-name": "%"},
                             "primary-key-def": {"name": "pk", "columns": ["id"]}}]}),
    ("table-settings with a wildcard",
     {"rules": [SELECT_ALL, {"rule-type": "table-settings", "rule-id": "2", "rule-name": "b",
                             "object-locator": {"schema-name": "s", "table-name": "%"},
                             "parallel-load": {"type": "partitions-auto"}}]}),
    ("an unknown parallel-load type",
     {"rules": [SELECT_ALL, {"rule-type": "table-settings", "rule-id": "2", "rule-name": "b",
                             "object-locator": {"schema-name": "s", "table-name": "t"},
                             "parallel-load": {"type": "partition-auto"}}]}),
    ("ranges without boundaries",
     {"rules": [SELECT_ALL, {"rule-type": "table-settings", "rule-id": "2", "rule-name": "b",
                             "object-locator": {"schema-name": "s", "table-name": "t"},
                             "parallel-load": {"type": "ranges", "columns": ["id"]}}]}),
    ("limited LOB settings without bulk-max-size",
     {"rules": [SELECT_ALL, {"rule-type": "table-settings", "rule-id": "2", "rule-name": "b",
                             "object-locator": {"schema-name": "s", "table-name": "t"},
                             "lob-settings": {"mode": "limited"}}]}),
    ("duplicate rule-names",
     {"rules": [SELECT_ALL, {"rule-type": "selection", "rule-id": "2", "rule-name": "all",
                             "rule-action": "exclude",
                             "object-locator": {"schema-name": "s", "table-name": "x%"}}]}),
]

SELF_TEST_GOOD = [
    ("every documented rule shape",
     {"rules": [
         SELECT_ALL,
         {"rule-type": "selection", "rule-id": "2", "rule-name": "one", "rule-action": "explicit",
          "object-locator": {"schema-name": "s", "table-name": "exact"}},
         {"rule-type": "transformation", "rule-id": "3", "rule-name": "prefix",
          "rule-action": "add-prefix", "rule-target": "table",
          "object-locator": {"schema-name": "s", "table-name": "%"}, "value": "x_"},
         {"rule-type": "transformation", "rule-id": "4", "rule-name": "pk",
          "rule-action": "define-primary-key", "rule-target": "table",
          "object-locator": {"schema-name": "s", "table-name": "exact"},
          "primary-key-def": {"name": "pk", "columns": ["id"]}},
         {"rule-type": "transformation", "rule-id": "5", "rule-name": "type",
          "rule-action": "change-data-type", "rule-target": "column",
          "object-locator": {"schema-name": "s", "table-name": "exact", "column-name": "c"},
          "data-type": {"type": "int8"}},
         {"rule-type": "table-settings", "rule-id": "6", "rule-name": "parallel",
          "object-locator": {"schema-name": "s", "table-name": "exact"},
          "parallel-load": {"type": "ranges", "columns": ["id"], "boundaries": [["100"]]}},
         {"rule-type": "table-settings", "rule-id": "7", "rule-name": "lobs",
          "object-locator": {"schema-name": "s", "table-name": "other"},
          "lob-settings": {"mode": "unlimited", "bulk-max-size": "0"}},
     ]}),
    ("a normal selection rule",
     {"rules": [{"rule-type": "selection", "rule-id": "1", "rule-name": "include-app",
                 "rule-action": "include",
                 "object-locator": {"schema-name": "app", "table-name": "%"}}]}),
    ("settings the module renders by default",
     {"ValidationSettings": {"EnableValidation": True, "ThreadCount": 5},
      "Logging": {"EnableLogging": True,
                  "LogComponents": [{"Id": "TARGET_APPLY", "Severity": "LOGGER_SEVERITY_DEFAULT"}]},
      "ErrorBehavior": {"FailOnNoTablesCaptured": True},
      "FullLoadSettings": {"TargetTablePrepMode": "DO_NOTHING"},
      "TargetMetadata": {"LimitedSizeLobMode": True, "LobMaxSize": 32}}),
]


def self_test() -> int:
    global findings
    bad = 0

    for label, doc in SELF_TEST_CASES:
        findings = []
        if "rules" in doc:
            lint_table_mappings(doc, "case")
        else:
            lint_task_settings(doc, "case")
        if findings:
            print(f"  ok    detected: {label}")
        else:
            print(f"  FAIL  NOT detected: {label}")
            bad += 1

    for label, doc in SELF_TEST_GOOD:
        findings = []
        if "rules" in doc:
            lint_table_mappings(doc, "case")
        else:
            lint_task_settings(doc, "case")
        if findings:
            print(f"  FAIL  false positive on: {label}")
            for f in findings:
                print(f"          {f}")
            bad += 1
        else:
            print(f"  ok    no false positive: {label}")

    # The HCL copy of the allowlist: a drifted copy must be detected, and the
    # shipped one must match.
    findings = []
    lint_allowlist_drift(
        HCL_BEGIN + "\n  known_task_settings = {\n"
        "    ValidationSettings = [\"EnableValidation\"]\n"
        "    PostProcessingRules = []\n  }\n" + HCL_END, "synthetic")
    if findings:
        print("  ok    detected: known_task_settings drifted from SETTINGS_SCHEMA")
    else:
        print("  FAIL  NOT detected: known_task_settings drifted from SETTINGS_SCHEMA")
        bad += 1
    findings = []
    lint_allowlist_drift("locals {\n}\n", "synthetic")
    if findings:
        print("  ok    detected: known_task_settings markers missing")
    else:
        print("  FAIL  NOT detected: known_task_settings markers missing")
        bad += 1
    findings = []
    lint_mapping_rules_drift(
        HCL_MAP_BEGIN + "\n  known_mapping_rules = {\n"
        "    rule_types = [\"selection\"]\n    lob_modes = [\"limited\"]\n  }\n"
        + HCL_MAP_END, "synthetic")
    if findings:
        print("  ok    detected: known_mapping_rules drifted from MAPPING_RULES")
    else:
        print("  FAIL  NOT detected: known_mapping_rules drifted from MAPPING_RULES")
        bad += 1

    # And everything shipped in the repo must pass.
    findings = []
    here = pathlib.Path(__file__).resolve().parent.parent
    locals_tf = here / "locals.tf"
    if locals_tf.is_file():
        lint_allowlist_drift(locals_tf.read_text(), "locals.tf")
        lint_mapping_rules_drift(locals_tf.read_text(), "locals.tf")
    else:
        print("  FAIL  locals.tf not found next to tests/; cannot compare the allowlists")
        bad += 1
    fixtures = here / "tests" / "fixtures"
    if not fixtures.is_dir() or not any(fixtures.glob("*.json")):
        # Path.glob on a missing directory returns empty and reports success,
        # which is how the task-settings half of this linter went unexercised
        # while the self-test said "clean".
        print("  FAIL  tests/fixtures/ has no rendered task-settings documents; "
              "the settings half of this linter is unexercised")
        bad += 1
    shipped = [
        f for f in sorted(here.glob("examples/**/*.json")) + sorted(fixtures.glob("*.json"))
        if ".terraform" not in f.parts
    ]
    for f in shipped:
        lint_file(f)
    if findings:
        print("  FAIL  shipped JSON does not pass its own linter:")
        for f in findings:
            print(f"          {f}")
        bad += 1
    else:
        print(f"  ok    {len(shipped)} shipped JSON file(s) are clean")

    print()
    if bad:
        print(f"SELF-TEST FAILED: {bad} case(s)")
        return 1
    print(f"SELF-TEST OK: {len(SELF_TEST_CASES) + 3} defects detected, "
          f"{len(SELF_TEST_GOOD)} valid documents accepted")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2

    files: list[pathlib.Path] = []
    for arg in argv[1:]:
        p = pathlib.Path(arg)
        if p.is_dir():
            # Not .terraform: the provider cache and modules.json are JSON too,
            # and linting them fails on every machine that has run init.
            files.extend(
                f for f in sorted(p.rglob("*.json"))
                if ".terraform" not in f.parts
            )
        elif p.is_file():
            files.append(p)
        else:
            print(f"FATAL: {p} does not exist", file=sys.stderr)
            return 2

    if not files:
        print("FATAL: no JSON files to check", file=sys.stderr)
        return 2

    for f in files:
        lint_file(f)

    # The module's own copy of the allowlist, whenever this runs from the
    # module tree: a key added on one side only is exactly the drift that
    # lets a typo through one gate and not the other.
    locals_tf = pathlib.Path(__file__).resolve().parent.parent / "locals.tf"
    if locals_tf.is_file():
        lint_allowlist_drift(locals_tf.read_text(), "locals.tf")
        lint_mapping_rules_drift(locals_tf.read_text(), "locals.tf")

    if findings:
        print(f"FAILED: {len(findings)} finding(s)", file=sys.stderr)
        for f in findings:
            print(f"  - {f}", file=sys.stderr)
        return 1

    print(f"OK: {len(files)} document(s) pass all structural checks")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
