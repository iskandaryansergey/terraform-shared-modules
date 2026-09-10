# AMI pipelines on EC2 Image Builder — Cost Analysis

**Module:** `modules/ami-builder`
**Provider:** AWS (sole provider; `hashicorp/aws >= 5.70.0, < 6.0.0`)
**Primary region:** **`eu-west-1` — EU (Ireland)**
**Currency:** USD (AWS list currency)
**Pricing basis:** eu-west-1 on-demand list prices, no Savings Plans, no EDP discount, free tiers shown separately and never netted in.
**Pricing date:** 2026-09-10.
**Analysis basis:** module defaults as committed at `01fc53a`, plus the review changes in the working tree. Every deviation from defaults is stated where it is used.

> **Verify before quoting externally.** The unit prices in §3 are working figures,
> not a Price List API pull. Re-check them with the command in §9 before this
> document goes into a funding submission. The *structure* of the answer — which
> line dominates, and by how much — does not move with a 10% price change. The
> absolute numbers do.

---

## 1. Executive summary

Image Builder itself is free. Every instance this module launches is transient.
So a plausible first reading is that the module costs nothing — and for the first
month, it roughly doesn't.

The bill is dominated by a line that **has no natural ceiling and never appears
in a plan diff**: retained EBS snapshot storage behind every AMI the pipeline has
ever produced.

### The three numbers a budget needs

| Scenario | Monthly, month 12 | Monthly, month 60 | 5-year cumulative |
|---|---:|---:|---:|
| **A — Baseline.** Monthly build, 1 region, module defaults | **$1.86** | **$1.86** | **$107** |
| **B — Manager image.** Monthly, 1 region, CMK, 20 GB root | **$4.06** | **$4.06** | **$226** |
| **C — Aggressive, unpoliced.** Nightly, 4 regions, `lifecycle_delete_after_days = 0` | **$444** | **$2,172** | **$66,610** |
| C with the module's default retention instead | $444 | $450 | **$24,562** |
| C with `lifecycle_delete_after_days = 30` | $48 | $48 | **$2,890** |

All three are the same module. Scenario C is what happens when a team wires a
nightly cadence to four regions and turns deletion off "until we know what we
can delete".

### Five findings worth a platform lead's attention

1. **Retention is the entire cost conversation.** On scenario C the lifecycle
   policy is worth **$42,048 over five years**. The build compute over the same
   period is **$82**. Three orders of magnitude separate the line everyone tunes
   from the line that pays for itself.

2. **The pipeline is cheaper than the network it needs.** At defaults the module
   spends **$1.85/month**. Three interface endpoints in one AZ cost **$24/month**
   — 13× the thing they exist to serve. If the build subnet gets its own endpoint
   estate, the endpoints *are* the cost of this module. Share the landing zone's
   and the marginal network cost is ~$0.

3. **Billed snapshot GB is not provisioned GB, and the gap is 5×.** A 30 GB root
   volume holding a hardened AL2023 image bills roughly **6 GB** of unique
   blocks. Sizing the bill on `root_volume_size_gb` overstates it fivefold; that
   variable's real cost lands on the *fleet*, not the pipeline (§6).

4. **Each distribution region multiplies the only growing line.** Not adds to —
   multiplies. A copy per region per build, stored forever in that region, plus
   transfer. `check "cross_region_copies_are_intentional"` warns above three for
   this reason.

