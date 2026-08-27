# GitLab CI/CD Runner Infrastructure — Cost Analysis

**Module:** `modules/gitlab-runner`
**Provider:** AWS (sole provider; `hashicorp/aws >= 5.40.0, < 6.0.0`)
**Primary region:** **`eu-west-1` — EU (Ireland)**
**Secondary region:** `eu-west-2` — EU (London), costed alongside
**Reference region:** `us-east-1` — US East (N. Virginia), for delta only
**Pricing date:** 2026-08-27. AWS Price List bulk API publication date **2026-08-25**.
**Currency:** USD primary (AWS list currency); EUR/GBP conversions labelled where shown.
**Analysis basis:** module defaults as committed at `7b25201`, every deviation stated explicitly.

---

## 0. What changed in this revision, and why the answer is different

The module was refactored to **bring-your-own network**. It now creates **no VPC, subnet, route
table, NAT gateway, VPC endpoint, security group, or security-group rule** — a `grep` over the
module returns zero network resources. `ARCHITECTURE.md` §0 states the design target as a **VPC
with no route to the public internet**: GitLab over Direct Connect or VPN, AWS APIs over
PrivateLink, no NAT and no internet gateway.

That invalidates the previous revision of this document at the thesis level, not the detail
level. The old analysis concluded _"NAT Gateway is 43–78% of every scenario; spend an engineering
week on the image-delivery path to dodge it."_ In the design-target topology **there is no NAT
gateway to dodge**, container image bytes travel over a **free** S3 gateway endpoint, and the
dominant cost becomes a **fixed** charge for PrivateLink interface endpoints that the module does
not create and may not even be responsible for.

|                                                              | Previous revision                             | This revision                                                            |
| ------------------------------------------------------------ | --------------------------------------------- | ------------------------------------------------------------------------ |
| Network resources created by the module                      | 3 SGs, ~15 rules, 2 opt-in endpoint resources | **none**                                                                 |
| Assumed egress path                                          | NAT gateway to the public internet            | **PrivateLink + Direct Connect/VPN**, NAT modelled as the secondary case |
| #1 cost driver at Typical                                    | NAT data processing, 43.1%                    | **VPC interface endpoints, 66.4%** (fixed, caller-owned)                 |
| #1 cost driver at Peak                                       | NAT data processing, 75.2%                    | **Worker compute, 41.8%**                                                |
| Cost elasticity (workload ×10)                               | +515%                                         | **+134%**                                                                |
| Headline recommendation                                      | ECR pull-through cache to bypass NAT          | **Share the endpoint estate; do not give CI its own**                    |
| Financial case for weakening job isolation (`max_use_count`) | 24–37% saving                                 | **2.1% saving — the case is gone**                                       |

Two figures were also corrected on their own merits, independent of the refactor:

- **Warm idle pool hours.** The previous revision used 239 h in one table and $14.13 (≈266 h) in
  another. The correct figure from the default `autoscaling_policies` is **238.7 h/month**
  (11 h × 21.7 business days) = **$12.70** at the Ireland blended Spot rate. Used consistently here.
- **`detailed_monitoring` cost.** Previously modelled at $0.07/metric-month. AWS bills EC2
  detailed monitoring as custom metrics: **7 metrics × $0.30 = $2.10 per instance-month**. The
  sensitivity moves from +0.3% to **+1.2%**. Still immaterial, now correct.

Stale references elsewhere in the module's docs, found while preparing this and **not fixed here**
because they are outside this file: `ARCHITECTURE.md` line 523 recommends `create_vpc_endpoints`
and line 768 counts "2 VPC endpoint resources (opt-in)". Neither variable nor resource exists any
more.

---

## 1. Executive Summary

The module itself is close to free. Its entire created footprint at defaults — one small manager,
its disk, seven alarms, two custom metrics and a log group — is a **$17.40/month fixed floor**.
Everything else on the bill is either **elastic worker compute** or **network infrastructure the
module deliberately does not own**.

Because the module no longer creates network resources, the cost question splits in two. The
answer depends far more on **which network you drop it into** — and on **who is charged for that
network** — than on anything the module does.

### The three numbers a budget needs

|                                                                     | Monthly (USD) | Monthly (EUR) | Annual (USD) | Annual (EUR) |
| ------------------------------------------------------------------- | ------------: | ------------: | -----------: | -----------: |
| **Expected — isolated VPC, endpoints attributed in full**           |     **~$363** |     **~€311** |  **~$4,354** |  **~€3,731** |
| **Expected — isolated VPC, endpoints shared with the landing zone** |     **~$134** |     **~€114** |  **~$1,603** |  **~€1,374** |
| Expected — internet-connected VPC with NAT egress                   |         ~$319 |         ~€273 |      ~$3,830 |      ~€3,282 |

All three are the **same workload** (Scenario B: 20–30 developers, 4,340 jobs/month) on the
**same module defaults**. The 2.7× spread between the first two rows is a **cost-attribution
decision**, not an engineering one, and it is the single largest lever in this document.

### Full range, isolated topology (the design target)

|                                     | Endpoints attributed in full | Endpoints shared |
| ----------------------------------- | ---------------------------: | ---------------: |
| Minimum (Scenario A — Minimal)      |                        ~$317 |             ~$88 |
| **Expected (Scenario B — Typical)** |                    **~$363** |        **~$134** |
| High (Scenario C — Heavy)           |                        ~$633 |            ~$404 |
| Peak (Scenario D — Peak)            |                      ~$1,438 |          ~$1,208 |

**Largest cost driver: VPC interface endpoints — $240.90/month fixed, 66% of the Typical bill.**
Ten interface endpoints (eight named by `output.network_contract`, plus `ecr.api` and `ecr.dkr`
that the contract omits) across three AZs at $0.011/endpoint/AZ/hour. This is a **fixed** charge
that does not move with CI activity, and it is **the entire reason the Minimal scenario costs
almost as much as Typical.**

Worker compute — the line most teams budget for — is 12% at Typical and only becomes the top
driver at Peak.

**Estimated optimization opportunity: 53% of total spend at Typical, from one decision** —
provisioning the runner fleet into an existing landing-zone VPC whose SSM/EC2/logs/ECR endpoints
already exist, instead of standing up a CI-dedicated VPC with its own endpoint estate. No code
change, no security reduction.

> **Primary recommendation.** Budget **$140/month (€120) — $1,700/year (€1,450)** for a typical
> 20–30 developer fleet placed in an **existing** isolated landing zone in Ireland. If the fleet
> must have its own VPC and endpoint estate, budget **$370/month (€317) — $4,450/year (€3,810)**
> and treat the $241/month endpoint line as the thing to attack, because it is 66% of the bill and
> it is fixed. Do **not** budget on the assumption that CI network cost scales with CI activity in
> this topology — it barely does.

### Five findings worth a CTO's attention

1. **The isolated topology has a much flatter cost curve than the NAT topology.** 10× the
   workload costs **+134%** here versus **+515%** over NAT. Container image pulls — the byte class
   that dominated the previous analysis — cross a **free** S3 gateway endpoint. In an isolated
   VPC, CI cost is compute-bound and roughly linear; over NAT it is network-bound and
   super-linear. §12.

2. **The financial argument for weakening job isolation has disappeared.** Setting
   `max_use_count = 10` — one host serving ten jobs instead of one — saved 24–37% over NAT
   because it reused the Docker layer cache. In the isolated topology it saves **2.1%**, because
   the image bytes it was avoiding are already free. **Leave `max_use_count` at 1.** §14.

3. **The module's default manager bootstrap cannot work in the design-target topology.** It
   `curl`s `packages.gitlab.com` and runs `gitlab-runner fleeting install`, which downloads the
   plugin from GitLab.com. Neither is reachable with no internet path. A **baked manager AMI (or
   an internal RPM mirror) is a prerequisite, not an optimization** — roughly $2/month of snapshot
   storage and 16 hours of initial engineering. Worker bootstrap is fine: AL2023's `dnf install
docker` resolves to regional S3 and rides the free gateway endpoint. §3, §13-P1, §16.

4. **`output.network_contract` names eight interface endpoints. Jobs pulling from ECR need two
   more** (`ecr.api`, `ecr.dkr`) that the contract does not list — **$48.18/month at three AZs**.
   The contract enumerates what the _module_ needs, not what _jobs_ need. Costed here as required.
   §3.

5. **At every scenario up to Heavy, operational labour exceeds the cloud bill** — 45–80% of true
   TCO, and a _higher_ share than in the NAT topology, because a missing endpoint fails as a hang
   rather than an error and the AMI pipeline is mandatory. Any FinOps exercise that optimizes the
   $363 while ignoring the $450 is optimizing the smaller number. §17.

---

## 2. Architecture Cost Model

The module creates one long-lived manager and one scale-to-zero worker ASG. It attaches security
groups it is handed and otherwise does not touch the network. **Two network topologies are
therefore in scope, and they have different cost shapes.**

### Topology I — Isolated VPC (the design target)

```
   ON-PREM / CORPORATE                        AWS — VPC WITH NO INTERNET ROUTE
   ┌─────────────────┐                        ┌──────────────────────────────────────────┐
   │  GitLab (self-  │   Direct Connect       │  MANAGER  (ASG min=max=1)                │
   │  managed)       │◀══ or VPN ════════════▶│  t4g.small · 20 GB gp3 · 730 h/month     │  FIXED
   │  Package mirror │   $0/GB in             │  BAKED AMI REQUIRED (see §3)             │  $15.19/mo
   │  Artifact store │   $0.02/GB out         └────────────────┬─────────────────────────┘
   └─────────────────┘   (+$0.02/GB if a               │       │ SetDesiredCapacity
            ▲             Transit Gateway              │       │ + EC2 Instance Connect
            ║             is in the path)              │       ▼
            ║                                 ┌────────┴───────────────────────────────┐
            ║                                 │  WORKER ASG  min=0 · desired=0 · max=N │  VARIABLE
            ╚═════════════════════════════════│  Spot · 50 GB gp3 · one job per host   │  $0.05315/h
              git clone · deps · artifacts    └────────────────┬───────────────────────┘
                                                               │
                     ┌─────────────────────────────────────────┴──────────────────────┐
                     │  VPC ENDPOINTS  (NOT created by module)                        │  FIXED
                     │  10 × interface  @ $0.011/AZ/h  →  $240.90/mo at 3 AZ          │  ← THE DRIVER
                     │   1 × S3 gateway @ $0            →  image + package bytes FREE  │
                     └───────────────────────────────────────────────────────────────┘
```

Cost behaviour: **a high fixed floor and an almost flat variable line.** The endpoint estate is
billed by the hour whether or not a single job runs. Image pulls, `dnf` traffic and S3 cache
traffic are free. Only three byte classes cost anything — AWS control-plane calls at $0.01/GB
through the interface endpoints, and on-prem traffic at $0.02/GB through a Transit Gateway and/or
Direct Connect.

### Topology II — Internet-connected VPC with NAT egress (the secondary case)

```
   MANAGER + WORKER ASG (as above, in private subnets)
                │  every image pull, every package, every git clone, every artifact
                ▼
   ┌──────────────────────────────────────────┐
   │  NAT GATEWAY  (NOT created by module)    │  FIXED + VARIABLE
   │  $0.048/hour  +  $0.048/GB processed     │  $105.12/mo at 3 AZ
   └────────────────┬─────────────────────────┘  + $0.09/GB outbound egress
                    ▼
       Docker Hub · GitLab.com · package mirrors
