Rendered `replication_task_settings`, one per LOB mode, exactly as the module
produces them. Regenerate with:

    terraform test -filter=tests/dms.tftest.hcl   # proves the module renders these
    # then, from a plan: terraform output -json task_settings_json

They exist because the linter's settings half was never pointed at a settings
document — only at table mappings — which is how a broken INLINE rendering
passed a green self-test.
