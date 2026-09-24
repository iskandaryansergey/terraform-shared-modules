# Everything is nullable = false, and anything reaching an AWS API gets a
# validation.
#
# Rule if you add one: ternaries, can(), or alltrue([for ...]). Never
# `x == "" || f(x)` - 1.9 evaluates both sides.

variable "create" {
  description = "Master switch. false plans and applies cleanly to nothing."
  type        = bool
  default     = true
  nullable    = false
}

variable "name" {
  description = "Name prefix for the endpoints, rules and security group."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,40}$", var.name))
    error_message = "name must be 2-41 chars, lowercase alphanumeric or hyphen, starting with a letter."
  }
}

variable "vpc_id" {
  description = "VPC the resolver endpoints live in, and the first VPC every rule is associated with. Additional VPCs go in additional_vpc_associations."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id))
    error_message = "vpc_id must look like vpc-0123456789abcdef0."
  }
}

variable "additional_vpc_associations" {
  description = <<-EOT
    Further VPCs in THIS account to associate every rule with, beyond vpc_id.

    A rule takes effect in a VPC only once associated with it, and one rule can
    serve many VPCs - which is the point of owning the endpoint centrally. VPCs
    in other accounts cannot be associated from here: share the rule with
    forward_rules[*].share_with and let the receiving account associate it.
  EOT
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for v in var.additional_vpc_associations : can(regex("^vpc-[0-9a-f]{8,17}$", v))
    ])
    error_message = "additional_vpc_associations entries must look like vpc-0123456789abcdef0."
  }

  validation {
    condition     = !contains(var.additional_vpc_associations, var.vpc_id)
    error_message = "additional_vpc_associations must not repeat vpc_id; it is already associated."
  }

  validation {
    condition     = length(distinct(var.additional_vpc_associations)) == length(var.additional_vpc_associations)
    error_message = "additional_vpc_associations entries must be unique."
  }
}

variable "subnet_ids" {
  description = <<-EOT
    Subnets for the resolver ENIs. At least two, in different availability
    zones - Route 53 Resolver refuses to create an endpoint with one, and one
    AZ would make DNS a single point of failure for everything in the VPC.

    Each subnet gets one ENI, and each ENI is billed per hour.
  EOT
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.subnet_ids) >= 2 && length(var.subnet_ids) <= 10
    error_message = "subnet_ids must contain 2 to 10 subnets; Route 53 Resolver requires at least two IP addresses and accepts at most ten."
  }

  validation {
    condition = alltrue([
      for s in var.subnet_ids : can(regex("^subnet-[0-9a-f]{8,17}$", s))
    ])
    error_message = "subnet_ids entries must look like subnet-0123456789abcdef0."
  }

  validation {
    condition     = length(distinct(var.subnet_ids)) == length(var.subnet_ids)
    error_message = "subnet_ids entries must be unique."
  }
}

# ---------------------------------------------------------------------------
# Direction
#
# Two independent capabilities, and most estates want only one:
#
#   outbound  AWS resolves on-premises names. This is what a hybrid workload
#             needs to reach a database by hostname.
#   inbound   on-premises resolves AWS private names. Only needed when
#             something on-premises has to find a private hosted zone record.
#
# Each direction is its own endpoint and its own pair of ENIs, so turning both
# on doubles the hourly cost. Off by default for inbound because it is rarely
# what the caller actually came for.
# ---------------------------------------------------------------------------

variable "create_outbound" {
  description = "Create the outbound endpoint: AWS forwards queries to your DNS servers. This is the one a hybrid workload needs to resolve on-premises hostnames. Set false and supply existing_outbound_endpoint_id to add rules to an endpoint that already exists."
  type        = bool
  default     = true
  nullable    = false
}

