#!/bin/bash
# Lab Fix: Rollback SQS Backlog Spike
# Reverts the SQS backlog spike scenario

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/crm-common.sh"

# Initialize CRM lab environment
init_crm_lab

print_info "Rolling back SQS backlog spike scenario..."

call_crm_admin "/api/admin/simulator/sqs-backlog-spike/stop"

echo ""
print_success "SQS backlog spike rolled back! CRM application restored to normal operation."
