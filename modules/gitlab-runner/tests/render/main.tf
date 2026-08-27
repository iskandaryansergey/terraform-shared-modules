# Offline render fixture. create = false means no AWS API calls and no
# credentials, but config.toml and the bootstrap script are pure functions of the
# inputs, so they still render - which lets CI parse them properly.
#
# This exists because `terraform test` can only pattern-match strings. A TOML key
# emitted under the wrong table still matches a substring assertion; only a real
# parser catches it.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.40.0, < 6.0.0" }
  }
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

module "runner" {
  source = "../.."

  create = false # nothing is created; the templates still render

  name = "render"
  # BYO network. Verification is off because this fixture applies with FAKE
  # credentials and must make zero AWS calls - that is what lets it render the
  # real config.toml and bootstrap offline.
  manager_security_group_ids        = ["sg-0aaaaaaaaaaaaaaa1"]
  worker_security_group_ids         = ["sg-0bbbbbbbbbbbbbbb2"]
  verify_manager_to_worker_ssh_rule = false
  worker_subnet_ids                 = ["subnet-render"]
  runner_token                      = "glrt-RENDERONLY"

  gitlab_runner_version   = "17.9.0-1"
  fleeting_plugin_version = "1.1.0"

  # exercise the fields most likely to be misplaced or mis-escaped
  worker_ready_command = "docker info >/dev/null 2>&1"
  scale_throttle       = { limit = 5, burst = 10 }
  allowed_images       = ["registry.example.com/ci/*"]
  allowed_services     = ["registry.example.com/svc/*"]
  runner_environment   = ["DOCKER_DRIVER=overlay2"]
  # A bare key AND a table header, so the parser can prove where each lands.
  extra_runner_config_toml = "[runners.cache]\n  Type = \"s3\"\n  Path = \"probe\""

  # Catch-all FIRST, per last-match-wins. This fixture previously shipped the
  # reversed order - the same defect the module's default had - so the artifact it
  # produced for the parser to check encoded the bug rather than exposing it.
  autoscaling_policies = [
    { idle_count = 0, idle_time = "5m0s", periods = ["* * * * *"] },
    { idle_count = 2, idle_time = "20m0s", periods = ["* 8-18 * * mon-fri"], timezone = "Europe/London" },
  ]
}

# Both are sensitive at the module boundary (they embed runner_environment and
# extra_runner_config_toml), so they must be re-declared sensitive here. Read them
# with `terraform output -raw`. This is a render fixture with a fake token, so
# nothing secret is actually present.
output "config_toml" {
  value     = module.runner.config_toml
  sensitive = true
}

output "manager_user_data" {
  value     = module.runner.manager_user_data_preview
  sensitive = true
}
