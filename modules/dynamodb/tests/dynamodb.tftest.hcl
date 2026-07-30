# plan-level, mocked. Table shape is a pure function of the inputs.

mock_provider "aws" {
  mock_resource "aws_dynamodb_table" {
    defaults = { arn = "arn:aws:dynamodb:us-east-1:123456789012:table/mock" }
  }
}

variables {
  name       = "sessions"
  hash_key   = "pk"
  attributes = { pk = "S" }
}

# --- secure defaults: PITR + deletion protection + encryption, on-demand -----
run "secure_defaults" {
  command = apply

  assert {
    condition = alltrue([
      length(aws_dynamodb_table.this) == 1,
      aws_dynamodb_table.this[0].billing_mode == "PAY_PER_REQUEST",
      aws_dynamodb_table.this[0].deletion_protection_enabled == true,
      aws_dynamodb_table.this[0].point_in_time_recovery[0].enabled == true,
      # no CMK -> no SSE block -> the free AWS-owned key (still encrypted at rest)
      length(aws_dynamodb_table.this[0].server_side_encryption) == 0,
    ])
    error_message = "Defaults should be on-demand, PITR on, deletion protection on, AWS-owned encryption"
  }

}

# --- composite key + GSI + LSI, attribute types rendered once ---------------
run "keys_and_indexes" {
  command = apply

  variables {
    hash_key  = "pk"
    range_key = "sk"
    attributes = {
      pk      = "S"
      sk      = "S"
      gsi1pk  = "S"
      lsidate = "N"
    }
    global_secondary_indexes = {
      by-status = { hash_key = "gsi1pk", projection_type = "INCLUDE", non_key_attributes = ["email"] }
    }
    local_secondary_indexes = {
      by-date = { range_key = "lsidate" }
    }
  }

  assert {
    condition = alltrue([
      length(aws_dynamodb_table.this[0].attribute) == 4,
      length(aws_dynamodb_table.this[0].global_secondary_index) == 1,
      length(aws_dynamodb_table.this[0].local_secondary_index) == 1,
      aws_dynamodb_table.this[0].range_key == "sk",
    ])
    error_message = "Composite key + one GSI + one LSI + 4 attributes should render"
  }
}

# --- provisioned capacity ----------------------------------------------------
run "provisioned" {
  command = apply

  variables {
    billing_mode   = "PROVISIONED"
    read_capacity  = 10
    write_capacity = 5
    global_secondary_indexes = {
      by-status = { hash_key = "pk", read_capacity = 3, write_capacity = 2 }
    }
  }

  assert {
    condition = alltrue([
      aws_dynamodb_table.this[0].read_capacity == 10,
      aws_dynamodb_table.this[0].write_capacity == 5,
    ])
    error_message = "PROVISIONED should set base capacity"
  }
}

# --- streams + TTL -----------------------------------------------------------
run "streams_ttl" {
  command = apply

  variables {
    stream_enabled   = true
    stream_view_type = "NEW_AND_OLD_IMAGES"
    ttl_attribute    = "expires_at"
  }

  assert {
    condition = alltrue([
      aws_dynamodb_table.this[0].stream_enabled == true,
      aws_dynamodb_table.this[0].stream_view_type == "NEW_AND_OLD_IMAGES",
      aws_dynamodb_table.this[0].ttl[0].attribute_name == "expires_at",
    ])
    error_message = "Streams + TTL should render"
  }
}

# --- global table replicas ---------------------------------------------------
run "global_table" {
  command = apply

  variables {
    stream_enabled   = true
    stream_view_type = "NEW_AND_OLD_IMAGES"
    replicas = [
      { region_name = "eu-west-1" },
      { region_name = "ap-southeast-2", point_in_time_recovery = true },
    ]
  }

  assert {
    condition     = length(aws_dynamodb_table.this[0].replica) == 2
    error_message = "Two replicas should render"
  }
}

# --- CMK + contributor insights + resource policy ---------------------------
run "cmk_and_extras" {
  command = apply

  variables {
    kms_key_arn          = "arn:aws:kms:us-east-1:123456789012:key/abc"
    contributor_insights = true
    resource_policy_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }

  assert {
    condition = alltrue([
      aws_dynamodb_table.this[0].server_side_encryption[0].kms_key_arn == "arn:aws:kms:us-east-1:123456789012:key/abc",
      length(aws_dynamodb_contributor_insights.this) == 1,
      length(aws_dynamodb_resource_policy.this) == 1,
    ])
    error_message = "CMK + contributor insights + resource policy should wire"
  }
}

