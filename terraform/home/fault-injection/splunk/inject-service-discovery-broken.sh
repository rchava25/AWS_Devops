#!/bin/bash
# Splunk variant of Lab 4: Database Security Group Blocked
# Switches catalog to Splunk logging, then removes RDS SG rule
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/splunk-common.sh"

init_ecs_lab
ensure_splunk_params
ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-${ECS_CLUSTER_NAME%-cluster}}"

print_info "=============================================="
print_info "Splunk Lab 4: Database SG Blocked"
print_info "=============================================="
echo ""

print_info "Switching catalog to Splunk logging..."
switch_service_to_splunk "catalog"
aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" --services "catalog" \
  --region "$AWS_REGION" 2>/dev/null || true

# Now inject the SG fault (same logic as ecs/ version)
print_info "Injecting network issue..."
RDS_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=*${ENVIRONMENT_NAME}*catalog*db*" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null)
[[ -z "$RDS_SG_ID" || "$RDS_SG_ID" == "None" ]] && \
  RDS_SG_ID=$(aws rds describe-db-instances \
    --query "DBInstances[?contains(DBInstanceIdentifier, 'catalog')].VpcSecurityGroups[0].VpcSecurityGroupId | [0]" \
    --output text --region "$AWS_REGION" 2>/dev/null | head -1)
[[ -z "$RDS_SG_ID" || "$RDS_SG_ID" == "None" ]] && { print_error "Could not find RDS SG."; exit 1; }

CATALOG_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=*${ENVIRONMENT_NAME}*catalog*task*" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null)

echo "$RDS_SG_ID" > /tmp/ecs_lab_rds_sg_id.txt
echo "$CATALOG_SG_ID" > /tmp/ecs_lab_catalog_sg_id.txt

RULE_ID=$(aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$RDS_SG_ID" \
  --query "SecurityGroupRules[?ReferencedGroupInfo.GroupId=='$CATALOG_SG_ID'].SecurityGroupRuleId" \
  --output text --region "$AWS_REGION" 2>/dev/null)

if [[ -n "$RULE_ID" && "$RULE_ID" != "None" ]]; then
  aws ec2 revoke-security-group-ingress --group-id "$RDS_SG_ID" \
    --security-group-rule-ids "$RULE_ID" --region "$AWS_REGION"
else
  aws ec2 revoke-security-group-ingress --group-id "$RDS_SG_ID" \
    --protocol tcp --port 3306 --source-group "$CATALOG_SG_ID" --region "$AWS_REGION" 2>/dev/null || true
fi

aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "catalog" \
  --force-new-deployment --region "$AWS_REGION" > /dev/null

print_success "Issue injected! Catalog can't reach database. Splunk logging active."
print_warning "Run 'rollback-service-discovery-broken.sh' in ~/fault-injection/splunk/ to fix"
