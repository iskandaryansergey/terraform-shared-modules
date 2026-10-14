# Example: a locked-down key set

Two keys for cardholder data, with every guardrail on.

| Key | For | Who |
|---|---|---|
| `data` | the database profile: `rds`, `dms`, `backup` | `users` = the application role; every direct call must carry a `tenant` encryption context |
| `ingest` | S3 objects | the ingest role encrypts, the application role decrypts |

What it shows:

- **`iam_delegation = false`.** There is no account-root statement, so an IAM
  policy alone grants nothing. The plan refuses this without a deployer: KMS
  rejects a policy that locks out the principal applying it.
- **The deployer is named, and detection is off.** The plan refuses
  `iam_delegation = false` and `protect_policy` without named deployers: a
  detected deployer is the plan's role, and HCP Terraform may apply as
  another. With separate plan and apply roles, list both.
- **Separation of duties.**
  - `administrators` manage the keys but cannot use them, create grants or
    change the policy.
  - `auditors` read configuration only.
  - `encrypters` and `decrypters` each get one half of the cryptographic
    actions.
- **`service_access = "named"`.** S3 can use `ingest` only for the principals
  named on it. The default, `"account"`, lets any principal in the account
  use a key through its services, as AWS managed keys do.
- **Guardrails:**
  - organization perimeter;
  - direct cryptographic calls only through the VPC endpoint (calls a service
    makes for a caller are exempt);
  - no deletion window under 30 days, for anyone;
  - policy, alias and rotation changes only by the deployer and break-glass.
- **Notifications** include CloudTrail-based events: scheduled deletion,
  disabling, policy changes, alias changes and rotation being turned off.
- **`organization_policy_snippets`** gives an SCP and an RCP that enforce the
  same perimeter at the organization level, for the platform team.

What fails in it:

- **The break-glass role must exist** before the policy names it. KMS refuses
  a policy with an unknown principal.
- **`terraform destroy` resets the policy** to the provider default before it
  schedules the key's deletion. The denies protect a managed key; they do not
  stop its own workspace from destroying it.
- **A client outside the VPC** cannot encrypt or decrypt directly, including a
  developer's laptop. Add its role pattern to
  `guardrails.vpc_endpoint_exempt_principals` when that is intended.
- **`require_encryption_context`** applies to direct calls by `users`,
  `encrypters` and `decrypters`. A service calling for a caller supplies its
  own context, and the `ThroughServices` statement does not require yours.
