#!/bin/bash
# =============================================================================
# New Relic Integration Lab — Prepare Environment
# =============================================================================
# One-time setup that:
#   1. Collects New Relic region, account ID, and ingest license key
#   2. Stores the license key in AWS Secrets Manager
#   3. Adds a New Relic OTel Collector sidecar container to ALL ECS services
#   4. Grants execution role permission to read the secret
#   5. Waits for services to stabilize
#
# Run this ONCE before starting any New Relic lab scenario.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/newrelic-common.sh"

init_ecs_lab

ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-${ECS_CLUSTER_NAME%-cluster}}"

print_info "=============================================="
print_info "New Relic Integration Lab — Environment Setup"
print_info "=============================================="
echo ""
print_info "This will add a New Relic OTel Collector sidecar to all ECS services."
print_info "The sidecar collects logs, metrics, and traces and sends them to your"
print_info "New Relic account via OTLP."
echo ""

# Step 1: Collect New Relic params (interactive, cached)
ensure_newrelic_params

# Step 2: Switch each service to include the New Relic OTel Collector sidecar
SERVICES="ui catalog carts checkout orders"

echo ""
print_info "Adding New Relic OTel Collector sidecar to services..."
echo ""

for svc in $SERVICES; do
  SVC_EXISTS=$(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" \
    --services "$svc" --region "$AWS_REGION" \
    --query 'services[?status==`ACTIVE`].serviceName' --output text 2>/dev/null)

  if [[ -n "$SVC_EXISTS" && "$SVC_EXISTS" != "None" ]]; then
    switch_service_to_newrelic "$svc"
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
print_success "New Relic environment ready!"
print_success "=============================================="
echo ""
echo "All services now run a New Relic OTel Collector sidecar sending telemetry to:"
echo "  ${NR_OTLP_ENDPOINT}  (region: ${NR_REGION})"
echo ""
echo "CloudWatch awslogs logging is preserved alongside New Relic telemetry."
echo ""
print_info "Available lab scenarios:"
echo "  newrelic-lab2-start  — Orders can't pull secrets"
echo ""
print_info "When done with all labs, run: newrelic-cleanup"
echo ""
