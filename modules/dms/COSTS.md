# terraform-aws-dms — what a migration costs

**Module:** `terraform-aws-dms` (`modules/dms`)
**Region:** **`eu-west-2` — EU (London)**, with `eu-west-1` (Ireland) alongside
**Currency:** USD, on-demand list, no Savings Plans, no EDP discount
**Priced from:** the **AWS Price List bulk API** (`AWSDatabaseMigrationSvc`), pulled 2026-09-21
**Basis:** module defaults; every deviation is stated where it is used

> **One rate here could not be verified.** The published price list contains **no
> DCU-hour SKU for DMS Serverless** — the only serverless entry is a per-GB
> charge. Every serverless figure in §5 therefore rests on a rate this document
> could not confirm from primary source, and the provisioned-versus-serverless
> decision turns on it. Confirm it in the console or on your own bill before
> choosing on those numbers. Everything else below is a live figure.

---

## 1. The shape of the bill

A migration is cheap. Forgetting to delete it is not, and the network it runs
in usually costs more than it does.

| | Cost |
|---|---:|
| **The migration itself** — `dms.c5.xlarge` multi-AZ, 200 GB, 8 weeks | **~$1,029 once** |
| That instance still running a year later | **$6,132/year** |
| The isolated VPC's own interface endpoints, 5 × 2 AZ | **~$964/year**, whether DMS runs or not |
| A `dms.t3.medium` multi-AZ, if the change rate allows it | $1,437/year |

Three things follow, and they are the whole document:

**The teardown is the cost control.** DMS has no idle timeout and no
scale-to-zero. A *stopped task does not stop the instance* — the console shows
everything finished while the meter runs. An unowned `dms.r5.xlarge` multi-AZ is
$9,461/year.

**Size on change rate, not data volume.** A 500 GB database with a quiet schema
runs on a `t3.medium`. A 50 GB core-banking source in CDC will saturate a
`c5.large`. Getting this wrong shows up as CDC latency that grows without bound
— which is a cutover that never happens, not a slow one.

**In an isolated VPC, the endpoints are the floor.** Five interface endpoints
across two AZs is ~$80/month before a single byte moves. That is 4× a
`t3.medium`'s monthly cost, and it is charged whether or not a migration is
running. Share the landing zone's endpoints if you possibly can.

---

## 2. What is billable

| Line | Billed | Note |
|---|---|---|
| **Replication instance** | per hour, creation → deletion | Multi-AZ doubles it. Bills whether tasks run or not |
| **Instance storage** | per GB-month | **Multi-AZ storage is double the Single-AZ rate.** Holds cached changes and in-flight LOBs |
| Serverless capacity | per DCU-hour | Scales between min and max, never to zero |
| Cross-AZ data transfer | $0.01/GB each direction | Instance in a different AZ from either database |
| CloudWatch Logs | ingest + storage | `LOGGER_SEVERITY_DEBUG` is the surprise |
| CloudWatch alarms | $0.10/alarm-month | 7 alarms at defaults ≈ $0.70/month |
| **DMS itself** | **$0** | Free service; you pay for what it runs on |
| **VPC interface endpoints** | per endpoint-hour **per AZ** | Not a DMS charge. Mandatory in an isolated VPC |
| **Cloud WAN** | CNE hours + attachment + per-GB processing | Usually larger than DMS. Get the figure from whoever owns the core network |
| **The Aurora target** | its own bill | Running source and target in parallel for the whole migration is often the biggest line in the programme |

Two allowances worth checking rather than assuming: AWS documents an included
storage allowance for C4/R4/R5 classes, and **whether C5 carries it is
unconfirmed**. This document budgets the full volume.

---

## 3. Rates (London, live)

