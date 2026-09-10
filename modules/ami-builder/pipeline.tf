resource "aws_imagebuilder_image_pipeline" "this" {
  count = local.create && var.create_pipeline ? 1 : 0

  name        = var.name
  description = var.description != "" ? var.description : "Image pipeline ${var.name}"
  status      = var.pipeline_status

  image_recipe_arn                 = aws_imagebuilder_image_recipe.this[0].arn
  infrastructure_configuration_arn = aws_imagebuilder_infrastructure_configuration.this[0].arn
  distribution_configuration_arn   = aws_imagebuilder_distribution_configuration.this[0].arn

  enhanced_image_metadata_enabled = var.enhanced_image_metadata_enabled

  execution_role = var.workflow_execution_role_arn != "" ? var.workflow_execution_role_arn : null

  image_tests_configuration {
    image_tests_enabled = var.enable_image_tests
    timeout_minutes     = var.image_tests_timeout_minutes
  }

  dynamic "image_scanning_configuration" {
    for_each = var.enable_image_scanning ? [1] : []

    content {
      image_scanning_enabled = true
    }
  }

  dynamic "schedule" {
    for_each = var.schedule_expression != "" ? [1] : []

    content {
      schedule_expression = var.schedule_expression
      timezone            = var.schedule_timezone != "" ? var.schedule_timezone : null

      # Default only builds when the parent image or a component changed.
      # EXPRESSION_MATCH_ONLY bills you a new AMI and new snapshots every tick.
      pipeline_execution_start_condition = var.pipeline_execution_start_condition
    }
  }

  dynamic "workflow" {
    for_each = var.workflows

    content {
      workflow_arn   = local.workflow_arns[workflow.key]
      on_failure     = workflow.value.on_failure
      parallel_group = workflow.value.parallel_group != "" ? workflow.value.parallel_group : null

      dynamic "parameter" {
        for_each = workflow.value.parameters

        content {
          name  = parameter.key
          value = parameter.value
        }
      }
    }
  }

  tags = local.common_tags

  lifecycle {
    precondition {
      condition     = length(var.workflows) == 0 ? true : var.workflow_execution_role_arn != ""
      error_message = "workflows requires workflow_execution_role_arn: Image Builder needs a role to assume when running a custom workflow."
    }

    precondition {
      # Dead config that reads as a working control.
      condition     = var.schedule_expression == "" ? true : var.pipeline_status == "ENABLED"
      error_message = "schedule_expression is set but pipeline_status is DISABLED, so the schedule can never fire. Enable the pipeline or drop the schedule."
    }
  }
}

# ---------------------------------------------------------------------------
# One-shot build during apply
#
# The only way to get an AMI id as a Terraform output, and it blocks apply for
# 20-45 minutes. Fine for bootstrapping something that can't start without an
# image. For steady state use the pipeline and ami_ssm_parameter_name.
# ---------------------------------------------------------------------------
resource "aws_imagebuilder_image" "this" {
  count = local.create && var.build_on_apply ? 1 : 0

  image_recipe_arn                 = aws_imagebuilder_image_recipe.this[0].arn
  infrastructure_configuration_arn = aws_imagebuilder_infrastructure_configuration.this[0].arn
  distribution_configuration_arn   = aws_imagebuilder_distribution_configuration.this[0].arn

  enhanced_image_metadata_enabled = var.enhanced_image_metadata_enabled
  execution_role                  = var.workflow_execution_role_arn != "" ? var.workflow_execution_role_arn : null

  image_tests_configuration {
    image_tests_enabled = var.enable_image_tests
    timeout_minutes     = var.image_tests_timeout_minutes
  }

  dynamic "image_scanning_configuration" {
    for_each = var.enable_image_scanning ? [1] : []

    content {
      image_scanning_enabled = true
    }
  }

  # Note this block is a SET on aws_imagebuilder_image (it is a list on the
  # pipeline), so workflow ORDER is not preserved here. Use parallel_group, or
  # the pipeline, if ordering matters.
  dynamic "workflow" {
    for_each = var.workflows

    content {
      workflow_arn   = local.workflow_arns[workflow.key]
      on_failure     = workflow.value.on_failure
      parallel_group = workflow.value.parallel_group != "" ? workflow.value.parallel_group : null

      dynamic "parameter" {
        for_each = workflow.value.parameters

        content {
          name  = parameter.key
          value = parameter.value
        }
      }
    }
  }

  timeouts {
    create = var.build_timeout
  }

  tags = local.common_tags

  lifecycle {
    # Everything upstream is create_before_destroy and this was not, so a recipe
    # version change destroyed the image record first. DeleteImage does NOT
    # delete the AMI or its snapshots, so each replacement left an untracked,
    # billing AMI behind with no owner.
    create_before_destroy = true

    precondition {
      # AWS is allowed to keep building for image_tests_timeout_minutes while
      # Terraform stops waiting at build_timeout. When they disagree, apply
      # abandons an in-flight build and the next apply starts a second one
      # concurrently against the same recipe.
      condition = (
        endswith(var.build_timeout, "h")
        ? tonumber(trimsuffix(var.build_timeout, "h")) * 60
        : (
          endswith(var.build_timeout, "m")
          ? tonumber(trimsuffix(var.build_timeout, "m"))
          : tonumber(trimsuffix(var.build_timeout, "s")) / 60
        )
      ) >= var.image_tests_timeout_minutes
      error_message = "build_timeout (${var.build_timeout}) is shorter than image_tests_timeout_minutes (${var.image_tests_timeout_minutes}), so Terraform can stop waiting while AWS is still building - and the next apply would start a second concurrent build. Raise build_timeout or lower the test timeout."
    }
  }
}
