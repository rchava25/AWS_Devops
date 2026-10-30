#!/usr/bin/env bash
# ==============================================================================
# deploy-jira-outbound.sh
# 
# Deployment script for the EventBridge → Lambda → Jira outbound integration.
# 
# What it does:
#   1. Validates prerequisites (AWS CLI, credentials, region)
#   2. Prompts for Jira credentials (or uses environment variables)
#   3. Deploys the CloudFormation stack
#   4. Updates the Lambda function code with the actual handler
#   5. Updates the Secrets Manager secret with real credentials
#   6. Runs a test invocation with a sample EventBridge event
#
# Usage:
#   chmod +x deploy-jira-outbound.sh
#   ./deploy-jira-outbound.sh
#
# Environment variables (optional, overrides prompts):
#   JIRA_EMAIL       - Jira account email
#   JIRA_API_TOKEN   - Jira API token
#   JIRA_BASE_URL    - Jira instance URL, e.g. https://your-site.atlassian.net
#   JIRA_PROJECT_KEY - Jira project key where issues are created, e.g. OPS
#   AGENT_SPACE_ID   - (optional) DevOps Agent Space ID for the investigation deep link
#   AWS_REGION       - AWS region (default: us-east-1)
#   STACK_NAME       - CloudFormation stack name (default: devops-agent-jira-outbound)
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWS_REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-devops-agent-jira-outbound}"
FUNCTION_NAME="devops-agent-jira-outbound"
SECRET_NAME="devops-agent/jira-credentials"
# Your Jira values — override via env or the prompts below. No defaults are
# assumed for the site/project/agent-space so the workshop never ships one
# author's account details.
JIRA_BASE_URL="${JIRA_BASE_URL:-}"
JIRA_PROJECT_KEY="${JIRA_PROJECT_KEY:-}"
AGENT_SPACE_ID="${AGENT_SPACE_ID:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ------------------------------------------------------------------------------
# Step 0: Validate Prerequisites
# ------------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  DevOps Agent → Jira Outbound Integration Deployer"
echo "============================================================"
echo ""

log_info "Validating prerequisites..."

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    log_error "AWS CLI is not installed. Install it: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
fi

# Check AWS credentials
if ! aws sts get-caller-identity --region "$AWS_REGION" &> /dev/null; then
    log_error "AWS credentials not configured or expired. Run 'aws configure' or refresh your session."
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text --region "$AWS_REGION")
log_success "AWS Account: $ACCOUNT_ID | Region: $AWS_REGION"

# Check zip utility
if ! command -v zip &> /dev/null; then
    log_error "'zip' command not found. Install it: brew install zip (macOS) or apt install zip (Linux)"
fi

# ------------------------------------------------------------------------------
# Step 1: Gather Jira Credentials
# ------------------------------------------------------------------------------
echo ""
log_info "Gathering Jira credentials..."

if [[ -z "$JIRA_BASE_URL" ]]; then
    read -rp "  Jira base URL (e.g. https://your-site.atlassian.net): " JIRA_BASE_URL
fi
# Normalize: strip any trailing slash
JIRA_BASE_URL="${JIRA_BASE_URL%/}"

if [[ -z "${JIRA_EMAIL:-}" ]]; then
    read -rp "  Jira email address: " JIRA_EMAIL
fi

if [[ -z "${JIRA_API_TOKEN:-}" ]]; then
    read -rsp "  Jira API token (hidden): " JIRA_API_TOKEN
    echo ""
fi

if [[ -z "$JIRA_PROJECT_KEY" ]]; then
    read -rp "  Jira project key (e.g. OPS): " JIRA_PROJECT_KEY
fi

if [[ -z "$JIRA_BASE_URL" || -z "$JIRA_EMAIL" || -z "$JIRA_API_TOKEN" || -z "$JIRA_PROJECT_KEY" ]]; then
    log_error "Jira base URL, email, API token, and project key are all required."
fi

log_success "Jira credentials collected (${JIRA_EMAIL})"
echo "  Base URL:    ${JIRA_BASE_URL}"
echo "  Project key: ${JIRA_PROJECT_KEY}"

# Validate Jira connectivity
log_info "Testing Jira API connectivity..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
    "${JIRA_BASE_URL}/rest/api/3/myself")

if [[ "$HTTP_CODE" == "200" ]]; then
    log_success "Jira API connection verified (HTTP $HTTP_CODE)"
else
    log_warn "Jira API returned HTTP $HTTP_CODE — credentials may be invalid"
    read -rp "  Continue anyway? (y/N): " CONTINUE
    [[ "$CONTINUE" != "y" && "$CONTINUE" != "Y" ]] && exit 1
fi

