resource "aws_sfn_alias" "this" {
  for_each = local.create ? var.aliases : {}

  name        = each.key
  description = each.value.description

  dynamic "routing_configuration" {
    for_each = local.alias_routing[each.key]
    content {
      state_machine_version_arn = routing_configuration.value.version
      weight                    = routing_configuration.value.weight
    }
  }
}
