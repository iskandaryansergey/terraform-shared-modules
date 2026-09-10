# Replaces Image Builder's managed workflows. Rarely needed - an empty list
# leaves the service defaults, which is right for almost every pipeline.
#
# Worth it when you need a step the default has no place for: a signing stage
# between build and test, or distribution gated on an approval.

locals {
  managed_workflows = { for w in var.workflows : w.name => w if w.arn == "" }

  workflow_hash_input = {
    for name, w in local.managed_workflows : name => jsonencode({
      document = w.document
      uri      = w.uri
      type     = w.type
    })
  }

  # Same hashing as components; workflow versions are immutable too.
  workflow_versions = {
    for name, w in local.managed_workflows : name => (
      var.auto_version
      ? format("%d.%d.%d",
        var.version_major,
        parseint(substr(sha256(local.workflow_hash_input[name]), 0, 4), 16) % 1000,
        parseint(substr(sha256(local.workflow_hash_input[name]), 4, 4), 16) % 1000,
      )
      : var.component_version
    )
  }

  workflow_arns = [
    for w in var.workflows :
    w.arn != "" ? w.arn : try(aws_imagebuilder_workflow.this[w.name].arn, "")
  ]
}

resource "aws_imagebuilder_workflow" "this" {
  for_each = local.create ? local.managed_workflows : {}

  name    = "${var.name}-${each.key}"
  type    = each.value.type
  version = local.workflow_versions[each.key]

  data = each.value.uri == "" ? each.value.document : null
  uri  = each.value.uri != "" ? each.value.uri : null

  change_description = var.auto_version ? "Content hash ${substr(sha256(local.workflow_hash_input[each.key]), 0, 12)}" : null

  kms_key_id = var.kms_key_arn != "" ? var.kms_key_arn : null

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true

    precondition {
      # components.tf has this precondition too, but it lives on a resource with
      # zero instances when every components entry carries an arn - so an
      # all-arn config with a managed workflow reached CreateWorkflow with an
      # empty version.
      condition     = var.auto_version ? true : var.component_version != ""
      error_message = "auto_version = false requires component_version to be set; it doubles as the workflow version and AWS will not accept an empty one."
    }
  }
}
