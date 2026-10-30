#!/bin/bash
# =============================================================================
# Dynatrace Integration Lab — Prepare Environment
# =============================================================================
# One-time setup that:
#   1. Collects Dynatrace endpoint + API token
#   2. Stores the token in AWS Secrets Manager
#   3. Switches ALL ECS services to Dynatrace observability
#      (OTEL collector sidecar + optional OneAgent)
#   4. Waits for services to stabilize
#
# Run this ONCE before starting any Dynatrace lab scenario.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/dynatrace-common.sh"

init_ecs_lab

ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-${ECS_CLUSTER_NAME%-cluster}}"

print_info "=============================================="
print_info "Dynatrace Integration Lab — Environment Setup"
print_info "=============================================="
echo ""
print_info "This will switch all ECS services to send telemetry to Dynatrace"
print_info "via an OTEL collector sidecar container."
echo ""

# Step 1: Collect Dynatrace params (interactive, cached)
ensure_dynatrace_params

# Step 2: Switch each service to Dynatrace
SERVICES="ui catalog carts checkout orders"

echo ""
print_info "Switching services to Dynatrace observability..."
echo ""

for svc in $SERVICES; do
  # Check if service exists in the cluster
  SVC_EXISTS=$(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" \
    --services "$svc" --region "$AWS_REGION" \
    --query 'services[?status==`ACTIVE`].serviceName' --output text 2>/dev/null)

  if [[ -n "$SVC_EXISTS" && "$SVC_EXISTS" != "None" ]]; then
    switch_service_to_dynatrace "$svc"
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
print_success "Dynatrace environment ready!"
print_success "=============================================="
echo ""
echo "All services now send OTLP telemetry to: $DT_ENDPOINT"
echo "CloudWatch awslogs logging is preserved alongside Dynatrace."
echo ""
print_info "Available lab scenarios:"
echo "  1. inject-orders-db-broken.sh — Orders messaging broken (500 on order operations)"
echo ""
print_info "To verify: check-dynatrace-status.sh"
print_info "When done, run: cleanup-dynatrace.sh"
echo ""
