# Rolling a fleet onto a new image, and back off it

This module produces images. It does not own the things that launch them — no
launch templates, no ASGs, no ECS capacity providers. That boundary is
deliberate, but it leaves the question every consumer asks second:

**How does a running fleet move onto a new AMI, and how do I get it back?**

That is what this document answers. There is a runnable version in
[`examples/rollout-asg/`](examples/rollout-asg/).

---

## 1. Three ways to consume the image, and what each costs you

| | How the fleet learns about a new AMI | Rollout happens | Rollback lever | ASG auto-rollback |
|---|---|---|---|---|
| **A. `resolve:ssm:` in the launch template** | At *instance launch*, from the SSM parameter | On the next instance replacement — scale-out, health check, or an instance refresh you start | Write a known-good AMI id somewhere the fleet reads | **No** (see §3) |
| **B. Terraform reads the parameter at plan time** | On your next `terraform apply` | Deliberately, when a human runs apply | Pin the id, or revert the commit | Yes |
| **C. Module rewrites the launch template** (`update_launch_template_ids`) | Immediately after a successful build, as a new LT version | On the next replacement, if the ASG tracks `$Latest`/`$Default` | Revert the LT default version | Yes |

Pick by **what the instance holds**, not by taste:

- **Ephemeral workers** — CI runners, batch consumers, anything replaced hourly
  anyway: **A**. New images arrive with no Terraform in the path, which is the
  entire point of a scheduled pipeline.
- **Stateful or singleton instances** — a GitLab runner *manager*, a bastion, a
  license server: **B**. Replacing the instance that holds a registration should
  be a deliberate act, not something a 03:00 cron decides.
- **C** is A's automation with B's coupling: the pipeline changes your fleet's
  desired configuration directly. Correct for a fleet you want moved without
  asking, and a genuine surprise for anything else.

The module gives you A and B for free: `ami_launch_template_reference` is the
paste-ready `resolve:ssm:` string, and `ami_ssm_parameter_name` is what a
`data "aws_ssm_parameter"` reads.

---

## 2. The trap in mode A: the pipeline owns that parameter

`ami_ssm_parameter_name` is written **by Image Builder, after every successful
build**. So the obvious rollback — put yesterday's AMI id back in the parameter —
works until the next build overwrites it. On a nightly pipeline that is a
rollback with a shelf life of one day, and nobody is watching at 03:00.

There are three ways out, in ascending order of how much you should trust them:

**Disable the pipeline while you are rolled back.**
`pipeline_status = "DISABLED"` (or a console toggle for the duration). Honest,
crude, and it stops your patching cadence for as long as you forget about it.

**Pin the consumer instead of the parameter.** Put a literal AMI id in the
launch template and apply. The pipeline keeps building, the fleet ignores it.
This is what [`examples/rollout-asg/`](examples/rollout-asg/) does with its
`pinned_ami_id` variable, and it is the right answer for an incident.

**Two parameters, with a promotion step.** The recommended shape for a regulated
estate:

```
Image Builder writes  →  /ami/<name>/latest     (pipeline-owned, moves on its own)
Your fleet reads      →  /ami/<name>/current    (human-owned, moves when promoted)
```

Promotion is a deliberate copy, and rollback is the same operation with an older
id:

```bash
# Promote what the pipeline just built.
aws ssm put-parameter --name /ami/<name>/current --type String --overwrite \
  --value "$(aws ssm get-parameter --name /ami/<name>/latest \
              --query Parameter.Value --output text)"

# Roll back to a specific known-good image.
aws ssm put-parameter --name /ami/<name>/current --type String --overwrite \
  --value ami-0123456789abcdef0
```

Nothing overwrites `/current` behind you, the pipeline never stops, and the
promotion is an auditable event with a principal attached to it. The cost is one
extra parameter and one deliberate step — which is the step you wanted anyway.

---

## 3. `auto_rollback` does not do what you want in mode A

An ASG instance refresh can roll itself back on failure
(`preferences { auto_rollback = true }`), and it rolls back to the group's
**previous desired configuration** — in practice, the previous launch template
version.

In mode A the launch template never changes. The AMI moved *underneath* an
unchanged `resolve:ssm:` reference, so there is no previous version to return to
and auto-rollback has nothing to do. You get zero-Terraform rollout and you
forfeit the automatic safety net.

That is the real trade-off between A and C, and it is worth stating in a design
review:

| | Rollout needs a Terraform run | ASG can auto-roll-back | Pipeline can change the fleet unattended |
|---|---|---|---|
| A — `resolve:ssm:` | No | **No** | Yes, on the next replacement |
| B — Terraform reads SSM | Yes | Yes | No |
| C — LT rewrite | No | Yes | Yes, immediately |

If you want both unattended rollout *and* auto-rollback, use C with
`set_launch_template_default_version = true` and accept that a green build is
now a fleet change.

---

## 4. Your rollback depth is a retention setting

You cannot roll back to an image that has been deleted. So the retention knobs
in this module are not only a cost control — they set **how far back you can
recover**, and they deserve to be chosen with that in mind.

| Setting | Default | What it means for rollback |
|---|---|---|
| `lifecycle_deprecate_after_days` | 30 | **Nothing.** A deprecated AMI still launches. It only drops out of default listings, so `resolve:ssm:` and a pinned id both keep working |
| `lifecycle_delete_after_days` | 365 | **The hard limit.** Past this the image and its snapshots are gone and the rollback is a rebuild |
| `lifecycle_retain_at_least` | 3 | **The floor.** At least this many newest images survive whatever the age rules say, so this is your guaranteed rollback depth in images |
| `lifecycle_exclude_recently_launched_days` | 30 | Protects anything the fleet actually launched recently — including the version you just rolled back to |
| `lifecycle_exclude_tags` | `{}` | **The break-glass.** Tag an approved image and the policy never touches it, at any age |

