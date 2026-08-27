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
  description = "SSM Parameter Store prefix for this box's secrets (e.g. the GitHub token orb reads at setup). The instance role's read grant is scoped under this subtree."
  type        = string
  default     = "/sold-rate-agent/vm"
}

# --- Network / instance ------------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type. A memory-headroom class (t3.large = 8 GiB, t3.xlarge = 16 GiB) so parallel agent sessions + tool builds have room."
  type        = string
  default     = "t3.xlarge"
}

variable "data_volume_size_gb" {
  description = "Size of the encrypted gp3 EBS data volume mounted at data_mount (the durable work trees, tool installs, caches, and logs)."
  type        = number
  default     = 50
}

variable "timezone" {
  description = "IANA timezone the VM's clock is set to at boot."
  type        = string
  default     = "Europe/London"
}
