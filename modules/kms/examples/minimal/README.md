# Example: the smallest call

`name` is the only required input. It creates one key, `main`, with alias
`alias/orders-main` and these defaults:

| Setting | Default |
|---|---|
| Kind | `SYMMETRIC_DEFAULT`, `ENCRYPT_DECRYPT` |
| Rotation | on, every 365 days |
| Deletion window | 30 days |
| Access | `iam_delegation = true`: IAM policies in this account grant use, as with the AWS default policy |
| Deployer | the role running the plan, detected through `aws_iam_session_context` |
| Deletion protection | on: only the deployer may schedule deletion or disable the key |

What it shows:

- No `keys` input: the default is `{ main = {} }`.
- No warnings. The organization-perimeter check only fires once a key can be
  reached from outside the account (other accounts, `extra_statements`,
  principals in another account).

What fails in it:

- **Detection needs `iam:GetRole`** on the workspace role. Without it the
  plan fails reading `aws_iam_session_context`. Name the role in `deployers`
  instead. (`detect_deployer = false` alone leaves no deployer: deletion
  protection then denies deletion and disabling to everyone, and a check
  warns.)
- **A different identity planning later**, for example a developer running a
  local plan, shows as a policy change: the detected deployer changes. Name
  the workspace role in `deployers` to pin it.
