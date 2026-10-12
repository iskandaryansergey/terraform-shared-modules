# Renders the launcher with the real runner embedded, for
# tests/runner/test_runner.py. No provider: templatefile and file only.
variable "config_json" {
  type = string
}

output "script" {
  value = templatefile("${path.module}/../../../scripts/launcher.sh.tftpl", {
    region      = "eu-west-1"
    runner_py   = file("${path.module}/../../../scripts/runner.py")
    config_json = var.config_json
  })
}
