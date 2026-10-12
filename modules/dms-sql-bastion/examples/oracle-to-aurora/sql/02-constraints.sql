-- post-data: secondary indexes, foreign keys, grants.
CREATE INDEX IF NOT EXISTS customer_name_ix ON core.customer (full_name);
