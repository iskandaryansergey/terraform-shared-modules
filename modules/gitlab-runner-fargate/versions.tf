terraform {
  # 1.9 is the floor because several validations below reference other variables,
  # which is a 1.9 feature. Note R3: on 1.9 both operands of || and && are
  # evaluated, so no validation in this module puts a throwing expression on
  # either side of one.
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # A deliberately conservative floor, not a hard requirement: the module's
      # resource and attribute set validates as far back as provider 4.67. 5.40
      # is chosen because it is well past the ECS Fargate attribute churn and is
      # what this module is actually exercised against. An earlier version of this
      # comment claimed 5.40 was the floor for ephemeral_storage and
      # aws_ecs_cluster_capacity_providers; both predate it by many releases.
      version = ">= 5.40.0, < 6.0.0"
    }
  }
}
