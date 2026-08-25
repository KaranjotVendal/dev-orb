# Self-contained root module for the interim Sold-Rate-Agent runner VM (INV-7:
# shed-able wholesale). Adapted from jot-server's terraform-beta single-box mlops
# stack, stripped of all CI/registry surface (no ECR, no CircleCI-OIDC, no
# CloudFront) — the laptop is the single control plane (direct code deploy + token
# push over SSM). Plain AWS provider, applied with local Terraform + CLI creds.
# State is local for this interim box; the account is pinned via allowed_account_ids
# at GATE 2 (no default here so an unpinned apply cannot touch the wrong account).

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

  # Guard: refuse to run against anything but the sanctioned mlops account (set at
  # GATE 2). An empty list disables the guard, so GATE 2 MUST supply the account id.
  allowed_account_ids = var.allowed_account_ids

  default_tags {
    tags = var.tags
  }
}
