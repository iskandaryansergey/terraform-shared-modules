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
        "TransactionConsistencyTimeout", "CommitRate",
    },
    "Logging": {"EnableLogging", "LogComponents", "CloudWatchLogGroup", "CloudWatchLogStream"},
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
        "ValidationQueryCdcDelaySeconds", "PartitionSize",
    },
    "ErrorBehavior": {
        "DataErrorPolicy", "DataTruncationErrorPolicy", "DataErrorEscalationPolicy",
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
        "MemoryLimitTotal", "MemoryKeepTime", "StatementCacheSize",
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
    "TTSettings": {"EnableTT", "TTS3Settings", "TTRecordSettings"},
}

VALID_PREP_MODES = {"DO_NOTHING", "TRUNCATE_BEFORE_LOAD", "DROP_AND_CREATE"}
VALID_SEVERITIES = {
    "LOGGER_SEVERITY_ERROR", "LOGGER_SEVERITY_WARNING", "LOGGER_SEVERITY_INFO",
    "LOGGER_SEVERITY_DEFAULT", "LOGGER_SEVERITY_DEBUG", "LOGGER_SEVERITY_DETAILED_DEBUG",
}
VALID_LOG_COMPONENTS = {
    "SOURCE_UNLOAD", "SOURCE_CAPTURE", "TARGET_LOAD", "TARGET_APPLY", "TASK_MANAGER",
    "TABLES_MANAGER", "TRANSFORMATION", "IO", "PERFORMANCE", "SORTER", "REST_SERVER",
    "VALIDATOR", "VALIDATOR_EXT", "FILE_FACTORY", "FILE_TRANSFER", "METADATA_MANAGER",
    "COMMON", "ADDONS", "DATA_STRUCTURE", "COMMUNICATION",
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
VALID_RULE_TYPES = {"selection", "transformation", "table-settings", "object-mapping"}
VALID_RULE_ACTIONS = {
    "include", "exclude", "explicit",
    "rename", "remove-column", "convert-lowercase", "convert-uppercase",
    "add-column", "add-before-image-columns", "define-primary-key", "change-data-type",
    "map-record-to-record", "map-record-to-document",
}


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
    selections = 0

    for rule in rules:
        if not isinstance(rule, dict):
            finding(label, "every rule must be an object.")
            continue

        rid = rule.get("rule-id")
        if rid is None:
            finding(label, "a rule has no rule-id.")
        elif str(rid) in seen_ids:
            finding(label, f"rule-id {rid!r} is used more than once. DMS keys its state by "
                           f"rule-id, so one of these silently does not exist.")
        else:
            seen_ids.add(str(rid))

        rtype = rule.get("rule-type")
        if rtype not in VALID_RULE_TYPES:
            finding(label, f"rule {rid!r}: rule-type {rtype!r} is not one of "
                           f"{sorted(VALID_RULE_TYPES)}.")
            continue

        if rule.get("rule-name") is None:
            finding(label, f"rule {rid!r}: no rule-name. DMS requires one.")

        if rtype == "selection":
            selections += 1
            action = rule.get("rule-action")
            if action not in {"include", "exclude", "explicit"}:
                finding(label, f"rule {rid!r}: selection rule-action must be include, "
                               f"exclude or explicit, not {action!r}.")
            loc = rule.get("object-locator")
            if not isinstance(loc, dict) or "schema-name" not in loc or "table-name" not in loc:
                finding(label, f"rule {rid!r}: selection rules need an object-locator with "
                               f"schema-name and table-name.")

        if rtype == "transformation":
            if rule.get("rule-action") not in VALID_RULE_ACTIONS:
                finding(label, f"rule {rid!r}: transformation rule-action "
                               f"{rule.get('rule-action')!r} is not one of "
                               f"{sorted(VALID_RULE_ACTIONS)}.")
            if rule.get("rule-target") not in {"schema", "table", "column", "table-tablespace", "index-tablespace"}:
                finding(label, f"rule {rid!r}: transformation needs a rule-target of schema, "
                               f"table or column.")

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
]

SELF_TEST_GOOD = [
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

    # And everything shipped in the repo must pass.
    findings = []
    here = pathlib.Path(__file__).resolve().parent.parent
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
    print(f"SELF-TEST OK: {len(SELF_TEST_CASES)} defects detected, "
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

    if findings:
        print(f"FAILED: {len(findings)} finding(s)", file=sys.stderr)
        for f in findings:
            print(f"  - {f}", file=sys.stderr)
        return 1

    print(f"OK: {len(files)} document(s) pass all structural checks")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
