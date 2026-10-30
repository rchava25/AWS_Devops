# EKS Module - Observability Configuration
# CloudWatch, ADOT, Grafana (optional)
# Optimized: Removed unused Prometheus, kube-state-metrics, prometheus-node-exporter,
# EFS CSI driver, Secrets Store CSI driver, and Network Flow Monitoring addons

# =============================================================================
# CLOUDWATCH OBSERVABILITY
# =============================================================================

resource "aws_iam_role" "cloudwatch_observability" {
  name = "${var.cluster_name}-cloudwatch-observability"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(module.eks.oidc_provider_arn, "/^(.*provider/)/", "")}:aud" = "sts.amazonaws.com"
            "${replace(module.eks.oidc_provider_arn, "/^(.*provider/)/", "")}:sub" = "system:serviceaccount:amazon-cloudwatch:cloudwatch-agent"
          }
        }
      }
    ]
  })

  tags = var.tags

  depends_on = [module.eks]
}

resource "aws_iam_role_policy_attachment" "cloudwatch_observability" {
  role       = aws_iam_role.cloudwatch_observability.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_observability_xray" {
  role       = aws_iam_role.cloudwatch_observability.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess"
}

# =============================================================================
# CLOUDWATCH OBSERVABILITY ADDON
# =============================================================================

resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "amazon-cloudwatch-observability"
  service_account_role_arn    = aws_iam_role.cloudwatch_observability.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    agent = {
      config = {
        logs = {
          metrics_collected = {
            application_signals = {}
            kubernetes = {
              enhanced_container_insights = true
            }
          }
        }
        traces = {
          traces_collected = {
            application_signals = {}
          }
        }
      }
    }
    containerLogs = {
      enabled = true
    }
  })

  tags = var.tags

  depends_on = [
    module.eks,
    aws_iam_role.cloudwatch_observability,
    aws_iam_role_policy_attachment.cloudwatch_observability,
    aws_iam_role_policy_attachment.cloudwatch_observability_xray
  ]
}

# =============================================================================
# ADOT (AWS Distro for OpenTelemetry) - Optional
# =============================================================================

resource "aws_iam_role" "adot" {
  count = var.opentelemetry_enabled ? 1 : 0

  name = "${var.cluster_name}-adot"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(module.eks.oidc_provider_arn, "/^(.*provider/)/", "")}:aud" = "sts.amazonaws.com"
            "${replace(module.eks.oidc_provider_arn, "/^(.*provider/)/", "")}:sub" = "system:serviceaccount:opentelemetry-operator-system:opentelemetry-operator"
          }
        }
      }
    ]
  })

  tags = var.tags

  depends_on = [module.eks]
}

resource "aws_iam_role_policy_attachment" "adot_cloudwatch" {
  count = var.opentelemetry_enabled ? 1 : 0

  role       = aws_iam_role.adot[0].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "adot_xray" {
  count = var.opentelemetry_enabled ? 1 : 0

  role       = aws_iam_role.adot[0].name
  policy_arn = "arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess"
}

resource "aws_eks_addon" "adot" {
  count = var.opentelemetry_enabled ? 1 : 0

  cluster_name                = module.eks.cluster_name
  addon_name                  = "adot"
  service_account_role_arn    = aws_iam_role.adot[0].arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags

  depends_on = [
    module.eks,
    aws_iam_role.adot,
    aws_iam_role_policy_attachment.adot_cloudwatch,
    aws_iam_role_policy_attachment.adot_xray
  ]
}

# =============================================================================
# AMAZON MANAGED GRAFANA (Optional)
# =============================================================================

resource "aws_grafana_workspace" "retail_store" {
  count = var.enable_grafana ? 1 : 0

  name                     = "${var.cluster_name}-grafana"
  description              = "Grafana workspace for ${var.cluster_name} EKS cluster monitoring"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "SERVICE_MANAGED"
  role_arn                 = aws_iam_role.grafana[0].arn
  grafana_version          = "10.4"

  data_sources = ["PROMETHEUS", "CLOUDWATCH", "XRAY"]

  tags = var.tags
}

resource "aws_iam_role" "grafana" {
  count = var.enable_grafana ? 1 : 0

  name = "${var.cluster_name}-grafana"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "grafana.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "grafana_amp" {
  count = var.enable_grafana ? 1 : 0

  name = "${var.cluster_name}-grafana-amp-policy"
  role = aws_iam_role.grafana[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "aps:ListWorkspaces",
          "aps:DescribeWorkspace",
          "aps:QueryMetrics",
          "aps:GetLabels",
          "aps:GetSeries",
          "aps:GetMetricMetadata"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "grafana_cloudwatch" {
  count = var.enable_grafana ? 1 : 0

  role       = aws_iam_role.grafana[0].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "grafana_xray" {
  count = var.enable_grafana ? 1 : 0

  role       = aws_iam_role.grafana[0].name
  policy_arn = "arn:aws:iam::aws:policy/AWSXrayReadOnlyAccess"
}
