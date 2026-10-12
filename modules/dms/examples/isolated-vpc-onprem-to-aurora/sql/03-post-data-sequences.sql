-- post-data, and the step most Oracle -> PostgreSQL cutovers forget.
--
-- DMS migrates rows, not sequence positions. Every identity sequence is still
-- at its starting value, so the application's first insert fails on a
-- duplicate key. Run this after the load and again immediately before cutover,
-- because CDC keeps adding rows in between.
--
-- pg_get_serial_sequence finds the sequence behind an identity or serial
-- column (01-pre-data-schema.sql declares both id columns as identity). On a
-- column with no sequence it returns NULL and setval does nothing, silently.
--
-- setval(seq, max, true): the next value is max + 1.
-- setval(seq, 1, false):  an empty table starts at 1, not 2.

SELECT setval(
  pg_get_serial_sequence('core.customer', 'customer_id'),
  COALESCE(MAX(customer_id), 1),
  MAX(customer_id) IS NOT NULL
) FROM core.customer;

SELECT setval(
  pg_get_serial_sequence('core.account', 'account_id'),
  COALESCE(MAX(account_id), 1),
  MAX(account_id) IS NOT NULL
) FROM core.account;
