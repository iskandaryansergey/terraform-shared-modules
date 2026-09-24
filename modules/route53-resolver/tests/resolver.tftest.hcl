# Mocked plan tests.
#
# These prove the graph shape, the rule wiring, every validation and
# precondition, and the contract outputs.
#
# What they cannot prove is that a name resolves. That needs the DNS servers to
# accept queries from the endpoint's addresses, which is outside AWS entirely -
# see output.firewall_request.

mock_provider "aws" {
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_data "aws_region" { defaults = { name = "eu-west-2" } }
  mock_data "aws_caller_identity" { defaults = { account_id = "111122223333" } }

  # mock_data gives every instance the same value, so the baseline needs
  # per-subnet override_data blocks in each run to look like two AZs. Rather
  # than repeat those everywhere, the baseline below overrides them once and
  # the runs that care about AZ topology override them again.
  mock_data "aws_subnet" {
    defaults = { availability_zone = "eu-west-2a" }
  }

  # ip_address is a nested block, so the mock cannot supply it as a flat list -
  # the apply run below reads the real (mock-generated) values instead.
  mock_resource "aws_route53_resolver_endpoint" {
    defaults = {
      id  = "rslvr-out-mock"
      arn = "arn:aws:route53resolver:eu-west-2:111122223333:resolver-endpoint/rslvr-out-mock"
    }
  }
  mock_resource "aws_route53_resolver_rule" {
    defaults = {
      id  = "rslvr-rr-mock"
      arn = "arn:aws:route53resolver:eu-west-2:111122223333:resolver-rule/rslvr-rr-mock"
    }
  }
  mock_resource "aws_security_group" {
    defaults = { id = "sg-0mock0mock0mock0" }
  }
}

variables {
  name       = "onprem"
  vpc_id     = "vpc-0a1b2c3d4e5f60000"
  subnet_ids = ["subnet-0a1b2c3d4e5f60001", "subnet-0a1b2c3d4e5f60002"]

  dns_server_cidrs = ["10.36.65.179/32", "10.36.65.180/32"]

  # The audit record. Without it the endpoint precondition refuses, which is
  # the point - the absence of logging is what takes a deliberate flag.
  query_log_destination_arn = "arn:aws:logs:eu-west-2:111122223333:log-group:/aws/route53/resolver"

  forward_rules = {
    banksvc = {
      domain_name = "server.banksvc.net"
      target_ips  = ["10.36.65.179", "10.36.65.180"]
    }
  }
}

# ---------------------------------------------------------------------------
# Shape
# ---------------------------------------------------------------------------

run "creates_the_expected_resource_set" {
  command = plan

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  assert {
    condition     = length(aws_route53_resolver_endpoint.outbound) == 1
    error_message = "outbound is the default direction and should be created."
  }

  assert {
    condition     = length(aws_route53_resolver_endpoint.inbound) == 0
    error_message = "inbound is a separate pair of billed ENIs and must be opt-in."
  }

  assert {
    condition     = length(aws_route53_resolver_rule.this) == 1 && length(aws_route53_resolver_rule_association.this) == 1
    error_message = "every rule needs an association - without it the rule exists and does nothing."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.outbound_udp) == 2 && length(aws_vpc_security_group_egress_rule.outbound_tcp) == 2
    error_message = "both protocols, for every DNS server CIDR: UDP carries most queries, TCP carries the large responses."
  }
}

run "create_false_makes_nothing" {
  command = plan

  variables {
    create = false
  }

  assert {
    condition = alltrue([
      length(aws_route53_resolver_endpoint.outbound) == 0,
      length(aws_route53_resolver_rule.this) == 0,
      length(aws_route53_resolver_rule_association.this) == 0,
      length(aws_security_group.outbound) == 0,
    ])
    error_message = "create = false must plan to nothing at all."
  }

  assert {
    condition = alltrue([
      output.governance == null,
      output.firewall_request == null,
      output.verify == null,
      output.outbound_endpoint_id == null,
      length(output.rule_ids) == 0,
    ])
    error_message = "create = false must leave every output null or empty."
  }
}

# ---------------------------------------------------------------------------
# The failure this module exists to prevent
# ---------------------------------------------------------------------------

