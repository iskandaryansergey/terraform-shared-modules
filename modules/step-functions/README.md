# terraform-aws-step-functions

One AWS Step Functions state machine and everything around it: an execution
role built from the integrations it calls, logging to a bounded log group,
optional customer-managed encryption and X-Ray, published versions and
aliases, EventBridge Scheduler schedules and EventBridge rules that start
executions, and alarms.

You list what the definition calls; the module grants exactly what AWS
documents for each integration, on exactly those ARNs, and a check compares
that list with the ARNs written in the definition.

```hcl
module "orders" {
  source  = "app.terraform.io/CTO/step-functions/aws"
  version = "~> 0.1"

  name       = "orders"
  definition = templatefile("${path.module}/orders.asl.json.tftpl", { reserve_fn = var.reserve_fn })

  integrations = {
    lambda_functions = [var.reserve_fn]
    sqs_queues       = [var.orders_queue_arn]
  }

  alarms = { enabled = true, sns_topic_arn = var.alerts_topic_arn }
}
```

`name` and `definition` are required. Everything else is optional.

## Requirements

| | |
|---|---|
| Terraform | `>= 1.9.0` (HCP Terraform workspace: Terraform version setting) |
| `hashicorp/aws` | `>= 5.90.0, < 7.0.0`: both majors, tested on 5.100.0 and 6.x |
| The workspace's role | `states:ValidateStateMachineDefinition`: the provider sends the definition to AWS during **every plan**. `output.deployer_requirements` lists this and the rest |

## What it refuses at plan

| Refused | Why |
|---|---|
| A definition that is not JSON with `StartAt` and `States`, or over 1 MB | AWS's limits; the provider's plan-time validation then checks the ASL itself |
| EXPRESS with a `.sync` or `.waitForTaskToken` integration, or with a Distributed Map | Express supports request-response only, and Distributed Map is Standard only |
| An alias on `"current"` without `publish`; routing that is not one or two distinct versions with weights summing to 100 | AWS's alias rules |
| A schedule or rule on an alias that is not declared | A typo would otherwise start executions nowhere |
| `role.statements` granting `*` on `*`; statements or managed policies with a brought role; inline policies over 10,240 characters | A blanket grant; settings that would be dropped; IAM's limit |
| `ecs_pass_role_arns` without ECS tasks | PassRole for nothing |
| `include_execution_data` with logging `OFF`; a bus given as an ARN; `input_path` with an input template | — |
| `alarms.enabled` without a topic | An alarm that tells nobody |

## Advisory checks

Warnings that do not block the plan; name one in `acknowledged_checks` to
accept it, and the decision is listed in `output.governance`.

| Check | Warns when |
|---|---|
| `failures_reach_someone` | `alarms.enabled` is false |
| `express_executions_leave_a_record` | An EXPRESS machine logs below ERROR: Express keeps no execution history, so failures leave no trace |
| `log_retention_is_bounded` | The module's log group keeps logs forever |
| `execution_data_is_logged_deliberately` | `include_execution_data` writes every input and output to the logs |
| `the_definition_is_rendered` | The definition contains `${`: a template placeholder that was not rendered |
| `every_arn_in_the_definition_is_granted` | A Lambda, SQS, SNS, DynamoDB, EventBridge or Step Functions ARN in the definition is not in `integrations` or `role.statements`, or a Distributed Map without `distributed_map`: that state fails with AccessDenied at runtime |
| `event_deliveries_are_kept` | A schedule or rule without `dead_letter_arn`: a start that fails its retries is dropped |

The definition checks read the text, so nesting (Parallel, Map) hides
nothing from them; an ARN built at runtime (States.Format, JSONata) is
invisible to them. A definition built from resources in the same root is
unknown at plan, and those checks report "known after apply" there.

## Most-used inputs

The registry's Inputs tab is the reference.

| Input | Default | What it does |
|---|---|---|
| `definition` | — | ASL as JSON; JSONata supported |
| `type` | `STANDARD` | or `EXPRESS` |
| `integrations` | `{}` | What the states call, by service |
| `distributed_map` | `false` | Grants for child executions |
| `role` | module-created | `statements` for anything else; `create = false` + `arn` to bring one |
| `logging` | ERROR, 30 days, no execution data | Level, data, retention, key, brought group |
| `kms_key_arn` | AWS-owned key | Customer-managed encryption of definition and execution data |
| `tracing` | `false` | X-Ray |
| `publish`, `aliases` | `false`, `{}` | Versions and canary routing |
| `schedules` | `{}` | EventBridge Scheduler |
| `event_rules` | `{}` | EventBridge rules |
| `alarms` | off | Failed, timed-out, aborted, throttled, long-running executions |

## Contract outputs

| Output | For |
|---|---|
| `start_execution_policy_json` | Callers' roles: start (and for EXPRESS start synchronously) on the machine - which covers its aliases - describe and stop executions, decrypt under the customer key |
| `deployer_requirements` | The workspace's role: `states:ValidateStateMachineDefinition` (every plan), `iam:PassRole` on the execution role, `states:PublishStateMachineVersion` with `publish`, and `kms:Decrypt` on the customer key (every refresh reads the encrypted definition) |
| `role_requirements` | The owner of a brought role |
| `kms_key_policy_requirements` | Key owners. Contract v2, compiled by [modules/kms](../kms) |
| `governance` | Change reviews and tests: posture as data, including `ungranted_definition_arns` |
| `verify_commands` | CloudShell after an apply |

## How it works

**Execution role** `<name>-<region>-sfn`, trusted by `states.amazonaws.com`
with `aws:SourceArn` = this account's state machines in this region and
`aws:SourceAccount`, as the Step Functions documentation gives it. Its
`module-features` policy:

