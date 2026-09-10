# Versions are immutable - see locals.component_versions for the hashing.
#
# create_before_destroy is load-bearing: the recipe pins an exact component
# version ARN, and AWS won't delete a component a recipe still references. New
# version first, then the recipe moves, then the old one is free.

resource "aws_imagebuilder_component" "this" {
  for_each = local.create ? local.managed_components : {}

  name     = "${var.name}-${each.key}"
  platform = each.value.platform
  version  = local.component_versions[each.key]

  data = each.value.uri == "" ? local.component_documents[each.key] : null
  uri  = each.value.uri != "" ? each.value.uri : null

  description = each.value.description != "" ? each.value.description : "Component ${each.key} for ${var.name}"

  change_description = var.auto_version ? "Content hash ${substr(sha256(local.component_hash_input[each.key]), 0, 12)}" : null

  supported_os_versions = length(each.value.supported_os_versions) > 0 ? each.value.supported_os_versions : null

  kms_key_id = var.kms_key_arn != "" ? var.kms_key_arn : null

  skip_destroy = var.retain_component_versions

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = var.auto_version ? true : var.component_version != ""
      error_message = "auto_version = false requires component_version to be set; component versions are immutable and AWS will not accept an empty one."
    }
  }
}
