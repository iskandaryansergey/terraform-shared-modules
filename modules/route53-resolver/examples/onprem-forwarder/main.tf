# Resolving on-premises hostnames from an isolated VPC.
#
# The problem this solves: the VPC resolver answers for AWS-internal names and
# for public names, and returns nothing for a split-horizon corporate zone.
# There is no path from it to your DNS servers unless you build one. A name
# that resolves only on-premises fails as a connection timeout that reads
# exactly like a firewall problem, and people lose days to it.
#
# Diagnosis from any host in the VPC, before you build anything:
#
#   getent hosts amazon.com                  -> works  (resolver is fine)
#   getent hosts db.server.banksvc.net       -> empty  (no forwarding path)
#
# That pair is the whole diagnosis: nothing is broken, something is missing.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70.0, < 6.0.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-west-2"
}

variable "vpc_id" {
  description = "The isolated VPC that cannot resolve on-premises names."
  type        = string
}

variable "subnet_ids" {
  description = "Two subnets in different AZs for the resolver ENIs. Database subnets are fine - they already route to on-premises."
  type        = list(string)
}

variable "onprem_dns_servers" {
  description = <<-EOT
    Your DNS servers, authoritative for the zone below. Find them on an
    on-premises host:

      Linux:   cat /etc/resolv.conf
      Windows: ipconfig /all
  EOT
  type        = list(string)
}

variable "query_log_destination_arn" {
  description = "CloudWatch Logs group, S3 bucket or Firehose ARN for resolver query logs - the audit record of what was resolved through this endpoint. Leave empty only with acknowledge_no_query_logging."
  type        = string
  default     = ""
}

variable "acknowledge_no_query_logging" {
  description = "Run without the DNS audit record. Regulated estates should not."
  type        = bool
  default     = false
}

variable "forward_zone" {
  description = "The narrowest zone covering the hosts you need. \"server.banksvc.net\", not \"banksvc.net\"."
  type        = string
}

module "resolver" {
  source = "../../"

  name       = "onprem"
  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  # Egress for the endpoint. A single server is a /32 - this security group
  # exists to reach name servers and nothing else.
  dns_server_cidrs = [for ip in var.onprem_dns_servers : "${ip}/32"]

  forward_rules = {
    onprem = {
      domain_name = var.forward_zone
      target_ips  = var.onprem_dns_servers
    }
  }

  # The audit record for every name resolved through this endpoint. Its absence
  # is what needs acknowledging, not its presence.
  query_log_destination_arn    = var.query_log_destination_arn
  acknowledge_no_query_logging = var.acknowledge_no_query_logging

  tags = {
    Environment = "production"
    Owner       = "platform"
    Purpose     = "hybrid-dns"
  }
}

output "firewall_request" {
  description = "Hand to whoever administers the DNS servers. Terraform cannot open their firewall, and until it is open every query leaves AWS and is dropped."
  value       = module.resolver.firewall_request
}

output "verify" {
  description = "Run from a host in the VPC after apply."
  value       = module.resolver.verify
}

output "governance" {
  description = "The posture, including the billed ENI count."
  value       = module.resolver.governance
}
