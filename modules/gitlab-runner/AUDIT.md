# Adversarial Production Audit — `modules/gitlab-runner`

**Date:** 2026-08-26 · **Commit:** `eff3502` (branch `feat/gitlab-runner-module`, untagged)
**Method:** four independent auditors, no shared context, each given a distinct remit and told to
verify empirically rather than by inspection. None was permitted to modify the module; all work
happened in scratch copies. Between them they ran Terraform **1.9.8** (the declared floor) and
**1.12.2**, ~40 purpose-written `tftest` probes, 8 distinct render shapes parsed with `tomllib`,
live HTTP/HTTPS origins to test `curl` behaviour, `systemd-analyze verify`, `terraform graph`,
Python `ipaddress` for CIDR arithmetic, and cross-checks against GitLab Runner 17.9 documentation
and the `fleeting-plugin-aws` package docs.

| Track | Remit | Findings |
|---|---|---|
| 1 | Security, IAM, runner isolation, secrets | 17 |
| 2 | Network, compute, bootstrap, supply chain | 22 |
| 3 | Terraform quality, module API, idempotency, destroy | 23 |
| 4 | Runner architecture, reliability, observability, cost, testing | 30 |

Overlap was substantial and is treated as signal: a defect found independently by three tracks is
recorded as such. After deduplication, **61 distinct findings**.

---

## Verdict

`terraform test` — **105 passed, 0 failed**, on both 1.9.8 and 1.12.2. `terraform validate`,
`fmt -check`, `template_safety.py`, `parse_config.py`, `bash -n` and `shellcheck` all pass. All
four gitlab-runner examples validate. Every gate this module owns is currently green.

**The fleet as configured cannot launch a single worker.**

That sentence is the audit. Two independent defects each independently prevent the module from
doing the one thing it exists to do, and both are invisible to every gate:

- The manager never gives `gitlab-runner` an AWS region, so the fleeting plugin's first
  `DescribeAutoScalingGroups` call fails and no worker is ever requested (**P0-1**).
- The default scaling policies are ordered so the always-matching catch-all wins at every instant,
  making the advertised warm pool unreachable dead config (**P0-2**).

Neither is exotic. The first is four lines of `systemd` drop-in. The second is reversing a
two-element list. What matters is *why they survived*: every gate in this module stops at a proxy.
`terraform test` proves the plan is well-formed. `parse_config.py` proves `config.toml` is
structurally valid. `RunnerHealthy` proves a *process* is running. The integration test proves AWS
accepts the launch template — because it sets desired capacity with the AWS CLI *itself*, bypassing
the component under test. Nothing anywhere verifies that a job runs.

And the gates that might have caught them are dead in CI for three unrelated reasons: an untracked
script, an untracked sibling module that aborts the job before it, and a broken unrelated example
that aborts the sweep.

This is not a coding failure. It is a test-architecture failure, and it is the finding that
subsumes the other sixty.

---

## Scores

| Dimension | Score | One-line justification |
|---|---:|---|
| IAM / least privilege | **80** | The strongest dimension. Manager mutation scoped to the exact ASG ARN; no `iam:`/`sts:`/`PassRole` anywhere; `ec2:osuser` + `aws:autoscaling:groupName` conditions are real and unspoofable; omitting `aws:SourceAccount` is the *correct* call for the reason given. |
| Security | **74** | 14 inputs attacked with newlines, quotes, backslashes, `$(...)`, backticks, `;`, `\v`, `\f`, `\r` and the literal heredoc delimiter — **zero** achieved shell execution. Deducted for one real escalation, an absent guard rail, and an unreviewable bootstrap. |
| Secrets management | **71** | Token flow is careful and unbroken: SecureString → stdin (never argv) → placeholder substitution → `unset` → verification, into a file that is `0600` *before* content lands. Deducted because both quick-starts use the cleartext-in-state path. |
| Network security | **68** | The RFC1918 carve-out is *exactly* correct — 30 CIDRs decomposed, complement computed, no gaps. Deducted for CGNAT reachability, VPC-wide DNS, no IPv6 story, unpolicied endpoints. |
| Runner isolation | **68** | Excellent defaults, one fleet-wide one-line escape hatch (`docker_volumes`). |
| Documentation | **55** | Genuinely above-average prose; nearly every *quantitative* claim has drifted, and one headline feature does not exist. |
| Supply chain | **52** | A well-built gate that validates version *strings* while the actual *bytes* arrive unverified. |
| Architecture (runner) | **52** | TOML shape well-researched and largely correct; the missing region makes it non-functional. |
| Observability | **48** | The most sophisticated *reasoning* in the module, applied to a primary signal that measures the wrong thing. |
| Testing | **46** | Real breadth and the right instincts; three CI jobs permanently red, the one runtime gate dormant and booby-trapped. |
| Scalability | **45** | Spot design is strong; `concurrent` reaches 800 on an unmonitored `t4g.small` and user_data is at 79% of its hard limit at defaults. |
| Reliability | **44** | Manager bootstrap failure handling is excellent; nothing reclaims an orphaned fleet. |

---

## P0 — the fleet does not work, or root is reachable

### P0-1 · The manager never gives `gitlab-runner` a region; the plugin cannot scale the fleet
*Track 4 · Critical · verified independently during consolidation*

`[runners.autoscaler.plugin_config]` emits **only** `name` (`templates/config.toml.tftpl:61`). The
two places a region does appear are both dead ends:

- `templates/manager-user-data.sh.tftpl:11` — `export AWS_DEFAULT_REGION` in the *bootstrap shell*.
- `templates/manager-user-data.sh.tftpl:140` — `Environment=` inside the `HBSVC` heredoc, i.e. the
  **heartbeat** unit only.

There is no `systemd` drop-in for `gitlab-runner.service`, no `EnvironmentFile`, no
`/etc/sysconfig/gitlab-runner`. `systemd` starts services with a clean environment, so neither
reaches the runner. `aws-sdk-go-v2` does not include the IMDS region provider in its default chain,
and `fleeting-plugin-aws` exposes **no `region` config key** — so the process environment is the
only supply route, and it is empty. Upstream `fleeting/plugins/aws#27` reports exactly this error
*while running on an EC2 instance*.

The root cause is one sentence of comment. `config.toml.tftpl:59-60` says *"AWS credentials come
from the manager's instance role, so nothing is configured here."* That is true of **credentials**
and silent about **region** — IMDS supplies the former, not the latter.

**Which signals stay green:** `config.toml` is valid; `fleeting install` succeeds;
`systemctl enable/restart` succeeds; the bootstrap reaches `BOOTSTRAP_OK=1` so `BootstrapFailure=0`;
`systemctl is-active` returns active forever so `RunnerHealthy=1`. GitLab shows the runner
**online** — registration long-polls over HTTPS and uses no AWS SDK. All seven alarms report
healthy while zero workers ever launch.

Worse, `tests/parse_config.py:84` asserts
`set(pc.keys()) <= {"name","profile","config_file","credentials_file","scale_in_termination"}` —
the structural linter would **reject** a `region` key in `plugin_config`, actively pointing away
from one of the two possible fixes.