run "an_endpoint_with_no_egress_is_refused" {
  command = plan

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  # The endpoint comes up, the rules attach, the console looks healthy, and
  # every query times out. Nothing reports it.
  variables {
    dns_server_cidrs = []
  }

  expect_failures = [aws_route53_resolver_endpoint.outbound]
}

run "a_single_az_endpoint_is_refused" {
  command = plan

  # AWS accepts two subnets in one AZ. DNS for the entire VPC then has a single
  # point of failure and nothing says so.
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2a" }
  }

  expect_failures = [aws_route53_resolver_endpoint.outbound]
}

run "distinct_azs_are_accepted" {
  command = plan

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  assert {
    condition     = output.governance.single_az == false
    error_message = "two AZs must be reported as resilient."
  }
}

# ---------------------------------------------------------------------------
# Rules
# ---------------------------------------------------------------------------

run "a_forward_rule_with_no_target_is_rejected" {
  command = plan

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  variables {
    forward_rules = {
      banksvc = {
        domain_name = "server.banksvc.net"
        target_ips  = []
      }
    }
  }

  expect_failures = [var.forward_rules]
}

run "a_system_rule_needs_no_target_and_no_endpoint" {
  command = plan

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  # SYSTEM carves an exception out of a broader FORWARD - it stops forwarding
  # rather than redirecting it.
  variables {
    forward_rules = {
      banksvc = {
        domain_name = "server.banksvc.net"
        target_ips  = ["10.36.65.179", "10.36.65.180"]
      }
      public-exception = {
        domain_name = "www.server.banksvc.net"
        rule_type   = "SYSTEM"
      }
    }
  }

  assert {
    condition     = aws_route53_resolver_rule.this["public-exception"].resolver_endpoint_id == null
    error_message = "a SYSTEM rule must not reference an endpoint; there is nothing to forward through."
  }

  assert {
    condition     = length(aws_route53_resolver_rule_association.this) == 2
    error_message = "a SYSTEM rule still needs associating with the VPC to take effect."
  }
}

run "a_system_rule_with_targets_is_rejected" {
  command = plan

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  variables {
    forward_rules = {
      bad = {
        domain_name = "server.banksvc.net"
        rule_type   = "SYSTEM"
        target_ips  = ["10.36.65.179"]
      }
    }
  }

  expect_failures = [var.forward_rules]
}

run "two_rules_for_the_same_zone_are_rejected" {
  command = plan

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  # Route 53 would apply one of them, and which is not defined.
  variables {
    forward_rules = {
      a = { domain_name = "server.banksvc.net", target_ips = ["10.36.65.179"] }
      b = { domain_name = "server.banksvc.net", target_ips = ["10.36.65.180"] }
    }
  }

  expect_failures = [var.forward_rules]
}

run "a_malformed_dns_server_address_is_rejected" {
  command = plan

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  # 10.36.65179 is three octets and one of them is out of range - the shape of
  # a typo that reaches the API and fails there.
  variables {
    forward_rules = {
      banksvc = {
        domain_name = "server.banksvc.net"
        target_ips  = ["10.36.65179"]
      }
    }
  }

  expect_failures = [var.forward_rules]
}

run "an_out_of_range_octet_is_rejected" {
  command = plan

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  variables {
    forward_rules = {
      banksvc = {
        domain_name = "server.banksvc.net"
        target_ips  = ["10.36.999.1"]
      }
    }
  }

  expect_failures = [var.forward_rules]
}

run "one_subnet_is_rejected" {
  command = plan

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  variables {
    subnet_ids = ["subnet-0a1b2c3d4e5f60001"]
  }

  expect_failures = [var.subnet_ids]
}

# ---------------------------------------------------------------------------
# Contracts
# ---------------------------------------------------------------------------

run "the_firewall_request_names_the_new_addresses" {
  command = apply

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  # The endpoint's own ENIs, not the workload's - the distinction people miss
  # when they have already opened the database port.
  assert {
    condition     = length(output.firewall_request.outbound.source_addresses) == length(var.subnet_ids)
    error_message = "the request must list one source address per resolver ENI - the on-prem firewall needs every one of them, not just the first."
  }

  assert {
    condition = alltrue([
      contains(output.firewall_request.outbound.destinations, "10.36.65.179"),
      contains(output.firewall_request.outbound.destinations, "10.36.65.180"),
    ])
    error_message = "the request must name the DNS servers being queried."
  }

  assert {
    condition = alltrue([
      contains(output.firewall_request.outbound.ports, "53/udp"),
      contains(output.firewall_request.outbound.ports, "53/tcp"),
    ])
    error_message = "both protocols must be requested: UDP-only fails intermittently on large responses."
  }

  assert {
    condition     = can(regex("(?i)new", output.firewall_request.outbound.note))
    error_message = "the request must say these source addresses are new, or they get confused with the workload's."
  }
}

