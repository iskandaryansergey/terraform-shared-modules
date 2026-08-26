# Production GitLab CI runner fleet

A hardened, autoscaling GitLab runner fleet: a small manager drives a Spot fleet
of single-use EC2 workers that scales to zero when nothing is queued.

Every deviation from the module defaults in `main.tf` is commented with *why*.

## What this demonstrates

| Concern | How it's handled |
|---|---|
| **Token never in state** | written to SSM SecureString out of band; the module only reads it |
| **Supply chain** | gitlab-runner + fleeting plugin pinned; plugin checksum verified; baked AMIs so nothing is fetched at boot |
| **Isolation** | `docker_privileged = false`, one job per VM, worker destroyed after every job, IMDS hop-limit 1 |
| **Least privilege** | worker role gets only what jobs need; all fleet control stays on the manager; permissions boundary on both |
| **Encryption** | a CMK with a key policy naming only the fleet roles + the Auto Scaling service principal (needed for EBS) |
| **Network** | no public IPs, worker egress excludes RFC1918, S3 + SSM VPC endpoints keep traffic off NAT |
| **Observability** | bootstrap-failure, manager-unhealthy and fleet-at-capacity alarms wired to a real SNS topic; 90-day logs |
| **Cost** | Spot-first with a 1-instance on-demand floor, warm pool only in working hours, scale to zero otherwise, hard `max_instances` ceiling |
| **Performance** | baked AMI + `instance_ready_command` + an S3 distributed cache (essential with single-use workers) |

## Prerequisites

1. A VPC with **three private subnets** and egress (NAT and/or endpoints).
2. A **runner created in GitLab** (Settings → CI/CD → Runners → New runner) — set
   its tags, protected flag and `run_untagged` there; they're GitLab-side
   properties, not Terraform ones.
3. The `glrt-` token written to SSM as a SecureString.
4. **Baked AMIs** for worker and manager (Docker + sshd + SSM agent).
5. A permissions boundary policy and an SNS topic that pages someone.

```bash
cp terraform.tfvars.example terraform.tfvars   # then edit
terraform init
terraform plan      # review `config_toml` and `manager_policy_statements`
terraform apply
```

## After apply

```bash
terraform output -json verify_commands | jq -r .find_manager   # get the instance id
# bootstrap log / runner status, over SSM - no SSH, no bastion:
aws ssm start-session --target i-… --document-name AWS-StartInteractiveCommand \
  --parameters command='sudo cat /var/log/runner-bootstrap.log'
```

Then confirm the runner shows **online** in GitLab, and push a pipeline.

## Deliberate trade-offs

- **`max_use_count = 1`** costs a boot per job. That's the price of never sharing
  a kernel between jobs; the baked AMI and the S3 cache are what make it cheap.
- **`on_demand_base_capacity = 1`** costs one always-on instance during the warm
  window, and buys you CI that degrades instead of stopping in a Spot crunch.
- **`manager_instance_refresh = true`** is only safe here *because* the manager
  AMI is pinned — otherwise an unrelated apply could replace the manager and kill
  in-flight jobs.
- **Worker egress excludes RFC1918.** If your jobs must reach internal services,
  add just those CIDRs to `worker_egress_cidrs` rather than reverting to
  `0.0.0.0/0`.

## Compared with the dev example

`../gitlab-runner-dev` is the same module tuned the other way: unpinned artifacts,
worker reuse, no alarms, tiny ceiling, token straight from a variable. Read the two
side by side — the diff *is* the production checklist.
