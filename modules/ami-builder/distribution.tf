resource "aws_imagebuilder_distribution_configuration" "this" {
  count = local.create ? 1 : 0

  name        = var.name
  description = var.description != "" ? var.description : "Distribution for ${var.name}"

  dynamic "distribution" {
    for_each = local.distribution_regions

    content {
      region = distribution.value

      ami_distribution_configuration {
        name        = local.ami_name
        description = local.ami_description
        ami_tags    = local.distribution_ami_tags

        # A cross-region copy is re-encrypted with a key in the target region,
        # so one ARN can't cover the set. Absent = AWS-managed key there.
        kms_key_id = local.resolved_kms_key_arns[distribution.value] != "" ? local.resolved_kms_key_arns[distribution.value] : null

        # Copies the AMI into these accounts, which then own it.
        # launch_permission shares one we keep owning. Different things.
        target_account_ids = length(var.target_account_ids) > 0 ? var.target_account_ids : null

        dynamic "launch_permission" {
          for_each = local.has_launch_permission ? [1] : []

          content {
            user_ids                 = length(var.launch_permission.user_ids) > 0 ? var.launch_permission.user_ids : null
            user_groups              = length(var.launch_permission.user_groups) > 0 ? var.launch_permission.user_groups : null
            organization_arns        = length(var.launch_permission.organization_arns) > 0 ? var.launch_permission.organization_arns : null
            organizational_unit_arns = length(var.launch_permission.organizational_unit_arns) > 0 ? var.launch_permission.organizational_unit_arns : null
          }
        }
      }

      # How consumers are meant to read the AMI. Written per region after a
      # successful build, so resolve:ssm:<name> in a launch template picks up
      # new images with no Terraform run.
      dynamic "ssm_parameter_configuration" {
        for_each = var.ami_ssm_parameter_name != "" ? [1] : []

        content {
          parameter_name = var.ami_ssm_parameter_name
          data_type      = "aws:ec2:image"
        }
      }

      # Build region only - launch template ids are region-scoped, so the same
      # id elsewhere points at nothing.
      dynamic "launch_template_configuration" {
        for_each = distribution.value == local.region ? toset(var.update_launch_template_ids) : toset([])

        content {
          launch_template_id = launch_template_configuration.value
          default            = var.set_launch_template_default_version
        }
      }

      dynamic "fast_launch_configuration" {
        for_each = var.fast_launch.enabled && distribution.value == local.region ? [1] : []

        content {
          account_id            = local.account_id
          enabled               = true
          max_parallel_launches = var.fast_launch.max_parallel_launches

          snapshot_configuration {
            target_resource_count = var.fast_launch.target_resource_count
          }
        }
      }
    }
  }

  tags = local.common_tags

  lifecycle {
    precondition {
      # AWS-managed keys can't be shared cross-account, so the target account
      # ends up owning an AMI it can't launch. Fails late and confusingly.
      condition     = length(var.target_account_ids) == 0 ? true : length(local.regions_without_cmk) == 0
      error_message = "target_account_ids requires a customer-managed key in every distribution region: AWS-managed EBS keys cannot be shared cross-account, so the copied AMI would be unlaunchable in the target account. Supply distribution_kms_key_arns for every region."
    }

    precondition {
      condition     = var.require_cmk ? length(local.regions_without_cmk) == 0 : true
      error_message = "require_cmk = true but these distribution regions have no entry in distribution_kms_key_arns, so they would use the AWS-managed EBS key: ${join(", ", local.regions_without_cmk)}."
    }

    precondition {
      condition     = local.ami_is_public ? var.allow_public_ami : true
      error_message = "launch_permission.user_groups includes \"all\", which publishes this AMI to every AWS account. Set allow_public_ami = true if that is genuinely intended."
    }

    precondition {
      condition     = contains(local.distribution_regions, local.region)
      error_message = "the distribution configuration must include the region the pipeline builds in (${local.region})."
    }

    precondition {
      # EC2 caps an AMI description at 255 chars while description allows 1024,
      # and ami_description falls back to it. Otherwise the build runs to
      # completion and dies at distribution.
      condition     = length(local.ami_description) <= 255
      error_message = "the AMI description resolves to ${length(local.ami_description)} characters and EC2 accepts at most 255. It comes from ami_description, or from description when that is empty. The build would finish and then fail at the distribution step."
    }

    precondition {
      # tags + ami_tags + the two the module adds, against EC2's 50-tag ceiling.
      condition     = length(local.distribution_ami_tags) <= 50
      error_message = "the produced AMI would carry ${length(local.distribution_ami_tags)} tags (tags + ami_tags + SourceRecipe and SourceRecipeVersion) and EC2 allows 50 per resource. Trim tags or ami_tags."
    }
  }
}
