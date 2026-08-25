variable "region" {
  description = "AWS region for the runner VM."
  type        = string
  default     = "eu-west-1"
}

variable "allowed_account_ids" {
  description = "Accounts Terraform is allowed to run against (the sanctioned mlops account). REQUIRED (no default) so plan/apply fails CLOSED when unset — an empty list would DISABLE the provider guard and target whatever account the ambient creds point at. `validate` does not need a value, so the offline gate stays green. Supply at GATE 2."
  type        = list(string)

  validation {
    condition     = length(var.allowed_account_ids) > 0
    error_message = "allowed_account_ids must list at least one account id — the guard fails closed."
  }
}

variable "name" {
  description = "Name prefix for the runner-VM resources."
  type        = string
  default     = "sra-vm"
}

variable "tags" {
  description = "Tags applied to all resources (via the provider default_tags)."
  type        = map(string)
  default = {
    Project   = "sold-rate-agent"
    Component = "remote-vm-runner"
    ManagedBy = "terraform"
    Interim   = "true"
  }
}

# --- SSM ---------------------------------------------------------------------

variable "ssm_prefix" {
  description = "SSM Parameter Store prefix for this box's secrets. The instance role's read grant and the laptop broker's write grant are both scoped under this subtree."
  type        = string
  default     = "/sold-rate-agent/vm"
}

# --- Cache transfer (S3) -----------------------------------------------------

variable "cache_bucket" {
  description = "S3 bucket the VM uploads the daily serving cache + sessions to (the durable cache-transfer store the laptop/SPCS side then fetches). PRE-EXISTS and is operator-managed (region eu-north-1) — this module references it only, it does NOT create it. The instance role gets an upload-only grant on just this bucket."
  type        = string
  default     = "sold-rate-agent"
}

# --- Network / instance ------------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type. Sized UP from jot-server's t3.small to a memory-headroom class (t3.large = 8 GiB, t3.xlarge = 16 GiB) to avoid the OOM-at-51/60 that motivated moving the run off the laptop."
  type        = string
  default     = "t3.xlarge"
}

variable "data_volume_size_gb" {
  description = "Size of the encrypted gp3 EBS data volume (SRA_CACHE_DIR serving cache + session logs + the deployed repo)."
  type        = number
  default     = 50
}

variable "dashboard_url" {
  description = "Public dashboard ingress the Slack digest links to (the deployed SPCS app URL). Written into the VM run .env; not a secret."
  type        = string
  default     = "https://dashboard.example.com"
}

variable "timezone" {
  description = "IANA timezone the VM's clock is set to at boot, so the 06:00 systemd timer fires in the same wall-clock as the laptop's 05:55 broker."
  type        = string
  default     = "Europe/London"
}

# --- Laptop broker (token push) ----------------------------------------------

variable "broker_principal_arn" {
  description = "The laptop broker's AWS principal ARN (IAM user/role) allowed to assume the narrow broker role that can ssm:PutParameter ONLY the id-token parameter. Set at GATE 2; empty means the broker role trusts no one (assume fails closed)."
  type        = string
  default     = ""
}

variable "deploy_ssh_public_key" {
  description = "SSH public key authorized for the daily-run user (fetched at boot into authorized_keys). Reached ONLY over the SSM port-forward tunnel — no security-group SSH ingress. Non-secret; a String SSM param."
  type        = string
  default     = ""
}
