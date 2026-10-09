# Warnings, not refusals. Postures the module will let you have but a reviewer
# should see at plan time - and, in HCP Terraform, in every health assessment.
#
# Every check is silent under create = false, and silent once its name is in
# var.acknowledged_checks: a decision taken once, in code, and listed in
# output.governance, instead of a warning everyone learns to scroll past.

locals {
  ack_hint = "Acknowledge it with acknowledged_checks if this is intended."
}

# One instance is one AZ. When it fails, the cluster has no compute until AWS
# replaces it - minutes, not seconds.
check "cluster_survives_an_az" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "cluster_survives_an_az") ? true : (local.is_secondary ? true : local.has_readers))
    error_message = "the cluster has ${length(local.instances)} instance(s) and no reader. An instance or AZ failure leaves nothing to fail over to until AWS replaces it. Add a second instance; Aurora places them in different AZs. ${local.ack_hint}"
  }
}

# Two instances pinned to one AZ is one AZ.
check "instances_are_spread_across_azs" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "instances_are_spread_across_azs") ? true : !local.instances_share_one_az)
    error_message = "every instance is pinned to ${join(", ", local.pinned_azs)}, so an AZ outage takes all of them. Pin them to different AZs, or leave availability_zone empty. ${local.ack_hint}"
  }
}

check "somebody_hears_a_failover" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "somebody_hears_a_failover") ? true : (var.create_alarms || var.create_event_subscriptions))
    error_message = "create_alarms and create_event_subscriptions are both false. A failover, a failed instance or a filling disk will tell nobody. ${local.ack_hint}"
  }
}

check "deleting_the_cluster_is_protected" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "deleting_the_cluster_is_protected") ? true : var.deletion_protection)
    error_message = "deletion_protection is false: a terraform destroy, or a plan that replaces the cluster, deletes the database. ${local.ack_hint}"
  }
}

check "deleting_the_cluster_leaves_a_snapshot" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "deleting_the_cluster_leaves_a_snapshot") ? true : !var.skip_final_snapshot)
    error_message = "skip_final_snapshot is true: deleting the cluster keeps no copy of the data beyond automated backups (and none at all with delete_automated_backups). ${local.ack_hint}"
  }
}

check "backups_cover_a_week" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "backups_cover_a_week") ? true : var.backup_retention_days >= 7)
    error_message = "backup_retention_days is ${var.backup_retention_days}. A problem noticed on Monday that started on Friday cannot be restored to before it. Backup storage up to the cluster's size is free. ${local.ack_hint}"
  }
}

# Performance Insights off: the first question in an incident - which queries? -
# has no answer.
check "query_level_metrics_exist" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "query_level_metrics_exist") ? true : var.performance_insights_enabled)
    error_message = "performance_insights_enabled is false, so there is no record of which queries were running when something went wrong. Seven days of retention are free. ${local.ack_hint}"
  }
}

check "database_logs_leave_the_instance" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "database_logs_leave_the_instance") ? true : length(var.enabled_cloudwatch_logs_exports) > 0)
    error_message = "enabled_cloudwatch_logs_exports is empty. Engine logs stay on the instance and rotate away within days, and are gone with it when it is replaced. ${local.ack_hint}"
  }
}

check "log_retention_is_bounded" {
  assert {
    condition     = !local.create_log_groups ? true : (contains(local.acknowledged, "log_retention_is_bounded") ? true : (length(var.enabled_cloudwatch_logs_exports) == 0 ? true : var.log_retention_days > 0))
    error_message = "log_retention_days = 0 keeps database logs forever, billed per GB-month for as long as the account exists. ${local.ack_hint}"
  }
}

# BYO parameter group: the module cannot write rds.force_ssl into it, and
# cannot read it to check.
check "tls_is_enforced_where_the_module_can_see" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "tls_is_enforced_where_the_module_can_see") ? true : (var.enforce_tls ? local.tls_enforced : true))
    error_message = "create_cluster_parameter_group is false, so enforce_tls cannot be applied. Make sure ${local.tls_parameter_name} = ${local.tls_parameter_value} is set in ${var.cluster_parameter_group_name}. ${local.ack_hint}"
  }
}

# BYO security groups silence the module's control of who connects.
check "the_module_controls_who_connects" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "the_module_controls_who_connects") ? true : var.create_security_group)
    error_message = "create_security_group is false, so who can reach the database is decided entirely by vpc_security_group_ids. The module cannot see or check those rules. ${local.ack_hint}"
  }
}

check "ingress_stays_inside_private_address_space" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "ingress_stays_inside_private_address_space") ? true : length(local.non_private_ingress) == 0)
    error_message = "these ingress rules allow addresses outside RFC 1918, 100.64.0.0/10 and IPv6 unique-local space: ${join(", ", local.non_private_ingress)}. Normal for a hybrid estate with public-range addressing; otherwise it is the internet. ${local.ack_hint}"
  }
}