variable "existing_outbound_endpoint_id" {
  description = <<-EOT
    Attach FORWARD rules to an outbound endpoint that already exists, instead of
    creating one.

    An endpoint is a pair of ENIs billed by the hour and it serves any number of
    rules, so a second zone does not need a second endpoint. This is how a
    shared estate is meant to work: one team owns the endpoint, every other team
    calls this module with create_outbound = false and adds their own rules.

    Mutually exclusive with create_outbound.
  EOT
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.existing_outbound_endpoint_id == "" ? true : can(regex("^rslvr-out-[0-9a-f]+$", var.existing_outbound_endpoint_id))
    error_message = "existing_outbound_endpoint_id must look like rslvr-out-0123456789abcdef0."
  }

  validation {
    condition     = var.existing_outbound_endpoint_id == "" ? true : !var.create_outbound
    error_message = "existing_outbound_endpoint_id and create_outbound are mutually exclusive: either this module creates the endpoint, or it attaches rules to yours. Set create_outbound = false."
  }
}

variable "create_inbound" {
  description = "Create the inbound endpoint: on-premises resolvers forward queries INTO Route 53. A separate pair of billed ENIs, and only needed when something on-premises has to resolve an AWS private hosted zone."
  type        = bool
  default     = false
  nullable    = false
}

# ---------------------------------------------------------------------------
# Forwarding rules
# ---------------------------------------------------------------------------

variable "forward_rules" {
  description = <<-EOT
    Zones to forward to your own DNS servers, keyed by a name you choose.

    Use the NARROWEST domain that covers the hosts you need. A rule for
    "banksvc.net" forwards that entire zone from this VPC, so any name in it
    that resolves publicly today stops doing so - your DNS servers become
    authoritative for all of it as far as this VPC is concerned. A rule for
    "server.banksvc.net" forwards only that subtree.

    target_ips are your DNS servers. Supply at least two in different failure
    domains where you can: with one, a single DNS outage takes down every name
    in the forwarded zone, which for a migration means every task that has to
    reconnect.

    rule_type:
      FORWARD  send these queries to target_ips (the normal case)
      SYSTEM   stop forwarding for this subdomain - carve an exception out of a
               broader FORWARD rule, e.g. keep one public name public
  EOT
  type = map(object({
    domain_name = string
    target_ips  = optional(list(string), [])
    target_port = optional(number, 53)
    rule_type   = optional(string, "FORWARD")
    share_with  = optional(list(string), [])
  }))
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for k, r in var.forward_rules : can(regex("^[a-z][a-z0-9-]{0,50}$", k))
    ])
    error_message = "forward_rules keys must be 1-51 chars, lowercase alphanumeric or hyphen, starting with a letter."
  }

  validation {
    condition = alltrue([
      for k, r in var.forward_rules :
      can(regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\\.?$", lower(r.domain_name)))
    ])
    error_message = "forward_rules[*].domain_name must be a DNS name like server.banksvc.net. Case is not significant and a trailing dot is accepted - both are normalised before they reach AWS."
  }

  validation {
    condition = alltrue([
      for k, r in var.forward_rules : contains(["FORWARD", "SYSTEM"], r.rule_type)
    ])
    error_message = "forward_rules[*].rule_type must be FORWARD or SYSTEM."
  }

  validation {
    # A FORWARD rule with nowhere to forward to is accepted by Terraform and
    # then fails at the API, or worse creates a rule that blackholes the zone.
    condition = alltrue([
      for k, r in var.forward_rules :
      r.rule_type == "FORWARD" ? length(r.target_ips) >= 1 : true
    ])
    error_message = "a FORWARD rule needs at least one target_ip. A SYSTEM rule takes none - it exists to stop forwarding for a subdomain."
  }

  validation {
    condition = alltrue([
      for k, r in var.forward_rules :
      r.rule_type == "SYSTEM" ? length(r.target_ips) == 0 : true
    ])
    error_message = "a SYSTEM rule must not have target_ips; it stops forwarding rather than redirecting it."
  }

  validation {
    condition = alltrue([
      for k, r in var.forward_rules : length(r.target_ips) <= 6
    ])
    error_message = "forward_rules[*].target_ips accepts at most six DNS servers per rule."
  }

  validation {
    # On-premises DNS reached over Cloud WAN or a VPN is RFC1918 by
    # construction, so a public address here forwards queries outside the
    # estate - the payload half of a DNS exfiltration path.
    condition = alltrue([
      for k, r in var.forward_rules : alltrue([
        for ip in r.target_ips :
        can(regex("^(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.)", ip))
      ])
    ])
    error_message = "forward_rules[*].target_ips must be RFC1918 (10/8, 172.16/12, 192.168/16). A public address forwards your queries outside the estate."
  }

  validation {
    # target_ip is a SET on the resource, so duplicates collapse into one
    # target - and the single-name-server check counts the input list, so it
    # would not fire. A typo would silently produce the exact fragility the
    # check exists to catch.
    condition = alltrue([
      for k, r in var.forward_rules : length(distinct(r.target_ips)) == length(r.target_ips)
    ])
    error_message = "forward_rules[*].target_ips entries must be unique. Duplicates collapse into a single target on the resource and defeat the single-name-server check."
  }

  validation {
    condition = alltrue([
      for k, r in var.forward_rules : alltrue([
        for ip in r.target_ips : can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", ip))
      ])
    ])
    error_message = "forward_rules[*].target_ips entries must be IPv4 addresses."
  }

  validation {
    condition = alltrue([
      for k, r in var.forward_rules : alltrue([
        for ip in r.target_ips : alltrue([
          for o in split(".", ip) : tonumber(o) <= 255
        ])
      ])
    ])
    error_message = "forward_rules[*].target_ips entries must have octets in the range 0-255."
  }

  validation {
    condition = alltrue([
      for k, r in var.forward_rules : r.target_port >= 1 && r.target_port <= 65535
    ])
    error_message = "forward_rules[*].target_port must be between 1 and 65535."
  }

  validation {
    # The generated rule name is "<name>-<key>" against a 64-character AWS
    # limit; without this it fails at the API naming neither variable.
    condition = alltrue([
      for k, r in var.forward_rules : length("${var.name}-${k}") <= 64
    ])
    error_message = "name plus a forward_rules key exceeds the 64-character Route 53 Resolver rule name limit. Shorten name or the key."
  }

  validation {
    # Two rules for the same domain is ambiguous and Route 53 picks one.
    condition = length(distinct([
      for k, r in var.forward_rules : lower(r.domain_name)
    ])) == length(var.forward_rules)
    error_message = "two forward_rules share a domain_name. Route 53 Resolver would apply one of them and which is not defined - merge them, or make one a narrower subdomain."
  }

  validation {
    condition = alltrue([
      for k, r in var.forward_rules : alltrue([
        for a in r.share_with : can(regex("^[0-9]{12}$", a))
      ])
    ])
    error_message = "forward_rules[*].share_with entries must be 12-digit account ids."
  }
}