```

Cost behaviour: **a modest fixed floor and a steep variable line.** Every byte a job moves is
metered twice for outbound traffic ($0.048 NAT + $0.09 egress = $0.138/GB) and once for inbound
($0.048/GB). This is the topology the previous revision analysed, retained in full because
plenty of callers will deploy into a VPC that already has NAT.

### The three behaviours that follow from the module's own design

**Compute is genuinely elastic, and this is the module's best cost property.** `min_size = 0`,
`desired_capacity = 0`, and the default `autoscaling_policies` catch-all `idle_count = 0` mean an
idle weekend costs nothing but the manager. `max_instances` is a spend ceiling, not a
reservation — raising it from 10 to 100 costs exactly $0 until jobs actually queue. Spot at
`price-capacity-optimized` across four families lands ~48% below On-Demand in Ireland.

**Network cost is no longer the module's to shape.** Under BYO the module cannot create an
endpoint, cannot create a NAT, and cannot route anything. Its only network artefact is a
plan-time _verification_ (`network-byo.tf`) that a manager→worker SSH rule exists, which costs
nothing — `DescribeSecurityGroupRules` is a free API call. Everything else is the caller's bill.
This document therefore attributes network cost explicitly rather than folding it in.

**Two defaults still drive real money, but different money than before.** `max_use_count = 1`
means a fresh instance per job. Over NAT that bought a cold image pull every time — expensive.
In an isolated VPC the image bytes are free, so all that remains is **~2.24 minutes of billed
boot time per job**, an 18–36% provisioning tax on worker-hours. `worker_ami_id = ""` triggers
`dnf install docker` on every boot; in an isolated VPC that traffic is free (regional S3), so the
default is only a **latency** cost, not a network cost.

---

## 3. Resource Inventory

### Created by the module — every billable and non-billable resource, defaults, eu-west-1

Resources with no line item are listed so that "free" is an assertion, not an omission.

| Resource                       | Terraform address                                 |                                 Qty (default) | Billing model                        |    Monthly | Cost type           |
| ------------------------------ | ------------------------------------------------- | --------------------------------------------: | ------------------------------------ | ---------: | ------------------- |
| Manager EC2 instance           | `aws_autoscaling_group.manager` via LT            |                               1 × `t4g.small` | On-Demand, per-second (60 s min)     |     $13.43 | **Fixed**           |
| Manager root EBS               | `aws_launch_template.manager`                     |                                 1 × 20 GB gp3 | GB-month                             |      $1.76 | **Fixed**           |
| Worker EC2 instances           | `aws_autoscaling_group.workers`                   |                      0 → `max_instances` (10) | Spot, per-second (60 s min)          |   variable | **Variable**        |
| Worker root EBS                | `aws_launch_template.worker`                      |                     50 GB gp3 × live instance | GB-second while attached             |   variable | **Variable**        |
| Worker EBS IOPS                | `worker_disk_iops = 3000`                         |                          at gp3 free baseline | $0 ≤ 3,000                           |         $0 | **$0**              |
| Worker EBS throughput          | `worker_disk_throughput = 125`                    |                          at gp3 free baseline | $0 ≤ 125 MiBps                       |         $0 | **$0**              |
| CloudWatch metric alarms       | `aws_cloudwatch_metric_alarm.*`                   |                                         **6** | $0.10/alarm-month                    |      $0.60 | **Fixed**           |
| CloudWatch composite alarm     | `aws_cloudwatch_composite_alarm.orphaned_workers` |                                             1 | $0.50/alarm-month                    |      $0.50 | **Fixed**           |
| CloudWatch custom metrics      | `RunnerHealthy`, `BootstrapFailure`               |                               2 metric-months | $0.30/metric-month                   |      $0.60 | **Fixed**           |
| `PutMetricData` calls          | 60 s heartbeat timer on the manager               |                                  43,800/month | $0.01/1,000 requests                 |      $0.44 | **Fixed**           |
| CloudWatch log group           | `aws_cloudwatch_log_group.manager`                |                           1, 30-day retention | $0.57/GB in, $0.03/GB-mo             | $0.03–0.18 | **Variable** (tiny) |
| SSM Parameter (SecureString)   | `aws_ssm_parameter.token`                         |                              1, Standard tier | $0 (Standard ≤ 4 KB)                 |         $0 | **$0**              |
| Manager AMI lookup             | `data.aws_ami.al2023_manager`                     |                                  Amazon-owned | free API call                        |         $0 | **$0**              |
| Worker AMI lookup              | `data.aws_ami.al2023_worker`                      |                                  Amazon-owned | free API call                        |         $0 | **$0**              |
| SG-rule verification           | `data.aws_vpc_security_group_rule[s].worker`      |                                1 + N per plan | `DescribeSecurityGroupRules` is free |         $0 | **$0**              |
| IAM roles, profiles, policies  | `iam.tf`                                          | 2 roles, 2 profiles, 1 inline, ≤4 attachments | —                                    |         $0 | **$0**              |
| Launch templates, ASGs         | `manager.tf`, `workers.tf`                        |                                 2 LTs, 2 ASGs | —                                    |         $0 | **$0**              |
| ASG group metrics (1-min)      | `enabled_metrics` on both ASGs                    |                                     6 metrics | ASG group metrics are free           |         $0 | **$0**              |
| EC2 Instance Connect           | `ec2-instance-connect:SendSSHPublicKey`           |                                   ~1 call/job | —                                    |         $0 | **$0**              |
| Public IPv4                    | `assign_public_ips = false`                       |                                             0 | $0.005/h if enabled                  |         $0 | **$0 at default**   |
| Detailed monitoring            | `detailed_monitoring = false`                     |                                             0 | $2.10/instance-mo if enabled         |         $0 | **$0 at default**   |
| KMS                            | `kms_key_arn = ""` → AWS-managed keys             |                                             — | $1/mo per CMK if caller supplies one |         $0 | **$0 at default**   |
| **Module-created fixed floor** |                                                   |                                               |                                      | **$17.36** | **$208/year**       |

**Alarm count note.** Six metric alarms at defaults: `runner_unhealthy`, `bootstrap_failed`,
`manager_absent`, `fleet_at_capacity`, `capacity_shortfall`, `workers_present`. `manager_absent`
is gated on `manager_self_heal` (default `true`); with `manager_self_heal = false` the count drops
to five and the module provisions `aws_instance.manager` instead of the single-instance ASG — same
compute cost, one alarm less, no self-healing.

**Not created, and not invented here.** No S3 bucket, no ECR repository, no load balancer, no DNS
record, no Lambda, no EventBridge rule, no snapshot lifecycle policy, no KMS key, and — as of the
BYO refactor — **no VPC, subnet, route table, NAT gateway, VPC endpoint, security group, or
security-group rule.** Distributed S3 caching is reachable via `extra_runner_config_toml` but is
not configured by default; it appears only as an optimization in §13.

### Required but NOT created — Topology I (isolated)

Architecturally mandatory for the module to function as designed. Attributed explicitly rather
than folded into the module's own numbers.

| Resource                                                        | Why mandatory                                                                                                                                                                | eu-west-1 rate           |        At 3 AZ | Cost type                   |
| --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ | -------------: | --------------------------- |
| **Interface endpoints — named by `network_contract`**           | `ec2`, `autoscaling`, `ssm`, `ssmmessages`, `ec2messages`, `ec2-instance-connect`, `logs`, `monitoring`. Without any one of them the fleet fails **as a hang, not an error** | $0.011/endpoint/AZ/h     | **$192.72/mo** | **Fixed**                   |
| **Interface endpoints — required by jobs, NOT in the contract** | `ecr.api`, `ecr.dkr`. Jobs cannot pull an image without them and there is no public path                                                                                     | $0.011/endpoint/AZ/h     |  **$48.18/mo** | **Fixed**                   |
| **S3 gateway endpoint**                                         | ECR layer bytes, AL2023 `dnf` repos, S3 cache. Mandatory _and_ free                                                                                                          | **$0.00**                |      **$0.00** | **$0**                      |
| Interface endpoint data processing                              | All AWS API traffic                                                                                                                                                          | $0.01/GB                 |       variable | **Variable**                |
| Transit Gateway VPC attachment                                  | If the on-prem path traverses a TGW                                                                                                                                          | $0.05/h                  |      $36.50/mo | **Fixed**                   |
| Transit Gateway data processing                                 | Same                                                                                                                                                                         | $0.02/GB                 |       variable | **Variable**                |
| Direct Connect data transfer out                                | Artifact uploads and git pushes to on-prem GitLab. **Data _in_ is free**                                                                                                     | $0.02/GB (Europe)        |       variable | **Variable**                |
| Direct Connect port hours                                       | The circuit itself                                                                                                                                                           | $0.30/h (1 Gbps, Europe) |        $219/mo | **Shared — not attributed** |
| Manager AMI pipeline                                            | **Prerequisite, not optional** — see below                                                                                                                                   | ~$2/mo snapshot storage  |          $2/mo | **Fixed**                   |
| VPC, subnets, route tables, SGs                                 | Passed in via `worker_subnet_ids`, `*_security_group_ids`                                                                                                                    | $0                       |             $0 | **$0**                      |
| GitLab (self-managed, on-prem)                                  | The CI system itself                                                                                                                                                         | Out of AWS scope — §15   |              — | —                           |

**Endpoints not required, listed so nobody buys them.** `kms` is **not** needed: EBS encryption
and `ssm get-parameter --with-decryption` both call KMS service-side, not from the instance —
that is $24.09/month at 3 AZ someone will otherwise add "for completeness". `sts` is **not**
needed by the module (it uses instance-profile credentials from IMDS directly) but **is** needed
if jobs assume roles via `additional_worker_policy_arns` — conditional +$24.09/month.

> ### The manager bootstrap does not work in this topology at defaults
>
> `templates/manager-user-data.sh.tftpl` does three things that need the public internet:
> `curl`s `package_repo_script_url` (defaults to `packages.gitlab.com`), `dnf install
gitlab-runner` from that repo, and runs `gitlab-runner fleeting install`, which resolves the
> plugin from GitLab.com's registry and has **no URL override**.
>
> In a VPC with no internet route all three **hang** rather than fail cleanly. So Topology I
> requires **either** a baked `manager_ami_id` with `gitlab-runner` and `fleeting-plugin-aws`
> pre-installed, **or** an internal RPM mirror plus a pre-staged plugin binary. This document
> assumes the baked AMI and carries its cost: ~$2/month of EBS snapshot storage (three retained
> versions of a manager and a worker image, at $0.05/GB-month) plus the labour in §16.
>
> **The worker bootstrap is fine.** `dnf install docker` resolves to the regional AL2023
> repository, which is S3-backed, so it rides the free gateway endpoint. Baking `worker_ami_id`
> remains a **latency** optimization in this topology, not a network-cost one.

### Required but NOT created — Topology II (NAT egress)

| Resource                             | Why mandatory                                                                                              | eu-west-1 rate       |                   At 3 AZ | Cost type            |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------- | -------------------- | ------------------------: | -------------------- |
| **NAT Gateway**                      | Workers are in private subnets (`assign_public_ips = false`) and must reach registries, mirrors and GitLab | $0.048/h + $0.048/GB | **$105.12/mo** + variable | **Fixed + Variable** |
| Internet data transfer out           | Artifact uploads, git pushes, API traffic                                                                  | $0.09/GB             |                  variable | **Variable**         |
| VPC, subnets, route tables, SGs, IGW | Passed in / caller-owned                                                                                   | $0                   |                        $0 | **$0**               |

---

## 4. Pricing Assumptions

EC2/EBS/NAT/CloudWatch/VPC-endpoint rates were pulled from the **AWS Price List Bulk API**
(`pricing.us-east-1.amazonaws.com/offers/v1.0/aws/…/{region}/index.json`, publication date
**2026-08-25**). Spot rates came from the **AWS public Spot price feed**
(`website.spot.ec2.aws.a2z.com/spot.json`). Both on 2026-08-26. The BYO refactor changed no
prices, so these carry forward unmodified.

**Transit Gateway, Direct Connect and Site-to-Site VPN rates were not part of that pull** and come
from AWS public pricing pages. They are marked **MEDIUM confidence** in §19 and are the figures
most worth re-checking against your own account before committing a budget.

### Compute — On-Demand and Spot, Linux, shared tenancy (USD/hour)

| Instance                  | vCPU / RAM | **IE On-Demand** | **IE Spot** | **LON On-Demand** | **LON Spot** | US-E1 Spot (ref) |
| ------------------------- | ---------- | ---------------: | ----------: | ----------------: | -----------: | ---------------: |
| `m6i.large`               | 2 / 8 GiB  |          0.10700 |      0.0541 |           0.11100 |       0.0390 |           0.0377 |
| `m6a.large`               | 2 / 8 GiB  |          0.09630 |      0.0528 |           0.09990 |       0.0394 |           0.0389 |
| `m5.large`                | 2 / 8 GiB  |          0.10700 |      0.0522 |           0.11100 |       0.0355 |           0.0421 |
| `m5a.large`               | 2 / 8 GiB  |          0.09600 |      0.0535 |           0.10000 |       0.0404 |           0.0383 |
| **Blended default fleet** |            |      **0.10158** | **0.05315** |       **0.10548** |  **0.03858** |      **0.03925** |
| `t4g.small` (manager)     | 2 / 2 GiB  |          0.01840 |      0.0092 |           0.01880 |       0.0059 |           0.0068 |
| `m7g.large` (arm64)       | 2 / 8 GiB  |          0.09100 |      0.0397 |           0.09440 |       0.0288 |           0.0406 |
| `m6g.large` (arm64)       | 2 / 8 GiB  |          0.08600 |      0.0390 |           0.08880 |       0.0375 |           0.0311 |
| `c7g.large` (arm64)       | 2 / 4 GiB  |          0.07750 |      0.0335 |           0.08590 |       0.0264 |           0.0237 |
| **Blended arm64 fleet**   |            |      **0.08483** | **0.03740** |       **0.08970** |  **0.03090** |      **0.03180** |

### The Ireland Spot anomaly — still true, and now a larger share of the bill

|                                 |                                  IE x86 default fleet |                              IE arm64 fleet |
| ------------------------------- | ----------------------------------------------------: | ------------------------------------------: |
| Blended Spot rate               |                                            $0.05315/h |                       **$0.03740/h (−30%)** |
| Discount vs On-Demand           |                                                   48% |                                     **56%** |
| Spot Advisor interruption bands | `m6i` **>20%**, `m5` **>20%**, `m6a` 5–10%, `m5a` <5% | `m7g` **<5%**, `m6g` **<5%**, `c7g` **<5%** |

The module's default `worker_instance_types` are both **more expensive and less stable** in
eu-west-1 than the Graviton alternative. `price-capacity-optimized` will steer away from the two

> 20% pools, but that steers it toward `m5a`/`m6a` — the pricier end of an already pricey set. The
> identical x86 fleet costs **$0.03925/h in us-east-1** and **$0.03858/h in London**; Ireland is
> **+35% vs us-east-1** for these specific pools.

**This matters more in Topology I than it did over NAT.** With the network bill collapsed, worker
compute rises from ~14% to 30–42% of the total at Heavy and Peak — so a 30% cut to the compute
line is worth proportionally more. See §13-Q3.

### Network and everything else (USD)

| Item                                        | **eu-west-1 (Ireland)** | **eu-west-2 (London)** | us-east-1 (ref) | Unit                               |
| ------------------------------------------- | ----------------------: | ---------------------: | --------------: | ---------------------------------- |
| **VPC interface endpoint**                  |               **0.011** |                  0.011 |           0.010 | per endpoint/AZ/hour               |
| **VPC interface endpoint data**             |                **0.01** |                   0.01 |            0.01 | per GB                             |
| **VPC S3 gateway endpoint**                 |                **0.00** |               **0.00** |        **0.00** | —                                  |
| Transit Gateway VPC attachment              |                    0.05 |                   0.05 |            0.05 | per attachment/hour                |
| Transit Gateway data processing             |                    0.02 |                   0.02 |            0.02 | per GB                             |
| Direct Connect data transfer out            |                    0.02 |                   0.02 |            0.02 | per GB (to a European DX location) |
| Direct Connect data transfer in             |                **0.00** |                   0.00 |            0.00 | per GB                             |
| Direct Connect port — 1 Gbps dedicated      |                    0.30 |                   0.30 |            0.30 | per hour                           |
| Direct Connect port — 10 Gbps dedicated     |                    2.25 |                   2.25 |            2.25 | per hour                           |
| Site-to-Site VPN connection                 |                    0.05 |                   0.05 |            0.05 | per connection/hour                |
| NAT Gateway hourly                          |               **0.048** |                  0.050 |           0.045 | per hour                           |
| NAT Gateway data processing                 |               **0.048** |                  0.050 |           0.045 | per GB (both directions)           |
| Data transfer out to internet (first 10 TB) |                **0.09** |                   0.09 |            0.09 | per GB                             |
| Cross-AZ data transfer                      |     0.01 each direction |                   0.01 |            0.01 | per GB                             |
| EBS gp3 storage                             |               **0.088** |                 0.0928 |           0.080 | GB-month                           |
| EBS gp3 IOPS above 3,000                    |                  0.0055 |                 0.0058 |           0.005 | IOPS-month                         |
| EBS gp3 throughput above 125 MiBps          |                   0.044 |                 0.0464 |            0.04 | MiBps-month                        |
| EBS snapshot (standard tier)                |                    0.05 |                  0.053 |            0.05 | GB-month                           |
| Public IPv4 (in use)                        |                   0.005 |                  0.005 |           0.005 | per hour                           |
| CloudWatch standard alarm                   |                    0.10 |                   0.10 |            0.10 | per alarm-month                    |
| CloudWatch composite alarm                  |                    0.50 |                   0.50 |            0.50 | per alarm-month                    |
| CloudWatch custom metric                    |                    0.30 |                   0.30 |            0.30 | per metric-month                   |
| CloudWatch `PutMetricData`                  |                    0.01 |                   0.01 |            0.01 | per 1,000 requests                 |
| CloudWatch Logs ingestion (Standard)        |                **0.57** |                 0.5985 |            0.50 | per GB                             |
| CloudWatch Logs storage                     |                    0.03 |                 0.0315 |            0.03 | per GB-month                       |
| EC2 detailed monitoring                     |                    2.10 |                   2.10 |            2.10 | per instance-month (7 × $0.30)     |
| T4g surplus CPU credits                     |                    0.04 |                   0.04 |            0.04 | per vCPU-hour                      |
| ECR storage                                 |                    0.10 |                   0.10 |            0.10 | per GB-month                       |
| GitLab.com compute minutes                  |           $10 per 1,000 |                   same |            same | —                                  |

**Regional deltas vs us-east-1:** Ireland is **+10% on interface endpoints**, +6.7% on NAT, +10%
on EBS, +14% on CloudWatch Logs ingestion, and **+35% on default-fleet Spot**. London is +10% on
endpoints, +11% NAT, +16% EBS, +20% Logs, and −2% Spot. Endpoint data processing, TGW, DX, DTO,
alarms and custom metrics are **identical in all three regions**.

### Foreign exchange

| Pair      |     Rate | Source          | Date       |
| --------- | -------: | --------------- | ---------- |
| USD → EUR | 0.856908 | open.er-api.com | 2026-08-26 |
| USD → GBP | 0.733061 | open.er-api.com | 2026-08-26 |

AWS lists in USD and bills in USD by default. EUR/GBP figures here are **indicative conversions**,
not AWS-quoted prices. Currencies are never mixed inside a table without a labelled column.

### Pricing notes that change the answer

- **The interface-endpoint charge is per endpoint, per AZ, per hour.** Not per VPC. Ten endpoints
  across three AZs is **thirty** billable endpoint-AZ-hours at every hour of every month:
  10 × 3 × $0.011 × 730 = **$240.90**. AZ count is a first-order cost variable in Topology I, and
  it is a variable the module does not control — it follows the subnets you pass.
- **The S3 gateway endpoint is genuinely free** — no hourly charge, no data-processing charge. It
  is also the mechanism that makes ECR layer pulls and AL2023 `dnf` traffic free, which is why
  Topology I's variable line is nearly flat. Take it unconditionally.
- **Direct Connect is asymmetric.** Data _into_ AWS is free; data _out_ is $0.02/GB. For CI that
  is favourable: `git clone` and dependency downloads are inbound and free; only artifact uploads
  are charged.
- **The gp3 defaults sit exactly on the free baseline.** `worker_disk_iops = 3000` and
  `worker_disk_throughput = 125` are the included allowance. Raising either bills immediately.
- **Spot is a live market.** These are point-in-time rates; historical variance for these pools is
  roughly ±15%, and the Ireland x86 pools are currently at an unusually poor point in that band.
- **No free tier is applied in the primary model.** The 100 GB/month internet-egress allowance is
  excluded, and in Topology I it is worth nothing anyway — there is no internet egress. Shown
  separately for Topology II in §8.

---

## 5. Workload Scenarios

Runner cost is a function of workload, not of provisioned size. Four scenarios with every
assumption stated. **These are modelled scenarios, not observed usage.** Traffic totals are
identical across both topologies — what changes is the **price of each byte**.

|                                         | **A — Minimal** | **B — Typical** | **C — Heavy** | **D — Peak**    |
| --------------------------------------- | --------------- | --------------- | ------------- | --------------- |
| Team size                               | 5–8 devs        | 20–30 devs      | 80–120 devs   | 200+ / monorepo |
| Jobs per business day                   | 40              | 200             | 900           | 2,500           |
| **Jobs per month** (21.7 business days) | **868**         | **4,340**       | **19,530**    | **54,250**      |
| Average job duration                    | 4 min           | 6 min           | 8 min         | 10 min          |
| Job-minutes/month                       | 3,472           | 26,040          | 156,240       | 542,500         |
| Peak concurrency                        | 3               | 8               | 25            | 60              |
| `max_instances` setting                 | 10 (default)    | 10 (default)    | 40            | 100             |
| Container image per job                 | 250 MB          | 350 MB          | 500 MB        | 700 MB          |
| Dependencies per job                    | 80 MB           | 120 MB          | 180 MB        | 250 MB          |
| Git clone/fetch per job                 | 30 MB           | 40 MB           | 60 MB         | 80 MB           |
| Artifacts uploaded per job              | 15 MB           | 25 MB           | 40 MB         | 50 MB           |
| Docker install per boot                 | 120 MB          | 120 MB          | 120 MB        | 120 MB          |

### Traffic totals, and where each byte class goes

| Byte class                           |          A |            B |             C |             D | Topology I destination        |         I rate | II rate |
| ------------------------------------ | ---------: | -----------: | ------------: | ------------: | ----------------------------- | -------------: | ------: |
| Container image layers (99%)         |     215 GB |     1,504 GB |      9,667 GB |     37,595 GB | ECR → **S3 gateway**          |      **$0.00** |  $0.048 |
| ECR manifest + auth (1%)             |       2 GB |        15 GB |         98 GB |        380 GB | `ecr.api`/`ecr.dkr` interface |          $0.01 |  $0.048 |
| Docker install at boot               |     104 GB |       521 GB |      2,344 GB |      6,510 GB | AL2023 repo → **S3 gateway**  |      **$0.00** |  $0.048 |
| Dependencies (npm/pip/maven)         |      69 GB |       521 GB |      3,515 GB |     13,563 GB | on-prem mirror, **inbound**   |    $0.02 (TGW) |  $0.048 |
| Git clone/fetch                      |      26 GB |       174 GB |      1,172 GB |      4,340 GB | on-prem GitLab, **inbound**   |    $0.02 (TGW) |  $0.048 |
| Artifact uploads                     |      13 GB |       108 GB |        781 GB |      2,713 GB | on-prem GitLab, **outbound**  | $0.04 (TGW+DX) |  $0.138 |
| AWS control plane (SSM/EC2/ASG/logs) |       8 GB |        22 GB |         99 GB |        275 GB | interface endpoints           |          $0.01 |  $0.048 |
| **Total**                            | **437 GB** | **2,865 GB** | **17,676 GB** | **65,375 GB** |                               |                |         |
| **Priced bytes (Topology I)**        | **118 GB** |   **840 GB** |  **5,665 GB** | **21,270 GB** |                               |                |         |
| **Priced bytes (Topology II)**       | **437 GB** | **2,865 GB** | **17,676 GB** | **65,375 GB** |                               |                |         |

**73% of CI bytes are free in Topology I and none of them are in Topology II.** That single row is
the reason the two topologies scale so differently. Image layers and `dnf` traffic — the two
largest classes, 73% of the total at Typical — cost nothing over the S3 gateway endpoint.

All four scenarios use module defaults except `max_instances`, raised in C and D because peak
concurrency exceeds the default ceiling of 10. `capacity_per_instance = 1` and
`max_use_count = 1` stay at their defaults throughout, so the baseline reflects what a caller
gets untuned.

**Topology I additionally assumes a Transit Gateway in the on-prem path.** If the runner VPC
attaches directly to a Direct Connect gateway or VGW with no TGW, drop the $36.50/month attachment
and the $0.02/GB processing — that removes $52.56/month at Typical (14.5%). Both variants are
shown in §8.

---

## 6. Monthly Cost Projection

### Topology I — isolated VPC, EU (Ireland)

| Scenario        | **Endpoints attributed in full** | **Endpoints shared** | Range (±25% workload)           |
| --------------- | -------------------------------: | -------------------: | ------------------------------- |
| **A — Minimal** |                        **~$317** |             **~$88** | $310 – $325 / $80 – $96         |
| **B — Typical** |                        **~$363** |            **~$134** | $330 – $400 / $105 – $165       |
| **C — Heavy**   |                        **~$633** |            **~$404** | $540 – $730 / $315 – $500       |
| **D — Peak**    |                      **~$1,438** |          **~$1,208** | $1,150 – $1,740 / $920 – $1,510 |

**"Attributed in full"** = the fleet has its own VPC, so all ten interface endpoints and the TGW
attachment are its cost. **"Shared"** = the fleet sits in an existing landing zone where
`ssm`, `ssmmessages`, `ec2messages`, `ec2`, `logs`, `monitoring`, `ecr.api`, `ecr.dkr` and the S3
gateway already exist for other workloads, and the TGW attachment is already paid. Only
`autoscaling` and `ec2-instance-connect` are genuinely new — 2 × 3 AZ = **$48.18/month**.

### Topology II — NAT egress, EU (Ireland)

| Scenario    | Monthly (USD) | Monthly (EUR) | Range (±25% workload) |
| ----------- | ------------: | ------------: | --------------------- |
| A — Minimal |         ~$164 |         ~€141 | $137 – $192           |
| B — Typical |         ~$319 |         ~€273 | $265 – $395           |
| C — Heavy   |       ~$1,253 |       ~€1,074 | $990 – $1,540         |
| D — Peak    |       ~$4,174 |       ~€3,577 | $3,300 – $5,150       |

### The comparison that decides the budget

| Scenario    | I — full attribution | I — shared endpoints |  II — NAT | Cheapest     |
| ----------- | -------------------: | -------------------: | --------: | ------------ |
| Minimal     |              $316.76 |           **$87.54** |   $164.12 | **I shared** |
| **Typical** |              $362.80 |          **$133.58** |   $319.20 | **I shared** |
| Heavy       |              $633.35 |          **$404.13** | $1,252.87 | **I shared** |
| Peak        |            $1,437.59 |        **$1,208.37** | $4,174.34 | **I shared** |

**The isolated topology is not the expensive choice — the _dedicated_ isolated topology is.**
Sharing an existing endpoint estate makes the fully-isolated, no-internet architecture the
cheapest of the three at every scenario, by 1.9× at Minimal and 3.5× at Peak. Security and cost
point the same way here, which is unusual and worth saying plainly.

Against NAT, full attribution crosses over between Minimal and Typical: **the isolated topology
becomes cheaper above ~3,835 GB/month of CI traffic** (§18), which at Typical byte volumes is
about **5,800 jobs/month**.

### Region comparison — Topology I, Typical, full attribution

|                                               | **eu-west-1 (Ireland)** | **eu-west-2 (London)** | us-east-1 (ref) |
| --------------------------------------------- | ----------------------: | ---------------------: | --------------: |
| Interface endpoints (10 × 3 AZ)               |                 $240.90 |                $240.90 |         $219.00 |
| TGW attachment + processing                   |                  $52.56 |                 $52.56 |          $52.56 |
| Worker compute (Spot)                         |                  $44.40 |                 $32.22 |          $32.78 |
| Manager compute + EBS                         |                  $15.19 |                 $15.58 |          $14.02 |
| Worker EBS                                    |                   $5.03 |                  $5.31 |           $4.58 |
| CloudWatch + logs + PrivateLink data + DX out |                   $4.72 |                  $4.76 |           $4.63 |
| **TOTAL**                                     |             **$362.80** |            **$351.33** |     **$327.57** |
| vs us-east-1                                  |              **+10.8%** |                  +7.3% |               — |

**London is 3.2% cheaper than Ireland in Topology I** — a wider gap than the <1% in Topology II,
because with the network bill fixed and identical, London's 27% cheaper x86 Spot no longer has a
pricier NAT to cancel it against. Still not a reason to choose on price: **decide on data
residency and latency to your on-prem GitLab**, which in an on-prem-connected architecture is a
harder constraint than in an internet-connected one.

---

## 7. Annual Cost Projection

### Topology I — EU (Ireland)

| Scenario        | Full attribution (USD) | Full (EUR) | Shared (USD) | Shared (EUR) | 3-year, full, 3%/yr |
| --------------- | ---------------------: | ---------: | -----------: | -----------: | ------------------: |
| **A — Minimal** |            **~$3,801** |    ~€3,257 |  **~$1,050** |        ~€900 |            ~$11,749 |
| **B — Typical** |            **~$4,354** |    ~€3,731 |  **~$1,603** |      ~€1,374 |            ~$13,458 |
| **C — Heavy**   |            **~$7,600** |    ~€6,513 |  **~$4,850** |      ~€4,156 |            ~$23,491 |
| **D — Peak**    |           **~$17,251** |   ~€14,782 | **~$14,500** |     ~€12,425 |            ~$53,320 |

### Topology II — EU (Ireland)

| Scenario    | Annual (USD) | Annual (EUR) | 3-year (3%/yr drift) |
| ----------- | -----------: | -----------: | -------------------: |
| A — Minimal |      ~$1,969 |      ~€1,687 |              ~$6,086 |
| B — Typical |      ~$3,830 |      ~€3,282 |             ~$11,840 |
| C — Heavy   |     ~$15,034 |     ~€12,883 |             ~$46,469 |
| D — Peak    |     ~$50,092 |     ~€42,924 |            ~$154,829 |

### Topology I — EU (London)

| Scenario | Full attribution (USD) | Full (GBP) | Shared (USD) | Shared (GBP) |
| -------- | ---------------------: | ---------: | -----------: | -----------: |
| Minimal  |                ~$3,657 |    ~£2,681 |        ~$906 |        ~£664 |
| Typical  |                ~$4,216 |    ~£3,091 |      ~$1,465 |      ~£1,074 |
| Heavy    |                ~$7,181 |    ~£5,263 |      ~$4,431 |      ~£3,248 |
| Peak     |               ~$16,048 |   ~£11,764 |     ~$13,297 |      ~£9,747 |

3-year figures assume 3%/year price drift and **flat workload** — deliberately conservative, since
AWS list prices for mature instance families and for VPC endpoints have historically been flat.
Real 3-year cost is dominated by workload growth, not price drift (§12), and in Topology I by
whether the endpoint estate stays shared.

---

## 8. Detailed Cost Breakdown

### Topology I — isolated, full attribution, 3 AZ, TGW in path, EU (Ireland)

| Cost component                                         |     Minimal |     Typical |       Heavy |          Peak |
| ------------------------------------------------------ | ----------: | ----------: | ----------: | ------------: |
| **VPC interface endpoints** (10 × 3 AZ × $8.03)        | **$240.90** | **$240.90** | **$240.90** |       $240.90 |
| Worker compute (Spot, blended $0.05315/h)              |      $17.49 |      $44.40 | **$190.02** |   **$601.38** |
| Transit Gateway — VPC attachment                       |      $36.50 |      $36.50 |      $36.50 |        $36.50 |
| Transit Gateway — data processing ($0.02/GB)           |       $2.17 |      $16.06 | **$109.37** |   **$412.30** |
| Manager compute (`t4g.small`, 730 h)                   |      $13.43 |      $13.43 |      $13.43 |        $13.43 |
| Worker EBS (gp3 50 GB, ephemeral)                      |       $1.98 |       $5.03 |      $21.55 |        $68.20 |
| Direct Connect data transfer out ($0.02/GB)            |       $0.26 |       $2.17 |      $15.62 |        $54.25 |
| CloudWatch alarms (6 std + 1 composite)                |       $1.10 |       $1.10 |       $1.10 |         $1.10 |
| CloudWatch custom metrics + heartbeat API              |       $1.04 |       $1.04 |       $1.04 |         $1.04 |
| Manager EBS (gp3 20 GB)                                |       $1.76 |       $1.76 |       $1.76 |         $1.76 |
| AMI snapshot storage (3 versions × 2 images)           |       $2.00 |       $2.00 |       $2.00 |         $2.00 |
| PrivateLink data processing ($0.01/GB)                 |       $0.10 |       $0.37 |       $1.97 |         $6.55 |
| CloudWatch Logs (manager only)                         |       $0.03 |       $0.04 |       $0.09 |         $0.18 |
| **S3 gateway endpoint** (images + `dnf`, 73% of bytes) |   **$0.00** |   **$0.00** |   **$0.00** |     **$0.00** |
| **TOTAL**                                              | **$318.76** | **$364.80** | **$635.35** | **$1,439.59** |

_(Totals include the $2.00 AMI-pipeline line, which the §6 headline figures exclude as a
build-system cost rather than a runtime one. Cited elsewhere as $316.76 / $362.80 / $633.35 /
$1,437.59 without it.)_

### Topology I — percentage view

| Component                   |   Minimal |   Typical |     Heavy |      Peak |
| --------------------------- | --------: | --------: | --------: | --------: |
| **VPC interface endpoints** | **75.6%** | **66.0%** | **37.9%** |     16.7% |
| Worker compute              |      5.5% |     12.2% | **29.9%** | **41.8%** |
| TGW attachment              |     11.5% |     10.0% |      5.7% |      2.5% |
| TGW data processing         |      0.7% |      4.4% | **17.2%** | **28.6%** |
| Manager compute             |      4.2% |      3.7% |      2.1% |      0.9% |
| Worker EBS                  |      0.6% |      1.4% |      3.4% |      4.7% |
| DX data transfer out        |      0.1% |      0.6% |      2.5% |      3.8% |
| CloudWatch (all)            |      0.7% |      0.6% |      0.4% |      0.2% |
| PrivateLink data processing |      0.0% |      0.1% |      0.3% |      0.5% |

**The driver rotates cleanly with scale.** At Minimal, 87% of the bill is fixed network
infrastructure serving 868 jobs. By Peak the endpoint estate is 17% and **compute plus on-prem
data movement is 70%**. Those are two different budget problems needing two different fixes
(§13): at small scale, attack the fixed estate; at large scale, attack compute efficiency and
artifact volume.

### Topology I — shared endpoints (marginal attribution)

Only `autoscaling` + `ec2-instance-connect` are new; the TGW attachment is already paid.

| Cost component                             |    Minimal |     Typical |       Heavy |          Peak |
| ------------------------------------------ | ---------: | ----------: | ----------: | ------------: |
| VPC interface endpoints (2 × 3 AZ)         |     $48.18 |      $48.18 |      $48.18 |        $48.18 |
| Worker compute (Spot)                      |     $17.49 |      $44.40 |     $190.02 |       $601.38 |
| TGW data processing                        |      $2.17 |      $16.06 |     $109.37 |       $412.30 |
| Manager compute                            |     $13.43 |      $13.43 |      $13.43 |        $13.43 |
| Worker EBS                                 |      $1.98 |       $5.03 |      $21.55 |        $68.20 |
| DX data transfer out                       |      $0.26 |       $2.17 |      $15.62 |        $54.25 |
| Manager EBS                                |      $1.76 |       $1.76 |       $1.76 |         $1.76 |
| CloudWatch (alarms + metrics + API + logs) |      $2.17 |       $2.18 |       $2.23 |         $2.32 |
| PrivateLink data processing                |      $0.10 |       $0.37 |       $1.97 |         $6.55 |
| **TOTAL**                                  | **$87.54** | **$133.58** | **$404.13** | **$1,208.37** |

### Topology I — no Transit Gateway (direct DX gateway / VGW attachment)

Drops the $36.50 attachment and the $0.02/GB processing; DX data-out remains.

| Scenario    | Full attribution | Shared endpoints |
| ----------- | ---------------: | ---------------: |
| Minimal     |          $278.09 |           $48.87 |
| **Typical** |      **$310.24** |       **$81.02** |
| Heavy       |          $487.48 |          $258.26 |
| Peak        |          $988.79 |          $759.57 |

**Removing a TGW from the path is worth $52.56/month at Typical (14.5%) and $448.80 at Peak
(31.2%).** If the runner VPC can attach directly to a Direct Connect gateway, that is the second
largest structural saving in Topology I after sharing the endpoints. It is a landing-zone
decision, not a module one.

### Topology II — NAT egress, 3 NAT gateways, EU (Ireland)

| Cost component                             |     Minimal |     Typical |         Heavy |          Peak |
| ------------------------------------------ | ----------: | ----------: | ------------: | ------------: |
| NAT Gateway — data processing ($0.048/GB)  |      $21.00 | **$137.51** |   **$848.45** | **$3,138.00** |
| NAT Gateway — hourly (3 × $35.04)          | **$105.12** |     $105.12 |       $105.12 |       $105.12 |
| Worker compute (Spot)                      |      $17.49 |      $44.40 |       $190.02 |       $601.38 |
| Internet data transfer out ($0.09/GB)      |       $1.17 |       $9.77 |        $70.31 |       $244.13 |
| Manager compute                            |      $13.43 |      $13.43 |        $13.43 |        $13.43 |
| Worker EBS                                 |       $1.98 |       $5.03 |        $21.55 |        $68.20 |
| Manager EBS                                |       $1.76 |       $1.76 |         $1.76 |         $1.76 |
| CloudWatch (alarms + metrics + API + logs) |       $2.17 |       $2.18 |         $2.23 |         $2.32 |
| **TOTAL**                                  | **$164.12** | **$319.20** | **$1,252.87** | **$4,174.34** |
| **NAT as % of total**                      |   **76.9%** |   **76.1%** |     **76.1%** |     **77.7%** |

### Topology II — EU (London)

| Cost component                    |     Minimal |     Typical |         Heavy |          Peak |
| --------------------------------- | ----------: | ----------: | ------------: | ------------: |
| NAT Gateway — data processing     |      $21.88 |     $143.24 |       $883.80 |     $3,268.75 |
| NAT Gateway — hourly (3 × $36.50) |     $109.50 |     $109.50 |       $109.50 |       $109.50 |
| Worker compute (Spot)             |      $12.69 |      $32.22 |       $137.92 |       $436.53 |
| Internet data transfer out        |       $1.17 |       $9.77 |        $70.31 |       $244.13 |
| Manager compute                   |      $13.72 |      $13.72 |        $13.72 |        $13.72 |
| Worker EBS                        |       $2.09 |       $5.31 |        $22.72 |        $71.92 |
| Manager EBS                       |       $1.86 |       $1.86 |         $1.86 |         $1.86 |
| CloudWatch (all)                  |       $2.20 |       $2.21 |         $2.26 |         $2.36 |
| **TOTAL**                         | **$165.11** | **$317.83** | **$1,242.09** | **$4,148.77** |

### Free-tier effect, shown separately and never netted in

AWS includes 100 GB/month of internet egress account-wide. In **Topology II** it reduces the
internet-egress line by up to $9.00/month if unused elsewhere — 2.8% of Ireland Typical, 0.2% of
Peak. In **Topology I it is worth $0**, because there is no internet egress. Excluded from every
figure above.

---

## 9. Cost Drivers

Top five, calculated, not assumed.

### Topology I — Ireland, Typical, full attribution ($362.80/month)

```
1. VPC interface endpoints      — 66.4%   ($240.90/mo)   FIXED, caller-owned
2. Worker compute (Spot)        — 12.2%   ($ 44.40/mo)   VARIABLE
3. TGW VPC attachment           — 10.1%   ($ 36.50/mo)   FIXED, caller-owned
4. TGW data processing          —  4.4%   ($ 16.06/mo)   VARIABLE
5. Manager compute + EBS        —  4.2%   ($ 15.19/mo)   FIXED, module-owned
```

**76.5% of the Typical bill is fixed network infrastructure the module does not create.**

### Topology I — Ireland, Peak, full attribution ($1,437.59/month)

```
1. Worker compute (Spot)        — 41.8%   ($601.38/mo)   VARIABLE
2. TGW data processing          — 28.7%   ($412.30/mo)   VARIABLE
3. VPC interface endpoints      — 16.8%   ($240.90/mo)   FIXED
4. Worker EBS                   —  4.7%   ($ 68.20/mo)   VARIABLE
5. DX data transfer out         —  3.8%   ($ 54.25/mo)   VARIABLE
```

**The ranking inverts entirely between Typical and Peak.** At Typical this is a fixed-cost
problem; at Peak it is a compute-and-artifact-volume problem. A budget built on one shape will be
wrong about the other.

### Topology I — Ireland, Typical, shared endpoints ($133.58/month)

```
1. VPC interface endpoints      — 36.1%   ($ 48.18/mo)
2. Worker compute (Spot)        — 33.2%   ($ 44.40/mo)
3. TGW data processing          — 12.0%   ($ 16.06/mo)
4. Manager compute              — 10.1%   ($ 13.43/mo)
5. Worker EBS                   —  3.8%   ($  5.03/mo)
```

This is the healthiest cost shape available from this module: no single line above 37%, and the
two largest are one fixed and one genuinely elastic.

### Topology II — Ireland, Typical ($319.20/month)

```
1. NAT Gateway data processing  — 43.1%   ($137.51/mo)
2. NAT Gateway hourly charge    — 32.9%   ($105.12/mo)
3. Worker compute (Spot)        — 13.9%   ($ 44.40/mo)
4. Manager compute + EBS        —  4.8%   ($ 15.19/mo)
5. Internet data transfer out   —  3.1%   ($  9.77/mo)
```

### The module defaults behind each driver

| Default                            | What it does                                                                   |                           Topology I cost at Typical |            Topology II cost at Typical |
| ---------------------------------- | ------------------------------------------------------------------------------ | ---------------------------------------------------: | -------------------------------------: |
| `max_use_count = 1`                | Fresh instance per job ⇒ zero Docker layer-cache reuse and a full boot per job | **$8.63/mo** (boot time only — image bytes are free) | **$77/mo** (cold image pull every job) |
| `worker_ami_id = ""`               | `dnf install docker` on every worker boot                                      |   **$4.81/mo** (boot latency only — traffic is free) |  **$30/mo** (120 MB over NAT per boot) |
| `autoscaling_policies` warm pool   | `idle_count = 1` weekday 08:00–18:59                                           |                                            $12.70/mo |                              $12.70/mo |
| Subnet AZ spread (caller's choice) | Drives the endpoint-AZ multiplier                                              |                                 **$80.30/mo per AZ** |                      $35.04/mo per NAT |

**The two defaults that cost the most money over NAT cost almost nothing in an isolated VPC.**
Both are deliberate isolation choices — a fresh instance per job is genuinely strong tenant
separation — and in the design-target topology they are close to free. That is the most
consequential single fact in this rewrite; it is developed in §14.

---

## 10. Fixed vs Variable Costs

### Topology I — Ireland, Typical, full attribution

|                                               |             Monthly | Behaviour                                  |
| --------------------------------------------- | ------------------: | ------------------------------------------ |
| **FIXED — independent of workload**           |                     |                                            |
| VPC interface endpoints (10 × 3 AZ)           |             $240.90 | Billed hourly whether or not a job runs    |
| Transit Gateway VPC attachment                |              $36.50 | Same                                       |
| Manager compute (`t4g.small`, 730 h)          |              $13.43 | ASG min=max=1, always on                   |
| Manager EBS (20 GB gp3)                       |               $1.76 | Persistent volume                          |
| CloudWatch alarms (6 + 1 composite)           |               $1.10 | Per-alarm-month regardless of state        |
| CloudWatch custom metrics + heartbeat API     |               $1.04 | 60 s systemd timer, always publishing      |
| **Fixed subtotal**                            | **$294.73 (81.2%)** | **$3,537/year floor**                      |
| **SEMI-FIXED — schedule-driven**              |                     |                                            |
| Warm idle pool (`idle_count = 1`, 238.7 h/mo) |       $12.70 (3.5%) | Weekday 08:00–18:59; buys pickup latency   |
| **VARIABLE — scales with jobs and bytes**     |                     |                                            |
| Worker compute beyond the warm pool           |              $31.68 | $0.05315/instance-hour, per-second billing |
| TGW data processing                           |              $16.06 | $0.02/GB on on-prem traffic                |
| Worker EBS                                    |               $5.03 | $0.088/GB-month prorated per second        |
| DX data transfer out                          |               $2.17 | $0.02/GB, outbound only                    |
| PrivateLink data processing                   |               $0.37 | $0.01/GB on AWS API traffic                |
| CloudWatch Logs                               |               $0.04 | $0.60/GB ingest+store; manager only        |
| S3 gateway traffic (2,025 GB)                 |           **$0.00** | **Free — 73% of all CI bytes**             |
| **Variable subtotal**                         |  **$55.35 (15.3%)** |                                            |

**Floor cost: $307.43/month (€263)** — what you pay for a month with zero CI activity.
**Marginal cost per job: $0.01275.**

### Topology I — shared endpoints

Fixed subtotal drops to **$102.01**, floor to **$114.71/month**, variable unchanged at $55.35.

### Topology II — Ireland, Typical

|                                                        |           Monthly | Share |
| ------------------------------------------------------ | ----------------: | ----: |
| Fixed (3 × NAT hourly, manager, alarms, metrics)       |           $122.45 | 38.4% |
| Semi-fixed (warm idle pool)                            |            $12.70 |  4.0% |
| Variable (NAT data, egress, worker compute, EBS, logs) |           $184.05 | 57.6% |
| **Floor cost**                                         | **$135.15/month** |       |
| **Marginal cost per job**                              |       **$0.0424** |       |

### Cost per job — the number to quote to a finance team

| Scenario                        | I — full attribution |  I — shared | II — NAT | GitLab SaaS |
| ------------------------------- | -------------------: | ----------: | -------: | ----------: |
| Minimal (868 jobs, 4 min)       |              $0.3649 | **$0.1009** |  $0.1891 |     $0.0400 |
| **Typical (4,340 jobs, 6 min)** |              $0.0836 | **$0.0308** |  $0.0736 |     $0.0600 |
| Heavy (19,530 jobs, 8 min)      |              $0.0324 | **$0.0207** |  $0.0642 |     $0.0800 |
| Peak (54,250 jobs, 10 min)      |              $0.0265 | **$0.0223** |  $0.0769 |     $0.1000 |

**Marginal cost per job in Topology I is $0.01275 — a third of Topology II's $0.0424.** The
fully-loaded numbers above look worse at Minimal only because the fixed estate is spread over few
jobs. This is why the fixed/variable split matters more than the total: **in an isolated VPC,
growth is cheap and existence is expensive.** Over NAT, existence is cheap and growth is
expensive.

---

## 11. Scaling Analysis

### Runner capacity: required vs provisioned

| Scenario | Ceiling (`max_instances`) | Avg concurrent | Peak concurrency |   Ceiling headroom |
| -------- | ------------------------: | -------------: | ---------------: | -----------------: |
| Minimal  |                        10 |           0.45 |                3 | 70% unused at peak |
| Typical  |                        10 |           1.14 |                8 | 20% unused at peak |
| Heavy    |                        40 |           4.90 |               25 | 38% unused at peak |
| Peak     |                       100 |          15.50 |               60 | 40% unused at peak |

Because `min_size = 0` and `desired_capacity = 0`, **unused ceiling costs nothing.**
`max_instances` is a spend guardrail, not a reservation — this remains the single best thing about
the module's cost design, and the BYO refactor did not touch it. Raising it has zero cost impact
until jobs actually queue.

### Idle waste — where billed worker-hours actually go

Identical in both topologies; worker defaults are unchanged.

| Scenario | Billed worker-hours | Running a job | Booting | Warm idle pool | **Useful work** |
| -------- | ------------------: | ------------: | ------: | -------------: | --------------: |
| Minimal  |               329 h |          58 h |    33 h |          239 h |         **18%** |
| Typical  |               835 h |         434 h |   163 h |          239 h |         **52%** |
| Heavy    |             3,575 h |       2,604 h |   732 h |          239 h |         **73%** |
| Peak     |            11,315 h |       9,042 h | 2,034 h |          239 h |         **80%** |

**At Minimal, 82% of worker compute is not running a job.** The warm idle pool alone (238.7 h for
`idle_count = 1` on weekday business hours) is four times the busy time.

**Provisioning overhead is a permanent 18–36% tax under `max_use_count = 1`.** Each launch costs
~2.24 minutes of billed instance time before a job starts: ~15 s pending, ~40 s AL2023 boot,
~60 s `dnf install docker`, then `worker_ready_command` polls `docker info`, plus ~20 s teardown.
A pre-baked worker AMI cuts this to ~1.0 minute.

> **A note on `idle_count` that is easy to get wrong.** With `max_use_count = 1`, a warm idle
> instance is consumed by one job and then discarded, and the autoscaler boots a replacement. The
> warm pool therefore **moves boot time off the job's critical path but does not reduce billed
> instance-hours** — it slightly increases them. `idle_count` buys **latency, not cost.**

### How cost responds to each growth axis

| Axis                          | Topology I                                                                                  | Topology II                                             | Why the difference                                                                                                   |
| ----------------------------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| **Jobs per month**            | **Roughly linear in the variable half, strongly sub-linear overall.** 10× jobs = 2.3× total | **Strongly super-linear.** 10× jobs = 6.1× total        | Every job re-pays a full image pull over NAT. Over the S3 gateway it re-pays nothing                                 |
| **Average job duration**      | **Weak** — 2× duration = +7.1%                                                              | **Weak** — 2× = +8.0%                                   | Longer jobs amortise fixed boot cost and move no extra bytes. **Long jobs are cheap; many short jobs are expensive** |
| **Peak concurrency**          | **Zero cost effect**                                                                        | **Zero cost effect**                                    | Concurrency changes only the ceiling, and unused ceiling is free. Affects queue latency, not spend                   |
| **Container image size**      | **Almost none** — 4× image = **+0.1%**                                                      | **Strong, linear** — 4× image = +68.5%                  | Layer bytes ride the free S3 gateway endpoint. Only the ~1% manifest/auth share is metered                           |
| **Artifact size**             | **Moderate** — 8× artifacts = +8.4%                                                         | **Strongest per-GB** — 8× = +32.8%                      | $0.04/GB (TGW+DX) versus $0.138/GB (NAT+egress). Still the priciest byte class in both                               |
| **AZ spread of your subnets** | **Strong and fixed** — each AZ is **+$80.30/mo**                                            | Each NAT is +$35.04/mo                                  | Interface endpoints bill per endpoint **per AZ**. Ten endpoints make AZ count expensive                              |
| **Number of runner fleets**   | **+$30.03/mo each in a shared VPC; +$307/mo each with its own**                             | +$30.02/mo each, plus a NAT if it needs its own subnets | The endpoint estate is the thing worth sharing                                                                       |

**Image size going from a 68.5% sensitivity to a 0.1% sensitivity is the headline of this
rewrite.** Teams that were told to slim their CI images to save money should be told that in an
isolated VPC that work buys **job speed only** — which may still be worth doing, but not from a
FinOps budget.

---

## 12. Sensitivity Analysis

One variable changed at a time.

### Topology I — baseline Ireland, Typical, full attribution, $362.80/month

| Change                                      | New monthly |                                     Δ |
| ------------------------------------------- | ----------: | ------------------------------------: |
| **Workload × 10** (43,400 jobs)             |        $848 |                           **+133.7%** |
| **Workload × 5** (21,700 jobs)              |        $578 |                            **+59.4%** |
| Endpoint AZ spread 3 → 4                    |        $443 |                                +22.1% |
| `idle_count` 1 → 4, 24×7                    |        $521 |                                +43.7% |
| **Workload × 2** (8,680 jobs)               |        $417 |                            **+14.9%** |
| Spot → On-Demand (`spot_enabled = false`)   |        $403 |                                +11.1% |
| Artifacts 25 MB → 200 MB                    |        $393 |                                 +8.4% |
| Average job 6 → 12 min                      |        $388 |                                 +7.1% |
| `worker_disk_iops` 3000 → 6000              |        $382 |                                 +5.2% |
| `worker_disk_gb` 50 → 200                   |        $378 |                                 +4.2% |
| `assign_public_ips = true`                  |        $371 | +2.2% (**and buys nothing — no IGW**) |
| Add an `sts` endpoint (jobs assuming roles) |        $387 |                                 +6.6% |
| `detailed_monitoring = true`                |        $367 |                                 +1.2% |
| **Image 350 MB → 1.4 GB**                   |    **$363** |                             **+0.1%** |
| Average job 6 → 3 min                       |        $350 |                                 −3.5% |
| arm64 / Graviton workers                    |        $350 |                                 −3.6% |
| Drop the warm idle pool                     |        $349 |                                 −3.9% |
| **Endpoint AZ spread 3 → 2**                |    **$283** |                            **−22.1%** |
| Remove the TGW from the path                |        $310 |                                −14.5% |
| **Share the landing zone's endpoints**      |    **$134** |                            **−63.2%** |

### Topology II — baseline Ireland, Typical, $319.20/month

| Change                         | New monthly |           Δ |
| ------------------------------ | ----------: | ----------: |
| **Workload × 10**              |      $1,962 | **+514.8%** |
| **Workload × 5**               |      $1,050 | **+228.8%** |
| Image 350 MB → 1.4 GB          |        $538 |      +68.5% |
| **Workload × 2**               |        $502 |  **+57.2%** |
| `idle_count` 1 → 4, 24×7       |        $449 |      +40.6% |
| Artifacts 25 MB → 200 MB       |        $424 |      +32.8% |
| Image 350 MB → 700 MB          |        $392 |      +22.8% |
| Dependencies 120 MB → 360 MB   |        $369 |      +15.7% |
| Spot → On-Demand               |        $360 |      +12.7% |
| Average job 6 → 12 min         |        $345 |       +8.0% |
| `worker_disk_iops` 3000 → 6000 |        $338 |       +5.9% |
| `worker_disk_gb` 50 → 200      |        $334 |       +4.7% |
| `assign_public_ips = true`     |        $327 |       +2.5% |
| `detailed_monitoring = true`   |        $323 |       +1.2% |

### What variable has the greatest effect on monthly cost?

**Topology I: the endpoint attribution decision — a 63% swing from one choice with no code
change and no security consequence.** Nothing else in this document comes close for effort spent.
After that, **AZ spread** (±22% per AZ) and then **workload** (+134% for 10×).

**Topology II: number of jobs per month, decisively.** Each 1× of workload growth adds ~51% of the
baseline, because every job independently re-pays the full network cost of building its
environment from scratch.

Three knobs worth flagging because they look free and are not:

- **Adding an AZ to the subnet list.** `worker_subnet_ids` is a plain list and nothing in the
  module hints that a fourth AZ costs **$80.30/month** in endpoint charges. The module cannot know
  — it does not create the endpoints — but the caller should. In Topology I, subnet AZ spread is a
  cost decision disguised as an availability decision.
- **`worker_disk_iops` above 3,000** leaves the gp3 free baseline and bills $0.0055/IOPS-month per
  attached volume-month. Doubling to 6,000 adds ~5.2% — more than switching the whole fleet to
  Graviton saves.
- **The manager is a T4g burstable with no `credit_specification` block**, so it defaults to
  **unlimited** mode. A manager driving a large fleet at sustained high CPU can bill surplus
  credits at $0.04/vCPU-hour — **up to ~$47/month, roughly 3.5× the instance's own cost.** Not
  included in any figure above; see §19.

---

## 13. Optimization Opportunities

Savings computed against each scenario's own **Ireland Topology I, full attribution** baseline
unless stated. Topology II figures given where they differ materially.

### PREREQUISITE — not an optimization, and not optional

| #   | Item                                                                                                               | Why                                                                                                                                                                                     |                   Cost | Effort               |
| --- | ------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------: | -------------------- |
| P1  | **Baked manager AMI** (`manager_ami_id`) with `gitlab-runner` and `fleeting-plugin-aws` pre-installed              | The default bootstrap `curl`s `packages.gitlab.com` and runs `gitlab-runner fleeting install`, which pulls from GitLab.com. Neither is reachable with no internet route — they **hang** |    **+$1/mo** snapshot | 16 h initial, 1 h/mo |
| P2  | **`ecr.api` + `ecr.dkr` interface endpoints**                                                                      | Jobs cannot pull an image without them and `network_contract` does not name them                                                                                                        | **+$48.18/mo** at 3 AZ | 2 h                  |
| P3  | **S3 gateway endpoint** on every worker subnet's route table                                                       | ECR layer bytes and AL2023 `dnf` traffic. **Free**, and the reason 73% of CI bytes cost nothing                                                                                         |                 **$0** | 1 h                  |
| P4  | **Pin `gitlab_runner_version`, `fleeting_plugin_version`, `fleeting_plugin_sha256`, `package_repo_script_sha256`** | Baking an AMI without pinning just moves an unverified fetch into the image pipeline                                                                                                    |                     $0 | 2 h                  |

**P3 is the highest-value $0 line in this document.** It is what turns a $1,253/month Heavy
workload over NAT into a $633/month Heavy workload in an isolated VPC. Verify it is on the
**worker** subnets' route tables, not just the manager's.

### QUICK WIN — low effort, low risk

| #   | Optimization                                    | Change                                                                                                      |             Typical |               Heavy | Effort         | Risk   | Security impact    |
| --- | ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------- | ------------------: | ------------------: | -------------- | ------ | ------------------ |
| Q1  | **Share the landing zone's endpoint estate** ⭐ | Deploy into an existing isolated VPC rather than a CI-dedicated one                                         | **$229/mo (63.2%)** | **$229/mo (36.2%)** | organizational | Low    | **None**           |
| Q2  | **Reduce endpoint AZ spread 3 → 2**             | Two entries in `worker_subnet_ids`, endpoints in two AZs                                                    |  **$80/mo (22.1%)** |  **$80/mo (12.7%)** | 1 h            | Medium | None — but see §14 |
| Q3  | **arm64 / Graviton workers** ⭐                 | `cpu_architecture = "arm64"` + `worker_instance_types = ["m7g.large","m6g.large","c7g.large","m7g.xlarge"]` |       $13/mo (3.6%) |   **$56/mo (8.9%)** | 2–5 days       | Medium | None               |
| Q4  | **Drop the warm idle pool**                     | `autoscaling_policies = [{ idle_count = 0, idle_time = "10m0s", periods = ["* * * * *"] }]`                 |       $14/mo (3.9%) |       $14/mo (2.2%) | 15 min         | Low    | None               |
| Q5  | **Right-size the worker disk**                  | `worker_disk_gb = 30`                                                                                       |        $2/mo (0.6%) |        $9/mo (1.4%) | 15 min         | Medium | None               |
| Q6  | **Baked worker AMI**                            | `worker_ami_id`                                                                                             |        $5/mo (1.3%) |   **$22/mo (3.4%)** | 1–2 days       | Low    | **Improves**       |

**Q1 is the recommendation, and it is not an engineering task.** The endpoint estate is 66% of
the Typical bill and 38% of Heavy, and in most banking landing zones `ssm`, `ssmmessages`,
`ec2messages`, `ec2`, `logs`, `monitoring` and the S3 gateway **already exist** for other
workloads. Provisioning a CI-dedicated VPC duplicates all of them. The conversation to have is
with whoever owns the landing zone, not with Terraform.

> **Q3 — the Ireland-specific recommendation.** ⭐ Graviton is **30% cheaper compute** in Ireland
> ($0.05315 → $0.03740/h) _and_ moves the fleet from two pools with >20% Spot interruption rates
> to three pools all under 5%. In Topology I its share of the total is **larger** than it was over
> NAT (worker compute is 12–42% here versus 14–15% there), so it is worth $56/month at Heavy and
> $178/month at Peak. The cost is porting CI images to arm64 (multi-arch builds), which is why it
> is days rather than minutes.

> **Q6 payback note — different from the previous revision.** Over NAT, baking the worker AMI
> saved $30/month at Typical because it removed 120 MB of metered traffic per boot. In an isolated
> VPC that traffic is **free** (regional S3 via the gateway endpoint), so Q6 now saves only
> **~1.25 minutes of billed boot time per launch**: $4.81/month at Typical, $21.63 at Heavy.
> **Take it for job latency and for removing a root-level `dnf` from every boot, not for the cloud
> saving.** Note the _manager_ AMI is a different matter entirely — see P1.

**Q4 caveat:** removing the warm pool adds ~2 minutes of cold-start latency to the first job of
each burst, to save 3.9%. Not worth it above Typical scale — buy the latency.

### MEDIUM — moderate architectural effort

| #   | Optimization                                          | Change                                               |            Typical |               Heavy |                Peak | Effort                  | Risk                 |
| --- | ----------------------------------------------------- | ---------------------------------------------------- | -----------------: | ------------------: | ------------------: | ----------------------- | -------------------- |
| M1  | **Remove the Transit Gateway from the on-prem path**  | Attach the runner VPC directly to a DX gateway / VGW | **$53/mo (14.5%)** | **$146/mo (23.0%)** | **$449/mo (31.2%)** | 1–2 weeks, network team | Medium               |
| M2  | **Pack jobs onto instances**                          | `capacity_per_instance = 2` + `.xlarge` types        |      ~$9/mo (2.4%) |      ~$38/mo (6.0%) |     ~$122/mo (8.5%) | 2–3 days                | Medium               |
| M3  | **Reuse instances across jobs**                       | `max_use_count = 10`                                 |       $9/mo (2.4%) |       $39/mo (6.2%) |      $108/mo (7.5%) | 1 day + policy review   | **Medium — see §14** |
| M4  | **Internal package/dependency mirror inside the VPC** | Nexus/Artifactory on the AWS side instead of on-prem |      $10/mo (2.9%) |      $70/mo (11.1%) |     $271/mo (18.9%) | 1–2 weeks               | Low                  |
| M5  | **Shrink artifacts**                                  | `.gitlab-ci.yml` hygiene, expire_in, exclude paths   |        up to $4/mo |        up to $31/mo |       up to $109/mo | ongoing                 | Low                  |

**M1 is the largest architectural saving in Topology I after Q1**, and it grows with scale
because the TGW charges $0.02/GB on every byte crossing it in addition to the DX charge. Whether
it is available at all depends on the landing zone's routing model — a bank running a
hub-and-spoke TGW topology for inspection reasons cannot simply bypass it, and should not.

**M3 is no longer worth the security trade.** Over NAT it saved 24–37%; here it saves 2.4–7.5%,
because the image bytes it was avoiding are already free. See §14 — the economics that used to
justify it are gone.

**M4 note.** Moving the dependency mirror inside the VPC converts $0.02/GB of TGW traffic into
$0 (same-AZ) or $0.01/GB (cross-AZ). At Peak the dependency line is 13,563 GB — $271/month of TGW
processing that a same-AZ mirror removes entirely. It also removes a dependency on the on-prem
link being up for CI to work, which is a reliability argument as much as a cost one.

### STRATEGIC — requires architecture change

| #   | Optimization                                            |                                    Typical |               Heavy |                Peak | Effort    | Risk                     |
| --- | ------------------------------------------------------- | -----------------------------------------: | ------------------: | ------------------: | --------- | ------------------------ |
| S1  | **One shared runner VPC for every fleet in the org** ⭐ |        **$229/mo per extra fleet avoided** |                same |                same | 2–4 weeks | Low                      |
| S2  | **Q1 + Q2 + Q3 + M1 combined**                          |                        **$274/mo (75.7%)** | **$411/mo (64.9%)** | **$836/mo (58.1%)** | 4–6 weeks | Medium                   |
| S3  | **S3 distributed cache** via `extra_runner_config_toml` |                          workload-specific |   workload-specific |   workload-specific | 3–5 days  | Low                      |
| S4  | **Evaluate the Fargate sibling module**                 | **$48/mo of endpoints + the AMI pipeline** |                same |                same | 2–4 weeks | Medium — capability loss |

**S1 is the strategic recommendation.** The economics of Topology I are dominated by a fixed
estate, so the correct organizational move is to pay for that estate **once**:

|                           | Own VPC + endpoints | Shared runner VPC |
| ------------------------- | ------------------: | ----------------: |
| First fleet               |    $307.43/mo floor |  $307.43/mo floor |
| **Each additional fleet** |     **+$307.43/mo** |    **+$30.03/mo** |
| Five fleets               |           $1,537/mo |       **$427/mo** |

**A tenth fleet costs 10× less in a shared VPC than in its own.** For an organization running
separate fleets per business line — the scenario this module was built for — this is the single
largest number in the document.

**S4 — the cross-module comparison, which the BYO refactor makes newly relevant.** The sibling
`gitlab-runner-fargate` module needs **no ASG and no SSH to workers**, so it does not need the
`autoscaling` or `ec2-instance-connect` endpoints (**−$48.18/month at 3 AZ**) and has **no AMI
pipeline at all** (−16 h initial, −1 h/month). In Topology I, where fixed network cost dominates
and the mandatory AMI pipeline is pure overhead, that is a materially better cost shape at small
scale. It cannot run `image:`, `services:` or Docker-in-Docker — so this is a **capability
decision with a cost consequence**, not a cost decision. See `ARCHITECTURE.md` §12 for the
decision flowchart.

**S3 (distributed cache)** value depends entirely on whether your jobs have cacheable dependency
trees. An S3 cache reaches the same **free** gateway endpoint, so in Topology I it converts
$0.02/GB of TGW dependency traffic into $0. On dependency-heavy pipelines this approaches the M4
figures. Not modelled as a headline saving because it is too workload-dependent to quantify
honestly.

### Optimization summary — Ireland, Topology I

| Path                                  |         Typical |           Heavy |              Peak | Security impact   |
| ------------------------------------- | --------------: | --------------: | ----------------: | ----------------- |
| Do nothing (own VPC, 3 AZ, TGW)       |            $363 |            $633 |            $1,438 | baseline          |
| Quick wins Q3+Q4+Q5+Q6                |      $329 (−9%) |     $533 (−16%) |     $1,158 (−19%) | **Improves** (Q6) |
| **Q1 alone — share the endpoints** ⭐ | **$134 (−63%)** | **$404 (−36%)** | **$1,208 (−16%)** | **None**          |
| **S2 — Q1+Q2+Q3+M1**                  |  **$88 (−76%)** | **$222 (−65%)** |   **$602 (−58%)** | **See §14 on Q2** |

---

## 14. Security vs Cost Considerations

The module's defaults are well-chosen. Several cheap-looking changes undo deliberate engineering,
and the BYO refactor **changed which trade-offs are even worth considering**.

### The trade-off that disappeared: `max_use_count`

Over NAT this was the largest single tuning saving available (24–37%) and the document had to
argue carefully against it. In Topology I it saves **2.4% at Typical, 7.5% at Peak**.

| `max_use_count` | Saving (Topology I, Heavy) | Saving (Topology II, Heavy) | Isolation                                                     |
| --------------- | -------------------------: | --------------------------: | ------------------------------------------------------------- |
| **1 (default)** |                          — |                           — | **One job per host. Strongest.**                              |
| 5               |             ~$35/mo (5.5%) |            ~$387/mo (30.9%) | Sequential sharing; a compromised host affects ≤5 later jobs  |
| 10              |             ~$39/mo (6.2%) |            ~$436/mo (34.8%) | Sequential sharing; a compromised host affects ≤10 later jobs |

`max_use_count = 1` means one CI job per EC2 instance, ever. A job that escapes its container onto
the host cannot observe or tamper with any other job, because there is no other job on that host
and the instance is destroyed afterwards. `max_use_count = 10` means up to ten jobs share a host,
sequentially, with a shared Docker daemon, shared layer cache and shared kernel.

**Recommendation: leave it at 1.** Trading the fleet's strongest isolation boundary for 2.4% of a
$363 bill is not a trade any security review should accept. If you were previously considering it
on the strength of the NAT-era numbers, the case is gone. `NOT RECOMMENDED FOR PRODUCTION` on any
fleet running fork or merge-request pipelines from untrusted contributors, and **especially** with
`docker_privileged = true`, where one escape compromises every following job on that host.

### The new trade-off: endpoint AZ spread (Q2)

Reducing interface endpoints from three AZs to two saves **$80.30/month (22.1%)**. This is a real
availability reduction, not a free win: **an instance in an AZ with no endpoint cannot reach the
AWS API at all, and with no public path it hangs rather than failing over.**

| AZ spread          | Monthly endpoint cost | If one AZ fails                                    |
| ------------------ | --------------------: | -------------------------------------------------- |
| 3 AZ (recommended) |               $240.90 | Fleet continues in the other two                   |
| 2 AZ               |               $160.60 | Fleet continues in one; halved capacity            |
| **1 AZ**           |            **$80.30** | **All CI stops.** `NOT RECOMMENDED FOR PRODUCTION` |

**2 AZ is defensible for a CI fleet** — CI is not a customer-facing service, and a rebuild is a
retry rather than an outage. Keep `worker_subnet_ids` aligned with the AZs that actually have
endpoints; a subnet in a third AZ with no endpoints there is worse than not having the subnet,
because jobs will land in it and hang. **1 AZ is not defensible for a shared fleet** — one AZ
event stops every pipeline in the business line.

### Changes that are cheaper and should not be made

| Change                                                     | Saves (Ireland, Typical, Topology I) | Why NOT                                                                                                                                                                                                                                                                                                                                                             |
| ---------------------------------------------------------- | -----------------------------------: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`assign_public_ips = true`**                             |        **−$7.83 — it _costs_ money** | In Topology I there is no internet gateway, so a public IP routes nowhere: you pay $0.005/h per address for nothing. Over NAT the flag at least removed a gateway; here it is **pure cost with zero benefit and a real risk** — it puts a routable address on a host running untrusted CI code the moment someone attaches an IGW. `NOT RECOMMENDED FOR PRODUCTION` |
| **Dropping interface endpoints to save the hourly charge** |                        up to $240.90 | The fleet **hangs**, and nothing names the missing endpoint. This is exactly the failure mode `ARCHITECTURE.md` §3.6 and `output.network_contract` exist to prevent. Not an optimization — an outage with a delayed diagnosis                                                                                                                                       |
| **`verify_manager_to_worker_ssh_rule = false`**            |                               **$0** | Saves nothing. `DescribeSecurityGroupRules` is a free API call. It removes the module's **only** enforced network control — the plan-time check that the manager can actually reach workers on 22. There is no cost argument for this at all                                                                                                                        |
| **`docker_privileged = true`** for faster dind             |               Marginal job-time only | `NOT RECOMMENDED FOR PRODUCTION` as a cost measure. Grants effective host root to job containers and saves no measurable money. If you need it for dind, that is a capability decision                                                                                                                                                                              |
| **`log_retention_days = 0`** to stop log shipping          |                                $0.04 | Disables manager log shipping entirely and makes the `bootstrap_failed` alarm undiagnosable. In Topology I this is worse than over NAT: a hung bootstrap waiting on a missing endpoint is **only** visible in that log. Trading incident-response capability for four cents is indefensible                                                                         |
| **`create_alarms = false`**                                |                                $1.10 | Removes the `orphaned_workers` composite alarm, which exists to catch scale-in-protected workers billing forever with no manager to release them. **Deleting the control that prevents an unbounded bill, to save $1.10.** Strictly negative expected value                                                                                                         |
| **`manager_self_heal = false`**                            |                    $0.10 (one alarm) | A manager failure then pauses all CI until a human notices. Saves one alarm; costs an outage                                                                                                                                                                                                                                                                        |
| **Removing `worker_max_lifetime_seconds`**                 |                                   $0 | Saves nothing and removes a backstop. Note the module's own comment is honest that this **cannot** reclaim orphaned workers — ASG-initiated replacement respects scale-in protection — so keep the `orphaned_workers` alarm as the real control                                                                                                                     |
| **Moving the fleet to us-east-1 to save ~11%**             |                                 ~$35 | For an EU organization this is a **data-residency decision, not a cost decision** — and in an on-prem-connected architecture it is also a _latency_ decision, since every `git clone` and artifact upload crosses the Atlantic. ~$420/year does not buy that. The honest comparison is against London                                                               |

### Optimizations that improve security and cost at once

Take these without debate:

- **S3 gateway endpoint (P3)** — mandatory, free, and keeps 73% of CI bytes off any metered or
  public path.
- **Baked AMIs (P1, Q6)** — removes an unverified `curl | bash` and a root-level `dnf` from every
  boot. In Topology I the manager AMI is mandatory anyway; take the worker one for the same
  reason.
- **`package_repo_script_sha256` + pinned versions (P4)** — no cost impact, closes the module's
  own documented `curl | bash` gap. Free.
- **`ecr.api`/`ecr.dkr` + ECR (P2)** — pins image provenance to a registry you control, enables
  scanning, removes Docker Hub rate-limit exposure, and keeps every image byte inside the EU and
  off the metered path.
- **Graviton in Ireland (Q3)** — 30% cheaper compute _and_ a move from >20% to <5% Spot
  interruption bands. Fewer interruptions means fewer retried jobs: a reliability and a cost win
  simultaneously.
- **Sharing the landing zone's endpoints (Q1)** — 63% cheaper, and it _centralises_ endpoint
  policy and monitoring rather than scattering it across per-team VPCs.

---

## 15. On-Demand vs Commitment

**Commitment pricing is nearly worthless for this architecture, and the BYO refactor made it
worse.**

Reserved Instances and Savings Plans do not apply to Spot capacity. With `spot_enabled = true` and
`on_demand_percentage_above_base = 0` the entire worker fleet is Spot. Only the manager is
commitment-eligible — and in Topology I the manager is 3.7% of the bill.

| Component (Ireland, Topology I, Typical) |      On-Demand | 1-yr no-upfront Compute SP (~28%) |         3-yr all-upfront (~50%) | Eligible? |
| ---------------------------------------- | -------------: | --------------------------------: | ------------------------------: | --------- |
| Manager (`t4g.small`, 730 h)             |      $13.43/mo |                         ~$9.67/mo |                       ~$6.72/mo | **Yes**   |
| Worker fleet (Spot)                      |      $44.40/mo |                      not eligible |                    not eligible | **No**    |
| **VPC interface endpoints**              | **$240.90/mo** |   **no commitment option exists** | **no commitment option exists** | **No**    |
| Transit Gateway                          |      $52.56/mo |              no commitment option |            no commitment option | **No**    |
| EBS, CloudWatch, DX data                 |      $11.62/mo |              no commitment option |            no commitment option | No        |

```
Maximum achievable commitment saving (Ireland, Topology I, Typical) = $3.76/month = 1.0% of total
81% of the bill has no commitment mechanism at any price
```

**Recommendation: do not buy a commitment for this module.** $3.76/month does not justify a
12-month lock on a single instance you may resize, re-architect or move to Graviton. If your
organization already holds a Compute Savings Plan with unused commitment, the manager absorbs into
it automatically at no decision cost — the only case worth anything.

**The Direct Connect port is the one commitment-shaped decision that matters**, and it is not this
module's. A 1 Gbps dedicated port is $219/month ($2,628/year) and a 10 Gbps port $1,642/month.
Neither should be attributed to CI — but **if CI is the reason a circuit is being upgraded, that
single line dwarfs everything else in this document.** At Peak the fleet moves 21 TB/month, of
which 2.7 TB is outbound; that is comfortably inside a 1 Gbps port, so CI alone should never drive
a DX upgrade. Check this before accepting a network team's cost allocation.

### The Direct Connect vs Site-to-Site VPN break-even

If the on-prem path does not exist yet and CI is a driver for building it:

```
Site-to-Site VPN:   $36.50/month  + $0.09/GB outbound (internet DTO rates)
Direct Connect:     $219/month    + $0.02/GB outbound
Break-even          = ($219 − $36.50) ÷ ($0.09 − $0.02) = 2,607 GB/month of AWS→on-prem traffic
```

| Scenario | Outbound to on-prem | Cheaper link for CI alone                        |
| -------- | ------------------: | ------------------------------------------------ |
| Minimal  |               13 GB | **VPN** — by $181/mo                             |
| Typical  |              108 GB | **VPN** — by $175/mo                             |
| Heavy    |              781 GB | **VPN** — by $128/mo                             |
| Peak     |            2,713 GB | **Direct Connect** — by $5/mo, essentially a tie |

**For CI traffic alone, a VPN is cheaper at every realistic scale.** Direct Connect wins on
latency, jitter and bandwidth predictability — which matter for `git clone` wall time — not on
price. If a DX already exists, use it; do not build one for CI.

### Spot vs On-Demand — where the real risk/price trade lives

Ireland, Topology I, Typical:

| Setting                       | Monthly | vs baseline | Reliability                                                              |
| ----------------------------- | ------: | ----------: | ------------------------------------------------------------------------ |
| Spot 100% (default)           |    $363 |           — | Interruptions happen; **two of the four default Ireland pools are >20%** |
| Spot 100% on **Graviton**     |    $350 |       −3.6% | **All three pools <5%.** Best risk/price point in Ireland                |
| `on_demand_base_capacity = 2` |   ~$392 |        ~+8% | On small fleets this is effectively an off switch for Spot               |
| `spot_enabled = false`        |    $403 |      +11.1% | No interruptions                                                         |

`on_demand_base_capacity = 2` barely differs from disabling Spot entirely: at Typical the fleet
rarely exceeds two concurrent instances, so an On-Demand base of 2 converts almost the whole fleet
to On-Demand. **On small fleets it is not a partial hedge — it is an off switch.** Reach for it
only once average concurrency is comfortably above the base.

Given the module's Spot-resilience design — four families across two generations,
`price-capacity-optimized`, capacity rebalance, and one job per instance so a reclaim costs
exactly one retry — **staying on Spot is correct.** Mark jobs `interruptible: true` and set
`retry` in `.gitlab-ci.yml`. **In Ireland specifically, pair Spot with Graviton** to get both the
price and the interruption profile right.

### Build vs buy — and why it is mostly moot in this topology

GitLab.com SaaS runners are **$10 per 1,000 compute minutes** ($0.01/minute for
`saas-linux-small-amd64`, 2 vCPU / 8 GiB — the same shape as `m6i.large`), verified at
about.gitlab.com/pricing on 2026-08-26. Self-hosted runners consume zero compute minutes and have
no build-time limit.

| Scenario | Job-min/mo | GitLab SaaS | I — full attr | I — shared | II — NAT | Cheapest                          |
| -------- | ---------: | ----------: | ------------: | ---------: | -------: | --------------------------------- |
| Minimal  |      3,472 |     **$35** |          $317 |        $88 |     $164 | **SaaS**                          |
| Typical  |     26,040 |        $260 |          $363 |   **$134** |     $319 | **Self-hosted, shared endpoints** |
| Heavy    |    156,240 |      $1,562 |          $633 |   **$404** |   $1,253 | **Self-hosted**                   |
| Peak     |    542,500 |      $5,425 |        $1,438 | **$1,208** |   $4,174 | **Self-hosted, decisively**       |

```
Break-even, 6-minute jobs, Ireland:
  Topology I, full attribution   ~6,500 jobs/mo   = ~39,000 job-minutes/mo
  Topology I, shared endpoints   ~1,700 jobs/mo   = ~10,000 job-minutes/mo
  Topology II, NAT               ~7,600 jobs/mo   = ~45,700 job-minutes/mo
