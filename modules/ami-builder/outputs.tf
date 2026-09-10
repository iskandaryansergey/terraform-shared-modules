output "pipeline_arn" {
  description = "ARN of the image pipeline. This is what you invoke to trigger a build: aws imagebuilder start-image-pipeline-execution --image-pipeline-arn <this>."
  value       = one(aws_imagebuilder_image_pipeline.this[*].arn)
}

output "pipeline_name" {
  description = "Name of the image pipeline."
  value       = one(aws_imagebuilder_image_pipeline.this[*].name)
}

output "recipe_arn" {
  description = "ARN of the image recipe, including its version."
  value       = one(aws_imagebuilder_image_recipe.this[*].arn)
}

output "recipe_version" {
  description = "Resolved recipe version. Under auto_version this is content-derived, so it changes exactly when an input that affects the image changes."
  value       = local.create ? local.recipe_version : null
}

output "infrastructure_configuration_arn" {
  description = "ARN of the build infrastructure configuration."
  value       = one(aws_imagebuilder_infrastructure_configuration.this[*].arn)
}

output "distribution_configuration_arn" {
  description = "ARN of the distribution configuration."
  value       = one(aws_imagebuilder_distribution_configuration.this[*].arn)
}

output "component_arns" {
  description = "Versioned ARN per component, keyed by the name you gave it. Components referenced by arn appear with the ARN you supplied."
  value = local.create ? {
    for idx, c in var.components : c.name => local.component_arns[idx]
  } : {}
}

output "component_versions" {
  description = "Resolved version per component this module created. Useful in a change record: these are the exact versions that went into the image."
  value       = local.create ? local.component_versions : {}
}

output "build_instance_role_arn" {
  description = "ARN of the build instance role. Attach component-specific permissions here via additional_build_policy_arns rather than widening a shared role."
  value       = one(aws_iam_role.build[*].arn)
}

output "build_instance_role_name" {
  description = "Name of the build instance role, for attaching policies externally."
  value       = one(aws_iam_role.build[*].name)
}

output "build_instance_profile_name" {
  description = "Instance profile the build runs under, whether created here or supplied."
  value       = local.create ? local.build_profile_name : null
}

output "lifecycle_policy_arn" {
  description = "ARN of the lifecycle policy, if one was created."
  value       = one(aws_imagebuilder_lifecycle_policy.this[*].arn)
}

output "log_group_name" {
  description = "CloudWatch log group Image Builder writes the service-side build log to."
  value       = local.create ? local.log_group_name : null
}

output "ami_ssm_parameter_name" {
  description = "SSM parameter carrying the latest AMI id, or null if ami_ssm_parameter_name was not set. This is what consumers should read."
  value       = local.create && var.ami_ssm_parameter_name != "" ? var.ami_ssm_parameter_name : null
}

output "ami_id" {
  description = "AMI id from the build_on_apply image, in this region. null unless build_on_apply = true - the pipeline path deliberately keeps AMI ids out of state, because the whole point of a schedule is that new images arrive without a Terraform run."
  value       = one([for a in local.built_amis : a.image if a.region == local.region])
}

output "ami_ids_by_region" {
  description = "Every AMI the build_on_apply image produced, keyed by region. Empty unless build_on_apply = true."
  value       = { for a in local.built_amis : a.region => a.image }
}

output "ami_launch_template_reference" {
  description = "Paste-ready value for a launch template's image_id when consuming via SSM. Resolves at instance launch, so the fleet tracks the pipeline with no Terraform in the path."
  value       = local.create && var.ami_ssm_parameter_name != "" ? "resolve:ssm:${var.ami_ssm_parameter_name}" : null
}

