# Example: a regulated workload

Two keys, with the controls auditors of a bank tend to ask for.

| Key | What | Why |
|---|---|---|
| `data` | symmetric, **imported key material** (`origin = "EXTERNAL"`) | the material is generated in the bank's HSM; deleting it makes the data unreadable at once, without the 7-30 day wait |
| `statements` | ECC signing key in **generations** `2025`, `2026` | signing keys cannot rotate automatically; a yearly generation is the cryptoperiod |

What it shows:

- **Imported material never touches Terraform.** The key is created pending
  import. The ceremony role (`key_custodians`) fetches import parameters - SHA-256
  wrapping only - and imports the material from CloudShell:
  `aws kms get-parameters-for-import`, then `aws kms import-key-material`.
  `import_expiry` notifications say when material with an expiry runs out.
- **Generations.** `key_arns["statements"]` and `alias/ledger-statements` are
  the 2026 key; `statements-2025` stays enabled with its own alias, so
  signatures it made still verify. `output.generations` lists them. Adding
  `"2027"` moves the alias and grants; removing `"2025"` later deletes that key.
- **Tenant isolation.** Direct use of `data` must carry a `tenant` encryption
  context equal to the caller's `tenant` principal tag.
- **Algorithm limits.** `statements` signs and verifies with ECDSA_SHA_256 only.
- **Guardrails.**
  - Deleting a key used in the last 90 days is denied, to everyone.
  - Deleting the imported material is denied to all but break-glass.
  - Policy, alias, rotation and tag changes are the deployer's and
    break-glass's only.
  - Break-glass does nothing without MFA.
- **`compliance_snippets`**: AWS Config rules (KMS.3, KMS.4, required tags)
  and the CIS metric filter, for the platform team to deploy.

What fails in it:

- **`data` is unusable until the material is imported.** Anything that needs
  the key on creation (an RDS cluster) has to wait for the ceremony.
- **The material can expire.** Imported with an expiry, the key stops working
  when it ends; only re-importing the same material revives it.
- **Imported material does not rotate.** A new generation of an imported key
  is a new key; re-encrypt with it.
- **The break-glass role must be assumed with MFA** for anything at all; a
  role assumed by automation without MFA is denied.
