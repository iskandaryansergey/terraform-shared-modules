# terraform-aws-aurora — what a cluster costs

**Module:** `terraform-aws-aurora` (`modules/aurora`)
**Region:** **`eu-west-2` — EU (London)**
**Currency:** USD, on-demand list, no Reserved Instances, no Savings Plans, no EDP discount
**Priced from:** the **AWS Price List bulk API**, eu-west-2 region files, pulled 2026-10-08 — `AmazonRDS` (published 2026-10-06), `AmazonCloudWatch` (2026-10-07), `AWSSecretsManager`, `AmazonKinesis`, `AmazonVPC`, `awskms`, `AWSDataTransfer`
**Basis:** the defaults of module version 2.0.0 (unreleased); every deviation is stated where it is used. 730 hours a month, 8,760 a year.

> **Verify before quoting externally.** Every rate in §3 is a live list price.
> These are not: the I/O, log and Enhanced Monitoring **volumes** are
> assumptions, stated where they are used. **Performance Insights retention
> beyond 7 days** is priced from the "Database Insights (Standard Mode)"
> retention SKUs, which is this document's reading of their names, not a
> confirmed bill line. The **minimum RDS Proxy charge on Serverless v2**, the
> **Kinesis mode and shard count** an activity stream gets, and **eu-west-1
> rates** for a global secondary are not in what was pulled. Confirm those on
> your own bill before relying on them.

---

## 1. The shape of the bill

The instances are the bill. Everything else is rounding until someone turns on
one of the lines that are not.

| | Cost |
|---|---:|
| **Two db.r7g.large, 100 GB standard storage, alarms, managed secret** (§4a) | **$503.02/month — $6,036/year** |
| — of which the two instances | $471.58/month, 94% |
| The same cluster after its major leaves standard support, on Extended Support (§4c) | **+$4,135/year**, then **+$8,234** in year 3 |
| Dev: one `db.serverless`, 0–4 ACU, pausing outside working hours (§4b) | $36.01/month |
| The same dev cluster held at its 4 ACU ceiling all month | $413.20/month |

Three things follow, and they are the whole document:

**Extended Support is the line with no owner.** It starts billing on a date,
not on a change: no plan, no apply, no review. AWS's default turns it on; at
$0.118 per vCPU-hour it is 73% of a db.r7g.large's own price, and 146% in year
3 — the old major then costs more than the database. The module defaults it
off for a new cluster, and `check "extended_support_is_a_decision"` warns when
it is on. The setting is fixed at creation: a cluster the module adopts keeps
what it was created with — *on*, if it was created with AWS's default — and
`check "extended_support_matches_the_setting"` warns until someone decides.
Only a restore from snapshot changes it; otherwise the way out is to upgrade
the major before its standard support ends.

**The line that grows is storage nobody uses.** Every deletion leaves a final
snapshot, by default, under a name unique to that cluster's lifetime — so they
never collide, and nothing ever removes them. Each is billed at $0.022/GB-month
until a person deletes it. Log groups are bounded at 30 days by default;
snapshots are bounded by nothing.

**Standard storage has no ceiling on I/O.** At 100 million requests a month
it is $20; a missing index on a hot table makes it whatever it makes it. Past
roughly 770 million requests a month on this shape, I/O-Optimized is cheaper
(§4a).

---

## 2. What is billable

