locals {
  create = var.create

  common_tags = merge(var.tags, {
    "ManagedBy" = "Terraform"
    "Module"    = "ami-builder"
    # The lifecycle policy selects on this, and it has to be here rather than in
    # ami_tags: resourceSelection.tagMap only looks at the Image Builder image
    # resource, never at the output AMI's EC2 tags.
    "SourceRecipe" = var.name
  })

  # Placeholders so ARN expressions still evaluate when create = false.
  partition  = coalesce(one(data.aws_partition.current[*].partition), "aws")
  region     = coalesce(one(data.aws_region.current[*].name), "us-east-1")
  account_id = coalesce(one(data.aws_caller_identity.current[*].account_id), "000000000000")

  # -------------------------------------------------------------------------
  # Components
  # -------------------------------------------------------------------------

  # Entries with an arn already exist somewhere; the rest we create.
  managed_components = { for c in var.components : c.name => c if c.arn == "" }

  # Read here, not by the caller, so the shipped components stay versioned with
  # the module instead of copy-pasted into root configs.
  component_documents = {
    for name, c in local.managed_components : name => (
      c.bundled != "" ? file("${path.module}/components/${c.bundled}.yaml") : c.document
    )
  }

  # Component versions are immutable: reuse one with different content and the
  # API says no. Hashing the content means an edit always lands on a new
  # version and an unchanged document is a no-op.
  #
  # Everything in here forces replacement on aws_imagebuilder_component. Leave
  # a ForceNew attribute out and a change to it replaces the component without
  # moving the version, which then fails CreateComponent on a version whose
  # content didn't change - and retrying doesn't help. description and
  # kms_key_id are the two easy ones to forget.
  #
  # uri components hash the URI, not the object behind it. We never read it.
  component_hash_input = {
    for name, c in local.managed_components : name => jsonencode({
      document              = local.component_documents[name]
      uri                   = c.uri
      platform              = c.platform
      supported_os_versions = c.supported_os_versions
      description           = c.description
      kms_key_arn           = var.kms_key_arn
    })
  }

  # Two 4-hex slices, so ~1e6 values. A collision errors on apply rather than
  # quietly building the wrong thing.
  component_versions = {
    for name, c in local.managed_components : name => (
      var.auto_version
      ? format("%d.%d.%d",
        var.version_major,
        parseint(substr(sha256(local.component_hash_input[name]), 0, 4), 16) % 1000,
        parseint(substr(sha256(local.component_hash_input[name]), 4, 4), 16) % 1000,
      )
      : var.component_version
    )
  }

  # Caller order is build order: AWSTOE runs every build phase in sequence, then
  # every test phase.
  component_arns = [
    for c in var.components :
    c.arn != "" ? c.arn : try(aws_imagebuilder_component.this[c.name].arn, "")
  ]

  # -------------------------------------------------------------------------
  # Recipe
  # -------------------------------------------------------------------------

  root_device = var.root_device_name != "" ? var.root_device_name : "/dev/xvda"

  # Hash the inputs, not the component ARNs they produce. ARNs are computed, and
  # an unknown inside an immutable version field makes every plan want a
  # replacement.
  recipe_hash_input = jsonencode({
    parent_image = var.parent_image
    components = [
      for c in var.components : {
        name       = c.name
        arn        = c.arn
        parameters = c.parameters
        content    = c.arn != "" ? "" : local.component_hash_input[c.name]
      }
    ]
    root_volume       = [var.root_volume_size_gb, var.root_volume_type, var.root_volume_iops, var.root_volume_throughput]
    root_device       = local.root_device
    kms_key_arn       = var.kms_key_arn
    extra_devices     = var.additional_block_devices
    working_directory = var.working_directory
    user_data         = var.recipe_user_data
    uninstall_ssm     = var.uninstall_ssm_agent_after_build
    major             = var.version_major
    # ForceNew on the recipe, so it belongs here for the same reason.
    description = var.description
  })

  # nonsensitive() because recipe_user_data is sensitive and taints the hash
  # input. A sha256 slice of a secret isn't the secret, and the version has to
  # be readable - it names the artifact in every console and change record.
  recipe_version = (
    var.auto_version
    ? nonsensitive(format("%d.%d.%d",
      var.version_major,
      parseint(substr(sha256(local.recipe_hash_input), 0, 4), 16) % 1000,
      parseint(substr(sha256(local.recipe_hash_input), 4, 4), 16) % 1000,
    ))
    : var.recipe_version
  )

  # -------------------------------------------------------------------------
  # Parent image
  # -------------------------------------------------------------------------

  parent_is_ami_id   = can(regex("^ami-[0-9a-f]{8,17}$", var.parent_image))
  parent_is_ssm_path = startswith(var.parent_image, "/")

  # Populated only when the parent was readable at plan time.
  parent_architecture = one(data.aws_ami.parent[*].architecture)
  parent_root_device  = one(data.aws_ami.parent[*].root_device_name)

  # AWS reports volume size as a string inside a set of mappings, hence the
  # digging. try() covers all the ways this can be absent - no data source, a
  # test override, a parent with no matching mapping.
  parent_root_volume_gb = try(tonumber([
    for m in one(data.aws_ami.parent[*].block_device_mappings) :
    m.ebs["volume_size"]
    if m.device_name == local.parent_root_device
  ][0]), null)

  # A withdrawn base image still builds, so this is advisory only. try()
  # because deprecation_time is empty on most AMIs and timecmp throws on that.
  parent_deprecated = try(timecmp(one(data.aws_ami.parent[*].deprecation_time), plantimestamp()) < 0, false)

  # Marketplace billing codes are inherited by every image built from the
  # parent, which is what breaks cross-account copies later.
  parent_product_codes = try([
    for p in one(data.aws_ami.parent[*].product_codes) : p.product_code_id
  ], [])

  # error_message is evaluated even when its condition passes, and a null in a
  # string template throws - so messages interpolate these, not the raw values.
  parent_architecture_display = coalesce(local.parent_architecture, "not read at plan time")
  parent_root_device_display  = coalesce(local.parent_root_device, "not read at plan time")
  parent_root_volume_display  = local.parent_root_volume_gb == null ? "not read at plan time" : "${local.parent_root_volume_gb} GB"

  # Graviton types end their generation in "g" - m7g, c6gn, t4g. a1 is the one
  # arm64 family that predates the convention. Same heuristic the sibling
  # gitlab-runner module uses, and the parent's real architecture overrules it
  # whenever we could read it.
  instance_type_architectures = distinct([
    for t in var.instance_types :
    can(regex("^a1\\.", t)) ? "arm64" : (can(regex("^[a-z]+[0-9]+g", t)) ? "arm64" : "x86_64")
  ])

  parent_is_arn = can(regex("^arn:aws[a-z-]*:imagebuilder:", var.parent_image))

  # Image Builder semver takes `x` in any position and the build number is a
  # separate wildcard-able segment, so a substring match on "x.x.x" calls
  # .../2024.5.x/1 pinned. Parse it instead.
  #
  # A fully-pinned image ARN is exactly 4 slash-separated parts:
  #   arn:...:image / <name> / <major.minor.patch> / <build>
  parent_arn_parts = local.parent_is_arn ? split("/", var.parent_image) : []

  parent_arn_is_pinned = (
    length(local.parent_arn_parts) != 4 ? false : (
      can(regex("(^|\\.)x(\\.|$)", local.parent_arn_parts[2])) ? false : (
        local.parent_arn_parts[3] == "x" ? false : true
      )
    )
  )

  parent_unpinned = (
    local.parent_is_ssm_path ? true : (
      local.parent_is_arn ? !local.parent_arn_is_pinned : false
    )
  )

  # An ARN owned by neither AWS nor this account is pinned, but it isn't yours.
  parent_owner = (
    !local.parent_is_arn ? "ami-id-or-ssm" : (
      length(local.parent_arn_parts) < 1 ? "unknown" : (
        can(regex(":aws:image/", var.parent_image)) ? "aws" : (
          can(regex(":${local.account_id}:image/", var.parent_image)) ? "self" : "third-party"
        )
      )
    )
  )

  # A referenced component pinned to an exact version can never "update", and a
  # module-created one only moves when its content hash does, i.e. on apply.
  # Feeds check "the_schedule_can_actually_fire".
  all_components_pinned = alltrue([
    for c in var.components :
    c.arn == "" ? true : !can(regex("/x(\\.x)*(\\.x)*/", c.arn))
  ])

  # -------------------------------------------------------------------------
  # Distribution
  # -------------------------------------------------------------------------

  # Image Builder rejects a distribution config that leaves out the build region.
  distribution_regions = distinct(concat([local.region], var.distribution_regions))

  ami_name_prefix = var.ami_name_prefix != "" ? var.ami_name_prefix : var.name

  # buildDate is substituted at distribution time. AMI names are unique per
  # account per region, so something has to vary.
  ami_name = "${local.ami_name_prefix}-{{ imagebuilder:buildDate }}"

  ami_description = coalesce(
    var.ami_description != "" ? var.ami_description : null,
    var.description != "" ? var.description : null,
    "Built by the ami-builder module from recipe ${var.name}",
  )

  distribution_ami_tags = merge(local.common_tags, var.ami_tags, {
    "SourceRecipe"        = var.name
    "SourceRecipeVersion" = local.recipe_version
  })

  # Per-region CMK. The build region falls back to kms_key_arn, which is the
  # variable that actually reaches the recipe's block device mappings.
  #
  # Nested ternary rather than coalesce: coalesce skips empty strings and then
  # errors with "no non-null, non-empty-string arguments" when every argument is
  # one - which is the default case here.
  resolved_kms_key_arns = {
    for r in local.distribution_regions : r => (
      lookup(var.distribution_kms_key_arns, r, "") != ""
      ? var.distribution_kms_key_arns[r]
      : (r == local.region ? var.kms_key_arn : "")
    )
  }

  regions_without_cmk = [
    for r in local.distribution_regions : r
    if local.resolved_kms_key_arns[r] == ""
  ]

  # Accounts that can launch this AMI without owning it. The lifecycle policy
  # has to exempt them from deletion.
  shared_ami_accounts = distinct(concat(var.launch_permission.user_ids, var.target_account_ids))

  has_launch_permission = (
    length(var.launch_permission.user_ids) +
    length(var.launch_permission.user_groups) +
    length(var.launch_permission.organization_arns) +
    length(var.launch_permission.organizational_unit_arns)
  ) > 0

  ami_is_public = contains(var.launch_permission.user_groups, "all")

  # -------------------------------------------------------------------------
  # IAM
  # -------------------------------------------------------------------------

  create_build_role = local.create && var.build_instance_profile_name == ""

  build_role_name       = "${var.name}-imagebuilder-build"
  build_profile_name    = var.build_instance_profile_name != "" ? var.build_instance_profile_name : "${var.name}-imagebuilder-build"
  lifecycle_role_name   = "${var.name}-imagebuilder-lifecycle"
  create_lifecycle_role = local.create && var.create_lifecycle_policy && var.lifecycle_execution_role_arn == ""
  lifecycle_role_arn    = var.lifecycle_execution_role_arn != "" ? var.lifecycle_execution_role_arn : try(aws_iam_role.lifecycle[0].arn, "")
  managed_policy_prefix = "arn:${local.partition}:iam::aws:policy"
  log_group_name        = "/aws/imagebuilder/${var.name}"

  # Always namespaced by pipeline name. An empty prefix would grant s3:PutObject
  # on <bucket>/*, so a component - arbitrary root code - could overwrite any
  # other pipeline's build logs in a shared platform bucket.
  log_bucket_key_prefix = "${trimsuffix(var.log_s3_prefix != "" ? var.log_s3_prefix : "imagebuilder", "/")}/${var.name}/*"

  notifications_enabled  = local.create && var.sns_topic_arn != "" && var.create_event_rule
  lifecycle_deletes_amis = var.lifecycle_delete_after_days > 0

  # Image Builder only publishes to a topic in its own region, and EventBridge
  # only delivers to a same-region topic. Checked on the infrastructure config.
  sns_topic_region = (
    var.sns_topic_arn == "" ? "" : (
      length(split(":", var.sns_topic_arn)) < 4 ? "" : split(":", var.sns_topic_arn)[3]
    )
  )

  # jsonencode rather than aws_iam_policy_document: mock_provider returns a mock
  # for provider-computed data sources, so tests would assert against the mock.
  # This way the policy is in the plan.
  #
  # log_s3_bucket is a required variable, so the log statements are
  # unconditional - there is no "no bucket" case to branch on.
  build_policy_statements = concat(
    [
      {
        Sid      = "PutBuildLogs"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = ["arn:${local.partition}:s3:::${var.log_s3_bucket}/${local.log_bucket_key_prefix}"]
      },
      {
        # AWSTOE resolves the bucket region before writing.
        Sid      = "LocateLogBucket"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation"]
        Resource = ["arn:${local.partition}:s3:::${var.log_s3_bucket}"]
      },
    ],
    var.kms_key_arn != "" ? [
      {
        # EBS calls KMS for the snapshot. Miss GenerateDataKey* and the build
        # dies at the snapshot step, after you've paid for every component.
        Sid    = "UseCmkForImageSnapshots"
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = [var.kms_key_arn]
        Condition = {
          StringEquals = { "kms:ViaService" = "ec2.${local.region}.amazonaws.com" }
        }
      },
      {
        # Split out and conditioned. Unconditioned CreateGrant lets a component
        # leave a persistent grant on the estate's image key for a principal of
        # its choosing - outliving the build instance and invisible in a
        # key-policy review.
        Sid      = "CreateGrantForEbsOnly"
        Effect   = "Allow"
        Action   = ["kms:CreateGrant"]
        Resource = [var.kms_key_arn]
        Condition = {
          Bool         = { "kms:GrantIsForAWSResource" = "true" }
          StringEquals = { "kms:ViaService" = "ec2.${local.region}.amazonaws.com" }
        }
      },
    ] : [],
    var.log_s3_kms_key_arn != "" ? [
      {
        # PutObject into an SSE-KMS bucket needs GenerateDataKey on the
        # bucket's key. Without it log delivery 403s while the build reports
        # success - and in a regulated estate the log bucket's key is not the
        # EBS one.
        Sid      = "EncryptBuildLogs"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"]
        Resource = [var.log_s3_kms_key_arn]
      },
    ] : [],
  )

  # Key policies the caller has to write. Same idea as network_contract: the
  # module can't set a key policy, and each of these fails at a different time
  # and in a different way when it's missing.
  kms_key_policy_requirements = concat(
    var.kms_key_arn != "" ? [
      {
        key       = var.kms_key_arn
        principal = "the build instance role (${local.build_role_name})"
        actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
        condition = ""
        why       = "EBS creates the encrypted snapshot on the instance's behalf. Missing: the build fails at the snapshot step, after every component has run."
      },
      {
        key       = var.kms_key_arn
        principal = "imagebuilder.amazonaws.com"
        actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
        condition = ""
        why       = "the component and workflow documents are encrypted with this key. Missing: AWSTOE cannot read them on the build instance."
      },
    ] : [],
    var.kms_key_arn != "" && var.create_log_group && var.log_retention_days > 0 ? [
      {
        key       = var.kms_key_arn
        principal = "logs.${local.region}.amazonaws.com"
        actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
        condition = "ArnLike on kms:EncryptionContext:aws:logs:arn = arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${local.log_group_name}"
        why       = "CreateLogGroup succeeds without it and every PutLogEvents then fails, so you get a log group that exists and stays permanently empty."
      },
    ] : [],
    var.log_s3_kms_key_arn != "" ? [
      {
        key       = var.log_s3_kms_key_arn
        principal = "the build instance role (${local.build_role_name})"
        actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
        condition = ""
        why       = "AWSTOE writes build logs to the bucket. Missing: log delivery 403s while the build reports success."
      },
    ] : [],
    length(var.target_account_ids) > 0 ? [
      {
        key       = "every entry in distribution_kms_key_arns"
        principal = join(", ", var.target_account_ids)
        actions   = ["kms:DescribeKey", "kms:CreateGrant", "kms:Decrypt", "kms:ReEncrypt*"]
        condition = ""
        why       = "a cross-account copy is re-encrypted in the target account. Missing: the target owns an AMI it cannot launch."
      },
    ] : [],
    var.sns_topic_arn != "" ? [
      {
        key       = "the KMS key encrypting ${var.sns_topic_arn}, if any"
        principal = "events.amazonaws.com and imagebuilder.amazonaws.com"
        actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
        condition = ""
        why       = "an encrypted SNS topic drops publishes it cannot encrypt, silently. The topic also needs a resource policy - see output.sns_topic_policy_requirement."
      },
    ] : [],
  )

  # output_resources is a list but amis inside it is a set, so no indexing. N
  # distribution regions means N entries.
  built_amis = local.create && var.build_on_apply ? flatten([
    for r in aws_imagebuilder_image.this[0].output_resources : tolist(r.amis)
  ]) : []

  # one() of an empty tuple is null, and a null in a template throws.
  # create_pipeline = false hits that.
  pipeline_arn_or_note = coalesce(one(aws_imagebuilder_image_pipeline.this[*].arn), "<no pipeline>")

  # -------------------------------------------------------------------------
  # Network prerequisites
  # -------------------------------------------------------------------------

  required_interface_endpoints = concat(
    [
      # No imagebuilder endpoint on purpose - the build instance talks to SSM,
      # not the control plane. Adding it is $8/AZ/month for nothing.
      "ssm",
      "ssmmessages",
      "ec2messages",
    ],
    # Only when a component calls KMS itself. EBS and SSM both call KMS
    # service-side, so listing this unconditionally was another $8/AZ/month of
    # endpoint nobody asked for.
    var.components_call_kms ? ["kms"] : [],
    ["s3 (gateway, free) for log delivery"],
    var.enable_image_scanning ? ["inspector2"] : [],
  )
}
