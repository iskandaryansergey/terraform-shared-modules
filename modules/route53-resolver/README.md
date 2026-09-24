# terraform-aws-route53-resolver

Hybrid DNS for an isolated VPC: an outbound endpoint so AWS can resolve your
on-premises names, an optional inbound endpoint so on-premises can resolve AWS
private names, the forwarding rules, and the associations that make them take
effect.

**Status:** implemented and reviewed — 15 resources, 18 variables, 35
validations, 8 preconditions, 5 advisory checks, 15 outputs, 37 plan tests green.

Three independent reviews (correctness, security, module design) produced
**5 CRITICAL, 9 HIGH and ~20 MEDIUM/LOW** findings. The defects are fixed, each
with a regression test. See [What the reviews found](#what-the-reviews-found).

**Not validated against a live hybrid estate.** Every runtime claim here comes
from the provider schema and the Route 53 Resolver documentation.

---

## The problem it solves

The VPC resolver answers for AWS-internal names and for public names. For a
split-horizon corporate zone it returns nothing, because it has no path to your
DNS servers. Diagnosis from any host in the VPC:

```bash
getent hosts amazon.com                # works  -> the resolver itself is fine
getent hosts db.server.banksvc.net     # empty  -> no forwarding path exists
```

That pair is the whole diagnosis: nothing is broken, something is missing.

Three objects are required, and **all three**:

| # | Object | What happens without it |
|---|---|---|
| 1 | Outbound endpoint | Nowhere to send the query |
| 2 | Forwarding rule | Nothing says which zone goes where |
| 3 | **Rule↔VPC association** | The rule exists, reads correctly in the console, and **does nothing** |

The association is the one people miss.

---

## Quick start

```hcl
module "resolver" {
  source = "../../modules/route53-resolver"

  name       = "onprem"
  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids            # two AZs, required

  dns_server_cidrs = ["10.36.65.179/32"]         # egress for the endpoint

  forward_rules = {
    onprem = {
      domain_name = "server.banksvc.net"         # narrowest zone that works
      target_ips  = ["10.36.65.179"]
    }
  }
}
```

Then hand `terraform output -json firewall_request` to whoever administers the
DNS servers. **Terraform cannot open their firewall**, and until it is open the
queries leave AWS and are dropped — which presents as an unresolvable hostname
rather than an error.

---

## What it refuses

**An endpoint with no egress.** The commonest failure: the endpoint is created,
the rules attach, the console is green, and every query times out. Refused
unless `dns_server_cidrs` is set or you supply your own security groups.

**Both subnets in one AZ.** AWS accepts it. It makes DNS for the entire VPC a
single point of failure, and nothing reports it.

**A FORWARD rule with no target**, and a SYSTEM rule *with* one.

**Two rules for the same zone** — Route 53 applies one and which is undefined.

**Malformed addresses.** `10.36.65179` is three octets with one out of range —
the shape of a typo that otherwise reaches the API.

### Advisory checks

Four, warning without refusing: a zone with a **single DNS server**, an **apex
zone** being forwarded, **both directions** created (two sets of billed ENIs),
and **BYO security groups** (which silence the egress precondition).

---

## The parts people get wrong

**Zone breadth.** A rule for `banksvc.net` forwards that *entire zone* from this
VPC — anything in it that resolves publicly today stops. Use the narrowest
subdomain, or add a `SYSTEM` rule to carve out exceptions:

```hcl
forward_rules = {
  corp   = { domain_name = "server.banksvc.net", target_ips = var.dns }
  public = { domain_name = "www.server.banksvc.net", rule_type = "SYSTEM" }
}
```

**Both protocols.** UDP carries most queries, TCP carries responses too large
for UDP. Opening only UDP works until the first large answer, then fails
intermittently — the least pleasant DNS fault to diagnose. The module opens both.

**New source addresses.** The endpoint queries from its own ENIs, not from the
workload. If you already opened the database port for an application, those are
different addresses. `firewall_request` says so explicitly.

**One endpoint, many rules.** A second zone does not need a second endpoint.
Reuse `outbound_endpoint_id`, or share the rule to other accounts with
`share_with` so one estate serves many VPCs instead of every spoke paying for
its own pair of ENIs.

**Resolution is not reachability.** A name resolving proves the forwarder works,
not that anything routes to the address it returned.

---

## What the reviews found

**"One endpoint, many rules" was documented and unbuildable.** The rule
hard-referenced the endpoint each instance creates, so a second team either paid
for a second pair of billed ENIs or left the module. `existing_outbound_endpoint_id`
now expresses it, which is the shared-estate pattern the README always claimed.

**A rule could only reach one VPC.** `additional_vpc_associations` makes the
shared-services topology — one endpoint, many spokes — buildable.

**The apex check missed the zones that matter.** It counted labels, so
`secretsmanager.eu-west-2.amazonaws.com` sailed through at three labels deep —
a credential-interception position for every workload in the VPC, reported as
clean. AWS and infrastructure namespaces are now a **hard refusal** behind
`allow_reserved_namespace_override`, and breadth is computed over `SYSTEM` rules
too, since a SYSTEM rule on an apex is denial-of-resolution with the same reach.

**DNS egress could be opened to the world.** `dns_server_cidrs = ["0.0.0.0/0"]`
was accepted, and the egress precondition's error message pointed callers
straight at that variable — steering a frustrated engineer toward the widest
possible rule, in the one VPC with no other egress. Both `dns_server_cidrs` and
`target_ips` are now RFC1918-only.

**No query logging, and no way to add it.** The audit record for every name
resolved through the endpoint. Now created by default; its *absence* takes
`acknowledge_no_query_logging = true`.

Plus: uppercase and trailing-dot domains reached AWS verbatim and produced a
permanent plan diff; duplicate `target_ips` collapsed silently and defeated the
single-name-server check; a self-share was accepted and failed at apply;
`IPV6`/`DUALSTACK` were advertised but unwired; `DoH-FIPS` was accepted on an
outbound endpoint that rejects it; the security-group output changed type under
`create = false`.

---

## Day 2

| Change | Behaviour |
|---|---|
| Add a rule | Safe. New rule and associations; existing zones untouched |
| Remove a rule | That zone stops forwarding immediately |
| Change `domain_name` | ⚠️ Plans as in-place; **the API cannot update it**. Delete and re-add the rule under a new key |
| Change an association's VPC | ⚠️ Same — there is no update API. Use `additional_vpc_associations` to add, not to move |
| Change `subnet_ids` | ENIs are replaced and **the endpoint IPs change** — `firewall_request` is reissued and your DNS team must re-open the new addresses |
| Change security groups | Genuinely in-place, safe |

The `domain_name` and association rows are the ones that bite: Terraform shows a
clean plan and the apply fails partway. Treat a zone rename as remove-then-add.

---

## Cost

Billed per ENI-hour, one ENI per subnet, whether or not a query is made.

| Setup | ENIs | Approx/month |
|---|---:|---:|
| Outbound only, 2 AZs | 2 | ~$90 |
| Outbound + inbound, 2 AZs | 4 | ~$180 |

`governance.billed_enis` reports the count. If more than one VPC needs the same
zone, share the rule rather than repeating the estate.

---

## Testing

```bash
terraform test                      # 20 plan tests
terraform fmt -check -recursive .
terraform validate
```

The tests prove graph shape, rule wiring, every validation and precondition, and
the contract outputs. They cannot prove a name resolves — that needs the DNS
servers to accept queries from the endpoint's addresses, which is outside AWS.

---

## Inputs

| Name | Type | Default | Notes |
|---|---|---|---|
| `name` | string | — | Prefixes everything |
| `vpc_id` | string | — | Where the ENIs live and rules associate |
| `subnet_ids` | list(string) | — | **Two AZs minimum** |
| `forward_rules` | map(object) | `{}` | `domain_name`, `target_ips`, `rule_type`, `share_with` |
| `dns_server_cidrs` | list(string) | `[]` | Egress targets. Required with FORWARD rules |
| `create_outbound` | bool | `true` | AWS resolves your names |
| `existing_outbound_endpoint_id` | string | `""` | Attach rules to an endpoint you already have |
| `additional_vpc_associations` | list(string) | `[]` | Extra VPCs every rule reaches |
| `query_log_destination_arn` | string | `""` | CloudWatch Logs, S3 or Firehose. The audit record |
| `acknowledge_no_query_logging` | bool | `false` | Required to run without it |
| `allow_reserved_namespace_override` | bool | `false` | Required to forward an AWS namespace |
| `create_inbound` | bool | `false` | On-premises resolves AWS names |
| `inbound_client_cidrs` | list(string) | `[]` | Required with `create_inbound` |
| `security_group_ids` | list(string) | `[]` | BYO — silences the egress guard |
| `protocols` | list(string) | `["Do53"]` | Plain DNS is what a forwarder speaks |

## Outputs

| Name | Use |
|---|---|
| `firewall_request` | **Hand to your DNS administrators** — addresses, ports, why |
| `verify` | The commands to run after apply, in order |
| `outbound_ips` | Addresses queries come from |
| `outbound_endpoint_id` | Reuse for more rules; do not build a second endpoint |
| `rule_arns` | For sharing outside this module |
| `governance` | Posture, including billed ENI count |

## Not in scope

| Out | Why |
|---|---|
| VPC, subnets, routing | BYO, like the sibling modules |
| Private hosted zones | Different lifecycle; usually owned elsewhere |
| DNS Firewall rule groups | A separate concern with its own model |
| Your DNS servers' firewall | Emitted as `firewall_request` — cannot be automated from here |

## Limits

- **Not validated against a live hybrid estate.** No query has been resolved
  through anything this module built.
- **`domain_name` and association VPC cannot be changed in place** — the AWS API
  has no update for either, and Terraform plans them as in-place anyway. See
  [Day 2](#day-2).
- **IPv4 only.** `IPV6`/`DUALSTACK` are refused rather than half-supported: the
  `ip_address` blocks set only `subnet_id`, and the security-group rules and
  target validation are IPv4-only.
- **`DoH`/`DoH-FIPS` open no 443 egress.** The security groups open 53 only, so
  a non-Do53 protocol needs BYO security groups.
- **`target_port` applies to every target in a rule** — targets on different
  ports need separate rules, and the duplicate-domain validation then refuses
  them.
- **BYO security groups apply to both directions**, which cannot be correct for
  both if you run inbound and outbound together. Split them or use the module's
  own.
- **Cross-account association is the receiver's job.** `share_with` shares the
  rule; the receiving account associates it with its own VPCs.
