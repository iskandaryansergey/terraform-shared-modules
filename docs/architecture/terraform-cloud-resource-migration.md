# Migrating Resources in HCP Terraform Without Losing What Matters

|                   |                                                                                                                                                                                                                 |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Author**        | Ivan Kovtun, Cloud Solution Architect, NatWest, Lending                                                                                                                                                         |
| **Document type** | Architecture guidance and runbook                                                                                                                                                                               |
| **Status**        | Draft for review                                                                                                                                                                                                |
| **Version**       | 2.6                                                                                                                                                                                                             |
| **Date**          | 14 October 2026                                                                                                                                                                                                 |
| **Applies to**    | Any Terraform configuration run from HCP Terraform (Terraform Cloud) or Terraform Enterprise, with any provider (AWS, Azure, Google Cloud, Kubernetes, and others). Terraform 1.7 or later for the full toolset |
| **Audience**      | Engineers changing Terraform code; reviewers and approvers of runs; platform engineers who own workspaces, policy sets and shared modules                                                                       |

---

## 1. Summary

A Terraform "migration" is any change after which Terraform has to work out
that an object it manages is the **same** object under a new address, a new
module version, a new provider version, or in a new workspace. When it fails
to work that out, it does the only thing it can: **destroys the old object and
creates a new one**. For a database, a storage bucket, an encryption key or a
DNS zone, that is data loss or an outage, and some of it cannot be undone.

This guide is provider-neutral. The mechanisms (`moved`, `import`, `removed`,
lifecycle rules, policy checks) are Terraform's and HCP Terraform's; examples
name resources from several clouds to show the pattern, not to limit it.

The five rules this document expands on:

1. **Classify before you touch.** Know which resources hold data or identity
   (Tier 0) before the first line changes. Their deletion is never acceptable
   by default.
2. **Declare migrations in code, never in the CLI.** `moved`, `import` and
   `removed` blocks are reviewed, planned and kept. `terraform state` commands
   against a remote workspace are invisible to review.
3. **The plan is the contract.** A migration is ready only when its plan
   shows `has moved to` / `will be imported` / `will no longer be managed` for
   every object, and **no** `must be replaced` or `will be destroyed` on
   Tier 0. Read the plan, then let a machine check it too.
4. **Rehearse.** On a non-production workspace of the same shape, or offline
   against a copy of the state. A migration never planned against real state
   is a guess.
5. **Make destruction need two keys.** Protection in the platform itself
   (deletion protection, locks, soft delete, backups) **and** in HCP Terraform
   (policy checks, apply approvals). Terraform code alone is one key.

---

## 2. Scope

### 2.1 In scope

| Migration                                    | Example                                                                                                 |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Address refactoring inside one configuration | renaming a resource, `count` to `for_each`, moving resources into or out of a module                    |
| Module version upgrades                      | a shared module's major version that renames resources or changes defaults                              |
| Moving resources between workspaces          | splitting a monolithic workspace; handing networking to a platform workspace                            |
| Adopting existing resources                  | bringing console-created or legacy resources under Terraform                                            |
| Releasing resources from Terraform           | decommissioning a workspace while keeping its resources                                                 |
| Provider and Terraform version upgrades      | a provider major version; a Terraform minor version on the workspace                                    |
| Replacing one resource type with another     | a deprecated resource type split into several new ones; inline sub-blocks moved to standalone resources |

### 2.2 Out of scope

Moving **data** between resources (database migration, object storage
replication, cross-account or cross-subscription copies). Where a Terraform
change unavoidably creates a new resource, this document covers getting the
data across safely (section 9), not the data-migration tooling itself.

---

## 3. Terminology

| Term                      | Meaning here                                                                                                                                          |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Address**               | Where an object lives in Terraform state: `module.db.<type>.this[0]`. Changing the address without telling Terraform is a destroy and a create        |
| **Instance key**          | The `[0]` (count) or `["name"]` (for_each) part of an address. Changing it is a change of address                                                     |
| **Replacement attribute** | An argument whose change the provider cannot apply in place (often called ForceNew): the plan shows `# forces replacement` and the object is replaced |
| **Replacement**           | Destroy then create (`-/+`), or create then destroy (`+/-`) with `create_before_destroy`                                                              |
| **Tier 0**                | A resource whose destruction loses data, keys or identity irrecoverably, or breaks consumers outside the team (section 4)                             |
| **Speculative plan**      | A plan HCP Terraform runs for a pull request; it cannot be applied                                                                                    |
| **State version**         | Every apply writes a new state version to the workspace; previous versions are kept and can be restored                                               |
| **Policy check**          | A Sentinel or OPA policy set evaluated on every run, after plan, before apply                                                                         |

---

## 4. Classify first: what you cannot afford to lose

Every migration starts with a list of the objects it touches, each with a
tier. The tier decides how much protection the change needs. The categories
are universal; the examples are illustrative.

