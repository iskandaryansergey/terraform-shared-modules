# The job security group is a security control, not plumbing.
#
# The Fargate driver calls ssh.InsecureIgnoreHostKey(): it does NOT verify the job
# task's SSH host key. Whatever answers on the resolved private IP:22 receives the
# manager's session, and that session carries the generated build script - which
# contains CI_JOB_TOKEN and every job variable. The host key also cannot usefully
# be pinned, because it is baked at image build time and shared by every task from
# that image.
#
# So the containment is network-level and it is this file. TWO rules matter, and
# the more important one is easy to mistake for redundant:
#
#   - the MANAGER'S EGRESS rule (manager_ssh_to_job) bounds the set of hosts the
#     manager will open an SSH session to. This is the control: the threat is the
#     manager connecting to something that is not the real job task.
#   - the JOB'S INGRESS rule (job_ssh_from_manager) bounds who may connect to a
#     job task. Defence in depth.
#
# Both are security-group references, never CIDRs. GitLab's own docs suggest
# "source: the VPC CIDR" for the ingress rule; do not do that - it would let
# anything in the VPC answer.
#
# Note the reference image generates a FRESH host key per task
# (docker/job-entrypoint.sh runs ssh-keygen -A at start), so host keys are not
# shared across tasks. Pinning is still impossible because the driver has no
# out-of-band channel to learn a key generated seconds earlier - not, as an
# earlier version of this comment claimed, because the key is baked into the
# image.

