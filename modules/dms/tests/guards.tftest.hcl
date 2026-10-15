# The fixes that the mocked suite could not see on its own, because each one
# is about how AWS behaves rather than how the graph is shaped: SSL modes per
# engine, the database name on the secret path, the IAM trust condition, the
# task dimension CloudWatch publishes under, logging posture from the merged
# settings, and the configurations DMS refuses at apply.
#
# Plan runs first; the apply runs at the end need the task ARN.

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
  # The account-wide service roles exist; tests that need them missing
  # override this.
  mock_data "aws_iam_roles" {
    defaults = { names = ["dms-vpc-role", "dms-cloudwatch-logs-role"] }
  }
  mock_resource "aws_dms_replication_instance" {
    defaults = {
      replication_instance_arn = "arn:aws:dms:eu-west-1:111122223333:rep:MOCKINSTANCE"
      replication_instance_id  = "mock-instance"
    }
  }
  mock_resource "aws_dms_endpoint" {
    defaults = { endpoint_arn = "arn:aws:dms:eu-west-1:111122223333:endpoint:MOCKENDPOINT" }
  }
  mock_resource "aws_dms_s3_endpoint" {
    defaults = { endpoint_arn = "arn:aws:dms:eu-west-1:111122223333:endpoint:MOCKS3" }
  }
  mock_resource "aws_dms_certificate" {
    defaults = { certificate_arn = "arn:aws:dms:eu-west-1:111122223333:cert:MOCKCERT" }
  }
  mock_resource "aws_dms_replication_task" {
    defaults = {
      replication_task_arn = "arn:aws:dms:eu-west-1:111122223333:task:MOCKTASK"
      replication_task_id  = "mock-task"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/mock" }
  }
}

