# Two security groups, because the directions are opposites:
#
#   outbound  egress to your DNS servers. No ingress at all.
#   inbound   ingress from your on-premises resolvers. No egress needed.
#
# Both protocols in both cases. UDP carries most queries; TCP carries anything
# too large for UDP. Opening only UDP works until the first large response and
# then fails intermittently, which is the least pleasant DNS fault to diagnose.

resource "aws_security_group" "outbound" {
  count = local.create_outbound && !local.byo_security_groups ? 1 : 0

  name_prefix = "${var.name}-resolver-outbound-"
  description = "Route 53 Resolver outbound endpoint - queries to your DNS servers"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${var.name}-resolver-outbound" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "outbound_udp" {
  for_each = local.create_outbound && !local.byo_security_groups ? toset(var.dns_server_cidrs) : toset([])

  security_group_id = aws_security_group.outbound[0].id
  description       = "DNS queries to your resolvers (UDP)"
  cidr_ipv4         = each.value
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"

  tags = local.common_tags
}

resource "aws_vpc_security_group_egress_rule" "outbound_tcp" {
  for_each = local.create_outbound && !local.byo_security_groups ? toset(var.dns_server_cidrs) : toset([])

  security_group_id = aws_security_group.outbound[0].id
  description       = "DNS queries to your resolvers (TCP - responses too large for UDP)"
  cidr_ipv4         = each.value
  from_port         = 53
  to_port           = 53
  ip_protocol       = "tcp"

  tags = local.common_tags
}

resource "aws_security_group" "inbound" {
  count = local.create_inbound && !local.byo_security_groups ? 1 : 0

  name_prefix = "${var.name}-resolver-inbound-"
  description = "Route 53 Resolver inbound endpoint - queries from your on-premises resolvers"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${var.name}-resolver-inbound" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "inbound_udp" {
  for_each = local.create_inbound && !local.byo_security_groups ? toset(var.inbound_client_cidrs) : toset([])

  security_group_id = aws_security_group.inbound[0].id
  description       = "DNS queries from your on-premises resolvers (UDP)"
  cidr_ipv4         = each.value
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"

  tags = local.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "inbound_tcp" {
  for_each = local.create_inbound && !local.byo_security_groups ? toset(var.inbound_client_cidrs) : toset([])

  security_group_id = aws_security_group.inbound[0].id
  description       = "DNS queries from your on-premises resolvers (TCP)"
  cidr_ipv4         = each.value
  from_port         = 53
  to_port           = 53
  ip_protocol       = "tcp"

  tags = local.common_tags
}
