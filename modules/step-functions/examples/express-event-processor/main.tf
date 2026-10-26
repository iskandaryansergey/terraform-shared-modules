# An EXPRESS workflow started by an EventBridge rule for each new S3 object.
# Express keeps no execution history in Step Functions, so logs at ERROR are
# the record of failures; events EventBridge cannot deliver go to a queue.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.90.0, < 7.0.0" }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-west-2"
}

variable "bucket_name" {
  description = "Bucket with EventBridge notifications turned on."
  type        = string
}

variable "classify_function_arn" {
  description = "Classifies a document."
  type        = string
}

variable "dead_letter_queue_arn" {
  description = "SQS queue for events EventBridge could not deliver."
  type        = string
}

variable "alerts_topic_arn" {
  description = "SNS topic for the alarms."
  type        = string
}

module "classifier" {
  source = "../.."

  name = "document-classifier"
  type = "EXPRESS"
  definition = jsonencode({
    QueryLanguage = "JSONata"
    StartAt       = "Classify"
    States = {
      Classify = {
        Type      = "Task"
        Resource  = "arn:aws:states:::lambda:invoke"
        Arguments = { FunctionName = var.classify_function_arn, Payload = "{% $states.input %}" }
        Retry     = [{ ErrorEquals = ["Lambda.TooManyRequestsException"], MaxAttempts = 3 }]
        End       = true
      }
    }
  })

  integrations = { lambda_functions = [var.classify_function_arn] }

  event_rules = {
    object-created = {
      event_pattern = jsonencode({
        source        = ["aws.s3"]
        "detail-type" = ["Object Created"]
        detail        = { bucket = { name = [var.bucket_name] } }
      })
      input_path      = "$.detail"
      dead_letter_arn = var.dead_letter_queue_arn
    }
  }

  logging = { level = "ERROR", retention_days = 14 }
  alarms  = { enabled = true, sns_topic_arn = var.alerts_topic_arn }
  tags    = { CostCentre = "cc-1234", Owner = "documents-team" }
}

output "event_rule_arns" {
  value = module.classifier.event_rule_arns
}
