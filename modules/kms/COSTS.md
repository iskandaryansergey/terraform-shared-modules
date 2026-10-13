# Costs: kms

| | |
|---|---|
| Region | any (KMS prices are the same in eu-west-2 and us-east-1) |
| Currency | USD |
| Pricing date | AWS Price List `awskms` offer, published 2026-09-11; KMS pricing page read 2026-10-13 |
| Basis | module 2.0.0 defaults (`rotation = true`, 365-day period) |

> Verify before quoting externally. Prices were read from the Price List and
> the pricing page during development, not pulled live.

## What the module spends

| Line | Unit price | Quantity | Monthly |
|---|---|---|---|
| Customer managed key | $1.00/month | per key | $1.00 × keys |
| Rotation | +$1.00/month at the 1st and 2nd rotation, then free | per rotating key | up to +$2.00 × rotating keys |
| Multi-Region replica | $1.00/month, rotations billed the same way | per replica | $1.00 × replicas (up to $3.00 each) |
| Key pending deletion | $0 | | |
| EventBridge rules | $0 for AWS-sourced events | 0–4 rules (native and CloudTrail-based, per region) | $0 |
| Grants, aliases, policies | $0 | | $0 |

`output.cost` computes the first two rows for the set: the cost before any
rotation, and the upper bound once every rotating key has rotated twice.

Worked example: 3 symmetric rotating keys, one of them replicated. Before
rotation: 3 keys + 1 replica = **$4/month**. After two yearly rotations:
(3 + 1) × $3 = **$12/month**, flat after that.

## What callers spend because of the keys

Requests are billed to the account that makes them, including AWS services
acting for it:

| Request | Price per 10,000 |
|---|---|
| Symmetric (Encrypt, Decrypt, GenerateDataKey, ...) | $0.03 |
| RSA_2048 asymmetric | $0.03 |
| Other asymmetric | $0.15 |
| ECC GenerateDataKeyPair | $0.10 |
| RSA GenerateDataKeyPair | $12.00 |

The first 20,000 requests a month are free, counted across all Regions.
Asymmetric requests (`Sign`, `Verify`, `Encrypt`, `Decrypt` and `GetPublicKey`
on an asymmetric key) and `GenerateDataKeyPair` requests are outside the free
tier and are billed from the first one.

## The growing line

Requests, not keys. Key storage plateaus at $3 per key and replica after the
second rotation. Requests grow with traffic, and two patterns dominate:

- S3 SSE-KMS **without a Bucket Key**: one KMS call per object operation.
  Enable Bucket Keys on high-volume buckets; it cuts S3's KMS calls by up to
  99%.
- Envelope encryption **without data-key caching** in applications.

Neither is controlled by this module. Both show in Cost Explorer under KMS,
attributed to the calling account.

## Not spent by the module

- **Custom key stores.** A key in a CloudHSM or external key store costs the
  same $1/month, but the store itself (CloudHSM cluster, external key manager)
  is billed to whoever runs it.
- **SNS deliveries** of the notifications, billed to the topic owner. Native
  key events are a handful a year per key.
- **CloudTrail**, needed only for the CloudTrail-based notifications. The first
  copy of management events in a trail is free.