| Tier                              | Category                                            | Examples (AWS / Azure / Google Cloud / Kubernetes)                                                                                                                                                                                                                                                                                                          | Destroy means                                                                                                                                | Required before migrating                                                                                 |
| --------------------------------- | --------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| **0 - Data**                      | Stores data                                         | Managed databases (RDS/Aurora, Azure SQL, Cloud SQL), NoSQL tables (DynamoDB, Cosmos DB, Firestore, Bigtable), object storage (S3, Storage Accounts, Cloud Storage), file and block storage (EFS/EBS, Azure Files/Managed Disks, Filestore/Persistent Disk), caches and search clusters with persistence, message stores with retention, persistent volumes | Data loss                                                                                                                                    | A fresh backup verified restorable; deletion protection on; a gate rule that fails the plan on any delete |
| **0 - Keys and secrets**          | Encrypts or authenticates everything else           | Key management keys (AWS KMS, Azure Key Vault keys, Cloud KMS), secret stores (Secrets Manager, Key Vault, Secret Manager), certificate authorities                                                                                                                                                                                                         | Everything encrypted under the key becomes unreadable once deletion completes                                                                | As for data, plus the platform's deletion window or soft delete confirmed on                              |
| **0 - Identity others depend on** | Its identifier is referenced from outside the stack | DNS zones, certificates, identities assumed by other accounts or CI (IAM roles, managed identities, service accounts), key aliases, private endpoints with DNS, names that are globally unique (bucket and storage account names)                                                                                                                           | A new ID: trust relationships, delegations and integrations break; some names cannot be reclaimed for a long time, or at all                 | Inventory of consumers; gate rule as for data                                                             |
| **0 - Evidence**                  | Logs and audit trails kept for compliance           | Log groups, Log Analytics workspaces, logging buckets and sinks with retention                                                                                                                                                                                                                                                                              | The retained evidence is deleted                                                                                                             | As for data                                                                                               |
| **1 - Connectivity**              | Recreatable, but recreation interrupts traffic      | Networks and subnets in use, security groups and NSGs, firewall rules, route tables, gateways, load balancers, ingress                                                                                                                                                                                                                                      | Outage while it is recreated; a network object still attached to running resources often cannot be deleted at all, failing the apply halfway | `create_before_destroy` where names allow; a change window                                                |
| **2 - Recreatable**               | No data, no external references                     | Alarms and alerts, dashboards, policies attached only inside the stack, event rules, parameter and configuration sets (with care)                                                                                                                                                                                                                           | A short gap                                                                                                                                  | Normal review                                                                                             |

> **Note.** Deleting a key-management key is usually not immediate (AWS KMS
> schedules deletion for 7-30 days; Azure Key Vault keeps deleted keys under
> soft delete; Cloud KMS destroys key versions after a scheduled period).
> Treat a planned destroy of a key as a P1 regardless: once the window passes,
> no backup of the data helps, because the backup is encrypted with the same key.

---

## 5. The mechanisms, and which one to use

### 5.1 Decision table

| Situation                                                                                                                     | Use                                                                                                  | Never use                                                                  |
| ----------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Same object, new address in the same configuration (rename, into a module, `count` to `for_each`)                             | `moved` block                                                                                        | `terraform state mv` against the workspace                                 |
| Same object, new resource type, and the provider supports the move (Terraform 1.8+, provider implements resource-state moves) | `moved` block across types, after confirming support in the provider documentation                   | Assuming it works; if unsupported, the plan errors, which is at least safe |
| Same object, new resource type, no provider support                                                                           | `removed` (`destroy = false`) for the old type **and** `import` for the new type, in the same change | Deleting the old block and writing the new one: destroy and create         |
| Object exists, not in any state                                                                                               | `import` block (Terraform 1.5+; `for_each` in imports 1.7+)                                          | `terraform import` from a laptop against the workspace state               |
| Object moves to another workspace                                                                                             | `removed` (`destroy = false`) in the source, `import` in the target, sequenced (section 7.4)         | `terraform state rm` / `push` by hand                                      |
| Stop managing an object, keep it                                                                                              | `removed` block with `lifecycle { destroy = false }` (Terraform 1.7+)                                | Deleting the block: that **destroys** it                                   |
| A change would replace a Tier 0 object                                                                                        | Stop. Change the input back, or design a data migration (section 9)                                  | `-replace`, or accepting `must be replaced` "because it is only a rename"  |

### 5.2 `moved` blocks

```hcl
# Rename
moved {
  from = example_bucket.logs
  to   = example_bucket.audit_logs
}

# Into a module (written in the calling configuration)
moved {
  from = example_database.main
  to   = module.orders_db.example_database.this[0]
}

# count -> for_each: one block per instance, because the keys change type
moved {
  from = example_identity.service[0]
  to   = example_identity.service["api"]
}
moved {
  from = example_identity.service[1]
  to   = example_identity.service["worker"]
}

# A whole module call renamed (keeps every resource inside)
moved {
  from = module.db
  to   = module.orders_db
}
```

`example_*` stands for any resource type. The same rules apply to every
provider.

Rules that keep them safe:

- **Never delete a `moved` block.** A workspace that skips versions, or a
  second environment that upgrades later, still needs it. They cost nothing.
- **Never reuse a `from` address** for a new resource later: the block moves
  unrelated state into it.
- **Instance keys are part of the address.** Moving `x.a` to `x.b` keeps each
  instance's key. If the keys change too (`[0]` to `["api"]`), write one block
  per instance.
- **A shared module that renames its resources ships the `moved` blocks
  itself** (a `moved.tf` in the module). Callers then only keep the module
  block's name.
- **A `moved` block renames the state record, nothing else.** It cannot
  hand an object to a different provider configuration (another alias,
  region, account or subscription). The real object stays where it was
  created; the next plan either replaces it or reports it missing and creates
  a new one. Changing where an object is managed is a workspace move
  (section 7.4) or a data migration (section 9).
- **Know every historical layout.** If an earlier release had `x.main`
  without `count` and a later one had `x.main[0]`, one block covers only one
  of them. Two blocks with the same target are rejected as ambiguous. Chain
  them instead:

  ```hcl
  moved {
    from = example_subnet_group.main      # either shape...
    to   = example_subnet_group.this
  }
  moved {
    from = example_subnet_group.this      # ...then the key-less one gets [0]
    to   = example_subnet_group.this[0]
  }
  ```

  A real case: a shared database module's major release moved its subnet
  group with a single block. Workspaces created by its early releases (no
  `count`) would have destroyed the subnet group their running database was
  using. Only a rehearsal against both historical layouts found it
  (section 8.3).

