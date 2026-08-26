# Terraform GitLab CI/CD Runner Module — Production Audit

**Target:** `modules/gitlab-runner` — 16 config files, 3 templates, ~65 variables, 13 outputs, an 1,037-line test suite (81 runs), a TOML-parsing structural linter, and an offline render fixture.
**Scope:** the module plus `examples/simple`, `examples/gitlab-runner-dev`, `examples/gitlab-runner-production`, and the repository CI workflow.
**Mode:** adversarial, read-only. No module file was modified during this audit.
**Method:** four independent auditors (security/IAM/isolation/secrets; network/compute/bootstrap/supply-chain; Terraform quality/API/idempotency/destroy; runner architecture/reliability/observability/cost/testing), then cross-correlation of every finding.

**Verification performed by execution, not inspection.** `terraform validate` and `fmt -check -recursive` clean; `terraform test` 81/81 pass on both 1.9.8 and 1.12; the rendered `config.toml` parsed with `tomllib` and inspected key-by-key; the rendered bootstrap exercised in a bash harness and checked with `bash -n`; the systemd units extracted and run through `systemd-analyze verify`; the 30-CIDR egress default decomposed and complemented programmatically with Python's `ipaddress`; 22 instance families classified against the architecture regex in `terraform console`; the manager's IAM policy rebuilt in a scratch root module and serialised offline to see what actually attaches; the route-table heuristic and SG rule counts proven with a purpose-built test fixture; the provider's JSON schema consulted for `aws_route_tables.ids`, `aws_vpc_endpoint`, and the ASG delete path.

---

## 1. Executive Summary

**Overall score: 69/100. Quality gate: PRODUCTION READY WITH CONDITIONS.**

No critical defect survived this audit. The module boots, the security model holds under attack, and the parts that are hard to get right are right. What remains is a set of ten high-severity findings clustered in three places: **things that silently do nothing**, **things that page or fail during normal operation**, and **a class of inputs that leak secrets by default**.

**What is genuinely strong.** The containment architecture is correct and I could not break it. The `glrt-` token lives only on the manager, reaches it from an SSM SecureString, and is substituted via stdin — never argv, never `user_data`, never the launch template, never the rendered outputs, never the log, never the journal, never `ps`. All of that was verified against the actual rendered artifacts. The manager holds the only fleet-control IAM in the system and its policy is an **exact match** for the fleeting plugin's documented requirement with no excess. The worker role — what jobs run as — is empty by default. Jobs run unprivileged with IMDS hop limit 1, on single-use VMs, with no docker socket mounted. The ASG contract for a plugin-owned fleet is exactly right, and the dependency graph is not only acyclic but *accidentally correct on destroy*: the manager is torn down before the fleet, so it cannot fight the drain.

The `worker_egress_cidrs` RFC1918 complement is **provably exact and minimal**. The version-pinning gate is real, enforced, and tested — rare in modules of this kind. The TOML structural linter genuinely catches table-scoping bugs that substring assertions cannot.

**The three problem clusters.**

1. **Controls that do nothing.** `worker_max_lifetime_seconds` — the documented backstop against orphaned workers — cannot fire, because every worker is born scale-in-protected and the ASG will not rotate a protected instance. That is the *exact* failure it was built for. `metrics_listen_address` configures a Prometheus endpoint nothing can reach or scrape. An `aws:SourceAccount` condition on the EC2 instance-profile trust policy guards nothing and, two auditors independently warn, may prevent instances from receiving credentials at all.
2. **Behaviour during normal operation.** `terraform destroy` cannot delete the worker ASG while a job is running. Manager loss orphans the entire running fleet with no signal. The two fleet alarms are effectively inverted by the module's own `max_use_count = 1` default and misbehave on small fleets. The S3 gateway endpoint writes a route into the VPC's **main** route table on the most common subnet layout. The default egress silently blocks a self-managed GitLab, and the failure is per-job.
3. **Secret-bearing inputs that are not treated as secrets.** `extra_runner_config_toml`, `runner_environment`, and `worker_user_data` are natural places to put a credential, are unmarked `sensitive`, and are broadcast into `user_data` *and* two non-sensitive outputs. `extra_runner_config_toml` additionally binds bare keys into the last autoscaling policy rather than where both the variable and the template claim, and a line matching the heredoc delimiter yields root code execution on the manager.

**Most important recommendation:** fix the four controls that silently do nothing before anything else. A control that reports success while doing nothing is worse than an absent one, because it justifies not building the real thing. Then mark the secret-bearing inputs `sensitive` and correct where `extra_runner_config_toml` lands.

---

## 2. Architecture Overview

```
Input variables
      ↓
IAM   manager role: SetDesiredCapacity / SetInstanceProtection / Terminate (scoped to this ASG)
                    + SendSSHPublicKey (scoped by ASG tag AND ec2:osuser)
                    + ssm:GetParameter (one parameter) + PutMetricData (one namespace)
                    + logs:Put* (one log group)
      worker role:  AmazonSSMManagedInstanceCore only
      ↓
SSM SecureString (glrt- token) → manager EC2 (ASG of 1; user_data renders config.toml,
                                  installs CW agent first, then a 60s liveness heartbeat)
      ↓                                    ↓ SetDesiredCapacity / SSH via EC2 Instance Connect
GitLab (long-poll for jobs) ←──────────────┤
                                           ↓
                         worker ASG (min 0, mixed instances, Spot-first, multi-AZ,
                                     scale-in protection, AZRebalance suspended,
                                     group metrics enabled)
                                           ↓
                         ephemeral workers → Docker executor → CI jobs
      +
CloudWatch: 1 log group, 5 alarms (RunnerHealthy, BootstrapFailure, manager absent,
            fleet at capacity, capacity shortfall via metric math)
Optional:   N interface endpoints + 1 S3 gateway endpoint
```

