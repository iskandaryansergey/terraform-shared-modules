-- post-data: applied after the full load, before cutover. Primary keys are
-- already in pre-data, so CDC has them from the first change.

CREATE INDEX account_customer_ix ON core.account (customer_id);
CREATE INDEX account_status_ix   ON core.account (status) WHERE status <> 'CLOSED';

-- Foreign keys last: during the load the child rows arrive before the parents.
ALTER TABLE core.account
  ADD CONSTRAINT account_customer_fk FOREIGN KEY (customer_id)
  REFERENCES core.customer (customer_id);

GRANT SELECT ON ALL TABLES IN SCHEMA core TO app_readonly;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core TO app_service;
