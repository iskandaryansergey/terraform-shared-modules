resource "aws_imagebuilder_infrastructure_configuration" "this" {
  count = local.create ? 1 : 0

  name                          = var.name
  description                   = var.description != "" ? var.description : "Build infrastructure for ${var.name}"
  instance_profile_name         = local.build_profile_name
  instance_types                = var.instance_types
  subnet_id                     = var.subnet_id
  security_group_ids            = var.security_group_ids
  terminate_instance_on_failure = var.terminate_instance_on_failure

  # Nothing needs inbound - Image Builder reaches the instance over SSM. A key
  # pair here is just a standing SSH credential on a box holding the build role.
  key_pair = var.key_pair_name != "" ? var.key_pair_name : null

  sns_topic_arn = var.sns_topic_arn != "" ? var.sns_topic_arn : null

  instance_metadata_options {
    http_tokens                 = var.imds_http_tokens
    http_put_response_hop_limit = var.imds_hop_limit
  }

  dynamic "logging" {
    for_each = local.logging_enabled ? [1] : []

    content {
      s3_logs {
        s3_bucket_name = var.log_s3_bucket
        s3_key_prefix  = var.log_s3_prefix != "" ? var.log_s3_prefix : null
      }
    }
  }

  dynamic "placement" {
    for_each = anytrue([
      var.instance_placement.availability_zone != "",
      var.instance_placement.tenancy != "",
      var.instance_placement.host_id != "",
      var.instance_placement.host_resource_group_arn != "",
    ]) ? [1] : []

    content {
      availability_zone       = var.instance_placement.availability_zone != "" ? var.instance_placement.availability_zone : null
      tenancy                 = var.instance_placement.tenancy != "" ? var.instance_placement.tenancy : null
      host_id                 = var.instance_placement.host_id != "" ? var.instance_placement.host_id : null
      host_resource_group_arn = var.instance_placement.host_resource_group_arn != "" ? var.instance_placement.host_resource_group_arn : null
    }
  }

  # These land on the build instance and its volumes, not on the Image Builder
  # resource. Without them the instance is anonymous in Cost Explorer and
  # invisible to tag-based SCPs.
  resource_tags = merge(var.build_resource_tags, {
    "ManagedBy"       = "Terraform"
    "Module"          = "ami-builder"
    "ImageBuilderFor" = var.name
  })

  tags = local.common_tags

  lifecycle {
    precondition {
      # Would otherwise fail at the API instead of here.
      condition     = trimspace(local.build_profile_name) != ""
      error_message = "build_instance_profile_name resolved to an empty string or whitespace; leave it unset to have the module create a profile."
    }

    precondition {
      # With a BYO profile the module creates no role, so both of these become
      # silent no-ops. A platform team that mandates a boundary and hands teams a
      # shared profile would get an unbounded shared role and a green plan.
      condition = var.build_instance_profile_name == "" ? true : (
        length(var.additional_build_policy_arns) == 0 && var.permissions_boundary_arn == ""
      )
      error_message = "build_instance_profile_name is set, so this module creates no role - additional_build_policy_arns and permissions_boundary_arn would be silently ignored. Attach them to the profile's role yourself, or drop build_instance_profile_name."
    }
  }
}

# Image Builder creates this group on first build with no expiry, and it then
# grows for the life of the account. Creating it here is how the retention
# actually applies.
#
# If the pipeline name has ever run before - a reused name, an existing pipeline
# being brought under management, a prior sandbox attempt - the group already
# exists and this fails with ResourceAlreadyExistsException. Set
# create_log_group = false, or import it.
resource "aws_cloudwatch_log_group" "this" {
  count = local.create && var.create_log_group && var.log_retention_days > 0 ? 1 : 0

  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn != "" ? var.kms_key_arn : null
  tags              = local.common_tags
}