run "governance_reports_the_billed_footprint" {
  command = plan

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  assert {
    condition     = output.governance.billed_enis == 2
    error_message = "one ENI per subnet, billed hourly, is the cost of this module - it should be visible."
  }

  assert {
    condition     = output.governance.forwarded_zones["banksvc"] == "server.banksvc.net"
    error_message = "governance must name what is being forwarded."
  }
}

# ---------------------------------------------------------------------------
# Advisory checks
# ---------------------------------------------------------------------------

run "a_single_dns_server_warns" {
  command = plan

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  variables {
    dns_server_cidrs = ["10.36.65.179/32"]
    forward_rules = {
      banksvc = {
        domain_name = "server.banksvc.net"
        target_ips  = ["10.36.65.179"]
      }
    }
  }

  assert {
    condition     = contains(output.governance.rules_with_one_dns_server, "banksvc")
    error_message = "governance must name the zones with a single name server."
  }

  expect_failures = [check.forwarded_zones_have_more_than_one_name_server]
}

run "an_apex_zone_warns" {
  command = plan

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  # Forwarding banksvc.net takes every name under it out of public resolution
  # from this VPC.
  variables {
    forward_rules = {
      banksvc = {
        domain_name = "banksvc.net"
        target_ips  = ["10.36.65.179", "10.36.65.180"]
      }
    }
  }

  expect_failures = [check.forwarded_zones_are_no_broader_than_they_need_to_be]
}

run "both_directions_warns" {
  command = plan

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  variables {
    create_inbound       = true
    inbound_client_cidrs = ["10.36.0.0/16"]
  }

  assert {
    condition     = output.governance.billed_enis == 4
    error_message = "two endpoints is two pairs of ENIs, and the cost should be visible."
  }

  expect_failures = [check.both_directions_are_intentional]
}

run "byo_security_groups_warn_that_the_guard_is_gone" {
  command = plan

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  variables {
    security_group_ids = ["sg-0a1b2c3d4e5f6aaaa"]
    dns_server_cidrs   = []
  }

  assert {
    condition     = length(aws_security_group.outbound) == 0
    error_message = "supplying security groups must suppress the module's own."
  }

  expect_failures = [check.the_module_can_still_see_its_own_egress]
}

# ---------------------------------------------------------------------------
# Sharing
# ---------------------------------------------------------------------------

run "a_rule_can_be_shared_with_other_accounts" {
  command = plan

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  # One endpoint estate serving many VPCs, instead of every spoke building its
  # own pair of billed ENIs.
  variables {
    forward_rules = {
      banksvc = {
        domain_name = "server.banksvc.net"
        target_ips  = ["10.36.65.179", "10.36.65.180"]
        share_with  = ["222233334444", "555566667777"]
      }
    }
  }

  assert {
    condition     = length(aws_ram_resource_share.rules) == 1
    error_message = "one share per shared rule."
  }

  assert {
    condition     = length(aws_ram_principal_association.rules) == 2
    error_message = "one principal association per receiving account."
  }

  assert {
    condition     = length(output.governance.shared_with_accounts["banksvc"]) == 2
    error_message = "governance must report who a rule is shared with."
  }
}

run "a_malformed_account_id_is_rejected" {
  command = plan

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  variables {
    forward_rules = {
      banksvc = {
        domain_name = "server.banksvc.net"
        target_ips  = ["10.36.65.179"]
        share_with  = ["not-an-account"]
      }
    }
  }

  expect_failures = [var.forward_rules]
}

# ---------------------------------------------------------------------------
# Review regressions
#
# One run per finding. Each passed - or did not exist - while the thing it
# names was broken.
# ---------------------------------------------------------------------------

