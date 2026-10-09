# Addresses from the module's previous interface, so an existing deployment
# plans as updates rather than destroy-and-create. The cluster keeps its data
# only if name equals the old cluster_identifier, created_subnet_group_name
# equals the old group's name, and the other ForceNew inputs match - README
# "Upgrading from the previous interface" lists them.

moved {
  from = aws_rds_cluster.main
  to   = aws_rds_cluster.this[0]
}

moved {
  from = aws_rds_cluster_instance.instances
  to   = aws_rds_cluster_instance.this
}

moved {
  from = aws_rds_global_cluster.main
  to   = aws_rds_global_cluster.this
}

moved {
  from = aws_db_subnet_group.main
  to   = aws_db_subnet_group.this
}

moved {
  from = aws_rds_cluster_parameter_group.main
  to   = aws_rds_cluster_parameter_group.this
}

moved {
  from = aws_db_parameter_group.main
  to   = aws_db_parameter_group.this
}

moved {
  from = aws_security_group.aurora
  to   = aws_security_group.this
}

moved {
  from = aws_iam_role.enhanced_monitoring
  to   = aws_iam_role.monitoring
}

moved {
  from = aws_rds_cluster_endpoint.custom
  to   = aws_rds_cluster_endpoint.this
}

moved {
  from = aws_cloudwatch_log_group.aurora_logs
  to   = aws_cloudwatch_log_group.this
}