| Configured | Grant |
|---|---|
| `lambda_functions` | `lambda:InvokeFunction` on each function and `<arn>:*` (an unqualified ARN grants no version or alias) |
| `sqs_queues`, `sns_topics` | `sqs:SendMessage`, `sns:Publish` |
| `dynamodb_read_tables` / `_write_tables` | `GetItem` / `PutItem`, `UpdateItem`, `DeleteItem` |
| `event_buses` | `events:PutEvents` |
| `state_machines` | `states:StartExecution`; `DescribeExecution`, `StopExecution` on their executions; the managed rule `StepFunctionsGetEventsForStepFunctionsExecutionRule` (for `.sync`) |
| `ecs_task_definitions` | `ecs:RunTask` on every revision; `StopTask`, `DescribeTasks` on `*`; the managed rule `StepFunctionsGetEventsForECSTaskRule`; `iam:PassRole` on `ecs_pass_role_arns`, to ECS tasks only |
| `glue_job_runs` | `glue:StartJobRun`, `GetJobRun`, `GetJobRuns`, `BatchStopJobRun` on `*` (Glue has no resource-level permissions) |
| `kms_key_arns` | `kms:Decrypt`, `kms:GenerateDataKey` |
| `distributed_map` | `states:StartExecution` on itself and `states:DescribeExecution` on its executions - AWS's least privilege |
| logging not `OFF` | the ten log delivery actions on `*` (they take no resource) |
| `tracing` | `xray:PutTraceSegments`, `PutTelemetryRecords`, `GetSamplingRules`, `GetSamplingTargets` |
| `kms_key_arn` | `kms:Decrypt`, `kms:GenerateDataKey` with `kms:EncryptionContext:aws:states:stateMachineArn` = this machine; with logging, `kms:GenerateDataKey` for log delivery. No `kms:ViaService`: AWS warns it stops executions |

`role.statements` become a second policy, `definition-calls`.

**Logging.** `/aws/vendedlogs/states/<name>`: the vendedlogs prefix keeps
CloudWatch Logs' resource policy (5,120 characters, shared by every state
machine in the region) from filling up. Default level ERROR without execution
data. The logging and encryption blocks are always written - at `OFF` and
`AWS_OWNED_KEY` when not in use - because the provider sends neither when it
is absent: removing them would leave the old setting running.

**Encryption.** With `kms_key_arn`, Step Functions encrypts the definition
and execution data with it. The key policy needs the execution role, the
deployer, the callers that read executions, and, with logging,
`delivery.logs.amazonaws.com` - all in `kms_key_policy_requirements`.

**Versions and aliases.** With `publish`, each change publishes a version;
an alias on `"current"` follows it, and a second routing entry makes a
canary. Schedules and rules can start executions on an alias.

**Triggers.** Schedules use EventBridge Scheduler's default group, with a
role trusted by that group only. Rules get a role trusted only for their own
rule ARNs (`aws:SourceArn`, as EventBridge documents for rule targets). Each
role may start only this state machine. Step Functions authorises a start on
an alias against the unqualified ARN, so a role whose triggers all name
aliases is granted the unqualified ARN with `states:StateMachineQualifier`
holding it to those aliases; a grant on the alias ARN would never match.

**Alarms** on `StateMachineArn`, missing data not breaching: failed,
timed-out, aborted and throttled executions, and optionally execution time.

## What replaces what

From the provider source (v5.100.0): `name` and `type` replace the state
machine, and with it its execution history; an alias's `name` replaces the
alias. Definition, role, logging, tracing and encryption change in place.

## Limits

- **Never applied against real AWS.** Verified with `terraform test` against
  a mocked provider on aws 5.100.0 and 6.69, the provider schema and source,
  and the AWS documentation. The mock does not run AWS's definition
  validation.
- **Terraform 1.9.8 is not run locally**; CI runs it.
- **Integrations not listed** (aws-sdk, HTTP tasks, Bedrock, Batch, Athena,
  SageMaker, ...) go in `role.statements`.
- **The ARN check reads literal ARNs only.** Resources named by URL (SQS
  `QueueUrl`), by name (DynamoDB `TableName`) or built at runtime are not
  compared.
- **Schedules use the default schedule group**; rules use buses in this
  account.
- **Old versions are not pruned** (1000 per state machine).

## Versioning and support

Semantic versioning, tagged `vX.Y.Z` on the module's repository, which the
HCP Terraform private registry publishes as
`app.terraform.io/CTO/step-functions/aws`. The module stays at 0.x until its
first live apply confirms the items under "Limits"; while it is, a minor
release may change a default and says so under **BREAKING**. From 1.0.0 a
major release is anything that changes what an unchanged configuration
plans.

Tests: `tests/core.tftest.hcl` (role, integrations, definition checks,
Express, logging, encryption, aliases, contracts), `tests/triggers.tftest.hcl`
(schedules, rules), `tests/same_root.tftest.hcl` (resources created next to
the module, unknown at plan) and `tests/examples.tftest.hcl` (every example
plans without a warning), 43 runs; `tests/lint_validations.py`.

| Document | Question |
|---|---|
| [COSTS.md](COSTS.md) | What it costs, and which line has no ceiling |
| [CHANGELOG.md](CHANGELOG.md) | What changed in each version |
| [examples/order-workflow](examples/order-workflow) | A templated STANDARD workflow with retries and compensation |
| [examples/express-event-processor](examples/express-event-processor) | EXPRESS, JSONata, started by an EventBridge rule |
| [examples/released-with-aliases](examples/released-with-aliases) | Customer key, ECS `.sync`, an alias started on a schedule |
