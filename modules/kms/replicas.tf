# What modules/replica needs to create the replicas, compiled here: their
# policies name the replica region, carry its VPC endpoints and the consumer
# requirements that name a replica ARN. modules/replica only creates
# resources, so it can run in another workspace, in the disaster-recovery
# region, and still apply while this region is down.

locals {
  replica_blueprint = !local.create || length(local.replicated_keys) == 0 ? null : {
    schema  = 1
    key_set = var.name
    region  = local.replica_region
    keys = {
      for k, v in local.replicated_keys : k => {
        primary_key_arn      = local.key_arn[k]
        origin               = v.origin
        arn                  = local.replica_arns[k]
        description          = v.description
        enabled              = v.enabled
        deletion_window_days = v.deletion_window_days
        bootstrap_policy     = local.bootstrap_policy[k].replica
        policy               = local.final_policy[k].replica
        aliases              = [for a in v.aliases : "alias/${a}"]
        tags                 = local.key_tags[k]
      }
    }
    notifications = {
      native_pattern     = length(local.native_events) > 0 ? local.native_pattern.replica : ""
      cloudtrail_pattern = length(local.cloudtrail_events) > 0 ? local.cloudtrail_pattern.replica : ""
      tags               = local.rule_tags
    }
  }
}
