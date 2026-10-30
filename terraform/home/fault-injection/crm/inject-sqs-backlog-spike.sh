#!/bin/bash
# Lab: SQS Backlog Spike
# Triggers a sudden spike in SQS queue backlog for the CRM application
# Symptom: Messages pile up in the queue, processing delays, potential timeouts

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/crm-common.sh"

# Initialize CRM lab environment
init_crm_lab

print_info "=============================================="
print_info "Lab: SQS Backlog Spike"
print_info "=============================================="
echo ""

# Trigger the SQS backlog spike scenario
print_info "Triggering SQS backlog spike..."
call_crm_admin "/api/admin/simulator/sqs-backlog-spike/start"

echo ""
print_success "Issue injected successfully!"
echo ""
print_info "=============================================="
print_info "SCENARIO:"
print_info "=============================================="
echo "The CRM application's SQS queue is experiencing a sudden backlog spike."
echo "Messages are piling up and not being processed in a timely manner."
echo "Users report delays in order processing and notification delivery."
echo ""
print_info "YOUR TASK:"
echo "1. Use AWS DevOps Agent to investigate the SQS backlog"
echo "2. Check CloudWatch metrics for SQS queue depth"
echo "3. Examine Lambda consumer logs for processing errors"
echo "4. Identify the root cause of the message backlog"
echo ""
print_info "HINTS:"
echo "- Check SQS ApproximateNumberOfMessagesVisible metric"
echo "- Look at Lambda concurrent executions and error rates"
echo "- Examine dead-letter queue for failed messages"
echo ""
print_warning "Run 'rollback-sqs-backlog-spike.sh' to restore normal operation"
print_info "=============================================="
