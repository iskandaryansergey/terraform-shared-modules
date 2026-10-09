# Engine features that reach outside the cluster: IAM roles for S3, Lambda,
# Bedrock and friends, and Database Activity Streams. Each one is a path data
# can leave by, which is why none is on by default and each shows in
# output.governance.

# aurora-postgresql only. aurora-mysql takes roles without a feature name, which
# this resource requires - main.tf passes those through the cluster's iam_roles.
resource "aws_rds_cluster_role_association" "this" {
  for_each = local.create && local.is_postgres ? var.cluster_iam_roles : {}

  db_cluster_identifier = aws_rds_cluster.this[0].cluster_identifier
  feature_name          = each.value.feature_name
  role_arn              = each.value.role_arn
}

resource "aws_rds_cluster_activity_stream" "this" {
  count = local.activity_stream_enabled ? 1 : 0

  resource_arn = local.cluster_arn
  mode         = var.activity_stream.mode
  kms_key_id   = local.activity_stream_kms_key_arn

  # The stream starts on running instances.
  depends_on = [aws_rds_cluster.this, aws_rds_cluster_instance.this]

  lifecycle {
    # The provider reads the key back in whatever form AWS returns it - an ARN
    # or a bare key ID - and kms_key_id forces replacement. Restarting the
    # stream over a spelling difference is a gap in the audit record, so the
    # key is set at creation and compared by the
    # activity_stream_key_is_the_one_configured check instead.
    ignore_changes = [kms_key_id]

    precondition {
      condition     = local.activity_stream_kms_key_arn != ""
      error_message = "an activity stream needs a customer-managed key: set activity_stream.kms_key_arn or kms_key_arn."
    }
  }
}
