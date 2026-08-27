# Network is BYO: no VPC, subnets, routing, endpoints or security groups here.
# The module only checks that the manager can SSH to workers, because the
# fleeting plugin needs that and a missing rule fails as a hung job rather than
# an error.

data "aws_vpc_security_group_rules" "worker" {
  count = local.create && var.verify_manager_to_worker_ssh_rule ? 1 : 0

  filter {
    name   = "group-id"
    values = var.worker_security_group_ids
  }
}

data "aws_vpc_security_group_rule" "worker" {
  for_each = local.create && var.verify_manager_to_worker_ssh_rule ? toset(data.aws_vpc_security_group_rules.worker[0].ids) : toset([])

  security_group_rule_id = each.value
}

locals {
  worker_ingress_rules = [
    for r in data.aws_vpc_security_group_rule.worker : {
      protocol = r.ip_protocol
      from     = r.from_port
      to       = r.to_port
      # Cross-account references arrive as "123456789012/sg-abc".
      ref_sg = r.referenced_security_group_id == null ? "" : element(reverse(split("/", r.referenced_security_group_id)), 0)
      prefix = r.prefix_list_id == null ? "" : r.prefix_list_id
    }
    if !r.is_egress
  ]

  # protocol "-1" is all protocols; AWS reports its ports as -1, so the range
  # check has to be skipped for it.
  manager_to_worker_ssh_rule_exists = anytrue([
    for r in local.worker_ingress_rules :
    contains(var.manager_security_group_ids, r.ref_sg) && (
      r.protocol == "-1" || (r.protocol == "tcp" && r.from <= 22 && r.to >= 22)
    )
  ])

  # Prefix lists can't be resolved here, so the error message mentions it as a
  # likely reason the check found nothing.
  worker_ingress_via_prefix_list = anytrue([
    for r in local.worker_ingress_rules : r.prefix != ""
  ])

  worker_ingress_via_cidr = anytrue([
    for r in local.worker_ingress_rules :
    r.ref_sg == "" && r.prefix == "" && (r.protocol == "-1" || (r.protocol == "tcp" && r.from <= 22 && r.to >= 22))
  ])
}

# The precondition lives on the worker launch template in workers.tf.

check "worker_ssh_ingress_is_not_a_cidr" {
  # Works, but widens who can answer on 22, and the manager sends the build
  # script over that session. Warn rather than fail: some estates can't express
  # an SG reference.
  assert {
    condition     = !var.verify_manager_to_worker_ssh_rule || !local.worker_ingress_via_cidr
    error_message = "A worker security group permits inbound 22 from a CIDR rather than from the manager's security group. The manager sends the generated build script over that session, so anything able to answer on 22 receives it. Prefer a security-group reference."
  }
}