| Line | Billed | Note |
|---|---|---|
| **Instances** | per instance-hour, creation → deletion | Every key in `instances`, plus every autoscaled reader. A stopped cluster stops instance billing for at most 7 days, then AWS starts it again |
| Serverless v2 capacity | per ACU-hour, between `min_capacity` and `max_capacity` | Zero only when `min_capacity = 0` and the instance has paused |
| **Cluster storage** | per GB-month of the volume | One volume, billed once however many instances read it |
| **I/O** | per million requests | Standard storage only. No ceiling |
| Backup storage | per GB-month beyond the cluster's size | Retention up to the volume's size is free |
| **Final snapshots** | per GB-month, after the cluster is gone | No free allowance without a cluster. Until someone deletes them |
| **Extended Support** | per vCPU-hour, or ACU-hour | Only on a major past end of standard support, and only if enabled |
| Performance Insights beyond 7 days | per vCPU-hour, by months retained | 7 days free (the default) |
| Database Insights advanced | per vCPU-hour, or ACU-hour | `database_insights_mode = "advanced"` |
| RDS Proxy | per vCPU-hour of the cluster's instances | Minimum 2 vCPU; per ACU-hour on Serverless v2 |
| Backtrack | per million change records stored, per hour | aurora-mysql only |
| Activity streams | the Kinesis stream AWS creates, plus KMS | The consumer is yours |
| Global database | replicated write I/O, and the secondary's own instances and storage | A full copy, billed in the other region |
| Data API | per request | `enable_data_api` |
| CloudWatch Logs | per GB ingested, per GB-month stored | Exports, and Enhanced Monitoring into `RDSOSMetrics` |
| CloudWatch alarms | per alarm-month | 8 on a two-instance aurora-postgresql cluster at defaults; 4 on a one-instance global secondary; none with `create_alarms = false` |
| Secrets Manager | per secret-month | The RDS-managed master secret. None on a global database member, which uses `master_password` |
| Event subscriptions, IAM roles, parameter groups, subnet group, security groups | $0 | SNS delivery is the topic owner's |

---

## 3. Rates (London, live)

Aurora PostgreSQL and Aurora MySQL are priced identically in eu-west-2 for
every line below.

| Line | Unit | Standard | I/O-Optimized |
|---|---|---:|---:|
| `db.t4g.medium` | instance-hour | $0.082 | $0.107 |
| `db.t4g.large` | instance-hour | $0.164 | $0.213 |
| `db.r7g.large` | instance-hour | $0.323 | $0.420 |
| `db.r7g.xlarge` | instance-hour | $0.646 | $0.840 |
| `db.r7g.2xlarge` | instance-hour | $1.293 | $1.681 |
| `db.r8g.large` | instance-hour | $0.323 | $0.420 |
| `db.r8g.xlarge` | instance-hour | $0.646 | $0.840 |
| `db.r8g.2xlarge` | instance-hour | $1.292 | $1.680 |
| Serverless v2 | ACU-hour | $0.14 | $0.19 |
| Cluster storage | GB-month | $0.10 | $0.225 |
| I/O | million requests | $0.20 | $0 |
| Burstable CPU credits (`db.t*` surplus) | vCPU-hour | $0.09 | $0.09 |

| Line | Unit | eu-west-2 |
|---|---|---:|
| Backup storage beyond the free allowance | GB-month | $0.022 |
| Snapshot export to S3 | GB | $0.012 |
| Backtrack | million change records × hour | $0.014 |
| Global database replicated write I/O | million | $0.20 |
| Data API | million requests (first billion) | $0.397 |
| **Extended Support, provisioned, years 1–2** | vCPU-hour | **$0.118** |
| **Extended Support, provisioned, year 3** | vCPU-hour | **$0.235** |
| Extended Support, Serverless v2, years 1–2 | ACU-hour | $0.100 |
| Extended Support, Serverless v2, year 3 | ACU-hour | $0.200 |
| Database Insights advanced | vCPU-hour / ACU-hour | $0.0125 / $0.003125 |
| Performance Insights retention, first month beyond the free 7 days* | vCPU-hour | $0.002405 |
| Performance Insights retention, each further month* | vCPU-hour | $0.000101 |
| RDS Proxy | vCPU-hour of the instances | $0.017 |
| RDS Proxy on Serverless v2 | ACU-hour | $0.018 |
| CloudWatch alarm, standard resolution | alarm-month | $0.10 |
| CloudWatch alarm on a Metrics Insights query (the RPO alarm) | metric analysed, per month | $0.10 |
| CloudWatch Logs ingestion, standard class | GB | $0.5985 |
| CloudWatch Logs ingestion, Infrequent Access class (`log_group_class`) | GB | $0.299 |
| CloudWatch Logs storage | GB-month | $0.0315 |
| Secrets Manager secret | secret-month | $0.40 |
| Secrets Manager API | 10,000 requests | $0.05 |
| Kinesis provisioned shard | shard-hour | $0.0179 |
| Kinesis PUT payload units | million | $0.0173 |
| Interface VPC endpoint | endpoint-hour per AZ | $0.011 |
| VPC endpoint data processed | GB | $0.01 |
| KMS customer-managed key | key-month | $1.00 |
| KMS requests | 10,000 | $0.03 |
| Cross-AZ transfer | GB, each way | $0.01 |
| Transfer to eu-west-1 | GB | $0.02 |

