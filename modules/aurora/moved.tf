# =============================================================================
# Moved blocks: from the 1.x interface (aws_rds_cluster.main) to 2.x.
#
# What this file guarantees, and what it cannot
# ---------------------------------------------
# A moved block renames an object in state. It never changes the object in
# AWS. With these blocks, every 1.x object below plans as an UPDATE of itself
# instead of a destroy and a create - for every 1.x layout that shipped:
#
#   early 1.x  aws_db_subnet_group.main had no count   -> chained below
#   late 1.x   aws_db_subnet_group.main[0] (count)      -> chained below
#
# Both layouts are rehearsed against this module by tests/check_moved.py:
# a 1.x state, a plan with -refresh=false, no AWS. It must report every move
# below and no replacement of a cluster, an instance or a subnet group.
#
# A moved block cannot stop a REPLACEMENT that a changed input causes. The
# data survives only if the 2.x inputs equal what is running, above all:
#
#   input                      must equal                     else
#   name                       the old cluster_identifier     cluster REPLACED
#   engine                     the running engine             cluster REPLACED
#   kms_key_arn                the running key (ARN), or ""   cluster REPLACED
#   db_subnet_group_name       the running group's name       cluster REPLACED
#     (1.x created "<cluster_identifier>-subnet-group")
#   instances (map keys)       the old instances keys         instance REPLACED
#   instances.*.availability_zone   unchanged                 instance REPLACED
#   engine_version             the running version, exact     apply refused
#
# docs/UPGRADE-2.0.md section 2 shows how to read each from the running
# cluster. Then gate the plan before anyone applies it:
#
#   terraform show -json plan.tfplan > plan.json
#   python3 tests/check_plan.py plan.json      # fails on a cluster, instance
#                                              # or global cluster replaced or
#                                              # deleted, and on a log group
#                                              # or subnet group deleted
#
# and read the plan for these lines:
#   "has moved to"               one per object below that exists
#   "must be replaced"           must NOT appear on aws_rds_cluster,
#                                aws_rds_cluster_instance, aws_rds_global_cluster
#                                or aws_db_subnet_group
#   "will be destroyed"          only on the objects listed under "Not moved"
#
# Rules for whoever edits this file
# ---------------------------------
#   - Never delete a moved block. A workspace may skip versions; 1.x -> 2.7
#     still needs every block here. Removing one turns that rename into a
#     destroy and a create.
#   - Never reuse a "from" address for a new resource: the block would move
#     unrelated state into it.
#   - A rename in 2.x itself gets its own block here, with the version.
#   - Every change to this file is rehearsed: python3 tests/check_moved.py.
#
# Rules for the caller
# --------------------
#   - Keep the module block's name. These blocks are relative to it; renaming
#     module "db" as well needs a root-level block of your own first:
#       moved { from = module.old_name  to = module.db }
#   - A changed instances key is not a rename this file can know. Keep the
#     keys, or write the move in your root:
#       moved {
#         from = module.db.aws_rds_cluster_instance.this["old"]
#         to   = module.db.aws_rds_cluster_instance.this["new"]
#       }
#     The instance identifier is "<name>-<key>", ForceNew: a new key is a new
#     instance even when moved. Prefer keeping the key.
#
# Not moved, on purpose (the plan destroys and recreates them; no data)
# ---------------------------------------------------------------------
#   aws_cloudwatch_metric_alarm.*          1.x alarms had other names and no
#                                          actions; alarm_name forces a new one
#   aws_iam_role_policy_attachment.enhanced_monitoring
#                                          2.x uses a scoped inline policy
#   aws_vpc_security_group_*_rule.from_*/allow_all
#                                          count-indexed; they go with the old
#                                          security group, which 2.x replaces
#                                          create-before-destroy (new rules
#                                          exist before the old group goes)
#   aws_rds_cluster_role_association.this  aurora-mysql only: 2.x attaches
#                                          those roles on the cluster itself
# =============================================================================

# -----------------------------------------------------------------------------
# Data: the cluster, its instances, the global database
# -----------------------------------------------------------------------------

# 1.x: a single resource. 2.x: count, for create = false.
moved {
  from = aws_rds_cluster.main
  to   = aws_rds_cluster.this[0]
}

# Keyed by the caller's instances map in both; the keys carry over.
moved {
  from = aws_rds_cluster_instance.instances
  to   = aws_rds_cluster_instance.this
}

moved {
  from = aws_rds_global_cluster.main
  to   = aws_rds_global_cluster.this
}

# -----------------------------------------------------------------------------
# Placement: the cluster names its subnet group, and that name is ForceNew on
# the cluster - a lost subnet group is a lost cluster.
# -----------------------------------------------------------------------------

# Two steps, because 1.x shipped both shapes: early 1.x had no count
# (aws_db_subnet_group.main), late 1.x had one (aws_db_subnet_group.main[0]).
# The rename keeps whichever key the state has; the second block then gives a
# key-less object instance [0]. One block with both forms is refused by
# Terraform as ambiguous; one block with either form leaves the other layout
# destroying the group.
moved {
  from = aws_db_subnet_group.main
  to   = aws_db_subnet_group.this
}

moved {
  from = aws_db_subnet_group.this
  to   = aws_db_subnet_group.this[0]
}

# -----------------------------------------------------------------------------
# Connectivity and configuration
# -----------------------------------------------------------------------------

# Moved, then replaced create-before-destroy (the name prefix changed): the
# new group and its rules exist before the cluster lets go of the old one.
moved {
  from = aws_security_group.aurora
  to   = aws_security_group.this
}

moved {
  from = aws_rds_cluster_endpoint.custom
  to   = aws_rds_cluster_endpoint.this
}

moved {
  from = aws_rds_cluster_parameter_group.main
  to   = aws_rds_cluster_parameter_group.this
}

moved {
  from = aws_db_parameter_group.main
  to   = aws_db_parameter_group.this
}

# -----------------------------------------------------------------------------
# Observability and IAM
# -----------------------------------------------------------------------------

# Log groups hold the exported logs: destroying one deletes them. Keyed by
# log type in both versions, named /aws/rds/cluster/<name>/<type>.
moved {
  from = aws_cloudwatch_log_group.aurora_logs
  to   = aws_cloudwatch_log_group.this
}

moved {
  from = aws_iam_role.enhanced_monitoring
  to   = aws_iam_role.monitoring
}

# aws_rds_cluster_activity_stream.this and aws_rds_cluster_role_association.this
# kept their 1.x addresses: no block needed.
