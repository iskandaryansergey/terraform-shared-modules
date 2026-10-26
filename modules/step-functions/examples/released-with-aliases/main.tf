# A STANDARD workflow released through an alias, encrypted with a customer
# managed key, started nightly by EventBridge Scheduler on "live". Every apply
# publishes a version; "live" moves to it, "canary" would split traffic.

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

variable "kms_key_arn" {
  description = "Customer managed key for execution data and logs."
  type        = string
}

variable "report_task_definition_arn" {
  description = "ECS task definition family ARN (task-definition/<family>) of the report job."
  type        = string
}

variable "report_task_role_arns" {
  description = "Task role and execution role of that task."
  type        = list(string)
}

variable "cluster_arn" {
  description = "ECS cluster that runs the report."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the task."
  type        = list(string)
}

variable "dead_letter_queue_arn" {
  description = "SQS queue for starts the scheduler could not deliver."
  type        = string
}

variable "alerts_topic_arn" {
  description = "SNS topic for the alarms."
  type        = string
}

module "nightly_report" {
  source = "../.."

  name = "nightly-report"
  definition = jsonencode({
    StartAt = "Run"
    States = {
      Run = {
        Type     = "Task"
        Resource = "arn:aws:states:::ecs:runTask.sync"
        Parameters = {
          Cluster        = var.cluster_arn
          TaskDefinition = var.report_task_definition_arn
          LaunchType     = "FARGATE"
          NetworkConfiguration = {
            AwsvpcConfiguration = { Subnets = var.subnet_ids, AssignPublicIp = "DISABLED" }
          }
        }
        TimeoutSeconds = 7200
        End            = true
      }
    }
  })

  integrations = {
    ecs_task_definitions = [var.report_task_definition_arn]
    ecs_pass_role_arns   = var.report_task_role_arns
  }

  kms_key_arn = var.kms_key_arn

  publish = true
  aliases = { live = {} }

  schedules = {
    nightly = { expression = "cron(0 1 * * ? *)", timezone = "Europe/London", alias = "live", dead_letter_arn = var.dead_letter_queue_arn }
  }

  logging = { level = "ALL", retention_days = 90 }
  alarms  = { enabled = true, sns_topic_arn = var.alerts_topic_arn, execution_time_threshold_seconds = 5400 }
  tags    = { CostCentre = "cc-1234", Owner = "reporting-team" }
}

output "alias_arns" {
  value = module.nightly_report.alias_arns
}

output "kms_key_policy_requirements" {
  description = "For the key owner, before the first apply."
  value       = module.nightly_report.kms_key_policy_requirements
}