# --- create = false ----------------------------------------------------------
run "create_false" {
  command = plan
  variables { create = false }
  assert {
    condition     = length(aws_dynamodb_table.this) == 0
    error_message = "create=false builds nothing"
  }
}

# ============================================================================
# PRECONDITION / VALIDATION FAILURES
# ============================================================================

run "undeclared_key_fails" {
  command = plan
  variables {
    hash_key   = "pk"
    range_key  = "sk" # not in attributes
    attributes = { pk = "S" }
  }
  expect_failures = [aws_dynamodb_table.this]
}

run "gsi_key_not_declared_fails" {
  command = plan
  variables {
    global_secondary_indexes = { gsi = { hash_key = "missing" } }
  }
  expect_failures = [aws_dynamodb_table.this]
}

run "provisioned_without_capacity_fails" {
  command = plan
  variables { billing_mode = "PROVISIONED" }
  expect_failures = [aws_dynamodb_table.this]
}

run "replicas_without_stream_fails" {
  command = plan
  variables {
    replicas = [{ region_name = "eu-west-1" }]
  }
  expect_failures = [aws_dynamodb_table.this]
}

run "bad_attribute_type_fails" {
  command = plan
  variables {
    attributes = { pk = "STRING" }
  }
  expect_failures = [var.attributes]
}

run "gsi_include_without_attrs_fails" {
  command = plan
  variables {
    attributes               = { pk = "S", g = "S" }
    global_secondary_indexes = { idx = { hash_key = "g", projection_type = "INCLUDE" } }
  }
  expect_failures = [var.global_secondary_indexes]
}

run "bad_billing_mode_fails" {
  command = plan
  variables { billing_mode = "ONDEMAND" }
  expect_failures = [var.billing_mode]
}

run "gsi_provisioned_without_capacity_fails" {
  command = plan
  variables {
    billing_mode             = "PROVISIONED"
    read_capacity            = 5
    write_capacity           = 5
    global_secondary_indexes = { gsi = { hash_key = "pk" } } # capacity defaults to 0
  }
  expect_failures = [aws_dynamodb_table.this]
}

run "unused_attribute_fails" {
  command = plan
  variables {
    attributes = { pk = "S", orphan = "S" } # orphan is not any key
  }
  expect_failures = [aws_dynamodb_table.this]
}

run "index_name_collision_fails" {
  command = plan
  variables {
    hash_key                 = "pk"
    range_key                = "sk"
    attributes               = { pk = "S", sk = "S", g = "S" }
    global_secondary_indexes = { dup = { hash_key = "g" } }
    local_secondary_indexes  = { dup = { range_key = "sk" } }
  }
  expect_failures = [aws_dynamodb_table.this]
}

run "duplicate_table_key_fails" {
  command = plan
  variables {
    hash_key   = "pk"
    range_key  = "pk" # same attribute as hash_key
    attributes = { pk = "S" }
  }
  expect_failures = [aws_dynamodb_table.this]
}

run "null_attribute_type_fails" {
  command = plan
  variables {
    attributes = { pk = "S", bad = null }
  }
  expect_failures = [var.attributes]
}

run "gsi_null_hash_key_fails" {
  command = plan
  variables {
    global_secondary_indexes = { gsi = { hash_key = null } }
  }
  expect_failures = [var.global_secondary_indexes]
}

run "lsi_range_equals_table_hash_fails" {
  command = plan
  variables {
    hash_key                = "pk"
    range_key               = "sk"
    attributes              = { pk = "S", sk = "S" }
    local_secondary_indexes = { by-pk = { range_key = "pk" } } # == table hash_key
  }
  expect_failures = [aws_dynamodb_table.this]
}

run "too_many_lsi_fails" {
  command = plan
  variables {
    hash_key   = "pk"
    range_key  = "sk"
    attributes = { pk = "S", sk = "S", a = "S", b = "S", c = "S", d = "S", e = "S", f = "S" }
    local_secondary_indexes = {
      idx1 = { range_key = "a" }, idx2 = { range_key = "b" }, idx3 = { range_key = "c" }
      idx4 = { range_key = "d" }, idx5 = { range_key = "e" }, idx6 = { range_key = "f" }
    }
  }
  expect_failures = [aws_dynamodb_table.this]
}

run "bad_gsi_index_name_fails" {
  command = plan
  variables {
    attributes               = { pk = "S", g = "S" }
    global_secondary_indexes = { "bad name!" = { hash_key = "g" } }
  }
  expect_failures = [var.global_secondary_indexes]
}

run "on_demand_caps_under_provisioned_fails" {
  command = plan
  variables {
    billing_mode           = "PROVISIONED"
    read_capacity          = 5
    write_capacity         = 5
    max_read_request_units = 100 # on-demand cap has no meaning under PROVISIONED
  }
  expect_failures = [aws_dynamodb_table.this]
}

