# =============================================================================
# Unified DevOps Agent Workshop - Provider Configuration
# =============================================================================
# This file configures the AWS and Kubernetes providers.
# 
# Note: The Kubernetes/Helm providers are configured with exec-based auth
# to avoid circular dependencies when EKS is conditionally enabled.
# =============================================================================

# -----------------------------------------------------------------------------
# AWS Provider
# -----------------------------------------------------------------------------

provider "aws" {
  # Region is determined by AWS_REGION environment variable or aws configure
  default_tags {
    tags = {
      ManagedBy   = "terraform"
      Workshop    = "devops-agent-workshop"
      Environment = var.environment_name
    }
  }
}

# ECR provider for us-east-1 (required for public ECR repos)
provider "aws" {
  alias  = "ecr"
  region = "us-east-1"
}

# -----------------------------------------------------------------------------
# Kubernetes Provider (for EKS)
# -----------------------------------------------------------------------------
# Uses exec-based authentication to avoid circular dependencies.
# When EKS is disabled, the provider will have null values but won't be used.

provider "kubernetes" {
  host                   = try(module.eks[0].cluster_endpoint, null)
  cluster_ca_certificate = try(base64decode(module.eks[0].cluster_certificate_authority_data), null)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.eks_cluster_name, "--region", data.aws_region.current.name]
  }
}

# -----------------------------------------------------------------------------
# Helm Provider (for EKS)
# -----------------------------------------------------------------------------
# Used for deploying Helm charts to EKS cluster

provider "helm" {
  kubernetes {
    host                   = try(module.eks[0].cluster_endpoint, null)
    cluster_ca_certificate = try(base64decode(module.eks[0].cluster_certificate_authority_data), null)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.eks_cluster_name, "--region", data.aws_region.current.name]
    }
  }
}

# -----------------------------------------------------------------------------
# Kubectl Provider (for EKS)
# -----------------------------------------------------------------------------
# Used for applying raw Kubernetes manifests

provider "kubectl" {
  host                   = try(module.eks[0].cluster_endpoint, null)
  cluster_ca_certificate = try(base64decode(module.eks[0].cluster_certificate_authority_data), null)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.eks_cluster_name, "--region", data.aws_region.current.name]
  }
}
