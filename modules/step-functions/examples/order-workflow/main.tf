# A STANDARD workflow from a template: two Lambda steps with retries and a
# compensation, a DynamoDB update and an SNS notification. integrations lists
# each resource the definition calls; the check every_arn_in_the_definition_is_granted
# compares the two.

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

variable "reserve_function_arn" {
  description = "Reserves stock."
  type        = string
}

variable "charge_function_arn" {
  description = "Takes payment."
  type        = string
}

variable "orders_table_arn" {
  description = "The orders table."
  type        = string
}

variable "notify_topic_arn" {
  description = "Order notifications."
  type        = string
}

variable "alerts_topic_arn" {
  description = "SNS topic for the alarms."
  type        = string
}

module "orders" {
  source = "../.."

  name = "orders"
  definition = templatefile("${path.module}/order.asl.json.tftpl", {
    reserve_function_arn = var.reserve_function_arn
    charge_function_arn  = var.charge_function_arn
    orders_table         = element(split("/", var.orders_table_arn), 1)
    notify_topic_arn     = var.notify_topic_arn
  })

  integrations = {
    lambda_functions      = [var.reserve_function_arn, var.charge_function_arn]
    dynamodb_write_tables = [var.orders_table_arn]
    sns_topics            = [var.notify_topic_arn]
  }

  alarms = { enabled = true, sns_topic_arn = var.alerts_topic_arn }
  tags   = { CostCentre = "cc-1234", Owner = "orders-team" }
}

output "state_machine_arn" {
  value = module.orders.state_machine_arn
}

output "start_execution_policy_json" {
  description = "Attach to the callers' roles."
  value       = module.orders.start_execution_policy_json
}

output "deployer_requirements" {
  description = "The workspace's role needs these, including states:ValidateStateMachineDefinition for every plan."
  value       = module.orders.deployer_requirements
}
