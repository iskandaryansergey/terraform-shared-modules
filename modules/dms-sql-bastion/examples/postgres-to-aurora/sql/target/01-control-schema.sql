-- Target groundwork before the schema arrives.
--
-- dms_control: where DMS writes awsdms_apply_exceptions and its status
-- tables (task setting control_schema), instead of the application's schema.
--
-- pg_dump --schema does not carry extensions. Create the ones the migrated
-- schemas use here, e.g.:
--   CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS dms_control;
GRANT USAGE, CREATE ON SCHEMA dms_control TO :"dms_user";