# ---------------------------------------------------------------------------
# Governance posture, as data
#
# Everything a reviewer would otherwise reconstruct by reading the whole config.
# Emitting it makes the posture assertable in tests and greppable in output.
# ---------------------------------------------------------------------------
output "governance" {
  description = "The security and retention posture of this pipeline, as data rather than prose. Assert on it in tests, or diff it in a change review."
  value = !local.create ? null : {
    # Supply chain
    parent_image_pinned = !local.parent_unpinned
    parent_image_owner  = local.parent_owner
    # The bundled hardening and docker components run dnf without version pins,
    # so a pinned parent does not make the image reproducible on its own.
    components_fetch_from_moving_sources = length([
      for c in var.components : c.name
      if contains(["amazon-linux-hardening", "install-docker"], c.bundled)
    ]) > 0

    # Encryption. snapshots_encrypted is not a claim about the whole image: if
    # root_device_name doesn't match the parent's actual root device, AWS
    # discards the mapping and encryption goes with it, which Terraform cannot
    # see. Hence the qualified name.
    snapshots_encrypted_if_root_device_matches_parent = true
    root_device                                       = local.root_device
    # These are null when parent_image is not a plain AMI id, or when
    # verify_parent_image is false. Populated means the recipe preconditions
    # have checked them.
    parent_image_verified_at_plan  = local.parent_root_device != null
    parent_image_root_device       = local.parent_root_device
    parent_image_architecture      = local.parent_architecture
    parent_image_root_volume_gb    = local.parent_root_volume_gb
    parent_image_deprecated        = local.parent_deprecated
    parent_image_marketplace_codes = local.parent_product_codes
    customer_managed_key           = length(local.regions_without_cmk) == 0
    regions_without_cmk            = local.regions_without_cmk

    # Build instance
    imds_v2_required           = var.imds_http_tokens == "required"
    imds_hop_limit             = var.imds_hop_limit
    build_instance_has_keypair = var.key_pair_name != ""
    terminates_on_failure      = var.terminate_instance_on_failure

    # Blast radius of the role that runs arbitrary component code as root.
    byo_instance_profile         = var.build_instance_profile_name != ""
    permissions_boundary         = var.permissions_boundary_arn
    additional_build_policy_arns = var.additional_build_policy_arns

    # Gates
    image_tests_enabled    = var.enable_image_tests
    vulnerability_scanning = var.enable_image_scanning
    build_log_bucket       = var.log_s3_bucket
    log_retention_days     = var.log_retention_days

    # Alerting. A topic with no DLQ can drop every failure notification without
    # anything anywhere going red.
    notifications_enabled           = local.notifications_enabled
    notification_states             = var.notify_on_states
    notification_failures_go_to_dlq = var.event_dead_letter_queue_arn != ""

    # Retention, which is also the rollback window - see ROLLOUT.md. You cannot
    # roll back to an image the policy has deleted, and retain_at_least is the
    # floor that survives every age rule.
    component_versions_retained = var.retain_component_versions
    lifecycle_policy_enabled    = var.create_lifecycle_policy
    lifecycle_deletes_amis      = local.lifecycle_deletes_amis
    lifecycle_delete_after_days = var.lifecycle_delete_after_days
    # The two together are the rollback window: how many images survive whatever
    # the age rules say, and when the age rule takes the rest.
    rollback_depth_images = var.lifecycle_retain_at_least

    # Distribution. org and OU shares get their own fields: rolled into
    # "shared_with_accounts" they'd report an org-wide share as shared with
    # nobody.
    ami_is_public                    = local.ami_is_public
    shared_with_accounts             = var.launch_permission.user_ids
    shared_with_organizations        = var.launch_permission.organization_arns
    shared_with_organizational_units = var.launch_permission.organizational_unit_arns
    distributed_to_accounts          = var.target_account_ids
    distribution_regions             = local.distribution_regions

    # Schedule
    rebuild_schedule        = var.schedule_expression != "" ? var.schedule_expression : "none - manual invocation only"
    rebuilds_only_on_change = var.pipeline_execution_start_condition == "EXPRESSION_MATCH_AND_DEPENDENCY_UPDATES_AVAILABLE"
    # A schedule that cannot fire is worse than no schedule, because it reports
    # as a cadence. See check "the_schedule_can_actually_fire".
    schedule_can_fire = (
      var.schedule_expression == "" ? false : (
        var.pipeline_execution_start_condition == "EXPRESSION_MATCH_ONLY" ? true : (
          local.parent_unpinned ? true : !local.all_components_pinned
        )
      )
    )
  }
}

