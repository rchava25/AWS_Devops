#!/bin/bash
# =============================================================================
# Setup AWS DevOps Agent Space for Unified Workshop
# =============================================================================
# This script creates the DevOps Agent IAM roles and Agent Space.
# It supports both ECS and EKS platforms.
#
# Environment variables expected:
# - ACCOUNTID or AWS_ACCOUNT_ID: AWS Account ID
# - ECS_CLUSTER_NAME: ECS cluster name (optional)
# - EKS_CLUSTER_NAME: EKS cluster name (optional)
# =============================================================================

set -e

echo "=== SETUP AWS DEVOPS AGENT ==="
SECTION_START=$(date +%s)

# Get account info
export ACCOUNTID=${ACCOUNTID:-$(aws sts get-caller-identity --query Account --output text)}
export DEVOPS_AGENT_REGION="us-east-1"
export DEVOPS_AGENT_ENDPOINT="https://api.prod.cp.aidevops.us-east-1.api.aws"

echo "Account ID: $ACCOUNTID"
echo "DevOps Agent Region: $DEVOPS_AGENT_REGION"
echo "ECS Cluster: ${ECS_CLUSTER_NAME:-not set}"
echo "EKS Cluster: ${EKS_CLUSTER_NAME:-not set}"

# Download and patch AWS CLI for DevOps Agent
echo "Downloading DevOps Agent service model..."
curl -Lqs -o /tmp/devopsagent.json https://d1co8nkiwcta1g.cloudfront.net/devopsagent.json
aws configure add-model --service-model "file:///tmp/devopsagent.json" --service-name devopsagent

# =============================================================================
# CREATE IAM ROLES FOR DEVOPS AGENT
# =============================================================================
echo "Creating DevOps Agent IAM roles..."

# 1. Create AgentSpace Role Trust Policy
cat > /tmp/devops-agentspace-trust-policy.json << TRUSTEOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "aidevops.amazonaws.com"},
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": {"aws:SourceAccount": "${ACCOUNTID}"},
      "ArnLike": {"aws:SourceArn": "arn:aws:aidevops:us-east-1:${ACCOUNTID}:agentspace/*"}
    }
  }]
}
TRUSTEOF

aws iam create-role \
  --role-name DevOpsAgentRole-AgentSpace \
  --assume-role-policy-document file:///tmp/devops-agentspace-trust-policy.json \
  --region $DEVOPS_AGENT_REGION 2>/dev/null || echo "AgentSpace role may already exist, continuing..."

aws iam attach-role-policy \
  --role-name DevOpsAgentRole-AgentSpace \
  --policy-arn arn:aws:iam::aws:policy/AIOpsAssistantPolicy 2>/dev/null || true

# Create inline policy for AgentSpace (supports both ECS and EKS)
cat > /tmp/devops-agentspace-inline-policy.json << INLINEEOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAwsSupportActions",
      "Effect": "Allow",
      "Action": ["support:CreateCase", "support:DescribeCases"],
      "Resource": ["*"]
    },
    {
      "Sid": "AllowExpandedAIOpsAssistantPolicy",
      "Effect": "Allow",
      "Action": [
        "aidevops:GetKnowledgeItem",
        "aidevops:ListKnowledgeItems",
        "eks:AccessKubernetesApi",
        "synthetics:GetCanaryRuns",
        "route53:GetHealthCheckStatus",
        "resource-explorer-2:Search"
      ],
      "Resource": ["*"]
    },
    {
      "Sid": "DataPipelineInvestigationPermissions",
      "Effect": "Allow",
      "Action": [
        "airflow:ListEnvironments",
        "airflow:GetEnvironment",
        "airflow:CreateWebLoginToken",
        "glue:GetJob",
        "glue:GetJobRun",
        "glue:GetJobRuns",
        "glue:ListJobs",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
        "logs:GetLogEvents",
        "logs:FilterLogEvents",
        "s3:ListBucket",
        "s3:GetObject",
        "s3:ListAllMyBuckets",
        "lambda:ListFunctions",
        "lambda:GetFunction",
        "lambda:GetFunctionConfiguration",
        "cloudformation:DescribeStacks",
        "cloudformation:ListStacks",
        "cloudformation:DescribeStackResources"
      ],
      "Resource": ["*"]
    }
  ]
}
INLINEEOF

aws iam put-role-policy \
  --role-name DevOpsAgentRole-AgentSpace \
  --policy-name AllowExpandedAIOpsAssistantPolicy \
  --policy-document file:///tmp/devops-agentspace-inline-policy.json 2>/dev/null || true

# 2. Create Operator App Role Trust Policy
cat > /tmp/devops-operator-trust-policy.json << OPTTRUSTEOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "aidevops.amazonaws.com"},
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": {"aws:SourceAccount": "${ACCOUNTID}"},
      "ArnLike": {"aws:SourceArn": "arn:aws:aidevops:us-east-1:${ACCOUNTID}:agentspace/*"}
    }
  }]
}
OPTTRUSTEOF

aws iam create-role \
  --role-name DevOpsAgentRole-WebappAdmin \
  --assume-role-policy-document file:///tmp/devops-operator-trust-policy.json \
  --region $DEVOPS_AGENT_REGION 2>/dev/null || echo "WebappAdmin role may already exist, continuing..."