### 5.3 `import` blocks

```hcl
import {
  to = example_bucket.audit_logs
  id = "<the provider's import ID for this object>"
}

# Many at once (Terraform 1.7+)
import {
  for_each = var.legacy_queues          # { orders = "<import id>", ... }
  to       = example_queue.this[each.key]
  id       = each.value
}
```

- Each provider documents the import ID format per resource type, at the
  bottom of the resource's page. Use exactly that format.
- The plan shows `will be imported` and then **any** difference between the
  configuration and the real object, as an update or a **replacement**. An
  import that plans `must be replaced` would destroy the object you meant to
  adopt. Make the configuration match reality first.
- `terraform plan -generate-config-out=generated.tf` (Terraform 1.5+) writes
  a starting configuration from the real object. Review it before using it.
- Import blocks can stay after the import (they become no-ops), or be
  removed in a follow-up change. Keep them until every environment has
  applied.

### 5.4 `removed` blocks

```hcl
removed {
  from = example_dns_zone.legacy

  lifecycle {
    destroy = false   # forget it, leave it running
  }
}
```

- The plan shows `will no longer be managed by Terraform, but will not be
  destroyed`. The object stays, untouched.
- The `destroy` argument is mandatory: `destroy = true` destroys the object
  on the next apply, and a `removed` block without a `lifecycle` block does
  not plan at all. Simply deleting the resource block, with no `removed`
  block, **destroys** the object.
- `removed` cannot target a resource that is still declared in the
  configuration.

### 5.5 Lifecycle settings that protect

| Setting                        | Protects against                                                                        | Limits                                                                                                                                                                                  |
| ------------------------------ | --------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prevent_destroy = true`       | A changed input that would replace the resource, and `terraform destroy`: the plan fails | Lives in the resource block, so it protects only while the block exists. Delete or rename the block without a `moved` block and the protection goes with it: Terraform destroys the object. It is a guard against bad inputs, not against a failed migration; the policy check (8.2) is the guard for that. Cannot be set from a variable. Inside a shared module it also blocks intentional teardown, so prefer it in **root** configurations for Tier 0 |
| `create_before_destroy = true` | Outage during a replacement                                                              | Needs names that can coexist (prefixes or generated suffixes). It does not stop data loss: the old object is still destroyed                                                                                                                                                                                                                                                                                                                  |
| `ignore_changes = [...]`       | A creation-only or externally managed attribute forcing replacement                      | Hides real drift; document why each entry exists                                                                                                                                                                                                                                                                                                                                                                                              |
| `replace_triggered_by = [...]` | Nothing: it **causes** replacement when a referenced resource or attribute changes       | A migration that touches the referenced object (moving it, re-keying it) replaces this one too. Search for it in every configuration the migration touches                                                                                                                                                                                                                                                                                      |
| `precondition` / `check`       | Inputs that would cause replacement or misconfiguration, refused or warned at plan time  | Only as good as what the module author foresaw                                                                                                                                                                                                                                                                                                                                                                                                |

---

## 6. The signals: reading a migration plan

Read **every** line of a migration plan, in this order. Then run the
automated gate (section 8.2), which checks the same things without tiring.

### 6.1 The summary line

```
Plan: 2 to import, 3 to add, 12 to change, 2 to destroy.
```

Moves have no counter: an object that `has moved to` a new address appears
in no column. Imports have their own counter (Terraform 1.5 and later).

| Signal                                                   | Meaning                                                                 | Action                                                                         |
| -------------------------------------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `0 to destroy`                                           | Nothing is removed                                                      | Still read the replacements: a `+/-` is counted under both add **and** destroy |
| `N to import` with anything but `0 to change` on those objects | The configuration differs from the imported object | Read each difference; an imported object that is also `must be replaced` is destroyed right after adoption |
| Any destroy count in a migration that should only rename | A `moved` or `import` did not match                                     | **Stop.** Find each destroyed address                                          |
| Add count equals destroy count                           | Classic sign of a failed rename: old address destroyed, new one created | **Stop**                                                                       |

### 6.2 Lines in the plan body

| Plan text                                                                | Severity                  | What it means                                                         | What to do                                                                          |
| ------------------------------------------------------------------------ | ------------------------- | --------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `# X has moved to Y`                                                     | Green                     | A `moved` block matched                                               | Confirm every expected object has one                                               |
| `# X will be imported`                                                   | Green, if no other change | An `import` block matched                                             | The same object must not also show `must be replaced`                               |
| `# X will no longer be managed by Terraform, but will not be destroyed`  | Amber                     | A `removed` block with `destroy = false`                              | Confirm it is intended, and who manages it next                                     |
| `~ update in-place`                                                      | Green or amber            | Changed attributes, same object                                       | Read each attribute: some updates restart services, fail over or rotate credentials |
| `-/+ must be replaced`                                                   | **Red** on Tier 0 or 1    | Destroy, then create                                                  | Find the `# forces replacement` attribute; fix the input                            |
| `+/- create replacement and then destroy`                                | Amber                     | `create_before_destroy` replacement                                   | Acceptable for Tier 2, and for Tier 1 in a window; **red** on Tier 0                |
| `# forces replacement`                                                   | **Red** on Tier 0         | This attribute cannot change in place                                 | The single most important line in the plan                                          |
| `- destroy` / `will be destroyed`                                        | **Red** on Tier 0         | The object goes                                                       | Every one needs a named reason                                                      |
| `(known after apply)` on an identifier, name or ID of an existing object | Amber                     | The value will change, usually because of a replacement upstream      | Trace where it comes from                                                           |
| `Objects have changed outside of Terraform`                              | Amber                     | Drift: someone changed the object directly                            | Absorb it first with a refresh-only run (HCP Terraform: Actions, Start new run, Refresh-only), then plan the migration on its own |
| `will be read during apply` on a data source                             | Amber                     | Its inputs are unknown; anything depending on it may show as changing | Check what depends on it                                                            |
| `Warning: Check block assertion failed`                                  | Amber                     | A module's advisory check                                             | Read it; fix or acknowledge explicitly                                              |
| `Error: Resource precondition failed`                                    | Green (it worked)         | The module refused an unsafe input                                    | Do what the message says; never work around it                                      |
| `Error: Ambiguous move statements` / `Moved object still exists`         | Safe failure              | Conflicting `moved` blocks                                            | Fix the blocks (section 5.2)                                                        |

