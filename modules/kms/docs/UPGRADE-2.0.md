# Upgrading kms from 1.x to 2.0

2.0 manages a set of keys per call, keyed by name, and compiles each key's
policy. One 1.x call becomes one 2.0 call with a single key in `keys`.

**The danger in this upgrade is the key address.** In 1.x the key was
`aws_kms_key.this`; in 2.0 it is `aws_kms_key.this["<key>"]`. Without the
`moved` blocks below, the plan **destroys the old key**. Destroying a key
schedules its deletion, and every byte encrypted under it is lost when the
window ends. Search every plan of this upgrade for `aws_kms_key` and
`will be destroyed` before approving it.

## 1. Inputs

| 1.x input                            | 2.0                                                                                                                                                             |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `name` | `name` (now the key set name) plus a key name in `keys`; pick e.g. `main`. It must now be 2-41 lowercase letters, digits or hyphens: if the 1.x name is not, pick a new set name and keep the old alias through `aliases` |
| `description` | `keys.main.description`. Without it the 2.0 default is `<name> main, managed by Terraform`; set it to the 1.x description (1.x default: `KMS key for <purpose> in <environment> environment`, or `Managed by Terraform`) to avoid an update |
| `key_usage`                          | `keys.main.usage`                                                                                                                                               |
| `customer_master_key_spec`           | `keys.main.spec`                                                                                                                                                |
| `multi_region`                       | `keys.main.multi_region`                                                                                                                                        |
| `enable_key_rotation`                | `keys.main.rotation`                                                                                                                                            |
| `rotation_period_in_days`            | `keys.main.rotation_period_days`                                                                                                                                |
| `deletion_window_in_days`            | `keys.main.deletion_window_days`                                                                                                                                |
| `is_enabled`                         | `keys.main.enabled`                                                                                                                                             |
| `create_alias`, `alias_name` | `keys.main.aliases`, names without `alias/`. **Set it**: the 2.0 default is `alias/<name>-main`, and 1.x used `alias/<name>` (or `alias_name`). `create_alias = false` is not available: every key has an alias |
| `grants`                             | `keys.main.grants`. `constraints` becomes `encryption_context_equals` / `encryption_context_subset`. `retire_on_delete` now defaults to `false` (1.x: `true`): set it to `true` to keep a grant from being replaced. `grant_creation_tokens` is removed |
| `additional_policy_statements`       | `keys.main.extra_statements = jsonencode([...])`, or better, `users`, `administrators` and `services`                                                           |
| `key_policy`                         | removed. A complete hand-written policy defeats the compiler; express it as roles, presets and `extra_statements`                                               |
| `bypass_policy_lockout_safety_check` | removed; the check is never bypassed                                                                                                                            |
| `purpose`, `environment`             | removed; put them in `tags` if you want them                                                                                                                    |
| `tags`                               | `tags` (the module's own tags now win)                                                                                                                          |

The module still takes one provider. 1.x created no replicas; in 2.0 a
replica is created by `modules/replica` (README, "Disaster recovery").

## 2. Outputs

| 1.x output                                                                                                                                                                                                                     | 2.0                                                                             |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------- |
| `key_arn`, `key_id`                                                                                                                                                                                                            | `keys.main.arn`, `keys.main.id` (or `key_arns.main`)                            |
| `alias_name`, `alias_arn`                                                                                                                                                                                                      | `keys.main.aliases[0]`, `keys.main.alias_arns[0]`                               |
| `policy`                                                                                                                                                                                                                       | `policies.main.primary`                                                         |
| `kms_key_for_encryption` | `keys.main`, with fields renamed: `key_arn` is `arn`, `key_id` is `id` |
| `grant_ids`, `grant_tokens`, `key_usage`, `customer_master_key_spec`, `multi_region`, `is_enabled`, `enable_key_rotation`, `rotation_period_in_days`, `deletion_window_in_days`, `description`, `tags`, `alias_target_key_arn` | removed. `keys`, `governance` and `verify_commands` carry what a reviewer needs |

## 3. `moved` blocks, in your root module

The module cannot know your key name, so these go in the calling module, next
to the module block (here the module is `module.kms` and the key is `main`):

```hcl
moved {
  from = module.kms.aws_kms_key.this
  to   = module.kms.aws_kms_key.this["main"]
}

moved {
  from = module.kms.aws_kms_alias.this[0]
  to   = module.kms.aws_kms_alias.this["<alias without alias/>"]
}

# One per 1.x grant:
moved {
  from = module.kms.aws_kms_grant.this["<grant>"]
  to   = module.kms.aws_kms_grant.this["main/<grant>"]
}
```

Never delete these blocks: a workspace that skips a version still needs them.

## 4. What still changes on the first plan

These are expected. Read each one.

- **The alias is replaced unless `keys.main.aliases` is set** to the 1.x name.
  2.0 names it `alias/<name>-main`; the `moved` block above then points at an
  address that does not exist, and the old alias is deleted. Every
  application using `alias/<name>` breaks.

- **`aws_kms_key_policy.this["main"]` is created.** It replaces the key's
  policy with the compiled one. Read `output.policies` in the plan, and
  compare it with the 1.x policy (`aws kms get-key-policy`).
  - If 1.x relied on the account-root statement alone, keep
    `iam_delegation = true` (the default).
  - The compiled policy also adds **deletion protection**: only the deployer
    and `break_glass` may schedule deletion or disable the key. The deployer
    is the role running the plan, detected, unless `deployers` names one. Name
    the workspace role(s) in `deployers` - both, with separate plan and apply
    roles.
  - The 1.x statement `Enable IAM User Permissions` is now `EnableIamPolicies`;
    the diff shows it renamed.
- **`aws_kms_key.this["main"]` updates tags.** `Name`, `Purpose` and
  `Environment` are removed, and `Module`, `KeySet` and `Key` are added
  (`ManagedBy` stays). Its policy does not change on the key resource itself, because it is
  `ignore_changes`.
- **`aws_kms_key.this["main"]` updates its description** unless
  `description` is set to the 1.x one. An in-place update.
- **Grants are replaced** when any argument differs from 1.x: every grant
  argument forces a new grant. The common causes are `retire_on_delete`, whose
  default changed from `true` to `false`, and `grant_creation_tokens`, which is
  gone. A replaced grant gets a new grant ID and token; anything holding the
  old token must be updated.
- **A 1.x `multi_region = true` key** now warns
  (`multi_region_keys_are_replicated`) unless it replicates through
  `modules/replica` or the check is acknowledged.

## 5. In HCP Terraform

1. Raise the workspace's Terraform version to 1.9 or later. Run
   `terraform init -upgrade` so the lock file allows provider 5.73 or later.
2. Open a pull request with the new module version, the input changes and the
   `moved` blocks.
3. In the speculative plan:
   - search for `will be destroyed`: there must be none on `aws_kms_key` or
     `aws_kms_alias`;
   - search for `has moved to`: one per key, alias and grant;
   - read the planned `aws_kms_key_policy` document.
4. Apply. Then run `verify_commands.main.policy`, and compare the result with
   `output.policies.main.primary`.
