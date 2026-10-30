# =============================================================================
# amg-keycloak-idp module — root file
# =============================================================================
# Creates AMP, AMG (with SAML), and the AMP scraper for an existing EKS cluster.
# Keycloak (Fargate + Aurora + ALB + API Gateway) lives in keycloak.tf.
# Configurator Lambda lives in configurator.tf.

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  family_for_engine = {
    "16.11" = "aurora-postgresql16"
    "17.7"  = "aurora-postgresql17"
  }
  family = local.family_for_engine[var.db_engine_version]
  region = data.aws_region.current.name
}

# =============================================================================
# AMAZON MANAGED PROMETHEUS (AMP)
# =============================================================================

resource "aws_prometheus_workspace" "this" {
  alias = "${var.name}-amp"
  tags  = var.tags
}

resource "aws_security_group" "amp_scraper" {
  name        = "${var.name}-amp-scraper"
  description = "AMP managed scraper egress"
  vpc_id      = var.vpc_id

  egress {
    description = "scraper to cluster targets"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-amp-scraper" })
}

resource "aws_security_group_rule" "amp_scraper_to_eks" {
  description              = "AMP scraper to EKS"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = var.eks_cluster_security_group_id
  source_security_group_id = aws_security_group.amp_scraper.id
}

# Open each node-attached security group to the scraper SG so pod-IP targets
# (kube-state-metrics, node-exporter, anything scraped via pod IP) are reachable.
# In EKS, pods typically land on the cluster-managed primary SG, which is
# distinct from the EKS module's additional cluster SG.
resource "aws_security_group_rule" "amp_scraper_to_node_sgs" {
  for_each                 = var.eks_node_security_group_ids
  description              = "AMP scraper to EKS node/pod SG (${each.key})"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = each.value
  source_security_group_id = aws_security_group.amp_scraper.id
}

# Gate for Kubernetes-provider resources in this module.
# var.cluster_ready is the eks module's cluster_ready token, only resolved after
# the cluster-admin access entry has propagated. Routing the K8s resources
# through this null_resource prevents the "cannot create clusterroles ...
# forbidden" race on freshly created clusters without forcing the rest of this
# module (Aurora, ALB, Fargate) to wait on EKS add-ons.
resource "null_resource" "cluster_ready_gate" {
  triggers = {
    cluster_ready = var.cluster_ready
  }
}

# Kubernetes RBAC required by the AMP managed scraper.
# AMP auto-registers its service-linked role with the cluster as group
# "aps-collector" when the scraper is created (no explicit access entry needed).
resource "kubernetes_cluster_role_v1" "aps_collector" {
  metadata {
    name = "aps-collector-role"
  }

  rule {
    api_groups = [""]
    resources  = ["nodes", "nodes/proxy", "nodes/metrics", "services", "endpoints", "pods"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["extensions", "networking.k8s.io"]
    resources  = ["ingresses"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    non_resource_urls = ["/metrics"]
    verbs             = ["get"]
  }

  depends_on = [null_resource.cluster_ready_gate]
}

resource "kubernetes_cluster_role_binding_v1" "aps_collector" {
  metadata {
    name = "aps-collector-user-role-binding"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.aps_collector.metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = "aps-collector"
  }
}

resource "aws_prometheus_scraper" "this" {
  alias = "${var.name}-eks-scraper"

  source {
    eks {
      cluster_arn        = "arn:${data.aws_partition.current.id}:eks:${local.region}:${data.aws_caller_identity.current.account_id}:cluster/${var.eks_cluster_name}"
      subnet_ids         = var.private_subnet_ids
      security_group_ids = [aws_security_group.amp_scraper.id]
    }
  }

  destination {
    amp {
      workspace_arn = aws_prometheus_workspace.this.arn
    }
  }

  scrape_configuration = templatefile("${path.module}/files/scrape_config.yaml", {
    cluster_name = var.eks_cluster_name
  })

  tags = var.tags

  # Scraper only requires:
  #   - Network reachability to pod IPs (SG rules)
  #   - RBAC for AMP's service-linked role to list endpoints (cluster role binding)
  # It does NOT require kube-state-metrics or node-exporter add-ons to be
  # installed — those are scrape *targets*. The scraper goes ACTIVE and writes
  # up=0 until targets exist, then auto-discovers them. Removing the add-on
  # depends_on lets the scraper start ~3-5 min earlier in parallel with add-ons.
  depends_on = [
    aws_security_group_rule.amp_scraper_to_eks,
    aws_security_group_rule.amp_scraper_to_node_sgs,
    kubernetes_cluster_role_binding_v1.aps_collector,
  ]
}

# =============================================================================
# Community add-ons (kube-state-metrics, node-exporter, metrics-server)
# =============================================================================

data "aws_eks_addon_version" "kube_state_metrics" {
  addon_name         = "kube-state-metrics"
  kubernetes_version = var.kubernetes_version
  most_recent        = true
}

resource "aws_eks_addon" "kube_state_metrics" {
  cluster_name                = var.eks_cluster_name
  addon_name                  = "kube-state-metrics"
  addon_version               = data.aws_eks_addon_version.kube_state_metrics.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags
}

data "aws_eks_addon_version" "node_exporter" {
  addon_name         = "prometheus-node-exporter"
  kubernetes_version = var.kubernetes_version
  most_recent        = true
}

resource "aws_eks_addon" "node_exporter" {
  cluster_name                = var.eks_cluster_name
  addon_name                  = "prometheus-node-exporter"
  addon_version               = data.aws_eks_addon_version.node_exporter.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags
}

data "aws_eks_addon_version" "metrics_server" {
  addon_name         = "metrics-server"
  kubernetes_version = var.kubernetes_version
  most_recent        = true
}

resource "aws_eks_addon" "metrics_server" {
  cluster_name                = var.eks_cluster_name
  addon_name                  = "metrics-server"
  addon_version               = data.aws_eks_addon_version.metrics_server.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags
}

# =============================================================================
# AMG (Amazon Managed Grafana)
# =============================================================================

resource "aws_iam_role" "grafana" {
  name = "${var.name}-grafana"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "grafana.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "grafana_amp" {
  name = "amp-query"
  role = aws_iam_role.grafana.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "aps:ListWorkspaces", "aps:DescribeWorkspace", "aps:QueryMetrics",
        "aps:GetLabels", "aps:GetSeries", "aps:GetMetricMetadata",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "grafana_cloudwatch" {
  name = "cloudwatch-read"
  role = aws_iam_role.grafana.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarmsForMetric", "cloudwatch:DescribeAlarmHistory",
          "cloudwatch:DescribeAlarms", "cloudwatch:ListMetrics",
          "cloudwatch:GetMetricData", "cloudwatch:GetInsightRuleReport",
          "logs:DescribeLogGroups", "logs:GetLogGroupFields", "logs:StartQuery",
          "logs:StopQuery", "logs:GetQueryResults", "logs:GetLogEvents",
          "logs:FilterLogEvents",
          "tag:GetResources", "ec2:DescribeTags", "ec2:DescribeInstances",
          "ec2:DescribeRegions",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_security_group" "grafana" {
  name        = "${var.name}-grafana"
  description = "AMG workspace SG"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-grafana" })
}

resource "aws_grafana_workspace" "this" {
  name                     = "${var.name}-grafana"
  description              = "${var.name} Managed Grafana workspace"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["SAML"]
  permission_type          = "SERVICE_MANAGED"
  role_arn                 = aws_iam_role.grafana.arn
  data_sources             = ["PROMETHEUS", "CLOUDWATCH"]

  vpc_configuration {
    security_group_ids = [aws_security_group.grafana.id]
    subnet_ids         = var.private_subnet_ids
  }

  tags = var.tags
}

resource "aws_ssm_parameter" "grafana_url" {
  name  = "/${var.name}/grafana-workspace-url"
  type  = "String"
  value = "https://${aws_grafana_workspace.this.endpoint}"
  tags  = var.tags
}