**The graph is acyclic, and one design decision is why.** `local.manager_user_data` embeds the ASG *name* via `local.worker_asg_name` — a pure function of `var.name`, not a resource attribute — while `local.manager_statements` consumes the ASG *ARN* and the log-group ARN. The manager's `depends_on` closes the loop *around* the worker ASG rather than into it. Get that wrong and the module does not plan.

**An unintended benefit worth recording:** the same edge chain forces destroy order manager-ASG → manager-role-policy → worker-ASG, so the manager is gone before Terraform drains the fleet and cannot re-scale against the drain. And the `ShipLogs` statement's reference to the log-group ARN transitively orders the log group before the manager boots, so the CloudWatch agent never races a missing group.

**Trust boundaries:** untrusted CI code → job container → worker host → worker instance role → AWS; and manager → AWS control plane. The manager boundary is well defended. The worker boundary is deliberately thin, which is acceptable *because* the worker role is empty — and becomes the blast radius the moment a caller populates it.

---

## 3. Scorecard

| Category | Score | Weight | Weighted |
| --- | ---: | ---: | ---: |
| Security | 72 | 18% | 12.96 |
| IAM / Least Privilege | 74 | 10% | 7.40 |
| GitLab Runner Architecture | 78 | 10% | 7.80 |
| Runner Isolation | 66 | 8% | 5.28 |
| Secrets Management | 68 | 7% | 4.76 |
| Network Security | 78 | 7% | 5.46 |
| Terraform Quality | 76 | 8% | 6.08 |
| Module Reusability | 58 | 7% | 4.06 |
| Reliability | 52 | 6% | 3.12 |
| Scalability | 62 | 5% | 3.10 |
| Observability | 55 | 4% | 2.20 |
| Supply Chain Security | 62 | 4% | 2.48 |
| Testing | 72 | 3% | 2.16 |
| Documentation | 71 | 3% | 2.13 |
| **Weighted total** | | **100%** | **68.99 ≈ 69** |

---

## 4. Quality Gate

```
PRODUCTION READY WITH CONDITIONS
```

**Why not a straight pass.** Ten high-severity findings remain, and three of them describe controls the documentation presents as working guarantees that do not function (`worker_max_lifetime_seconds`, the Prometheus endpoint, the `aws:SourceAccount` condition). A further cluster describes normal-operation failures: destroy blocked by a running job, manager loss orphaning the fleet invisibly, and two alarms mis-tuned against the module's own defaults.

**Why not a fail.** None of the spec's automatic-FAIL conditions is met. There is no privilege-escalation path, no administrative IAM reachable from a CI job, no path from a runner compromise to broad cloud compromise, and isolation is not fundamentally unsafe — jobs are unprivileged, single-use, and hold an empty role. The two candidates were examined and neither qualifies: the token-in-state exposure has a first-class mitigation the module documents and the production example uses; and the heredoc-delimiter RCE requires control of module inputs, which is already a trusted position.

**Conditions for unconditional production use:** the P0 set in §18 — four silent-no-op controls, the `sensitive` markings, the `extra_runner_config_toml` scope correction, the destroy path, and the two alarm thresholds.

---

## 5. Critical Findings

**None.** No finding in this audit meets the CRITICAL bar. Every candidate was tested and downgraded: the token handling was attacked and held, the rendered TOML parses with every key on its correct table, injection stress against `name`/`docker_image`/`allowed_images`/`runner_environment`/`worker_ready_command` could not break the template, and the bootstrap's failure signalling fires on every exit path examined.

---

## 6. High Findings

## FINDING-001 — `aws:SourceAccount` on the EC2 instance-profile trust policy guards nothing and may block credentials entirely
Severity: HIGH · Category: IAM / Correctness · Score Impact: −14 · Confidence: MEDIUM (two auditors, independently)
**Evidence:** `iam.tf:22-37` (condition at `:31-35`), applied to both roles at `:48` and `:179`.
**Problem:** The trust is `sts:AssumeRole` for `ec2.amazonaws.com` gated on `StringEquals aws:SourceAccount`. When EC2 assumes a role on behalf of an instance profile, it is not documented to populate `aws:SourceAccount` or `aws:SourceArn` in the request context. AWS's own canonical EC2 trust policy carries no such condition.
**Why it matters:** If the key is absent, `StringEquals` does not match and the assume-role is **denied** — no instance in the fleet ever receives credentials, so nothing bootstraps. If it *is* populated, the condition is still near-worthless: an instance-profile assume-role is already implicitly scoped to the account that owns the profile.
**Consequence:** Either a total, confusing outage on first apply, or security theatre. Both are bad, and which one you get is undocumented.
**Failure scenario:** First apply succeeds. The manager boots, `aws ssm get-parameter` fails with AccessDenied, bootstrap traps, `BootstrapFailure=1` fires, and the operator hunts a permissions bug that is actually a trust-policy condition.
**Root cause:** A confused-deputy control was applied to a principal type where the condition key is not part of the request context.
**Recommendation:** Remove the condition. The canonical EC2 service trust is correct as-is; scoping comes from the instance profile. If a guard is genuinely wanted, add a `PassRole` constraint on whoever can attach the profile instead. **Verify against a live apply before shipping** — this is the one finding whose severity depends on runtime behaviour.
**Priority:** IMMEDIATE · **Effort:** XS

## FINDING-002 — `worker_max_lifetime_seconds` cannot fire on the exact failure it exists for
Severity: HIGH · Category: Reliability / Cost · Score Impact: −10 · Confidence: HIGH (two auditors)
**Evidence:** `workers.tf:121` (`max_instance_lifetime`), `workers.tf:101` (`protect_from_scale_in = true`), documented as the backstop at `variables.tf:667-677` and `README.md:213`.
**Problem:** Every worker is created scale-in-protected, and the plugin protects instances while they hold jobs. ASG-initiated replacement for `max_instance_lifetime` respects scale-in protection, so the very instances the backstop targets — orphaned, protected workers left behind by a dead manager — are precisely the ones it cannot rotate.
**Consequence:** The documented protection against indefinitely-billed orphans does not exist. Combined with FINDING-003 (manager loss orphans the fleet silently), an unnoticed manager failure bills a full fleet until a human intervenes.
**Recommendation:** Either a scheduled reaper (EventBridge + Lambda that clears protection on instances with no manager, or on age) or a documented manual sweep (`set-instance-protection --no-protected-from-scale-in`). Whichever you choose, **correct the variable description and README** — right now they promise a guarantee that isn't there.
**Priority:** IMMEDIATE · **Effort:** M (reaper) / XS (docs)

