# The audit record for what this module builds.
#
# A forwarding rule decides where queries go; this is the only thing that
# records what was asked for. Without it a rule being abused - or simply
# misbehaving - leaves no trace, and "what did that workload look up, and when"
# has no answer after the fact.
#
# The config is account-wide and the association is per-VPC, so a shared estate
# creates one config and associates every VPC with it.

resource "aws_route53_resolver_query_log_config" "this" {
  count = local.create_query_logging ? 1 : 0

  name            = var.name
  destination_arn = var.query_log_destination_arn

  tags = merge(local.common_tags, { Name = var.name })
}

resource "aws_route53_resolver_query_log_config_association" "this" {
  for_each = local.create_query_logging ? toset(local.associated_vpc_ids) : toset([])

  resolver_query_log_config_id = aws_route53_resolver_query_log_config.this[0].id
  resource_id                  = each.value
}