# A module-created group with no ingress is a database nothing can reach.
check "something_can_connect" {
  assert {
    condition = !local.create ? true : (contains(local.acknowledged, "something_can_connect") ? true : (
      !var.create_security_group ? true : (
        length(var.ingress_rules) > 0 ? true : (
          length(var.vpc_security_group_ids) > 0 ? true : (var.proxy.enabled && var.proxy.create_security_group)
        )
      )
    ))
    error_message = "the module-created security group has no ingress_rules, no other group is attached and no proxy is in front: nothing can reach the database. Add ingress_rules. ${local.ack_hint}"
  }
}

check "credentials_are_not_in_state" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "credentials_are_not_in_state") ? true : !local.static_password)
    error_message = "master_password is in Terraform state in plaintext. Anyone with read access to state has the master password. manage_master_user_password = true keeps it in Secrets Manager only - except in a global database, where AWS does not support it. ${local.ack_hint}"
  }
}

# Major-only version: the provider re-sends it with every later modify of the
# cluster, because "17" differs from the running "17.x".
check "engine_version_is_exact" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "engine_version_is_exact") ? true : local.version_is_full_pin)
    error_message = "engine_version ${var.engine_version} is major-only. AWS picks the minor at create time, and every later modification of the cluster re-sends \"${var.engine_version}\" alongside it - AWS does not document the result. Pin the exact version (output.engine_version_actual after the first apply). ${local.ack_hint}"
  }
}

check "minor_upgrades_do_not_fight_the_pin" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "minor_upgrades_do_not_fight_the_pin") ? true : !local.minor_upgrade_fights_pin)
    error_message = "engine_version ${var.engine_version} pins a minor version and auto_minor_version_upgrade is on. After AWS upgrades the minor, engine_version is behind what runs: provider v5 plans a downgrade AWS refuses, v6 hides the difference. Turn automatic minor upgrades off and move engine_version yourself, or raise it after each maintenance window. ${local.ack_hint}"
  }
}

# Set at creation and not modifiable: a cluster adopted from elsewhere keeps
# whatever it was created with, whatever this module says.
check "extended_support_matches_the_setting" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "extended_support_matches_the_setting") ? true : try(aws_rds_cluster.this[0].engine_lifecycle_support == var.engine_lifecycle_support, true))
    error_message = "the cluster was created with engine_lifecycle_support = ${try(aws_rds_cluster.this[0].engine_lifecycle_support, "unknown")}, and AWS cannot change it in place. var.engine_lifecycle_support only applies to a new cluster. A restore from snapshot is the only way to change it. ${local.ack_hint}"
  }
}

check "extended_support_is_a_decision" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "extended_support_is_a_decision") ? true : var.engine_lifecycle_support == "open-source-rds-extended-support-disabled")
    error_message = "engine_lifecycle_support enables RDS Extended Support: once ${var.engine_version} leaves standard support it keeps running and is billed per vCPU-hour on top of the instances. See COSTS.md. ${local.ack_hint}"
  }
}

check "auto_pause_has_an_engine_that_supports_it" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "auto_pause_has_an_engine_that_supports_it") ? true : !local.auto_pause_version_too_old)
    error_message = "serverlessv2_scaling_configuration.min_capacity = 0 needs aurora-postgresql 13.15/14.12/15.7/16.3+ or aurora-mysql 3.08+, and engine_version ${var.engine_version} is older. AWS will refuse the scaling configuration. ${local.ack_hint}"
  }
}

check "the_proxy_has_clients" {
  assert {
    condition     = !local.create_proxy_security_group ? true : (contains(local.acknowledged, "the_proxy_has_clients") ? true : length(var.proxy.ingress_rules) > 0)
    error_message = "the proxy's security group is module-created with no proxy.ingress_rules, so nothing can connect to it. ${local.ack_hint}"
  }
}

# The proxy fetches the database secret over its own network interfaces. In a
# VPC with no route to Secrets Manager, targets stay UNAVAILABLE while every
# resource reports healthy.
check "the_proxy_can_reach_secrets_manager" {
  assert {
    condition     = !local.create_proxy_security_group ? true : (contains(local.acknowledged, "the_proxy_can_reach_secrets_manager") ? true : length([for r in values(var.proxy.egress_rules) : r if r.port == 443]) > 0)
    error_message = "the proxy's module-created security group has no egress on 443, so it cannot reach Secrets Manager to read the database secret. Add a proxy.egress_rules entry to the Secrets Manager endpoint's security group or prefix list. ${local.ack_hint}"
  }
}

# The module-created role gets kms:Decrypt only on proxy.secret_kms_key_arn. The
# caller's own secrets on a customer-managed key, with that empty, leave targets
# UNAVAILABLE while every resource reports healthy. A brought role is the
# caller's to grant.
check "the_proxy_can_decrypt_its_secrets" {
  assert {
    condition = !local.create_proxy_role ? true : (contains(local.acknowledged, "the_proxy_can_decrypt_its_secrets") ? true : (
      local.proxy_uses_master_secret ? true : var.proxy.secret_kms_key_arn != ""
    ))
    error_message = "proxy.secret_arns is set and proxy.secret_kms_key_arn is empty, so the module-created proxy role has no kms:Decrypt. That works only if every secret uses the AWS-managed aws/secretsmanager key; with a customer-managed key the proxy cannot read them. Set proxy.secret_kms_key_arn, or acknowledge if the secrets use the default key. ${local.ack_hint}"
  }
}

