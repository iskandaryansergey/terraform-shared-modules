# RDS Proxy. Each part is create-or-bring: the role (proxy.create_role), the
# secrets (proxy.secret_arns, or the master secret with proxy.use_master_secret),
# the security group (proxy.create_security_group) and the subnets
# (proxy.subnet_ids).

resource "aws_db_proxy" "this" {
  count = local.proxy_enabled ? 1 : 0

  name                   = "${var.name}-proxy"
  engine_family          = local.proxy_engine_family
  role_arn               = local.proxy_role_arn
  vpc_subnet_ids         = local.proxy_subnet_ids
  vpc_security_group_ids = local.proxy_security_group_ids
  require_tls            = var.proxy.require_tls
  idle_client_timeout    = var.proxy.idle_client_timeout
  # Logs full SQL text, parameters included. For a debugging session, not a default.
  debug_logging = var.proxy.debug_logging

  dynamic "auth" {
    for_each = local.proxy_secret_arns
    content {
      auth_scheme               = "SECRETS"
      secret_arn                = auth.value
      iam_auth                  = var.proxy.iam_auth
      client_password_auth_type = var.proxy.client_password_auth_type != "" ? var.proxy.client_password_auth_type : null
      description               = "Database credentials for ${var.name}"
    }
  }

  tags = local.common_tags

  depends_on = [aws_iam_role_policy.proxy]
}

resource "aws_db_proxy_default_target_group" "this" {
  count = local.proxy_enabled ? 1 : 0

  db_proxy_name = aws_db_proxy.this[0].name

  connection_pool_config {
    max_connections_percent      = var.proxy.max_connections_percent
    max_idle_connections_percent = var.proxy.max_idle_connections_percent
    connection_borrow_timeout    = var.proxy.connection_borrow_timeout
    session_pinning_filters      = var.proxy.session_pinning_filters
    init_query                   = var.proxy.init_query != "" ? var.proxy.init_query : null
  }
}

resource "aws_db_proxy_target" "this" {
  count = local.proxy_enabled ? 1 : 0

  db_proxy_name         = aws_db_proxy.this[0].name
  target_group_name     = aws_db_proxy_default_target_group.this[0].name
  db_cluster_identifier = aws_rds_cluster.this[0].cluster_identifier

  # A target with no available instance registers as unavailable.
  depends_on = [aws_rds_cluster_instance.this]
}

resource "aws_db_proxy_endpoint" "reader" {
  count = local.proxy_enabled && var.proxy.create_reader_endpoint ? 1 : 0

  db_proxy_name          = aws_db_proxy.this[0].name
  db_proxy_endpoint_name = "${var.name}-proxy-ro"
  vpc_subnet_ids         = local.proxy_subnet_ids
  vpc_security_group_ids = local.proxy_security_group_ids
  target_role            = "READ_ONLY"

  tags = local.common_tags
}
