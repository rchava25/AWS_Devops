# =============================================================================
# Unified DevOps Agent Workshop - Root Terraform Configuration
# =============================================================================
# This configuration creates SEPARATE ECS and EKS stacks that share only the VPC.
# Each platform has its own dependencies (RDS, DynamoDB, ElastiCache, MQ).
#
# Usage:
#   - Set enable_ecs = true to deploy ECS cluster with its own dependencies
#   - Set enable_eks = true to deploy EKS cluster with its own dependencies
#   - Both can be enabled simultaneously - they are completely independent
# =============================================================================

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# -----------------------------------------------------------------------------
# Local Values
# -----------------------------------------------------------------------------

locals {
  region         = data.aws_region.current.name
  aws_account_id = data.aws_caller_identity.current.account_id
  azs            = slice(data.aws_availability_zones.available.names, 0, 3)

  # Separate environment names for ECS and EKS resources
  ecs_environment_name = "${var.environment_name}-ecs"
  eks_environment_name = var.eks_cluster_name

  # Common tags applied to all resources
  common_tags = merge(var.tags, {
    environment-name = var.environment_name
    created-by       = "devops-agent-workshop"
    devopsagent      = "true"
    ManagedBy        = "terraform"
  })

  # Tags for EKS module - exclude 'created-by' to avoid conflict with EKS module's
  # internal aws_ec2_tag resource for cluster_primary_security_group
  eks_tags = merge(var.tags, {
    environment-name = var.environment_name
    devopsagent      = "true"
    ManagedBy        = "terraform"
  })

  # Alias for backward compatibility
  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Container Images Module
# -----------------------------------------------------------------------------
# Resolves container image URLs for the retail store application services.
# Used by both ECS and EKS modules.

module "container_images" {
  source = "./modules/container-images"

  container_image_overrides = var.container_image_overrides
}

# -----------------------------------------------------------------------------
# VPC Module (SHARED)
# -----------------------------------------------------------------------------
# Creates a shared VPC with public and private subnets across 3 AZs.
# This is the ONLY shared resource between ECS and EKS.

module "vpc" {
  source = "./modules/vpc"

  environment_name = var.environment_name
  vpc_cidr         = var.vpc_cidr
  azs              = local.azs

  # Enable EKS-specific subnet tags when EKS is enabled
  enable_eks       = var.enable_eks
  eks_cluster_name = var.eks_cluster_name

  # VPC Flow Logs for observability
  enable_flow_logs = var.enable_vpc_flow_logs

  tags = local.tags
}

# =============================================================================
# ECS STACK (Completely Independent)
# =============================================================================
# When enable_ecs = true, creates:
# - ECS-specific security groups
# - ECS-specific dependencies (RDS, DynamoDB, ElastiCache, MQ)
# - ECS cluster and services

# ECS Security Groups
module "ecs_security_groups" {
  source = "./modules/security-groups"
  count  = var.enable_ecs ? 1 : 0

  environment_name = local.ecs_environment_name
  vpc_id           = module.vpc.vpc_id
  vpc_cidr_block   = module.vpc.vpc_cidr_block
  enable_eks_rules = false

  tags = merge(local.tags, { stack = "ecs" })
}

# ECS Dependencies (RDS, DynamoDB, ElastiCache, MQ)
module "ecs_dependencies" {
  source = "./modules/dependencies"
  count  = var.enable_ecs ? 1 : 0

  environment_name = local.ecs_environment_name
  vpc_id           = module.vpc.vpc_id
  subnet_ids       = module.vpc.private_subnets

  catalog_security_group_id  = module.ecs_security_groups[0].catalog_id
  orders_security_group_id   = module.ecs_security_groups[0].orders_id
  checkout_security_group_id = module.ecs_security_groups[0].checkout_id
  carts_security_group_id    = module.ecs_security_groups[0].carts_id
  allowed_security_group_ids = []

  tags = merge(local.tags, { stack = "ecs" })
}

# ECS Cluster and Services
module "ecs" {
  source = "./modules/ecs"
  count  = var.enable_ecs ? 1 : 0

  environment_name  = local.ecs_environment_name
  vpc_id            = module.vpc.vpc_id
  subnet_ids        = module.vpc.private_subnets
  public_subnet_ids = module.vpc.public_subnets

  # Container images
  container_image_overrides = var.container_image_overrides

  # ECS-specific security groups
  catalog_security_group_id  = module.ecs_security_groups[0].catalog_id
  carts_security_group_id    = module.ecs_security_groups[0].carts_id
  checkout_security_group_id = module.ecs_security_groups[0].checkout_id
  orders_security_group_id   = module.ecs_security_groups[0].orders_id
  ui_security_group_id       = module.ecs_security_groups[0].ui_id

  # ECS-specific Catalog database
  catalog_db_endpoint = module.ecs_dependencies[0].catalog_db_endpoint
  catalog_db_port     = module.ecs_dependencies[0].catalog_db_port
  catalog_db_name     = module.ecs_dependencies[0].catalog_db_database_name
  catalog_db_username = module.ecs_dependencies[0].catalog_db_master_username
  catalog_db_password = module.ecs_dependencies[0].catalog_db_master_password

  # ECS-specific Carts DynamoDB
  carts_dynamodb_table_name = module.ecs_dependencies[0].carts_dynamodb_table_name
  carts_dynamodb_policy_arn = module.ecs_dependencies[0].carts_dynamodb_policy_arn

  # ECS-specific Checkout Redis
  checkout_redis_endpoint = module.ecs_dependencies[0].checkout_elasticache_primary_endpoint
  checkout_redis_port     = module.ecs_dependencies[0].checkout_elasticache_port

  # ECS-specific Orders database
  orders_db_endpoint = module.ecs_dependencies[0].orders_db_endpoint
  orders_db_port     = module.ecs_dependencies[0].orders_db_port
  orders_db_name     = module.ecs_dependencies[0].orders_db_database_name
  orders_db_username = module.ecs_dependencies[0].orders_db_master_username
  orders_db_password = module.ecs_dependencies[0].orders_db_master_password

  # ECS-specific Amazon SQS for orders messaging
  orders_sqs_queue_name = module.ecs_dependencies[0].orders_sqs_queue_name
  orders_sqs_queue_arn  = module.ecs_dependencies[0].orders_sqs_queue_arn

  # Observability settings
  opentelemetry_enabled      = var.ecs_opentelemetry_enabled
  container_insights_setting = var.ecs_container_insights_setting
  log_retention_days         = var.log_retention_days
  cloudwatch_alarms_enabled  = var.cloudwatch_alarms_enabled
  alarm_sns_topic_arn        = var.alarm_sns_topic_arn

  tags = merge(local.tags, { stack = "ecs" })
}

# =============================================================================
# EKS STACK (Completely Independent)
# =============================================================================
# When enable_eks = true, creates:
# - EKS cluster with Auto Mode
# - EKS-specific dependencies (RDS, DynamoDB, ElastiCache, MQ)
# - EKS addons and observability

# EKS Cluster
module "eks" {
  source = "./modules/eks"
  count  = var.enable_eks ? 1 : 0

  cluster_name       = var.eks_cluster_name
  environment_name   = local.eks_environment_name
  kubernetes_version = var.kubernetes_version

  vpc_id          = module.vpc.vpc_id
  private_subnets = module.vpc.private_subnets
  public_subnets  = module.vpc.public_subnets

  # EKS Auto Mode node pools
  node_pools = var.eks_node_pools

  # Feature flags
  istio_enabled               = var.eks_istio_enabled
  opentelemetry_enabled       = var.eks_opentelemetry_enabled
  application_signals_enabled = var.eks_application_signals_enabled
  enable_grafana              = var.eks_enable_grafana
  deploy_retail_app           = var.eks_deploy_retail_app

  # Container images
  container_image_overrides = var.container_image_overrides

  # Use eks_tags to avoid 'created-by' tag conflict with EKS module's
  # aws_ec2_tag resource for cluster_primary_security_group
  tags = merge(local.eks_tags, { stack = "eks" })
}

# EKS Dependencies (RDS, DynamoDB, ElastiCache, MQ) - Created AFTER EKS cluster
module "eks_dependencies" {
  source = "./modules/eks-dependencies"
  count  = var.enable_eks ? 1 : 0

  environment_name = local.eks_environment_name
  vpc_id           = module.vpc.vpc_id
  vpc_cidr         = var.vpc_cidr
  subnet_ids       = module.vpc.private_subnets

  # Pass EKS cluster security group for access rules
  eks_cluster_security_group_id = module.eks[0].cluster_security_group_id
  eks_oidc_provider             = module.eks[0].oidc_provider

  tags = merge(local.tags, { stack = "eks" })
}

# -----------------------------------------------------------------------------
# AMG + Keycloak SAML IdP + AMP scraper for EKS
# -----------------------------------------------------------------------------
# When enable_amg_keycloak_idp = true (and EKS is enabled), provisions:
#   - Amazon Managed Prometheus workspace
#   - AMP managed scraper that scrapes the EKS cluster created above
#   - Amazon Managed Grafana workspace (SAML auth, AMP + CloudWatch data sources)
#   - Keycloak on Fargate as the SAML IdP
#   - Aurora PostgreSQL backing Keycloak

module "amg_keycloak_idp" {
  source = "./modules/amg-keycloak-idp"
  count  = var.enable_eks && var.enable_amg_keycloak_idp ? 1 : 0

  name                          = var.amg_keycloak_idp_name
  realm_name                    = var.amg_keycloak_realm_name
  vpc_id                        = module.vpc.vpc_id
  vpc_cidr                      = var.vpc_cidr
  private_subnet_ids            = module.vpc.private_subnets
  eks_cluster_name              = module.eks[0].cluster_name
  eks_cluster_security_group_id = module.eks[0].cluster_security_group_id
  # Gates this module's Kubernetes resources on EKS access-entry propagation.
  cluster_ready = module.eks[0].cluster_ready
  # EKS-managed primary cluster SG is what nodes/pods use by default. Without
  # ingress from the scraper SG, kube-state-metrics and other pod-IP scrape
  # targets are unreachable. The node SG is also included for setups where
  # nodes are launched into an additional SG. Static map keys let Terraform
  # plan for_each before EKS creates the SGs.
  eks_node_security_group_ids = {
    primary = module.eks[0].cluster_primary_security_group_id
    node    = module.eks[0].node_security_group_id
  }
  kubernetes_version = var.kubernetes_version

  tags = merge(local.tags, { stack = "amg-keycloak-idp" })
}

# =============================================================================
# CRM STACK (Completely Independent - Serverless via CDK)
# =============================================================================
# When enable_crm = true, deploys the external CRM CDK app into the shared VPC.
# The CRM module orchestrates CDK deployment, creates a Cognito workshop user,
# and exposes outputs for helper scripts and CFN stack outputs.

module "crm" {
  source = "./modules/crm"
  count  = var.enable_crm ? 1 : 0

  environment_name         = var.environment_name
  vpc_id                   = module.vpc.vpc_id
  private_subnet_ids       = module.vpc.private_subnets
  region                   = local.region
  crm_app_path             = var.crm_app_path
  crm_app_s3_url           = var.crm_app_s3_url
  devops_agent_webhook_url = var.crm_devops_agent_webhook_url
  workshop_username        = var.crm_workshop_username

  tags = merge(local.tags, { stack = "crm" })
}

# =============================================================================
# SSM Parameters for CRM Lambda (ECS probe)
# =============================================================================
# These parameters allow the CRM proxy Lambda to discover the ECS cluster
# and service names at runtime for the ECS Code Deploy Error scenario probe.

resource "aws_ssm_parameter" "crm_ecs_cluster_name" {
  count = var.enable_ecs && var.enable_crm ? 1 : 0

  name  = "/workshop/crm/ecs-cluster-name"
  type  = "String"
  value = module.ecs[0].ecs_cluster_name

  tags = local.tags
}

resource "aws_ssm_parameter" "crm_ecs_service_name" {
  count = var.enable_ecs && var.enable_crm ? 1 : 0

  name  = "/workshop/crm/ecs-service-name"
  type  = "String"
  value = "${local.ecs_environment_name}-ui"

  tags = local.tags
}

# =============================================================================
# CRM EKS Notification Worker (Kubernetes Deployment)
# =============================================================================
# Deploys the CRM notification worker as a Kubernetes Deployment on the
# existing EKS cluster. The worker consumes SQS messages for CRM notifications.
# GitHub Actions deploys code changes by updating the container image.

# ECR repository for the CRM notification worker Docker image
# GitHub Actions builds and pushes the image here during EKS scenario deployments
resource "aws_ecr_repository" "crm_notification_worker" {
  count = var.enable_eks && var.enable_crm ? 1 : 0

  name                 = "crm-notification-worker"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  tags = merge(local.tags, { service = "crm-notification-worker" })
}

resource "null_resource" "crm_eks_notification_worker" {
  count = var.enable_eks && var.enable_crm ? 1 : 0

  depends_on = [module.eks, module.crm]

  triggers = {
    cluster_name = var.eks_cluster_name
    region       = local.region
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig --name ${var.eks_cluster_name} --region ${local.region}

      # Create the notification worker deployment
      cat <<'K8S' | kubectl apply -f -
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: crm-notification-worker
        namespace: default
        labels:
          app: crm-notification-worker
          service: crm
      spec:
        replicas: 1
        selector:
          matchLabels:
            app: crm-notification-worker
        template:
          metadata:
            labels:
              app: crm-notification-worker
              service: crm
          spec:
            containers:
            - name: crm-notification-worker
              image: public.ecr.aws/docker/library/node:18-alpine
              command: ["node", "-e", "console.log(JSON.stringify({level:'info',message:'Notification worker placeholder — awaiting GitHub Actions deployment',service:'crm-notification-worker'})); setInterval(() => {}, 86400000)"]
              resources:
                requests:
                  cpu: 64m
                  memory: 128Mi
                limits:
                  cpu: 256m
                  memory: 256Mi
      K8S

      echo "CRM notification worker deployment created on EKS"
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} 2>/dev/null || true
      kubectl delete deployment crm-notification-worker --namespace default 2>/dev/null || true
    EOT
  }
}

