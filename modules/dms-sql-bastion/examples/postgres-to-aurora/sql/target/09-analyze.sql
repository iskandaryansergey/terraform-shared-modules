-- Fresh statistics after the load and the new indexes, before the application
-- queries the target. Without them the planner works from empty-table guesses.
ANALYZE;
