# Canonical SSM parameter names, derived once from the prefix so the instance role,
# the broker write grant, the bootstrap reads, and the outputs all agree.

locals {
  # The fresh ~4h id-token the laptop broker pushes at 05:55 and the VM fetches at
  # 06:00. SecureString. This is the ONLY parameter the broker may write.
  token_param_name = "${var.ssm_prefix}/snowflake/id-token"

  # The three codex seat auth bundles (per-seat auth.json). SecureString; set out of
  # band, read at boot into per-seat files.
  seat_param_names = [
    "${var.ssm_prefix}/codex/seat-1",
    "${var.ssm_prefix}/codex/seat-2",
    "${var.ssm_prefix}/codex/seat-3",
  ]

  # The DEBUG Slack webhook the VM run posts the digest to (INV-2: DEBUG only, never
  # the prod/MACS webhook). SecureString.
  debug_webhook_param_name = "${var.ssm_prefix}/slack/debug-webhook"

  # The SSH public key authorized for the daily-run user. String (non-secret).
  ssh_key_param_name = "${var.ssm_prefix}/deploy/ssh-authorized-key"

  # The Snowflake connection identity (non-secret identifiers: SF_ACCOUNT/SF_USER/
  # SF_ROLE/SF_WAREHOUSE/SF_DATABASE/SF_SCHEMA) written into run.env. String (auth is
  # the injected id-token, not these); set out of band.
  sf_identity_param_name = "${var.ssm_prefix}/snowflake/identity"

  # The RSA private key for key-pair auth, stored as base64 of the PKCS#8 PEM (the .p8.b64
  # shape). SecureString, STATIC -- unlike the id-token it is not re-minted nightly, so the
  # 06:00 wrapper fetches it only to survive an instance replacement. Read by the instance
  # role through the existing ssm_prefix/* grant; no new IAM statement is needed.
  private_key_param_name = "${var.ssm_prefix}/snowflake/private-key-b64"

  # Where the durable EBS volume mounts and where the deployed repo lives.
  data_mount   = "/mnt/sra-data"
  run_user     = "sra"
  remote_repo  = "/mnt/sra-data/sold-rate-agent"
  cache_dir    = "/mnt/sra-data/cache"
  session_logs = "/mnt/sra-data/logs"
}