run "regression_rules_can_attach_to_an_existing_endpoint" {
  command = plan

  # "One endpoint, many rules" was documented and unbuildable: the rule
  # hard-referenced the endpoint this instance creates, so a second team either
  # paid for a second pair of billed ENIs or left the module.
  variables {
    create_outbound               = false
    existing_outbound_endpoint_id = "rslvr-out-0123456789abcdef0"
    dns_server_cidrs              = []
    query_log_destination_arn     = ""
    acknowledge_no_query_logging  = true
    forward_rules = {
      extra = { domain_name = "another.banksvc.net", target_ips = ["10.36.65.179", "10.36.65.180"] }
    }
  }

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  assert {
    condition     = length(aws_route53_resolver_endpoint.outbound) == 0
    error_message = "reusing an endpoint must not create a second one."
  }

  assert {
    condition     = aws_route53_resolver_rule.this["extra"].resolver_endpoint_id == "rslvr-out-0123456789abcdef0"
    error_message = "the rule must attach to the endpoint supplied, not to one of its own."
  }

  assert {
    condition     = output.governance.uses_existing_endpoint
    error_message = "governance must report that this instance does not own the endpoint."
  }
}

run "regression_a_rule_can_serve_many_vpcs" {
  command = plan

  # One rule, one VPC made the shared-services topology - the whole point of
  # owning an endpoint centrally - unbuildable.
  variables {
    additional_vpc_associations = ["vpc-0a1b2c3d4e5f6aaaa", "vpc-0a1b2c3d4e5f6bbbb"]
  }

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  assert {
    condition     = length(aws_route53_resolver_rule_association.this) == 3
    error_message = "one association per rule per VPC: the rule is inert in a VPC it is not associated with."
  }

  assert {
    condition     = length(output.governance.associated_vpcs) == 3
    error_message = "governance must name every VPC the rules reach."
  }
}

run "regression_an_aws_namespace_cannot_be_hijacked_by_default" {
  command = plan

  # The old apex check counted labels, so secretsmanager.<region>.amazonaws.com
  # sailed through - three labels deep, and a credential-interception position
  # for every workload in the VPC.
  variables {
    forward_rules = {
      hijack = {
        domain_name = "secretsmanager.eu-west-2.amazonaws.com"
        target_ips  = ["10.36.65.179", "10.36.65.180"]
      }
    }
  }

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  expect_failures = [aws_route53_resolver_rule.this]
}

run "regression_an_aws_namespace_is_allowed_when_acknowledged" {
  command = plan

  variables {
    allow_reserved_namespace_override = true
    forward_rules = {
      split-horizon = {
        domain_name = "s3.eu-west-2.amazonaws.com"
        target_ips  = ["10.36.65.179", "10.36.65.180"]
      }
    }
  }

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  assert {
    condition     = contains(output.governance.reserved_namespace_rules, "split-horizon")
    error_message = "an acknowledged interception must still be visible in governance - accepted is not the same as unremarkable."
  }
}

run "regression_a_system_rule_on_an_apex_is_counted" {
  command = plan

  # Breadth was computed over FORWARD rules only, so a SYSTEM rule on an apex -
  # a denial-of-resolution primitive with the same blast radius - was invisible.
  variables {
    forward_rules = {
      sys = { domain_name = "banksvc.net", rule_type = "SYSTEM" }
    }
  }

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  assert {
    condition     = contains(output.governance.broad_zone_rules, "sys")
    error_message = "a SYSTEM rule's breadth is as consequential as a FORWARD rule's."
  }

  expect_failures = [
    check.forwarded_zones_are_no_broader_than_they_need_to_be,
    check.the_outbound_endpoint_has_something_to_do,
  ]
}

run "regression_dns_egress_cannot_be_opened_to_the_world" {
  command = plan

  # The egress precondition points callers at this variable, so it has to
  # constrain what they set - otherwise the module's most prominent guardrail
  # steers a frustrated engineer toward 0.0.0.0/0.
  variables {
    dns_server_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.dns_server_cidrs]
}

run "regression_queries_cannot_be_forwarded_off_the_estate" {
  command = plan

  variables {
    dns_server_cidrs = ["10.36.65.179/32"]
    forward_rules = {
      exfil = { domain_name = "x.banksvc.net", target_ips = ["8.8.8.8"] }
    }
  }

  expect_failures = [var.forward_rules]
}

