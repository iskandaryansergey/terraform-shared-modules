-- What the DMS user needs on the tables pre-data just created.
--
-- The target endpoint's after_connect_script sets session_replication_role,
-- which also needs rds_superuser for the DMS user - granted by whoever owns
-- the cluster, not by this script.

SELECT set_config('migration.schemas', :'schemas', false),
       set_config('migration.dms_user', :'dms_user', false);

DO $$
DECLARE
  s text;
BEGIN
  FOREACH s IN ARRAY string_to_array(current_setting('migration.schemas'), ',') LOOP
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', s, current_setting('migration.dms_user'));
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA %I TO %I',
                   s, current_setting('migration.dms_user'));
  END LOOP;
END
$$;