variable "query_log_destination_arn" {
  description = <<-EOT
    CloudWatch Logs group, S3 bucket or Firehose ARN for Resolver query logs.

    This is the audit record for the thing this module builds: which names were
    resolved from the VPC, and when. Without it there is no way to answer that
    after an incident, and no way to detect a forwarding rule being abused -
    which for a regulated estate is the DNS equivalent of running without flow
    logs.

    Empty requires acknowledge_no_query_logging = true.
  EOT
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.query_log_destination_arn == "" ? true : can(regex("^arn:aws[a-z-]*:(logs|s3|firehose):", var.query_log_destination_arn))
    error_message = "query_log_destination_arn must be a CloudWatch Logs, S3 or Firehose ARN."
  }
}

variable "acknowledge_no_query_logging" {
  description = "Run without DNS query logging. The absence of an audit record is the deliberate choice here, so it takes a flag rather than an empty variable."
  type        = bool
  default     = false
  nullable    = false
}

variable "allow_reserved_namespace_override" {
  description = <<-EOT
    Permit a forwarding rule on an AWS or infrastructure namespace -
    amazonaws.com and friends.

    Refused by default because such a rule is not a routing decision, it is an
    interception: redirecting sts.amazonaws.com or
    secretsmanager.<region>.amazonaws.com inside a VPC puts whoever controls the
    target name server between every workload and its credentials. There are
    legitimate uses (a PrivateLink split-horizon estate), and they are rare
    enough to deserve a deliberate, reviewable flag.
  EOT
  type        = bool
  default     = false
  nullable    = false
}

