# The module next to the endpoint secrets it reads, created in the same plan:
# their ARNs are unknown at plan (live: Aurora sandbox, "Invalid for_each
# argument" on aws_iam_role.endpoint_secret before the fix).
resource "aws_secretsmanager_secret" "db" {
  for_each = toset(["source", "target"])
  name     = "fixture-${each.key}"
}

module "dms" {
  source             = "../../.."
  name               = "test-migration"
  subnet_ids         = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  security_group_ids = ["sg-0123456789abcdef0"]
  engine_version     = "3.5.4"
  kms_key_arn        = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
  certificates       = { rds-ca = { pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----" } }
  endpoints = {
    source-db = { role = "source", engine = "aurora-postgresql", database_name = "app", secret_arn = aws_secretsmanager_secret.db["source"].arn, certificate_key = "rds-ca" }
    target-db = {
      role     = "target", engine = "aurora-postgresql", database_name = "app", secret_arn = aws_secretsmanager_secret.db["target"].arn, certificate_key = "rds-ca"
      postgres = { after_connect_script = "SET session_replication_role = replica;" }
    }
  }
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

output "endpoint_arns" {
  value = module.dms.endpoint_arns
}