# ---------------------------------------------------------------------------
# Network prerequisites
# ---------------------------------------------------------------------------
output "network_contract" {
  description = <<-EOT
    What the build needs from YOUR network, as data rather than prose - hand it
    to whoever owns the VPC.

    This module creates no network resources. Nothing here is enforced, and in a
    VPC with no internet route a missing endpoint fails as a HANG partway through
    a build, not as an error: AWSTOE resolves the public API name, gets no route,
    and waits until the build times out.
  EOT
  value = !local.create ? null : {
    subnet_id          = var.subnet_id
    security_group_ids = var.security_group_ids

    required_interface_endpoints = local.required_interface_endpoints

    gateway_endpoints = [
      "s3 - free, and required: AWSTOE fetches component documents from S3, and the AL2023 dnf repositories are S3-backed",
    ]

    required_egress = [
      "443 -> the interface endpoints above",
      "443 -> S3 gateway endpoint",
      "443 -> wherever your components fetch from (internal mirror, CodeArtifact, private registry)",
      "53  -> your DNS resolver (UDP and TCP)",
    ]

    required_ingress = [
      "none - Image Builder drives the build instance through SSM, outbound-initiated",
    ]

    notes = [
      "Interface endpoints need private DNS enabled, or the instance resolves the public name and hangs instead of erroring.",
      "There is deliberately no imagebuilder endpoint in the list: the build instance talks to SSM, not to the Image Builder control plane.",
      "No KMS endpoint is needed for EBS or SSM encryption - both call KMS service-side. It IS needed if a component calls KMS itself.",
      "Build logs go to s3://${var.log_s3_bucket}, reachable over the S3 gateway endpoint.",
    ]
  }
}

# ---------------------------------------------------------------------------
# Key policies the CALLER has to write
#
# Same reasoning as network_contract: the module cannot set a key policy, and
# every entry here fails at a different time and in a different way when it is
# missing - one of them by producing a log group that exists and stays
# permanently empty.
# ---------------------------------------------------------------------------
output "kms_key_policy_requirements" {
  description = "Key-policy statements your CMKs need, as data. Empty when no customer-managed key is in play. Hand it to whoever owns KMS."
  # A comprehension, not a ternary: two tuples of different LENGTH cannot unify
  # in a conditional, and `[]` is a zero-length tuple. This yields the right
  # shape in both cases.
  value = [for r in local.kms_key_policy_requirements : r if local.create]
}

# ---------------------------------------------------------------------------
# The SNS topic policy is the caller's job too
#
# The module creates the rule and the target but owns no topic, and an
# aws_sns_topic_policy here would replace whatever policy the topic already has.
# Without these statements the publish is simply denied and the notification is
# gone - EventBridge does not retry into a permission error forever, and nothing
# turns red.
# ---------------------------------------------------------------------------
output "sns_topic_policy_requirement" {
  description = "Statements sns_topic_arn's resource policy needs for build notifications to arrive, as data. null when no topic is configured."
  value = !local.create || var.sns_topic_arn == "" ? null : {
    topic = var.sns_topic_arn
    statements = concat(
      [
        {
          principal = "imagebuilder.amazonaws.com"
          actions   = ["sns:Publish"]
          condition = "StringEquals on aws:SourceAccount = ${local.account_id}"
          why       = "the infrastructure configuration publishes Image Builder's own build messages to this topic."
        },
      ],
      local.notifications_enabled ? [
        {
          principal = "events.amazonaws.com"
          actions   = ["sns:Publish"]
          condition = "ArnEquals on aws:SourceArn = ${one(aws_cloudwatch_event_rule.image_state[*].arn)}"
          why       = "the EventBridge rule created here carries the failure reason. This is the notification worth paging on, and it is the one that silently disappears without the statement."
        },
      ] : [],
    )
  }
}