\* The "Database Insights (Standard Mode)" first-month and additional-month
retention SKUs, read as the price of Performance Insights history beyond 7
days. See the note at the top.

The provisioned Extended Support SKUs published for London today cover Aurora
PostgreSQL 11–13 and Aurora MySQL 2, all at the same rate; this document
assumes the next major to leave standard support is priced the same.

---

## 4. Three shapes, costed

### 4a. The defaults: two db.r7g.large

aurora-postgresql 17.9 at the module defaults — two instances, standard storage,
7-day backups, Performance Insights at 7 days, Enhanced Monitoring every 60 s,
no log exports — plus `sns_topic_arn`, so the eight alarms exist. Assumed: 100
GB on the volume, 100 million I/O requests a month (about 38 a second), backups
inside the free allowance, ~0.2 GB of Enhanced Monitoring per instance-month.

| Line | Arithmetic | Monthly |
|---|---|---:|
| Instances | 2 × 730 h × $0.323 | $471.58 |
| Storage | 100 GB × $0.10 | $10.00 |
| I/O | 100 M × $0.20 | $20.00 |
| Backup storage | 7 days of change, inside 100 GB free | $0.00 |
| Performance Insights | 7 days | $0.00 |
| Enhanced Monitoring | 2 × 0.2 GB × $0.5985 | $0.24 |
| Alarms | 8 × $0.10 | $0.80 |
| Master secret | 1 × $0.40 | $0.40 |
| **Total** | | **$503.02** |
| **Annual** | × 12 | **$6,036.24** |

Exporting the `postgresql` log, as the quick start does, adds about $1.26 a
month at an assumed 2 GB: 2 × $0.5985 ingested, plus 2 GB × $0.0315 held for
the 30-day retention.

**Standard or I/O-Optimized.** I/O-Optimized is 2 × 730 × $0.420 = $613.20 for
the instances plus 100 × $0.225 = $22.50 for storage: **$635.70 whatever the
I/O**. Standard is $481.58 plus the I/O. They cross at $154.12 of I/O — **770.6
million requests a month, about 293 a second** — where I/O is 24% of the
I/O-Optimized bill, which is AWS's own rule of thumb of about a quarter.

| I/O a month | Standard | I/O-Optimized | Cheaper |
|---:|---:|---:|---|
| 100 M | $501.58 | $635.70 | Standard, by $134.12 |
| 500 M | $581.58 | $635.70 | Standard, by $54.12 |
| 770.6 M | $635.70 | $635.70 | Break-even |
| 1,000 M | $681.58 | $635.70 | I/O-Optimized, by $45.88 |
| 2,000 M | $881.58 | $635.70 | I/O-Optimized, by $245.88 |

The $1.44 of monitoring, alarms and secret is the same on both and left out.
Your own number is the month's sum of `VolumeReadIOPs` and `VolumeWriteIOPs`
(§8). AWS allows a switch to I/O-Optimized once every 30 days.

### 4b. Dev: Serverless v2 that pauses

The `serverless-v2-dev` example: one `db.serverless` instance, 0–4 ACU, pausing
after 1,800 idle seconds, alarms and event subscriptions switched off. Assumed: 22 working days ×
10 hours at an average of 1 ACU, a 30-minute idle tail each day at 0.5 ACU
before it pauses (the running floor with `min_capacity = 0` is **verify**), paused
otherwise; 20 GB, 10 million I/O.

| Line | Arithmetic | Monthly |
|---|---|---:|
| Compute | (220 h × 1.0 + 22 × 0.5 h × 0.5) = 225.5 ACU-h × $0.14 | $31.57 |
| Storage | 20 GB × $0.10 — billed while paused | $2.00 |
| I/O | 10 M × $0.20 | $2.00 |
| Master secret | | $0.40 |
| Enhanced Monitoring | ~0.06 GB while running × $0.5985 | $0.04 |
| **Total** | | **$36.01** |