5. **`pipeline_execution_start_condition` is not a cost control.** It is worth
   about **$14/year** of build compute on a nightly pipeline. It is worth having
   set correctly because a schedule that cannot fire is an operational lie (see
   the module's `check "the_schedule_can_actually_fire"`), not because of money.

---

## 2. What the module creates, and which parts are billable

| Resource | Count at defaults | Billable | Note |
|---|---:|---|---|
| `aws_imagebuilder_image_recipe` | 1 | **$0** | Configuration only |
| `aws_imagebuilder_component` | 1 per entry | **$0** | Stored documents, free, kept forever by default (`retain_component_versions`) |
| `aws_imagebuilder_infrastructure_configuration` | 1 | **$0** | |
| `aws_imagebuilder_distribution_configuration` | 1 | **$0** | |
| `aws_imagebuilder_image_pipeline` | 1 | **$0** | |
| `aws_imagebuilder_lifecycle_policy` | 1 | **$0** | The only free thing here that *reduces* the bill |
| `aws_imagebuilder_workflow` | 0 | **$0** | |
| `aws_imagebuilder_image` (`build_on_apply`) | 0 | indirect | Launches the same instances as a pipeline run |
| `aws_iam_role` / policy / instance profile | 5 | **$0** | |
| `aws_cloudwatch_log_group` | 1 | **cents** | Ingestion + storage, ~200 KB per build |
| `aws_cloudwatch_event_rule` / target | 0–1 | **$0** | AWS-service events are not charged |
| **What the builds launch** | 2 instances per run | **yes** | Build instance, then a test instance from the snapshot |
| **What the builds leave behind** | 1 AMI + snapshots per run | **yes, forever** | The line in this document |

Not created by the module, required to run it, billed to whoever owns it:

| Prerequisite | Cost | Who usually pays |
|---|---:|---|
| VPC interface endpoints: `ssm`, `ssmmessages`, `ec2messages` | $8.03/AZ/month each | Landing zone, if you are lucky |
| S3 gateway endpoint (log delivery, dnf repos) | **$0** | — |
| S3 bucket for build logs | ~$0.01/month at this volume | Platform |
| KMS CMK, if `kms_key_arn` is set | $1.00/month + requests | Security |
| SNS topic, SQS DLQ | cents | Platform |
| Amazon Inspector EC2 scanning | prorated per instance-hour | Security |

---

## 3. Unit prices

| Line | Unit | eu-west-1 |
|---|---|---:|
| `m6i.large` on-demand, Linux, shared tenancy | instance-hour | $0.1128 |
| `m7g.large` on-demand (arm64, scenario B) | instance-hour | $0.0898 |
| gp3 volume storage | GB-month | $0.088 |
| gp3 baseline 3000 IOPS / 125 MiBps | — | $0 (included) |
| **EBS snapshot storage, standard tier** | **GB-month** | **$0.050** |
| Snapshot copy to another region | GB transferred | $0.02 |
| VPC interface endpoint | AZ-hour | $0.011 (= $8.03/month) |
| Interface endpoint data processing | GB | $0.011 |
| S3 Standard storage | GB-month | $0.024 |
| S3 PUT/POST requests | 1,000 | $0.0054 |
| CloudWatch Logs ingestion | GB | $0.57 |
| CloudWatch Logs storage | GB-month | $0.0324 |
| KMS customer-managed key | key-month | $1.00 |
| KMS requests | 10,000 | $0.03 |
| SNS notifications (email) | 100,000 | $2.00 (first 1,000 free) |
| SQS requests | 1,000,000 | $0.40 (first 1M free) |
| EventBridge, AWS service events | event | $0 |
| Amazon Inspector, EC2 scanning | instance-month | $1.2586, prorated |
| EC2 Image Builder | — | **$0** |

### The two assumptions that carry the whole model

**Build duration: 23 instance-minutes per run.** 15 minutes on the build
instance (parent boot, `dnf update --security`, Docker install, cleanup) plus 8
minutes on the *test* instance, which Image Builder launches separately from the
finished snapshot. Two instances per build is easy to miss.

**Billed snapshot size: 6 GB per image.** EBS bills snapshots on unique blocks,
not on the provisioned volume. A hardened AL2023 root with Docker is roughly 5–8
GB of actual data on a 30 GB volume. This document models 6 GB and gives the
3–12 GB sensitivity in §8.

There is a second-order effect worth naming: snapshots are incremental *within a
lineage*. Because the parent AMI is normally owned by `amazon` rather than by
your account, each build's snapshot is billed as a near-full snapshot with no
block sharing against its predecessor. If you build from **your own** base AMI in
the same account and region, actual billed GB will be lower than modelled here.
Measure yours (§9) rather than trusting either number.

---

## 4. Per-build cost

| Component | Scenario A/C (`m6i.large`) | Scenario B (`m7g.large`) |
|---|---:|---:|
| Build instance, 15 min | $0.0282 | $0.0225 |
| Test instance, 8 min | $0.0150 | $0.0120 |
| Transient root volume, 23 min | $0.0014 | $0.0009 |
| Inspector scan, prorated | $0.0007 | — (off in that example) |
| Build logs to S3 + CloudWatch | $0.0002 | $0.0002 |
| **Total per build** | **$0.046** | **$0.036** |

A build is noise. It is worth knowing precisely only so that nobody spends an
afternoon optimising it: **1,000 builds cost $46.**

---

## 5. Snapshot storage — the line that matters

Retained images at steady state, given the module's retention model:

```
retained ≈ max(lifecycle_retain_at_least,
               builds_per_month × lifecycle_delete_after_days / 30
               + anything the recency and tag exemptions hold)
```

Monthly cost = `retained × billed_GB × $0.05 × regions`.

### Scenario A — baseline, module defaults

Monthly build, 1 region, `lifecycle_delete_after_days = 180`, `retain_at_least = 3`.

| Line | Monthly |
|---|---:|
| 1 build | $0.046 |
| 6 retained images × 6 GB × $0.05 | $1.800 |
| Logs (S3 + CWL) | $0.010 |
| **Total** | **$1.86** |
| Annual | **$22.27** |
| Endpoints, if unshared, 1 AZ | +$24.09/month |

### Scenario B — the `gitlab-runner-manager` example

Monthly build, 1 region, arm64, CMK, 20 GB root (~5 GB billed), `delete_after_days = 365`, recency 60 days.

| Line | Monthly |
|---|---:|
| 1 build | $0.036 |
| 12 retained images × 5 GB × $0.05 | $3.000 |
| KMS CMK + requests | $1.010 |
| Logs | $0.010 |
| **Total** | **$4.06** |
| Annual | **$48.67** |

### Scenario C — nightly, 4 regions, deletion off

30 builds/month, build region + 3 distribution regions, `lifecycle_delete_after_days = 0`.

| | Month 1 | Month 12 | Month 60 | 5-year cumulative |
|---|---:|---:|---:|---:|
| Build compute | $1.37 | $1.37 | $1.37 | $82 |
| Cross-region copy transfer | $10.80 | $10.80 | $10.80 | $648 |
| Snapshot storage, 4 regions | $36 | $432 | $2,160 | **$65,880** |
| **Total** | **$48** | **$444** | **$2,172** | **$66,610** |

The same pipeline, changing only retention:

| Retention | Month 12 | Month 60 | 5-year cumulative | Δ vs deletion off |
|---|---:|---:|---:|---:|
| `delete_after_days = 0` (off) | $444 | $2,172 | $66,610 | — |
| `= 365` (module default) | $444 | $450 | $24,562 | **−$42,048** |
| `= 90` | $120 | $120 | $7,102 | **−$59,508** |
| `= 30` | $48 | $48 | $2,890 | **−$63,720** |

Note the first row against the second at **month 12: identical to the cent.**
Thirty builds a month for twelve months is 360 images, and nothing has reached
365 days yet, so the default policy has deleted precisely nothing. From month 13
the two diverge without limit. **A cost review conducted at the end of year one
concludes that the retention policy is worthless** — which is the wrong
conclusion by $42,048, and the reason this document projects to month 60.

---

## 6. `root_volume_size_gb` is a fleet cost, not a pipeline cost

It sets the default root volume of **every instance ever launched from the
image**. That is a different budget, usually a bigger one, and it does not show
up in this module's cost centre at all.

| Fleet | 20 GB | 30 GB | Δ/month |
|---|---:|---:|---:|
| 5 instances | $8.80 | $13.20 | +$4.40 |
| 20 instances | $35.20 | $52.80 | **+$17.60** |
| 100 instances | $176.00 | $264.00 | +$88.00 |

Against a $1.85/month pipeline, the 10 GB you added "to be safe" costs 9× the
pipeline at 20 workers. The `verify-image` component's `MinFreeRootGb` assertion
exists so you can size this down with evidence instead of superstition.

---

## 7. Where the money goes

Scenario C at month 12, $444/month:

| Driver | Share |
|---|---:|
| Snapshot storage, 4 regions | **97.3%** |
| Cross-region copy transfer | 2.4% |
| Build compute | 0.3% |

Scenario A at defaults, $1.86/month — or $25.95/month with unshared endpoints:

| Driver | Share, endpoints shared | Share, endpoints attributed |
|---|---:|---:|
| VPC interface endpoints | — | **92.8%** |
| Snapshot storage | **97.0%** | 6.9% |
| Build compute + logs | 3.0% | 0.3% |

Two different modules, financially. Which one you are running depends entirely
on a network-attribution decision made somewhere else.

---

## 8. Sensitivity

Scenario C, month 12, baseline $444/month. One variable at a time.

| Change | New monthly | Δ |
|---|---:|---:|
| `lifecycle_delete_after_days` 0 → 90 | $120 | **−73%** |
| `distribution_regions` 3 → 0 | $109 | **−75%** |
| Schedule nightly → monthly | $15 | **−97%** |
| Billed snapshot size 6 → 12 GB | $887 | **+100%** |
| Billed snapshot size 6 → 3 GB | $223 | −50% |
| `instance_types` → `m7g.large` | $444 | −0.1% |
| `image_tests_timeout_minutes` 120 → 720 | $444 | 0% (a ceiling, not a duration) |
| `enable_image_tests = false` | $444 | −0.1% and a lost gate. Never for cost |
| `fast_launch` at `target_resource_count = 5` (Windows) | $2,172 | **+389%** |
| `retain_component_versions = false` | $444 | 0%. Components are free; keep the audit trail |

The ranking is stable across the whole plausible price range: **retention,
regions, cadence, then everything else.**

---

## 9. Verifying this against your own bill

The module ships the first command as `verify_commands.snapshot_spend`, with a
caveat this document has to state plainly:

```bash
# Provisioned GB, summed. This OVERSTATES the bill — EBS charges unique blocks.
aws ec2 describe-images --owners self \
  --filters Name=tag:SourceRecipe,Values=<name> \
  --query 'Images[].BlockDeviceMappings[].Ebs.SnapshotId' --output text \
| xargs -r aws ec2 describe-snapshots --snapshot-ids \
  --query 'sum(Snapshots[].VolumeSize)'
```

For the number that is actually billed, go to the bill:

```bash
# Billed snapshot storage, this month, by usage type.
aws ce get-cost-and-usage \
  --time-period Start=$(date -u +%Y-%m-01),End=$(date -u +%Y-%m-%d) \
  --granularity MONTHLY --metrics UnblendedCost \
  --filter '{"Dimensions":{"Key":"USAGE_TYPE_GROUP","Values":["EC2: EBS - Snapshots"]}}'

# And how many images this recipe is keeping alive right now.
aws ec2 describe-images --owners self \
  --filters Name=tag:SourceRecipe,Values=<name> \
  --query 'length(Images)'
```

To re-check the unit prices in §3:

```bash
aws pricing get-products --region us-east-1 --service-code AmazonEC2 \
  --filters 'Type=TERM_MATCH,Field=location,Value=EU (Ireland)' \
            'Type=TERM_MATCH,Field=usagetype,Value=EU-EBS:SnapshotUsage' \
  --query 'PriceList[0]' --output text | python3 -m json.tool | head -40
```

---

## 10. Recommendations, in order of dollars per hour of work

1. **Keep lifecycle deletion on, and set the horizon from your rollback window
   rather than from a feeling about audit.** `lifecycle_retain_at_least` and
   `lifecycle_delete_after_days` are what bound how far back you can roll — see
   [ROLLOUT.md](ROLLOUT.md). Deciding that consciously is worth tens of thousands
   on an aggressive pipeline and costs an afternoon.

2. **Do not give the build pipeline its own interface endpoints.** $24/AZ/month
   to run $1.85/month of builds. If the landing zone has `ssm`, `ssmmessages` and
   `ec2messages`, build there. If it does not, that conversation is worth more
   than everything else in this document.

3. **Distribute only to regions with a consumer.** Each one multiplies the only
   growing line and adds transfer per build.

4. **Right-size `root_volume_size_gb` against the fleet**, using
   `verify-image`'s `MinFreeRootGb` output as evidence. At 20+ workers this
   dwarfs the pipeline.

5. **Choose cadence on patching value, not on cost.** Nightly costs 30× the
   snapshot growth of monthly for 30× the images. Monthly plus a manual trigger
   when a CVE lands is usually the better trade, and
   `verify_commands.trigger_build` is that trigger.

6. **Do not tune `pipeline_execution_start_condition` for money** ($14/year), do
   set it correctly so the schedule can actually fire.

7. **Never disable `enable_image_tests` or `retain_component_versions` for
   cost.** They are 0.1% and 0% of the bill respectively, and both are load
   bearing for everything else the module claims.

---

## 11. What this document does not cover

- **Nothing here has been measured against a real build.** Durations are
  estimates from the component documents, and the 6 GB snapshot figure is a
  modelled value. One live build replaces the two assumptions in §3 that the
  whole model rests on.
- **Windows.** Every bundled component is Linux; `fast_launch` is priced above
  only to show the multiplier it applies.
- **Data transfer inside the build** (package downloads from an internal mirror,
  artefacts from CodeArtifact or ECR). Volume-dependent and caller-specific; at
  interface-endpoint rates, $0.011/GB.
- **Savings Plans, Reserved Instances, EDP or PPA discounts.** None apply to
  snapshot storage, which is 97% of the aggressive case.