| Line | Unit | eu-west-2 | eu-west-1 |
|---|---|---:|---:|
| `dms.t3.medium` | instance-hour, Single-AZ | $0.082 | $0.078 |
| `dms.t3.large` | instance-hour, Single-AZ | $0.165 | $0.157 |
| `dms.c5.large` | instance-hour, Single-AZ | $0.175 | $0.175 |
| `dms.c5.xlarge` | instance-hour, Single-AZ | $0.350 | $0.351 |
| `dms.r5.large` | instance-hour, Single-AZ | $0.270 | $0.230 |
| `dms.r5.xlarge` | instance-hour, Single-AZ | $0.540 | $0.460 |
| **Multi-AZ** | — | **×2 on every rate above** | ×2 |
| Instance storage (gp2), Single-AZ | GB-month | $0.120 | $0.127 |
| **Instance storage (gp2), Multi-AZ** | GB-month | **$0.240** | $0.254 |
| Interface endpoint | endpoint-hour per AZ | $0.011 | $0.011 |
| Cross-AZ transfer | GB, each way | $0.010 | $0.010 |
| CloudWatch Logs ingest | GB | $0.57 | $0.57 |
| CloudWatch alarm | alarm-month | $0.10 | $0.10 |
| Serverless capacity | DCU-hour | *not in the price list* | *not in the price list* |

---

## 4. The migration, costed

`dms.c5.xlarge` multi-AZ, 200 GB storage, 8 weeks from first load to teardown —
the `isolated-vpc-onprem-to-aurora` example.

| Line | Cost |
|---|---:|
| Instance, 56 days × 24h × $0.350 × 2 | $940.80 |
| Storage, 200 GB × $0.240 × 1.84 months | $88.42 |
| Cross-AZ transfer, 600 GB each way | $12.00 |
| CloudWatch Logs, ~2 GB at default severity | $1.14 |
| 7 alarms × 2 months | $1.40 |
| **Migration total** | **$1,043.76** |

Against the engineering time, this is noise. It is worth knowing precisely only
so nobody spends a week optimising it.

### Sized differently

| Instance | Multi-AZ | 8 weeks | Suits |
|---|---|---:|---|
| `dms.t3.medium` | yes | $220.42 | Quiet schema, modest change rate |
| `dms.c5.large` | yes | $470.40 | Most relational migrations |
| **`dms.c5.xlarge`** | **yes** | **$940.80** | **On-prem source over a WAN link** |
| `dms.r5.xlarge` | yes | $1,451.52 | Large LOB payloads, memory-bound |

Single-AZ halves the compute line and buys a full restart of the load if the AZ
fails. On a migration with a committed cutover date that is a bad trade — $470
to protect an eight-week programme.

---

## 5. Leaving it running

| Instance | Multi-AZ | Monthly | Annual |
|---|---|---:|---:|
| `dms.t3.medium` | yes | $119.72 | $1,437 |
| `dms.c5.large` | yes | $255.50 | $3,066 |
| `dms.c5.xlarge` | yes | $511.00 | **$6,132** |
| `dms.r5.xlarge` | yes | $788.40 | **$9,461** |

The instance from §4, left in place, costs **six times the entire migration
every year**. There is no idle timeout to save you, and the tasks showing
`stopped` is not a signal that anything has been released.

`check "full_load_does_not_leave_the_meter_running"` fires at plan time when
every task is full-load-only on a provisioned instance, because that is the
configuration with a definite end and no automatic stop.

### Serverless, and where it wins

Serverless removes the instance nobody deleted. It scales down but **never to
zero**, so `min_dcu` bills around the clock while the source is quiet.

The crossover depends on the DCU rate this document could not verify, so the
rule is stated structurally instead of numerically:

- **Steady, modest CDC** that a `t3.medium` handles: **provisioned**.
  Serverless cannot go low enough to compete with $119/month.
- **Bursty CDC** where peaks would force a class larger than the average needs:
  **serverless** — you stop paying for the peak between peaks.
- **A migration with an end date and an owner**: **provisioned**, with the
  teardown in the plan.
