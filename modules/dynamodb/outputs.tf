output "table_name" {
  description = "Table name."
  value       = one(aws_dynamodb_table.this[*].name)
}

output "table_arn" {
  description = "Table ARN (grant access / reference in IAM policies)."
  value       = one(aws_dynamodb_table.this[*].arn)
}

output "table_id" {
  description = "Table id."
  value       = one(aws_dynamodb_table.this[*].id)
}

output "stream_arn" {
  description = "DynamoDB Stream ARN (null unless stream_enabled) - wire to Lambda/Kinesis."
  value       = one(aws_dynamodb_table.this[*].stream_arn)
}

output "stream_label" {
  description = "Stream label (timestamp), null unless enabled."
  value       = one(aws_dynamodb_table.this[*].stream_label)
}

output "index_arn_pattern" {
  description = "Wildcard ARN for all indexes - drop straight into an IAM policy that needs dynamodb:Query on GSIs/LSIs."
  value       = local.create ? "${one(aws_dynamodb_table.this[*].arn)}/index/*" : null
}

output "gsi_names" {
  description = "Names of the global secondary indexes."
  value       = keys(var.global_secondary_indexes)
}

output "lsi_names" {
  description = "Names of the local secondary indexes."
  value       = keys(var.local_secondary_indexes)
}

output "replica_regions" {
  description = "Regions this table is replicated to (global table)."
  value       = [for r in var.replicas : r.region_name]
}
