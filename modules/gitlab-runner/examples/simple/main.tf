# Simplest useful fleet: Spot workers that scale to zero when nothing is queued.
# Create the runner in GitLab first (Settings -> CI/CD -> Runners -> New runner)
# and pass its glrt- token.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.40.0, < 6.0.0" }
  }
}

provider "aws" {
  region = "us-east-1"
}

variable "runner_token" {
  description = "GitLab runner authentication token (glrt-...)."
  type        = string
  sensitive   = true
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  description = "Private subnets across 3 AZs."
  type        = list(string)
}

module "runners" {
  source = "../.." # the gitlab-runner module

  name              = "ci"
  worker_subnet_ids = var.private_subnet_ids

  # BYO network. The module attaches these and creates no network resources.
  manager_security_group_ids = [aws_security_group.manager.id]
  worker_security_group_ids  = [aws_security_group.worker.id]
  runner_token               = var.runner_token

  max_instances = 5 # spend guardrail

  # Pin what the manager fetches and runs as root. The module refuses to build
  # unpinned unless you explicitly set allow_unpinned_artifacts = true.
  gitlab_runner_version   = "17.9.0-1"
  fleeting_plugin_version = "1.1.0"

  tags = { Team = "platform" }
}

output "worker_asg_name" {
  value = module.runners.worker_asg_name
}

output "max_concurrent_jobs" {
  value = module.runners.max_concurrent_jobs
}

# ---------------------------------------------------------------------------
# The network the module no longer manages.
#
# This is deliberately IN the example rather than in the module: in a real estate
# these belong to your landing zone, and showing them here is how the example
# communicates the contract. The one rule the module VERIFIES rather than creates
# is the manager -> worker SSH path.
#
# NOTE: this example is written for a VPC WITH internet egress, to stay a usable
# quick start. For a fully isolated VPC replace the 0.0.0.0/0 rules with your
# on-prem CIDRs and VPC endpoint security groups - see ARCHITECTURE.md.
# ---------------------------------------------------------------------------

resource "aws_security_group" "manager" {
  name_prefix = "ci-runner-manager-"
  description = "GitLab runner manager. No inbound - operator access via SSM."
  vpc_id      = var.vpc_id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "worker" {
  name_prefix = "ci-runner-worker-"
  description = "GitLab runner workers. Inbound 22 from the manager SG only."
  vpc_id      = var.vpc_id

  lifecycle {
    create_before_destroy = true
  }
}

# THE rule the module verifies at plan time. Without it the fleeting plugin pushes
# an ephemeral key, cannot connect, and every job hangs until the retry budget
# expires - with no error naming the cause.
#
# A security-group REFERENCE, never a CIDR: the manager's SSH session carries the
# generated build script, so anything able to answer on 22 receives it.
resource "aws_vpc_security_group_ingress_rule" "worker_ssh_from_manager" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.manager.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  description                  = "Fleeting plugin SSH (EC2 Instance Connect ephemeral key)"
}

resource "aws_vpc_security_group_egress_rule" "manager_ssh_to_worker" {
  security_group_id            = aws_security_group.manager.id
  referenced_security_group_id = aws_security_group.worker.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  description                  = "SSH to workers"
}

# Egress. In an isolated VPC these become on-prem CIDRs plus your endpoint SGs.
resource "aws_vpc_security_group_egress_rule" "manager_https" {
  security_group_id = aws_security_group.manager.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "GitLab and AWS APIs"
}

resource "aws_vpc_security_group_egress_rule" "worker_https" {
  security_group_id = aws_security_group.worker.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "git clone, registry, package mirrors"
}

resource "aws_vpc_security_group_egress_rule" "dns" {
  for_each = {
    manager-udp = { sg = aws_security_group.manager.id, proto = "udp" }
    manager-tcp = { sg = aws_security_group.manager.id, proto = "tcp" }
    worker-udp  = { sg = aws_security_group.worker.id, proto = "udp" }
    worker-tcp  = { sg = aws_security_group.worker.id, proto = "tcp" }
  }

  security_group_id = each.value.sg
  cidr_ipv4         = data.aws_vpc.this.cidr_block
  ip_protocol       = each.value.proto
  from_port         = 53
  to_port           = 53
  description       = "DNS - easy to forget and silently fatal to omit"
}

data "aws_vpc" "this" {
  id = var.vpc_id
}