The same developers, other ways:

| Setup | Arithmetic | Monthly |
|---|---|---:|
| **0–4 ACU, pausing** (above) | | **$36.01** |
| 0.5–4 ACU, the module default — never pauses | (730 × 0.5 + 220 × 0.5) = 475 ACU-h × $0.14 + $4.40 | $70.90 |
| One idle connection that never closes | same as the line above: awake at the floor | $70.90 |
| `db.t4g.medium`, always on | 730 × $0.082 + $4.40 | $64.26 |
| A runaway job holding it at `max_capacity` all month | 730 × 4 × $0.14 + $4.40 | $413.20 |

A pause needs zero connections. A CI runner's pool or a monitoring probe that
holds one open turns the first row into the second, silently. `max_capacity`
is the ceiling of the bill, which is why the example keeps it at 4.

### 4c. The defaults, on Extended Support for a year

4a after its major leaves standard support, with
`engine_lifecycle_support = "open-source-rds-extended-support"`:

| Line | Arithmetic | Annual |
|---|---|---:|
| The cluster, as 4a | $503.02 × 12 | $6,036.24 |
| Extended Support, years 1–2 | 2 instances × 2 vCPU × 8,760 h × $0.118 | $4,134.72 |
| **Total, year 1** | | **$10,170.96** |
| Extended Support, year 3 | 4 vCPU × 8,760 h × $0.235 | $8,234.40 |
| **Total, year 3** | | **$14,270.64** |

Extended Support is 73% of the instances' price in years 1–2 and 146% in year
3. Per instance-hour: $0.236 on top of $0.323, then $0.470.

---

## 5. Leaving it running

| Shape | Monthly | 1 year | 3 years |
|---|---:|---:|---:|
| 4a, flat | $503.02 | $6,036 | $18,109 |
| 4a, volume growing 10 GB a month | — | — | $18,739 |
| 4a, on Extended Support from day one | — | $10,171 | **$34,613** |
| 4b, pausing | $36.01 | $432 | $1,296 |
| 4b at the module's 0.5 ACU floor | $70.90 | $851 | $2,552 |

Three years of 4a on Extended Support cost 1.9 times what the cluster alone
does: $16,504 of the $34,613 is Extended Support. The storage-growth row is $990
of storage over 36 months instead of $360 — a line that stays small next to the
instances.

### The lines that grow

| Line | Bounded by | Default |
|---|---|---|
| **Final snapshots** | **Nothing — a person deletes them** | One per deletion. 100 GB is $2.20/month, $26.40/year, for ever |
| Extended Support | A date, and the year-3 step | Disabled |
| Cluster volume | Your data. Current engines shrink it when data is deleted (**verify** for your version) | `alarm_volume_bytes` is the tripwire, off by default |
| Log groups | `log_retention_days` | 30 days |
| Automated backups after a delete | `backup_retention_days` | 7 days (`delete_automated_backups = false`) |
| Performance Insights history | `performance_insights_retention_days` | 7 days, free |

A dev environment destroyed and recreated weekly with the module's default
final snapshot leaves 52 a year. At 20 GB each that is 52 × 20 × $0.022 =
$22.88 a month by the end of year one, $45.76 by the end of year two, and
rising. The dev example sets `skip_final_snapshot = true` for this reason.

---

## 6. What the caller's estate spends because of it

None of this is billed to the module's resources, and most of it lands on
someone else's cost centre.

| Line | Who pays | Arithmetic | Monthly |
|---|---|---|---:|
| `secretsmanager` interface endpoint, 2 AZs — clients fetching the master secret, and the proxy | Network / landing zone | 2 × 730 × $0.011 | $16.06 |
| `rds-data` interface endpoint, 2 AZs — Data API from an isolated VPC | Network | same | $16.06 |
| An endpoint per `cluster_iam_roles` feature (Lambda, Bedrock, …) | Network | same, each | $16.06 |
| Endpoint data processed | Network | $0.01/GB | volume |
| The customer-managed key | Key owner | $1.00 + $0.03 per 10,000 requests | ~$1.00 |
| Secrets Manager API calls from applications | Application | $0.05 per 10,000 | volume |
| Client ↔ database across AZs | Application | $0.01/GB each way | volume |
| SNS delivery of alarms and events | Topic owner | | negligible |
| A global secondary's instances and storage | Database owner, eu-west-1 | e.g. one db.r7g.large at London's rate, 730 × $0.323, as an approximation | ~$236 + a full copy of the storage |
| Global replication | Database owner | $0.20 per million replicated writes; transfer to eu-west-1 at $0.02/GB may also apply (**verify**) | volume |

