# Rotation schedule for the RDS-managed master secret. RDS owns the secret and
# rotates it every 7 days on its own; this only replaces the schedule, so a
# rotation lands inside a change window instead of whenever the 7 days run out.
#
# rotate_immediately is set explicitly: the provider defaults it to true, which
# would rotate the master password on the apply that sets the schedule.

resource "aws_secretsmanager_secret_rotation" "master" {
  count = local.create_rotation_schedule ? 1 : 0

  secret_id          = local.managed_secret_arn
  rotate_immediately = var.master_password_rotation.rotate_immediately

  rotation_rules {
    schedule_expression      = var.master_password_rotation.schedule_expression != "" ? var.master_password_rotation.schedule_expression : null
    automatically_after_days = var.master_password_rotation.automatically_after_days > 0 ? var.master_password_rotation.automatically_after_days : null
    duration                 = var.master_password_rotation.duration != "" ? var.master_password_rotation.duration : null
  }
}