### 6.3 Where replacement hides

Every provider marks some attributes as unchangeable in place. The patterns
repeat across clouds:

| Pattern                           | Typical attributes                                         | Examples                                                                                                                 |
| --------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| The object's name or identifier   | `name`, `identifier`, `bucket`, `*_name`                   | Almost every resource in every major provider                                                                            |
| Where it lives                    | `region`, `location`, `zone`, `availability_zone`          | AWS zone-bound resources; Azure `location`; Google `region`/`zone`/`location`                                            |
| Its parent                        | resource group, project, account, network, cluster         | Azure `resource_group_name`; Google `project`; a subnet group, VPC or network id                                         |
| How it is encrypted               | the key reference, an `encrypted` flag                     | AWS `kms_key_id` on databases, file systems and volumes; customer-managed key settings that cannot change after creation |
| Its fundamental shape             | engine or edition, key schema, partitioning, tier families | a database engine, a NoSQL table's key schema, a storage account's kind or replication class on some providers           |
| The source it was built from      | snapshot, image, backup it was restored from               | `snapshot_identifier`, `source_*`, `restore_*`                                                                           |
| Descriptions you would not expect | free-text fields some APIs cannot update                   | AWS security group `description`                                                                                         |

Confirm in the provider documentation for the exact version in use: the
argument reference marks these (and the plan always will, with
`# forces replacement`).

Three more sources of replacement come from the configuration rather than
the provider, and no argument reference lists them:

| Source | What happens | Signal in the plan |
| --- | --- | --- |
| **`count` index shift** | Removing an element from the middle of the list a `count` iterates over renumbers every later instance: `[2]` becomes `[1]`, and Terraform destroys and recreates each shifted object. Appending at the end is safe; removing or reordering is not | Several `-/+` on the same resource type with consecutive indexes, old and new attributes identical |
| **`for_each` keys derived from values** | Keys computed from an attribute that changes (a name, a CIDR, an ARN) change with it, so the object moves to a new key: destroy and create | `-/+` on a `for_each` resource whose only difference is the key |
| **`replace_triggered_by`** | A referenced object or attribute changed, possibly far from the migration, and forces this one to be replaced | `-/+` with `# forces replacement` pointing at `replace_triggered_by` |

The first two are the reason `count` belongs only on resources that are
all-or-nothing, and `for_each` keys should be stable names chosen by the
caller, never derived from the object.

> **Watch defaults.** The most common silent replacement in a module upgrade
> is not a renamed argument but a **changed default**: an input you never set
> now defaults to something else, and that something is a replacement
> attribute. A shared module must list its changed defaults in its changelog,
> marked BREAKING, and in its upgrade guide.

### 6.4 Signals outside the plan

| Signal                                                | Where                              | Why it matters                                                                                                          |
| ----------------------------------------------------- | ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Workspace Terraform version                           | Workspace settings                 | Older than the code's `required_version` fails; newer upgrades the state format, and that is one-way                    |
| `.terraform.lock.hcl` provider versions               | Repository                         | A provider major upgrade changes resource schemas; state written by the new provider may not be readable by the old one |
| Run triggers from other workspaces                    | Workspace settings                 | A migration in workspace A can trigger an apply in B mid-change                                                         |
| Auto-apply                                            | Workspace settings                 | Must be **off** for any workspace being migrated                                                                        |
| "Allow destroy plans"                                 | Workspace settings                 | Off for workspaces holding Tier 0, unless a decommission is in progress                                                 |
| Policy check results                                  | Run page                           | A soft-mandatory override is a decision; record who made it and why                                                     |
| Health assessments (drift detection)                  | Workspace health                   | Unresolved drift makes the migration plan harder to read                                                                |
| Concurrent runs                                       | Run queue                          | Lock the workspace for the duration of the migration                                                                    |
| Remote state consumers (`tfe_outputs`, state sharing) | Workspace settings, consuming code | Outputs renamed or removed by the migration break downstream workspaces                                                 |

---

## 7. Procedure

### 7.1 Phases

| #   | Phase                  | Output                                                                                                                              | Owner                   |
| --- | ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ----------------------- |
| 0   | Inventory and classify | Every object touched, with its tier, its address before and after, and its consumers                                                | Change author           |
| 1   | Protect                | Backups taken and verified restorable; platform-side protection confirmed on; workspace locked; auto-apply off; run triggers paused | Change author, platform |
| 2   | Code the migration     | `moved` / `import` / `removed` blocks and the configuration, on a branch                                                            | Change author           |
| 3   | Plan and gate          | A speculative plan that is clean against the checklist (7.2) and the automated gate (8.2)                                           | Author, reviewer        |
| 4   | Rehearse               | The same change applied on a non-production workspace of the same shape, or rehearsed offline (8.3)                                 | Author                  |
| 5   | Apply                  | In a change window, by an approver who is not the author. In a VCS-driven workspace the merge starts a **new** run with a new plan; the approver reads that plan in full before confirming, and its summary line must match the reviewed pull-request plan | Approver                |
| 6   | Verify                 | Objects exist with the same IDs; consumers healthy; outputs unchanged where expected; the next plan shows no changes                | Author                  |
| 7   | Close                  | Temporary protections removed; `moved` blocks **kept**; runbooks and changelog updated                                              | Author                  |

