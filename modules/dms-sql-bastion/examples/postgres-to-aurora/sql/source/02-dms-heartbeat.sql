-- The schema the DMS heartbeat writes to on the source (endpoint
-- postgres.heartbeat_schema). The heartbeat keeps the replication slot moving
-- on a quiet source, so WAL does not pile up on the database you are leaving.

CREATE SCHEMA IF NOT EXISTS dms_heartbeat;
GRANT USAGE, CREATE ON SCHEMA dms_heartbeat TO :"dms_user";
