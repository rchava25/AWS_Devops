#!/bin/bash
# Lab: RDS Index Drop
# Drops database indexes causing severe query performance degradation
# Symptom: Slow API responses, database query timeouts, high RDS CPU

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/crm-common.sh"

# Initialize CRM lab environment
init_crm_lab

print_info "=============================================="
print_info "Lab: RDS Index Drop"
print_info "=============================================="
echo ""

# Trigger the RDS index drop scenario
print_info "Triggering RDS index drop..."
call_crm_admin "/api/admin/simulator/rds-index-drop/start"

echo ""
print_success "Issue injected successfully!"
echo ""
print_info "=============================================="
print_info "SCENARIO:"
print_info "=============================================="
echo "Critical database indexes have been dropped from the CRM application's RDS instance."
echo "Database queries are now performing full table scans."
echo "Users report extremely slow page loads and API timeouts."
echo ""
print_info "YOUR TASK:"
echo "1. Use AWS DevOps Agent to investigate the performance degradation"
echo "2. Check RDS Performance Insights for slow queries"
echo "3. Examine CloudWatch metrics for RDS CPU and latency"
echo "4. Identify missing indexes as the root cause"
echo ""
print_info "HINTS:"
echo "- Check RDS CPUUtilization and ReadLatency metrics"
echo "- Look at RDS Performance Insights for top SQL queries"
echo "- Examine Lambda function duration metrics for increased latency"
echo ""
print_warning "Run 'rollback-rds-index-drop.sh' to restore normal operation"
print_info "=============================================="
