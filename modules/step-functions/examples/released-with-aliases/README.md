# released-with-aliases

A STANDARD workflow that runs an ECS task and waits for it (`.sync`),
encrypted with a customer managed key, published on every change and
started nightly on the `live` alias by EventBridge Scheduler.

- The role gets `ecs:RunTask` on every revision of the task family, the
  managed EventBridge rule `.sync` needs, and `iam:PassRole` on the task's
  two roles, to ECS tasks only.
- Logging at ALL (without execution data) is encrypted with the same key:
  the key owner needs `output.kms_key_policy_requirements` before the first
  apply, including `delivery.logs.amazonaws.com`.
- An alarm fires if a run takes longer than 90 minutes.
