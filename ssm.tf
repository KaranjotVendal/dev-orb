# SSM Parameter Store entries the box reads at boot / run time. Created here as
# PLACEHOLDERS; the real values are set out-of-band (`aws ssm put-parameter
# --overwrite`) — the id-token by the laptop broker at 05:55, the seat bundles /
# webhook / SSH key by the operator at provisioning time. `ignore_changes = [value]`
# keeps Terraform from clobbering those real values on later applies.

# SecureString secrets: the Snowflake private key (key-pair auth), the three codex seat
# bundles, the DEBUG webhook, and the legacy id-token (retired with externalbrowser in
# key-pair Task 2 and kept only until its producer is decommissioned).
resource "aws_ssm_parameter" "secure" {
  for_each = toset(concat(
    [local.token_param_name, local.debug_webhook_param_name, local.private_key_param_name],
    local.seat_param_names,
  ))

  name = each.value
  type = "SecureString"
  # Intelligent-Tiering keeps Standard pricing for the small params (id-token, webhook)
  # and auto-promotes the >4KB codex seat auth bundles to Advanced. Declared here (not set
  # out of band) so the tier does not drift on later plans.
  tier  = "Intelligent-Tiering"
  value = "PLACEHOLDER" # real value set out of band; see lifecycle below

  lifecycle {
    ignore_changes = [value]
  }
}

# The daily-run user's authorized SSH public key. A String (public key, non-secret);
# reached only over the SSM port-forward tunnel (no security-group SSH ingress). If
# deploy_ssh_public_key is unset it stays PLACEHOLDER (set out of band at GATE 2).
resource "aws_ssm_parameter" "ssh_authorized_key" {
  name  = local.ssh_key_param_name
  type  = "String"
  value = var.deploy_ssh_public_key == "" ? "PLACEHOLDER" : var.deploy_ssh_public_key

  lifecycle {
    ignore_changes = [value]
  }
}

# The Snowflake connection identity: a dotenv-format block of non-secret SF_*
# identifiers (SF_ACCOUNT/SF_USER/SF_ROLE/SF_WAREHOUSE/SF_DATABASE/SF_SCHEMA). Auth is the
# RSA private key (a separate SecureString), so these stay IDENTIFIERS only — a String.
#
# ATTENTION: this block currently holds the operator's SSO identity, left over from the
# id-token era. The key is registered on SOLD_RATE_AGENT_USER, so it MUST be repointed at
# the service user before the first key-pair run: a correct key under the wrong SF_USER
# fails auth, and this is the likeliest cause of a failed first live run.
# Seeded PLACEHOLDER here; the operator sets the real dotenv block out of band
# (`aws ssm put-parameter --overwrite`). The bootstrap appends it to run.env at boot.
resource "aws_ssm_parameter" "sf_identity" {
  name  = local.sf_identity_param_name
  type  = "String"
  value = "PLACEHOLDER"

  lifecycle {
    ignore_changes = [value]
  }
}
