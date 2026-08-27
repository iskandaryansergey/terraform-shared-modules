# Engineering charter — `gitlab-runner-fargate`

This module is a second implementation. Its sibling, `modules/gitlab-runner`
(EC2 + fleeting autoscaler), went through four adversarial audit cycles that
found two reproduced root-RCE paths, four non-functional alarms, three controls
that silently did nothing, and several documented protections that did not exist.
Every one of those was found *after* the code was written.

This file is the standing constraint list derived from those findings. It is not
a retrospective — it is the specification. **A change that violates a rule here
does not get merged, even if `terraform test` is green.** The audits demonstrated
repeatedly that a green plan-level suite is compatible with a badly broken module.

---

## R1 — No caller string reaches a shell or a config file unencoded

**Where this came from:** two separate reproduced root-RCE paths.

1. One raw interpolation inside a *TOML comment* (`# ... ${join(", ", periods)}`).
   Comments are inert in TOML, but the file was transported through a shell
   heredoc, where a newline in the value closed the heredoc and everything after
   it ran as root. **A value's safety depends on every layer it traverses, not
   the one you are looking at.**
2. A validation that anchored a URL to RFC 3986 *URL-safe* characters. URL-safe
   is not shell-safe: `$`, `(`, `)`, `;`, `'` are all permitted, and the value
   landed in a double-quoted shell word where `$(...)` is live.

**Rules:**

- **R1.1** Every string interpolated into a generated config file goes through
  `jsonencode()`. No exceptions, including inside comments. Numeric and boolean
  template variables are exempt *only* because the type system guarantees them,
  and each exemption is enumerated in the guard's allow-list.
- **R1.2** Every interpolation into a shell context is single-quoted at the point
  of use, or the value is constrained by a **positive grammar** (an allow-list of
  a small, enumerated character set) — preferably both.
- **R1.3** Validation uses positive grammars, never rejection lists. "Reject the
  bad characters" fails the moment someone finds a character you did not think of.
  `jsonencode()` does **not** escape `$`, `(`, `)` or backticks — it protects TOML
  structure, not shell semantics. Never rely on it for shell safety.
- **R1.4 — No raw-text escape hatch into a security-relevant config file.** The
  sibling module shipped `extra_runner_config_toml`, and it produced a *new*
  finding in three consecutive audits: bare-key table rebinding, then heredoc
  breakout, then injection of a second `[[runners]]` block with
  `executor = "shell"` (root job execution on the control plane). Each fix
  narrowed the hole and revealed another. **Configuration extension is exposed as
  typed, structured inputs only.** If a use case genuinely needs something the
  schema does not model, the schema grows — the caller does not get a text box
  into the config file.

## R2 — A guard must verify its own assumptions, and must be in the repository

**Where this came from:** the linter written to prevent R1 regressions had five
demonstrated bypasses, and was never `git add`ed — so the CI step invoking it
would have failed on a clean checkout while protecting nothing.

The worst bypass was conceptual, and it is the one to internalise: the tool
allow-listed the whole rendered config **because** it was written into a *quoted*
heredoc — and never checked that the heredoc was actually quoted. Deleting one
apostrophe converted every string in the config into a root-RCE vector, with the
guard still printing `OK`.

**Rules:**

- **R2.1** Every guard is committed and tracked. CI asserts the guard file exists
  before running it, so absence fails loudly instead of looking like tooling flake.
- **R2.2** A guard may not *assume* the property that justifies an exemption. If
  an allow-list entry says "safe because the heredoc is quoted", the guard
  verifies the quoting.
- **R2.3** Every allow-list entry carries a written justification, and the
  justification is itself checked against the code where mechanically possible.
  Two entries in the sibling's linter asserted validation that did not exist.
- **R2.4** Guards are proven by regression: reintroduce the original defect and
  confirm the guard fails with a precise message. An unproven guard is a comment.
- **R2.5** No heuristic parsing where a real parser is available. The sibling's
  quote-detection used `count("'") % 2`, which an apostrophe inside a
  double-quoted string defeats.

## R3 — Terraform 1.9 evaluates both operands of `||` and `&&`

**Where this came from:** three separate crashes, one of which I introduced
*while fixing* this exact class in another module.

- **R3.1** Never write `x == "" || f(x)`. Use nested lazy ternaries, `try()`, or
  `coalesce()`. `x == "" ? true : f(x)`.
- **R3.2** Two validations must never reference each other's variable — that is a
  dependency cycle, and it only surfaces at `validate` time.
