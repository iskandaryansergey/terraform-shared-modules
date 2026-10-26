# Each example plans, against a mocked provider, without tripping an advisory
# check it does not acknowledge - the examples are what readers copy.

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

run "order_workflow_grants_everything_its_definition_calls" {
  command = plan

  module {
    source = "./examples/order-workflow"
  }

  variables {
    reserve_function_arn = "arn:aws:lambda:eu-west-2:111122223333:function:reserve"
    charge_function_arn  = "arn:aws:lambda:eu-west-2:111122223333:function:charge"
    orders_table_arn     = "arn:aws:dynamodb:eu-west-2:111122223333:table/orders"
    notify_topic_arn     = "arn:aws:sns:eu-west-2:111122223333:order-events"
    alerts_topic_arn     = "arn:aws:sns:eu-west-2:111122223333:alerts"
  }

  assert {
    condition     = length(module.orders.governance.ungranted_definition_arns) == 0
    error_message = "the rendered definition calls nothing the role is not granted."
  }
}

run "express_event_processor_plans" {
  command = plan

  module {
    source = "./examples/express-event-processor"
  }

  variables {
    bucket_name           = "documents-in"
    classify_function_arn = "arn:aws:lambda:eu-west-2:111122223333:function:classify"
    dead_letter_queue_arn = "arn:aws:sqs:eu-west-2:111122223333:classifier-dlq"
    alerts_topic_arn      = "arn:aws:sns:eu-west-2:111122223333:alerts"
  }

  assert {
    condition     = module.classifier.governance.type == "EXPRESS" && module.classifier.governance.query_language == "JSONata"
    error_message = "an EXPRESS JSONata workflow."
  }
}

run "released_with_aliases_plans" {
  command = plan

  module {
    source = "./examples/released-with-aliases"
  }

  variables {
    kms_key_arn                = "arn:aws:kms:eu-west-2:111122223333:key/11111111-2222-3333-4444-555555555555"
    report_task_definition_arn = "arn:aws:ecs:eu-west-2:111122223333:task-definition/nightly-report"
    report_task_role_arns      = ["arn:aws:iam::111122223333:role/report-task", "arn:aws:iam::111122223333:role/report-exec"]
    cluster_arn                = "arn:aws:ecs:eu-west-2:111122223333:cluster/batch"
    subnet_ids                 = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
    dead_letter_queue_arn      = "arn:aws:sqs:eu-west-2:111122223333:report-dlq"
    alerts_topic_arn           = "arn:aws:sns:eu-west-2:111122223333:alerts"
  }

  assert {
    condition     = module.nightly_report.governance.customer_managed_key && contains(module.nightly_report.governance.aliases, "live")
    error_message = "encrypted, released through live."
  }
}
