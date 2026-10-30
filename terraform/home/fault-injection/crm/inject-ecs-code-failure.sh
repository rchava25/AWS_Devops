#!/bin/bash
# Lab: ECS Code Deploy Error
# Deploys buggy code to the CRM Contact Sync Service on ECS Fargate
# Symptom: 5xx errors on database write operations, unhandled exceptions in application logs

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/crm-common.sh"

# Initialize CRM lab environment
init_crm_lab

print_info "=============================================="
print_info "Lab: ECS Code Deploy Error"
print_info "=============================================="
echo ""

# Trigger the ECS code deploy failure scenario
print_info "Triggering ECS Code Deploy Error..."
call_crm_admin "/api/admin/simulator/ec2-code-failure/start"

echo ""
print_success "Issue injected successfully!"
echo ""
print_warning "The ECS deployment is now in progress via GitHub Actions."
print_warning "This takes 3–5 minutes to complete."
print_info "Monitor the deployment at: https://github.com/<your-repo>/actions"
echo ""
print_info "=============================================="
print_info "SCENARIO:"
print_info "=============================================="
echo "A recent GitHub Actions deployment to the CRM Contact Sync Service"
echo "(running on ECS Fargate) has introduced a code-level bug."
echo "The database write operation is missing error handling (try/catch)."
echo "Contact sync requests that trigger constraint violations now cause"
echo "unhandled exceptions and 5xx errors."
echo ""
print_info "YOUR TASK:"
echo "1. Use AWS DevOps Agent to investigate the ECS application errors"
echo "2. Check CloudWatch Logs for application stack traces from the ECS task"
echo "3. Trace the error to the recent GitHub Actions deployment"
echo "4. Identify the missing try/catch block in the source code"
echo "5. Recommend a code-level fix"
echo ""
print_info "HINTS:"
echo "- Check CloudWatch Logs for the Contact Sync Service log group"
echo "- Look for unhandled exception stack traces pointing to a specific file and line"
echo "- Review the GitHub Actions deployment history for recent commits"
echo "- The root cause is a missing try/catch around an RDS INSERT/UPDATE operation"
echo ""
print_warning "Run 'rollback-ecs-code-failure.sh' to restore normal operation"
print_info "=============================================="