output "verify_commands" {
  description = "Copy-paste checks for what actually goes wrong. The first three are for a hung build, which is this module's documented first-run failure mode."
  value = !local.create ? null : {
    # A missing endpoint fails as a hang, so start by getting onto the box. The
    # ImageBuilderFor tag exists for exactly this.
    find_build_instance = "aws ec2 describe-instances --filters Name=tag:ImageBuilderFor,Values=${var.name} Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text"
    shell_on_build      = "aws ssm start-session --target <instance-id-from-find_build_instance>"
    cancel_stuck_build  = "aws imagebuilder cancel-image-creation --image-build-version-arn <arn-from-list_builds>"

    why_no_build  = var.create_pipeline ? "aws imagebuilder get-image-pipeline --image-pipeline-arn ${local.pipeline_arn_or_note} --query 'imagePipeline.[status,dateLastRun,dateNextRun]'" : "no pipeline (create_pipeline = false)"
    trigger_build = var.create_pipeline ? "aws imagebuilder start-image-pipeline-execution --image-pipeline-arn ${local.pipeline_arn_or_note}" : "no pipeline (create_pipeline = false); build from the recipe directly"
    list_builds   = "aws imagebuilder list-image-pipeline-images --image-pipeline-arn ${local.pipeline_arn_or_note} --query 'reverse(sort_by(imageSummaryList,&dateCreated))[*].[version,state.status,dateCreated]' --output table"
    # sorted: taking [0] of an unsorted list returns a months-old reason.
    last_failure = "aws imagebuilder list-image-pipeline-images --image-pipeline-arn ${local.pipeline_arn_or_note} --query 'reverse(sort_by(imageSummaryList[?state.status==`FAILED`],&dateCreated))[0].state.reason' --output text"

    current_ami = var.ami_ssm_parameter_name != "" ? "aws ssm get-parameter --name ${var.ami_ssm_parameter_name} --query Parameter.Value --output text" : "ami_ssm_parameter_name not set; aws ec2 describe-images --owners self --filters Name=tag:SourceRecipe,Values=${var.name} --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text"

    build_logs  = "aws s3 sync s3://${var.log_s3_bucket}/${trimsuffix(var.log_s3_prefix != "" ? var.log_s3_prefix : "imagebuilder", "/")}/${var.name}/ ./imagebuilder-logs/"
    service_log = "aws logs tail ${local.log_group_name} --since 2h"

    # The FinOps question about a cost-conscious module.
    snapshot_spend    = "aws ec2 describe-images --owners self --filters Name=tag:SourceRecipe,Values=${var.name} --query 'Images[].BlockDeviceMappings[].Ebs.SnapshotId' --output text | xargs -r aws ec2 describe-snapshots --snapshot-ids --query 'sum(Snapshots[].VolumeSize)'"
    lifecycle_actions = var.create_lifecycle_policy ? "aws imagebuilder list-lifecycle-execution-resources --lifecycle-execution-id <id-from-list-lifecycle-executions>" : "no lifecycle policy created"

    # Rollback. Full sequence and the reasoning in ROLLOUT.md; these are the
    # three commands you want at 3am, in order.
    rollback_candidates    = "aws ec2 describe-images --owners self --filters Name=tag:SourceRecipe,Values=${var.name} --query 'reverse(sort_by(Images,&CreationDate))[*].[ImageId,CreationDate,Tags[?Key==`SourceRecipeVersion`].Value|[0]]' --output table"
    protect_from_lifecycle = length(var.lifecycle_exclude_tags) > 0 ? "aws ec2 create-tags --resources <ami-id> --tags ${join(" ", [for k, v in var.lifecycle_exclude_tags : "Key=${k},Value=${v}"])}" : "lifecycle_exclude_tags is empty, so no tag exempts an image from deletion - set it if you want a break-glass"
    stop_the_pipeline      = var.create_pipeline ? "aws imagebuilder update-image-pipeline --image-pipeline-arn ${local.pipeline_arn_or_note} --status DISABLED   # remember to re-enable it" : "no pipeline (create_pipeline = false)"

    # "Did my failure notifications actually arrive" has no other answer.
    undelivered_notifications = var.event_dead_letter_queue_arn != "" ? "aws sqs get-queue-attributes --queue-url <url-of-${basename(var.event_dead_letter_queue_arn)}> --attribute-names ApproximateNumberOfMessages" : "no event_dead_letter_queue_arn set; a rejected publish (missing topic policy, wrong KMS key policy) is discarded with no trace"

    # The module cannot check this: the provider has no aws_inspector2_* data
    # source, which is why enable_image_scanning defaults false.
    is_inspector_enabled = "aws inspector2 batch-get-account-status --query 'accounts[].resourceState.ec2.status' --output text"
  }
}
