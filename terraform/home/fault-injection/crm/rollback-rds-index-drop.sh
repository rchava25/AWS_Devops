#!/bin/bash
# Lab Fix: Rollback RDS Index Drop
# Restores dropped database indexes

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/crm-common.sh"

# Initialize CRM lab environment
init_crm_lab

print_info "Rolling back RDS index drop scenario..."

call_crm_admin "/api/admin/simulator/rds-index-drop/stop"

echo ""
print_success "RDS indexes restored! CRM application restored to normal operation."
