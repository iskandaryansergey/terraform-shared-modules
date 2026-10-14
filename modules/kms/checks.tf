# Advisory checks: defensible postures a reviewer should see. Each is
# silenced by naming it in acknowledged_checks, which output.governance lists.

locals {
  # A key field that is no key identifier at all (prose such as "the key
  # encrypting the topic") can never match; it is reported apart from a real
  # identifier that belongs to another key set.
  key_is_identifier = { for i, r in local.machine : i => can(regex("^(arn:aws[a-z-]*:kms:|alias/|mrk-[0-9a-f]{32}$|[0-9a-f]{8}-[0-9a-f]{4}-)", r.key)) }

  all_match_ids = flatten([for k, ids in local.key_match_ids : concat(ids.primary, ids.replica)])

  unaddressed_requirements = [for i, r in local.machine : "${r.label}: ${r.key}" if !local.key_is_identifier[i]]
  unmatched_requirements = [
    for i, r in local.machine : "${r.label} -> ${r.key}" if local.key_is_identifier[i] ? !contains(local.all_match_ids, r.key) : false
  ]
  unresolved_roles     = distinct(flatten([for r in local.machine : [for role in r.unresolved_roles : "${role} (${r.label})"]]))
  without_principals   = [for r in local.machine : r.label if length(r.services) + length(r.arns) + length(r.roles) == 0]
  not_machine_readable = [for r in local.classified_full : "${r.label}${r.purpose != "" ? ": ${r.purpose}" : ""}" if r.applicable ? !r.machine : false]
  malformed            = [for r in local.classified_full : r.label if r.malformed]

  duty_overlaps = flatten([
    for k, v in local.keys : [
      for p in v.administrators : "${p} on ${k}" if contains(concat(v.users, v.encrypters, v.decrypters, v.grant_users), p)
    ]
  ])

  policy_sizes = { for k, v in local.keys : k => length(local.final_policy[k].primary) }

  # Anything that could put a principal from another account in a policy.
  named_principals = distinct(concat(
    local.deployers, local.break_glass, flatten(values(var.principal_roles)), flatten([for r in local.machine : r.arns]),
    flatten([for k, v in local.keys : concat(v.administrators, v.users, v.auditors, v.encrypters, v.decrypters, v.grant_users)]),
    flatten([for k, v in local.keys : [for g in values(v.grants) : compact([g.grantee_principal, g.retiring_principal])]]),
  ))
  other_account_principals = [for p in local.named_principals : p if try(regex("^arn:aws[a-z-]*:iam::([0-9]{12}):", p)[0], local.account_id) != local.account_id]
  reaches_outside = (
    length(local.other_account_principals) > 0 ||
    length(var.guardrails.trusted_accounts) > 0 ||
    anytrue([for k, v in local.keys : length(v.accounts) > 0 || v.extra_statements != ""])
  )
}

check "symmetric_keys_rotate" {
  assert {
    condition     = contains(local.acknowledged, "symmetric_keys_rotate") || !local.create ? true : length([for k, v in local.keys : k if local.key_kind[k] == "symmetric" && !v.custom_store && !v.external && !v.rotation]) == 0
    error_message = "these symmetric keys do not rotate: ${join(", ", [for k, v in local.keys : k if local.key_kind[k] == "symmetric" && !v.custom_store && !v.external && !v.rotation])}. Rotation costs at most $2/month per key (the first two rotations) and limits what one key version protects."
  }
}

check "deletion_window_leaves_time_to_notice" {
  assert {
    condition     = contains(local.acknowledged, "deletion_window_leaves_time_to_notice") || !local.create ? true : length([for k, v in local.keys : k if v.deletion_window_days < 30]) == 0
    error_message = "these keys can be deleted in under 30 days: ${join(", ", [for k, v in local.keys : "${k} (${v.deletion_window_days}d)" if v.deletion_window_days < 30])}. A deleted key destroys every byte encrypted under it; the window is the only time to cancel."
  }
}

check "every_requirement_found_its_key" {
  assert {
    condition     = contains(local.acknowledged, "every_requirement_found_its_key") || !local.create ? true : length(local.unmatched_requirements) + length(local.unaddressed_requirements) == 0
    error_message = "no policy here grants these consumer requirements. ${length(local.unmatched_requirements) > 0 ? "They name a key outside this set: ${join("; ", local.unmatched_requirements)}. Pass this module's key ARNs to the consumer, or drop the consumer. " : ""}${length(local.unaddressed_requirements) > 0 ? "Their key is not an ARN, ID or alias, so the producer could not say which key it means: ${join("; ", local.unaddressed_requirements)}. Grant them on the right key with a preset or extra_statements, then acknowledge." : ""}"
  }
}

check "every_principal_role_is_resolved" {
  assert {
    condition     = contains(local.acknowledged, "every_principal_role_is_resolved") || !local.create ? true : length(local.unresolved_roles) == 0
    error_message = "these roles in consumer requirements are not in principal_roles: ${join("; ", local.unresolved_roles)}. ${var.iam_delegation ? "IAM delegation covers them, so the IAM policies of those principals must grant the access." : "With iam_delegation = false nothing grants them access."}"
  }
}

