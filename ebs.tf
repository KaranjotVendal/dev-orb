# The durable data disk: an encrypted gp3 EBS volume in the instance's AZ. It holds
# the heavy trees (work repos, tool installs, caches, logs) and SURVIVES instance
# replacement — so re-provisioning the box (a user_data edit) keeps the workstation's
# on-disk state. Mounted first-boot-safe by user_data.sh.tftpl (UUID fstab, nofail,
# format-only-if-empty).

resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.selected.availability_zone
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true

  # Name is for console legibility; default_tags still layer
  # Project/Component/ManagedBy on top. (No Backup tag: DLM snapshots were dropped —
  # S3 is the durable cache/session store now.)
  tags = {
    Name = "${var.name}-data"
  }
}
