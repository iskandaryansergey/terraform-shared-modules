# One ENI per subnet, billed per hour. Both endpoints exist independently, so
# turning both on doubles that.

resource "aws_route53_resolver_endpoint" "outbound" {
  count = local.create_outbound ? 1 : 0

  name                   = "${var.name}-outbound"
  direction              = "OUTBOUND"
  security_group_ids     = local.outbound_security_group_ids
  protocols              = var.protocols
  resolver_endpoint_type = var.resolver_endpoint_type

  dynamic "ip_address" {
    for_each = var.subnet_ids

    content {
      subnet_id = ip_address.value
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name}-outbound" })

  lifecycle {
    precondition {
      # Making the ABSENCE of the audit record the thing that needs a flag,
      # rather than its presence.
      condition     = var.query_log_destination_arn != "" ? true : var.acknowledge_no_query_logging
      error_message = "no query logging: query_log_destination_arn is empty. That is the audit record for every name resolved through this endpoint, and without it an abused or misbehaving forwarding rule leaves no trace. Set a destination, or acknowledge_no_query_logging = true."
    }

    precondition {
      # The endpoint comes up, the rules attach, and every query times out.
      # Nothing reports it, because an empty security group is a valid one.
      condition     = !local.outbound_without_egress
      error_message = "the outbound endpoint has FORWARD rules but no egress: dns_server_cidrs is empty and no security_group_ids were supplied. The endpoint would be created, look healthy, and every query would time out. Set dns_server_cidrs to the CIDRs holding your DNS servers - a single server is a /32."
    }

    precondition {
      # AWS accepts two subnets in the same AZ. DNS for the entire VPC then has
      # a single point of failure, and nothing says so.
      condition     = !local.single_az
      error_message = "the subnets resolve to ${length(local.resolver_azs)} availability zone(s): ${join(", ", local.resolver_azs)}. Route 53 Resolver accepts this, and it makes DNS for the whole VPC a single point of failure. Use subnets in different AZs."
    }
  }
}

resource "aws_route53_resolver_endpoint" "inbound" {
  count = local.create_inbound ? 1 : 0

  name                   = "${var.name}-inbound"
  direction              = "INBOUND"
  security_group_ids     = local.inbound_security_group_ids
  protocols              = var.protocols
  resolver_endpoint_type = var.resolver_endpoint_type

  dynamic "ip_address" {
    for_each = var.subnet_ids

    content {
      subnet_id = ip_address.value
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name}-inbound" })

  lifecycle {
    precondition {
      condition     = !local.inbound_without_ingress
      error_message = "the inbound endpoint has no ingress: inbound_client_cidrs is empty and no security_group_ids were supplied. It would answer nobody. Set inbound_client_cidrs to the CIDRs your on-premises resolvers query from."
    }

    precondition {
      condition     = !local.single_az
      error_message = "the subnets resolve to ${length(local.resolver_azs)} availability zone(s): ${join(", ", local.resolver_azs)}. Use subnets in different AZs."
    }
  }
}