Sharing one pair of `secretsmanager` endpoints across the landing zone instead
of a dedicated pair per VPC is $192.72 a year saved per pair.

---

## 7. The lines that surprise people

**Extended Support arrives without a change.** The cluster, the code and the
plan are unchanged; the bill rises on the date the major leaves standard
support. `governance.engine_lifecycle_support` is the cluster's actual setting,
not the variable's; check it on every cluster, not just new ones. An adopted
cluster keeps what it was created with, and a cluster restored to a point in
time does not get the module's setting at all (README, "The parts people get wrong"). Either
raises `extended_support_matches_the_setting` at plan time.

**Backtrack bills on write rate × window.** Stored change records are the rate
times the window, charged every hour. 100 records a second with a 24-hour
window holds 8.64 million: $0.121 an hour, **$88.30 a month**. At 1,000 a second
it is **$883.01**; a 72-hour window triples either.

**Logging every statement.** `log_min_duration_statement = 0`, or the MySQL
`general` or `audit` log on a busy cluster: 1,000 statements a second at ~300
bytes is about 780 GB a month — **$466.83 of ingestion**. Those logs also contain
SQL text and parameter values, which makes them a data-classification problem.
`log_group_class = "INFREQUENT_ACCESS"` halves the ingestion — 780 × $0.299 =
$233.22 — at the price of metric filters, subscription filters and Live Tail;
switching an existing group replaces it, and the logs in it.

**Enhanced Monitoring at 1 second** is sixty times the 60-second volume: about
12 GB per instance-month, $7.18 per instance.

**Autoscaled readers** bill like any instance — at `max_capacity = 3` on
db.r7g.large, up to $707.37 a month — and are created by Application Auto
Scaling, not this module. Whether they carry the cluster's tags is **verify**;
if not, they are anonymous in Cost Explorer.

**A proxy bills whether anything connects or not**: $49.64 a month on two
db.r7g.large, minimum 2 vCPU.

**An activity stream is a Kinesis stream.** Two provisioned shards are $26.13
a month and 1.3 billion records another $22.49, before whatever consumes it.
RDS chooses the stream's mode and size (**verify**).

**Database Insights advanced** is $36.50 a month on two db.r7g.large and needs
Performance Insights at 465 days. Performance Insights history alone on the
same cluster: 31 days ≈ $7.02, 465 days ≈ $11.15, 731 days ≈ $13.81 a month (see
the note at the top).

**A restore is a second volume.** Restoring a snapshot or a point in time for an
investigation is a whole new cluster — instances, storage and its own final
snapshot when it is deleted. A `copy-on-write` point-in-time restore shares
pages with its source until they change, and is much cheaper to keep briefly.

**The Serverless v2 floor never sleeps.** `min_capacity = 0.5`, the module
default, is $51.10 a month per instance doing nothing.

---

## 8. Checking this against your own bill

Every resource this module creates carries `ManagedBy = Terraform`,
`Module = aurora` and `DatabaseCluster = <name>`, and snapshots copy them
(`copy_tags_to_snapshot = true`). Activate them as cost allocation tags in the
Billing console first; they apply from activation, not retroactively. The
RDS-managed secret, autoscaled readers and an activity stream's Kinesis stream
are created by AWS, not by this module — look for them in the untagged query.

