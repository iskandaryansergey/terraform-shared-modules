# Reference images

Two images, both of which you must build. The Terraform module supplies
configuration and permissions; it does not supply these.

```bash
# Manager
docker build -f Dockerfile.manager -t "$ECR/gitlab-runner-manager:17.9.0-fargate0.5.5" \
  --build-arg FARGATE_DRIVER_SHA256=<digest> .

# Job
docker build -f Dockerfile.job -t "$ECR/gitlab-runner-job:17.9.0" .

# Push, then pass the DIGESTS (not the tags) to the module.
docker push "$ECR/gitlab-runner-manager:17.9.0-fargate0.5.5"
docker inspect --format='{{index .RepoDigests 0}}' "$ECR/gitlab-runner-manager:17.9.0-fargate0.5.5"
```

## Why the shell lives here and not in Terraform

Everything the containers execute is a reviewed, `shellcheck`-clean file in this
directory. The module passes only base64-encoded configuration and one
Secrets Manager reference through the ECS task definition — it never interpolates
a caller value into a shell command.

That is a deliberate architectural choice, not an accident of packaging. In the
EC2 sibling module the configuration travelled through a shell heredoc inside
`user_data`, and three consecutive adversarial audits each found a new way to
turn a caller-supplied string into executed shell there — the third reaching root
job execution on the manager. Moving the shell into the image removes the
transport, and with it the entire class.

## The two contracts

**Manager** reads `RUNNER_CONFIG_B64`, `RUNNER_FARGATE_CONFIG_B64`,
`RUNNER_CA_PEM_B64`, `RUNNER_TOKEN`, `AWS_REGION`, `AWS_DEFAULT_REGION`. It
decodes the configs to `/etc/gitlab-runner`, substitutes the token via python
stdin (never argv, so it never appears in `ps` or `/proc/*/cmdline`), verifies the
substitution with a quiet `grep -q`, and forwards SIGTERM as SIGQUIT so a
redeploy drains rather than aborting every build.

**Job** must contain a container named exactly **`ci-coordinator`** in the task
definition — the driver injects `SSH_PUBLIC_KEY` only into that name. The
entrypoint fails loudly on an empty key, which the reference images GitLab links
to do not; that omission is why jobs on them hang with no error.

## If you fork the driver

Two defects are worth fixing at the root rather than compensating for:

- `executors/ssh/executor.go` uses `ssh.InsecureIgnoreHostKey()`. The module
  contains this with an SG-to-SG rule, which is genuine but is network-level.
- `cmd/fargate/main.go` accepts `CUSTOM_ENV_FARGATE_TASK_DEFINITION`, `_SUBNET`,
  `_SECURITY_GROUP` and `CUSTOM_ENV_ROLE_ARN`, so CI variables can retarget the
  driver. The module contains this with a narrow `ecs:RunTask` resource list and
  scoped `iam:PassRole`.

Removing the overrides is a few lines and costs you the `FARGATE_TASK_DEFINITION`
feature. Host-key verification is harder, because the host key is baked at image
build time and shared by every task from an image — it needs an entrypoint that
generates a key and reports it out of band.
