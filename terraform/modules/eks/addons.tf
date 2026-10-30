# EKS Module - Kubernetes Addons
# Migrated from aws-devops-agent-workshop/assetsSrc/terraform/addons.tf

# =============================================================================
# ALB INGRESS CLASS
# =============================================================================

# ALB IngressClass for AWS Load Balancer Controller (EKS Auto Mode)
resource "kubernetes_ingress_class_v1" "alb" {
  metadata {
    name = "alb"
    labels = {
      "app.kubernetes.io/name" = "LoadBalancerController"
    }
  }

  spec {
    controller = "eks.amazonaws.com/alb"
  }

  depends_on = [time_sleep.eks_access_propagation]
}

# =============================================================================
# STORAGE CLASSES
# =============================================================================

# EBS StorageClass for persistent volumes
resource "kubernetes_storage_class_v1" "ebs" {
  metadata {
    name = "auto-ebs-sc"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner = "ebs.csi.eks.amazonaws.com"
  volume_binding_mode = "WaitForFirstConsumer"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [time_sleep.eks_access_propagation]
}
