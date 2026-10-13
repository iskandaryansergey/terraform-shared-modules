# Example: a workload's key set

Two keys in one call:

| Key | For | Presets |
|---|---|---|
| `data` | RDS storage and Secrets Manager secrets, used by the application role | `rds`, `secretsmanager` |
| `logs` | CloudWatch Logs log groups, and an SNS topic that CloudWatch alarms publish to | `logs` (from `purpose = "logs"`), `cloudwatch-to-sns` |

What it shows:

- `providers = { aws = aws, aws.replica = aws }`: the module always takes a
  replica provider. When nothing replicates, pass the default one.
- The deploying role is named in `deployers`. It gets the administrator
  actions, which lets the next apply change the policy. It is also exempt from
  deletion protection, so `terraform destroy` still works.
- `guardrails.organization_id` denies use of the keys by any principal outside
  the organization. AWS service principals are exempt.
- `purpose = "logs"` brings the `logs` preset. `services` adds to what the
  purpose brings; it does not replace it.
- `notifications` sends the native KMS events to the security topic: a
  deletion that completes, a rotation, imported key material expiring. They
  need no CloudTrail trail. The topic's access policy must contain
  `output.sns_topic_policy_requirement`.

What fails in it:

- **The first plan** shows the key policies as known after apply. Later plans
  show the diff.
- **Native events do not cover who scheduled a deletion** or changed the
  policy. Those are the CloudTrail-based events (`schedule_deletion`,
  `policy_change`, ...); add them to `notifications.events` when the account
  has a trail. The `strict` example does.
