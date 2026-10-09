# The module creates no VPC, subnet or route. It creates a subnet group and
# security groups inside what you give it, or uses yours.
#
# The database security group has exactly the ingress in var.ingress_rules and
# no egress at all unless var.egress_rules adds some. Terraform removes the
# allow-all egress rule AWS puts on a new group.
#
# Rules are keyed by the caller's labels, or by position for brought group
# IDs: never by an ID itself, which may not be known until apply.

resource "aws_db_subnet_group" "this" {
  count = local.create_subnet_group ? 1 : 0

  name        = local.subnet_group_to_create
  description = "Aurora cluster ${var.name}"
  subnet_ids  = var.subnet_ids

  tags = merge(local.common_tags, { "Name" = local.subnet_group_to_create })
}

resource "aws_security_group" "this" {
  count = local.create_security_group ? 1 : 0

  name_prefix = "${var.name}-db-"
  description = "Aurora cluster ${var.name}"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { "Name" = "${var.name}-db" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = local.create_security_group ? var.ingress_rules : {}

  security_group_id = aws_security_group.this[0].id
  description       = each.value.description
  ip_protocol       = "tcp"
  from_port         = local.port
  to_port           = local.port

  cidr_ipv4                    = each.value.cidr_ipv4 != "" ? each.value.cidr_ipv4 : null
  cidr_ipv6                    = each.value.cidr_ipv6 != "" ? each.value.cidr_ipv6 : null
  referenced_security_group_id = each.value.referenced_security_group_id != "" ? each.value.referenced_security_group_id : null
  prefix_list_id               = each.value.prefix_list_id != "" ? each.value.prefix_list_id : null

  tags = merge(local.common_tags, { "Name" = "${var.name}-db-${each.key}" })
}

resource "aws_vpc_security_group_egress_rule" "this" {
  for_each = local.create_security_group ? var.egress_rules : {}

  security_group_id = aws_security_group.this[0].id
  description       = each.value.description
  ip_protocol       = each.value.protocol
  from_port         = each.value.port
  to_port           = each.value.port

  cidr_ipv4                    = each.value.cidr_ipv4 != "" ? each.value.cidr_ipv4 : null
  cidr_ipv6                    = each.value.cidr_ipv6 != "" ? each.value.cidr_ipv6 : null
  referenced_security_group_id = each.value.referenced_security_group_id != "" ? each.value.referenced_security_group_id : null
  prefix_list_id               = each.value.prefix_list_id != "" ? each.value.prefix_list_id : null

  tags = merge(local.common_tags, { "Name" = "${var.name}-db-${each.key}" })
}

# ---------------------------------------------------------------------------
# RDS Proxy security group
#
# Clients reach the proxy on the engine's default port - a proxy always listens
# there, whatever var.port is - and the proxy reaches the database on var.port.
# ---------------------------------------------------------------------------

resource "aws_security_group" "proxy" {
  count = local.create_proxy_security_group ? 1 : 0

  name_prefix = "${var.name}-proxy-"
  description = "RDS Proxy for Aurora cluster ${var.name}"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { "Name" = "${var.name}-proxy" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "proxy" {
  for_each = local.create_proxy_security_group ? var.proxy.ingress_rules : {}

  security_group_id = aws_security_group.proxy[0].id
  description       = each.value.description
  ip_protocol       = "tcp"
  from_port         = local.default_port
  to_port           = local.default_port

  cidr_ipv4                    = each.value.cidr_ipv4 != "" ? each.value.cidr_ipv4 : null
  cidr_ipv6                    = each.value.cidr_ipv6 != "" ? each.value.cidr_ipv6 : null
  referenced_security_group_id = each.value.referenced_security_group_id != "" ? each.value.referenced_security_group_id : null
  prefix_list_id               = each.value.prefix_list_id != "" ? each.value.prefix_list_id : null

  tags = merge(local.common_tags, { "Name" = "${var.name}-proxy-${each.key}" })
}

# The proxy's own outbound needs, chiefly 443 to the Secrets Manager endpoint.
resource "aws_vpc_security_group_egress_rule" "proxy" {
  for_each = local.create_proxy_security_group ? var.proxy.egress_rules : {}

  security_group_id = aws_security_group.proxy[0].id
  description       = each.value.description
  ip_protocol       = each.value.protocol
  from_port         = each.value.port
  to_port           = each.value.port

  cidr_ipv4                    = each.value.cidr_ipv4 != "" ? each.value.cidr_ipv4 : null
  cidr_ipv6                    = each.value.cidr_ipv6 != "" ? each.value.cidr_ipv6 : null
  referenced_security_group_id = each.value.referenced_security_group_id != "" ? each.value.referenced_security_group_id : null
  prefix_list_id               = each.value.prefix_list_id != "" ? each.value.prefix_list_id : null

  tags = merge(local.common_tags, { "Name" = "${var.name}-proxy-${each.key}" })
}

# Proxy to database, both directions of the one hop. Only when the module owns
# both groups; with a brought group on either side, the rule is yours to add -
# output.network_contract says which.
resource "aws_vpc_security_group_egress_rule" "proxy_to_cluster" {
  count = local.create_proxy_security_group && local.create_security_group ? 1 : 0

  security_group_id            = aws_security_group.proxy[0].id
  description                  = "RDS Proxy to Aurora cluster ${var.name}"
  ip_protocol                  = "tcp"
  from_port                    = local.port
  to_port                      = local.port
  referenced_security_group_id = aws_security_group.this[0].id

  tags = merge(local.common_tags, { "Name" = "${var.name}-proxy-to-db" })
}

# Database groups are brought: the proxy still needs a way out to them. The
# matching ingress on those groups is the caller's. Keyed by position, because
# a brought ID can come from a resource the caller creates in the same plan.
resource "aws_vpc_security_group_egress_rule" "proxy_to_brought_groups" {
  for_each = local.create_proxy_security_group && !local.create_security_group ? { for i, sg in var.vpc_security_group_ids : tostring(i) => sg } : {}

  security_group_id            = aws_security_group.proxy[0].id
  description                  = "RDS Proxy to Aurora cluster ${var.name}"
  ip_protocol                  = "tcp"
  from_port                    = local.port
  to_port                      = local.port
  referenced_security_group_id = each.value

  tags = merge(local.common_tags, { "Name" = "${var.name}-proxy-to-db-${each.key}" })
}

resource "aws_vpc_security_group_ingress_rule" "from_proxy" {
  count = local.create_proxy_security_group && local.create_security_group ? 1 : 0

  security_group_id            = aws_security_group.this[0].id
  description                  = "RDS Proxy for ${var.name}"
  ip_protocol                  = "tcp"
  from_port                    = local.port
  to_port                      = local.port
  referenced_security_group_id = aws_security_group.proxy[0].id

  tags = merge(local.common_tags, { "Name" = "${var.name}-db-from-proxy" })
}
