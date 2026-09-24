# Warnings, not refusals. Postures the module will let you have but a reviewer
# should see at plan time.

# One DNS server for a zone is a working configuration and a single point of
# failure for every name in it.
check "forwarded_zones_have_more_than_one_name_server" {
  assert {
    condition     = !local.create ? true : length(local.rules_with_one_target) == 0
    error_message = "these rules forward to a single DNS server: ${join(", ", local.rules_with_one_target)}. If that server is unavailable, every name in the zone stops resolving from this VPC - which for a migration means every task that has to reconnect. A rule accepts up to six targets; add a second when one exists."
  }
}

# An apex zone forwards everything beneath it out of the VPC.
check "forwarded_zones_are_no_broader_than_they_need_to_be" {
  assert {
    condition     = !local.create ? true : length(local.broad_rules) == 0
    error_message = "these rules forward an apex domain: ${join(", ", local.broad_rules)}. Every name under it now resolves via your DNS servers from this VPC, including any that resolve publicly today - those will stop. Forward the narrowest subdomain that covers the hosts you need, or add a SYSTEM rule to carve out the exceptions."
  }
}

# Both endpoints is twice the ENIs, and most estates want one direction.
check "both_directions_are_intentional" {
  assert {
    condition     = !local.create ? true : !(local.create_outbound && local.create_inbound)
    error_message = "both an outbound and an inbound endpoint are being created, which is two sets of billed ENIs. Outbound resolves on-premises names from AWS; inbound resolves AWS private names from on-premises. Most estates need one. Confirm both are actually used."
  }
}

# Billed ENIs that cannot forward anything. Legitimate as a staging step, which
# is why it warns rather than refuses.
check "the_outbound_endpoint_has_something_to_do" {
  assert {
    condition     = !local.create_outbound ? true : length(local.rules_needing_endpoint) > 0
    error_message = "an outbound endpoint is being created with no FORWARD rules, which is ${length(var.subnet_ids)} ENIs billed hourly that cannot forward anything. Add rules, or point existing_outbound_endpoint_id at an endpoint that already exists."
  }
}

# BYO security groups silence the two preconditions that catch the commonest
# failure, so it should be a deliberate choice.
check "the_module_can_still_see_its_own_egress" {
  assert {
    condition     = !local.create ? true : !local.byo_security_groups
    error_message = "security_group_ids was supplied, so this module cannot check that the endpoint can reach your DNS servers. That check is what catches an endpoint which comes up healthy and times out every query. Verify the egress rules yourself - 53 on both UDP and TCP."
  }
}
