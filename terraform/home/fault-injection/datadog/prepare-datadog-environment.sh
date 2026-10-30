#!/bin/bash
# =============================================================================
# Datadog Integration Lab — Prepare Environment
# =============================================================================
# One-time setup that:
#   1. Collects Datadog site + API key
#   2. Stores the API key in AWS Secrets Manager
#   3. Adds Datadog Agent sidecar container to ALL ECS services
#   4. Grants execution role permission to read the secret
#   5. Waits for services to stabilize
#
# Run this ONCE before starting any Datadog lab scenario.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/datadog-common.sh"

init_ecs_lab

ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-${ECS_CLUSTER_NAME%-cluster}}"

print_info "=============================================="
print_info "Datadog Integration Lab — Environment Setup"
print_info "=============================================="
echo ""
print_info "This will add a Datadog Agent sidecar to all ECS services."
print_info "The sidecar collects logs, metrics, and APM traces and sends"
print_info "them to your Datadog account."
echo ""

# Step 1: Collect Datadog params (interactive, cached)
ensure_datadog_params

# Step 2: Switch each service to include Datadog Agent sidecar
SERVICES="ui catalog carts checkout orders"

echo ""
print_info "Adding Datadog Agent sidecar to services..."
echo ""

for svc in $SERVICES; do
  SVC_EXISTS=$(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" \
    --services "$svc" --region "$AWS_REGION" \
    --query 'services[?status==`ACTIVE`].serviceName' --output text 2>/dev/null)

  if [[ -n "$SVC_EXISTS" && "$SVC_EXISTS" != "None" ]]; then
    switch_service_to_datadog "$svc"
  else
    print_warning "  Service $svc not found in cluster, skipping."
  fi
done

# Step 3: Wait for all services to stabilize
echo ""
print_info "Waiting for services to stabilize (this may take 2-3 minutes)..."
for svc in $SERVICES; do
  SVC_EXISTS=$(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" \
    --services "$svc" --region "$AWS_REGION" \
    --query 'services[?status==`ACTIVE`].serviceName' --output text 2>/dev/null)
  if [[ -n "$SVC_EXISTS" && "$SVC_EXISTS" != "None" ]]; then
    aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" \
      --services "$svc" --region "$AWS_REGION" 2>/dev/null || true
  fi
done

echo ""
print_success "=============================================="
print_success "Datadog environment ready!"
print_success "=============================================="
echo ""
echo "All services now run a Datadog Agent sidecar sending telemetry to:"
echo "  https://${DD_SITE}"
echo ""
echo "CloudWatch awslogs logging is preserved alongside Datadog log collection."
echo ""
print_info "Available lab scenarios:"
echo "  datadog-lab2-start  — Orders can't pull secrets"
echo ""
print_info "When done with all labs, run: datadog-cleanup"
echo ""
