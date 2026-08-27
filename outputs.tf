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
  description = "Encrypted EBS data volume the VM attaches + mounts at the data_mount path."
  value       = aws_ebs_volume.data.id
}
