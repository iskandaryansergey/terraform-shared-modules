# Two notification paths, different payloads. The infrastructure config's
# sns_topic_arn gets Image Builder's own message; the rule below gets the state
# change event, which carries the failure reason. Page on the second one.

resource "aws_cloudwatch_event_rule" "image_state" {
  count = local.notifications_enabled ? 1 : 0

  name        = "${var.name}-imagebuilder-state"
  description = "Image Builder state changes for ${var.name}"

  # Three separate defects lived here:
  #   - the detail-type was "EC2 Image Builder State Change". The documented
  #     type is "EC2 Image Builder Image State Change" - one missing word, and
  #     the rule matched nothing while looking configured.
  #   - no resources filter, so it fired on every pipeline in the account while
  #     the message hardcoded this one's name.
  #   - the transformer read $.detail.arn and $.detail.name, neither of which
  #     the event carries. The ARN is in top-level resources[].
  event_pattern = jsonencode({
    source      = ["aws.imagebuilder"]
    detail-type = ["EC2 Image Builder Image State Change"]
    resources = [{
      prefix = "arn:${local.partition}:imagebuilder:${local.region}:${local.account_id}:image/${var.name}/"
    }]
    detail = {
      state = { status = var.notify_on_states }
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "image_state" {
  count = local.notifications_enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.image_state[0].name
  target_id = "sns"
  arn       = var.sns_topic_arn

  # Flattened so it's readable in an email or a chat webhook instead of a wall
  # of event JSON.
  input_transformer {
    input_paths = {
      state = "$.detail.state.status"
      arn   = "$.resources[0]"
      time  = "$.time"
    }

    # <reason> is deliberately absent. EventBridge does not escape transformer
    # substitutions, and an AWSTOE failure reason routinely contains quotes and
    # newlines - which makes the payload invalid JSON and the notification is
    # dropped. The alert would be silenced by exactly the condition it reports.
    # Read the reason from the log group or with verify_commands.last_failure.
    input_template = <<-EOT
      "Image Builder ${var.name} is <state> at <time>. Image: <arn>. Logs: ${local.log_group_name}${local.logging_enabled ? " and s3://${var.log_s3_bucket}/${var.log_s3_prefix}" : " (no S3 log bucket configured)"}"
    EOT
  }
}

# ---------------------------------------------------------------------------
# Checks
#
# Warnings, not refusals. Postures the module will let you have but a reviewer
# should see at plan time.
# ---------------------------------------------------------------------------

check "failed_builds_are_diagnosable" {
  assert {
    # Previously this demanded terminate_instance_on_failure = false when no
    # bucket was set, while build_instance_survives_only_deliberately demanded
    # true - so exactly one of the two always fired and no configuration could
    # satisfy both. log_s3_bucket is now required, so this reduces to the honest
    # question: are the logs going somewhere.
    condition     = local.logging_enabled
    error_message = "log_s3_bucket is empty, so a failed build's component output is discarded. The CloudWatch group carries the service log, not AWSTOE's stdout."
  }
}

check "build_instance_has_no_standing_ssh_credential" {
  assert {
    condition     = var.key_pair_name == ""
    error_message = "key_pair_name is set, which puts a standing SSH credential on a machine holding the build role. Image Builder drives the instance over SSM and does not need it; for debugging use terminate_instance_on_failure = false and SSM Session Manager instead."
  }
}

check "build_instance_survives_only_deliberately" {
  assert {
    condition     = var.terminate_instance_on_failure
    error_message = "terminate_instance_on_failure is false, so a failed build leaves a running instance holding the build role and whatever the components fetched. This is the right setting while debugging and the wrong one to leave committed."
  }
}

check "images_are_scanned" {
  assert {
    condition     = var.enable_image_scanning
    error_message = "enable_image_scanning is false, so nothing checks the image for known CVEs before your fleet launches it. Enable Amazon Inspector EC2 scanning in this account, then set this true."
  }
}

check "snapshots_do_not_accumulate_forever" {
  assert {
    # Asserting create_lifecycle_policy passed while lifecycle_delete_after_days
    # was 0 and nothing was ever deleted - the check certified the opposite of
    # its own error message. Deprecation costs nothing and saves nothing;
    # deletion is the only line that touches the bill.
    condition     = local.lifecycle_deletes_amis
    error_message = "nothing deletes old AMIs: create_lifecycle_policy = ${var.create_lifecycle_policy}, lifecycle_delete_after_days = ${var.lifecycle_delete_after_days}. Deprecation alone does not reclaim snapshot storage, so it grows without bound."
  }
}

check "image_tests_gate_the_ami" {
  assert {
    condition     = var.enable_image_tests
    error_message = "enable_image_tests is false, so the test phase of every component is skipped and a broken build becomes an AMI your fleet will launch."
  }
}

check "imds_is_v2_only" {
  assert {
    condition     = var.imds_http_tokens == "required"
    error_message = "imds_http_tokens is \"optional\", which leaves IMDSv1 reachable on the build instance for the duration of the build."
  }
}

check "parent_image_is_reproducible" {
  assert {
    condition     = !local.parent_unpinned
    error_message = "parent_image resolves at build time, so rebuilding this recipe next month may produce an image from a different base than the one you audited. Pin it to an AMI id or a fully-versioned Image Builder ARN."
  }
}

# The worst defect this module shipped with: a schedule that can never fire.
#
# EXPRESSION_MATCH_AND_DEPENDENCY_UPDATES_AVAILABLE builds only when the base
# image or a component version has changed. With a pinned parent AMI (which
# allow_unpinned_parent_image = false forces) and content-addressed component
# versions that move only on apply, nothing ever changes between applies - so
# the cron fires and does nothing, forever, while the pipeline reports ENABLED
# and governance reports the schedule.
#
# Every term is known at plan time, so this is checkable rather than a comment.
check "the_schedule_can_actually_fire" {
  assert {
    condition = var.schedule_expression == "" ? true : (
      var.pipeline_execution_start_condition == "EXPRESSION_MATCH_ONLY" ? true : (
        local.parent_unpinned ? true : !local.all_components_pinned
      )
    )
    error_message = "schedule_expression is set with EXPRESSION_MATCH_AND_DEPENDENCY_UPDATES_AVAILABLE, but the parent image is pinned and every component version is content-derived - so no dependency can ever update and the schedule will never build anything. Use EXPRESSION_MATCH_ONLY, or accept an unpinned parent."
  }
}

# The build role is the ceiling on what arbitrary component code can reach, and
# it had no advisory check at all while nine strictly lower-impact things did.
check "build_role_blast_radius_was_reviewed" {
  assert {
    condition = length(var.additional_build_policy_arns) == 0 ? true : (
      var.permissions_boundary_arn != ""
    )
    error_message = "additional_build_policy_arns widens a role that runs arbitrary component code as root, and no permissions_boundary_arn is set. Set a boundary, or drop the extra policies."
  }
}

check "imds_hop_limit_is_tight" {
  assert {
    condition     = var.imds_hop_limit <= 2
    error_message = "imds_hop_limit is ${var.imds_hop_limit}, which puts the build role's credentials within reach of anything running in a container during the build."
  }
}

check "cross_region_copies_are_intentional" {
  assert {
    condition     = length(var.distribution_regions) <= 3
    error_message = "the AMI is distributed to more than three extra regions. Each is a full snapshot copy per build, billed for storage in that region plus cross-region transfer — worth confirming every one has a consumer."
  }
}
