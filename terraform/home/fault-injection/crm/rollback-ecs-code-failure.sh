#!/bin/bash
# Lab Fix: Rollback ECS Code Deploy Error
# Restores the working version of the Contact Sync Service on ECS Fargate

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/crm-common.sh"

# Initialize CRM lab environment
init_crm_lab

print_info "Rolling back ECS Code Deploy Error scenario..."

call_crm_admin "/api/admin/simulator/ec2-code-failure/stop"

echo ""
print_warning "The rollback deployment is now in progress via GitHub Actions."
print_warning "This takes 3–5 minutes to complete."

echo ""
print_success "ECS Code Deploy Error rolled back! Contact Sync Service restored to normal operation."
