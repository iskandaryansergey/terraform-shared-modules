# The rule says where a zone's queries go. The association attaches it to a VPC.
#
# The association is the step people miss: without it the rule exists, reads
# correctly in the console, and has no effect on resolution whatsoever.

resource "aws_route53_resolver_rule" "this" {
  for_each = local.forward_rules

  name = "${var.name}-${each.key}"
  # Normalised here, not in the variable: AWS lowercases the domain server-side
  # and strips the trailing dot, so passing "Server.BankSvc.NET." verbatim gives
  # a permanent diff on every subsequent plan.
  domain_name = lower(trimsuffix(each.value.domain_name, "."))
  rule_type   = each.value.rule_type

  # A SYSTEM rule takes no endpoint: it stops forwarding rather than
  # redirecting it, so there is nothing to forward through.
  resolver_endpoint_id = each.value.rule_type == "FORWARD" ? local.outbound_endpoint_id : null

  dynamic "target_ip" {
    for_each = each.value.target_ips

    content {
      ip   = target_ip.value
      port = each.value.target_port
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name}-${each.key}" })

  lifecycle {
    precondition {
      # A hard refusal, not a warning: this is the difference between a routing
      # decision and a credential-interception position, and a plan warning is
      # invisible to an automated gate.
      condition     = length(local.hijacks_reserved_namespace) == 0 ? true : var.allow_reserved_namespace_override
      error_message = "these rules forward an AWS or infrastructure namespace: ${join(", ", local.hijacks_reserved_namespace)}. Inside this VPC that redirects service endpoints - sts, secretsmanager, ec2 - to whatever name server you point at, which is an interception position rather than a routing choice. Set allow_reserved_namespace_override = true if this is a deliberate split-horizon design."
    }

    precondition {
      condition     = each.value.rule_type == "FORWARD" ? local.has_outbound_endpoint : true
      error_message = "rule \"${each.key}\" is a FORWARD rule with no endpoint to forward through. Either set create_outbound = true, or point existing_outbound_endpoint_id at an endpoint that already exists - one endpoint serves any number of rules."
    }
  }
}

# One per rule per VPC. A rule has no effect in a VPC it is not associated
# with - it exists, reads correctly in the console, and does nothing.
resource "aws_route53_resolver_rule_association" "this" {
  for_each = local.create ? local.rule_vpc_associations : {}

  name             = "${var.name}-${each.key}"
  resolver_rule_id = aws_route53_resolver_rule.this[each.value.rule_key].id
  vpc_id           = each.value.vpc_id
}

# Share a rule with other accounts, so one endpoint estate serves many VPCs
# instead of every spoke building its own pair of billed ENIs. The receiving
# account still has to associate the rule with its own VPC.
resource "aws_ram_resource_share" "rules" {
  for_each = local.create ? local.shared_rules : {}

  name                      = "${var.name}-${each.key}"
  allow_external_principals = false

  tags = merge(local.common_tags, { Name = "${var.name}-${each.key}" })
}

resource "aws_ram_resource_association" "rules" {
  for_each = local.create ? local.shared_rules : {}

  resource_arn       = aws_route53_resolver_rule.this[each.key].arn
  resource_share_arn = aws_ram_resource_share.rules[each.key].arn
}

resource "aws_ram_principal_association" "rules" {
  for_each = local.create ? local.rule_shares : {}

  principal          = each.value.account
  resource_share_arn = aws_ram_resource_share.rules[each.value.rule_key].arn

  lifecycle {
    precondition {
      # RAM refuses a principal association naming the share's own owner, and a
      # rule is already usable in the account that owns it. Caught here rather
      # than in a validation because it needs the caller identity.
      condition     = each.value.account != local.account_id
      error_message = "share_with for rule \"${each.value.rule_key}\" names this account (${local.account_id}). A resolver rule is already usable in its owning account, and RAM rejects a self-share."
    }
  }
}