## FINDING-003 — Manager loss orphans the entire running fleet, and nothing can see it
Severity: HIGH · Category: Reliability / Observability · Score Impact: −10 · Confidence: HIGH
**Evidence:** `manager.tf:87-127` (ASG of 1, `manager_instance_refresh` default off), `observability.tf:21-41`, `workers.tf:101`.
**Problem:** When the manager dies, every in-flight job dies with it, and the protected workers it left behind stay running and billed. The replacement manager has no knowledge of them. `RunnerHealthy` correctly goes missing and the alarm fires — but nothing reports or reconciles the orphaned fleet, and per FINDING-002 nothing rotates it.
**Consequence:** A single manager failure converts into an open-ended bill plus a silently degraded fleet.
**Recommendation:** Alarm on `GroupInServiceInstances > 0` while `RunnerHealthy` is absent — that composite is the orphan condition and both metrics already exist. Pair it with the reaper from FINDING-002.
**Priority:** HIGH · **Effort:** S

## FINDING-004 — `terraform destroy` cannot delete the worker ASG while a job is running
Severity: HIGH · Category: Destroy Safety · Score Impact: −8 · Confidence: HIGH (verified against the provider's ASG delete path)
**Evidence:** `workers.tf:101` (`protect_from_scale_in = true`) with no `force_delete` and no drain step anywhere in the module.
**Problem:** A scale-in-protected instance blocks ASG deletion. Any worker mid-job — or leaked after a manager crash — wedges `terraform destroy`, which retries and then times out.
**Why CI hides it:** the integration job destroys an idle fleet, so this never surfaces in testing.
**Recommendation:** Expose `force_delete` (default false) and/or a documented drain: clear protection across the group, wait for scale-in, then destroy. Document the manual escape hatch either way.
**Priority:** HIGH · **Effort:** S

## FINDING-005 — The two fleet alarms are effectively inverted by the module's own default
Severity: HIGH · Category: Observability · Score Impact: −8 · Confidence: HIGH (two auditors)
**Evidence:** `observability.tf:93-114` (`fleet_at_capacity`: `Average >= max_instances * 0.9`) and `:119-166` (`capacity_shortfall`: metric math, `> max(1, floor(max_instances * 0.25))`).
**Problem:** With `max_use_count = 1` the fleet churns continuously, so averaged in-service sits *below* the ceiling almost always — `fleet_at_capacity` under-fires. Meanwhile a persistent churn gap makes `capacity_shortfall` the more sensitive of the two. On **small fleets** the arithmetic inverts: with `max_instances = 2`, the shortfall threshold floors to 1 (a hair-trigger on any single pending instance) while the capacity threshold is 1.8 (fires at two instances, i.e. constantly).
**Consequence:** The two alarms most likely to matter operationally are mis-tuned in opposite directions, and worst on the small fleets most teams start with.
**Recommendation:** Scale both thresholds with fleet size and add a floor for small fleets; prefer alarming on `GroupPendingInstances` (already enabled) for the shortfall case — it is the direct signal for "AWS will not give me capacity" and needs no metric math. Add tests that assert threshold behaviour at `max_instances = 1, 2, 20`.
**Priority:** HIGH · **Effort:** S

## FINDING-006 — Secret-bearing inputs are unmarked and broadcast to `user_data` and two non-sensitive outputs
Severity: HIGH · Category: Secrets · Score Impact: −9 · Confidence: HIGH (three auditors)
**Evidence:** `variables.tf` — `extra_runner_config_toml`, `runner_environment`, `worker_user_data` all lack `sensitive = true`; consumed at `locals.tf:62-101`; re-exported by `outputs.tf` (`config_toml`, `manager_user_data_preview`), and again by `examples/gitlab-runner-production/outputs.tf`.
**Problem:** These are the natural places to put a registry credential, a cache secret, or an API token. Any value placed there lands in plan output, in state, in the launch template's `user_data` (readable via `ec2:DescribeInstanceAttribute`), and in two outputs the production example re-exports.
**Why it matters:** The token path is meticulous — SecureString, stdin not argv, `install -m 0600` before content, a placeholder-refusal guard, post-substitution verification, `unset`, no `set -x`. All verified. And then a whole class of secret-shaped inputs bypasses every one of those controls.
**Consequence:** The careful part is the part nobody was going to get wrong; the leaky part is the part everyone uses.
**Recommendation:** Mark all three `sensitive = true`; mark `config_toml` and `manager_user_data_preview` sensitive (or gate them behind a `debug_outputs` flag); drop them from the production example's outputs; and document that `user_data` is readable by anyone with `ec2:DescribeInstanceAttribute`.
**Priority:** HIGH · **Effort:** XS

## FINDING-007 — `extra_runner_config_toml` binds bare keys into the last autoscaling policy, not where either the variable or the template says
Severity: HIGH · Category: Runner Architecture / API · Score Impact: −7 · Confidence: HIGH (three auditors; confirmed by TOML parse)
**Evidence:** `templates/config.toml.tftpl:72-76` appends after the `[[runners.autoscaler.policy]]` loop. The template comment says "appended at TOP LEVEL"; the variable description says it is "appended to the `[[runners]]` section". Parsing shows a bare key binds to the **last `[[runners.autoscaler.policy]]`**.
**Problem:** Three different claims, none of which matches behaviour. A caller adding `check_interval = 10` silently corrupts a scaling policy instead of setting a global.
**Consequence:** The module's only escape hatch is a trap. A table header (`[runners.cache]`) happens to work because it is an absolute path; anything else misbehaves silently.
**Recommendation:** Emit the block at genuine top level (before `[[runners]]`), or keep the position and state precisely where bare keys land. Then assert the placement in `parse_config.py` with a bare-key probe, not just a table header.
**Priority:** HIGH · **Effort:** S

## FINDING-008 — Default worker egress silently blocks a self-managed GitLab, and the failure is per-job
Severity: HIGH · Category: Network / Usability · Score Impact: −6 · Confidence: HIGH (three auditors)
**Evidence:** `variables.tf` `worker_egress_cidrs` default excludes RFC1918; `security-groups.tf:73-82`.
**Problem:** A self-managed GitLab is almost always on a private address. Workers cannot reach it, so `git clone` fails on every job. The manager still registers (its egress is `0.0.0.0/0`), so GitLab shows the runner **online** while every job fails.
**Consequence:** The most confusing possible failure signature, on a supported configuration (`gitlab_url` explicitly accepts self-managed).
**Recommendation:** Detect a private `gitlab_url` and either add it to worker egress automatically or fail at plan with a message naming `worker_egress_cidrs`. At minimum, document it beside `gitlab_url`.
**Priority:** HIGH · **Effort:** S

## FINDING-009 — The S3 gateway endpoint writes a route into the VPC's main route table on the most common layout
Severity: HIGH · Category: Network / Blast Radius · Score Impact: −8 · Confidence: CONFIRMED (reproduced with a test fixture)
**Evidence:** `locals.tf:8-33` (`data.aws_route_tables.worker` filtered on `association.subnet-id`, plus a main-route-table fallback when explicit associations are fewer than subnets), consumed at `security-groups.tf:198-207`.
**Problem:** The fallback triggers whenever *any* worker subnet lacks an explicit association — including the very common case where several subnets share one table. It then adds the VPC's **main** route table, changing routing for every subnet in a VPC this module does not own.
**Consequence:** Unrelated workloads get an S3 gateway route they did not ask for; two fleets in one VPC collide on `RouteAlreadyExists`. The module's own comment two blocks below states that rewriting routing for unrelated subnets "is not ours to do".
**Recommendation:** Compute per-subnet associations properly (one plural lookup per subnet, or resolve main-table membership explicitly) and include the main table **only** for subnets genuinely on it. Better: expose `s3_endpoint_route_table_ids` and let the caller decide.
**Priority:** HIGH · **Effort:** S

## FINDING-010 — Production example ships a cross-project cache-poisoning primitive while commenting that it does not
Severity: HIGH · Category: Examples / Security · Score Impact: −6 · Confidence: HIGH (two auditors)
**Evidence:** `examples/gitlab-runner-production/main.tf:104-116` (the security comment) vs `:118-136` (the grant) and `:263-274` (`Shared = true` with a single `Path`).
**Problem:** The comment claims "keys are namespaced per project, and the policy is scoped to that prefix", so "a malicious job on one project can't poison another's". With `Shared = true` and one flat prefix, every project reads and writes the same prefix. `s3:DeleteObject` is correctly withheld, but `PutObject` over a shared prefix is sufficient to plant a payload a trusted job later restores.
**Recommendation:** Either `Shared = false`, or a bucket/prefix per trust boundary, or delete the claim. A comment asserting a protection that isn't implemented is worse than no comment.
**Priority:** HIGH · **Effort:** S

---

## 7. Medium Findings

| ID | Finding | Evidence | Fix |
|---|---|---|---|
| M01 | Heredoc-delimiter escape: a line equal to `TFCONFIG` in `extra_runner_config_toml` yields root code execution on the manager (the placeholder guard catches it after the fact) | `manager-user-data.sh.tftpl:168-170` | random-suffixed delimiter; reject the delimiter in validation |
| M02 | Worker role's `AmazonSSMManagedInstanceCore` grants account-wide SSM document read + inventory write — broader than "deliberately minimal" claims | `iam.tf:171-176` | scope it, or soften the claim |
| M03 | No way to open any egress port/protocol other than 443 without forking the module — breaks internal registries on 5000, proxies, apt over 80 | `security-groups.tf:73-82` | expose `worker_egress_rules` as a list of {protocol, port, cidrs} |
| M04 | `a1.*` (Graviton 1) misclassified as x86_64 by the arch regex; the **manager** has no arch-coherence check at all | `variables.tf` arch validation, `locals.tf:52` | extend the regex; validate `manager_instance_type` vs `manager_ami_id` |
| M05 | The default `worker_ready_command` (`docker info`) fails on a baked AMI whose SSH user isn't in the `docker` group — and a baked AMI is the documented production path | `variables.tf` ready command, `worker-user-data.sh.tftpl:13` | document the AMI contract; add the user to the group unconditionally |
| M06 | Zero worker-side observability: a worker boot-loop, a failing `docker info`, or a Spot reclaim storm is invisible | no worker log shipping anywhere | ship worker logs, or alarm on launch failures |
| M07 | `create_vpc_endpoints = true` is a net cost **loss** at low volume (N interface endpoints × AZs, hourly) while the docs present it as a saving | `variables.tf`, `README.md` | separate the free S3 gateway from the priced interface endpoints; correct the docs |
| M08 | Production S3 endpoint policy is default-deny and omits ECR layer buckets, breaking image pulls from ECR | `examples/.../main.tf:147-168` | add the ECR layer bucket ARNs |
| M09 | `kms_key_arn` needs two key-policy grants the variable never mentions (Logs service principal, Auto Scaling service-linked role) | `variables.tf` kms description | document both, with the encryption-context condition |
| M10 | Manager user_data is at ~71% of the 16 KB EC2 limit with no guard | `locals.tf:83-96` | add a precondition on rendered length |
| M11 | Prometheus metrics configured on loopback, unreachable and unscraped — a knob with no endpoint | `config.toml.tftpl:10`, `variables.tf` | add a CW-agent prometheus scrape (needs no ingress), or remove the knob |
| M12 | `manager_self_heal = false` replaces the manager on **every** config change — the opposite of the ASG path's behaviour, and undocumented | `manager.tf:131-160` | document, or add `ignore_changes` |
| M13 | The `gitlab-runner` service gets no explicit AWS region, unlike the heartbeat unit beside it | `manager-user-data.sh.tftpl` | add a systemd drop-in with `AWS_DEFAULT_REGION` |
| M14 | `worker_ready_command`'s 120s budget is undersized for the module's own default AMI path (Docker install at boot); timeout behaviour undocumented | `variables.tf` | raise it, or document that the default AMI needs a longer gate |
| M15 | Two fleets in one VPC collide on interface-endpoint private DNS; only the first wins | `security-groups.tf:180-190` | document; `endpoint_private_dns` exists but the collision isn't stated |
| M16 | Image/service allow-lists exist but are off by default and unset in the production example | `variables.tf`, production example | set them in the production example |
| M17 | `max_use_count > 1` reuses the `/cache` named volume across jobs; the dev example ships `max_use_count = 10` | `variables.tf` docker_volumes, dev example | document the reuse; consider dropping `/cache` when reuse is on |
| M18 | Manager egress defaults to `0.0.0.0/0` while workers get a 30-entry carve-out — the more privileged node is the less restricted one | `variables.tf` manager_egress_cidrs | apply the same carve-out by default |
| M19 | `no credit_specification`: the T4g manager launches in `unlimited` mode, so a busy manager silently accrues charges | `manager.tf` LT | set `standard`, or expose it |
| M20 | Spot interruption mid-job has no handling, drain, or signal; `.gitlab-ci.yml` guidance is one sentence | module + README | document `interruptible`/`retry`; consider a rebalance hook |
| M21 | Two tests assert less than their names claim, and the IAM policy documents are still mocked so the attached JSON is unasserted | `tests/gitlab-runner.tftest.hcl:29-31` | render for real in the fixture and assert the JSON |
| M22 | `package_repo_script_url` regex anchors only the scheme, so the value is shell-injectable in a root context | `variables.tf` | validate the full URL charset |
| M23 | CI has no Terraform version matrix; the integration job can pass without ever launching a worker | `.github/workflows/terraform-ci.yaml` | add a matrix; assert a worker reached InService |
| M24 | Provider lockfile is gitignored and **the whole module is untracked in git** — no consumer can pin a `?ref=` | repo state | commit and tag |
| M25 | `concurrent` can reach 100,000 with no relationship to manager size | `locals.tf:59` | validate against instance class; publish a sizing table |

---

## 8. Low / Informational Findings

- **L01** `DiscoverFleet` grants account-wide instance enumeration with no region condition (the APIs reject resource scoping, so this is near-unavoidable — but a region condition is possible).
- **L02** `additional_worker_policy_arns` is unbounded because `permissions_boundary_arn` is optional; a boundary would cap the footgun.
- **L03** Manager launch template omits `instance_initiated_shutdown_behavior`, unlike the worker.
- **L04** No SSH host-key verification on the manager→worker connection (upstream plugin behaviour, not the module's, but worth stating).
- **L05** The `coalesce` log-ARN fallback can render an account-wide wildcard; unreachable in a real apply (the guard matches the log group's `count`) but reachable under mocks, which makes one test weaker than it looks.
- **L06** The `validate` CI job runs `terraform apply` inside the module directory for the render fixture — harmless with `create = false`, but worth an explicit comment.
- **L07** The plain-instance manager is replaced by any new AL2023 release, bypassing the `manager_instance_refresh` protection that exists on the ASG path.
- **L08** Partition/AMI-name portability: the AL2023 name filter and the hardcoded `kernel-6.1` will strand when AWS moves kernels; the production example hardcodes an `al2023-repos-<region>-de612dc2` bucket suffix.
- **L09** README drift: "tested on 1.9.8 and current" is true locally but unsupported by CI (no version matrix); the module is absent from the repo's root module catalogue and CHANGELOG; no LICENSE or semver.
- **L10** `REQ.txt` and `creq.txt` are prompt files sitting inside the module directory and would ship with it.
- **INFO** Recorded positives: the RFC1918 complement is provably exact and minimal; the manager's IAM policy is an exact match for the plugin's documented requirement with no excess; `instance_ready_command` is on the correct TOML table; the destroy ordering is accidentally correct; the token path survived every attack attempted.

---

## 9. Security Assessment

**Threat model.** The realistic actor is anyone who can push a branch or open a fork MR on a project this fleet serves, plus the dependency and base-image supply chain. That actor runs arbitrary code by design.

**Attack path, traced against current defaults** (`docker_privileged = false`, `capacity_per_instance = 1`, `max_use_count = 1`, `imds_hop_limit = 1`, empty `additional_worker_policy_arns`):

| Hop | Reachable? | Notes |
|---|---|---|
| Job → container | YES | by design; image allow-lists exist but are off by default (M16) |
| Container → worker host | **NO** | unprivileged, no docker socket in `docker_volumes` |
| Container → IMDS | **NO** | hop limit 1 |
| Worker host → worker role | n/a by default | role holds only `AmazonSSMManagedInstanceCore` (see M02) |
| Worker → runner token / fleet control | **NO** | manager has zero ingress; token never leaves the manager |
| Worker → internal estate on 443 | **NO by default** | RFC1918 carved out — though the S3 gateway is a scoped bypass, and FINDING-009 widens it |

**Maximum blast radius of a runner compromise, stated plainly:** one disposable VM, an IAM role with SSM-agent permissions, and internet-only egress on 443. The attacker does **not** get the runner token, cannot change fleet capacity, and cannot sweep the internal network. That containment is real and it survived deliberate attack.

The genuine security exposure sits elsewhere: the unmarked secret-bearing inputs (FINDING-006), the heredoc RCE reachable by whoever sets module inputs (M01), the trust-policy condition that may deny everything (FINDING-001), and the moment a caller populates `additional_worker_policy_arns` — the single highest-leverage input in the module, with no guardrail.

**What I tried to break and could not:** the token path (SecureString → stdin → 0600 file → placeholder guard → verification → `unset`, with no leak into log, journal, `ps`, user_data, state-visible outputs, or either rendered artifact); TOML injection via quotes, backslashes, newlines and shell metacharacters in `name`, `docker_image`, `allowed_images`, `runner_environment`, `worker_ready_command`; the manager IAM policy's fallbacks rendering a wildcard in a real apply; and the dependency graph (no cycle, and destroy ordering is correct).

---

## 10. Terraform Assessment

Well-organised and idiomatic: coherent file split, consistent `local.create` gating, `nullable = false` throughout, ~65 variables with real validation, `name_prefix` + `create_before_destroy`, the correct lifecycle contract on a plugin-owned ASG, and `create = false` as a genuine no-op (which is what makes the offline render fixture possible). Every validation was checked against the Terraform < 1.10 eager-`||` hazard and the module works on 1.9.8 — verified, 81/81 on both versions.

Weaknesses: the route-table heuristic over-reaches (FINDING-009); `most_recent = true` keeps plans non-stationary; the variable surface at ~65 inputs is at the edge of exposing implementation rather than decisions; `coalesce(one(...), "*")` remains a mock-satisfying wart; and locals split across three files is defensible but costs readability.

**Destroy safety.** Verified precisely: `protect_from_scale_in` is a group attribute that does **not** categorically block `terraform destroy`, but a protected *instance* does block ASG deletion — so a running job wedges destroy (FINDING-004). Destroy also cannot de-register the runner in GitLab; the token outlives the fleet as an orphaned credential.

---

## 11. GitLab Runner Assessment

The architecture is correct and current: `docker-autoscaler` + `fleeting-plugin-aws` is the supported successor to the deprecated Docker Machine autoscaler, with the modern `glrt-` authentication-token flow and a clean manager/worker credential split.

The rendered `config.toml` was parsed and inspected key by key: `concurrent` equals `max_instances × capacity_per_instance`; `plugin`, `plugin_config.name`, `connector_config`, `capacity_per_instance`, `max_use_count`, `max_instances`, `scale_throttle`, `allowed_images`/`allowed_services` placement, and the `[[runners.autoscaler.policy]]` blocks are all schema-correct; and `instance_ready_command` is on `[runners.autoscaler]` where it belongs. `jsonencode()` is used correctly for every string. This is the strongest single dimension (78).

Remaining gaps: the escape hatch lands in the wrong scope (FINDING-007), metrics are unreachable (M11), one `[[runners]]` block only, and no first-class distributed cache.

---

## 12. Reliability & Operations

| Failure | Behaviour today |
|---|---|
| Manager instance loss | ASG replaces it; in-flight jobs lost; **fleet orphaned and billed** (FINDING-002/003) |
| Manager bootstrap failure | Detected (`BootstrapFailure` + trap on every exit path) but **never remediated**; alarm auto-resolves in ~5 min |
| Manager alive, runner dead | Detected by `RunnerHealthy` — a real improvement, though it proves the process runs, not that CI works |
| Config change applied | Silently ignored by default (`manager_instance_refresh = false`), documented |
| Cold worker first job | Gated by `instance_ready_command` — correct, but 120s may be short on the default AMI (M14) |
| Spot interruption mid-job | One job lost; no drain, handling, or signal (M20) |
| Jobs queued, no capacity | Alarm exists but mis-tuned (FINDING-005) |
| `terraform destroy` with a job running | **Wedges** (FINDING-004) |

Detection is much better than remediation. Nothing in the module self-heals a broken manager beyond hypervisor replacement, and the orphan path has neither detection nor cleanup.

---

## 13. Reusability & Portability

Reusable in shape: BYO VPC, no hardcoded region/account, partition-aware ARNs, x86_64 and arm64 with a coherence check, clean seams for token/AMI/role, and three worked examples whose diffs teach the production posture.

Blockers to org-wide adoption, and why this scores lowest (58): **the module is untracked in git**, so nobody can pin a version (M24); egress is 443-only with no way to add a port without forking (M03); self-managed GitLab is broken by default (FINDING-008); two fleets in one VPC collide on endpoints and route tables (FINDING-009, M15); the S3 gateway mutates a VPC the module does not own; and the baked-AMI contract that production depends on is undocumented and unenforced (M05).

---

## 14. Testing Assessment

Genuinely good, and better than most modules of this size (72). Three layers: 81 mocked plan runs green on both 1.9.8 and 1.12; an offline render fixture (`create = false`, no credentials) feeding a **real TOML parser** plus bootstrap assertions; and a gated integration apply. The parser catches table-scoping bugs that substring assertions provably cannot, and it is the right instinct.

Blind spots: the IAM policy documents are still mocked, so the attached JSON is never asserted (M21); two tests assert less than their names claim; no alarm-threshold tests at different fleet sizes (which is why FINDING-005 survived); the integration job can pass without launching a worker (M23); no Terraform version matrix in CI; and `checkov`/`tflint` steps remain commented out. Worker-side behaviour is entirely untested.

---

## 15. Documentation Assessment

Strong structure and unusual candour (71): mermaid architecture, cost-model table, worked recipes, full inputs/outputs, an "Operating it" section, an explicit security-assumptions list, a production checklist, and a three-layer testing explanation.

But claims still drift from code in ways that matter: `worker_max_lifetime_seconds` is presented as a working backstop (FINDING-002); `create_vpc_endpoints` is presented as a saving (M07); `extra_runner_config_toml`'s placement is described two different ways, neither correct (FINDING-007); the `kms_key_arn` prerequisites are incomplete (M09); and the production example's cache comment asserts a protection it does not implement (FINDING-010). No CHANGELOG, LICENSE, semver, or entry in the repo's module catalogue.

---

## 16. Cost & Scalability

**Where the money goes.** The manager runs 24/7 (`t4g.small` ≈ $12/mo, and in `unlimited` credit mode by default — M19). The default `idle_count = 1` across weekday 08:00–18:59 is roughly **240 idle instance-hours/month**. `max_use_count = 1` pays a full boot per job, plus NAT data for every image pull. `create_vpc_endpoints = true` adds N interface endpoints × AZs at an hourly rate — a net **loss** below meaningful S3/SSM volume, while the genuinely free win (the S3 gateway) is bundled with them rather than separable (M07). Log retention and five alarms are negligible. The open-ended risk is orphaned protected workers (FINDING-002/003), which have no upper bound.

**Strengths:** scale-to-zero and Spot-first are both on by default and are the two largest levers; `max_instances` is a hard ceiling surfaced as `max_concurrent_jobs`.

**At 10×.** `concurrent` can reach 100,000 against a fixed burstable manager with no validation (M25); `scale_throttle` is off by default; subnet IP exhaustion and the ~30-rule SG budget are unguarded; and the single manager remains both bottleneck and SPOF.

---

## 17. Top 10 Recommendations

1. **Remove the `aws:SourceAccount` condition** from the EC2 trust policy — verify on a live apply that instances receive credentials. (XS)
2. **Make `worker_max_lifetime_seconds` real or stop claiming it**: add a reaper for orphaned protected workers, and fix the docs. (M / XS)
3. **Mark `extra_runner_config_toml`, `runner_environment`, `worker_user_data` sensitive**, and stop re-exporting rendered artifacts from the production example. (XS)
4. **Fix where `extra_runner_config_toml` lands**, and assert it with a bare-key probe in the parser. (S)
5. **Alarm on the orphan condition** (`GroupInServiceInstances > 0` while `RunnerHealthy` absent) — both metrics already exist. (S)
6. **Re-tune the two fleet alarms** for small fleets and churn; test thresholds at `max_instances = 1, 2, 20`. (S)
7. **Constrain the S3 gateway to genuinely-associated route tables**, or expose the route-table list. (S)
8. **Handle self-managed GitLab**: detect a private `gitlab_url` and either allow it or fail at plan. (S)
9. **Expose arbitrary egress rules** (protocol + port + CIDR), not just 443. (S)
10. **Commit and tag the module**; add LICENSE/CHANGELOG and a Terraform version matrix in CI. (S)

---

## 18. Remediation Roadmap

**P0 — Immediate (conditions for unconditional production use):** FINDING-001 (trust condition); FINDING-002 (silent no-op backstop + docs); FINDING-006 (sensitive markings); FINDING-007 (escape-hatch scope); FINDING-004 (destroy path); FINDING-005 (alarm tuning).

**P1 — Before broad adoption:** FINDING-003 (orphan alarm); FINDING-008 (self-managed GitLab); FINDING-009 (route-table scope); FINDING-010 (cache claim); M01 (heredoc delimiter); M03 (egress ports); M24 (commit + tag).

**P2 — Hardening:** M02, M04–M14 — worker role scope, arch coverage, AMI contract, worker observability, endpoint economics, ECR buckets, KMS prerequisites, user_data size guard, metrics reachability, plain-instance replacement, service region, readiness budget.

**P3 — Optimization:** M15–M25 and L01–L10 — endpoint DNS collisions, allow-lists in the example, cache volume reuse, manager egress parity, credit specification, Spot guidance, test depth, URL validation, CI matrix, `concurrent` sizing, docs/catalogue/semver, and removing the stray prompt files.

---

## 19. Recommended Target Architecture

No redesign warranted — the topology and security model are right. The target state is this module plus:

- **A worker lifecycle that cannot orphan.** A reaper (EventBridge → Lambda) that clears scale-in protection on workers with no live manager or beyond a max age, plus the composite orphan alarm. This is the single largest reliability and cost gap.
- **A documented, enforced baked-AMI contract** (Docker running, sshd, SSM agent, SSH user in the `docker` group, matching architecture) with a Packer reference — it is already the mandated production path.
- **Two fleets, not one:** an unprivileged default fleet and a separate tagged, GitLab-protected privileged fleet for image builds.
- **Egress as a first-class list** of protocol/port/CIDR rules, with private-`gitlab_url` handling built in.
- **Endpoints split**: the free S3 gateway (scoped by policy and to genuinely-associated route tables) separable from the priced interface endpoints.
- **Secrets treated uniformly**: every input that can carry one marked sensitive, rendered artifacts behind a debug flag.
- **Testing in three layers as today**, plus alarm-threshold tests across fleet sizes, a real IAM policy render, and an integration job that asserts a worker actually reached InService.

---

## 20. Audit Coverage

**Files inspected (all, in full):** `variables.tf`, `locals.tf`, `iam.tf`, `security-groups.tf`, `workers.tf`, `manager.tf`, `observability.tf`, `outputs.tf`, `versions.tf`, `templates/config.toml.tftpl`, `templates/manager-user-data.sh.tftpl`, `templates/worker-user-data.sh.tftpl`, `tests/gitlab-runner.tftest.hcl` (1,037 lines / 81 runs), `tests/parse_config.py`, `tests/render/main.tf`, `README.md`, `examples/simple/main.tf`, `examples/gitlab-runner-dev/`, `examples/gitlab-runner-production/`, `.github/workflows/terraform-ci.yaml`.

**Resources inspected:** 2 launch templates, 3 ASG/instance resources, 2 IAM roles + 2 instance profiles + 1 inline policy + 5 attachments, 3 security groups, ~35 SG rules, N+1 VPC endpoints, 1 SSM parameter, 1 log group, 5 alarms. **Providers:** `hashicorp/aws` (`>= 5.40.0, < 6.0.0`).

**Executed:** `terraform validate`, `fmt -check -recursive`, `terraform test` (81/81 on 1.9.8 **and** 1.12), `tflint --recursive`, the render fixture + `parse_config.py`, `bash -n` on the rendered bootstrap, `systemd-analyze verify` on the rendered units, a Python decomposition/complement of the 30-CIDR egress default, `terraform console` classification of 22 instance families against the arch regex, a scratch-module serialisation of the manager IAM policy, purpose-built test fixtures for the route-table heuristic and SG rule counts, and provider-schema inspection.

**Not performed:** no real `terraform apply` against AWS (no credentials available) — so FINDING-001 (trust-policy condition), FINDING-002 (`max_instance_lifetime` vs scale-in protection) and FINDING-004 (ASG delete with a protected instance) are reasoned from AWS documentation and provider behaviour rather than observed. FINDING-001 in particular is MEDIUM confidence and must be confirmed on a live apply. `shellcheck` was unavailable in one auditor's environment. No live GitLab instance, so registration and job execution were not observed end to end.

**Assumption:** the fleeting plugin's SSH/EC2-Instance-Connect connection model (no SSM tunnelling) is current upstream behaviour.

---

## 21. References

- [GitLab Runner — Docker Autoscaler executor](https://docs.gitlab.com/runner/executors/docker_autoscaler/)
- [GitLab Runner — Advanced configuration (`config.toml` reference)](https://docs.gitlab.com/runner/configuration/advanced-configuration/)
- [GitLab Runner — Fleeting](https://docs.gitlab.com/runner/fleet_scaling/fleeting/) · [Autoscaler](https://docs.gitlab.com/runner/runner_autoscale/gitlab-runner-autoscaler/)
- [`fleeting-plugin-aws` — README & IAM policy](https://gitlab.com/gitlab-org/fleeting/plugins/aws)
- [GitLab — Runner authentication tokens](https://docs.gitlab.com/ci/runners/new_creation_workflow/) · [Runner security](https://docs.gitlab.com/runner/security/) · [Distributed cache](https://docs.gitlab.com/runner/configuration/autoscale/#distributed-runners-caching)
- [AWS — IAM roles for EC2 / instance profile trust](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2.html) · [`aws:SourceAccount` and cross-service confused deputy](https://docs.aws.amazon.com/IAM/latest/UserGuide/confused-deputy.html)
- [AWS — Instance scale-in protection](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-instance-protection.html) · [Replacing instances (max instance lifetime)](https://docs.aws.amazon.com/autoscaling/ec2/userguide/asg-max-instance-lifetime.html)
- [AWS — Auto Scaling group metrics (opt-in)](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-cloudwatch-monitoring.html) · [CloudWatch metric math](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoringGuide/using-metric-math.html)
- [AWS — Gateway endpoints for S3](https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-s3.html) · [Endpoint policies](https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-access.html) · [Route tables](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Route_Tables.html)
- [AWS — Encrypt CloudWatch Logs with KMS](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/encrypt-log-data-kms.html) · [Burstable instance credit modes](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-credits-baseline-concepts.html)
- [AWS — Instance metadata (IMDSv2)](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html) · [Security group quotas](https://docs.aws.amazon.com/vpc/latest/userguide/amazon-vpc-limits.html) · [User data limits](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html)
- [Terraform — `aws_launch_template`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_template) · [`aws_autoscaling_group`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/autoscaling_group) · [`aws_cloudwatch_metric_alarm`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm)
- [Terraform — Sensitive data in state](https://developer.hashicorp.com/terraform/language/state/sensitive-data) · [Tests](https://developer.hashicorp.com/terraform/language/tests) · [Module development](https://developer.hashicorp.com/terraform/language/modules/develop)
- [TOML v1.0.0 — table and key scoping](https://toml.io/en/v1.0.0#table)
- [OWASP — CI/CD Security Top 10 (CICD-SEC-4 Poisoned Pipeline Execution)](https://owasp.org/www-project-top-10-ci-cd-security-risks/)
- [CIS AWS Foundations Benchmark](https://www.cisecurity.org/benchmark/amazon_web_services)

---

```
============================================================

FINAL PRODUCTION READINESS VERDICT

Overall Score: 69/100

Security:              72/100
IAM:                   74/100
Runner Architecture:   78/100
Isolation:             66/100
Secrets:               68/100
Networking:            78/100
Terraform Quality:     76/100
Reusability:           58/100
Reliability:           52/100
Scalability:           62/100
Observability:         55/100
Supply Chain:          62/100
Testing:               72/100
Documentation:         71/100

QUALITY GATE:
PRODUCTION READY WITH CONDITIONS

============================================================
```

**Would I approve this module for production use and organizational reuse? For a single team that owns its VPC and works the P0 list: yes. As an organizational standard today: not yet.**

The security architecture has now been attacked from four independent directions and it holds. I tried to walk a malicious merge request to the cloud account and it stops at a disposable VM with an empty role and internet-only egress. The token survived every extraction attempt I could construct. The manager's IAM policy is an exact match for what the plugin documents — no excess. The rendered configuration parses correctly with every key on its proper table. The graph is acyclic and, by a happy accident of dependency ordering, destroys in the right order. Those are the expensive things, and they are done.

What holds it back is a pattern rather than a list: **several controls report success while doing nothing.** The orphan backstop cannot fire on the case it names. The metrics endpoint has no reachable listener. A trust-policy condition guards nothing and might deny everything. Two alarms are mis-tuned against the module's own defaults. And the escape hatch lands somewhere neither the variable nor the template says it does. Each is individually small; together they mean an operator cannot yet take this module's own documentation at face value, and that is the actual bar for an organizational standard.

The reusability score (58) is the other honest brake: egress is 443-only without forking, self-managed GitLab is broken by default, two fleets in one VPC collide, and **the module is not committed to git**, so nobody can pin a version of it.

Work the six P0 items — four are XS or S — verify FINDING-001 on a live apply, then commit and tag it. At that point this is a defensible standard, and a good one.
