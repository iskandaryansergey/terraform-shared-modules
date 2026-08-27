# Offline render fixture.
#
# create = false, so no resource is created and no AWS API is called - the module's
# data sources are all count-gated and its locals fall back to placeholders. That
# is what lets this apply with fake credentials in CI and emit the real rendered
# config.toml and fargate.toml for a parser to check (R8).
#
# The point of this fixture is that substring assertions cannot catch structural
# bugs. "instance_ready_command appears in the file" says nothing about which TOML
# table it landed in, and TOML binds a bare key to whichever table was opened
# last. Only a parser can tell those apart.
#
# Neither output is sensitive, and that is asserted deliberately: nothing secret
# reaches these files. The runner token is a placeholder substituted at container
# start from Secrets Manager. If a future change puts a real secret in here, the
# test suite fails rather than the property silently degrading (R10).

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0, < 6.0.0"
    }
  }
}

provider "aws" {
  region                      = "eu-west-1"
  access_key                  = "mock_access_key"
  secret_key                  = "mock_secret_key"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

module "runners" {
  source = "../.."

  create = false

  name       = "ci-render"
  gitlab_url = "https://gitlab.example.com/gitlab"

  runner_token_secret_arn = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:gitlab/runner/token-AbCdEf"

  vpc_id             = "vpc-0123456789abcdef0"
  manager_subnet_ids = ["subnet-0aaa1111bbbb2222c"]
  job_subnet_ids     = ["subnet-0ddd3333eeee4444f", "subnet-0fff5555aaaa6666b"]

  manager_image      = "111122223333.dkr.ecr.eu-west-1.amazonaws.com/gitlab-runner-manager@sha256:1111111111111111111111111111111111111111111111111111111111111111"
  manager_concurrent = 12

  job_profiles = {
    # Deliberately not first alphabetically, so the fixture proves the default
    # profile is chosen deterministically rather than by map ordering.
    small = {
      image  = "111122223333.dkr.ecr.eu-west-1.amazonaws.com/ci-small@sha256:2222222222222222222222222222222222222222222222222222222222222222"
      cpu    = 512
      memory = 1024
    }
    big = {
      image             = "111122223333.dkr.ecr.eu-west-1.amazonaws.com/ci-big@sha256:3333333333333333333333333333333333333333333333333333333333333333"
      cpu               = 2048
      memory            = 8192
      ephemeral_storage = 50
      ssh_username      = "ci"
      health_check_cmd  = ["CMD-SHELL", "pgrep sshd || exit 1"]
    }
  }

  cache_bucket_name = "example-runner-cache"
  cache_path        = "ci-render"

  # Hostile-ish values that must survive encoding into TOML without changing its
  # structure. A newline here is the classic way a config template turns into a
  # config with extra keys.
  job_extra_egress_rules = [
    { protocol = "tcp", port = 5000, cidrs = ["10.20.0.0/16"], description = "internal registry" },
  ]

  create_alarms = false
  tags          = { Environment = "render-fixture" }
}

output "config_toml" {
  value = module.runners.config_toml
}

output "fargate_toml" {
  value = module.runners.fargate_toml
}

output "job_egress_cidrs_effective" {
  value = module.runners.job_egress_cidrs_effective
}

output "job_egress_rule_count" {
  value = module.runners.job_egress_rule_count
}