### 7.2 Plan review checklist

Copy into the pull request description and tick each line.

- [ ] Every object in the inventory shows `has moved to`, `will be imported`,
      or `will no longer be managed`, as intended.
- [ ] No Tier 0 object shows `must be replaced`, `will be destroyed`, or
      `create replacement and then destroy`.
- [ ] Every Tier 1 replacement is `+/-` (create before destroy) and in the
      change window.
- [ ] The summary destroy count matches the list of intended destroys exactly.
- [ ] No `# forces replacement` on any Tier 0 or Tier 1 object.
- [ ] No `count` list has lost or reordered an element, and no `for_each` key
      has changed for an existing object (section 6.3).
- [ ] No `replace_triggered_by` references an object the migration touches.
- [ ] No identifier, name or ID of an existing object shows
      `(known after apply)`.
- [ ] In-place updates that restart, fail over or rotate credentials are known
      and scheduled with their consumers.
- [ ] No secret value appears in the plan. Where a credential leaves the
      configuration (for example a move to a platform-managed secret), it is
      rotated afterwards: every earlier state version still holds it.
- [ ] Outputs consumed by other workspaces are unchanged, or the consumers are
      updated in the same change window.
- [ ] The automated gate passed, or every exception is named and justified.
- [ ] Check-block warnings are fixed or explicitly acknowledged.
- [ ] Drift reported in the plan is understood.
- [ ] The pull-request plan and the merge run's plan have the same summary
      line, and the approver has read the merge run's plan, not only the
      pull request's.

### 7.3 Module version upgrades

1. Read the module's changelog for every version between the current and the
   target: every **BREAKING** entry, and above all the changed defaults.
2. Read its upgrade guide end to end. Get the running values of every input
   it says must match what is deployed.
3. Pin the exact version for the migration (`version = "2.0.0"`); relax the
   constraint afterwards.
4. **Keep the module block's name.** The module's own `moved` blocks are
   relative to it.
5. Set every input whose default changed to the value that is running, unless
   the change is wanted and planned.
6. Plan, review (7.2), gate (8.2). If any Tier 0 object would be replaced, an
   input is wrong. Fix the input; never accept the replacement.

### 7.4 Moving resources between workspaces

Two workspaces must never manage the same object at the same time, and no
object should be left managed by neither for longer than the change.

| Step | Workspace | Change                                                          | Plan must show                                                                               |
| ---- | --------- | --------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| 1    | Both      | Lock both workspaces (no other runs)                            | -                                                                                            |
| 2    | Target    | Configuration plus `import` blocks                              | `will be imported`, **0 to change, 0 to destroy** for the imported objects. Do not apply yet |
| 3    | Source    | `removed` blocks with `destroy = false`                         | `will no longer be managed`, **0 to destroy**                                                |
| 4    | Source    | Apply step 3                                                    | -                                                                                            |
| 5    | Target    | Re-plan, apply step 2                                           | Same as step 2                                                                               |
| 6    | Both      | Update run triggers, remote state consumers and sharing; unlock | -                                                                                            |

If step 5 fails, the object is in no state but still exists: re-plan and
apply the import, and nothing is lost. If step 4 runs before step 2 was
proven, the object is orphaned but intact.

> **Warning.** Never "move" a resource by deleting its block in the source and
> adding it in the target. The source apply destroys it.

### 7.5 Provider and Terraform upgrades

- Upgrade providers in their own change, never together with a refactor: the
  plan should contain only what the provider changed.
- Run `terraform init -upgrade` and commit the lock file.
- Read the provider's upgrade guide for every major version crossed. Look for
  arguments that became replacement attributes, removed arguments that fall
  back to defaults, and changed default values.
- **A state schema upgrade is one-way.** After applying with a newer provider
  or Terraform version, rolling back means restoring the previous state
  version **and** pinning the older version. Pinning alone fails.
- Raise the workspace's Terraform version deliberately, never by tracking
  "latest".

---

## 8. Making it automatic

### 8.1 HCP Terraform workspace settings for Tier 0 workspaces

| Setting                                                 | Value                                                                                          |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Apply method                                            | Manual apply; auto-apply off                                                                   |
| Allow destroy plans                                     | Off                                                                                            |
| Terraform version                                       | Pinned                                                                                         |
| VCS-driven runs with speculative plans on pull requests | On                                                                                             |
| Team access                                             | Apply permission for approvers only; authors can plan                                          |
| Credentials                                             | Separate plan (read-only) and apply identities where the provider supports dynamic credentials |
| Policy sets                                             | The Tier 0 deletion policy (8.2), mandatory                                                    |
| Health assessments                                      | Drift detection on (an HCP Terraform Plus feature; on Terraform Enterprise, a scheduled refresh-only run does the same job) |
| Notifications                                           | Run errored and needs attention, to the owning team's channel                                  |

### 8.2 Policy as code: the gate

A policy check runs on every plan in every workspace it is attached to; it is
the second key. Fail any plan that deletes or replaces a Tier 0 type, unless
an explicit, reviewed exception exists. Maintain the list of types per
provider in the policy set; the logic stays the same.

**Sentinel (tfplan/v2):**

