# ARNs and definitions built from resources in the same root are unknown at
# plan. No count or for_each in the module may depend on them.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { endpoint = "ec2.eu-west-2.amazonaws.com" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
}

run "resources_created_in_the_same_root_plan" {
  command = plan

  module {
    source = "./tests/fixtures/same-root"
  }

  assert {
    condition     = length(module.workflow.schedule_arns) == 1
    error_message = "the state machine, its role, schedule and alarms plan with unknown ARNs and an unknown definition."
  }
}