# A fully configured migration, not a minimal one: terraform test treats a
# failing check as an error, so a minimal baseline would fail on the module's
# own advisory checks.
variables {
  name = "test-migration"

  subnet_ids         = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  security_group_ids = ["sg-0123456789abcdef0"]

  engine_version = "3.5.3"
  kms_key_arn    = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"

  certificates = {
    rds-ca = { pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----" }
  }

  endpoints = {
    source-db = {
      role               = "source"
      engine             = "postgres"
      server_name        = "src.example.com"
      port               = 5432
      database_name      = "app"
      secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf"
      secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
      ssl_mode           = "verify-full"
      certificate_key    = "rds-ca"
    }
    target-db = {
      role               = "target"
      engine             = "aurora-postgresql"
      server_name        = "tgt.example.com"
      port               = 5432
      database_name      = "app"
      secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:tgt-AbCdEf"
      secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
      ssl_mode           = "verify-full"
      certificate_key    = "rds-ca"
      postgres = {
        # Triggers off and foreign keys deferred for the duration of the load.
        after_connect_script = "SET session_replication_role = replica;"
      }
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

  # 15% of the 50 GB default, so the storage alarm leaves room to react.
  alarm_free_storage_bytes = 8589934592

  sns_topic_arn = "arn:aws:sns:eu-west-1:111122223333:migrations"
}


# ---------------------------------------------------------------------------
# SSL modes DMS supports per engine
# ---------------------------------------------------------------------------

# Guards that had no failing-case run: each is tripped here on its own, with
# every other input clean, so the address in expect_failures can mean only the
# precondition named in the comment.

run "availability_zone_with_multi_az_is_refused" {
  command = plan

  # replication.tf: availability_zone is only meaningful when multi_az is false.
  variables {
    availability_zone = "eu-west-1a"
    multi_az          = true
  }

  expect_failures = [aws_dms_replication_instance.this]
}

run "require_cmk_refuses_an_s3_target_without_a_customer_key" {
  command = plan

  # endpoints.tf: require_cmk reaches S3 targets too.
  variables {
    require_cmk = true
    s3_targets = {
      lake = {
        bucket_name     = "lake-bucket"
        encryption_mode = "SSE_S3"
      }
    }
  }

  expect_failures = [aws_dms_s3_endpoint.this]
}

run "require_cmk_in_serverless_refuses_the_aws_managed_storage_key" {
  command = plan

  # replication.tf: in serverless mode the replication config is the only place the storage key is gated. Endpoints carry their own key so only that gate can fire.
  variables {
    compute_mode = "serverless"
    require_cmk  = true
    kms_key_arn  = ""
    endpoints = {
      source-db = {
        role               = "source"
        engine             = "postgres"
        server_name        = "src.example.com"
        port               = 5432
        database_name      = "app"
        secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf"
        secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        ssl_mode           = "verify-full"
        certificate_key    = "rds-ca"
        kms_key_arn        = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
      }
      target-db = {
        role               = "target"
        engine             = "aurora-postgresql"
        server_name        = "tgt.example.com"
        port               = 5432
        database_name      = "app"
        secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:tgt-AbCdEf"
        secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        ssl_mode           = "verify-full"
        certificate_key    = "rds-ca"
        postgres = {
          after_connect_script = "SET session_replication_role = replica;"
        }
        kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
      }
    }
  }

  expect_failures = [aws_dms_replication_config.this, check.serverless_replication_is_not_watched_by_this_module]
}

run "cleartext_transport_warns_when_it_is_allowed" {
  command = plan

  # observability.tf: allow_insecure_transport lifts the refusal; the check still says it out loud.
  variables {
    allow_insecure_transport = true
    endpoints = {
      source-db = {
        role               = "source"
        engine             = "postgres"
        server_name        = "src.example.com"
        port               = 5432
        database_name      = "app"
        secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf"
        secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        ssl_mode           = "none"
      }
      target-db = {
        role               = "target"
        engine             = "aurora-postgresql"
        server_name        = "tgt.example.com"
        port               = 5432
        database_name      = "app"
        secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:tgt-AbCdEf"
        secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        ssl_mode           = "verify-full"
        certificate_key    = "rds-ca"
        postgres = {
          after_connect_script = "SET session_replication_role = replica;"
        }
      }
    }
  }

  expect_failures = [check.transport_is_verified]
}

# ---------------------------------------------------------------------------
# DMS Serverless supports a subset of engines (replication.tf precondition on
# the subnet group). Validation is acknowledged where DMS cannot validate the
# engine, so that check cannot be what trips the run.
# ---------------------------------------------------------------------------

run "serverless_refuses_a_sap_ase_endpoint" {
  command = plan

  variables {
    compute_mode        = "serverless"
    acknowledged_checks = ["validation_is_claimed_where_it_cannot_run"]
    endpoints = {
      source-db = {
        role               = "source"
        engine             = "sybase"
        server_name        = "src.example.com"
        port               = 5000
        database_name      = "app"
        secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf"
        secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        ssl_mode           = "verify-full"
        certificate_key    = "rds-ca"
      }
      target-db = {
        role               = "target"
        engine             = "aurora-postgresql"
        server_name        = "tgt.example.com"
        port               = 5432
        database_name      = "app"
        secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:tgt-AbCdEf"
        secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        ssl_mode           = "verify-full"
        certificate_key    = "rds-ca"
        postgres = {
          after_connect_script = "SET session_replication_role = replica;"
        }
      }
    }
  }

  expect_failures = [aws_dms_replication_subnet_group.this, check.serverless_replication_is_not_watched_by_this_module]
}

run "serverless_refuses_a_db2_target" {
  command = plan

  variables {
    compute_mode = "serverless"
    endpoints = {
      source-db = {
        role               = "source"
        engine             = "postgres"
        server_name        = "src.example.com"
        port               = 5432
        database_name      = "app"
        secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf"
        secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        ssl_mode           = "verify-full"
        certificate_key    = "rds-ca"
      }
      target-db = {
        role               = "target"
        engine             = "db2"
        server_name        = "tgt.example.com"
        port               = 5432
        database_name      = "app"
        secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:tgt-AbCdEf"
        secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        ssl_mode           = "none"
      }
    }
    allow_insecure_transport = true
    acknowledged_checks      = ["transport_is_verified"]
  }

  expect_failures = [aws_dms_replication_subnet_group.this, check.serverless_replication_is_not_watched_by_this_module]
}

run "serverless_refuses_ssl_on_a_db2_source" {
  command = plan

  variables {
    compute_mode = "serverless"
    endpoints = {
      source-db = {
        role               = "source"
        engine             = "db2"
        server_name        = "src.example.com"
        port               = 50000
        database_name      = "app"
        secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf"
        secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        ssl_mode           = "verify-ca"
        certificate_key    = "rds-ca"
      }
      target-db = {
        role               = "target"
        engine             = "aurora-postgresql"
        server_name        = "tgt.example.com"
        port               = 5432
        database_name      = "app"
        secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:tgt-AbCdEf"
        secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        ssl_mode           = "verify-full"
        certificate_key    = "rds-ca"
        postgres = {
          after_connect_script = "SET session_replication_role = replica;"
        }
      }
    }
  }

  expect_failures = [aws_dms_replication_subnet_group.this, check.serverless_replication_is_not_watched_by_this_module]
}

run "serverless_accepts_a_db2_source_without_ssl" {
  command = plan

  variables {
    compute_mode             = "serverless"
    allow_insecure_transport = true
    acknowledged_checks      = ["transport_is_verified", "serverless_replication_is_not_watched_by_this_module"]
    endpoints = {
      source-db = {
        role               = "source"
        engine             = "db2"
        server_name        = "src.example.com"
        port               = 50000
        database_name      = "app"
        secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:src-AbCdEf"
        secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        ssl_mode           = "none"
      }
      target-db = {
        role               = "target"
        engine             = "aurora-postgresql"
        server_name        = "tgt.example.com"
        port               = 5432
        database_name      = "app"
        secret_arn         = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:tgt-AbCdEf"
        secret_kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
        ssl_mode           = "verify-full"
        certificate_key    = "rds-ca"
        postgres = {
          after_connect_script = "SET session_replication_role = replica;"
        }
      }
    }
  }

  assert {
    condition     = length(aws_dms_replication_config.this) == 1
    error_message = "a Db2 source without SSL is within what DMS Serverless supports and must plan."
  }
}

# ---------------------------------------------------------------------------
# Certificates: the id follows the content, so a CA rotation is a new
# certificate created before the old one is deleted.
# ---------------------------------------------------------------------------

run "the_certificate_id_carries_a_digest_of_its_content" {
  command = plan

  variables {
    certificates = {
      rds-ca = {
        pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"
      }
    }
  }

  assert {
    condition     = aws_dms_certificate.this["rds-ca"].certificate_id == "test-migration-rds-ca-${substr(sha256(var.certificates["rds-ca"].pem), 0, 8)}"
    error_message = "the certificate id must be <name>-<key>-<8 hex chars of sha256(content)>, or a rotation is an in-place replacement that deletes the in-use certificate first."
  }
}

run "a_rotated_ca_is_a_different_certificate" {
  command = plan

  variables {
    certificates = {
      rds-ca = {
        pem = "-----BEGIN CERTIFICATE-----\nMIIC\n-----END CERTIFICATE-----"
      }
    }
  }

  assert {
    condition     = aws_dms_certificate.this["rds-ca"].certificate_id == "test-migration-rds-ca-${substr(sha256(var.certificates["rds-ca"].pem), 0, 8)}"
    error_message = "a different PEM under the same key must produce a different certificate id."
  }

  assert {
    condition     = aws_dms_certificate.this["rds-ca"].certificate_id != "test-migration-rds-ca-6d20772b"
    error_message = "the id of the previous PEM must not be reused."
  }
}