```sentinel
import "tfplan/v2" as tfplan

# Tier 0 types for the providers in use. Extend per platform.
tier0 = [
  # AWS
  "aws_rds_cluster", "aws_db_instance", "aws_dynamodb_table", "aws_s3_bucket",
  "aws_efs_file_system", "aws_ebs_volume", "aws_kms_key", "aws_secretsmanager_secret",
  "aws_route53_zone", "aws_cloudwatch_log_group",
  # Azure
  "azurerm_mssql_server", "azurerm_mssql_database", "azurerm_cosmosdb_account",
  "azurerm_storage_account", "azurerm_key_vault", "azurerm_key_vault_key",
  "azurerm_dns_zone", "azurerm_log_analytics_workspace",
  # Google Cloud
  "google_sql_database_instance", "google_bigtable_instance", "google_storage_bucket",
  "google_kms_crypto_key", "google_secret_manager_secret", "google_dns_managed_zone",
  # Kubernetes
  "kubernetes_persistent_volume_claim", "kubernetes_persistent_volume",
]

removals = filter tfplan.resource_changes as _, rc {
  rc.type in tier0 and rc.change.actions contains "delete"
}

print("Tier 0 objects this plan deletes or replaces:", keys(removals))

main = rule { length(removals) is 0 }
```

**OPA (Rego), for HCP Terraform OPA policy sets:**

```rego
package terraform.tier0

import rego.v1   # OPA 0.59 or later; the policy set's OPA version decides

# Same list as above, extended per platform.
tier0 := {
  "aws_rds_cluster", "aws_db_instance", "aws_dynamodb_table", "aws_s3_bucket",
  "aws_kms_key", "azurerm_mssql_database", "azurerm_storage_account", "azurerm_key_vault",
  "google_sql_database_instance", "google_storage_bucket", "google_kms_crypto_key",
  "kubernetes_persistent_volume_claim",
}

deny contains msg if {
  rc := input.plan.resource_changes[_]
  tier0[rc.type]
  "delete" in rc.change.actions
  msg := sprintf("%s would be deleted or replaced (%v)", [rc.address, rc.change.actions])
}
```

An OPA policy only runs once the policy set's `policies.hcl` names its query
and level; without that entry the file is inert:

```hcl
policy "tier0_no_deletion" {
  query             = "data.terraform.tier0.deny"
  enforcement_level = "mandatory"
}
```

Enforcement level for production workspaces: Sentinel **hard-mandatory**, OPA
**mandatory** (OPA has only `advisory` and `mandatory`). A genuine
decommission goes through a time-boxed exception, approved and recorded, not
through a soft override clicked at apply time. Test both policies on a
non-production workspace before enforcing them.

**Module-level gates** complement the policy. A shared module can ship its
own plan checker for its specific rules, for example a database module that
also fails on unencrypted storage, public endpoints or TLS turned off. Run it
in the pipeline on the plan JSON (`terraform show -json`).

One trap when writing such a checker: `after_sensitive` is `true` for every
attribute the provider's schema marks sensitive, **even when its value is
null**. Test the value, not the flag. Otherwise the gate fails every plan and
teams learn to ignore it.

### 8.3 Rehearsal

A plan against real state is the only proof a migration works. Three ways,
from best to cheapest:

| Method                                     | How                                                                                                                                                                                                              | Proves                                                                                                      |
| ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Non-production workspace of the same shape | Apply the same change there first                                                                                                                                                                                | Everything, including the platform's behaviour on apply                                                     |
| Copy of the production state, offline      | Download the state version and plan locally against the new code with `-refresh=false`, using read-only credentials. `-refresh=false` skips re-reading managed resources; data sources are still read, which is what the credentials are for | That every address moves and nothing is replaced; nothing about apply                                       |
| Synthetic state, in a shared module's CI   | The module's CI writes a state at the old addresses, for every layout the module ever shipped, and plans the new version over it with `-refresh=false`. Data sources that call the platform are answered locally | That the module's `moved` blocks cover every historical layout, on every provider major version it supports |

The third method belongs in the CI of every shared module that renames
resources. In one case it found, before any workspace was touched:

- a missed historical layout (section 5.2);
- a check message that crashed the plan when an attribute was null;
- the gate trap above;
- an upgrade guide claiming an in-place change that the module in fact
  refuses.

None of these showed in unit tests, which always start from an empty state.

---

## 9. When replacement cannot be avoided

Some changes are replacements by nature: a new encryption key on a database,
a renamed bucket, a different table key schema, a move to another region.
Treat these as **data migrations with a Terraform step**, never as Terraform
changes.

| Step | What                                                                                                       |
| ---- | ---------------------------------------------------------------------------------------------------------- |
| 1    | Create the new resource **alongside** the old one, under a new address. No `moved` block                   |
| 2    | Copy the data: snapshot and restore, replication, export and import, or the platform's migration service   |
| 3    | Cut consumers over: DNS, configuration, secrets. Keep the old resource read-only                           |
| 4    | Verify in production use for a defined period                                                              |
| 5    | Remove the old resource in a **separate** change, with the deletion policy exception, after a final backup |

**Encryption keys.** Data encrypted under a key stays readable only while
that key exists. Re-encrypt, or copy with the new key, everything before
deleting the old key. Keep the old key disabled, not deleted, for at least one
full backup retention period, because backups are encrypted with it too.

**Credentials.** A password or token that was ever in the configuration is in
every state version written while it was there, and HCP Terraform keeps those
versions. Moving to a platform-managed secret removes it from the current
state only. Rotate it as part of the migration, or treat the move itself as
the rotation and confirm the platform generated a new value.

---

## 10. Protection layers

A migration should be safe even when one layer fails.