variable "dns_server_cidrs" {
  description = <<-EOT
    CIDR blocks holding the DNS servers the outbound endpoint queries, for its
    egress rules. Narrow: this security group exists to reach name servers and
    nothing else, so a single server is a /32.

    Required when create_outbound is true and any FORWARD rule exists - without
    egress the endpoint is created, looks healthy, and every query times out.
  EOT
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for c in var.dns_server_cidrs : can(cidrnetmask(c))
    ])
    error_message = "dns_server_cidrs entries must be valid IPv4 CIDR blocks, e.g. 10.36.65.179/32."
  }

  validation {
    # In a VPC with no IGW and no NAT this is the one module that legitimately
    # creates an egress rule, so a 53/any-destination rule becomes the only
    # general-purpose outbound channel there is. The egress precondition points
    # callers straight at this variable, so it has to constrain what they set.
    condition = alltrue([
      for c in var.dns_server_cidrs :
      can(cidrnetmask(c)) ? can(regex("^(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.)", c)) : false
    ])
    error_message = "dns_server_cidrs entries must be RFC1918. A resolver endpoint with egress to a public destination is an exfiltration channel out of an isolated VPC - narrow this to the name servers themselves, typically a /32 each."
  }

  validation {
    condition = alltrue([
      for c in var.dns_server_cidrs :
      can(cidrnetmask(c)) ? tonumber(split("/", c)[1]) >= 16 : false
    ])
    error_message = "dns_server_cidrs entries must be /16 or narrower. This security group exists to reach a handful of name servers, not a network."
  }
}

variable "inbound_client_cidrs" {
  description = "CIDR blocks allowed to send DNS queries TO the inbound endpoint - your on-premises resolvers. Required when create_inbound is true; an inbound endpoint with no ingress answers nobody."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for c in var.inbound_client_cidrs : can(cidrnetmask(c))
    ])
    error_message = "inbound_client_cidrs entries must be valid IPv4 CIDR blocks."
  }
}

variable "security_group_ids" {
  description = "Use existing security groups instead of the ones this module creates. Supplying these makes dns_server_cidrs and inbound_client_cidrs no-ops, so the module can no longer tell you what is missing."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for s in var.security_group_ids : can(regex("^sg-[0-9a-f]{8,17}$", s))
    ])
    error_message = "security_group_ids entries must look like sg-0123456789abcdef0."
  }
}

variable "protocols" {
  description = "Resolver protocols. Do53 is plain DNS on port 53 and is what an on-premises forwarder speaks. DoH and DoH-FIPS exist for specific hardened setups and are not accepted everywhere."
  type        = list(string)
  default     = ["Do53"]
  nullable    = false

  validation {
    condition = alltrue([
      for p in var.protocols : contains(["Do53", "DoH", "DoH-FIPS"], p)
    ])
    error_message = "protocols entries must be Do53, DoH or DoH-FIPS."
  }

  validation {
    condition     = length(var.protocols) >= 1
    error_message = "at least one protocol is required."
  }

  validation {
    # DoH-FIPS is accepted on an INBOUND endpoint only. On outbound the API
    # rejects it - after the security groups have already been created.
    condition     = var.create_outbound ? !contains(var.protocols, "DoH-FIPS") : true
    error_message = "DoH-FIPS is not accepted on an OUTBOUND resolver endpoint; it is an inbound-only protocol. Use Do53 for a forwarder."
  }
}

variable "resolver_endpoint_type" {
  description = <<-EOT
    Address family for the endpoint ENIs. IPV4 only, for now.

    IPV6 and DUALSTACK need an ipv6 address supplied per ip_address block, and
    this module only sets subnet_id and lets AWS choose. Advertising them while
    the module cannot express them would produce an endpoint the caller cannot
    address as intended, so they are refused rather than half-supported.
  EOT
  type        = string
  default     = "IPV4"
  nullable    = false

  validation {
    condition     = var.resolver_endpoint_type == "IPV4"
    error_message = "resolver_endpoint_type must be IPV4. IPV6 and DUALSTACK require per-ENI IPv6 addressing, which this module does not yet express - see the README limits."
  }
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
  nullable    = false

  validation {
    condition = alltrue([
      for k, v in var.tags :
      length(k) <= 128 && length(v) <= 256 && !startswith(lower(k), "aws:")
    ])
    error_message = "tags keys must be <= 128 chars, values <= 256 chars, and no key may use the reserved \"aws:\" prefix."
  }
}
