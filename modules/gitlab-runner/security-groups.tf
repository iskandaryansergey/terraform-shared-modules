# Manager: nothing may reach it. It dials out to GitLab and the AWS APIs, and
# dials in to workers.
#
# name_prefix (not name) because both groups are create_before_destroy: a
# replacement has to coexist with the old group, and SG names must be unique per
# VPC.
resource "aws_security_group" "manager" {
  count = local.create ? 1 : 0

  name_prefix = "${var.name}-manager-"
  description = "GitLab runner manager (no inbound)"
  vpc_id      = var.vpc_id
  tags        = merge(local.common_tags, { Name = "${var.name}-manager" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "manager_https" {
  for_each = local.create ? toset(var.manager_egress_cidrs) : toset([])

  security_group_id = aws_security_group.manager[0].id
  description       = "GitLab, AWS APIs, SSM"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

# Workers only ever accept connections from the manager - never from a CIDR, and
# never from the internet.
resource "aws_security_group" "worker" {
  count = local.create ? 1 : 0

  name_prefix = "${var.name}-worker-"
  description = "GitLab runner ephemeral workers"
  vpc_id      = var.vpc_id
  tags        = merge(local.common_tags, { Name = "${var.name}-worker" })

  lifecycle {
    create_before_destroy = true
  }
}

# The fleeting plugin runs jobs over SSH using a short-lived EC2 Instance Connect
# key. Upstream has no SSM tunnelling yet, so this rule is required today - it's
# scoped to the manager's SG, so nothing else in the VPC can reach port 22.
resource "aws_vpc_security_group_ingress_rule" "worker_ssh_from_manager" {
  count = local.create && var.manager_to_worker_ssh ? 1 : 0

  security_group_id            = aws_security_group.worker[0].id
  description                  = "SSH from the runner manager only (ephemeral EC2 Instance Connect key)"
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.manager[0].id
}

resource "aws_vpc_security_group_egress_rule" "manager_to_worker_ssh" {
  count = local.create && var.manager_to_worker_ssh ? 1 : 0

  security_group_id            = aws_security_group.manager[0].id
  description                  = "SSH to workers"
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.worker[0].id
}

# Jobs need to pull images and dependencies. Default excludes RFC1918, so a job
# can't quietly sweep the internal estate on 443.
resource "aws_vpc_security_group_egress_rule" "worker_https" {
  for_each = local.create ? toset(var.worker_egress_cidrs) : toset([])

  security_group_id = aws_security_group.worker[0].id
  description       = "Registries, package mirrors, AWS APIs, SSM"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

# Anything beyond 443 that jobs genuinely need: internal registries, proxies,
# package mirrors on non-standard ports.
resource "aws_vpc_security_group_egress_rule" "worker_extra" {
  for_each = local.create ? {
    for r in flatten([
      for i, rule in var.worker_extra_egress_rules : [
        for c in rule.cidrs : {
          key = "${rule.protocol}-${rule.port}-${c}", protocol = rule.protocol, port = rule.port, cidr = c
        }
      ]
    ]) : r.key => r
  } : {}

  security_group_id = aws_security_group.worker[0].id
  description       = "Caller-supplied egress"
  ip_protocol       = each.value.protocol
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
}

# FINDING-008: a self-managed GitLab is almost always on a private address, which
# the default egress deliberately excludes - so the manager registers (it has
# broad egress) while every job fails to clone. Allow it explicitly.
resource "aws_vpc_security_group_egress_rule" "worker_to_private_gitlab" {
  count = local.create && local.gitlab_is_private ? 1 : 0

  security_group_id = aws_security_group.worker[0].id
  description       = "Self-managed GitLab on a private address"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = local.gitlab_private_cidr
}

# ----------------------------------------------------------------------------
# DNS + NTP. Easy to forget and fatal to omit: a security group with any egress
# rule denies everything else, so without these nothing resolves a hostname and
# the whole fleet fails to bootstrap - silently, because the instances still
# pass their EC2 health check.
# ----------------------------------------------------------------------------
locals {
  # default to the VPC CIDR, where the Amazon-provided resolver lives
  dns_targets = length(var.dns_egress_cidrs) > 0 ? var.dns_egress_cidrs : compact([one(data.aws_vpc.this[*].cidr_block)])

  # {sg_key}-{proto}-{cidr} so every combination gets a stable address
  dns_rules = local.create ? merge([
    for sg_key, sg_id in {
      manager = one(aws_security_group.manager[*].id)
      worker  = one(aws_security_group.worker[*].id)
      } : merge([
        for proto in ["udp", "tcp"] : {
          for cidr in local.dns_targets : "${sg_key}-${proto}-${cidr}" => {
            sg_id = sg_id, proto = proto, cidr = cidr, port = 53, what = "DNS"
          }
        }
    ]...)
  ]...) : {}

  ntp_rules = local.create ? {
    for sg_key, sg_id in {
      manager = one(aws_security_group.manager[*].id)
      worker  = one(aws_security_group.worker[*].id)
      } : "${sg_key}-ntp" => {
      sg_id = sg_id, proto = "udp", cidr = "169.254.169.123/32", port = 123, what = "NTP (Amazon Time Sync)"
    }
  } : {}
}

resource "aws_vpc_security_group_egress_rule" "dns" {
  for_each = merge(local.dns_rules, local.ntp_rules)

  security_group_id = each.value.sg_id
  description       = each.value.what
  ip_protocol       = each.value.proto
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
}

# ----------------------------------------------------------------------------
# OPTIONAL VPC ENDPOINTS - keep SSM/S3 traffic off the NAT gateway. On a fleet
# that pulls images all day the NAT data-processing charge adds up fast. Note the
# three interface endpoints carry their own hourly cost, so this is only a net
# saving once your S3/SSM volume is meaningful.
# ----------------------------------------------------------------------------
resource "aws_security_group" "endpoints" {
  count = local.create && var.create_vpc_endpoints ? 1 : 0

  name_prefix = "${var.name}-vpce-"
  description = "GitLab runner VPC interface endpoints"
  vpc_id      = var.vpc_id
  tags        = merge(local.common_tags, { Name = "${var.name}-vpce" })

  lifecycle {
    create_before_destroy = true
  }
}

# The endpoints we just created sit on RFC1918 addresses INSIDE the VPC - which
# the default egress set deliberately excludes. Without these two rules,
# enabling endpoints creates endpoints the fleet cannot reach.
resource "aws_vpc_security_group_egress_rule" "fleet_to_endpoints" {
  for_each = local.create && var.create_vpc_endpoints ? {
    manager = one(aws_security_group.manager[*].id)
    worker  = one(aws_security_group.worker[*].id)
  } : {}

  security_group_id            = each.value
  description                  = "HTTPS to the module's VPC interface endpoints"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.endpoints[0].id
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_fleet" {
  for_each = local.create && var.create_vpc_endpoints ? {
    manager = one(aws_security_group.manager[*].id)
    worker  = one(aws_security_group.worker[*].id)
  } : {}

  security_group_id            = aws_security_group.endpoints[0].id
  description                  = "HTTPS from the ${each.key}"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = each.value
}

# One subnet per AZ - an interface endpoint rejects two subnets in the same AZ.
resource "aws_vpc_endpoint" "interface" {
  for_each = local.create && var.create_vpc_endpoints ? toset(var.vpc_endpoint_services) : toset([])

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${local.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.endpoint_subnet_ids
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = var.endpoint_private_dns
  tags                = merge(local.common_tags, { Name = "${var.name}-${each.value}" })
}

# The S3 gateway endpoint is the genuinely free win - no hourly charge, and it
# takes container-layer and cache traffic off the NAT gateway entirely.
#
# Scoped to the route tables the WORKER SUBNETS actually use, not every table in
# the VPC: this module does not own the VPC, and rewriting routing for unrelated
# subnets is not ours to do. Note this narrows the blast radius but does not
# prevent collision - two fleets sharing worker subnets resolve the same route
# tables and the second will fail on RouteAlreadyExists. Give each fleet its own
# subnets, or enable endpoints on only one of them.
resource "aws_vpc_endpoint" "s3" {
  count = local.create && var.create_vpc_endpoints ? 1 : 0

  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.worker_route_table_ids
  policy            = var.s3_endpoint_policy_json != "" ? var.s3_endpoint_policy_json : null
  tags              = merge(local.common_tags, { Name = "${var.name}-s3" })
}
