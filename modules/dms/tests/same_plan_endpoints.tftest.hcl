# Endpoint secrets created in the same plan, and the PostgreSQL target's
# MaxFileSize. Both were found by a live run on Aurora Serverless v2.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { name = "eu-west-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_data "aws_iam_roles" {
    defaults = { names = ["dms-vpc-role", "dms-cloudwatch-logs-role"] }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/mock" }
  }
}

variables {
  name               = "test-migration"
  subnet_ids         = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  security_group_ids = ["sg-0123456789abcdef0"]
  engine_version     = "3.5.4"
  kms_key_arn        = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
  certificates       = { rds-ca = { pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----" } }
  tasks = {
    app = {
      source_endpoint = "source-db"
      target_endpoint = "target-db"
      migration_type  = "full-load-and-cdc"
      table_mappings  = "{\"rules\":[{\"rule-type\":\"selection\",\"rule-id\":\"1\",\"rule-name\":\"all\",\"object-locator\":{\"schema-name\":\"app\",\"table-name\":\"%\"},\"rule-action\":\"include\"}]}"
    }
  }
  alarm_free_storage_bytes = 8589934592
  sns_topic_arn            = "arn:aws:sns:eu-west-1:111122223333:migrations"
}

run "endpoint_credentials_created_in_the_same_plan" {
  command = plan
  module {
    source = "./tests/fixtures/same_plan_endpoints"
  }
}

run "target_max_file_size" {
  command = plan

  variables {
    endpoints = {
      source-db = { role = "source", engine = "aurora-postgresql", database_name = "app", secret_arn = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf", certificate_key = "rds-ca" }
      target-db = {
        role     = "target", engine = "aurora-postgresql", database_name = "app", secret_arn = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:tgt-AbCdEf", certificate_key = "rds-ca"
        postgres = { after_connect_script = "SET session_replication_role = replica;" }
      }
    }
  }

  assert {
    condition     = toset(keys(aws_iam_role.endpoint_secret)) == toset(["source-db", "target-db"])
    error_message = "one secret role per endpoint on the secret path"
  }

  assert {
    condition     = aws_dms_endpoint.this["target-db"].postgres_settings[0].max_file_size == 32768
    error_message = "a PostgreSQL target gets MaxFileSize 32768 (DMS default), never the provider's 0"
  }

  assert {
    condition     = length(aws_dms_endpoint.this["source-db"].postgres_settings) == 1 && aws_dms_endpoint.this["source-db"].postgres_settings[0].max_file_size == null
    error_message = "MaxFileSize is a target setting; the source block does not send it"
  }
}

run "plaintext_endpoint_gets_no_secret_role" {
  command = plan

  variables {
    allow_plaintext_credentials = true
    acknowledged_checks         = ["credentials_are_not_in_state"]
    endpoints = {
      source-db = { role = "source", engine = "aurora-postgresql", database_name = "app", secret_arn = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf", certificate_key = "rds-ca" }
      target-db = {
        role     = "target", engine = "aurora-postgresql", database_name = "app", server_name = "tgt.example.com", port = 5432, username = "dms", password = "not-a-real-password", certificate_key = "rds-ca"
        postgres = { after_connect_script = "SET session_replication_role = replica;" }
      }
    }
  }

  assert {
    condition     = keys(aws_iam_role.endpoint_secret) == ["source-db"]
    error_message = "the username/password endpoint is not on the secret path"
  }
}
