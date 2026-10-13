# Example: key policies compiled from a consumer's contract

The key set (`module.kms`) gives its key ARNs to the script runner
(`module.runner`). The runner emits `kms_key_policy_requirements`, the things
it needs from those keys, and the key set compiles them into its policies:

| Runner requirement | Lands in | Principal |
|---|---|---|
| `RootVolume` | `runner` key | `deployer`, resolved to `deployers`, through EC2 (`kms:ViaService`) |
| `RunLogGroup` | `runner` key | `logs.eu-west-2.amazonaws.com`, scoped to the run log group |
| `ScriptsBucket` | `runner` key | the runner's instance role, through S3 |
| `TargetSecrets…` | `secrets` key | the runner's instance role, through Secrets Manager |

`output.coverage` shows each requirement under the key it matched.
`output.policies` shows the compiled statements: `ConsumerRunner<n><sid>`.

There is no dependency cycle:

- The runner depends only on the key ARNs.
- The compiled policy is a separate resource (`aws_kms_key_policy`) that
  depends on the runner's requirements.

What fails in it:

- **The first plan** shows both key policies as known after apply. The
  requirements match on key ARNs that do not exist yet.
- **The `logs` preset is needed on the `runner` key.** CloudWatch Logs checks
  the key when the log group is created, and the runner can be created before
  its own `RunLogGroup` requirement lands in the policy.
