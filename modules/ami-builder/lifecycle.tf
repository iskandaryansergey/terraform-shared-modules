# No policy means every AMI ever built keeps its snapshots at $0.05/GB-month
# forever. A monthly pipeline over three years is 36 root snapshots nobody
# removes.
#
# Asymmetric on purpose: DEPRECATE on, DELETE off. Deprecation is reversible and
# only affects discovery, which is enough to stop someone picking last year's
# image. Deletion isn't, so it's opt-in.

resource "aws_imagebuilder_lifecycle_policy" "this" {
  count = local.create && var.create_lifecycle_policy ? 1 : 0

  name           = var.name
  description    = "Retention for images produced by the ${var.name} recipe"
  execution_role = local.lifecycle_role_arn
  resource_type  = "AMI_IMAGE"
  status         = "ENABLED"

  # By tag, not by recipe. resource_selection wants an exact semantic_version,
  # which with content-addressed versions would pin the policy to one version and
  # quietly stop covering anything built after the next edit.
  resource_selection {
    tag_map = {
      "SourceRecipe" = var.name
    }
  }

  policy_detail {
    action {
      type = "DEPRECATE"

      # Without this, only the Image Builder image resource is deprecated and
      # describe-images keeps returning the AMI - i.e. exactly the "stops
      # someone picking last year's image" effect does not happen.
      include_resources {
        amis = true
      }
    }

    filter {
      type  = "AGE"
      value = var.lifecycle_deprecate_after_days
      unit  = "DAYS"

      # Backstop against an aggressive age rule emptying the recipe.
      retain_at_least = var.lifecycle_retain_at_least
    }

    dynamic "exclusion_rules" {
      for_each = length(var.lifecycle_exclude_tags) > 0 ? [1] : []

      content {
        # Image-Builder-resource level.
        tag_map = var.lifecycle_exclude_tags

        # And AMI level. tagMap at the top of exclusion_rules does NOT look at
        # the output AMI's EC2 tags, so an operator tagging an AMI Retain=true
        # got nothing from the top-level map alone.
        amis {
          tag_map = var.lifecycle_exclude_tags
        }
      }
    }
  }

  dynamic "policy_detail" {
    for_each = local.lifecycle_deletes_amis ? [1] : []

    content {
      action {
        type = "DELETE"

        include_resources {
          amis = true
          # Deregistering without the snapshots leaves the storage cost - the
          # exact thing this policy exists for.
          snapshots = true
        }
      }

      filter {
        type            = "AGE"
        value           = var.lifecycle_delete_after_days
        unit            = "DAYS"
        retain_at_least = var.lifecycle_retain_at_least
      }

      exclusion_rules {
        tag_map = length(var.lifecycle_exclude_tags) > 0 ? var.lifecycle_exclude_tags : null

        amis {
          tag_map = length(var.lifecycle_exclude_tags) > 0 ? var.lifecycle_exclude_tags : null

          # Accounts this AMI was shared with launch it without touching the
          # owner's last-launched metadata, so recency alone cannot protect it.
          shared_accounts = length(local.shared_ami_accounts) > 0 ? local.shared_ami_accounts : null

          # Age is a bad proxy for "in use". A six-month-old image something
          # launched yesterday is load-bearing, and deleting it breaks the next
          # scale-out, not the next audit.
          dynamic "last_launched" {
            for_each = var.lifecycle_exclude_recently_launched_days > 0 ? [1] : []

            content {
              value = var.lifecycle_exclude_recently_launched_days
              unit  = "DAYS"
            }
          }

          # true EXCLUDES public AMIs from the action. false was the inverse of
          # the intent: it left a public AMI eligible for deletion.
          is_public = true
        }
      }
    }
  }

  tags = local.common_tags

  lifecycle {
    precondition {
      condition     = local.lifecycle_role_arn != ""
      error_message = "the lifecycle policy needs an execution role. Leave lifecycle_execution_role_arn empty to have the module create one, or supply a role with EC2ImageBuilderLifecycleExecutionPolicy attached."
    }

    precondition {
      # No recency and no tag exemption means deleting purely on age, which is
      # how an in-use AMI disappears.
      condition = !local.lifecycle_deletes_amis ? true : (
        var.lifecycle_exclude_recently_launched_days > 0 ? true : length(var.lifecycle_exclude_tags) > 0
      )
      error_message = "lifecycle_delete_after_days is set with no exemptions: lifecycle_exclude_recently_launched_days is 0 and lifecycle_exclude_tags is empty, so AMIs would be deleted on age alone regardless of whether anything still launches them. Set one of the two."
    }
  }
}
