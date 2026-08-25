# The runner VM itself: Ubuntu LTS AMI, the picked default-VPC subnet, the no-ingress
# security group, and the instance profile, with the durable EBS data volume attached.
# No Elastic IP and no public-facing role: the box is reached only via SSM Session
# Manager (outbound), so it needs no stable public address.

resource "aws_instance" "box" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = local.instance_subnet_id
  vpc_security_group_ids = [aws_security_group.instance.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  # Explicit: the box needs a public IP for OUTBOUND SSM in the default VPC (it reaches
  # the SSM endpoints over the internet gateway). Harmless given the zero-ingress SG —
  # nothing can connect IN. Stated rather than relying on the subnet's default.
  associate_public_ip_address = true

  # Editing the bootstrap cleanly re-provisions the instance; the separate EBS data
  # volume re-attaches afterwards, so the serving cache + session logs survive the
  # replacement.
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/../user_data.sh.tftpl", {
    region        = data.aws_region.current.region
    timezone      = var.timezone
    data_mount    = local.data_mount
    ebs_volume_id = aws_ebs_volume.data.id
    run_user      = local.run_user
    remote_repo   = local.remote_repo
    cache_dir     = local.cache_dir
    session_logs  = local.session_logs
    dashboard_url = var.dashboard_url

    # SSM parameter names read at boot (seat bundles + DEBUG webhook + SSH key). The
    # id-token param is NOT read at boot — it is pushed at 05:55, after boot, so the
    # 06:00 wrapper fetches it fresh (see the wrapper contract / Finding 2).
    token_param_name         = local.token_param_name
    seat_param_names         = local.seat_param_names
    debug_webhook_param_name = local.debug_webhook_param_name
    ssh_key_param_name       = local.ssh_key_param_name
    sf_identity_param_name   = local.sf_identity_param_name
    private_key_param_name   = local.private_key_param_name
  })

  # NB the 06:00 schedule units live in deploy/remote-vm/systemd/ and are installed +
  # enabled by deploy.sh at the first code deploy, NOT by this bootstrap: the units
  # and the code they run (vm_daily_run.sh) must arrive together, so a timer enabled
  # at boot would only fire against absent code until that first deploy.

  root_block_device {
    encrypted = true
  }

  # No credentials or secrets in metadata; require IMDSv2 (token-bound) to blunt SSRF.
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  tags = {
    Name = "${var.name}-box"
  }
}

# On Ubuntu/nitro this device surfaces as a predictable NVMe device; user_data's
# mount logic resolves the nitro name from the volume id.
resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.box.id

  # On a user_data_replace_on_change re-provision, do NOT let Terraform race a
  # DetachVolume against the still-running old instance where /mnt/sra-data is
  # mounted+busy (it would stall in `detaching` until timeout and error the apply —
  # exactly the re-provision-to-inspect-evidence flow the durable volume exists for).
  # skip_destroy leaves detach to the instance's graceful terminate (AWS auto-detaches),
  # avoiding both the stall and the fs-corruption risk of a force_detach.
  skip_destroy = true
}
