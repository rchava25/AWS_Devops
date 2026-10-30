#!/bin/bash
# Splunk variant rollback for Lab 4: restore SG rule, keep Splunk logging
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/splunk-common.sh"
init_ecs_lab
ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-${ECS_CLUSTER_NAME%-cluster}}"

RDS_SG_ID=$(cat /tmp/ecs_lab_rds_sg_id.txt 2>/dev/null || echo "")
CATALOG_SG_ID=$(cat /tmp/ecs_lab_catalog_sg_id.txt 2>/dev/null || echo "")

if [[ -z "$RDS_SG_ID" || -z "$CATALOG_SG_ID" ]]; then
  # Rediscover
  RDS_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=tag:Name,Values=*${ENVIRONMENT_NAME}*catalog*db*" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null)
  CATALOG_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=tag:Name,Values=*${ENVIRONMENT_NAME}*catalog*task*" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null)
fi

aws ec2 authorize-security-group-ingress --group-id "$RDS_SG_ID" \
  --protocol tcp --port 3306 --source-group "$CATALOG_SG_ID" \
  --region "$AWS_REGION" > /dev/null 2>&1 || echo "Rule may already exist"

aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "catalog" \
  --force-new-deployment --region "$AWS_REGION" > /dev/null

rm -f /tmp/ecs_lab_rds_sg_id.txt /tmp/ecs_lab_catalog_sg_id.txt
print_success "SG rule restored. Splunk logging preserved on catalog."
