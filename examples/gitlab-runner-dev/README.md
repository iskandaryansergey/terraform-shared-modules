# Dev / sandbox GitLab CI runner fleet

The same module as `../gitlab-runner-production`, tuned for a sandbox: cheap,
quick, and explicit about the corners it cuts.

## What's traded away, and why it's fine here

| Setting | Dev | Production | Why the dev choice is acceptable |
|---|---|---|---|
| `runner_token` | passed as a variable | SSM parameter | token lands in state — fine for a throwaway sandbox token |
| `allow_unpinned_artifacts` | `true` | `false` | you don't want to chase version pins in a sandbox; the manager logs a warning at boot |
| `max_use_count` | `10` | `1` | reusing a worker skips cold boots; the only jobs sharing it are yours |
| `max_instances` | `2` | `20` | a runaway pipeline in dev shouldn't cost real money |
| `create_alarms` | `false` | `true` | you're watching the pipeline, not a dashboard |
| worker size | `t3.medium` | `m6i.xlarge` | small and cheap beats fast here |
| AMI | AL2023 + Docker at boot | baked | slower first job, nothing to build |

Kept the same as production on purpose: **`docker_privileged = false`** (if you
need DinD, give it its own fleet), no public IPs, encrypted volumes, and
scale-to-zero.

## Usage

```bash
terraform init
terraform apply \
  -var vpc_id=vpc-xxxx \
  -var 'private_subnet_ids=["subnet-a","subnet-b"]' \
  -var runner_token=glrt-xxxxxxxx
```

Then check it came up:

```bash
terraform output -json verify | jq -r .find_manager
aws ssm start-session --target i-… --document-name AWS-StartInteractiveCommand \
  --parameters command='sudo cat /var/log/runner-bootstrap.log'
```

## Cost shape

With `idle_count = 0` everywhere, the standing cost is just the `t4g.micro`
manager (a couple of dollars a month). Workers exist only while jobs run.
