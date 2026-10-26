# A root that creates the function and queue its workflow calls: their ARNs
# are unknown until apply, and so is the rendered definition.

resource "aws_sqs_queue" "orders" {
  name = "orders"
}

resource "aws_iam_policy" "extra" {
  name   = "orders-extra"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["s3:GetObject"], Resource = ["arn:aws:s3:::reports/*"] }] })
}

resource "aws_sqs_queue" "dlq" {
  name = "orders-starts-dlq"
}

module "workflow" {
  source = "../../.."

  name = "orders"
  definition = jsonencode({
    StartAt = "Notify"
    States = {
      Notify = {
        Type       = "Task"
        Resource   = "arn:aws:states:::sqs:sendMessage"
        Parameters = { QueueUrl = aws_sqs_queue.orders.url, "MessageBody.$" = "$" }
        End        = true
      }
    }
  })
  integrations = { sqs_queues = [aws_sqs_queue.orders.arn] }
  role         = { managed_policy_arns = [aws_iam_policy.extra.arn] }
  schedules    = { nightly = { expression = "rate(1 day)", dead_letter_arn = aws_sqs_queue.dlq.arn } }
  alarms       = { enabled = true, sns_topic_arn = "arn:aws:sns:eu-west-2:111122223333:alerts" }

  # The definition and the dead-letter ARN are unknown at plan, so the checks
  # that read them are "known after apply" - a warning in a plan, an error in
  # a test.
  acknowledged_checks = ["the_definition_is_rendered", "every_arn_in_the_definition_is_granted", "event_deliveries_are_kept"]
}

output "alarm_count" {
  value = length(module.workflow.alarm_arns)
}