# ------------------------------------------------------------------------------
# Step 2: Deploy CloudFormation Stack
# ------------------------------------------------------------------------------
echo ""
log_info "Deploying CloudFormation stack: $STACK_NAME..."

aws cloudformation deploy \
    --template-file "${SCRIPT_DIR}/outbound-jira-stack.yml" \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
        JiraProjectKey="$JIRA_PROJECT_KEY" \
        JiraSecretName="$SECRET_NAME" \
        AgentSpaceId="${AGENT_SPACE_ID:-UNSET}" \
    --tags \
        Application=DevOpsAgent \
        Component=JiraOutbound \
    --no-fail-on-empty-changeset

log_success "CloudFormation stack deployed successfully"

# ------------------------------------------------------------------------------
# Step 3: Update Secrets Manager with Real Credentials
# ------------------------------------------------------------------------------
echo ""
log_info "Updating Secrets Manager secret with real credentials..."

SECRET_VALUE=$(cat <<EOF
{
    "email": "${JIRA_EMAIL}",
    "api_token": "${JIRA_API_TOKEN}",
    "base_url": "${JIRA_BASE_URL}"
}
EOF
)

aws secretsmanager put-secret-value \
    --secret-id "$SECRET_NAME" \
    --secret-string "$SECRET_VALUE" \
    --region "$AWS_REGION" \
    > /dev/null

log_success "Secret updated: $SECRET_NAME"

# ------------------------------------------------------------------------------
# Step 4: Package and Update Lambda Function Code
# ------------------------------------------------------------------------------
echo ""
log_info "Packaging Lambda function code..."

# Create a temporary directory for the deployment package
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Copy handler to temp directory (handler.py sits alongside this script)
cp "${SCRIPT_DIR}/handler.py" "$TEMP_DIR/"

# Create zip package
(cd "$TEMP_DIR" && zip -q handler.zip handler.py)

log_info "Uploading Lambda function code..."

aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file "fileb://${TEMP_DIR}/handler.zip" \
    --region "$AWS_REGION" \
    > /dev/null

# Wait for the function to be updated
aws lambda wait function-updated-v2 \
    --function-name "$FUNCTION_NAME" \
    --region "$AWS_REGION" \
    2>/dev/null || sleep 5

log_success "Lambda function code updated"

# ------------------------------------------------------------------------------
# Step 5: Test with Sample Event
# ------------------------------------------------------------------------------
echo ""
log_info "Testing Lambda function with sample EventBridge event..."

# Invoke the function with the test event
INVOKE_RESULT=$(aws lambda invoke \
    --function-name "$FUNCTION_NAME" \
    --payload "fileb://${SCRIPT_DIR}/test-event.json" \
    --region "$AWS_REGION" \
    --cli-binary-format raw-in-base64-out \
    "${TEMP_DIR}/response.json" \
    2>&1)

# Check for invocation errors
if echo "$INVOKE_RESULT" | grep -q '"FunctionError"'; then
    log_warn "Lambda invocation returned a function error"
    cat "${TEMP_DIR}/response.json" | python3 -m json.tool 2>/dev/null || cat "${TEMP_DIR}/response.json"
else
    RESPONSE=$(cat "${TEMP_DIR}/response.json")
    STATUS_CODE=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('statusCode','?'))" 2>/dev/null || echo "?")
    
    if [[ "$STATUS_CODE" == "201" ]]; then
        JIRA_KEY=$(echo "$RESPONSE" | python3 -c "import sys,json; body=json.loads(json.load(sys.stdin)['body']); print(body.get('jira_key',''))" 2>/dev/null || echo "")
        log_success "Test successful! Jira issue created: $JIRA_KEY"
        echo "  Response: $RESPONSE" | python3 -m json.tool 2>/dev/null || echo "  $RESPONSE"
    else
        log_warn "Lambda returned status $STATUS_CODE"
        echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
    fi
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "============================================================"
echo -e "  ${GREEN}Deployment Complete!${NC}"
echo "============================================================"
echo ""
echo "  Stack:     $STACK_NAME"
echo "  Function:  $FUNCTION_NAME"
echo "  Rule:      devops-agent-investigation-to-jira"
echo "  Secret:    $SECRET_NAME"
echo "  Region:    $AWS_REGION"
echo ""
echo "  The integration will now automatically create Jira issues"
echo "  in project ${JIRA_PROJECT_KEY} when DevOps Agent investigations complete"
echo "  or fail."
echo ""
echo "  To test manually:"
echo "    aws events put-events --entries file://${SCRIPT_DIR}/test-event.json --region $AWS_REGION"
echo ""
echo "  To view logs:"
echo "    aws logs tail /aws/lambda/$FUNCTION_NAME --follow --region $AWS_REGION"
echo ""
