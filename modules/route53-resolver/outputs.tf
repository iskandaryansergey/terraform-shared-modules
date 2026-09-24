output "outbound_endpoint_id" {
  description = "The outbound endpoint rules attach to, whether created here or supplied as existing_outbound_endpoint_id. Pass this to other callers so they add rules instead of building a second pair of billed ENIs."
  value       = local.create && local.outbound_endpoint_id != "" ? local.outbound_endpoint_id : null
}

output "inbound_endpoint_id" {
  description = "Inbound endpoint id, if one was created."
  value       = one(aws_route53_resolver_endpoint.inbound[*].id)
}

output "outbound_ips" {
  description = "Addresses the outbound endpoint queries FROM. These are what your DNS servers have to accept traffic from, and they are new addresses - not whatever you already allowed for the workload itself."
  value       = local.outbound_ips
}

output "inbound_ips" {
  description = "Addresses your on-premises resolvers forward TO. Put these in the on-premises conditional forwarder for your AWS private zones."
  value       = local.inbound_ips
}

output "outbound_endpoint_arn" {
  description = "Outbound endpoint ARN, for IAM policies or RAM shares scoped to the endpoint."
  value       = one(aws_route53_resolver_endpoint.outbound[*].arn)
}

output "inbound_endpoint_arn" {
  description = "Inbound endpoint ARN."
  value       = one(aws_route53_resolver_endpoint.inbound[*].arn)
}

output "rule_association_ids" {
  description = "Association id per rule-and-VPC. The association is what makes a rule take effect in a VPC - a rule without one exists and does nothing."
  value       = { for k, a in aws_route53_resolver_rule_association.this : k => a.id }
}

output "ram_share_arns" {
  description = "RAM share ARN per shared rule. The receiving account needs this to accept the share and associate the rule with its own VPCs."
  value       = { for k, s in aws_ram_resource_share.rules : k => s.arn }
}

output "query_log_config_id" {
  description = "Resolver query log config id, if one was created. Associate further VPCs with this rather than creating a second config."
  value       = one(aws_route53_resolver_query_log_config.this[*].id)
}

output "rule_ids" {
  description = "Resolver rule id per key."
  value       = { for k, r in aws_route53_resolver_rule.this : k => r.id }
}

output "rule_arns" {
  description = "Resolver rule ARN per key, for sharing to other accounts outside this module."
  value       = { for k, r in aws_route53_resolver_rule.this : k => r.arn }
}

output "security_group_ids" {
  description = "Security groups created here, by direction. Empty when security_group_ids was supplied, since the module created none."
  # Type-stable: both members are null when not created, so a consumer writing
  # module.resolver.security_group_ids.outbound keeps working when someone
  # flips create - which is the one operation that switch exists to make safe.
  value = {
    outbound = one(aws_security_group.outbound[*].id)
    inbound  = one(aws_security_group.inbound[*].id)
  }
}

# ---------------------------------------------------------------------------
# The request your DNS team actually needs
#
# Everything above is an id. This is the artefact: the addresses, the ports, and
# why - in a form that can be pasted into a change request without translation.
# ---------------------------------------------------------------------------
output "firewall_request" {
  description = "Hand to whoever administers the DNS servers. Terraform cannot open their firewall, and until it is open the queries leave AWS and are dropped - which presents as an unresolvable hostname rather than an error."
  value = !local.create ? null : {
    outbound = local.create_outbound ? {
      direction        = "AWS -> your DNS servers"
      source_addresses = local.outbound_ips
      destinations     = distinct(flatten([for k, r in local.rules_needing_endpoint : r.target_ips]))
      ports            = ["53/udp", "53/tcp"]
      zones            = { for k, r in local.rules_needing_endpoint : k => r.domain_name }
      why              = "Route 53 Resolver forwards these zones from VPC ${var.vpc_id}. Both protocols are required: UDP carries most queries, TCP carries responses too large for UDP. Allowing only UDP works until the first large answer and then fails intermittently."
      note             = "These source addresses are NEW. They are the resolver's own ENIs, not the workload's."
    } : null

    inbound = local.create_inbound ? {
      direction        = "your resolvers -> AWS"
      destinations     = local.inbound_ips
      source_addresses = var.inbound_client_cidrs
      ports            = ["53/udp", "53/tcp"]
      why              = "Point your on-premises conditional forwarder for AWS private zones at these addresses."
    } : null
  }
}

output "verify" {
  description = "Run from a host in the VPC after apply, before trusting anything downstream."
  value = !local.create ? null : {
    step_1_resolver_is_alive = "getent hosts amazon.com    # public names should already resolve"
    step_2_forwarded_zone    = length(local.rules_needing_endpoint) > 0 ? "getent hosts <host>.${values(local.rules_needing_endpoint)[0].domain_name}" : "no FORWARD rules configured"
    step_3_right_answer      = "compare the address returned with the one you can already reach - a public record for the same name would resolve and point somewhere else entirely"
    if_still_empty           = "the DNS servers are not accepting queries from the outbound_ips above. That is the firewall_request output, and no Terraform here fixes it."
    dns_is_not_reachability  = "resolution and connectivity are separate. A name resolving proves the forwarder works, not that anything routes to the address it returned."
  }
}

output "governance" {
  description = "The posture of this resolver estate, as data rather than prose."
  value = !local.create ? null : {
    outbound_created          = local.create_outbound
    inbound_created           = local.create_inbound
    availability_zones        = local.resolver_azs
    single_az                 = local.single_az
    forwarded_zones           = { for k, r in local.forward_rules : k => lower(trimsuffix(r.domain_name, ".")) }
    associated_vpcs           = local.associated_vpc_ids
    uses_existing_endpoint    = var.existing_outbound_endpoint_id != ""
    query_logging_enabled     = local.create_query_logging
    reserved_namespace_rules  = local.hijacks_reserved_namespace
    rules_with_one_dns_server = local.rules_with_one_target
    broad_zone_rules          = local.broad_rules
    shared_with_accounts      = { for k, r in local.shared_rules : k => r.share_with }
    byo_security_groups       = local.byo_security_groups
    # Two ENIs per endpoint, billed hourly, whether or not a query is made.
    billed_enis = (local.create_outbound ? length(var.subnet_ids) : 0) + (local.create_inbound ? length(var.subnet_ids) : 0)
  }
}