# Fixed once RDS owns the secret: a later change is ignored by the module and
# refused by AWS, so the only place it shows is here.
check "master_secret_key_is_the_one_configured" {
  assert {
    condition = !local.create ? true : (contains(local.acknowledged, "master_secret_key_is_the_one_configured") ? true : (
      !local.manage_password ? true : (local.master_secret_kms_key_arn == "" ? true : (
        # The argument is in ignore_changes: the configured key on create, the
        # prior one after. Known at plan, so a create does not read as unknown.
        try(aws_rds_cluster.this[0].master_user_secret_kms_key_id == local.master_secret_kms_key_arn, false) ? true : try(local.managed_secret_kms_key_id == local.master_secret_kms_key_arn, true)
      ))
    ))
    error_message = "the master secret is encrypted with ${local.managed_secret_kms_key_id}, not ${local.master_secret_kms_key_arn}. AWS cannot change the key of an RDS-managed secret; turning managed credentials off and on again creates a new secret with the new key. ${local.ack_hint}"
  }
}

check "performance_insights_key_is_the_one_configured" {
  assert {
    condition = !local.create ? true : (contains(local.acknowledged, "performance_insights_key_is_the_one_configured") ? true : (
      !var.performance_insights_enabled ? true : (local.performance_insights_kms_key == "" ? true : try(aws_rds_cluster.this[0].performance_insights_kms_key_id == local.performance_insights_kms_key, true))
    ))
    error_message = "Performance Insights data is encrypted with ${try(aws_rds_cluster.this[0].performance_insights_kms_key_id, "unknown")}, not ${local.performance_insights_kms_key}. AWS cannot change it once set. ${local.ack_hint}"
  }
}

# Compared on the key ID, because AWS may report the key as an ARN or a bare ID.
check "activity_stream_key_is_the_one_configured" {
  assert {
    condition = !local.activity_stream_enabled ? true : (contains(local.acknowledged, "activity_stream_key_is_the_one_configured") ? true : try(
      reverse(split("/", aws_rds_cluster_activity_stream.this[0].kms_key_id))[0] == reverse(split("/", local.activity_stream_kms_key_arn))[0],
      true
    ))
    error_message = "the activity stream runs with key ${try(aws_rds_cluster_activity_stream.this[0].kms_key_id, "unknown")}, not ${local.activity_stream_kms_key_arn}. The module does not restart a stream to change its key; stop and start it (activity_stream.enabled false, apply, true, apply) if the new key is required. ${local.ack_hint}"
  }
}

# The provider defers Performance Insights settings on a global member to a
# modify after create, while sending the insights mode on the create itself.
check "database_insights_advanced_on_a_global_member" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "database_insights_advanced_on_a_global_member") ? true : (local.is_global ? var.database_insights_mode == "standard" : true))
    error_message = "database_insights_mode = advanced on a global database member may fail at create, because the provider applies Performance Insights only after the cluster exists. Create with standard, then switch to advanced. ${local.ack_hint}"
  }
}

# A deferred major upgrade leaves the instances on the old engine with the new
# family's parameter group pending - the combination most likely to fail
# part way.
check "major_upgrade_applies_immediately" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "major_upgrade_applies_immediately") ? true : (var.allow_major_version_upgrade ? var.apply_immediately : true))
    error_message = "allow_major_version_upgrade is on with apply_immediately = false. A major upgrade deferred to the maintenance window is the path most likely to fail half-done. Upgrade with apply_immediately = true, in a window you choose. ${local.ack_hint}"
  }
}

check "reader_autoscaling_has_a_reader" {
  assert {
    condition = !local.create ? true : (contains(local.acknowledged, "reader_autoscaling_has_a_reader") ? true : (
      !var.reader_autoscaling.enabled ? true : (length(var.instances) > 1 ? true : var.reader_autoscaling.min_capacity > 0)
    ))
    error_message = "reader_autoscaling is on with one instance and min_capacity = 0. AWS scales only a cluster that already has a reader, so it will never act. Add a reader instance or raise min_capacity. ${local.ack_hint}"
  }
}

check "mysql_log_exports_have_their_switches" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "mysql_log_exports_have_their_switches") ? true : length(local.mysql_exports_without_switch) == 0)
    error_message = "these log types are exported but switched off in the engine, so their log groups stay empty: ${join(", ", local.mysql_exports_without_switch)}. Set the parameter in cluster_parameters, or stop exporting the type. ${local.ack_hint}"
  }
}

check "parameter_group_family_matches_the_engine" {
  assert {
    condition     = !local.create ? true : (contains(local.acknowledged, "parameter_group_family_matches_the_engine") ? true : !local.family_mismatch)
    error_message = "parameter_group_family ${var.parameter_group_family} does not match engine ${var.engine} ${var.engine_version} (expected ${local.derived_family}). The module's parameter groups would be on another family than the cluster. ${local.ack_hint}"
  }
}
