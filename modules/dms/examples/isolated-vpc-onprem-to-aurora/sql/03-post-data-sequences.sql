-- post-data, and the step most Oracle -> PostgreSQL cutovers forget.
--
-- DMS migrates rows, not sequence positions. Every identity/serial sequence is
-- still at its starting value, so the application's first insert fails on a
-- duplicate key. Run this after the load and again immediately before cutover,
-- because CDC keeps adding rows in between.

SELECT setval(
  pg_get_serial_sequence('core.customer', 'customer_id'),
  COALESCE((SELECT MAX(customer_id) FROM core.customer), 1)
);

SELECT setval(
  pg_get_serial_sequence('core.account', 'account_id'),
  COALESCE((SELECT MAX(account_id) FROM core.account), 1)
);

-- Put the target back the way the application expects it: the load guard on the
-- target endpoint set session_replication_role = replica for DMS's sessions.
-- This asserts the default is intact for everyone else.
SHOW session_replication_role;