**Fix** (4 lines, before `systemctl enable gitlab-runner`):
```bash
install -d /etc/systemd/system/gitlab-runner.service.d
printf '[Service]\nEnvironment=AWS_REGION=%s\nEnvironment=AWS_DEFAULT_REGION=%s\n' "$R" "$R" \
  > /etc/systemd/system/gitlab-runner.service.d/10-region.conf
systemctl daemon-reload
```
Assert the drop-in in `parse_config.py` (its user-data arm already receives the script). **Verify on
any existing deployment in 60 seconds:** `systemctl show gitlab-runner -p Environment`.

### P0-2 · Scaling-policy ordering is inverted; the advertised warm pool has never existed
*Track 4 · High · verified independently — this one needs no upstream documentation at all*

`variables.tf:209` states the rule: *"evaluated in order — the LAST matching period wins, so put the
catch-all last."* The default (`variables.tf:225-228`) then does exactly that:

```hcl
[ { idle_count = 1, idle_time = "20m0s", periods = ["* 8-18 * * mon-fri"] },
  { idle_count = 0, idle_time = "10m0s", periods = ["* * * * *"] } ]   # matches ALWAYS, and is last
```

The premise and the conclusion contradict each other. If the last *matching* policy wins, and the
last policy matches at every instant, then the weekday warm-pool policy is unreachable and
`idle_count` is permanently **0**. GitLab's own canonical example puts the catch-all **first**, for
this reason. Whichever way upstream behaves, the module cannot be right: either the documented rule
is wrong or the shipped default is.