# =============================================================================
# CRM EC2 Report Generator
# =============================================================================
# Deploys a small EC2 instance running the CRM report generator service.
# The service generates pipeline reports by querying RDS.
# GitHub Actions deploys code changes via SSM Run Command.
#
# IMPORTANT: The instance uses the standard AL2023 AMI from SSM Parameter Store
# (includes SSM Agent pre-installed), a dedicated security group with HTTPS
# egress, and installs Node.js from AL2023 repos (no internet dependency on
# external package repos like nodesource.com).

# Use the standard AL2023 AMI from SSM Parameter Store — this AMI includes
# SSM Agent pre-installed, unlike the minimal AMI from aws_ami data source.
data "aws_ssm_parameter" "al2023_ami" {
  count = var.enable_crm ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# Dedicated security group for the EC2 report generator.
# The VPC default security group has no egress rules, which prevents SSM Agent
# from connecting to AWS endpoints. This SG allows HTTPS outbound.
resource "aws_security_group" "crm_report_generator" {
  count       = var.enable_crm ? 1 : 0
  name        = "${var.environment_name}-crm-report-generator"
  description = "Security group for CRM report generator EC2 instance"
  vpc_id      = module.vpc.vpc_id

  # HTTPS outbound — required for SSM Agent, CloudWatch Agent, and package installs
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS outbound for SSM, CloudWatch, and package repos"
  }

  # HTTP outbound — required for AL2023 dnf package repos (some use HTTP)
  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP outbound for package repos"
  }

  tags = merge(local.tags, {
    Name    = "${var.environment_name}-crm-report-generator"
    service = "crm-report-generator"
  })
}

