# One instance, reached only through SSM. No inbound rule, no key pair, no
# public address, no user data: the AMI arrives complete (see var.ami_id).

resource "aws_instance" "this" {
  count = local.create ? 1 : 0

  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = concat([aws_security_group.this[0].id], var.additional_security_group_ids)
  iam_instance_profile   = aws_iam_instance_profile.this[0].name

  associate_public_ip_address = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    kms_key_id            = var.kms_key_arn != "" ? var.kms_key_arn : null
    delete_on_termination = true
  }

  tags        = merge(local.common_tags, { "Name" = "${var.name}-sql-bastion" })
  volume_tags = local.common_tags

  lifecycle {
    precondition {
      condition     = length(local.insecure_targets) == 0 ? true : var.allow_insecure_transport
      error_message = "these targets do not verify the server certificate: ${join(", ", local.insecure_targets)}. Use verify-full with ca_bundle_path, or set allow_insecure_transport = true."
    }
  }
}

# Stopping is the off switch between waves. The instance, its role and the
# document stay; only the compute stops billing.
resource "aws_ec2_instance_state" "this" {
  count = local.create ? 1 : 0

  instance_id = aws_instance.this[0].id
  state       = var.running ? "running" : "stopped"
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

resource "aws_security_group" "this" {
  count = local.create ? 1 : 0

  name        = "${var.name}-sql-bastion"
  description = "dms-sql-bastion ${var.name}: no ingress; egress to VPC endpoints and the target databases only"
  vpc_id      = var.vpc_id

  revoke_rules_on_delete = true

  tags = merge(local.common_tags, { "Name" = "${var.name}-sql-bastion" })
}

resource "aws_vpc_security_group_egress_rule" "https" {
  for_each = local.create ? local.https_egress : {}

  security_group_id = aws_security_group.this[0].id
  description       = "HTTPS to SSM, Secrets Manager, S3, CloudWatch Logs"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443

  referenced_security_group_id = each.value.security_group_id
  prefix_list_id               = each.value.prefix_list_id
  cidr_ipv4                    = each.value.cidr

  tags = local.common_tags
}

resource "aws_vpc_security_group_egress_rule" "database" {
  for_each = local.create ? local.database_egress : {}

  security_group_id = aws_security_group.this[0].id
  description       = "Database port"
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port

  referenced_security_group_id = each.value.security_group_id
  cidr_ipv4                    = each.value.cidr

  tags = local.common_tags
}

# The other half: the database lets the bastion in. Written on the database's
# security group, so manage_target_ingress = false when another team owns it.
resource "aws_vpc_security_group_ingress_rule" "target" {
  for_each = local.create ? local.target_ingress : {}

  security_group_id            = each.value.security_group_id
  description                  = "dms-sql-bastion ${var.name}"
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  referenced_security_group_id = aws_security_group.this[0].id

  tags = local.common_tags
}

resource "aws_vpc_security_group_egress_rule" "additional" {
  for_each = local.create ? local.extra_egress : {}

  security_group_id = aws_security_group.this[0].id
  description       = each.value.description != "" ? each.value.description : each.key
  ip_protocol       = each.value.protocol
  from_port         = each.value.from_port
  to_port           = each.value.to_port

  referenced_security_group_id = each.value.security_group_id
  prefix_list_id               = each.value.prefix_list_id
  cidr_ipv4                    = each.value.cidr

  tags = local.common_tags
}
