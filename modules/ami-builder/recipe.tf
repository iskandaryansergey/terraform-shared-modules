resource "aws_imagebuilder_image_recipe" "this" {
  count = local.create ? 1 : 0

  name         = var.name
  version      = local.recipe_version
  parent_image = var.parent_image
  description  = var.description != "" ? var.description : "Image recipe ${var.name}"

  working_directory = var.working_directory

  user_data_base64 = var.recipe_user_data != "" ? base64encode(var.recipe_user_data) : null

  # dynamic over the caller's list, not over the computed ARNs. Keys are known
  # at plan time and only the values inside are computed; for_each over a set of
  # ARNs that don't exist yet can't be planned at all.
  dynamic "component" {
    for_each = var.components

    content {
      component_arn = local.component_arns[component.key]

      dynamic "parameter" {
        for_each = component.value.parameters

        content {
          name  = parameter.key
          value = parameter.value
        }
      }
    }
  }

  # "true" as a string - the API takes strings here and the provider mirrors it.
  # A bool is a type error at plan.
  block_device_mapping {
    device_name = local.root_device

    ebs {
      volume_size           = var.root_volume_size_gb
      volume_type           = var.root_volume_type
      iops                  = contains(["gp3", "io1", "io2"], var.root_volume_type) ? var.root_volume_iops : null
      throughput            = var.root_volume_type == "gp3" ? var.root_volume_throughput : null
      encrypted             = "true"
      delete_on_termination = "true"
      kms_key_id            = var.kms_key_arn != "" ? var.kms_key_arn : null
    }
  }

  dynamic "block_device_mapping" {
    for_each = var.additional_block_devices

    content {
      device_name = block_device_mapping.value.device_name

      ebs {
        volume_size           = block_device_mapping.value.size_gb
        volume_type           = block_device_mapping.value.volume_type
        iops                  = contains(["gp3", "io1", "io2"], block_device_mapping.value.volume_type) ? block_device_mapping.value.iops : null
        throughput            = block_device_mapping.value.volume_type == "gp3" ? block_device_mapping.value.throughput : null
        encrypted             = "true"
        delete_on_termination = "true"
        snapshot_id           = block_device_mapping.value.snapshot_id != "" ? block_device_mapping.value.snapshot_id : null
        kms_key_id            = var.kms_key_arn != "" ? var.kms_key_arn : null
      }
    }
  }

  dynamic "systems_manager_agent" {
    for_each = var.uninstall_ssm_agent_after_build ? [1] : []

    content {
      uninstall_after_build = true
    }
  }

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = var.allow_unpinned_parent_image ? true : !local.parent_unpinned
      error_message = "parent_image resolves at build time, so two builds of this recipe can produce different images from different bases. Pin it to an AMI id or a fully-versioned Image Builder ARN, or set allow_unpinned_parent_image = true to accept that."
    }

    precondition {
      condition     = var.auto_version ? true : var.recipe_version != ""
      error_message = "auto_version = false requires recipe_version to be set; recipe versions are immutable and AWS will not accept an empty one."
    }

    precondition {
      # Get the device name wrong and AWS drops the whole mapping - volume size
      # and encryption with it. You get an unencrypted default-sized image and a
      # green build.
      condition     = startswith(local.root_device, "/dev/")
      error_message = "root_device_name must be a /dev/ path matching the parent image's root device."
    }

    precondition {
      # Same trap, checked against the parent we actually read. Nothing else in
      # the module can see it, which is why the governance field has to hedge
      # the encryption claim when this check didn't run.
      condition = local.parent_root_device == null ? true : (
        local.root_device == local.parent_root_device
      )
      error_message = "root_device_name is \"${local.root_device}\" but the parent image's root device is \"${local.parent_root_device_display}\". AWS would silently discard the whole block device mapping - encryption and volume size included - and hand you a green build. Set root_device_name to match, or set verify_parent_image = false to skip this check."
    }

    precondition {
      # Image Builder treats instance_types as a pool and picks whatever is
      # available, so a mixed list is a coin flip: half the builds launch the
      # wrong architecture for the parent and die at instance launch.
      condition     = length(local.instance_type_architectures) == 1
      error_message = "instance_types mixes architectures (${join(", ", local.instance_type_architectures)}). Image Builder picks any type from the list, so builds would fail at instance launch whenever it picks one that does not match the parent image."
    }

    precondition {
      # Otherwise fails ~2 minutes into a build as a generic Image Builder error.
      condition = local.parent_architecture == null ? true : (
        contains(local.instance_type_architectures, local.parent_architecture)
      )
      error_message = "the parent image is ${local.parent_architecture_display} but instance_types resolve to ${join(", ", local.instance_type_architectures)}. The build instance cannot launch from a mismatched architecture."
    }

    precondition {
      # EBS can grow a volume from a snapshot but never shrink one, so this
      # fails at instance launch with nothing built.
      condition = local.parent_root_volume_gb == null ? true : (
        var.root_volume_size_gb >= local.parent_root_volume_gb
      )
      error_message = "root_volume_size_gb is ${var.root_volume_size_gb} but the parent image's root volume is ${local.parent_root_volume_display}. A volume created from a snapshot cannot be smaller than the snapshot, so the build would fail at instance launch."
    }

    precondition {
      condition = length([
        for d in var.additional_block_devices : d.device_name if trimspace(d.device_name) == trimspace(local.root_device)
      ]) == 0
      error_message = "an additional_block_devices entry reuses the root device name, which would override the encrypted root mapping."
    }
  }
}
