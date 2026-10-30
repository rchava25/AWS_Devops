# EKS Module for Unified DevOps Agent Workshop
# Provisions EKS cluster with Auto Mode for the retail store application
# Migrated from aws-devops-agent-workshop/assetsSrc/terraform/eks.tf

# =============================================================================
# DATA SOURCES
# =============================================================================

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_elb_service_account" "main" {}

locals {
  region         = data.aws_region.current.name
  aws_account_id = data.aws_caller_identity.current.account_id
  aws_partition  = data.aws_partition.current.id
}

# =============================================================================
# S3 BUCKET FOR ALB ACCESS LOGS
# =============================================================================

resource "aws_s3_bucket" "alb_logs" {
  bucket_prefix = "${var.cluster_name}-alb-logs-"
  force_destroy = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-alb-logs"
  })
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_elb_service_account.main.id}:root"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.alb_logs.arn}/*"
      },
      {
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.alb_logs.arn}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      },
      {
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.alb_logs.arn
      }
    ]
  })
}

# =============================================================================
# IAM ROLES FOR EKS AUTO MODE
# =============================================================================

# IAM Role for EKS Auto Mode nodes
resource "aws_iam_role" "eks_auto_node" {
  name = "${var.cluster_name}-eks-auto-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = ["sts:AssumeRole", "sts:TagSession"]
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "eks_auto_node_worker" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy"
  role       = aws_iam_role.eks_auto_node.name
}

resource "aws_iam_role_policy_attachment" "eks_auto_node_ecr" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
  role       = aws_iam_role.eks_auto_node.name
}

# IAM Role for EKS Auto Mode cluster
resource "aws_iam_role" "eks_auto_cluster" {
  name = "${var.cluster_name}-eks-auto-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = ["sts:AssumeRole", "sts:TagSession"]
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

# Required policies for EKS Auto Mode cluster role
resource "aws_iam_role_policy_attachment" "eks_auto_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_auto_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_auto_compute_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSComputePolicy"
  role       = aws_iam_role.eks_auto_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_auto_block_storage_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy"
  role       = aws_iam_role.eks_auto_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_auto_load_balancing_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy"
  role       = aws_iam_role.eks_auto_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_auto_networking_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy"
  role       = aws_iam_role.eks_auto_cluster.name
}

# =============================================================================
# EKS CLUSTER (using terraform-aws-modules/eks/aws)
# =============================================================================

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  # Use the default kubernetes provider (passed from parent module)
  # The parent module configures this provider with the cluster credentials

  cluster_name                   = var.cluster_name
  cluster_version                = var.kubernetes_version
  cluster_endpoint_public_access = true

  # Use custom cluster role with Auto Mode policies
  create_iam_role = false
  iam_role_arn    = aws_iam_role.eks_auto_cluster.arn

  # Enable all control plane logging
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # Tags for CloudWatch log group
  cloudwatch_log_group_tags = var.tags

  # Access configuration - API_AND_CONFIG_MAP mode
  authentication_mode = "API_AND_CONFIG_MAP"

  # Access entries managed via AWS Console or CDK
  access_entries = {}

  # EKS Auto Mode configuration
  cluster_compute_config = {
    enabled       = true
    node_pools    = var.node_pools
    node_role_arn = aws_iam_role.eks_auto_node.arn
  }

  # Disable self-managed addons for Auto Mode
  bootstrap_self_managed_addons = false

  # Auto Mode handles these - no additional addons needed
  # metrics-server is managed by Auto Mode automatically
  cluster_addons = {}

  vpc_id                   = var.vpc_id
  subnet_ids               = var.private_subnets
  control_plane_subnet_ids = var.private_subnets

  # Auto Mode manages compute - no managed node groups
  eks_managed_node_groups = {}

  # Auto Mode manages node security groups
  node_security_group_additional_rules = {}

  # Enable EKS Auto Mode features
  enable_cluster_creator_admin_permissions = true

  # Extend cluster lifecycle timeouts. The default delete timeout (15m) is too
  # short for Auto Mode clusters in recycled workshop accounts — teardown was
  # timing out and leaving stacks in ROLLBACK_FAILED. 30m gives the control
  # plane and Auto Mode compute enough time to drain and delete cleanly.
  cluster_timeouts = {
    create = "30m"
    update = "60m"
    delete = "30m"
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.eks_auto_cluster_policy,
    aws_iam_role_policy_attachment.eks_auto_compute_policy,
    aws_iam_role_policy_attachment.eks_auto_block_storage_policy,
    aws_iam_role_policy_attachment.eks_auto_load_balancing_policy,
    aws_iam_role_policy_attachment.eks_auto_networking_policy,
  ]
}

# =============================================================================
# CLUSTER AUTH DATA SOURCES
# =============================================================================

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name

  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name

  depends_on = [module.eks]
}

# =============================================================================
# TIMING RESOURCES FOR DEPENDENCIES
# =============================================================================

# EKS access-entry propagation delay.
# `enable_cluster_creator_admin_permissions = true` creates the access entry +
# policy association that grants the Terraform runner role (SharedRole) cluster
# admin. That grant is eventually consistent — the Kubernetes API server can
# still return 403 for a short window after the access entry is created. Any
# Kubernetes-provider resource (ClusterRole, ConfigMap, IngressClass, etc.)
# created in that window fails with "cannot create clusterroles ... forbidden",
# which fails the whole apply and forces a retry (blowing past the 60m CFN
# custom-resource ceiling). Waiting ~30s after the cluster/access entry is
# ready lets the grant propagate before the first K8s call.
resource "time_sleep" "eks_access_propagation" {
  depends_on = [module.eks]

  create_duration = "30s"
}

resource "null_resource" "cluster_blocker" {
  depends_on = [time_sleep.eks_access_propagation]
}

# =============================================================================
# NETWORK POLICY CONTROLLER FOR EKS AUTO MODE
# =============================================================================

# Enable Network Policy Controller for EKS Auto Mode
# This ConfigMap enables the VPC CNI network policy controller on Auto Mode nodes
# Reference: https://docs.aws.amazon.com/eks/latest/userguide/auto-net-pol.html
resource "kubernetes_config_map_v1" "network_policy_controller" {
  metadata {
    name      = "amazon-vpc-cni"
    namespace = "kube-system"
  }

  data = {
    "enable-network-policy-controller" = "true"
  }

  depends_on = [time_sleep.eks_access_propagation]
}

# NodeClass with Network Policy enabled for EKS Auto Mode
# This is required for NetworkPolicy resources to be enforced
# Using null_resource with kubectl to avoid kubernetes_manifest REST client issues during plan/destroy
resource "null_resource" "nodeclass_network_policy" {
  triggers = {
    cluster_name = module.eks.cluster_name
    region       = local.region
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${local.region}
      cat <<EOF | kubectl apply -f -
apiVersion: eks.amazonaws.com/v1
kind: NodeClass
metadata:
  name: default
spec:
  # DefaultAllow: Allow all traffic by default, NetworkPolicy/ClusterNetworkPolicy can deny specific traffic
  # This is required for EKS Auto Mode network policy enforcement
  networkPolicy: DefaultAllow
  networkPolicyEventLogs: Enabled
EOF
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} 2>/dev/null || true
      kubectl delete nodeclass default 2>/dev/null || true
    EOT
  }

  depends_on = [time_sleep.eks_access_propagation]
}