# ============================================================================
# RENDERING COVERAGE
# ============================================================================

run "ttl_enabled_renders" {
  command = apply
  variables { ttl_attribute = "expires_at" }
  assert {
    condition = alltrue([
      length(aws_dynamodb_table.this[0].ttl) == 1,
      aws_dynamodb_table.this[0].ttl[0].enabled == true,
      aws_dynamodb_table.this[0].ttl[0].attribute_name == "expires_at",
    ])
    error_message = "ttl_attribute must render an enabled ttl block"
  }
}

run "ttl_absent_by_default" {
  command = apply
  assert {
    condition     = length(aws_dynamodb_table.this[0].ttl) == 0
    error_message = "No ttl_attribute => no ttl block"
  }
}

run "range_key_null_when_empty" {
  command = apply
  assert {
    condition     = aws_dynamodb_table.this[0].range_key == null
    error_message = "Empty range_key must render as null"
  }
}

run "table_class_infrequent_access" {
  command = apply
  variables { table_class = "STANDARD_INFREQUENT_ACCESS" }
  assert {
    condition     = aws_dynamodb_table.this[0].table_class == "STANDARD_INFREQUENT_ACCESS"
    error_message = "table_class must pass through"
  }
}

run "pitr_disabled_passthrough" {
  command = apply
  variables { point_in_time_recovery = false }
  assert {
    condition     = aws_dynamodb_table.this[0].point_in_time_recovery[0].enabled == false
    error_message = "point_in_time_recovery=false must pass through"
  }
}

run "deletion_protection_disabled_passthrough" {
  command = apply
  variables { deletion_protection = false }
  assert {
    condition     = aws_dynamodb_table.this[0].deletion_protection_enabled == false
    error_message = "deletion_protection=false must pass through"
  }
}