- **No owner for the teardown**: **serverless**, and treat the DCU floor as the
  price of that. But note this module creates **no alarms, no event
  subscriptions and no log group** in serverless mode — see the README limits.

---

## 6. The isolated VPC's own bill

This is not a DMS charge and it does not stop when the migration does.

| Line | Monthly | Annual |
|---|---:|---:|
| 1 interface endpoint × 2 AZ | $16.06 | $193 |
| 5 interface endpoints × 2 AZ | **$80.30** | **$964** |
| Endpoint data processing | $0.011/GB | volume-dependent |
| Cloud WAN CNE + attachment + processing | ask the network team | usually the largest network line |

If the build VPC gets its own endpoint estate, the endpoints cost more than the
migration. If the landing zone already has `secretsmanager`, `kms` and `logs`,
the marginal cost is roughly zero. That conversation is worth more than every
instance-sizing decision in this document.

---

## 7. The lines that surprise people

**DEBUG logging.** `LOGGER_SEVERITY_DEBUG` on a busy CDC task can produce 20
GB/month — $11.40 ingest plus storage, indefinitely if retention is unbounded.
`check "debug_logging_is_temporary"` exists because this is a diagnostic
setting that gets committed. It is also a data-classification problem: at that
severity the logs contain row data and SQL text.

**Validation load on the source.** Row validation queries both databases. It
costs nothing in DMS and can cost a great deal on a production source that is
still serving traffic — and on an on-prem source, that capacity belongs to
someone who does not report to you. `validation_threads` defaults to 5 for this
reason; raise it with the DBA team, not around them.

**Cross-region.** A source or target in another region turns cross-AZ transfer
into inter-region transfer, and it applies to every byte of the full load.

**Re-running the load.** Every restart pays the full-load transfer again. On a
WAN link that is the expensive kind of retry, which is the financial argument
for multi-AZ and for getting the LOB settings right the first time.

---

## 8. Checking this against your own bill

```bash
# What is running right now, and since when.
aws dms describe-replication-instances \
  --query 'ReplicationInstances[].[ReplicationInstanceIdentifier,ReplicationInstanceClass,MultiAZ,ReplicationInstanceStatus,InstanceCreateTime]' \
  --output table

# The DMS line, this month.
aws ce get-cost-and-usage \
  --time-period Start=$(date -u +%Y-%m-01),End=$(date -u +%Y-%m-%d) \
  --granularity MONTHLY --metrics UnblendedCost \
  --filter '{"Dimensions":{"Key":"SERVICE","Values":["AWS Database Migration Service"]}}'

# The endpoint line, which is usually the bigger one.
aws ce get-cost-and-usage \
  --time-period Start=$(date -u +%Y-%m-01),End=$(date -u +%Y-%m-%d) \
  --granularity MONTHLY --metrics UnblendedCost \
  --filter '{"Dimensions":{"Key":"USAGE_TYPE_GROUP","Values":["VPC: PrivateLink"]}}'

# Re-check any rate in §3.
curl -s https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSDatabaseMigrationSvc/current/index.json \
  | python3 -c "import json,sys; d=json.load(sys.stdin); [print(p['attributes'].get('usagetype'), p['attributes'].get('instanceType')) for p in d['products'].values() if p['attributes'].get('location')=='EU (London)'][:20]"
```

---

## 9. Recommendations, in order of money saved per hour of work

1. **Put the teardown in the migration plan with a date and an owner.** Worth
   more than everything else here combined.
2. **Share the landing zone's VPC endpoints.** ~$964/year for a dedicated
   estate, to run a migration that costs ~$1,000 once.
3. **Size on change rate**, and let the CDC latency alarm tell you if you were
   wrong — that is what it is for.
4. **Keep multi-AZ** for anything with a committed cutover date.
5. **Turn DEBUG logging back off** when the thing you were debugging is fixed.
6. **Never economise on validation or multi-AZ.** Together they are a few
   hundred dollars on a programme whose failure mode is silent data loss.
