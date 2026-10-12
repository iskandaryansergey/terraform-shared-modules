#!/bin/bash
# Shell step on the SOURCE: dumps one pg_dump section of the migrated schemas
# and uploads it, for the next step in the runbook to run on the target.
#
#   section  pre-data  (types, tables, sequences, functions - no keys)
#            post-data (primary keys, indexes, foreign keys, triggers)
#   schemas  comma-separated, from the target's default variables
#   out_key  where to upload it, under the scripts prefix
#
# The connection comes from the runner as PGHOST, PGPORT, PGDATABASE, PGUSER,
# PGPASSWORD, PGSSLMODE and PGSSLROOTCERT. pg_dump on the AMI must be at least
# the source's major version.
set -euo pipefail
: "${section:?}" "${schemas:?}" "${out_key:?}"

args=()
IFS=',' read -ra list <<<"$schemas"
for s in "${list[@]}"; do args+=(--schema="$s"); done

out=$(mktemp)
trap 'rm -f "$out"' EXIT

# --no-owner and --no-privileges: the target's roles are not the source's.
# Grants are a script of their own (sql/target/02-dms-grants.sql).
pg_dump --schema-only --section="$section" --no-owner --no-privileges "${args[@]}" --file="$out"

echo "dumped $section of $schemas: $(wc -l <"$out") lines, sha256 $(sha256sum "$out" | cut -d' ' -f1)"
aws s3 cp "$out" "s3://$DMS_SCRIPTS_BUCKET/$DMS_SCRIPTS_PREFIX$out_key" --only-show-errors
echo "uploaded s3://$DMS_SCRIPTS_BUCKET/$DMS_SCRIPTS_PREFIX$out_key"