resource "aws_iam_role" "crm_report_generator" {
  count = var.enable_crm ? 1 : 0
  name  = "${var.environment_name}-crm-report-generator"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = merge(local.tags, { service = "crm-report-generator" })
}

resource "aws_iam_role_policy_attachment" "crm_report_generator_ssm" {
  count      = var.enable_crm ? 1 : 0
  role       = aws_iam_role.crm_report_generator[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "crm_report_generator_cw" {
  count      = var.enable_crm ? 1 : 0
  role       = aws_iam_role.crm_report_generator[0].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "crm_report_generator" {
  count = var.enable_crm ? 1 : 0
  name  = "${var.environment_name}-crm-report-generator"
  role  = aws_iam_role.crm_report_generator[0].name
}

resource "aws_instance" "crm_report_generator" {
  count = var.enable_crm ? 1 : 0

  ami                    = data.aws_ssm_parameter.al2023_ami[0].value
  instance_type          = "t3.micro"
  subnet_id              = module.vpc.private_subnets[0]
  vpc_security_group_ids = [aws_security_group.crm_report_generator[0].id]
  iam_instance_profile   = aws_iam_instance_profile.crm_report_generator[0].name

  # Require IMDSv2 (CKV_AWS_79). Nothing on this instance calls IMDS directly;
  # the SSM agent and CloudWatch agent are IMDSv2-aware.
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  user_data = <<-USERDATA
#!/bin/bash
# NOTE: Do NOT use set -e — we want the script to continue even if some steps fail.
# The instance is in a private subnet; package installs go through NAT Gateway.

# Ensure SSM Agent is running (pre-installed on standard AL2023 AMI)
systemctl enable amazon-ssm-agent 2>/dev/null || true
systemctl start amazon-ssm-agent 2>/dev/null || true

# Install Node.js and CloudWatch Agent from AL2023 repos
dnf install -y nodejs amazon-cloudwatch-agent 2>&1 || true

# Create app directory
mkdir -p /opt/crm-report-generator
cd /opt/crm-report-generator

# Create a placeholder report generator service
cat > reportGenerator.js << 'JSEOF'
const http = require('http');
const server = http.createServer((req, res) => {
  const log = (level, msg) => console.log(JSON.stringify({timestamp: new Date().toISOString(), level, message: msg, service: 'crm-report-generator'}));
  if (req.url === '/health') {
    res.writeHead(200, {'Content-Type': 'application/json'});
    res.end(JSON.stringify({status: 'healthy', service: 'crm-report-generator'}));
  } else if (req.url === '/generate') {
    log('info', 'Report generation requested — waiting for GitHub Actions deployment');
    res.writeHead(200, {'Content-Type': 'application/json'});
    res.end(JSON.stringify({status: 'placeholder', message: 'Awaiting code deployment via GitHub Actions'}));
  } else {
    res.writeHead(404);
    res.end('Not found');
  }
});
server.listen(3001, () => console.log(JSON.stringify({level:'info',message:'Report generator started on port 3001',service:'crm-report-generator'})));
JSEOF

# Create systemd service — output to log file for CloudWatch Agent to collect
cat > /etc/systemd/system/crm-report-generator.service << 'SVCEOF'
[Unit]
Description=CRM Report Generator
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/crm-report-generator
ExecStart=/usr/bin/node reportGenerator.js
Restart=always
RestartSec=5
StandardOutput=append:/var/log/crm-report-generator.log
StandardError=append:/var/log/crm-report-generator.log

[Install]
WantedBy=multi-user.target
SVCEOF

# Configure CloudWatch Agent to stream application log file
mkdir -p /opt/aws/amazon-cloudwatch-agent/etc
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWEOF'
{"logs":{"logs_collected":{"files":{"collect_list":[{"file_path":"/var/log/crm-report-generator.log","log_group_name":"/ec2/crm-report-generator","log_stream_name":"{instance_id}","retention_in_days":14}]}}}}
CWEOF

# Start services
systemctl daemon-reload
systemctl enable crm-report-generator
systemctl start crm-report-generator
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json 2>&1 || true
  USERDATA

  tags = merge(local.tags, {
    Name    = "${var.environment_name}-crm-report-generator"
    service = "crm-report-generator"
  })
}

# SSM parameter for the EC2 instance ID (used by GitHub Actions for SSM Run Command)
resource "aws_ssm_parameter" "crm_report_generator_instance_id" {
  count = var.enable_crm ? 1 : 0

  name  = "/workshop/crm/report-generator-instance-id"
  type  = "String"
  value = aws_instance.crm_report_generator[0].id

  tags = local.tags
}

# =============================================================================
# EKS Access Entries for DevOps Agent
# =============================================================================
# Automatically grants the DevOps Agent IAM role access to the EKS cluster.
# The DevOps Agent role follows the naming pattern "DevOpsAgentRole-AgentSpace*".
# This runs after the EKS cluster is ready and discovers the role dynamically.
#
# Also grants access to any existing GitHub Actions role so that the EKS
# notification worker scenario works immediately after deployment.

resource "null_resource" "eks_devops_agent_access" {
  count = var.enable_eks ? 1 : 0

  depends_on = [module.eks]

  triggers = {
    cluster_name = var.eks_cluster_name
    region       = local.region
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      CLUSTER="${var.eks_cluster_name}"
      REGION="${local.region}"

      echo "=== Configuring EKS access entries for $CLUSTER ==="

      # --- DevOps Agent Role ---
      AGENT_ROLE=$(aws iam list-roles \
        --query "Roles[?starts_with(RoleName, 'DevOpsAgentRole-AgentSpace')].Arn" \
        --output text 2>/dev/null || true)

      if [ -n "$AGENT_ROLE" ] && [ "$AGENT_ROLE" != "None" ]; then
        echo "Found DevOps Agent role: $AGENT_ROLE"

        # Create access entry (ignore if already exists)
        aws eks create-access-entry \
          --cluster-name "$CLUSTER" \
          --principal-arn "$AGENT_ROLE" \
          --type STANDARD \
          --region "$REGION" 2>/dev/null || echo "  Access entry may already exist (OK)"

        # Associate cluster admin policy
        aws eks associate-access-policy \
          --cluster-name "$CLUSTER" \
          --principal-arn "$AGENT_ROLE" \
          --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
          --access-scope type=cluster \
          --region "$REGION" 2>/dev/null || echo "  Policy may already be associated (OK)"

        echo "  DevOps Agent EKS access configured"
      else
        echo "  DevOps Agent role not found yet (will be created when AgentSpace is set up)"
        echo "  Users can run the manual command from the workshop instructions"
      fi

      # --- GitHub Actions Role (if already exists from a previous setup) ---
      GH_ROLE=$(aws iam list-roles \
        --query "Roles[?starts_with(RoleName, 'github-actions-')].Arn" \
        --output text 2>/dev/null | head -1 || true)

      if [ -n "$GH_ROLE" ] && [ "$GH_ROLE" != "None" ]; then
        echo "Found GitHub Actions role: $GH_ROLE"

        aws eks create-access-entry \
          --cluster-name "$CLUSTER" \
          --principal-arn "$GH_ROLE" \
          --type STANDARD \
          --region "$REGION" 2>/dev/null || echo "  Access entry may already exist (OK)"

        aws eks associate-access-policy \
          --cluster-name "$CLUSTER" \
          --principal-arn "$GH_ROLE" \
          --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
          --access-scope type=cluster \
          --region "$REGION" 2>/dev/null || echo "  Policy may already be associated (OK)"

        echo "  GitHub Actions EKS access configured"
      else
        echo "  No GitHub Actions role found yet (will be created during GitHub setup in CRM UI)"
        echo "  The CRM Lambda automatically creates the EKS access entry when the role is created"
      fi

      echo "=== EKS access entry configuration complete ==="
    EOT
  }
}

# =============================================================================
# EKS Retail Store Application Deployment
# =============================================================================
# Deploys the retail store application (catalog, carts, checkout, orders, ui)
# onto the EKS cluster as part of `terraform apply`.
#
# WHY THIS RUNS IN TERRAFORM (and not the IDE bootstrap):
# The app used to be deployed by bootstrap.sh on the code-server IDE instance,
# which depends on the IDE's AWS CLI working at exactly that moment. When that
# CLI shipped a corrupted build ("Bus error (core dumped)"), the deploy failed,
# the failure was swallowed, CloudFormation went green, and the EKS labs were
# silently broken. Running the deploy here moves it into the CodeBuild apply
# environment (reliable, controlled CLI) and makes a failed deploy fail the
# apply -- so a broken account is flagged at provision time, not discovered by
# a participant. This mirrors the existing null_resource + local-exec pattern
# already used in this file (nodeclass_network_policy, crm_eks_notification_worker,
# eks_devops_agent_access). The CodeBuild apply role has cluster-admin via the
# EKS module's enable_cluster_creator_admin_permissions = true.
#
# Backend values are passed as ENV VARS (not `terraform output`): calling
# terraform from inside `terraform apply` would recurse into locked state.

resource "null_resource" "eks_retail_app" {
  count = var.enable_eks && var.eks_deploy_retail_app ? 1 : 0

  # Re-run when the cluster or any backend endpoint changes. A previous apply
  # that failed the readiness gate leaves this resource tainted, so the next
  # apply re-runs it automatically (the deploy itself is idempotent:
  # `helm upgrade --install`).
  triggers = {
    cluster_name       = var.eks_cluster_name
    region             = local.region
    catalog_db         = module.eks_dependencies[0].catalog_db_endpoint
    orders_db          = module.eks_dependencies[0].orders_db_endpoint
    dynamodb_table     = module.eks_dependencies[0].carts_dynamodb_table_name
    elasticache        = module.eks_dependencies[0].checkout_elasticache_endpoint
    orders_sqs         = module.eks_dependencies[0].orders_sqs_queue_name
    carts_iam_role     = module.eks_dependencies[0].carts_iam_role_arn
    orders_iam_role    = module.eks_dependencies[0].orders_iam_role_arn
    deploy_script_hash = filemd5("${path.module}/home/scripts/deploy-eks-app.sh")
  }

  # Ensure the cluster, its access-entry propagation, and all backend services
  # exist before we deploy the workloads that consume them.
  depends_on = [
    module.eks,
    module.eks_dependencies,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    # Invoke via `bash <script>` (not `./script`) so it does not depend on the
    # file's execute bit. The scripts are also committed executable (100755),
    # but bash-invocation is robust even if zip/unzip drops the mode in transit.
    command = "bash \"${path.module}/home/scripts/deploy-eks-app.sh\""

    environment = {
      CLUSTER_NAME = var.eks_cluster_name
      AWS_REGION   = local.region

      # Pin chart/image the same way the script defaults them; explicit here so
      # the deployed versions are visible and change-tracked in the plan.
      CHART_VERSION = "0.8.5"
      IMAGE_TAG     = "1.3.0"

      # Backend values injected directly (script prefers these over any
      # `terraform output` fallback, avoiding nested-state recursion).
      CATALOG_DB_ENDPOINT  = module.eks_dependencies[0].catalog_db_endpoint
      CATALOG_DB_PASSWORD  = module.eks_dependencies[0].catalog_db_master_password
      ORDERS_DB_ENDPOINT   = module.eks_dependencies[0].orders_db_endpoint
      ORDERS_DB_PASSWORD   = module.eks_dependencies[0].orders_db_master_password
      DYNAMODB_TABLE       = module.eks_dependencies[0].carts_dynamodb_table_name
      ELASTICACHE_ENDPOINT = module.eks_dependencies[0].checkout_elasticache_endpoint
      ORDERS_SQS_QUEUE     = module.eks_dependencies[0].orders_sqs_queue_name
      CARTS_IAM_ROLE       = module.eks_dependencies[0].carts_iam_role_arn
      ORDERS_IAM_ROLE      = module.eks_dependencies[0].orders_iam_role_arn

      # Fail the apply if the app does not become healthy (no more silent green).
      FAIL_ON_UNHEALTHY = "true"
    }
  }
}
