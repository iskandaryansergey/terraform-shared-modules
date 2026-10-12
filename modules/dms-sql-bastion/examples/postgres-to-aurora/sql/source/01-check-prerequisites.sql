-- Source prerequisites for DMS full load + CDC from PostgreSQL. Read-only.
-- Fails on the first gap, here, instead of the DMS task failing at CDC start
-- or - worse - running and silently dropping changes.
--
-- Variables (from the target's defaults): schemas, dms_user.

SELECT set_config('migration.schemas', :'schemas', false),
       set_config('migration.dms_user', :'dms_user', false);

DO $$
DECLARE
  keyless text;
BEGIN
  IF current_setting('wal_level') <> 'logical' THEN
    RAISE EXCEPTION 'wal_level is %; DMS CDC needs logical (postgresql.conf, then a restart)',
      current_setting('wal_level');
  END IF;

  IF current_setting('max_replication_slots')::int < 1 OR current_setting('max_wal_senders')::int < 1 THEN
    RAISE EXCEPTION 'max_replication_slots (%) and max_wal_senders (%) must each be at least 1 per concurrent DMS task',
      current_setting('max_replication_slots'), current_setting('max_wal_senders');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_roles
     WHERE rolname = current_setting('migration.dms_user')
       AND (rolreplication OR rolsuper)
  ) THEN
    RAISE EXCEPTION 'role % does not exist or has neither REPLICATION nor SUPERUSER: DMS cannot create its replication slot',
      current_setting('migration.dms_user');
  END IF;

  -- DMS ignores UPDATE and DELETE on a table without a primary key. Silently.
  SELECT string_agg(format('%I.%I', n.nspname, c.relname), ', ' ORDER BY 1)
    INTO keyless
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.relkind = 'r'
     AND n.nspname = ANY (string_to_array(current_setting('migration.schemas'), ','))
     AND NOT EXISTS (SELECT 1 FROM pg_constraint p WHERE p.conrelid = c.oid AND p.contype = 'p');

  IF keyless IS NOT NULL THEN
    RAISE EXCEPTION 'tables without a primary key - CDC would drop their UPDATEs and DELETEs: %', keyless;
  END IF;

  RAISE NOTICE 'source prerequisites ok for schemas %', current_setting('migration.schemas');
END
$$;
