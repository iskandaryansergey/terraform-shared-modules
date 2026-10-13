# Example: a multi-Region key with a disaster-recovery replica

One key, `data`. It is a multi-Region primary in eu-west-2, with a replica in
eu-west-1 created through the `aws.replica` provider (here `aws.dr`).

What it shows:

- **Shared with the primary:** the replica has the same key material, spec,
  usage and rotation.
- **Its own:** the replica has its own policy, aliases, description and tags,
  and the module sets each of them.
- **Region-specific presets:** each policy names its own region. The `logs`
  preset grants `logs.eu-west-1.amazonaws.com` on the replica.
- **Cost:** `output.cost` counts the replica. Each replica is billed as a key:
  $1/month, plus its rotations.
- **Notifications in both regions.** EventBridge rules only see events in
  their own region and target topics in it, so the replica's rules are created
  through `aws.replica` and publish to `replica_sns_topic_arn`.
  `output.sns_topic_policy_requirement` has one statement per region.

What fails in it:

- `multi_region` cannot be turned off, and turning it on replaces the key. Set
  it when the key is created.
- **VPC endpoint guardrails are regional.** An endpoint ID from eu-west-2
  means nothing in eu-west-1; a replica needs
  `guardrails.replica_vpc_endpoint_ids`, and the module warns when it is
  missing.
- **Consumer requirements match per region.** A requirement naming the
  primary's ARN lands only in the primary's policy; one naming the replica ARN
  (`keys.data.replica_arn`) lands only in the replica's.