check "every_requirement_is_machine_readable" {
  assert {
    condition     = contains(local.acknowledged, "every_requirement_is_machine_readable") || !local.create ? true : length(local.not_machine_readable) + length(local.malformed) + length(local.unreadable_consumers) == 0
    error_message = "not compiled into any policy:${length(local.unreadable_consumers) > 0 ? " consumers that are not a list of requirements (pass the module's kms_key_policy_requirements output, not the module): ${join(", ", local.unreadable_consumers)}." : ""}${length(local.not_machine_readable) > 0 ? " prose-only requirements (no sid, principals and actions): ${join("; ", local.not_machine_readable)}." : ""}${length(local.malformed) > 0 ? " requirements with a condition that has no values or repeats a test and key: ${join("; ", local.malformed)}." : ""}"
  }
}

check "keys_have_an_organization_perimeter" {
  assert {
    condition     = contains(local.acknowledged, "keys_have_an_organization_perimeter") || !local.create ? true : (var.guardrails.organization_id != "" || !local.reaches_outside)
    error_message = "these keys can be reached from outside this account (principals or grantees in other accounts, keys[*].accounts, trusted_accounts or extra_statements) and guardrails.organization_id is empty, so nothing stops a principal in another organization granted access by mistake.${length(local.other_account_principals) > 0 ? " Principals in other accounts: ${join(", ", local.other_account_principals)}." : ""}"
  }
}

check "deletion_protection_has_an_exemption" {
  assert {
    condition     = contains(local.acknowledged, "deletion_protection_has_an_exemption") || !local.create ? true : (var.guardrails.deletion_protection ? length(local.exempt) > 0 : true)
    error_message = "deletion_protection is on with no deployer and no break_glass, so nobody can disable or delete these keys until an administrator changes the key policy first. Name deployers, or leave detect_deployer on."
  }
}

check "cloudtrail_events_need_a_trail" {
  assert {
    condition     = contains(local.acknowledged, "cloudtrail_events_need_a_trail") || !local.notify ? true : length(local.cloudtrail_events) == 0
    error_message = "notifications include ${join(", ", local.cloudtrail_events)}, which reach EventBridge only while a CloudTrail trail is logging management events in this account (an organization trail counts). Acknowledge this check once the trail is confirmed."
  }
}

check "multi_region_keys_are_replicated" {
  assert {
    condition     = contains(local.acknowledged, "multi_region_keys_are_replicated") || !local.create ? true : length([for k, v in local.keys : k if v.multi_region && !v.replicate]) == 0
    error_message = "these multi-Region primaries have replicate = false: ${join(", ", [for k, v in local.keys : k if v.multi_region && !v.replicate])}. Fine if another configuration replicates them; otherwise multi_region only made the key unchangeable back to single-Region."
  }
}

check "key_policies_leave_room_to_grow" {
  assert {
    condition     = contains(local.acknowledged, "key_policies_leave_room_to_grow") || !local.create ? true : length([for k, n in local.policy_sizes : k if n > 26000]) == 0
    error_message = "these key policies are above 80% of the 32768-character limit: ${join(", ", [for k, n in local.policy_sizes : "${k} (${n})" if n > 26000])}. The next consumer may not fit."
  }
}

check "strict_mode_keeps_services_named" {
  assert {
    condition     = contains(local.acknowledged, "strict_mode_keeps_services_named") || !local.create || var.iam_delegation ? true : length([for k, v in local.keys : k if v.service_access == "account" ? length(local.via_values[k].primary) > 0 : false]) == 0
    error_message = "iam_delegation = false, yet these keys let any principal in the account use them through their services (service_access = \"account\"): ${join(", ", [for k, v in local.keys : k if v.service_access == "account" ? length(local.via_values[k].primary) > 0 : false])}. Set service_access = \"named\" to keep KMS a second authorization layer."
  }
}

check "replicas_have_their_vpc_endpoints" {
  assert {
    condition     = contains(local.acknowledged, "replicas_have_their_vpc_endpoints") || !local.create ? true : (length(var.guardrails.vpc_endpoint_ids) == 0 || length(local.replicated_keys) == 0 || length(var.guardrails.replica_vpc_endpoint_ids) > 0)
    error_message = "the primaries only accept direct calls through KMS VPC endpoints, but replica_vpc_endpoint_ids is empty, so the replicas accept direct calls from anywhere. VPC endpoints are regional: list the replica region's."
  }
}

# Separation of duties: whoever manages a key should not also use it.
check "duties_are_separated" {
  assert {
    condition     = contains(local.acknowledged, "duties_are_separated") || !local.create ? true : length(local.duty_overlaps) == 0
    error_message = "these principals both administer and use a key: ${join("; ", local.duty_overlaps)}. A key administrator who can also decrypt needs no one else to read the data."
  }
}

# Imported material can expire, and the key stops working when it does.
check "imported_material_expiry_is_watched" {
  assert {
    condition     = contains(local.acknowledged, "imported_material_expiry_is_watched") || !local.create ? true : length([for k, v in local.keys : k if v.external]) == 0 || (var.notifications.sns_topic_arn != "" && contains(var.notifications.events, "import_expiry"))
    error_message = "keys with imported material (${join(", ", [for k, v in local.keys : k if v.external])}) have no import_expiry notification. When material imported with an expiry runs out, the key stops working; set notifications.sns_topic_arn, or acknowledge if the material never expires."
  }
}