run "sse_block_enabled_with_cmk" {
  command = apply
  variables { kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/abc" }
  assert {
    condition = alltrue([
      length(aws_dynamodb_table.this[0].server_side_encryption) == 1,
      aws_dynamodb_table.this[0].server_side_encryption[0].enabled == true,
    ])
    error_message = "CMK must render an enabled SSE block"
  }
}

run "tags_merged" {
  command = apply
  variables { tags = { Team = "payments", Env = "prod" } }
  assert {
    condition = alltrue([
      aws_dynamodb_table.this[0].tags["ManagedBy"] == "Terraform",
      aws_dynamodb_table.this[0].tags["Module"] == "dynamodb",
      aws_dynamodb_table.this[0].tags["Team"] == "payments",
    ])
    error_message = "common_tags must merge with user tags"
  }
}

run "multiple_gsis_render" {
  command = apply
  variables {
    range_key  = "sk"
    attributes = { pk = "S", sk = "S", g1 = "S", g2 = "N" }
    global_secondary_indexes = {
      by-g1 = { hash_key = "g1", range_key = "sk", projection_type = "ALL" }
      by-g2 = { hash_key = "g2", projection_type = "KEYS_ONLY" }
    }
  }
  assert {
    condition = alltrue([
      length(aws_dynamodb_table.this[0].global_secondary_index) == 2,
      one([for g in aws_dynamodb_table.this[0].global_secondary_index : g.range_key if g.name == "by-g1"]) == "sk",
      one([for g in aws_dynamodb_table.this[0].global_secondary_index : g.range_key if g.name == "by-g2"]) == null,
    ])
    error_message = "Two GSIs render; range_key set on one, null on the other"
  }
}

run "gsi_capacity_passthrough" {
  command = apply
  variables {
    billing_mode   = "PROVISIONED"
    read_capacity  = 10
    write_capacity = 5
    attributes     = { pk = "S", g = "S" }
    global_secondary_indexes = {
      by-g = { hash_key = "g", read_capacity = 3, write_capacity = 2 }
    }
  }
  assert {
    condition = alltrue([
      one([for g in aws_dynamodb_table.this[0].global_secondary_index : g.read_capacity if g.name == "by-g"]) == 3,
      one([for g in aws_dynamodb_table.this[0].global_secondary_index : g.write_capacity if g.name == "by-g"]) == 2,
    ])
    error_message = "GSI capacity must pass through under PROVISIONED"
  }
}

run "lsi_include_projection" {
  command = apply
  variables {
    range_key  = "sk"
    attributes = { pk = "S", sk = "S", ld = "N" }
    local_secondary_indexes = {
      by-date = { range_key = "ld", projection_type = "INCLUDE", non_key_attributes = ["email", "status"] }
    }
  }
  assert {
    condition = alltrue([
      one([for l in aws_dynamodb_table.this[0].local_secondary_index : l.projection_type if l.name == "by-date"]) == "INCLUDE",
      length(one([for l in aws_dynamodb_table.this[0].local_secondary_index : l.non_key_attributes if l.name == "by-date"])) == 2,
    ])
    error_message = "LSI INCLUDE must render non_key_attributes"
  }
}

run "per_replica_settings_render" {
  command = apply
  variables {
    stream_enabled = true
    replicas = [
      { region_name = "eu-west-1", point_in_time_recovery = false, propagate_tags = false },
      { region_name = "ap-southeast-2", point_in_time_recovery = true },
    ]
  }
  assert {
    condition = alltrue([
      length(aws_dynamodb_table.this[0].replica) == 2,
      one([for r in aws_dynamodb_table.this[0].replica : r.point_in_time_recovery if r.region_name == "eu-west-1"]) == false,
      one([for r in aws_dynamodb_table.this[0].replica : r.propagate_tags if r.region_name == "eu-west-1"]) == false,
      one([for r in aws_dynamodb_table.this[0].replica : r.point_in_time_recovery if r.region_name == "ap-southeast-2"]) == true,
    ])
    error_message = "Per-replica PITR/propagate_tags must render from inputs"
  }
}

run "contributor_insights_created" {
  command = apply
  variables { contributor_insights = true }
  assert {
    condition = alltrue([
      length(aws_dynamodb_contributor_insights.this) == 1,
      aws_dynamodb_contributor_insights.this[0].table_name == "sessions",
    ])
    error_message = "contributor_insights=true creates a resource wired to the table"
  }
}

run "resource_policy_arn_wiring" {
  command = apply
  variables { resource_policy_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  assert {
    condition = alltrue([
      length(aws_dynamodb_resource_policy.this) == 1,
      aws_dynamodb_resource_policy.this[0].resource_arn == "arn:aws:dynamodb:us-east-1:123456789012:table/mock",
    ])
    error_message = "resource policy must wire to the table ARN"
  }
}

# --- on-demand throughput caps (FinOps guardrail) ---------------------------
run "on_demand_caps_render" {
  command = apply
  variables {
    max_read_request_units  = 1000
    max_write_request_units = 500
    attributes              = { pk = "S", g = "S" }
    global_secondary_indexes = {
      by-g = { hash_key = "g", max_read_request_units = 200 }
    }
  }
  assert {
    condition = alltrue([
      length(aws_dynamodb_table.this[0].on_demand_throughput) == 1,
      aws_dynamodb_table.this[0].on_demand_throughput[0].max_read_request_units == 1000,
      aws_dynamodb_table.this[0].on_demand_throughput[0].max_write_request_units == 500,
      one([for g in aws_dynamodb_table.this[0].global_secondary_index : one(g.on_demand_throughput).max_read_request_units if g.name == "by-g"]) == 200,
    ])
    error_message = "on-demand request-unit caps must render on the table and GSI"
  }
}

run "on_demand_caps_absent_by_default" {
  command = apply
  assert {
    condition     = length(aws_dynamodb_table.this[0].on_demand_throughput) == 0
    error_message = "no caps set => no on_demand_throughput block"
  }
}

# --- outputs ----------------------------------------------------------------
run "outputs_wiring" {
  command = apply
  variables {
    stream_enabled = true
    attributes     = { pk = "S", g = "S" }
    global_secondary_indexes = {
      by-g = { hash_key = "g" }
    }
    replicas = [{ region_name = "eu-west-1" }, { region_name = "ap-southeast-2" }]
  }
  assert {
    condition = alltrue([
      output.table_name == "sessions",
      output.table_arn == "arn:aws:dynamodb:us-east-1:123456789012:table/mock",
      output.index_arn_pattern == "arn:aws:dynamodb:us-east-1:123456789012:table/mock/index/*",
      length(output.gsi_names) == 1 && contains(output.gsi_names, "by-g"),
      length(output.replica_regions) == 2 && contains(output.replica_regions, "eu-west-1") && contains(output.replica_regions, "ap-southeast-2"),
    ])
    error_message = "Outputs must surface name, ARN, index pattern, GSI names, replica regions"
  }
}

run "outputs_null_when_not_created" {
  command = apply
  variables { create = false }
  assert {
    condition = alltrue([
      output.table_arn == null,
      output.table_name == null,
      output.index_arn_pattern == null,
      length(output.replica_regions) == 0,
    ])
    error_message = "create=false => table outputs null, replica_regions empty"
  }
}
