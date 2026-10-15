Rendered `replication_task_settings`, one per LOB mode, exactly as the module
produces them with its defaults. `tests/lint_task_settings.py` lints them, so
they are only evidence while they ARE what the module renders:
`tests/task_settings.tftest.hcl` compares each one with the live output and
fails on any difference.

To regenerate after a deliberate change to the rendering, take
`output.task_settings_json["app"]` from a mocked run with
`settings = { lob_mode = "<MODE>" }` and write it here pretty-printed with
sorted keys; the test then goes green again, and the linter re-checks the
result.
