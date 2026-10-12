#!/bin/bash
# Shell step on the SOURCE, at cutover: DMS migrates rows, not sequence
# positions. Writes one setval per sequence in the migrated schemas and
# uploads it for the next step to run on the target. Run it after writes to
# the source have stopped, or the positions are already stale.
#
#   schemas  comma-separated, from the target's default variables
#   out_key  where to upload it, under the scripts prefix
set -euo pipefail
: "${schemas:?}" "${out_key:?}"

out=$(mktemp)
trap 'rm -f "$out"' EXIT

# last_value is NULL for a sequence never used, or one this user may not read:
# that becomes setval(seq, 1, false), so the first nextval returns 1.
psql --no-psqlrc --tuples-only --no-align --set ON_ERROR_STOP=1 --set schemas="$schemas" --output="$out" <<'SQL'
SELECT format('SELECT setval(%L, %s, %s);',
              format('%I.%I', schemaname, sequencename),
              COALESCE(last_value, 1),
              last_value IS NOT NULL)
  FROM pg_sequences
 WHERE schemaname = ANY (string_to_array(:'schemas', ','))
 ORDER BY 1;
SQL

echo "$(grep -c setval "$out" || true) sequences, sha256 $(sha256sum "$out" | cut -d' ' -f1)"
aws s3 cp "$out" "s3://$DMS_SCRIPTS_BUCKET/$DMS_SCRIPTS_PREFIX$out_key" --only-show-errors
echo "uploaded s3://$DMS_SCRIPTS_BUCKET/$DMS_SCRIPTS_PREFIX$out_key"