resource "aws_security_group" "manager" {
  count = local.create ? 1 : 0

  name_prefix = "${var.name}-manager-"
  description = "GitLab runner manager (${var.name}). No inbound."
  vpc_id      = var.vpc_id
  tags        = merge(local.common_tags, { Name = "${var.name}-manager" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "job" {
  count = local.create ? 1 : 0

  name_prefix = "${var.name}-job-"
  description = "GitLab runner job tasks (${var.name}). Inbound 22 from the manager SG only."
  vpc_id      = var.vpc_id
  tags        = merge(local.common_tags, { Name = "${var.name}-job" })

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# The one rule that matters. SG-to-SG, never a CIDR.
# ---------------------------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "job_ssh_from_manager" {
  count = local.create ? 1 : 0

  security_group_id            = aws_security_group.job[0].id
  referenced_security_group_id = aws_security_group.manager[0].id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  description                  = "Driver SSH from the manager. Host key is NOT verified by the driver, so this rule is the control."
  tags                         = local.common_tags
}

resource "aws_vpc_security_group_egress_rule" "manager_ssh_to_job" {
  count = local.create ? 1 : 0

  security_group_id            = aws_security_group.manager[0].id
  referenced_security_group_id = aws_security_group.job[0].id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  description                  = "Driver SSH to job tasks"
  tags                         = local.common_tags
}

# ---------------------------------------------------------------------------
# Manager egress. Reaching gitlab.com requires the internet; no VPC endpoint
# can substitute, because PrivateLink only reaches AWS services.
# ---------------------------------------------------------------------------
resource "aws_vpc_security_group_egress_rule" "manager_https" {
  for_each = local.create ? toset(var.manager_egress_cidrs) : toset([])

  security_group_id = aws_security_group.manager[0].id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "GitLab and AWS APIs"
  tags              = local.common_tags
}

# ---------------------------------------------------------------------------
# On-prem reachability, over Direct Connect or VPN.
#
# BOTH tiers get it: the manager needs GitLab's API, and job tasks need the same
# host for `git clone` and artifact upload. This is deliberately the one place the
# module grants job tasks access to internal address space, which is why
# on_prem_cidrs is documented as "keep it as narrow as your estate allows".
# ---------------------------------------------------------------------------
resource "aws_vpc_security_group_egress_rule" "manager_on_prem" {
  for_each = local.create ? toset(var.on_prem_cidrs) : toset([])

  security_group_id = aws_security_group.manager[0].id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "On-prem GitLab and internal services (Direct Connect / VPN)"
  tags              = local.common_tags
}

resource "aws_vpc_security_group_egress_rule" "job_on_prem" {
  for_each = local.create ? toset(var.on_prem_cidrs) : toset([])

  security_group_id = aws_security_group.job[0].id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "On-prem GitLab clone and internal registries (Direct Connect / VPN)"
  tags              = local.common_tags
}

# ---------------------------------------------------------------------------
# Pre-existing VPC endpoints owned by the landing zone. SG-to-SG, so the rule
# survives the endpoints changing address.
# ---------------------------------------------------------------------------
resource "aws_vpc_security_group_egress_rule" "fleet_to_existing_endpoints" {
  for_each = local.create ? {
    for pair in setproduct(["manager", "job"], var.existing_endpoint_security_group_ids) :
    "${pair[0]}-${pair[1]}" => { tier = pair[0], sg = pair[1] }
  } : {}

  security_group_id            = each.value.tier == "manager" ? aws_security_group.manager[0].id : aws_security_group.job[0].id
  referenced_security_group_id = each.value.sg
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "HTTPS to pre-existing VPC endpoints (${each.value.tier} tier)"
  tags                         = local.common_tags
}

# ---------------------------------------------------------------------------
# Job egress.
# ---------------------------------------------------------------------------
resource "aws_vpc_security_group_egress_rule" "job_https" {
  for_each = local.create ? toset(local.job_egress) : toset([])

  security_group_id = aws_security_group.job[0].id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Job egress on 443 (private space carved out - see job_egress_exclude_cidrs)"
  tags              = local.common_tags
}

resource "aws_vpc_security_group_egress_rule" "job_extra" {
  for_each = local.create ? local.job_extra_egress : {}

  security_group_id = aws_security_group.job[0].id
  cidr_ipv4         = each.value.cidr
  ip_protocol       = each.value.protocol
  from_port         = each.value.port
  to_port           = each.value.port
  description       = each.value.description != "" ? each.value.description : "job extra egress"
  tags              = local.common_tags
}

# DNS. Easy to forget and silently fatal to omit: with no resolver reachable,
# nothing resolves, the image pull fails, and the task still looks healthy right
# up to the point the job times out.
#
# Scoped to the VPC resolver (base + 2) rather than the whole VPC CIDR. The
# sibling module opened TCP+UDP 53 to the entire VPC, which hands a job a working
# internal liveness-scan primitive on a port that reads as benign in flow logs.
#
# Only the .2 resolver gets a rule - there is deliberately no 169.254.169.253
# rule, because security groups do not filter link-local traffic, so it would be
# inert. If your VPC's DHCP option set points at a custom resolver, that address
# needs a job_extra_egress_rules entry on udp/53 and tcp/53.
resource "aws_vpc_security_group_egress_rule" "dns" {
  for_each = local.create ? {
    for pair in setproduct(
      ["manager", "job"],
      ["udp", "tcp"],
    ) : "${pair[0]}-${pair[1]}" => { tier = pair[0], protocol = pair[1] }
  } : {}

  security_group_id = each.value.tier == "manager" ? aws_security_group.manager[0].id : aws_security_group.job[0].id
  cidr_ipv4         = "${cidrhost(local.vpc_cidr, 2)}/32"
  ip_protocol       = each.value.protocol
  from_port         = 53
  to_port           = 53
  description       = "VPC resolver (${each.value.protocol})"
  tags              = local.common_tags
}

# ---------------------------------------------------------------------------
# VPC endpoints. All-or-nothing on purpose: a partial set does not error, it
# silently falls back to the public endpoint, which in a NAT-free subnet is a
# hang rather than a diagnosis.
# ---------------------------------------------------------------------------
resource "aws_security_group" "endpoints" {
  count = local.create && var.create_vpc_endpoints ? 1 : 0

  name_prefix = "${var.name}-endpoints-"
  description = "Interface endpoints for the ${var.name} runner fleet"
  vpc_id      = var.vpc_id
  tags        = merge(local.common_tags, { Name = "${var.name}-endpoints" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_fleet" {
  for_each = local.create && var.create_vpc_endpoints ? {
    manager = aws_security_group.manager[0].id
    job     = aws_security_group.job[0].id
  } : {}

  security_group_id            = aws_security_group.endpoints[0].id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "HTTPS from the ${each.key} tier"
  tags                         = local.common_tags
}

# Without these the carve-out above blocks the in-VPC endpoints this same flag
# creates - the endpoints live in RFC1918 space, which job_egress excludes.
resource "aws_vpc_security_group_egress_rule" "fleet_to_endpoints" {
  for_each = local.create && var.create_vpc_endpoints ? {
    manager = aws_security_group.manager[0].id
    job     = aws_security_group.job[0].id
  } : {}

  security_group_id            = each.value
  referenced_security_group_id = aws_security_group.endpoints[0].id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "HTTPS to the fleet's interface endpoints"
  tags                         = local.common_tags
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.create && var.create_vpc_endpoints ? toset(local.interface_endpoint_services) : toset([])

  vpc_id            = var.vpc_id
  service_name      = "${local.endpoint_service_prefix}.${local.region}.${each.value}"
  vpc_endpoint_type = "Interface"

  subnet_ids         = local.endpoint_subnet_ids
  security_group_ids = [aws_security_group.endpoints[0].id]

  # Defaults to false - see the endpoint_private_dns variable. Enabling it
  # rewrites resolution for the whole VPC, which this module does not own.
  private_dns_enabled = var.endpoint_private_dns

  policy = local.endpoint_policy

  tags = merge(local.common_tags, { Name = "${var.name}-${each.value}" })
}

# ECR stores image layers in S3, so a GATEWAY endpoint for S3 is required for
# private image pulls on Fargate platform 1.4.0+ - an interface endpoint is not a
# documented substitute. It is also free, unlike the interface endpoints.
resource "aws_vpc_endpoint" "s3" {
  count = local.create && var.create_vpc_endpoints ? 1 : 0

  vpc_id            = var.vpc_id
  service_name      = "${local.endpoint_service_prefix}.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.job_route_table_ids

  policy = local.endpoint_policy

  tags = merge(local.common_tags, { Name = "${var.name}-s3" })

  lifecycle {
    precondition {
      # A gateway endpoint attaches to route tables, and an implicitly-associated
      # subnet resolves to the VPC MAIN route table - which is shared with every
      # other implicitly-associated subnet in the VPC. Adding an S3 route there
      # changes routing for workloads this module does not own, so it is refused
      # rather than done quietly.
      condition     = !local.any_subnet_uses_main_route_table
      error_message = "One or more job/manager subnets have no explicit route table association, so they resolve to the VPC main route table. Attaching the S3 gateway endpoint there would change S3 routing for every other implicitly-associated subnet in the VPC. Give these subnets explicit route tables, or set create_vpc_endpoints = false."
    }
  }
}

# Both endpoint types get a same-account policy.
#
# The AWS default for an endpoint with NO policy is full access, and an
# unpolicied S3 gateway endpoint is a high-bandwidth egress path that the 443
# rules cannot see - anonymous access to a third-party bucket is not gated by IAM
# at all, so a job could exfiltrate a workspace to an open bucket and it would
# look like a cache write in flow logs.
#
# Built with jsonencode rather than aws_iam_policy_document for the same reason
# as the IAM policies: a provider-computed data source is a mock under
# mock_provider, so an assertion about it would test the mock.
locals {
  endpoint_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "SameAccountOnly"
        Effect    = "Allow"
        Principal = "*"
        Action    = "*"
        Resource  = "*"
        Condition = {
          StringEquals = { "aws:PrincipalAccount" = local.account_id }
        }
      },
      {
        # The ECR layer buckets are not in this account, so a strict same-account
        # policy alone would break every image pull. Scoped to the layer-bucket
        # name pattern rather than opened generally.
        Sid       = "AllowEcrLayerBuckets"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "arn:${local.partition}:s3:::prod-${local.region}-starport-layer-bucket/*"
      },
    ]
  })
}