| Layer                       | Controls                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Platform services**       | Deletion protection on databases and clusters (e.g. RDS/Aurora `deletion_protection`, Cloud SQL `deletion_protection`); final snapshots and automated backups with retention; point-in-time recovery; object versioning and immutability (S3 Object Lock, Azure immutable blobs, Cloud Storage retention policies); key deletion windows and soft delete with purge protection (AWS KMS, Azure Key Vault); backup vaults with locks; persistent volume `reclaimPolicy: Retain` in Kubernetes |
| **Organisation guardrails** | AWS service control policies; Azure Policy and resource locks (`CanNotDelete`); Google Cloud organisation policies and IAM deny policies. Deny deletion of tagged or labelled Tier 0 resources outside break-glass                                                                                                                                                                                                                                                                           |
| **Terraform code**          | `moved` / `import` / `removed` blocks; `prevent_destroy` on Tier 0 in root configurations (against bad inputs; it does not survive the removal of its own block); module preconditions and checks; `create_before_destroy` for Tier 1                                                                                                                                                                                                                                                       |
| **HCP Terraform**           | Mandatory policy sets; manual apply; separate plan and apply identities; "Allow destroy plans" off; team permissions; state version history                                                                                                                                                                                                                                                                                                                                                  |
| **Process**                 | Inventory and tiers; checklist in the pull request; rehearsal; change windows; an approver who is not the author                                                                                                                                                                                                                                                                                                                                                                             |

---

## 11. Rollback

| What went wrong                                                                         | Recovery                                                                                                                                                                                                                                                          |
| --------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A `moved` / `import` / `removed` change applied, the result is wrong, nothing destroyed | Revert the code, re-plan, apply. If the state is now inconsistent, roll back to the previous state version in HCP Terraform: lock the workspace, open States, pick the version before the run, Advanced, roll back. The rollback writes a copy of that version as a new current version (undoing it is another rollback), and the workspace stays locked until you unlock it. Re-plan before anything else: a restored state that no longer matches the platform shows as orphaned or duplicated objects |
| A provider or Terraform upgrade applied and must be undone                              | Restore the previous state version **and** pin the previous provider or Terraform version. Pinning alone fails: the newer state cannot be read                                                                                                                    |
| A Tier 0 object destroyed                                                               | Restore from its backup through the platform: snapshot or point-in-time restore for databases, versions or soft-deleted copies for object storage, snapshots for volumes and file systems, soft-delete recovery for key vaults. Then `import` the restored object |
| A key scheduled for deletion or soft-deleted                                            | Cancel the deletion or recover the key within the window (for example `aws kms cancel-key-deletion`; Key Vault recover), re-enable it, then reconcile the state                                                                                                   |
| An object orphaned by a workspace move                                                  | It still exists: `import` it in the intended workspace                                                                                                                                                                                                            |

> **Note.** A state version restore changes only what Terraform believes; it
> does not touch the platform. After any restore, read the next plan as
> carefully as the migration plan itself.

---

## 12. Anti-patterns

| Anti-pattern                                                                          | Why it fails                                                                             |
| ------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `terraform state mv` / `rm` / `push` against an HCP Terraform workspace from a laptop | No review, no plan, no record of intent; a typo becomes a destroy on the next run        |
| "It only renames, approve it"                                                         | A failed rename is a destroy plus a create; the summary line says so                     |
| Accepting `must be replaced` on a database "because there is a backup"                | A restore is an outage, loses everything since the backup, and usually changes endpoints |
| Refactor, provider upgrade and module upgrade in one change                           | Nobody can attribute the plan line by line                                               |
| Deleting `moved` blocks to tidy up                                                    | Breaks every environment that has not applied them yet                                   |
| Soft-mandatory policy overridden at apply time                                        | Hands the second key to whoever is in a hurry                                            |
| Auto-apply on a workspace with Tier 0                                                 | The speculative plan was reviewed; the applied plan was not                              |
| Relying on `prevent_destroy` inside a shared module                                   | It blocks legitimate teardown, so people remove it. Keep it in root configurations       |
| Relying on `prevent_destroy` to catch a failed rename                                 | The protection lives in the block that the rename deletes; the policy check is the guard |
| Removing an element from the middle of a `count` list                                 | Every later instance is renumbered and replaced                                          |
| A migration plan with unresolved drift                                                | Two sets of changes in one plan, and the dangerous one hides                             |
| Testing migrations only with unit tests                                               | Unit tests start from empty state, where every migration trivially succeeds              |

---

## 13. Roles

| Activity                       | Author | Reviewer | Approver (applies) | Platform |
| ------------------------------ | ------ | -------- | ------------------ | -------- |
| Inventory and tiers            | R      | C        | I                  | C        |
| Backups and protections        | R      | C        | A                  | C        |
| Code and plan                  | R/A    | C        | I                  | I        |
| Automated gate and policy sets | I      | I        | I                  | R/A      |
| Rehearsal                      | R      | C        | I                  | C        |
| Apply                          | C      | I        | R/A                | I        |
| Verification and close-out     | R      | C        | A                  | I        |

R responsible, A accountable, C consulted, I informed.

---

## Appendix A. Pull request template for a migration

```markdown
## Migration: <short title>

**Type:** rename / module upgrade (x.y -> z.w) / workspace move / import / removal / provider upgrade
**Workspaces:** <names> **Change window:** <date, time>
**Rehearsed on:** <non-prod workspace or offline method>

### Objects touched

| Address before | Address after | Tier | Expected plan line                                            |
| -------------- | ------------- | ---- | ------------------------------------------------------------- |
|                |               |      | has moved to / will be imported / no longer managed / updated |

### Protection in place

- [ ] Backups taken at: <time>, verified restorable
- [ ] Deletion protection confirmed on for Tier 0
- [ ] Workspace locked; auto-apply off; run triggers paused

### Plan review (section 7.2)

- [ ] ... (paste the checklist)

### Gate

- Policy check: pass / exception <link>
- Module plan check: pass

### Rollback

<what we do if step N fails>
```

## Appendix B. Verification after apply

The same three questions on any platform:

1. **Is it the same object?** Compare the IDs, ARNs or resource IDs with the
   inventory taken in phase 0. A new ID means a replacement happened.
2. **Is anything pending deletion?** Keys scheduled for deletion, soft-deleted
   vaults or buckets, snapshots being removed.
