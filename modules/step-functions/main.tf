# The state machine. The provider validates the definition with AWS's
# ValidateStateMachineDefinition during plan; the preconditions here cover
# what that validator cannot know - the type, the role, the triggers.

resource "aws_sfn_state_machine" "this" {
  count = local.create ? 1 : 0

  name     = var.name
  type     = var.type
  role_arn = local.role_arn
  publish  = var.publish

  definition = var.definition

  # Always written, OFF included: the provider sends this block only when it
  # is present, so dropping it would leave the old level running against a
  # log group the module has just destroyed.
  logging_configuration {
    # The service takes the group's ARN with the :* stream suffix.
    log_destination        = local.logging_on ? "${local.log_group_arn}:*" : null
    include_execution_data = var.logging.include_execution_data
    level                  = var.logging.level
  }

  tracing_configuration {
    enabled = var.tracing
  }

  # Always written, for the same reason: removing kms_key_arn must switch the
  # state machine back to an AWS-owned key, not leave it on a key whose grant
  # the module has just removed.
  encryption_configuration {
    type                              = var.kms_key_arn != "" ? "CUSTOMER_MANAGED_KMS_KEY" : "AWS_OWNED_KEY"
    kms_key_id                        = var.kms_key_arn != "" ? var.kms_key_arn : null
    kms_data_key_reuse_period_seconds = var.kms_key_arn != "" ? var.kms_data_key_reuse_period_seconds : null
  }

  tags = local.common_tags

  # The role's policy before the first execution can start, and the log
  # group before Step Functions sets up delivery to it.
  depends_on = [aws_iam_role_policy.this, aws_cloudwatch_log_group.this]

  lifecycle {
    precondition {
      condition     = local.is_express ? !local.uses_sync_or_callback : true
      error_message = "the definition uses a .sync or .waitForTaskToken integration, which EXPRESS state machines do not support (request-response only). Use STANDARD, or call the service without waiting."
    }

    precondition {
      condition     = local.is_express ? !(var.distributed_map || local.uses_distributed_map) : true
      error_message = "Distributed Map is supported in STANDARD workflows only; its child executions may be EXPRESS."
    }

    precondition {
      condition     = length(local.unknown_aliases) == 0
      error_message = "these aliases are referenced by schedules or event_rules but not declared in aliases: ${join(", ", local.unknown_aliases)}."
    }

    precondition {
      condition     = var.publish ? true : length(local.aliases_on_current) == 0
      error_message = "aliases on version \"current\" need publish = true: there is no published version to point at. Aliases: ${join(", ", local.aliases_on_current)}."
    }

    precondition {
      # IAM counts every inline policy of a role together, without white space.
      condition     = !local.create_role ? true : length(local.role_policy_document) + length(local.caller_policy_document) <= 10240
      error_message = "the role's inline policies total ${length(local.role_policy_document) + length(local.caller_policy_document)} characters, over IAM's 10240. Move role.statements into a managed policy (role.managed_policy_arns)."
    }

    precondition {
      condition     = var.logging.include_execution_data ? local.logging_on : true
      error_message = "logging.include_execution_data needs a logging.level other than OFF."
    }
  }
}
