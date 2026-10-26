# terraform-aws-step-functions — what a state machine costs

| | |
|---|---|
| Region | eu-west-2 (London); us-east-1 is similar or a little lower |
| Currency | USD |
| Pricing date | 2026-10-19 |
| Basis | step-functions 0.1.0, defaults unless stated |

> **Verify before quoting externally.** These are list prices as the author
> knows them, not pulled from the AWS Price List API in this session.

## 1. What is billable

| Line | Unit | Driven by |
|---|---|---|
| **STANDARD state transitions** | per 1,000 (4,000 a month free) | every state entered, every retry |
| **EXPRESS requests and duration** | per million requests; per GB-second, billed in 64 MB steps | executions × memory × duration |
| **CloudWatch Logs** | per GB ingested, per GB-month stored | `logging.level` (ALL logs every transition), `include_execution_data`, `retention_days` |
| The integrations | each service's own price | Lambda, SQS, ECS, ... |
| KMS | per request, after the free tier | `kms_key_arn`, `kms_data_key_reuse_period_seconds` |
| X-Ray | per trace | `tracing` |
| Alarms | per alarm-month | 4, or 5 with `execution_time_threshold_seconds` |
| EventBridge, Scheduler | rules on the default bus are free; Scheduler 14 million a month free | `event_rules`, `schedules` |

## 2. Rates used

| Item | Rate |
|---|---|
| STANDARD | $0.025 per 1,000 state transitions |
| EXPRESS requests | $1.00 per million |
| EXPRESS duration | $0.00001667 per GB-second (first tier) |
| Logs ingestion | $0.57 per GB in London |
| Logs storage | $0.03 per GB-month |
| Alarm | $0.10 per alarm-month |

## 3. Two shapes

**The order workflow** (examples/order-workflow): 6 transitions an order,
200,000 orders a month.

| Line | Arithmetic | Month |
|---|---|---|
| Transitions | (1,200,000 − 4,000) × $0.025 / 1,000 | $29.90 |
| Logs at ERROR | ≈ 0.1 GB × $0.57 | $0.06 |
| Alarms | 4 × $0.10 | $0.40 |
| **Total** | | **≈ $30.36** |

Retries are transitions too: a step retried three times costs four.

**The express classifier** (examples/express-event-processor): 3 million
executions a month, 64 MB, 200 ms each.

| Line | Arithmetic | Month |
|---|---|---|
| Requests | 3 × $1.00 | $3.00 |
| Duration | 3,000,000 × 0.2 s × 0.0625 GB × $0.00001667 | $0.63 |
| Logs at ERROR | ≈ 0.2 GB × $0.57 | $0.11 |
| Alarms | 4 × $0.10 | $0.40 |
| **Total** | | **≈ $4.14** |

The same volume as STANDARD (3 transitions each) would be 9 million
transitions, about $225: high-volume, short workflows belong on EXPRESS.

## 4. The line that grows

**Logs at level ALL with execution data.** ALL writes an event per state
transition; `include_execution_data` adds every input and output. The order
workflow at ALL with data is roughly 1.2 million events of 2 KB, about 2.4
GB a month: $1.37 ingestion, and with `retention_days = 0` storage grows by
$0.07 a month, every month, without end. The default ERROR without data and
30 days bounds it; `log_retention_is_bounded` warns on 0.
