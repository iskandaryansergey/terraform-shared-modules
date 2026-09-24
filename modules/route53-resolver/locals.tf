locals {
  create = var.create

  common_tags = merge(var.tags, {
    "ManagedBy" = "Terraform"
    "Module"    = "route53-resolver"
  })

  partition  = coalesce(one(data.aws_partition.current[*].partition), "aws")
  region     = coalesce(one(data.aws_region.current[*].name), "us-east-1")
  account_id = coalesce(one(data.aws_caller_identity.current[*].account_id), "000000000000")

  create_outbound = local.create && var.create_outbound
  create_inbound  = local.create && var.create_inbound

  create_query_logging = local.create && var.query_log_destination_arn != ""

  # The endpoint a FORWARD rule attaches to: ours, or one that already exists.
  # One endpoint serves any number of rules, so a shared estate creates it once
  # and every other caller points at it.
  outbound_endpoint_id = (
    var.existing_outbound_endpoint_id != ""
    ? var.existing_outbound_endpoint_id
    : try(aws_route53_resolver_endpoint.outbound[0].id, "")
  )

  # A FORWARD rule needs an endpoint from somewhere.
  has_outbound_endpoint = var.create_outbound || var.existing_outbound_endpoint_id != ""

  # Every VPC each rule is associated with. A rule is inert in a VPC it is not
  # associated with, which is the step people miss.
  associated_vpc_ids = distinct(concat([var.vpc_id], var.additional_vpc_associations))

  # One association per rule per VPC.
  rule_vpc_associations = merge([
    for k, r in local.forward_rules : {
      for v in local.associated_vpc_ids : "${k}-${v}" => {
        rule_key = k
        vpc_id   = v
      }
    }
  ]...)

  # BYO security groups turn off the module's own, and with them its ability to
  # tell you which egress rule is missing.
  byo_security_groups = length(var.security_group_ids) > 0

  outbound_security_group_ids = local.byo_security_groups ? var.security_group_ids : [one(aws_security_group.outbound[*].id)]
  inbound_security_group_ids  = local.byo_security_groups ? var.security_group_ids : [one(aws_security_group.inbound[*].id)]

  # -------------------------------------------------------------------------
  # Rules
  # -------------------------------------------------------------------------

  forward_rules = local.create ? var.forward_rules : {}

  # Only FORWARD rules need an endpoint. A SYSTEM rule carves an exception out
  # of a broader forward and has no target at all.
  rules_needing_endpoint = {
    for k, r in local.forward_rules : k => r if r.rule_type == "FORWARD"
  }

  shared_rules = {
    for k, r in local.forward_rules : k => r if length(r.share_with) > 0
  }

  # Flattened for the RAM shares: one share per rule per account.
  rule_shares = merge([
    for k, r in local.shared_rules : {
      for account in r.share_with : "${k}-${account}" => {
        rule_key = k
        account  = account
      }
    }
  ]...)

  # -------------------------------------------------------------------------
  # Posture, computed once
  # -------------------------------------------------------------------------

  # A distinct AZ per subnet is what makes this survive an AZ failure. AWS
  # accepts two subnets in the SAME zone, and then DNS for the whole VPC has a
  # single point of failure that nothing reports.
  resolver_azs = local.create ? distinct([
    for s in data.aws_subnet.resolver : s.availability_zone
  ]) : []

  single_az = length(local.resolver_azs) < 2

  # A forwarded zone whose only name server is one address.
  rules_with_one_target = [
    for k, r in local.rules_needing_endpoint : k if length(distinct(r.target_ips)) == 1
  ]

  # Normalised once: AWS lowercases and strips the trailing dot server-side, so
  # every comparison below has to work on the same form the resource gets.
  rule_domains = {
    for k, r in local.forward_rules : k => lower(trimsuffix(r.domain_name, "."))
  }

  # Namespaces where a forwarding rule is not a routing decision but an
  # interception. Redirecting sts or secretsmanager inside a VPC puts an
  # attacker between every workload and its credentials, and the label-count
  # heuristic below never sees it - those names are three labels deep.
  reserved_suffixes = [
    "amazonaws.com",
    "amazonaws.com.cn",
    "aws",
    "amazon.com",
    "cloudfront.net",
    "internal",
    "ec2.internal",
    "compute.internal",
  ]

  hijacks_reserved_namespace = [
    for k, d in local.rule_domains : k
    if anytrue([
      for s in local.reserved_suffixes : d == s || endswith(d, ".${s}")
    ])
  ]

  # An apex-looking domain forwards everything under it out of this VPC.
  # Computed over ALL rules, not only FORWARD ones: a SYSTEM rule on an apex is
  # a denial-of-resolution primitive with the same blast radius.
  broad_rules = [
    for k, d in local.rule_domains : k
    if length(split(".", d)) <= 2 && !contains(local.reserved_suffixes, d)
  ]

  # Egress is what actually carries the query. Without it the endpoint exists
  # and every lookup times out.
  outbound_without_egress = local.create_outbound && length(local.rules_needing_endpoint) > 0 && !local.byo_security_groups && length(var.dns_server_cidrs) == 0

  inbound_without_ingress = local.create_inbound && !local.byo_security_groups && length(var.inbound_client_cidrs) == 0

  # The addresses the caller's DNS team has to allow. Known only after apply.
  outbound_ips = local.create_outbound ? sort([
    for ip in try(aws_route53_resolver_endpoint.outbound[0].ip_address, []) : ip.ip
  ]) : []

  inbound_ips = local.create_inbound ? sort([
    for ip in try(aws_route53_resolver_endpoint.inbound[0].ip_address, []) : ip.ip
  ]) : []
}