- **R3.3** Every change is tested on the declared floor (1.9.8) **and** current.
  A single-version green suite is not evidence.

## R4 — Alarms must be correct at every fleet size, and signals must mean what they claim

**Where this came from:** at one point *all* of the sibling's alarms were wrong
simultaneously — two permanently in ALARM on a healthy fleet, one that could
never fire, and one guarding an unbounded cost exposure that resolved itself
exactly when the condition had persisted longest.

- **R4.1** A **continuous** signal (liveness) uses `treat_missing_data = "breaching"`:
  silence means dead. A **discrete** signal (a failure event) uses
  `"notBreaching"`: silence means healthy. Mixing these produces an alarm that is
  either always red or always silent. A one-shot boot metric cannot express liveness.
- **R4.2** Metrics that are opt-in must be explicitly enabled. An alarm on an
  unpublished metric is decoration (the sibling shipped two).
- **R4.3** Thresholds are validated at scale 1, 2, 3 and 200. A `max * 0.9`
  threshold pages permanently on a 2-task fleet. Churn-heavy fleets need the
  statistic and the metric chosen so normal operation is not an alarm — prefer
  *desired*/*pending* counts over *running* counts where the latter oscillates.
- **R4.4** For "A **and** B" use a **composite alarm**, not metric math. Metric
  math `FILL()` only fills within the retrieved window, so the expression stops
  evaluating once one series goes fully absent — which is usually precisely the
  condition you were trying to catch.
- **R4.5** An alarm with no destination is not monitoring. If alarms are enabled,
  a notification target is required, not optional.
- **R4.6** A liveness probe must measure the outcome, not the process. "the
  service is running" is not "jobs are being picked up" — the sibling's heartbeat
  checked `systemctl is-active`, which is true for a runner GitLab is refusing.

## R5 — Never ship a control that cannot work

**Where this came from:** `max_instance_lifetime` was documented as the backstop
against orphaned scale-in-protected instances. ASG replacement *respects* scale-in
protection, so it could not act on the one case it was named for. Also: a
Prometheus listener bound to loopback with nothing able to scrape it, and an IAM
trust condition on a key absent from the request context, which guarded nothing
and might have denied every credential.

- **R5.1** Before documenting a protection, establish it actually functions in the
  configuration the module ships. If it cannot, either remove it or document the
  limitation in the same breath as the feature.
- **R5.2** No knob without a reachable effect. If enabling it changes nothing
  observable, it is a lie with a default value.

## R6 — Documentation claims are verified, not aspirational

**Where this came from:** a README asserting that IMDS hop-limit-1 "contains the
damage" of privileged containers (false once a job is on the host); an "empty
worker role" that carried an AWS-managed policy; an `ec2:osuser` condition
described as preventing root access to a host where that user was in the `docker`
group; a heredoc nonce described as unguessable that was `sha256(name)`.

- **R6.1** Every security claim in prose names the mechanism and is checkable
  against a specific line of code.
- **R6.2** State limitations beside the feature, not in a footnote. The sibling's
  most useful section was the one that listed where the obvious expectation is wrong.
- **R6.3** A comment that overstates a defence is worse than no comment: it stops
  the next person looking. The nonce comment could have caused a vulnerability by
  inviting someone to remove the validation that was actually load-bearing.

## R7 — Secrets: the convenient path must be the safe path

**Where this came from:** the token was handled meticulously (SecureString →
stdin → `0600`-before-content → verification → `unset`) and then the *documented
quick-start* wrote it to Terraform state in cleartext, and the integration CI job
used a real token on that path. Separately, inputs documented as "a natural place
to put a credential" were interpolated into EC2 user_data — API-readable, and
readable by any local process via IMDS.

- **R7.1** The recommended path keeps secrets out of Terraform state entirely.
  `sensitive = true` hides a value from CLI output; it does **not** remove it from
  state. Say so at the point of use.
- **R7.2** Examples and CI use the safe path. An example demonstrating the risky
  path *is* the recommendation, whatever the prose says.
- **R7.3** Any input that could carry a credential is `sensitive`, and so is any
  output derived from it. Enumerate every API that can read the delivery channel.
- **R7.4** Prefer platform secret injection (resolved at launch, never stored in
  the resource definition) over any form of templating into a definition body.

## R8 — Test the artifact, not the string

**Where this came from:** a key emitted into the wrong TOML table disabled the
worker-readiness gate entirely, and passed a 72-case suite because a substring
assertion cannot distinguish `key` under table A from `key` under table B. An
invalid CloudWatch-agent JSON block sat at the front of a bootstrap for a full
cycle because nothing parsed it.

- **R8.1** Every generated artifact (TOML, JSON, shell) is **parsed** in CI, and
  assertions are made on structure and key *paths* — never on substrings.
- **R8.2** Generated shell is checked with `bash -n` and `shellcheck`.
- **R8.3** Rendering is exercised offline (`create = false`, no credentials) so
  artifact checks run on every PR without an AWS account.
- **R8.4** A gated integration apply exists and asserts the outcome (the runner
  registers; a job runs), not merely that `apply` exited 0. The audits' four
  worst defects were all invisible to plan-only testing.
- **R8.5** Multiple input shapes per artifact. One fixture proves one path.
- **R8.6** No tautological tests. One sibling test named
  `ec2_trust_is_account_scoped` asserted only that two roles existed.

## R9 — Validate every input that reaches a shell, a config, or an API

**Where this came from:** 37 of 71 inputs had no validation, and the unvalidated
set was where the runtime failures lived — including `docker_volumes`, whose one
unvalidated list entry (`/var/run/docker.sock`) granted host root to every job,
sitting next to a heavily-guarded `docker_privileged` that achieved the same thing.

- **R9.1** Hazard-rank inputs and protect *equivalents* equally. If two inputs can
  produce the same outcome, they get the same default posture, the same warning
  and the same validation.
- **R9.2** Numeric inputs are integer-checked where an integer is required, not
  merely range-checked.
- **R9.3** Regexes are anchored at both ends. An unanchored `^[0-9]+[hms]` accepts
  `"20m0s junk; rm -rf /"`.
- **R9.4** Cross-field coherence is validated (architecture vs instance type vs
  image; capacity vs reuse; a feature vs the version that supports it).

## R10 — Reviewability is a security property

**Where this came from:** marking secret-bearing inputs `sensitive` propagated
through `templatefile()` and made the manager's root bootstrap script render as
`(sensitive value)` in *every* plan — so the single most security-relevant
artifact in the module became invisible to review, concealing exactly the payload
an injection finding would deliver.

- **R10.1** Where sensitivity hides a security-relevant artifact, provide a
  non-sensitive reviewable surrogate: a digest, and a structural summary
  (counts, table names, executor types) that a reviewer can diff.
- **R10.2** Review instructions in docs must actually work. Do not tell someone to
  review an output that is not exported, or that requires `-raw` without saying so.

## R11 — Destroy and failure paths are part of the interface

- **R11.1** Destroy must not wedge. If a protection mechanism can block teardown,
  provide the escape hatch and document the drain.
- **R11.2** State the module cannot clean up externally (a runner registration in
  GitLab outlives the infrastructure) is documented as an explicit operator step.
- **R11.3** Every failure mode gets an answer to "how does an operator find out?"
  — and detection without remediation is named as such, not implied to be fixed.

## R12 — Ship it properly

- **R12.1** Committed, tagged, listed in the repo catalogue and CHANGELOG, so a
  consumer can pin a `?ref=`. An untracked module cannot be adopted.
- **R12.2** Examples must plan and apply cleanly, and must not claim a posture
  they do not configure. The sibling's quick-start example could not even plan for
  a full cycle, and its production example asserted supply-chain verification it
  left unset.
- **R12.3** No stray files in the module directory.

---

## Structural advantages this platform gives us

Worth stating explicitly, because several of the sibling's worst findings are
**architecturally impossible** here rather than merely fixed:

| Sibling finding | Status on Fargate |
|---|---|
| Root RCE via user_data heredoc | **Gone** — Fargate tasks have no user_data |
| `docker_privileged` → host root | **Gone** — Fargate does not support privileged |
| Docker-socket mount → host root | **Gone** — no Docker socket, no host to reach |
| IMDS hop-limit reasoning | **Gone** — task-scoped credentials, no shared host |
| Worker SSH ingress + Instance Connect | Reduced to the driver's own connection path |
| AMI pinning, root-device names, kernel filters | **Gone** — container images |
| Orphaned scale-in-protected instances | **Gone** — no ASG, no instance protection |
| `curl \| bash` bootstrap supply chain | Reduced to a pinned image digest |

The remaining risk concentrates in **IAM** (`iam:PassRole` on the job task roles),
**the generated configuration**, and **secret delivery** — so those get the
disproportionate share of validation, guards and tests.
