# A DynamoDB table, secure by default: PITR and deletion protection on, always
# encrypted at rest (AWS-owned key unless you hand it a CMK). Declare each key's
# type once in `attributes` and everything references it by name. On-demand by
# default (with optional spend caps); PROVISIONED with fixed capacity works too.
# Autoscaling is a deliberate non-goal - see the README for why and the workaround.

resource "aws_dynamodb_table" "this" {
  count = local.create ? 1 : 0

  name         = var.name
  billing_mode = var.billing_mode
  hash_key     = var.hash_key
  range_key    = var.range_key != "" ? var.range_key : null
  table_class  = var.table_class

  read_capacity  = local.table_read_capacity
  write_capacity = local.table_write_capacity

  # optional on-demand spend caps (only rendered on a PAY_PER_REQUEST table).
  dynamic "on_demand_throughput" {
    for_each = local.table_on_demand ? [1] : []
    content {
      max_read_request_units  = var.max_read_request_units > 0 ? var.max_read_request_units : null
      max_write_request_units = var.max_write_request_units > 0 ? var.max_write_request_units : null
    }
  }

  deletion_protection_enabled = var.deletion_protection

  dynamic "attribute" {
    for_each = var.attributes
    content {
      name = attribute.key
      type = attribute.value
    }
  }

  dynamic "local_secondary_index" {
    for_each = var.local_secondary_indexes
    content {
      name               = local_secondary_index.key
      range_key          = local_secondary_index.value.range_key
      projection_type    = local_secondary_index.value.projection_type
      non_key_attributes = length(local_secondary_index.value.non_key_attributes) > 0 ? local_secondary_index.value.non_key_attributes : null
    }
  }

  dynamic "global_secondary_index" {
    for_each = var.global_secondary_indexes
    content {
      name               = global_secondary_index.key
      hash_key           = global_secondary_index.value.hash_key
      range_key          = global_secondary_index.value.range_key != "" ? global_secondary_index.value.range_key : null
      projection_type    = global_secondary_index.value.projection_type
      non_key_attributes = length(global_secondary_index.value.non_key_attributes) > 0 ? global_secondary_index.value.non_key_attributes : null
      read_capacity      = local.provisioned ? global_secondary_index.value.read_capacity : null
      write_capacity     = local.provisioned ? global_secondary_index.value.write_capacity : null

      dynamic "on_demand_throughput" {
        for_each = !local.provisioned && (global_secondary_index.value.max_read_request_units > 0 || global_secondary_index.value.max_write_request_units > 0) ? [1] : []
        content {
          max_read_request_units  = global_secondary_index.value.max_read_request_units > 0 ? global_secondary_index.value.max_read_request_units : null
          max_write_request_units = global_secondary_index.value.max_write_request_units > 0 ? global_secondary_index.value.max_write_request_units : null
        }
      }
    }
  }

  dynamic "ttl" {
    for_each = var.ttl_attribute != "" ? [1] : []
    content {
      enabled        = true
      attribute_name = var.ttl_attribute
    }
  }

  point_in_time_recovery {
    enabled = var.point_in_time_recovery
  }

  # Default (no CMK) = the free AWS-owned key: leave the block off so DynamoDB
  # uses it. Supplying kms_key_arn switches to a customer-managed CMK. (enabled =
  # true with no ARN would instead select the cost-bearing aws/dynamodb key.)
  dynamic "server_side_encryption" {
    for_each = var.kms_key_arn != "" ? [1] : []
    content {
      enabled     = true
      kms_key_arn = var.kms_key_arn
    }
  }

  stream_enabled   = var.stream_enabled
  stream_view_type = var.stream_enabled ? var.stream_view_type : null

  dynamic "replica" {
    for_each = { for r in var.replicas : r.region_name => r }
    content {
      region_name            = replica.value.region_name
      kms_key_arn            = try(replica.value.kms_key_arn, null)
      point_in_time_recovery = replica.value.point_in_time_recovery
      propagate_tags         = replica.value.propagate_tags
    }
  }

  tags = local.common_tags

  lifecycle {
    precondition {
      condition     = local.keys_resolved
      error_message = "Every hash_key/range_key (table + GSIs + LSIs) must be declared in var.attributes with a type."
    }
    precondition {
      condition     = local.attributes_all_used
      error_message = "Every attribute in var.attributes must be used as a table/GSI/LSI key; DynamoDB rejects unused attribute definitions."
    }
    precondition {
      condition     = local.index_names_unique
      error_message = "Secondary-index names must be unique across global_secondary_indexes and local_secondary_indexes."
    }
    precondition {
      condition     = local.no_dup_table_key && local.gsi_keys_distinct && local.lsi_keys_distinct
      error_message = "hash_key and range_key must be different attributes (table, each GSI, and each LSI's sort key vs the table hash_key)."
    }
    precondition {
      condition     = local.lsi_count_ok
      error_message = "A table can have at most 5 local secondary indexes (AWS hard limit)."
    }
    precondition {
      condition     = local.capacity_ok
      error_message = "PROVISIONED billing requires read_capacity > 0 and write_capacity > 0."
    }
    precondition {
      condition     = local.gsi_capacity_ok
      error_message = "PROVISIONED billing requires read_capacity > 0 and write_capacity > 0 on every GSI."
    }
    precondition {
      condition     = local.on_demand_caps_ok
      error_message = "max_read/write_request_units are PAY_PER_REQUEST-only; drop them under PROVISIONED."
    }
    precondition {
      condition     = local.stream_ok
      error_message = "replicas (global tables) require stream_enabled = true with stream_view_type = NEW_AND_OLD_IMAGES."
    }
  }
}

resource "aws_dynamodb_contributor_insights" "this" {
  count = local.create && var.contributor_insights ? 1 : 0

  table_name = aws_dynamodb_table.this[0].name
}

resource "aws_dynamodb_resource_policy" "this" {
  count = local.create && var.resource_policy_json != "" ? 1 : 0

  resource_arn = aws_dynamodb_table.this[0].arn
  policy       = var.resource_policy_json
}