```bash
# This cluster, this month, by usage type.
aws ce get-cost-and-usage \
  --time-period Start=$(date -u +%Y-%m-01),End=$(date -u +%Y-%m-%d) \
  --granularity MONTHLY --metrics UnblendedCost \
  --filter '{"Tags":{"Key":"DatabaseCluster","Values":["orders"]}}' \
  --group-by Type=DIMENSION,Key=USAGE_TYPE

# Every cluster this module manages, side by side.
aws ce get-cost-and-usage \
  --time-period Start=$(date -u +%Y-%m-01),End=$(date -u +%Y-%m-%d) \
  --granularity MONTHLY --metrics UnblendedCost \
  --filter '{"And":[{"Tags":{"Key":"Module","Values":["aurora"]}},{"Tags":{"Key":"ManagedBy","Values":["Terraform"]}}]}' \
  --group-by Type=TAG,Key=DatabaseCluster

# RDS spend with no DatabaseCluster tag: autoscaled readers, restored copies, orphans.
aws ce get-cost-and-usage \
  --time-period Start=$(date -u +%Y-%m-01),End=$(date -u +%Y-%m-%d) \
  --granularity MONTHLY --metrics UnblendedCost \
  --filter '{"And":[{"Dimensions":{"Key":"SERVICE","Values":["Amazon Relational Database Service"]}},{"Tags":{"Key":"DatabaseCluster","MatchOptions":["ABSENT"]}}]}' \
  --group-by Type=DIMENSION,Key=USAGE_TYPE

# Final snapshots nobody has deleted.
aws rds describe-db-cluster-snapshots --snapshot-type manual \
  --query "DBClusterSnapshots[?contains(DBClusterSnapshotIdentifier,'-final-')].[DBClusterSnapshotIdentifier,SnapshotCreateTime]" \
  --output table

# Which clusters are on Extended Support terms.
aws rds describe-db-clusters \
  --query 'DBClusters[].[DBClusterIdentifier,EngineVersion,EngineLifecycleSupport]' --output table

# Your I/O, to place the cluster on the break-even table in §4a (add the write metric too).
aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name VolumeReadIOPs \
  --dimensions Name=DBClusterIdentifier,Value=orders --statistics Sum --period 86400 \
  --start-time $(date -u -d '30 days ago' +%FT%TZ) --end-time $(date -u +%FT%TZ)

# Re-check any rate in §3.
curl -s https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonRDS/current/eu-west-2/index.json \
  | python3 -c '
import json, sys
d = json.load(sys.stdin); od = d["terms"]["OnDemand"]
for sku, p in d["products"].items():
    a = p["attributes"]
    if "Aurora" in a.get("databaseEngine", "") or "ExtendedSupport" in a.get("usagetype", ""):
        for t in od.get(sku, {}).values():
            for pd in t["priceDimensions"].values():
                print(a.get("usagetype"), pd["pricePerUnit"]["USD"], pd["unit"])
' | sort -u | grep -E 'r7g.large|ServerlessV2|StorageUsage|StorageIOUsage|ExtendedSupport|Proxy'
```

---

## 9. Recommendations, in order of money saved per hour of work

1. **Keep Extended Support off, and find the clusters that have it on.** It is
   the default for new clusters; for adopted ones, read
   `governance.engine_lifecycle_support` or the §8 query. Then put each major
   upgrade on a calendar before the end-of-support date. $4,135 a year per
   two-instance cluster, then $8,234.
2. **Let dev clusters pause.** One input, `min_capacity = 0`: $70.90 → $36.01 a
   month per dev cluster, $418 a year. Then find the connection that keeps one
   awake.
3. **Delete stale final snapshots**, and skip them where the data is disposable.
   One command finds them; each 100 GB is $26.40 a year for ever, and the count
   only grows.
4. **Check the I/O-Optimized break-even** each quarter — one metric query. At
   2,000 million requests a month on 4a, switching saves $2,950 a year; at 100
   million, switching would cost $1,609.
5. **Share the landing zone's Secrets Manager endpoint.** $192.72 a year per
   dedicated pair, and a conversation rather than a change.
6. **Right-size the instance class.** Each step from db.r7g.xlarge to
   db.r7g.large is $2,829 a year per instance — but it needs a load test, which
   is why it is this far down. Reader CPU and freeable-memory alarms are the
   evidence.
7. **Commit once the class is stable.** Reserved instances are not priced here.
8. **Never economise on the cheap lines.** Eight alarms are $0.80 a month,
   Performance Insights at 7 days and Enhanced Monitoring at 60 s are pennies,
   and the second instance is what `cluster_survives_an_az` is about. They are
   the difference between an incident with answers and one without.
