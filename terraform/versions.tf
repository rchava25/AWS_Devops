# =============================================================================
# Unified DevOps Agent Workshop - Terraform Version Requirements
# =============================================================================
# This file specifies the required Terraform and provider versions.
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
      # Upper bound: stay on the v2 line. Do not float to a future v3 without
      # reviewing schema changes (see helm pin below for why this matters).
      version = ">= 2.25.0, < 3.0.0"
    }
    helm = {
      source = "hashicorp/helm"
      # PINNED to the v2 line intentionally. helm provider v3 (2025) was
      # rewritten on the Plugin Framework and changed HCL syntax: `set` blocks
      # became a list attribute, the provider `kubernetes {}` nested block
      # became an object, and `registry` became `registries`. Our provider
      # config in providers.tf and the resources here use v2 syntax. Floating
      # to v3 on a fresh `terraform init` (there is no committed lock file)
      # would break the apply. Bump deliberately, not by accident.
      version = ">= 2.12.0, < 3.0.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.0.0, < 3.0.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.10.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
  }
}
