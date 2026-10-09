# Named for the family, not with a random suffix: a major upgrade changes the
# family, which changes the name, which with create_before_destroy gives a new
# group alongside the old one for the cluster to move to. The same name on a
# second apply is the same group.

resource "aws_rds_cluster_parameter_group" "this" {
  count = local.create_cluster_parameter_group ? 1 : 0

  name        = "${var.name}-cluster-${replace(local.family, ".", "-")}"
  family      = local.family
  description = "Cluster parameters for ${var.name}"

  dynamic "parameter" {
    for_each = local.effective_cluster_parameters
    content {
      name         = parameter.key
      value        = parameter.value.value
      apply_method = parameter.value.apply_method
    }
  }

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_parameter_group" "this" {
  count = local.create_db_parameter_group ? 1 : 0

  name        = "${var.name}-instance-${replace(local.family, ".", "-")}"
  family      = local.family
  description = "Instance parameters for ${var.name}"

  dynamic "parameter" {
    for_each = var.db_parameters
    content {
      name         = parameter.key
      value        = parameter.value.value
      apply_method = parameter.value.apply_method
    }
  }

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}