3. **Is the plan clean?** Re-run the plan: a completed migration plans
   **no changes**.

Examples:

```bash
# AWS: same cluster, still protected; no key pending deletion
aws rds describe-db-clusters --db-cluster-identifier <id> \
  --query 'DBClusters[0].[DBClusterArn,DbClusterResourceId,DeletionProtection]'
aws kms describe-key --key-id <alias or id> --query 'KeyMetadata.[Arn,KeyState]'

# Azure: same resource ID; delete lock still in place
az resource show --ids <resource id> --query id
az lock list --resource-group <rg> --query "[?level=='CanNotDelete'].name"

# Google Cloud: same instance; deletion protection on
gcloud sql instances describe <instance> --format='value(name,settings.deletionProtectionEnabled)'
```

## Appendix C. Version reference

| Capability                                                     | Terraform version |
| -------------------------------------------------------------- | ----------------- |
| `moved` blocks                                                 | 1.1               |
| `import` blocks, `-generate-config-out`                        | 1.5               |
| `removed` blocks (with a mandatory `lifecycle { destroy }`); `for_each` in `import` | 1.7               |
| `moved` across resource types (where the provider supports it) | 1.8               |

## Appendix D. Sources

The guidance above was written against the following documentation. Where a
statement in this document is specific to a version (of Terraform, of a
provider, of OPA), the version is the one current on the "Date" in the
header; check the linked page when the toolchain moves.

**Terraform language**

- [Refactoring: `moved` blocks and renaming resources](https://developer.hashicorp.com/terraform/language/modules/develop/refactoring)
- [`moved` block reference](https://developer.hashicorp.com/terraform/language/block/moved)
- [`import` block reference](https://developer.hashicorp.com/terraform/language/block/import) and [generating configuration for imported resources](https://developer.hashicorp.com/terraform/language/import/generating-configuration)
- [`removed` block reference](https://developer.hashicorp.com/terraform/language/block/removed)
- [The `lifecycle` meta-argument: `prevent_destroy`, `create_before_destroy`, `ignore_changes`, `replace_triggered_by`](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle)
- [`count`](https://developer.hashicorp.com/terraform/language/meta-arguments/count) and [`for_each`](https://developer.hashicorp.com/terraform/language/meta-arguments/for_each) meta-arguments
- [Custom conditions: preconditions, postconditions and `check` blocks](https://developer.hashicorp.com/terraform/language/expressions/custom-conditions)
- [JSON output format of plans and state](https://developer.hashicorp.com/terraform/internals/json-format)
- [Terraform upgrade guides](https://developer.hashicorp.com/terraform/language/upgrade-guides)

**HCP Terraform and Terraform Enterprise**

- [Workspace state: versions, rollback and sharing](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/state)
- [Workspace settings: apply method, destroy plans, locking, Terraform version](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/settings)
- [Run modes and options, including refresh-only and speculative plans](https://developer.hashicorp.com/terraform/cloud-docs/run/modes-and-options)
- [Run triggers](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/settings/run-triggers)
- [Health assessments and drift detection](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/health)
- [Dynamic provider credentials, with separate plan and apply identities](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/dynamic-provider-credentials)
- [Team permissions for workspaces](https://developer.hashicorp.com/terraform/cloud-docs/users-teams-organizations/permissions)

**Policy as code**

- [Sentinel policies in HCP Terraform](https://developer.hashicorp.com/terraform/cloud-docs/policy-enforcement/sentinel) and the [`tfplan/v2` import](https://developer.hashicorp.com/terraform/cloud-docs/policy-enforcement/sentinel/import/tfplan-v2)
- [OPA policies in HCP Terraform](https://developer.hashicorp.com/terraform/cloud-docs/policy-enforcement/opa)
- [OPA policy sets and `policies.hcl`](https://developer.hashicorp.com/terraform/cloud-docs/policy-enforcement/manage-policy-sets/opa-vcs)
- [Policy enforcement levels](https://developer.hashicorp.com/terraform/cloud-docs/policy-enforcement/manage-policy-sets)
- [Rego policy language](https://www.openpolicyagent.org/docs/latest/policy-language/)

**Platform protection mechanisms**

- AWS: [deleting KMS keys and the waiting period](https://docs.aws.amazon.com/kms/latest/developerguide/deleting-keys.html); [deleting an Aurora cluster and deletion protection](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/USER_DeleteCluster.html); [S3 Object Lock](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html); [service control policies](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html)
- Azure: [Key Vault soft delete and purge protection](https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview); [resource locks](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources); [immutable blob storage](https://learn.microsoft.com/en-us/azure/storage/blobs/immutable-storage-overview)
- Google Cloud: [destroying and restoring Cloud KMS key versions](https://cloud.google.com/kms/docs/destroy-restore); [Cloud SQL deletion protection](https://cloud.google.com/sql/docs/mysql/deletion-protection); [bucket retention policies and Bucket Lock](https://cloud.google.com/storage/docs/bucket-lock); [organisation policy](https://cloud.google.com/resource-manager/docs/organization-policy/overview)
- Kubernetes: [persistent volume reclaim policies](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#reclaiming)

**Provider upgrade guides consulted for the replacement patterns**

- [AWS provider version 6 upgrade guide](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/guides/version-6-upgrade)
- [AzureRM provider 4.0 upgrade guide](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/4.0-upgrade-guide)
- [Google provider 6.0 upgrade guide](https://registry.terraform.io/providers/hashicorp/google/latest/docs/guides/version_6_upgrade)

**Internal**

- The upgrade guide, `moved.tf` and CI rehearsal of the shared database
  module whose 1.x to 2.x migration is the worked example in sections 5.2
  and 8.3. The rehearsal found every defect listed there before any
  workspace was changed.
