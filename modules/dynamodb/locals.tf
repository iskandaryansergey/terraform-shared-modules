locals {
  create = var.create

  common_tags = merge(var.tags, {
    "ManagedBy" = "Terraform"
    "Module"    = "dynamodb"
  })

  provisioned = var.billing_mode == "PROVISIONED"

  # capacity is only meaningful under PROVISIONED; null it out on-demand so the
  # provider doesn't reject stray capacity values.
  table_read_capacity  = local.provisioned ? var.read_capacity : null
  table_write_capacity = local.provisioned ? var.write_capacity : null

  # every key referenced anywhere must be declared in var.attributes - collect
  # the set for a plan-time precondition (clearer than a raw provider error).
  referenced_keys = distinct(concat(
    [var.hash_key],
    var.range_key != "" ? [var.range_key] : [],
    flatten([for k, g in var.global_secondary_indexes : concat([g.hash_key], g.range_key != "" ? [g.range_key] : [])]),
    [for k, l in var.local_secondary_indexes : l.range_key],
  ))
  keys_resolved = alltrue([for a in local.referenced_keys : contains(keys(var.attributes), a)])

  # DynamoDB rejects an AttributeDefinition that isn't part of any key schema, so
  # every declared attribute must be referenced by some key (the reverse of
  # keys_resolved). Together they force attributes == referenced_keys exactly.
  attributes_all_used = alltrue([for a in keys(var.attributes) : contains(local.referenced_keys, a)])

  # secondary-index names must be unique across GSIs *and* LSIs.
  index_names_unique = length(setintersection(
    keys(var.global_secondary_indexes),
    keys(var.local_secondary_indexes),
  )) == 0

  # an attribute can't be both partition and sort key on the same table/index.
  no_dup_table_key = var.range_key == "" || var.range_key != var.hash_key
  gsi_keys_distinct = alltrue([
    for k, g in var.global_secondary_indexes : g.range_key == "" || g.range_key != g.hash_key
  ])
  # an LSI shares the table's partition key, so its sort key must be something else.
  lsi_keys_distinct = alltrue([
    for k, l in var.local_secondary_indexes : l.range_key != var.hash_key
  ])
  # DynamoDB caps LSIs at 5 per table (hard limit, not adjustable).
  lsi_count_ok = length(var.local_secondary_indexes) <= 5

  stream_ok   = length(var.replicas) == 0 || (var.stream_enabled && var.stream_view_type == "NEW_AND_OLD_IMAGES")
  capacity_ok = !local.provisioned || (var.read_capacity > 0 && var.write_capacity > 0)

  # under PROVISIONED every GSI also needs positive capacity (defaults are 0).
  gsi_capacity_ok = !local.provisioned || alltrue([
    for k, g in var.global_secondary_indexes : g.read_capacity > 0 && g.write_capacity > 0
  ])

  # on-demand request caps only make sense on PAY_PER_REQUEST tables.
  on_demand_caps_ok = local.provisioned ? (
    var.max_read_request_units == 0 && var.max_write_request_units == 0 &&
    alltrue([for k, g in var.global_secondary_indexes : g.max_read_request_units == 0 && g.max_write_request_units == 0])
  ) : true

  # table gets an on_demand_throughput block only when a cap is set (on-demand).
  table_on_demand = !local.provisioned && (var.max_read_request_units > 0 || var.max_write_request_units > 0)
}