`governance.rollback_depth_images` reports the floor, so a change review can see
it without reading the policy.

Two practical consequences:

1. **Set `lifecycle_delete_after_days` from your rollback window, not from a
   feeling about audit.** If the honest answer to "how far back would we ever
   roll?" is two months, 90 days is the setting — and it is
   [~$59,000 cheaper over five years](COSTS.md#5-snapshot-storage--the-line-that-matters)
   than leaving deletion off on an aggressive pipeline.
2. **Tag the image you are running in production.** Set
   `lifecycle_exclude_tags = { Retain = "true" }` on the module, then tag the
   specific AMI when you promote it. That image now survives every age rule,
   which is exactly what "known good" should mean.

---

## 5. Runbook

### Which image is this instance running, and where did it come from?

```bash
# The AMI a running instance was launched from.
aws ec2 describe-instances --instance-ids i-0123456789abcdef0 \
  --query 'Reservations[].Instances[].ImageId' --output text

# What went into that AMI: the recipe and the exact recipe version.
aws ec2 describe-images --image-ids ami-0123456789abcdef0 \
  --query 'Images[].Tags[?Key==`SourceRecipe`||Key==`SourceRecipeVersion`]'
```

`SourceRecipeVersion` ties the running instance back to a recipe version, and the
module's `component_versions` output ties that to the exact component versions —
which is the chain a change record needs.

### Roll forward

```bash
# 1. What is available, newest first.
aws imagebuilder list-image-pipeline-images --image-pipeline-arn <pipeline_arn> \
  --query 'reverse(sort_by(imageSummaryList,&dateCreated))[*].[version,state.status,dateCreated]' \
  --output table

# 2. Promote (two-parameter pattern), or apply (Terraform-read).
# 3. Replace the fleet. Nothing in the LT changed, so this is the trigger:
aws autoscaling start-instance-refresh --auto-scaling-group-name <asg> \
  --preferences '{"MinHealthyPercentage":90,"InstanceWarmup":300}'

# 4. Watch it.
aws autoscaling describe-instance-refreshes --auto-scaling-group-name <asg> \
  --query 'InstanceRefreshes[0].[Status,PercentageComplete,StatusReason]'
```

### Roll back a `resolve:ssm:` fleet

```bash
# Find a known-good image, with dates.
aws ec2 describe-images --owners self \
  --filters Name=tag:SourceRecipe,Values=<name> \
  --query 'reverse(sort_by(Images,&CreationDate))[*].[ImageId,CreationDate,Name]' \
  --output table

# Protect it from the lifecycle policy before you depend on it.
aws ec2 create-tags --resources ami-0123456789abcdef0 --tags Key=Retain,Value=true

# Then either promote the old id to /current, or pin it in the launch template
# and apply. Do NOT write it to the pipeline's own parameter and walk away.
aws autoscaling start-instance-refresh --auto-scaling-group-name <asg>
```

### Roll back an LT-rewrite fleet (mode C)

```bash
# The versions the pipeline created, newest last.
aws ec2 describe-launch-template-versions --launch-template-id lt-0123456789abcdef0 \
  --query 'LaunchTemplateVersions[*].[VersionNumber,LaunchTemplateData.ImageId,CreateTime]' \
  --output table

# Point the default back at the good one; new launches follow immediately.
aws ec2 modify-launch-template --launch-template-id lt-0123456789abcdef0 \
  --default-version 7

aws autoscaling start-instance-refresh --auto-scaling-group-name <asg>
```

### Stop the bleeding first

If a bad image is being handed out while you work, disable the pipeline before
anything else — it costs nothing and buys you the afternoon:

```bash
aws imagebuilder update-image-pipeline --image-pipeline-arn <pipeline_arn> --status DISABLED
```

Remember to put it back. A pipeline left DISABLED is a patching baseline that
stopped patching, which is the failure this module's
`check "the_schedule_can_actually_fire"` exists to make visible in the other
direction.

---

## 6. What good looks like

**Ephemeral workers.** Mode A. `ami_ssm_parameter_name` set, launch template on
`resolve:ssm:`, instance refresh started by CI (or by a human) after promotion.
Rollback is a pin. Keep `lifecycle_retain_at_least` at 3 or more so a pin always
has something to point at.

**Managers and singletons.** Mode B. Terraform reads the parameter, the fleet
moves on apply, and the replacement of a registered instance is a reviewed
change. This is what [`examples/gitlab-runner-manager/`](examples/gitlab-runner-manager/)
documents at the bottom of its file.

**Regulated estate.** Mode B or the two-parameter promotion from §2, plus
`lifecycle_exclude_tags = { Retain = "true" }` and a `Retain` tag applied at
promotion time. The approved image then survives retention by policy rather than
by luck, and `governance` reports the whole posture as data for the change
record.

**Never:** an unpinned parent image feeding an unattended mode-C rollout. That
chain has no point at which a human sees what changed — the base moved, the
image rebuilt, the launch template updated, the fleet replaced. The module
refuses the first link by default (`allow_unpinned_parent_image = false`), and
that default is load bearing for this reason as much as for reproducibility.