```

**In a shared isolated landing zone, self-hosting beats GitLab SaaS at roughly 1,700 jobs/month** —
4.5× lower than the NAT-topology break-even, because the marginal cost per job falls to $0.0128.
That is a genuinely different conclusion from the previous revision, and it follows directly from
73% of CI bytes becoming free.

**But for the design-target use case the comparison is largely moot.** GitLab.com SaaS runners
run on the public internet and **cannot reach an isolated on-prem estate** — no internal package
mirror, no internal artifact store, no private services under test, and no path to a self-managed
GitLab that is not internet-exposed. If the reason you are reading this document is a banking
environment with on-prem connectivity, SaaS is not a candidate architecture and this table is a
sanity check, not a decision. Adjust for allowances anyway: GitLab **Premium includes 10,000
compute minutes/month** (worth $100) and **Ultimate includes 50,000** (worth $500).

---

## 16. Operational Cost

`Operational Labour Cost` — **not cloud infrastructure cost**, and deliberately not folded into any
figure above. Assumes a fully-loaded platform engineer at **$100/hour** (≈ €86/h). Dublin and
London platform-engineering rates typically run $90–$140/h fully loaded, so treat $100 as the low
end of a European estimate.

### Topology I — isolated VPC

| Activity                                                                                    |     Minimal |     Typical |       Heavy |          Peak |
| ------------------------------------------------------------------------------------------- | ----------: | ----------: | ----------: | ------------: |
| **Initial** — integration, GitLab registration, alarm routing                               |        16 h |        20 h |        24 h |          28 h |
| **Initial** — network prerequisite coordination (endpoints, SG rules, DNS, on-prem routing) |         8 h |        12 h |        16 h |          20 h |
| **Initial** — AMI pipeline for the manager (mandatory, P1)                                  |        16 h |        16 h |        16 h |          16 h |
| **Total initial**                                                                           |    **40 h** |    **48 h** |    **56 h** |      **64 h** |
| **One-time cost**                                                                           |  **$4,000** |  **$4,800** |  **$5,600** |    **$6,400** |
| AMI rebuild + patching (manager, and worker if baked)                                       |      1 h/mo |      1 h/mo |    1.5 h/mo |        2 h/mo |
| `gitlab-runner` + fleeting plugin version bumps                                             |    0.5 h/mo |    0.5 h/mo |      1 h/mo |        1 h/mo |
| Spot interruption + capacity-shortfall triage                                               |    0.5 h/mo |      1 h/mo |      2 h/mo |        4 h/mo |
| Terraform maintenance, provider upgrades                                                    |    0.5 h/mo |    0.5 h/mo |      1 h/mo |      1.5 h/mo |
| Incident response (orphaned workers, wedged destroy)                                        |    0.5 h/mo |    0.5 h/mo |      1 h/mo |        2 h/mo |
| **Endpoint/DNS diagnosis** — failures present as hangs                                      |    0.5 h/mo |      1 h/mo |    1.5 h/mo |      1.5 h/mo |
| **Recurring hours/month**                                                                   |   **3.5 h** |   **4.5 h** |     **8 h** |      **12 h** |
| **Recurring labour cost**                                                                   | **$350/mo** | **$450/mo** | **$800/mo** | **$1,200/mo** |

### Topology II — NAT egress, for comparison

|                           |     Minimal |     Typical |       Heavy |          Peak |
| ------------------------- | ----------: | ----------: | ----------: | ------------: |
| Total initial             |        24 h |        32 h |        40 h |          48 h |
| One-time cost             |      $2,400 |      $3,200 |      $4,000 |        $4,800 |
| Recurring hours/month     |         2 h |         3 h |         6 h |          10 h |
| **Recurring labour cost** | **$200/mo** | **$300/mo** | **$600/mo** | **$1,000/mo** |

**The isolated topology costs 50% more labour, and that is the honest price of the security
posture.** Three lines drive it:

1. **The AMI pipeline is mandatory** (P1), not optional. 16 h up front and ~1 h/month forever.
2. **Network prerequisites need another team.** The module states the contract as data
   (`output.network_contract`) precisely because this coordination is the hard part, but stating
   it does not remove the 8–20 hours of coordinating it.
3. **Failures present as hangs, not errors.** A missing endpoint, a missing private-DNS setting or
   a missing SG rule produces a job that waits. Nothing names the missing piece. That is a
   materially higher MTTR than a `connection refused`, and it is why the endpoint/DNS diagnosis
   line exists.

**Ireland-specific note on the Spot-triage line.** With the default x86 `worker_instance_types`,
two of four Ireland pools sit in the >20% interruption band, putting triage hours at the upper end.
**Moving to Graviton (Q3) plausibly halves that line** — worth $100–$200/month at Heavy and Peak,
comparable to the compute saving itself and not counted in any infrastructure figure.

Two module design choices genuinely reduce this number and deserve credit in a TCO comparison:
`manager_self_heal = true` (an ASG of one, so a dead manager or a dead AZ recovers without a human)
and the alarm set — particularly the `orphaned_workers` composite alarm, which converts the
module's one unbounded-bill failure mode into a page with a documented runbook.

Two increase it: `manager_instance_refresh = false` means **config changes do not reach a running
manager** without manual intervention, and `max_use_count = 1` produces high instance churn, which
makes Spot interruption noise proportionally louder.

---

## 17. Total Cost of Ownership

### Infrastructure TCO — cloud only, EU (Ireland)

| Scenario    | I — full attr /mo | I — shared /mo | II — NAT /mo | I — full attr /yr | I — shared /yr | II — NAT /yr |
| ----------- | ----------------: | -------------: | -----------: | ----------------: | -------------: | -----------: |
| Minimal     |              $317 |        **$88** |         $164 |            $3,801 |     **$1,050** |       $1,969 |
| **Typical** |          **$363** |       **$134** |     **$319** |        **$4,354** |     **$1,603** |   **$3,830** |
| Heavy       |              $633 |       **$404** |       $1,253 |            $7,600 |     **$4,850** |      $15,034 |
| Peak        |            $1,438 |     **$1,208** |       $4,174 |           $17,251 |    **$14,500** |      $50,092 |

### Operational TCO — Topology I, Ireland (infrastructure + labour)

**Full attribution:**

| Scenario    | Infra/mo | Labour/mo | **Total/mo** | **Year 1** (incl. setup) | Labour share |
| ----------- | -------: | --------: | -----------: | -----------------------: | -----------: |
| Minimal     |     $317 |      $350 |     **$667** |                  $12,001 |      **52%** |
| **Typical** | **$363** |  **$450** |     **$813** |              **$14,554** |      **55%** |
| Heavy       |     $633 |      $800 |   **$1,433** |                  $22,800 |      **56%** |
| Peak        |   $1,438 |    $1,200 |   **$2,638** |                  $38,051 |      **45%** |

**Shared endpoints:**

| Scenario    | Infra/mo | Labour/mo | **Total/mo** |  **Year 1** | Labour share |
| ----------- | -------: | --------: | -----------: | ----------: | -----------: |
| Minimal     |      $88 |      $350 |     **$438** |      $9,250 |      **80%** |
| **Typical** | **$134** |  **$450** |     **$584** | **$11,803** |      **77%** |
| Heavy       |     $404 |      $800 |   **$1,204** |     $20,050 |      **66%** |
| Peak        |   $1,208 |    $1,200 |   **$2,408** |     $35,300 |      **50%** |

**Labour is the dominant cost at every scenario up to Peak, and up to 80% of true TCO once the
endpoint estate is shared.** This is a stronger version of the previous revision's finding, and it
is the most important framing in the document: **there is very little cloud cost left to optimize
in a well-placed isolated fleet. The remaining cost is people.**

The practical consequences:

- **Below Heavy, optimizing the cloud bill is the wrong project.** Reducing $134 to $110 saves
  $288/year. Reducing recurring labour from 4.5 h to 3 h/month saves $1,800/year — six times more.
  Invest in the AMI pipeline being boring, the alarms routing somewhere a human reads, and the
  runbook being accurate.
- **The single best labour investment is P1 done properly.** A manager AMI built by a scheduled
  pipeline, pinned and tested, removes both the mandatory-prerequisite risk and most of the
  monthly patching toil.
- **At Peak the ratio finally inverts** and the §13 optimizations become the highest-return
  engineering work available — S2 returns $10,032/year at Peak against 4–6 weeks of effort.

### 3-year TCO with realistic growth — Topology I, Ireland

Typical → Heavy over three years (a team growing 20 → 90 engineers), 3%/year price drift, +15%
workload in year 3, **Q1 (share the endpoints) applied at the start of year 2**:

| Year             | Workload               | Endpoints  |       Infra |                Labour |       Total |
| ---------------- | ---------------------- | ---------- | ----------: | --------------------: | ----------: |
| 1                | Typical, defaults      | dedicated  |      $4,354 | $10,200 (incl. setup) |     $14,554 |
| 2                | Heavy                  | **shared** |      $4,996 |                $9,600 |     $14,596 |
| 3                | Heavy +15%, Q3 applied | shared     |      $5,373 |                $9,600 |     $14,973 |
| **3-year total** |                        |            | **$14,723** |           **$29,400** | **$44,123** |

Without Q1, the same growth path costs **$20,220 in infrastructure** ($4,354 + $7,828 + $8,038) —
**Q1 is worth $5,497 over three years** on this trajectory, for a conversation rather than a
sprint. In EUR at the §4 rate: **≈ €4,710 saved.**

For comparison, the same growth path in **Topology II** costs **$30,930 in infrastructure**
($3,830 + $12,935 + $14,165) — the isolated topology is **$16,207 cheaper over three years** on
this trajectory, _and_ it is the more secure architecture. That is the rare case where the
security-driven choice is also the cheaper one, and it is worth saying to a CFO in exactly those
terms.

---

## 18. Break-Even Analysis

Ireland rates unless noted.

| Decision                                         | Break-even point                                                                                     | Below it                                                                            | Above it                                                                               |
| ------------------------------------------------ | ---------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| **Topology I vs Topology II**                    | **3,835 GB/month** of CI traffic ≈ **5,800 jobs/mo**. Fixed premium $172.28 ÷ per-GB saving $0.04492 | NAT cheaper in cash — but choose Topology I anyway for isolation                    | **Isolated is cheaper _and_ more secure**. At Heavy it is 2× cheaper; at Peak 2.9×     |
| **Topology I (shared endpoints) vs Topology II** | **Never — I wins at every volume**                                                                   | —                                                                                   | Shared-endpoint isolated is the cheapest option in this document at all four scenarios |
| **Dedicated CI VPC vs shared landing zone**      | **Immediate — $229/month, always**                                                                   | —                                                                                   | **Always share.** No security cost, no code change                                     |
| **Endpoints 3 AZ vs 2 AZ**                       | Availability decision, not a volume one: **$80.30/month**                                            | —                                                                                   | 2 AZ defensible for CI; **1 AZ is not** (§14)                                          |
| **Transit Gateway in path vs direct DX/VGW**     | **Immediate — $36.50/mo + $0.02/GB, always**                                                         | —                                                                                   | Remove it if the landing-zone routing model allows. $53/mo at Typical, $449 at Peak    |
| **S3 gateway endpoint**                          | **0 GB — free, always**                                                                              | always take it                                                                      | always take it                                                                         |
| **Direct Connect vs Site-to-Site VPN**           | **2,607 GB/month** of AWS→on-prem egress                                                             | **VPN cheaper** — true through Heavy                                                | DX cheaper, but only just at Peak. Choose DX for latency, not price                    |
| **`ecr.api`/`ecr.dkr` endpoints**                | **Mandatory in Topology I** — no volume threshold                                                    | —                                                                                   | Jobs cannot pull an image without them                                                 |
| **Spot vs On-Demand**                            | Immediate at any volume                                                                              | —                                                                                   | Saves $0.0484/instance-hour: $16/mo Minimal → $548/mo Peak                             |
| **arm64 vs x86 (Spot), Ireland** ⭐              | **Immediate** ($0.0158/h, **30% off compute**) once images support arm64                             | Porting cost dominates below ~500 worker-hours/mo                                   | Worth it from Typical up — _and_ it fixes the interruption profile                     |
| **arm64 vs x86 (Spot), London**                  | $0.0077/h (20% off compute)                                                                          | Marginal below Heavy                                                                | Worth it above Heavy                                                                   |
| **Baked manager AMI**                            | **Mandatory in Topology I** — not a cost decision                                                    | —                                                                                   | The default bootstrap cannot reach `packages.gitlab.com`                               |
| **Baked worker AMI**                             | ~$4.81/mo saved at Typical; 16 h build ≈ $1,600 → **28-month payback at Typical, 6 at Heavy**        | **Take it for latency and for removing a root `dnf` from every boot, not for cost** | Cost payback under a year from Heavy up                                                |
| **`max_use_count` 1 → 10**                       | Saves 2.4% at Typical. **The financial case is gone**                                                | —                                                                                   | Not recommended — see §14                                                              |
| **`capacity_per_instance` 1 → 2**                | Requires jobs that fit in half an instance's RAM                                                     | Keep at 1                                                                           | 2.2–8.5% saving                                                                        |
| **Commitment vs On-Demand**                      | Never meaningfully — max $3.76/mo, and 81% of the bill has no commitment mechanism                   | Do not buy                                                                          | Do not buy                                                                             |
| **Self-hosted vs GitLab SaaS**                   | **~10,000 job-min/mo** (shared endpoints), **~39,000** (dedicated), **~45,700** (NAT)                | SaaS cheaper on paper — **but it cannot reach an isolated estate at all**           | Self-hosted cheaper, increasingly so                                                   |
| **Additional runner fleet**                      | **+$30.03/mo** in a shared VPC vs **+$307.43/mo** with its own                                       | Consolidate into one fleet                                                          | Separate fleets justified by isolation needs — **but put them in one VPC**             |
| **This module vs `gitlab-runner-fargate`**       | Fargate saves $48.18/mo of endpoints and the whole AMI pipeline                                      | Fargate better at Minimal if you can live without `image:`/`services:`/dind         | This module, once those capabilities matter                                            |
| **Ireland vs London**                            | London 3.2% cheaper in Topology I (wider than the <1% over NAT)                                      | —                                                                                   | Decide on data residency and **latency to on-prem GitLab**                             |

### Does autoscaling actually reduce cost here?

**Yes, decisively — and the module's implementation is why.** Ireland, Typical, worker compute
only. Unchanged by the refactor, since it concerns only the ASG contract:

| Approach                                                      | Monthly worker compute |
| ------------------------------------------------------------- | ---------------------: |
| Static fleet sized to peak concurrency (8 × On-Demand, 730 h) |                $593.23 |
| Static fleet sized to peak concurrency (8 × Spot, 730 h)      |                $310.40 |
| Static fleet sized to average (2 × Spot, 730 h)               |                 $77.60 |
| **This module (scale-to-zero, Spot)**                         |             **$44.40** |
| This module on Graviton                                       |             **$31.23** |

`min_size = 0` / `desired_capacity = 0` means genuinely zero instances overnight and at weekends.
Against a peak-sized On-Demand fleet that is a **93% reduction — 95% on Graviton**.

**But the standard caveat applies, and it bites harder in Topology I.** At Minimal, provisioning
overhead plus the warm idle pool means **82% of billed worker time is not running a job** — and
worker compute is only 5.5% of the Minimal bill anyway, because the fixed endpoint estate swamps
it. **At Minimal scale in an isolated VPC, autoscaling is optimizing 5% of the problem.** The
thing to fix there is the fixed estate (Q1), not the fleet. Efficiency arrives at Typical (52%
useful) and is good by Heavy (73%), which is also where compute becomes worth optimizing.

---

## 19. Assumptions & Limitations

### Assumptions table

| Assumption                                      | Value                                                     | Unit  | Source                                                                   | Confidence                            |
| ----------------------------------------------- | --------------------------------------------------------- | ----- | ------------------------------------------------------------------------ | ------------------------------------- |
| Monthly hours                                   | 730                                                       | h     | AWS billing convention                                                   | **HIGH**                              |
| Business days/month                             | 21.7                                                      | days  | 260 business days ÷ 12                                                   | **HIGH**                              |
| Primary region                                  | eu-west-1                                                 | —     | Analysis choice for EU deployment                                        | **HIGH**                              |
| Module defaults                                 | as committed at `7b25201`                                 | —     | `variables.tf`, read directly                                            | **HIGH**                              |
| Manager instance                                | `t4g.small`, On-Demand, 730 h                             | —     | `manager_instance_type` default, ASG min=max=1                           | **HIGH**                              |
| Manager EBS                                     | 20 GB gp3                                                 | GB    | `manager_disk_gb` default                                                | **HIGH**                              |
| Worker fleet                                    | Spot 100%, blended $0.05315/h                             | USD/h | `spot_enabled`, `worker_instance_types`, Spot feed 2026-08-26            | **MEDIUM** — live market              |
| Worker EBS                                      | 50 GB gp3, ephemeral                                      | GB    | `worker_disk_gb` default                                                 | **HIGH**                              |
| Alarm count                                     | 6 metric + 1 composite                                    | —     | `observability.tf`, `manager_self_heal = true`                           | **HIGH**                              |
| Custom metrics                                  | 2 (`RunnerHealthy`, `BootstrapFailure`)                   | —     | manager bootstrap template                                               | **HIGH**                              |
| Heartbeat frequency                             | 60 s (`OnUnitActiveSec=60`) → 43,800 calls/mo             | calls | `runner-heartbeat.timer`                                                 | **HIGH**                              |
| Warm idle pool                                  | 238.7 h/mo (11 h × 21.7 d)                                | h     | `autoscaling_policies` default `* 8-18 * * mon-fri`                      | **HIGH**                              |
| Provisioning overhead                           | 2.24 min billed per launch                                | min   | Bootstrap step timing estimate                                           | **MEDIUM**                            |
| **Interface endpoints required**                | **10** (8 from `network_contract` + `ecr.api`, `ecr.dkr`) | —     | `output.network_contract` + ECR pull requirement                         | **MEDIUM** — depends on your registry |
| **Endpoint AZ spread**                          | **3**                                                     | AZ    | Typical landing-zone practice; **the caller's choice, not the module's** | **LOW** — biggest single swing        |
| Endpoint attribution                            | modelled both ways (full / shared)                        | —     | Cannot be determined from the module                                     | **N/A — presented as a range**        |
| TGW in the on-prem path                         | assumed present, shown both ways                          | —     | Common in hub-and-spoke banking landing zones                            | **LOW**                               |
| Interface endpoint rate                         | $0.011/endpoint/AZ/h                                      | USD   | AWS Price List Bulk API 2026-08-25                                       | **HIGH**                              |
| S3 gateway endpoint                             | $0 hourly, $0 data                                        | USD   | AWS VPC pricing page                                                     | **HIGH**                              |
| TGW attachment / processing                     | $0.05/h, $0.02/GB                                         | USD   | AWS TGW pricing page — **not in the bulk-API pull**                      | **MEDIUM**                            |
| DX data transfer out (Europe)                   | $0.02/GB                                                  | USD   | AWS DX pricing page — **not in the bulk-API pull**                       | **MEDIUM**                            |
| DX data transfer in                             | $0.00/GB                                                  | USD   | AWS DX pricing page                                                      | **HIGH**                              |
| Site-to-Site VPN                                | $0.05/connection/h                                        | USD   | AWS VPN pricing page                                                     | **MEDIUM**                            |
| Share of image bytes via S3 gateway             | 99% (1% manifest/auth via `ecr.*`)                        | %     | ECR architecture: layers redirect to S3                                  | **MEDIUM**                            |
| `dnf` traffic via S3 gateway                    | 100%                                                      | %     | AL2023 regional repos are S3-backed                                      | **MEDIUM**                            |
| Jobs/month, durations, image and artifact sizes | see §5                                                    | —     | **Modelled scenarios, NOT observed usage**                               | **LOW**                               |
| Log volume (manager only)                       | 50–300 MB/mo                                              | GB    | Journal-tail + bootstrap log estimate                                    | **LOW**                               |
| Labour rate                                     | $100/h fully loaded                                       | USD/h | European platform-engineering estimate                                   | **LOW**                               |
| 3-year price drift                              | 3%/year                                                   | %     | Conservative; AWS list prices historically flat                          | **LOW**                               |
| USD→EUR / USD→GBP                               | 0.856908 / 0.733061                                       | —     | open.er-api.com 2026-08-26                                               | **MEDIUM** — floating                 |

### Confidence by cost component

| Component                                      | Confidence | Why                                                                                                                                                                         |
| ---------------------------------------------- | ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Manager compute + EBS                          | **HIGH**   | Fixed instance type, fixed size, fixed hours                                                                                                                                |
| CloudWatch alarms + custom metrics + API calls | **HIGH**   | Resource count and timer interval read from the code                                                                                                                        |
| VPC interface endpoint **rate**                | **HIGH**   | Bulk-API figure                                                                                                                                                             |
| VPC interface endpoint **quantity × AZ**       | **LOW**    | Depends entirely on the caller's landing zone and registry choice. The 10 × 3 AZ model is a defensible default, not a fact about your account                               |
| Endpoint **attribution**                       | **N/A**    | Not determinable from the module. Both bounds are given; the truth is a policy question                                                                                     |
| Worker compute                                 | **MEDIUM** | Spot is a live market (±15% historical variance) and the Ireland x86 pools are at a poor point in that band                                                                 |
| Worker EBS                                     | **MEDIUM** | Follows worker-hours, which follow the job model                                                                                                                            |
| TGW / DX / VPN                                 | **MEDIUM** | Rates not from the bulk-API pull; presence in the path is an assumption                                                                                                     |
| Free-tier–style effects                        | **HIGH**   | Excluded from every figure and shown separately                                                                                                                             |
| CI traffic volume                              | **LOW**    | Modelled from job counts and per-job byte assumptions. **The single largest source of error in Topology II; much less material in Topology I, where 73% of bytes are free** |
| CloudWatch Logs                                | **LOW**    | Log volume is not observable from the code, but the line is $0.03–$0.18 so the error is immaterial                                                                          |
| Operational labour                             | **LOW**    | Estimated hours at an estimated rate. Directionally reliable (labour dominates below Heavy), not precise                                                                    |

### Limitations

1. **This document cannot tell you your endpoint bill.** The module creates no endpoints, so their
   count, AZ spread and attribution are properties of your landing zone. That is 66% of the
   Typical Topology I figure. **Both bounds are given; get the real number from whoever owns the
   VPC before committing a budget.** This is the honest consequence of the BYO refactor: the
   module became cleaner and the cost became less knowable from the module alone.

2. **Traffic volumes are modelled, not measured.** No repository, pipeline or registry was
   observed. The per-job byte assumptions in §5 are the largest single source of uncertainty in
   Topology II. Re-run §8 with your own Cost Explorer numbers once the fleet has been live for a
   month, filtered on the module's `ManagedBy`/`Module` tags.

3. **Spot prices are a live market.** Every worker-compute figure is a point-in-time snapshot.

4. **The T4g manager runs in `unlimited` credit mode** with no `credit_specification` block. A
   sustained-high-CPU manager can bill surplus credits at $0.04/vCPU-hour, up to ~$47/month.
   **Not included in any figure.** Watch `CPUCreditBalance` and `CPUSurplusCreditsCharged` on the
   manager for the first month.

5. **The fleet has never been run against a live AWS account.** `ARCHITECTURE.md` records the
   module as _"implemented, audited, not yet validated against a live AWS account"_. Every runtime
   figure — worker-hours, boot overhead, log volume, traffic totals — is derived from the code and
   from the workload model, not from observation.

6. **The manager bootstrap is assumed replaced by a baked AMI in Topology I** (P1). Costs for that
   pipeline are modelled at ~$2/month of snapshot storage plus the §16 labour. A real Image Builder
   or Packer pipeline may add build-instance hours, a KMS key, and an S3 bucket for logs — small,
   but not zero, and not modelled beyond the snapshot line.

7. **GitLab's own infrastructure is out of scope.** A self-managed GitLab instance, its database,
   object storage and artifact retention are the dominant CI cost in many organizations and are
   not costed here at all.

8. **No account-specific discounts are applied.** No EDP, no PPA, no MAP credits, no private
   pricing. If your organization holds any of these, every figure is an upper bound.

9. **Cross-AZ data transfer between workers and endpoints is not modelled.** Interface endpoints
   are assumed present in every AZ a worker subnet occupies. If they are not, add $0.01/GB each
   direction — and accept that a worker whose AZ has no endpoint will hang, which is a correctness
   problem before it is a cost one.

---

## 20. Pricing Sources

| Source                                                                                                                 | What it provided                                                                                                         | Accessed   | Publication date |
| ---------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | ---------- | ---------------- |
| **AWS Price List Bulk API** — `pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/eu-west-1/index.json` | EC2 On-Demand, EBS gp3, snapshot, NAT Gateway, VPC endpoint hourly and data rates, public IPv4                           | 2026-08-26 | **2026-08-25**   |
| Same, `eu-west-2` and `us-east-1`                                                                                      | Regional comparison rates                                                                                                | 2026-08-26 | 2026-08-25       |
| **AWS Price List Bulk API** — `AmazonCloudWatch`                                                                       | Alarms, composite alarms, custom metrics, `PutMetricData`, Logs ingestion and storage                                    | 2026-08-26 | 2026-08-25       |
| **AWS public Spot price feed** — `website.spot.ec2.aws.a2z.com/spot.json`                                              | Spot rates for all eight instance types, three regions                                                                   | 2026-08-26 | live             |
| **AWS Spot Instance Advisor**                                                                                          | Interruption-frequency bands per pool per region                                                                         | 2026-08-26 | live             |
| **AWS PrivateLink pricing page**                                                                                       | Interface endpoint $0.011/AZ/h, data $0.01/GB; S3 gateway endpoint free                                                  | 2026-08-27 | live             |
| **AWS Transit Gateway pricing page**                                                                                   | Attachment $0.05/h, data processing $0.02/GB                                                                             | 2026-08-27 | live             |
| **AWS Direct Connect pricing page**                                                                                    | Port hours (1/10 Gbps, Europe), DTO $0.02/GB, DTI free                                                                   | 2026-08-27 | live             |
| **AWS Site-to-Site VPN pricing page**                                                                                  | $0.05/connection/h                                                                                                       | 2026-08-27 | live             |
| **AWS EC2 detailed monitoring documentation**                                                                          | 7 metrics per instance billed as custom metrics                                                                          | 2026-08-27 | live             |
| **about.gitlab.com/pricing**                                                                                           | SaaS runner compute minutes, tier allowances                                                                             | 2026-08-26 | live             |
| **open.er-api.com**                                                                                                    | USD→EUR, USD→GBP                                                                                                         | 2026-08-26 | live             |
| **The module source itself**                                                                                           | Resource inventory, defaults, alarm count, heartbeat interval, bootstrap download list, `network_contract` endpoint list | 2026-08-27 | `7b25201`        |

No blog posts, vendor comparison sites or third-party calculators were used for any rate.

---

## 21. Final Recommendation

> ### How much should we realistically budget to operate this GitLab Runner infrastructure?

For a **20–30 developer business line (Scenario B) in an isolated eu-west-1 VPC**, which is this
module's design target:

### Recommended monthly budget

| Placement                                              |           Cloud | Labour |       **Total** |
| ------------------------------------------------------ | --------------: | -----: | --------------: |
| **In an existing isolated landing zone (recommended)** | **$140 (€120)** |   $450 | **$590 (€506)** |
| In a CI-dedicated VPC with its own endpoint estate     |     $370 (€317) |   $450 |     $820 (€703) |
| In an internet-connected VPC with NAT                  |     $325 (€278) |   $300 |     $625 (€536) |

### Recommended annual budget

| Placement                          |               Cloud | Labour (steady state) | **Year 1** (incl. setup) |
| ---------------------------------- | ------------------: | --------------------: | -----------------------: |
| **Existing isolated landing zone** | **$1,700 (€1,457)** |                $5,400 |    **$11,900 (€10,197)** |
| CI-dedicated VPC                   |     $4,450 (€3,813) |                $5,400 |        $14,650 (€12,554) |
| NAT-connected VPC                  |     $3,900 (€3,342) |                $3,600 |         $10,700 (€9,169) |

### Expected range

**Cloud cost, isolated topology, Typical workload: $88 – $363/month.** The 4.1× spread is not
workload uncertainty — it is the endpoint attribution decision. Workload uncertainty on top of
that is roughly ±25%.

Across the full workload range: **$88/month (Minimal, shared endpoints) to $1,438/month (Peak,
dedicated endpoints)** — a 16× range dominated by two variables, only one of which is CI activity.

### Contingency reserve

**Reserve 30% on the cloud line and 20% on the labour line.** Larger than the 15–20% a
compute-dominated workload would need, for three specific reasons:

1. **The endpoint count is not knowable from this module.** If your registry, your job IAM model
   or your DNS design needs endpoints beyond the ten modelled, each one is **+$8.03/month per AZ**
   — $24.09/month at three AZs. Two surprises make 20%.
2. **Spot is a live market**, and the default Ireland x86 pools are currently at a poor point in
   their historical band. A ±15% move in Spot is ±4% of the Typical bill and ±6% of Peak.
3. **The fleet has never been run against a live account.** Worker-hours, boot overhead and log
   volume are derived, not observed. Re-baseline after one month of real Cost Explorer data
   filtered on the module's tags.

### Biggest financial risk

**The runner fleet being given its own VPC and its own endpoint estate — $2,750/year of fixed
cost, decided in a network-design meeting nobody attends with a FinOps hat on.**

It is the biggest risk precisely because it does not look like a cost decision. It arrives as
"CI gets its own account and VPC for blast-radius isolation" — sound reasoning, real security
value, and a **$229/month invoice that scales with the number of fleets and does not scale down
with CI activity**. A five-fleet organization pays $1,537/month for endpoints instead of $427.

**Second risk: the mandatory AMI pipeline being discovered late.** The module's default bootstrap
cannot reach `packages.gitlab.com` from an isolated VPC. Discovered during design, that is 16
hours of planned work. Discovered during a go-live window, it is an outage, an emergency internal
mirror, and a strong temptation to "just add a NAT gateway temporarily" — which is how an isolated
banking VPC acquires an internet path.

**Third risk, and the one the module actively defends against: orphaned scale-in-protected
workers.** Every worker carries `protect_from_scale_in = true`, so a manager that dies without
releasing its fleet leaves instances billing indefinitely. `worker_max_lifetime_seconds` does
**not** reclaim them — ASG-initiated replacement respects scale-in protection, and the module's own
comment says so. The `orphaned_workers` composite alarm is the only real control. **Route it to a
channel a human reads, and never set `create_alarms = false`.** At Peak, 100 orphaned
`m6i.large` instances bill ~$5.32/hour — $3,900/month if nobody notices.

### Best optimization opportunity

**Deploy the fleet into an existing isolated landing zone rather than a CI-dedicated VPC.**

```
Saving:    $229/month  ·  $2,750/year  ·  63% of the Typical cloud bill
Effort:    one conversation with the landing-zone owner
Risk:      low — shared endpoints are the normal pattern, not a compromise
Security:  unchanged. Arguably improved: one endpoint estate to monitor, not N
Code:      no change to this module. It already creates nothing here
```

Nothing else in this document is close on return-per-hour. The runner-up is **removing the Transit
Gateway from the on-prem path** ($53/month at Typical, $449 at Peak) and then **Graviton workers**
($13/month at Typical, $178 at Peak, plus a materially better Spot interruption profile in
Ireland).

### Recommended sequence

1. **Week 0 — before any Terraform.** Get the endpoint list to the network team
   (`terraform output network_contract`), and **add `ecr.api` and `ecr.dkr` to it yourself** — the
   contract does not name them. Establish whether the endpoints already exist. This single
   conversation determines 63% of the cloud bill.
2. **Week 0 — decide the AZ spread deliberately.** Each AZ is $80.30/month of endpoints. Two is
   defensible for CI; one is not. Make sure `worker_subnet_ids` covers exactly the AZs that have
   endpoints, and no others.
3. **Week 1–2 — build the manager AMI (P1).** This is a prerequisite, not an optimization. Pin
   `gitlab_runner_version`, `fleeting_plugin_version` and `fleeting_plugin_sha256` while you are
   there (P4).
4. **Week 2 — deploy with defaults otherwise.** Leave `max_use_count = 1`,
   `capacity_per_instance = 1`, `create_alarms = true`, `verify_manager_to_worker_ssh_rule = true`.
   Route `alarm_sns_topic_arns` somewhere a human reads **before** the first job runs.
5. **Month 1 — measure, do not optimize.** Pull Cost Explorer filtered on the module's
   `ManagedBy`/`Module` tags. Compare against §8. Watch the manager's `CPUSurplusCreditsCharged`.
   Confirm the `orphaned_workers` alarm can actually fire by testing it.
6. **Month 2 — Graviton (Q3), if your images can be built multi-arch.** In Ireland this is a
   reliability decision as much as a cost one.
7. **Month 3+ — revisit only if you are past Heavy.** Then M1 (remove the TGW) and M4 (in-VPC
   dependency mirror) are the two remaining structural levers, worth $216/month combined at Heavy.
8. **Do not** buy a commitment, do not set `max_use_count > 1`, do not set
   `assign_public_ips = true`, and do not drop an endpoint to save its hourly charge.

---

## Financial Quality Gate

- [x] Every billable Terraform resource identified — §3, including a line for every free resource so "free" is asserted rather than omitted
- [x] Region identified — eu-west-1 primary, eu-west-2 and us-east-1 costed for comparison
- [x] Instance types identified — `t4g.small` manager, four-family x86 Spot worker fleet, Graviton alternative
- [x] Storage calculated — manager EBS, worker EBS with per-second proration, gp3 IOPS/throughput baselines, AMI snapshots
- [x] Network costs considered — **both topologies**: PrivateLink, S3 gateway, TGW, DX, VPN, NAT, internet egress, cross-AZ
- [x] NAT considered — §3, §8 Topology II, §18 (and its absence from the design target made explicit)
- [x] Data transfer considered — §5 byte-class table with per-topology rates, §8, §9
- [x] Logging considered — §3, §8, and honestly labelled LOW confidence and immaterial
- [x] Monitoring considered — 6 alarms + 1 composite + 2 custom metrics + 43,800 API calls, all read from the code
- [x] Autoscaling modelled — §11 capacity vs provisioned, §18 against three static alternatives
- [x] Idle capacity considered — §11 idle-waste table, 82% at Minimal, warm-pool derivation corrected to 238.7 h
- [x] Multiple workload scenarios calculated — four, each in three cost models
- [x] Fixed and variable costs separated — §10, per topology, with floor and marginal-per-job
- [x] Pricing sources recorded — §20, with publication dates and an explicit note on which rates were **not** in the bulk-API pull
- [x] Assumptions documented — §19, with the endpoint count and AZ spread flagged LOW confidence as the largest swing
- [x] No unsupported infrastructure invented — the module's zero network resources are stated as such; caller-required infrastructure is attributed, never folded in
- [x] No free-tier assumptions hidden — excluded everywhere, shown separately in §8, and worth $0 in Topology I
- [x] Security not sacrificed for cost — §14, including the finding that the main security/cost trade-off **disappeared** under BYO
- [x] Monthly costs calculated — §6
- [x] Annual costs calculated — §7
- [x] Sensitivity analysis performed — §12, both topologies, 2×/5×/10×
- [x] Major cost drivers identified — §9, with the ranking inverting between Typical and Peak
- [x] Optimization opportunities quantified — §13, with prerequisites separated from optimizations
- [x] Final recommendation produced — §21

**One item this document deliberately does not claim to have satisfied:** the endpoint quantity and
AZ spread cannot be determined from the module, because the module creates no endpoints. §6, §8 and
§21 present both bounds rather than a single number. Anyone using this to set a budget must get
that figure from whoever owns the VPC — it is 66% of the Typical answer.