# Create operator inline policy
cat > /tmp/devops-operator-inline-policy.json << OPTINLINEEOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowBasicOperatorActions",
      "Effect": "Allow",
      "Action": [
        "aidevops:GetAgentSpace",
        "aidevops:GetAssociation",
        "aidevops:ListAssociations",
        "aidevops:CreateBacklogTask",
        "aidevops:GetBacklogTask",
        "aidevops:UpdateBacklogTask",
        "aidevops:ListBacklogTasks",
        "aidevops:ListChildExecutions",
        "aidevops:ListJournalRecords",
        "aidevops:DiscoverTopology",
        "aidevops:InvokeAgent",
        "aidevops:ListGoals",
        "aidevops:ListRecommendations",
        "aidevops:ListExecutions",
        "aidevops:GetRecommendation",
        "aidevops:UpdateRecommendation",
        "aidevops:CreateKnowledgeItem",
        "aidevops:ListKnowledgeItems",
        "aidevops:GetKnowledgeItem",
        "aidevops:UpdateKnowledgeItem",
        "aidevops:ListPendingMessages",
        "aidevops:InitiateChatForCase",
        "aidevops:EndChatForCase",
        "aidevops:DescribeSupportLevel",
        "aidevops:SendChatMessage"
      ],
      "Resource": "arn:aws:aidevops:us-east-1:${ACCOUNTID}:agentspace/*"
    },
    {
      "Sid": "AllowSupportOperatorActions",
      "Effect": "Allow",
      "Action": [
        "support:DescribeCases",
        "support:InitiateChatForCase",
        "support:DescribeSupportLevel"
      ],
      "Resource": "*"
    }
  ]
}
OPTINLINEEOF

aws iam put-role-policy \
  --role-name DevOpsAgentRole-WebappAdmin \
  --policy-name AIDevOpsBasicOperatorActionsPolicy \
  --policy-document file:///tmp/devops-operator-inline-policy.json 2>/dev/null || true

# Wait for IAM propagation
echo "Waiting for IAM role propagation..."
sleep 15

# =============================================================================
# CREATE AGENT SPACE
# =============================================================================
echo "Creating DevOps Agent Space..."

# Determine agent space name based on available platforms
AGENT_SPACE_NAME="DevOps-Workshop-AgentSpace"
AGENT_SPACE_DESC="AgentSpace for DevOps Agent Workshop"

AGENT_SPACE_RESPONSE=$(aws devopsagent create-agent-space \
  --name "$AGENT_SPACE_NAME" \
  --description "$AGENT_SPACE_DESC" \
  --endpoint-url "$DEVOPS_AGENT_ENDPOINT" \
  --region $DEVOPS_AGENT_REGION 2>&1) || true

AGENT_SPACE_ID=$(echo "$AGENT_SPACE_RESPONSE" | jq -r '.agentSpaceId // empty')

# If creation failed, try to get existing agent space
if [ -z "$AGENT_SPACE_ID" ]; then
  echo "Checking for existing agent space..."
  AGENT_SPACE_ID=$(aws devopsagent list-agent-spaces \
    --endpoint-url "$DEVOPS_AGENT_ENDPOINT" \
    --region $DEVOPS_AGENT_REGION \
    --query "agentSpaces[?name=='$AGENT_SPACE_NAME'].agentSpaceId" \
    --output text 2>/dev/null || echo "")
fi

if [ -n "$AGENT_SPACE_ID" ]; then
  echo "Agent Space ID: $AGENT_SPACE_ID"

  # =============================================================================
  # ASSOCIATE AWS ACCOUNT
  # =============================================================================
  echo "Associating AWS Account with Agent Space..."
  aws devopsagent associate-service \
    --agent-space-id "$AGENT_SPACE_ID" \
    --service-id aws \
    --configuration "{
      \"aws\": {
        \"assumableRoleArn\": \"arn:aws:iam::${ACCOUNTID}:role/DevOpsAgentRole-AgentSpace\",
        \"accountId\": \"${ACCOUNTID}\",
        \"accountType\": \"monitor\",
        \"resources\": []
      }
    }" \
    --endpoint-url "$DEVOPS_AGENT_ENDPOINT" \
    --region $DEVOPS_AGENT_REGION 2>/dev/null || echo "AWS association may already exist, continuing..."

  # =============================================================================
  # ENABLE OPERATOR APP
  # =============================================================================
  echo "Enabling Operator App..."
  aws devopsagent enable-operator-app \
    --agent-space-id "$AGENT_SPACE_ID" \
    --auth-flow iam \
    --operator-app-role-arn "arn:aws:iam::${ACCOUNTID}:role/DevOpsAgentRole-WebappAdmin" \
    --endpoint-url "$DEVOPS_AGENT_ENDPOINT" \
    --region $DEVOPS_AGENT_REGION 2>/dev/null || echo "Operator App may already be enabled, continuing..."

  # =============================================================================
  # SAVE TO ENVIRONMENT
  # =============================================================================
  mkdir -p ~/.bashrc.d
  echo "export AGENT_SPACE_ID=$AGENT_SPACE_ID" >> ~/.bashrc.d/env.bash
  echo "export DEVOPS_AGENT_ENDPOINT=$DEVOPS_AGENT_ENDPOINT" >> ~/.bashrc.d/env.bash

  SECTION_END=$(date +%s)
  SECTION_DURATION=$((SECTION_END - SECTION_START))

  echo ""
  echo "========================================="
  echo "DEVOPS AGENT SETUP COMPLETE"
  echo "========================================="
  echo "Setup time: ${SECTION_DURATION}s"
  echo ""
  echo "Agent Space ID: $AGENT_SPACE_ID"
  echo "Operator App URL: https://us-east-1.console.aws.amazon.com/aidevops/home?region=us-east-1#/agentspaces/${AGENT_SPACE_ID}"
  echo "========================================="
else
  echo "WARNING: Failed to create or find Agent Space. DevOps Agent setup incomplete."
  exit 1
fi