run "regression_duplicate_targets_are_rejected" {
  command = plan

  # They collapse into one target on the resource AND defeat the
  # single-name-server check, which counts the input list.
  variables {
    forward_rules = {
      dup = { domain_name = "x.banksvc.net", target_ips = ["10.36.65.179", "10.36.65.179"] }
    }
  }

  expect_failures = [var.forward_rules]
}

run "regression_the_domain_reaches_aws_normalised" {
  command = plan

  # AWS lowercases and strips the trailing dot server-side, so passing the raw
  # value produced a permanent diff on every subsequent plan.
  variables {
    forward_rules = {
      mixed = { domain_name = "Server.BankSvc.NET.", target_ips = ["10.36.65.179", "10.36.65.180"] }
    }
  }

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  assert {
    condition     = aws_route53_resolver_rule.this["mixed"].domain_name == "server.banksvc.net"
    error_message = "the domain must reach AWS lowercased and without the trailing dot, or every later plan shows a diff."
  }
}

run "regression_a_self_share_is_refused" {
  command = plan

  # RAM rejects a principal association naming the share's own owner, and a
  # rule is already usable in the account that owns it.
  variables {
    forward_rules = {
      shared = {
        domain_name = "x.banksvc.net"
        target_ips  = ["10.36.65.179", "10.36.65.180"]
        share_with  = ["111122223333"]
      }
    }
  }

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  expect_failures = [aws_ram_principal_association.rules]
}

run "regression_query_logging_is_required_unless_acknowledged" {
  command = plan

  variables {
    query_log_destination_arn = ""
  }

  expect_failures = [aws_route53_resolver_endpoint.outbound]
}

run "regression_query_logging_associates_every_vpc" {
  command = plan

  variables {
    additional_vpc_associations = ["vpc-0a1b2c3d4e5f6aaaa"]
  }

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  assert {
    condition     = length(aws_route53_resolver_query_log_config_association.this) == 2
    error_message = "every associated VPC needs the query log config, or half the estate is unaudited."
  }

  assert {
    condition     = output.governance.query_logging_enabled
    error_message = "governance must report whether the audit record exists."
  }
}

run "regression_a_rule_name_over_the_aws_limit_is_rejected" {
  command = plan

  variables {
    # 41 chars - the maximum `name` allows - plus a 50-char key is 92, well
    # past the 64-character AWS rule-name limit.
    name = "a-very-long-migration-name-for-the-estate"
    forward_rules = {
      an-extremely-long-rule-key-that-pushes-past-the-limit = {
        domain_name = "x.banksvc.net"
        target_ips  = ["10.36.65.179", "10.36.65.180"]
      }
    }
  }

  expect_failures = [var.forward_rules]
}

run "regression_a_single_character_rule_key_is_accepted" {
  command = plan

  # The 2-character minimum was arbitrary, and reviewers hit it by accident.
  variables {
    forward_rules = {
      a = { domain_name = "x.banksvc.net", target_ips = ["10.36.65.179", "10.36.65.180"] }
    }
  }

  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60001"]
    values = { availability_zone = "eu-west-2a" }
  }
  override_data {
    target = data.aws_subnet.resolver["subnet-0a1b2c3d4e5f60002"]
    values = { availability_zone = "eu-west-2b" }
  }

  assert {
    condition     = length(aws_route53_resolver_rule.this) == 1
    error_message = "a one-character rule key is valid; nothing in AWS forbids it."
  }
}

run "regression_the_security_group_output_keeps_its_type" {
  command = plan

  # The output flipped from an object to an empty map under create = false,
  # breaking any consumer indexing it - on the one operation that switch exists
  # to make safe.
  variables {
    create = false
  }

  assert {
    condition     = output.security_group_ids.outbound == null
    error_message = "the output must keep its shape when the module is switched off, not change type."
  }
}

run "regression_ipv6_is_refused_rather_than_half_supported" {
  command = plan

  # The variable advertised IPV6 and DUALSTACK while the ip_address blocks only
  # ever set subnet_id - an endpoint the caller could not address as intended.
  variables {
    resolver_endpoint_type = "DUALSTACK"
  }

  expect_failures = [var.resolver_endpoint_type]
}

run "regression_doh_fips_is_refused_on_an_outbound_endpoint" {
  command = plan

  variables {
    protocols = ["Do53", "DoH-FIPS"]
  }

  expect_failures = [var.protocols]
}