The claim is load-bearing in three places — `README.md:78` ("one warm worker during weekday working
hours"), `variables.tf:220`, and the "Follow the sun" recipe at `README.md:117`, annotated
`# catch-all LAST`.

**Cost:** every job pays a full cold start — ASG launch (~25 s) + `dnf install docker` over NAT
(~30-60 s) + the readiness poll + image pull ≈ **90-150 s added to every job, forever**. On a
5-minute build that is a 30-50% latency tax. The predictable operator response is to raise
`idle_count`, which also does nothing, and then abandon scale-to-zero — losing the module's actual
cost advantage.

Nothing could catch it: the test at `tests/gitlab-runner.tftest.hcl:184` asserts only that the
substrings `idle_count = 1` and `idle_count = 0` both *appear*, and its error message asserts the
incorrect belief. `parse_config.py` checks `len(policies) >= 1` and per-policy key presence — not
order.

**Fix:** reverse the default, fix the rule text and the recipe, and add one assertion to
`parse_config.py`: when `len(policies) > 1`, the **last** policy's `periods` must not be
`["* * * * *"]`. That single check makes the class unrepeatable.

### P0-3 · `extra_runner_config_toml` can inject a second `[[runners]]` with `executor = "shell"`
*Tracks 1 + 4 · High · reproduced*

The validation at `variables.tf:886` requires the value to begin with a table header — which
correctly closes the bare-key rebinding trap, and which `[[runners]]` satisfies. Reproduced:
`"[[runners]]\n name = \"x\"\n executor = \"shell\"\n token = \"glrt-...\""` passes validation,
renders, and parses to **two runners**. The second executes jobs as **root on the manager** — the
host holding the runner token, `autoscaling:SetDesiredCapacity`, `SetInstanceProtection`,
`TerminateInstanceInAutoScalingGroup` and `ec2-instance-connect:SendSSHPublicKey` for every worker.

The input is documented as trusted, so this is least-surprise rather than a boundary breach — but it
is the third consecutive audit in which this one variable produced a new finding (bare-key
rebinding → heredoc breakout → this), and a second runner's token would sit in plaintext in
`config.toml` *and* in user_data, bypassing the SSM path the module otherwise enforces.

**Fix:** reject `[[runners]]` specifically; assert exactly one runner in `parse_config.py` (it
already does at line 44 — the fixture simply never renders this shape). Strategically: this
variable has now cost three findings, and the correct answer is typed structured inputs rather than
a raw-text hatch.

### P0-4 · `docker_volumes` is entirely unvalidated: one list entry mounts the Docker socket or `/`
*Track 1 · High*

`docker_volumes` has **no validation block**. `["/var/run/docker.sock:/var/run/docker.sock"]` or
`["/:/host"]` gives every job on every worker root-equivalent access to the worker host, fleet-wide.
It sits immediately beside `docker_privileged`, which is guarded with a ten-line justification — so
the heavily-defended door has an unlocked window next to it. This is reachable by the least
privileged actor class in the threat model (anyone who can land a `.gitlab-ci.yml`), because it is
also the mechanism the module documents for caching.

**Fix:** reject host-path mounts of `/`, `/etc`, `/var/run`, `/proc`, `/sys` and any `docker.sock`,
behind an explicit opt-out following the existing `allow_unpinned_artifacts` pattern.

### P0-5 · A BYO AMI silently discards EBS encryption, size and KMS on both tiers
*Track 2 · High · reproduced*

`locals.tf:85-92` resolves the root device as
`coalesce(one(data.aws_ami.al2023_*[*].root_device_name), "/dev/xvda")`, and the AMI data source is
gated `count = local.create && var.*_ami_id == "" ? 1 : 0`. So the moment a caller supplies a BYO
AMI — **the module's own recommended production path** — the data source has count 0, `one([])` is
null, and the expression yields the hardcoded `/dev/xvda`.

If the BYO AMI names its root device anything else (`/dev/sda1` is the norm for Ubuntu, Debian and
RHEL lineages), `block_device_mappings` no longer describes the root volume. `volume_size`, `gp3`,
`throughput`, `iops`, **`encrypted = true`** and **`kms_key_id`** are applied to a device that isn't
the root, and the root launches with whatever the AMI's snapshot specifies — while `terraform plan`
shows `encrypted = true` and an HCL compliance scan passes.

This is precisely the failure the comment at `locals.tf:81-84` says the derivation exists to
prevent. The `coalesce` cannot distinguish "no data source because the caller pinned an AMI" from
"no data source because `create = false`", and answers both with a guess.

**Fix:** resolve the BYO AMI too (a second `aws_ami` with `filter { name = "image-id" }`), or add a
`precondition`: `var.*_ami_id == "" || var.*_root_device_name != ""`. Keep `/dev/xvda` only for the
`create = false` render path.

### P0-6 · `curl -fsSL` follows an https → plaintext-http redirect and executes the result as root
*Track 2 · High · reproduced end-to-end*

The URL grammar at `variables.tf:548` is a genuinely good positive grammar — 28 attack strings, all
rejected (see *What held*). But it constrains the **first hop only**. `-L` follows redirects and
curl's default `--proto-redir` permits plain `http`. Against a local HTTPS origin 302-ing to
`http://…/evil.sh`, the module's exact flag set executed the payload. Adding
`--proto '=https' --proto-redir '=https'` blocked it outright.

The grammar protects what *string* reaches the shell; it says nothing about what *bytes* reach
`bash`. An attacker who can influence one redirect — compromised mirror, hijacked DNS, on-path once
downgraded to cleartext — gets root on the fleet's control plane without needing a certificate.

**Fix:** one line — add `--proto '=https' --proto-redir '=https' --max-redirs 3` to
`templates/manager-user-data.sh.tftpl:163`.

### P0-7 · The pinning gate validates version strings, not artifact integrity
*Track 2 · High*

`allow_unpinned_artifacts` gates exactly two things: that `gitlab_runner_version` and
`fleeting_plugin_version` are non-empty. It does not require `package_repo_script_sha256`, does not
require `fleeting_plugin_sha256`, and does not touch the AMI (`most_recent = true`).

So with the **secure default** and both versions dutifully pinned — the configuration a careful
operator reaches — the rendered bootstrap still contains:

```bash
curl -fsSL --retry 5 'https://packages.gitlab.com/.../script.rpm.sh' -o "$REPO_SCRIPT"
# NOTE: no repo_script_sha256 supplied, so this script is executed as root unverified.
bash "$REPO_SCRIPT"
```

The variable's own description sells the gate as closing this: *"everything the manager fetches runs
as root on every boot, so an unpinned upstream is a standing supply-chain exposure."* A reviewer
checking "is the supply chain pinned?" finds a well-built gate, two pinned versions, and a passing
plan. The residual risk is disclosed only in a comment inside rendered user-data, which nobody
reads.

Combined with P0-6, this is **the worst risk in the module**: it survives the operator doing
everything the module tells them to do, and it recurs on a schedule the module makes routine
(`manager_self_heal = true` + unpinned AMI ⇒ replacements for ordinary reasons). The blast radius is
not the manager — it is arbitrary code execution inside every CI job in the fleet.

**Fix:** extend the one existing condition —
`var.allow_unpinned_artifacts || (versions != "" && both_sha256 != "" && var.manager_ami_id != "")`.
Publish current digests in `examples/` so the strict path is usable, and fix P2-1 first (the
architecture-blind digest) or the strict path punishes whoever tries it.

### P0-8 · The whole `static-analysis` CI job is dead — twice over
*Tracks 1 + 3 + 4 (three independent finds) · High · verified*

`git ls-files` confirms `modules/gitlab-runner/tests/template_safety.py` is **untracked** (not
gitignored — never `git add`ed). `.github/workflows/terraform-ci.yaml:83` invokes it, so on a fresh
checkout `python3` exits 2 and the job aborts, taking the two following gitlab-runner steps with it
(structural lint, and the shellcheck that depends on its output file).

Track 4's follow-up found this is **over-determined**: `terraform-ci.yaml:68-70` does
`cd modules/agent-warden-2/tests/render`, and `git ls-files modules/agent-warden-2` returns **0
tracked files**. The job therefore dies at line 68, *before* reaching line 83. Two independent
untracked-directory breakages each individually prevent every gitlab-runner static gate from
running.

That makes it worse, not better. The job has been red on every push and PR for two unrelated
reasons — the exact condition that trains reviewers to ignore a red check. The module's entire
bespoke quality apparatus (the TOML parser, the interpolation guard, the rendered-script shellcheck)
has never executed in CI. **This is very likely why P0-1, P0-2, P1-2 and P2-6 survived.**

**Fix:** `git add` `modules/gitlab-runner/tests/template_safety.py`, `modules/agent-warden-2/`,
`modules/ci-oidc/`. Then make the class impossible — a guard step asserting every script the
workflow invokes is tracked:
`git ls-files --error-unmatch $(grep -ohE '[\w/.-]+\.py' .github/workflows/*.yaml | sort -u)`.
Split the gitlab-runner steps into their own job so one failure cannot mask the others.

---

## P1 — silent failure, unbounded cost, or a control that cannot work

### P1-1 · `template_safety.py` has five demonstrated bypasses, one of them conceptual
*Track 1 · High*

| # | Bypass | Why it works |
|---|---|---|
| g1 | interpolation on a `#` comment line in a shell template | comment lines are skipped; a newline in the value ends the comment and the rest is live shell |
| g2 | `count("'") % 2` parity | an apostrophe inside a double-quoted string flips parity, declaring an unquoted interpolation safe |
| g3 | bare word between two separately-quoted strings | `before.endswith("'") and after.startswith("'")` accepts it |
| **g4** | `<<TFCFG_${heredoc_nonce}` instead of `<<'TFCFG_…'` | `config_toml` is allow-listed **because** the heredoc is quoted — and the tool never verifies the quoting it relies on. Deleting one apostrophe turns every string in the config into a root-RCE vector with the guard still printing OK |
| g5 | a line starting with `%{ … }` | skipped entirely, though `%{ if x ~}${val}%{ endif ~}` is ordinary template style |

g4 is the important one: an exemption that *assumes* the property justifying it. A control
documented as airtight and demonstrably bypassable is worse than no control, because it stops the
next person looking.

**Status:** a v2 guard closing all five, plus self-tracking and justification-verification, has been
written for the sibling Fargate module at `modules/gitlab-runner-fargate/tests/template_safety.py`
and should be back-ported here.

### P1-2 · `extra_runner_config_toml` cannot extend any table the module emits
*Tracks 3 + 4 · High · reproduced*

TOML forbids redeclaring a table, and the hatch appends at EOF *after* the module has opened
`[runners.docker]`, `[runners.autoscaler]`, `[runners.autoscaler.plugin_config]`,
`[runners.autoscaler.connector_config]`, `[runners.autoscaler.scale_throttle]` and
`[[runners.autoscaler.policy]]`. Reproduced:

```
OK    : new table [runners.cache]
BROKEN: extend [runners.docker] (pull_policy)  -> Cannot declare ('runners','docker') twice
BROKEN: extend [runners.autoscaler]            -> Cannot declare ('runners','autoscaler') twice
```

So the hatch reaches only tables the module never touches — while the variable's description
advertises "custom docker settings", the exact case that hard-fails. Unreachable keys include
`pull_policy` (a supply-chain control), `helper_image` (mandatory for air-gapped GitLab), `shm_size`
(headless browser suites), `update_interval`, and `connector_config.timeout` (hardcoded `5m0s`).

The failure signature is the point: `validate` passes (opaque string), `plan`/`apply` pass, 105
tests pass, `parse_config.py` passes (the fixture only ever renders `[runners.cache]`), and
`manager_instance_refresh = false` means **the running manager keeps working**. Weeks later an AZ
event replaces it, `gitlab-runner` won't start, and the FATAL message says "gitlab-runner did not
start" with no mention of TOML. Five layers of testing, four of them better than industry norm, all
structurally blind.

With 71 inputs, the module is clearly trying to be complete; where it isn't, the escape hatch cannot
reach most of what's missing. **This is the biggest structural flaw.** Fix: per-table hatches
rendered *inside* their tables, plus first-class inputs for the common `[runners.docker]` keys, plus
render-fixture shapes so the parser that already detects this actually sees it.

### P1-3 · `RunnerHealthy` measures process liveness, not job pickup
*Track 4 · High*

The primary signal — the one `README.md:263` calls *"the primary liveness signal"* — is
`systemctl is-active --quiet gitlab-runner`. Every one of these leaves the process active and the
metric at 1: the plugin cannot resolve a region (P0-1); the token was revoked or rotated; GitLab is
unreachable or returns 401/403; EC2/ASG API throttling; the SSH connector fails on every worker; the
manager's root disk is full (P1-8).

Meanwhile `gitlab-runner` already exports the right signals on `:9252` — `gitlab_runner_jobs`,
`gitlab_runner_concurrent`, `gitlab_runner_errors_total`. The module **configures that endpoint and
discards it**: the CloudWatch agent config has no `metrics` block and no Prometheus scrape (verified
by extracting and parsing the rendered JSON: top-level keys `['agent','logs']`), nothing else
scrapes it, and loopback binding means nothing off-host can.

The reasoning in `observability.tf:3-8` about *cadence* — continuous vs discrete, matched
`treat_missing_data` — is genuinely sophisticated and correct. It simply never asks whether the
underlying measurement is a valid proxy for the outcome.

**Fix:** scrape `127.0.0.1:9252` in the existing heartbeat script; publish `RunnerJobsRunning` and a
`JobPickupHealthy` derived from a successful scrape plus a non-stalling request counter. The
namespace condition at `iam.tf:92-98` already covers the extra metric names.

### P1-4 · Nothing reclaims an orphaned fleet, and a code comment claims otherwise
*Tracks 2 + 4 · High*

Two statements in the module contradict each other. `workers.tf:122-124`: *"Backstop: if the manager
dies holding scale-in-protected workers they would otherwise bill forever. AWS retires them at this
age regardless."* `variables.tf:829-833`: *"ASG-initiated replacement respects scale-in protection …
orphaned protected workers left behind by a dead manager are exactly what it cannot reclaim."* The
variable is correct; the code comment — where an engineer looks when deciding whether the risk is
handled — is false.

Worse, the runbook is incomplete. When the manager dies the *live* desired capacity is whatever it
last set (say 40); Terraform's `0` is inert under `ignore_changes`. Clearing scale-in protection
(runbook step 3) does **not** lower desired capacity, and there is no scaling policy to do it — an
ASG *replaces* unprotected instances that terminate. So the documented remedy reclaims nothing, and
`worker_max_lifetime_seconds` converts a static orphan fleet into a *perpetually churning* one at
unchanged cost.

**Cost:** at `max_instances = 200` on `m6i.large` Spot, **$144/day ≈ $1,000/week**; on-demand
~$415/day. With `alarm_sns_topic_arns = []` (the default) nobody is notified at all.

**Fix:** add the load-bearing command to the runbook —
`aws autoscaling set-desired-capacity --auto-scaling-group-name "$ASG" --desired-capacity 0` — and
state that clearing protection alone is insufficient. Delete or invert the `workers.tf` comment. For
real safety, close the loop: EventBridge on the composite alarm → a small Lambda that clears
protection and zeroes desired capacity.

### P1-5 · The S3 endpoint rewrites the VPC's *main* route table, and `endpoint_private_dns` defaults to a VPC-wide DNS override
*Tracks 2 + 3 + 4 · High · reproduced*

Per-subnet route-table resolution is a real improvement, and the endpoint genuinely cannot touch a
table the module's subnets don't use. But when a worker subnet has no explicit association, the
fallback selects the VPC **main** route table — correct for that subnet, and simultaneously shared by
every other implicitly-associated subnet in the VPC. Reproduced: with `aws_route_tables` mocked to
`ids = []`, `aws_vpc_endpoint.s3.route_table_ids` contains the main table. The comment at
`locals.tf:14-16` claims per-subnet resolution "can't over-reach" — true of table *selection*, false
of *effect*.

Compounding it, `endpoint_private_dns` defaults to **`true`**, and its own description states the
consequence: *"this rewrites resolution of ssm/ssmmessages/ec2messages for the ENTIRE VPC, including
instances outside this fleet whose security groups can't reach the endpoints — they would lose SSM.
Set false if you don't own the VPC."* The module says, repeatedly and correctly, that it does not own
the VPC. Both switches default to the VPC-wide behaviour, and the **production example** enables
endpoints while leaving private DNS at its default, with no mention in `main.tf` or its README.

**Consequence:** deploying the production example into a shared landing-zone VPC can break Session
Manager for every unrelated instance in it — discovered during the next incident, when someone needs
emergency access and it silently times out. It is a denial-of-management primitive available to
anyone who can apply this module, with no cross-team review and no signal that anything changed.

**Fix:** flip `endpoint_private_dns` to `false`; set it explicitly in the production example with the
shared-VPC reasoning; add a `precondition` refusing the main route table unless an explicit
`allow_main_route_table_modification` is set; correct the `locals.tf` comment.

### P1-6 · `a1.*` is misclassified by both architecture regexes, and the manager has no coherence check at all
*Tracks 2 + 3 · Medium-High · reproduced two ways*

Both regexes require the `g` to follow the generation digit (`variables.tf:325-331` uses
`^[a-z]+[0-9]+[a-z]*g[a-z]*\.`; `locals.tf:99` uses `^[a-z]+[0-9]+g` — note they *differ*, so the
manager and worker can disagree about the same string). `a1` (Graviton 1) puts nothing after the
digit. Because the worker check is a hard equality, this fails symmetrically: `arm64` + `a1.large`
**rejects a correct config**, and `x86_64` + `a1.large` **is accepted**, resolves an x86_64 AMI, and
fails every launch.

A 34-family sweep found `a1` is the only production miss; every tempting case is handled correctly
(`c8g`/`r8g`/`x8g`/`i8g`/`hpc7g`/`im4gn`/`is4gen`/`x2gd`/`c7gn`/`g5g` → arm64; `g4dn`/`g4ad`/`g6e`/
`p5`/`inf2`/`trn1`/`u7i-12tb`/`m7i-flex`/`m6idn` → x86_64). That is better than expected.

Separately, `manager_instance_type` has **no validation whatsoever**, while its default `t4g.small`
is **arm64**. The auto-AMI path is safe because the arch is derived from the type — but the moment a
caller supplies `manager_ami_id`, which the production checklist *tells them to do*, the derivation
is bypassed and nothing replaces it. The most likely mistake (an x86_64 golden AMI, the common case
in most orgs) is the silent one, and it fails *inside the ASG*, so it appears as scaling activity
errors rather than a Terraform error. This is a first-day-of-production failure whose alarm says "no
in-service instance", not "your AMI is the wrong architecture".

**Fix:** one shared helper — an explicit arm64 family set plus the `g`-suffix regex as
forward-compatible fallback — used by both call sites. Add a `data "aws_ami"` on the supplied AMI
with a `precondition` comparing `.architecture` to the derived arch (catches it at plan time for one
data source). Add `verify_commands.scaling_errors = "aws autoscaling describe-scaling-activities …"`
— the missing diagnostic.

### P1-7 · Workers have no observability at all
*Tracks 2 + 3 + 4 · High*

`worker-user-data.sh.tftpl` is 22 lines: no `trap`, no `put_metric`, no CloudWatch agent, no log
shipping. The worker role has no `logs:*` and no `cloudwatch:PutMetricData`, so it *couldn't* ship
anything. Compare the manager's 268-line bootstrap with an `EXIT` trap, a `BootstrapFailure` metric,
a heartbeat timer, and log shipping installed first.

If `dnf install -y docker` fails — mirror outage, NAT saturation, a narrowed `worker_egress_cidrs`, a
tightened `s3_endpoint_policy_json`, a baked AMI without Docker — the script dies silently. The
instance still passes its EC2 health check and reaches **InService**, so `GroupPendingInstances` stays
~0 and `capacity_shortfall` never fires. `RunnerHealthy` stays 1 (the manager is fine), so
`orphaned_workers` never fires. The readiness gate then fails for 120 s, the plugin destroys the
instance and requests another — **continuous full-fleet churn at 100% cost with 0% throughput**, and
every diagnostic destroyed with its instance. `fleet_at_capacity` may eventually fire, blaming "jobs
queueing or something scaling out of control".

Ephemerality *raises* the need for shipped telemetry, because local state is destroyed by design.

**Fix:** port the manager's pattern — a `trap` publishing `WorkerBootstrapFailure` with
`cloudwatch:PutMetricData` scoped by the same namespace condition already used at `iam.tf:90-98`,
plus one alarm. Ship `/var/log/worker-bootstrap.log` to the existing log group. Add a churn detector
on `GroupTerminatingInstances`.

### P1-8 · `/var/log/gitlab-runner.log` grows without bound on a 20 GB root disk
*Tracks 2 + 4 · Medium-High*

`journalctl -u gitlab-runner -f >> /var/log/gitlab-runner.log` under `Restart=always`, forever. No
logrotate, no `size=`, no `truncate` anywhere in the rendered bootstrap. The
`install -m 0640 /dev/null` truncates only on a fresh user-data execution, and cloud-init's
`scripts-user` runs per-*instance*, not per-boot, so a reboot does not reset it. `log_format = "json"`
makes every line substantially larger, and volume scales with `concurrent` (up to 800 — P2-5).

The journal→file→agent bridge is a sound workaround for the agent's lack of journald support, but it
converted systemd's bounded, self-rotating journal into an unbounded plain file and discarded the
rotation that made it safe.

Worst exactly where the module recommends production settings: a *pinned* AMI plus
`manager_instance_refresh = false` means nothing ever replaces the manager. And when the disk fills,
the process stays up — so `RunnerHealthy = 1` and disk-full joins the silent-failure class.

**Fix:** `/var/log/gitlab-runner.log { size 100M rotate 3 compress copytruncate missingok }`.
`copytruncate` is **required** — both the agent and `journalctl -f` hold the fd. Add a
`disk_used_percent` metric; the agent is already installed.

### P1-9 · The integration apply is dormant, tests a proxy, and leaks a live fleet
*Tracks 3 + 4 · Medium-High*

The workflow comment says it plainly: *"the gitlab-runner module's highest-value test … its worst
defects are all invisible to a plan."* Three compounding defects:

**(a) It never runs.** Gated on `vars.RUN_RUNNER_INTEGRATION` plus two secrets and two vars. Its own
comment at line 228 names the **wrong variable** (`RUN_INTEGRATION_TESTS`, which a different job
uses). And `examples/simple` declares `private_subnet_ids` as `list(string)`, so a repo variable set
the natural way (`subnet-a,subnet-b`) is a hard type error rather than a list literal. An operator
enabling it follows a comment to the wrong variable, sees nothing, sets the right one, then hits an
opaque type error. Each step erodes the chance the only runtime gate ever runs.

**(b) Its crucial assertion bypasses the component under test.** It sets desired capacity *itself*
via the AWS CLI. That proves AWS accepts the launch template — real value — but never exercises the
fleeting plugin's scaling path. Combined with a `RunnerHealthy` check that is only
`systemctl is-active`, **this test would pass 100% green against P0-1.** The single most severe
defect is invisible to the single test designed to catch severe defects.

**(c) Its cleanup leaks.** The CLI-launched worker is born scale-in protected; `examples/simple`
leaves `force_delete_workers = false`; ASG deletion blocks; and `|| true` on the destroy trap
swallows it. Every run reports success while leaking a running Spot instance, an ASG, two IAM roles,
SGs, and **an SSM SecureString holding a live `glrt-` token**. After a dozen runs you have a dozen
orphaned runners GitLab still trusts. An attacker who can read that account's SSM parameters
harvests them and registers their own runner to receive other projects' CI jobs and secrets.

**Fix:** `force_delete_workers = true` in a CI-only invocation (not in `examples/simple` — the safe
default there is correct and is itself a teaching artifact); drain before destroy; drop `|| true` and
assert the ASG is gone; replace the CLI nudge with a real pipeline job, or at minimum poll for a
**plugin-driven** capacity increase — which is what would have caught P0-1; add
`journalctl -u gitlab-runner` to the failure dump, where the region error is the *only* evidence; run
it nightly so it is exercised regardless of the gate variable.

### P1-10 · The example sweep never validates a single gitlab-runner example
*Track 4 · Medium-High · measured*

`terraform-ci.yaml:180-188` iterates `find examples modules/*/examples | sort -u` under `set -e`.
`sort -u` puts `examples/acm-import` first, and its `source = "./modules/acm-import"` does not exist:
`Unreadable module directory … exit=1`. `set -e` aborts the loop on the first directory. The step's
own comment explains its purpose — *"an in-module quick-start that cannot plan is the worst possible
first impression, and nothing caught it before"* — and it still doesn't. All four gitlab-runner
examples are unvalidated in CI, including the one the integration job uses. (All four *do* validate
offline; there is simply no gate protecting that.)

Related: six `validate` matrix legs reference modules that do not exist (`network-hub`,
`agent-warden-2`, `ci-oidc`). `fail-fast: false` saves gitlab-runner's own legs, but three separate
jobs are now red for reasons unrelated to any code under review.

**Fix:** accumulate failures and report all of them rather than `set -e` on the first; fix or exclude
`examples/acm-import`; derive the matrix from the filesystem instead of a hand-maintained list.

### P1-11 · `runner_token` puts the GitLab token in state in cleartext — and both quick-starts use it
*Track 1 · Medium-High*

`runner_token_ssm_parameter` is a genuine mitigation and the XOR invariant holds. But the path both
shipped quick-starts and the CI job take is the inline one, so the token lands in state in cleartext.
Compounding it, nothing revokes it: `terraform destroy` removes the SSM parameter and the instance
and leaves a permanently "offline" runner in GitLab with a **still-valid** token. Anyone with
state-backend read access can register a runner against it *after* the fleet is gone and receive real
CI jobs — including protected-branch secrets. This compounds directly with P1-9(c).

**Fix:** make the SSM path the quick-start default; add an ASG `Terminating` lifecycle hook or a
systemd `ExecStop` running `gitlab-runner unregister`; document GitLab-side revocation in the destroy
runbook; state in the `runner_token` description that the token **survives destroy**.

### P1-12 · Sensitivity makes the manager's root bootstrap invisible in every plan diff
*Track 1 · Medium*

`config_toml` and `manager_user_data_preview` are `sensitive = true` — correctly, since they embed
`runner_environment` and `extra_runner_config_toml`. The consequence is that the highest-value review
in this module, reading the generated config and root bootstrap before they land, cannot be done in a
plan. Which is exactly where P0-3's payload would be visible.

`README.md:227` nevertheless advertises *"review it in a plan diff"* — a dead end. All other
consumers were tested and work: `terraform test` assertions read them fine, the render fixture works
*because* it re-declares its own outputs sensitive, and `terraform output -raw` in CI prints them
(verified end-to-end: 89-line config + 333-line script extracted, `parse_config.py` OK).

**Fix:** replace the README claim with the working recipe (`terraform output -raw config_toml | diff -
…`), and add a non-sensitive `config_toml_redacted` output — same render with the secret-shaped
inputs stubbed — purpose-built for plan-diff review. That restores the workflow without weakening
sensitivity. Reviewability is a security property.

### P1-13 · Documentation drift in nearly every quantitative claim
*Tracks 3 + 4 · Medium · all counts verified*

| Claim | Reality |
|---|---|
| "Six alarms are created by default" (README:266, CHANGELOG) | **7** — 6 metric + 1 composite; the table omits `workers-present` entirely |
| "72 mocked plan runs" (×2) | **105** |
| "one warm worker during weekday working hours" (×3) | **False** — P0-2 |
| "catch-all LAST" (×2) | **Inverted** — P0-2 |
| "cost nothing when idle" | Always-on manager floor ≈ **$13.9/mo**, plus ~$1.10 alarms, ~$0.74 custom metrics |
| "Three layers" of testing | Four tools exist; `template_safety.py` is never mentioned — and is untracked |
| `manager-absent` listed unconditionally | Conditional on `manager_self_heal` |
| Production example: "checksum-verified" (×3) | `fleeting_plugin_sha256` defaults `""` and ships `""` in `terraform.tfvars.example` — **the check is off** |
| "the worker role is empty by default" | Carries `AmazonSSMManagedInstanceCore` |
| "tested on 1.9.8 and current" | **True** — verified |

The README is otherwise the best artifact here — "Limits worth knowing", the security-assumptions
list, the composite-vs-metric-math rationale are better than most commercial modules. That quality
is what makes the drift dangerous: readers trust it, so the false warm-pool claim actively *prevents*
discovery of P0-2.

**Fix:** correct each row; make the numeric claims self-checking in CI (`grep -c '^run "'` against
the README string; an alarm-count assertion). Make `fleeting_plugin_sha256` **required** in the
production example, as `worker_ami_id`/`manager_ami_id` already are.

---

## P2 — real, bounded

| # | Finding | Track(s) | Fix |
|---|---|---|---|
| P2-1 | `fleeting_plugin_sha256` is architecture-blind while the default manager is **arm64**. An operator copying the x86_64 digest from the release page gets "checksum mismatch — refusing to start" on a brand-new fleet, and the predictable response is to unset it — defeating P0-7. The secure path punishes whoever tries it. | 2 | Make it a map keyed by arch; interpolate the resolved arch into the mismatch message |
| P2-2 | `scale_throttle` requires Runner **17.0** but the version floor is 16.11, and nothing couples them. Renders a key 16.x silently ignores. Promoted in the "bursty monorepo" recipe — the case where throttling matters most. | 4 | Cross-variable validation requiring major ≥ 17 |
| P2-3 | `capacity_shortfall` cannot detect the Spot exhaustion it was built for: failed launches never enter `Pending`, so the metric stays 0. And `Minimum` over 300 s requires a pending instance *every minute*, which at `max_use_count = 1` on a large fleet is the definition of *healthy*. | 4 | Alarm on the **gap** (`GroupDesiredCapacity - GroupInServiceInstances`), positive for every cause; add an EventBridge rule on `EC2 Instance Launch Unsuccessful` |
| P2-4 | `fleet_at_capacity` uses `>=` against `threshold = max_instances` on small fleets, so it fires on *normal full utilisation* — the exact thing its comment claims to avoid. At `max_instances = 1` a single 15-min build pages. The test asserts the arithmetic (`threshold == 2`) rather than the behaviour, encoding the bug. | 4 | Drop below ~4 instances, or composite with a real queue-depth signal |
| P2-5 | `concurrent = max_instances × capacity_per_instance` reaches **800** on a fixed `t4g.small` with no `credit_specification` (so `unlimited` — open-ended surcharges) and no CPU or credit alarm. Manager saturation presents as erratic pickup with every alarm green. | 4 | Relate `concurrent` to manager size; set `cpu_credits` explicitly; add the two free alarms |
| P2-6 | No integer validation on numeric TOML fields — `capacity_per_instance = 1.5` renders `concurrent = 15.75`. Reproduced. Plan-clean, apply-clean, CI-clean, bricks every manager boot. `scale_throttle` has no validation block at all. | 4 | `floor(x) == x` on five inputs; add a float shape to the render fixture |
| P2-7 | Manager user_data is at **79% of the 16 KB limit** with pure defaults (12,975 bytes measured), and nothing validates the total. The exact combination the production checklist recommends is what pushes it over, failing with an AWS error naming none of the six responsible inputs. | 4 | `precondition` on length naming the contributors; longer term, fetch config from SSM/S3 at boot |
| P2-8 | Two bootstrap exit paths precede the `trap`, so a failed manager ships no diagnostics. Reproduced: no `dnf`/`yum`, or both awscli installs failing, exits with **zero telemetry** and before log shipping is configured. Detection still works (the heartbeat never installs, so `runner_unhealthy` fires in ~10 min) — this is a *diagnosability* gap, and the ASG may destroy the evidence first. | 2 | Arm a minimal console-only trap first, upgrade to `put_metric` once `aws` exists |
| P2-9 | Partial failure inside the log-shipping brace group is completely silent. `errexit` is suppressed *throughout*, so every command runs regardless, and `\|\| echo WARN` fires only if the **last** one fails. If `systemctl enable runner-journal-tail` fails, the agent tails a file nothing writes to: log group exists, bootstrap stream healthy, runner stream permanently empty — the most misleading possible state during an incident. | 2 | Per-step `step()` wrapper chained with `&&`; verify both units active at the end |
| P2-10 | Workers get TCP **and** UDP 53 to the entire VPC CIDR, partly undoing the RFC1918 carve-out immediately above it. TCP/53 VPC-wide is a working liveness-scan primitive from a trusted internal source address, on a port that reads as benign in flow logs — plus DNS tunnelling through the resolver. | 1, 2 | Default to `[cidrhost(vpc_cidr, 2)/32, "169.254.169.253/32"]` — derivable at plan time; make TCP/53 separately opt-in |
| P2-11 | CGNAT `100.64.0.0/10` is **fully reachable** on 443 in the "internet minus RFC1918" default (complement computed exactly: 87.083% of IPv4, excluding only `10/8`, `172.16/12`, `192.168/16`, `224.0.0.0/3`). That range is the standard EKS secondary-CIDR / pod address space — so on an EKS-bearing VPC the headline control does not apply to pods. | 2, 3 | Add `100.64/10`, `169.254/16`, `127/8`, `0.0.0.0/8`; generate the list from an `excluded_ranges` variable so it is auditable |
| P2-12 | Interface endpoints get **no policy at all** and the S3 gateway gets none unless supplied — the variable itself concedes "full S3 access, which quietly bypasses the 443 egress restrictions". Anonymous S3 access is not gated by IAM, giving a clean high-throughput exfiltration channel out of a host running untrusted code, indistinguishable from a cache write in flow logs. | 2 | Default to a restrictive policy (`aws:PrincipalAccount` + the AL2023 repo buckets `dnf` needs) |
| P2-13 | `create_vpc_endpoints` bundles the **free** S3 gateway with ~**$66/mo** of interface endpoints behind one boolean. The interface set displaces SSM control-plane traffic measured in KB/s — break-even needs >730 GB/mo — so it is a net loss, while the S3 gateway genuinely saves ~$22/mo on ECR layer pulls at zero cost. The README gets the economics right; the code offers no lever matching the advice. | 4 | Split into `create_s3_endpoint` (default true) and `create_interface_endpoints` (default false) |
| P2-14 | Two fleets in one VPC collide on endpoints — private DNS (one per service per VPC) and S3 route tables. Only the S3 half is documented. "Separate fleet per trust tier" is the module's own headline security recommendation, stated twice. Everything *else* is multi-fleet clean: every derived name is `var.name`-scoped and length-safe at the 32-char max. | 3 | Document both; add `reuse_existing_endpoints` / `existing_endpoint_security_group_ids` |
| P2-15 | The worker role is not "empty": it carries `AmazonSSMManagedInstanceCore`, an **AWS-controlled** policy on the role that executes untrusted CI code — expandable by AWS with no Terraform change and no diff. There is no toggle to remove it. The stated containment story rests on three legs and one isn't what it says. Also unmentioned: anyone with `ssm:StartSession` gets an interactive shell on a worker mid-job, over an outbound channel no SG can block. | 1, 2, 3 | Add `attach_worker_ssm_core`; correct the README; note the `StartSession` path and recommend scoping it by resource tag |
| P2-16 | The `ec2:osuser` guarantee is overclaimed twice: `worker_ssh_username = "root"` passes validation (reproduced), and the default user is in the `docker` group, which is root-equivalent anyway. The condition is genuinely good — scoping by both ASG tag *and* OS user is more than most modules do — but the comment's "can never be used to land on a worker as root" holds for neither case. | 1, 3 | Reject privileged usernames behind an explicit opt-in; correct the comment to claim what it actually delivers |
| P2-17 | `alarm_sns_topic_arns = []` by default: **seven alarms and nobody is paged**, including `orphaned_workers`, which guards the unbounded cost in P1-4. A reviewer sees seven alarms in the plan and concludes the fleet is monitored. (Credit: the production example makes it a *required* variable with a non-empty validation.) | 4 | A `check` block — warns without failing the plan |
| P2-18 | Unpinned `most_recent` AMI drives perpetual plan drift on every path, and on the `manager_self_heal = false` path a `launch_template` change is ForceNew on `aws_instance` — so an unrelated apply can replace the manager and kill every in-flight job. The path the README calls "simpler to reason about" has the sharper edge, and "stationary plans" is a stated production goal the defaults cannot achieve. | 2, 3 | `ignore_changes` or a `precondition` requiring a pinned AMI on that path; fold the AMI into the P0-7 gate |
| P2-19 | `heredoc_nonce` is `substr(sha256("${var.name}-config-heredoc"), 0, 12)` — derived entirely from a caller input, so trivially computable (`ci-prod → TFCFG_c4c8dbf654d2`). Not currently exploitable: the real defences (jsonencode everywhere, the `(?m)^\s*TFCFG_` validation) both hold. But the comment claims unguessability, so a future change relaxing a real defence would be reviewed against a guarantee that does not exist. | 1, 2, 3 | Describe the operative defences; keep the nonce as defence-in-depth against accident |
| P2-20 | Production example: cache IAM does not prevent cross-project cache poisoning, contradicting its own stated mitigation (`PutObject` over a shared prefix). | 1 | Scope the prefix per project, or state the residual risk |

---

## P3 — polish, portability, ergonomics

Endpoint service names are not partition-aware, so `create_vpc_endpoints` fails in `aws-cn`
(`cn.com.amazonaws.…`) — the *only* partition gap in an otherwise meticulously partition-aware
module · no IPv6 egress anywhere and no way to express it, so a dual-stack subnet fails to bootstrap
in a way that presents as "nothing resolves" · the default worker SG spends **33 of 60** egress
rules, reaching 48 in a plausible hardened config, with no guard, failing mid-apply ·
`worker_extra_egress_rules` is index-keyed so reordering destroys and recreates every rule, intra-rule
duplicate CIDRs still crash with `Duplicate object key`, and neither CIDR validity nor integer ports
are checked · validation coverage is 34/71 (48%) — the injection-critical inputs are *all* covered
with positive grammars, and the gaps are ergonomic (`manager_disk_gb` reaches the LT as
`volume_size = 0`; a bogus `vpc_endpoint_services` name is accepted; a negative `scale_throttle`
silently drops the whole block) · `gitlab_url` accepts an embedded newline, `user:pass@host` defeats
private-IP detection, malformed IP literals hard-fail the plan deep inside an SG rule, and a
legitimate subpath install is rejected outright · `runner_unhealthy` can page on a normal cold boot
(heartbeat publishes 0 from `OnBootSec=60`; alarm breaches at ~10 min) and `ok_actions` doubles every
notification · the manager LT lacks the `instance_initiated_shutdown_behavior = "terminate"` its
worker sibling sets with good reason · default `docker:24.0` is a 2023 release from anonymous Docker
Hub (rate-limited — a busy fleet *will* hit `toomanyrequests`) and cannot run Docker at all without
privileged or a DinD service, while `/certs/client` in the default volumes is meaningless without one
· `log_format = "json"` is defeated by `journalctl -o short-iso`, which prefixes every line and
breaks per-line JSON parsing · a 4-line maintainer note is emitted into the production `config.toml`
once per policy · heartbeat and `PutMetricData` run even when `create_alarms = false` · dead test mock
for `aws_route_table` (singular) · dead `e`/`q` characters in the cron grammar, which also silently
rejects tab-separated cron and `@daily` · unused `0.0.0.0/32` sentinel that is a latent footgun for
any future consumer that forgets the gate · no `.tflint.hcl` for this module — **and no `plugin "aws"`
block anywhere in the repository**, so the AWS ruleset loads for none of the 24 modules and the step
passes vacuously · no git tag, everything under `## [Unreleased]`, so consumers have no version to
pin.

---

## What four auditors tried to break and could not

This section exists because it is the honest counterweight to the list above, and because several of
these are things most modules get wrong.

**The RFC1918 carve-out is exactly correct.** All 30 CIDRs decomposed, the complement computed: no
gaps, no overlaps, all canonical, excluding precisely `10/8 + 172.16/12 + 192.168/16` (plus
`224.0.0.0/3`). Boundary probes all right: `172.15`/`172.32` allowed, `172.16`–`172.31` blocked,
`192.167` allowed, `192.168` blocked. Hand-built lists of this kind are almost always subtly wrong.

**Shell injection: zero successes across 14 inputs.** Newlines, quotes, backslashes, `$(...)`,
backticks, `;`, `|`, `&`, `\v`, `\f`, `\r`, and the literal heredoc delimiter. In `config.toml.tftpl`
every string-valued interpolation goes through `jsonencode()`; only type-guaranteed numbers and bools
interpolate raw. In the shell templates every interpolation is single-quoted or justified. Verified at
the *class* level, not just per case: `jsonencode`'s escape alphabet is a **subset** of TOML
basic-string escapes (the only JSON escape TOML rejects is `\/`, which Terraform never emits).

**`package_repo_script_url`'s positive grammar: 28 attack strings, all rejected.** Go RE2's `$` is
end-of-text without `(?m)`, and neither charset admits `\n`, so multiline injection fails too. The
only accepts were cosmetically invalid hosts and ports that make `curl` fail loudly with the trap
armed. The comment's reasoning — that URL-safe is not shell-safe under RFC 3986 — is exactly right.

**Heredoc breakout.** The only form that terminates a quoted heredoc is the exact delimiter at
column 0; column-0 escapes, leading-whitespace and trailing-`\r` variants all verified not to. The
`(?m)^\s*TFCFG_` validation rejects all three, and is deliberately *broader* than the real rule.
Eleven bypass attempts on the table-header validation — bare key, bare key after a blank line, after
a comment, a quoted key, a multiline string hiding a fake `[table]` — **none reached the config**.

**The Terraform 1.9 eager-`||` hazard, the headline portability concern.** Confirmed real on 1.9.8
(`||` eager, `&&` eager, ternary lazy; all three verified). Then all 34 validated variables audited:
**every one is safe**, by `can()` swallowing the error (7), pure comparisons that cannot throw (12),
or — for the one genuinely dangerous case, the 16.11 version floor — nested ternaries plus `try()`,
with a comment explaining the reasoning. 15 version strings probed, no false accepts, no crash.
`required_version = ">= 1.9.0"` is *precisely* right, not approximately: five variables use
cross-variable validation references, a 1.9 feature.

**No dependency cycle, and the design that prevents it is deliberate.** The manager's user_data
embeds the ASG **name** from a pure local, never `aws_autoscaling_group.workers[0].name`.
`terraform graph` confirms the composite alarm has real edges to both children (because `alarm_rule`
interpolates `.alarm_name` rather than re-deriving the string), so create is children-first and
**destroy is composite-first** — exactly what CloudWatch requires. Easy to get wrong; right here.

**Manager IAM: no over-grant found.** ASG mutations scoped to the exact fleet ARN;
`SendSSHPublicKey` double-conditioned; `PutMetricData` namespace-conditioned to what the bootstrap
actually publishes; the SSM parameter ARN handles the leading-slash case; `ssm:GetParameter` singular
matches the call; no `iam:`/`sts:`/`PassRole` anywhere; `coalesce` wildcard fallbacks provably
unreachable in a real apply. The **omission** of `aws:SourceAccount` from the EC2 trust policy is the
correct call, for the reason the comment gives. Statement-by-statement against the documented
`fleeting-plugin-aws` policy: complete, with `ec2:GetPasswordData` correctly omitted (Windows-only).
The `ec2:osuser` condition is *stronger* than upstream's own recommendation.

**The token flow.** SecureString → boot fetch → **stdin, never argv** (so absent from `ps` and
`/proc/*/cmdline`; `printf` is a builtin so there is no separate process either) → placeholder
substitution → `unset` → post-write verification. `install -m 0600` then `cat >` verified to preserve
mode 600, in a `0700` directory created *after* the package install so it tightens whatever the RPM
made. `grep -q` is quiet. No `glrt-` in the rendered config or user_data across 8 shapes.

**`protect_from_scale_in = true` is correct.** Expected to be a cost bug; upstream explicitly states
"Instance scale-in protection should be enabled."

**`periods` is 5-field unix-cron.** Verified against the 17.9 docs — the 7-field format belongs to
legacy Docker Machine autoscaling, a different feature. So the default's *arity* is right even though
its *order* is not (P0-2).

**Root-device derivation** (for the non-BYO path) prevents AWS silently discarding the entire block
mapping — encryption included — on an AMI naming its root `/dev/sda1`. One of the sharper insights
here, and the reason P0-5 is a gap in an otherwise correct idea.

**`gitlab-runner fleeting install` runs *after* `config.toml` is written** — required, since it reads
the config to know which plugin to fetch. Easy to get backwards.

**The `[ -f ]` guard and the `|| true` on `find` are both genuinely load-bearing** — confirmed:
`[ -x <dir> ]` is true while `[ -f <dir> ]` is false, and `find` on a missing root under
`set -euo pipefail` kills the script without the `|| true`.

**`instance_ready_command` table scoping** — correctly emitted before any sub-table, with an accurate
positional comment, guarded by a real parser that checks all three sub-tables for leakage. The
module's best test idea: a case where substring assertions structurally cannot work.

**`create = false` is a true no-op** — all data sources count-gated, placeholder locals keep every ARN
expression valid, 8 shapes rendered with zero AWS calls and no credentials. This is what makes
offline template testing possible at all.

**Also verified sound:** interface-endpoint AZ dedup (order-stable, no perpetual diff) · both manager
paths mutually exclusive and internally consistent · the `0.0.0.0/32` sentinel structurally
unreachable · no non-determinism in any local or template render · the production example's KMS key
policy has all three non-obvious grants correctly scoped, including the `ArnLike aws:PrincipalArn`
trick to break the dependency cycle — the best-executed part of the surrounding material · every
`key =` in all four consumer configurations is a real variable (zero invalid names across 84 inputs) ·
no name-length overflow at the 32-char `name` maximum · sensitivity propagation works correctly in
five of six consumers · the AL2023 `owners = ["amazon"]` scoping defeats name-squatting · the
105-run suite genuinely passes on both versions.

---

## Fix order

**Do first, in this order — the first two are the difference between a working fleet and a decoration.**

1. **P0-1** — the region drop-in. Four lines. Nothing else matters until this is done.
2. **P0-2** — reverse the policy default. One line, plus the `parse_config.py` assertion that makes
   the class unrepeatable.
3. **P0-8** — `git add` the three untracked paths, then add the tracked-scripts guard step. Until CI
   is green for real reasons, no other gate can be trusted.
4. **P0-6** — the two `curl` flags. Smallest fix in this document, largest risk reduction per byte.
5. **P0-5** — the BYO-AMI precondition. Silent loss of encryption on the recommended production path.
6. **P0-3, P0-4** — the two root-reachable escape hatches.
7. **P0-7** — extend the pinning gate to integrity, after P2-1 makes the strict path usable.

**Then:** run the integration job — but fix P1-9(b) first, because as written it would pass against
P0-1 and tell you the fleet is healthy.

**The structural work,** in rough value order: replace `extra_runner_config_toml` with typed
per-table inputs (P1-2, and it retires P0-3 as a class); make `RunnerHealthy` measure job pickup
(P1-3); instrument workers (P1-7); close the orphan loop in code (P1-4); back-port the v2
`template_safety.py` (P1-1).

**The lesson worth carrying forward:** four of the worst defects in this audit — the readiness gate in
the wrong table (found in an earlier cycle), alarms on unpublished metrics, an unplannable example,
and now a fleet that cannot scale — all passed a green suite. A green plan-level test suite is fully
compatible with a badly broken module. Only parsing catches structural bugs, and only running catches
runtime ones.
