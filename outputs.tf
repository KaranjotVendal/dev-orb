output "instance_id" {
  description = "ID of the runner VM — the --target for SSM Session Manager and the deploy tunnel."
  value       = aws_instance.box.id
}

output "instance_role_arn" {
  description = "IAM role the VM runs as (SSM Session Manager + scoped SSM param read + KMS decrypt)."
  value       = aws_iam_role.instance.arn
}

output "instance_profile_name" {
  description = "Instance profile attached to the VM."
  value       = aws_iam_instance_profile.instance.name
}

output "instance_security_group_id" {
  description = "Security group for the VM (no ingress; egress only)."
  value       = aws_security_group.instance.id
}

output "instance_subnet_id" {
  description = "Deterministically-picked default-VPC subnet the VM launches into."
  value       = local.instance_subnet_id
}

output "instance_availability_zone" {
  description = "AZ of the picked subnet — where both the instance and the EBS data volume live."
  value       = data.aws_subnet.selected.availability_zone
}

output "instance_ami_id" {
  description = "Ubuntu LTS AMI the VM boots from."
  value       = data.aws_ami.ubuntu.id
}

output "data_volume_id" {
  description = "Encrypted EBS data volume the VM attaches + mounts (serving cache + session logs + repo)."
  value       = aws_ebs_volume.data.id
}

output "token_ssm_param_name" {
  description = "SSM SecureString parameter the broker writes the fresh id-token to and the VM fetches at 06:00."
  value       = local.token_param_name
}

output "seat_ssm_param_names" {
  description = "SSM SecureString parameters holding the three codex seat auth bundles."
  value       = local.seat_param_names
}

output "debug_webhook_ssm_param_name" {
  description = "SSM SecureString parameter holding the DEBUG Slack webhook (INV-2: DEBUG only)."
  value       = local.debug_webhook_param_name
}

output "sf_identity_ssm_param_name" {
  description = "SSM String parameter holding the non-secret Snowflake connection identity (SF_* identifiers) appended to run.env."
  value       = local.sf_identity_param_name
}

output "broker_role_arn" {
  description = "Narrow role the laptop broker assumes to ssm:PutParameter ONLY the id-token param. Null until broker_principal_arn is set at GATE 2."
  value       = var.broker_principal_arn == "" ? null : aws_iam_role.broker[0].arn
}
