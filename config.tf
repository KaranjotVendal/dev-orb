# Self-contained root module for a single agent-workstation VM. Stripped of all
# CI/registry surface (no container registry, no OIDC, no CDN) — the laptop is the
# single control plane (direct code deploy + token push over SSM). No SSH ingress;
# access is via SSM. Plain AWS provider, applied with local Terraform + CLI creds.
# State is local; the account is pinned via allowed_account_ids (no default here so
# an unpinned apply cannot touch the wrong account).

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  # Guard: refuse to run against anything but the sanctioned account (supplied at
  # apply time). An empty list disables the guard, so the account id MUST be supplied.
  allowed_account_ids = var.allowed_account_ids

  default_tags {
    tags = var.tags
  }
}
