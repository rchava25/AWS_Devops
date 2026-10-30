#!/bin/bash
# Lab Fix: Restore Database Security Group Access

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Initialize ECS lab environment
init_ecs_lab

# Derive environment name from cluster name (cluster name is ${env}-cluster)
ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-${ECS_CLUSTER_NAME%-cluster}}"

print_info "Restoring database security group access..."

# Try to get from temp files first, otherwise discover dynamically
if [ -f /tmp/ecs_lab_rds_sg_id.txt ] && [ -f /tmp/ecs_lab_catalog_sg_id.txt ]; then
    RDS_SG_ID=$(cat /tmp/ecs_lab_rds_sg_id.txt)
    CATALOG_SG_ID=$(cat /tmp/ecs_lab_catalog_sg_id.txt)
    print_info "Using saved security group IDs from temp files"
else
    print_info "Temp files not found, discovering security groups dynamically..."
    
    RDS_SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=tag:Name,Values=*${ENVIRONMENT_NAME}*catalog*db*" \
        --query 'SecurityGroups[0].GroupId' --output text --region $AWS_REGION 2>/dev/null)

    if [ -z "$RDS_SG_ID" ] || [ "$RDS_SG_ID" == "None" ]; then
        RDS_SG_ID=$(aws ec2 describe-security-groups \
            --filters "Name=group-name,Values=*catalog*rds*" \
            --query 'SecurityGroups[0].GroupId' --output text --region $AWS_REGION 2>/dev/null)
    fi

    if [ -z "$RDS_SG_ID" ] || [ "$RDS_SG_ID" == "None" ]; then
        # Look specifically for ECS catalog RDS (contains 'ecs' AND 'catalog')
        RDS_SG_ID=$(aws rds describe-db-instances \
            --query "DBInstances[?contains(DBInstanceIdentifier, 'ecs') && contains(DBInstanceIdentifier, 'catalog')].VpcSecurityGroups[0].VpcSecurityGroupId | [0]" \
            --output text --region $AWS_REGION 2>/dev/null)

        # Fallback: try matching the environment name pattern
        if [ -z "$RDS_SG_ID" ] || [ "$RDS_SG_ID" == "None" ]; then
            RDS_SG_ID=$(aws rds describe-db-instances \
                --query "DBInstances[?contains(DBInstanceIdentifier, '${ENVIRONMENT_NAME}') && contains(DBInstanceIdentifier, 'catalog')].VpcSecurityGroups[0].VpcSecurityGroupId | [0]" \
                --output text --region $AWS_REGION 2>/dev/null)
        fi

        if [ -z "$RDS_SG_ID" ] || [ "$RDS_SG_ID" == "None" ]; then
            print_error "Could not find ECS RDS security group."
            exit 1
        fi
    fi

    CATALOG_SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=tag:Name,Values=*${ENVIRONMENT_NAME}*catalog*task*" \
        --query 'SecurityGroups[0].GroupId' --output text --region $AWS_REGION 2>/dev/null)

    if [ -z "$CATALOG_SG_ID" ] || [ "$CATALOG_SG_ID" == "None" ]; then
        CATALOG_SG_ID=$(aws ec2 describe-security-groups \
            --filters "Name=group-name,Values=*catalog*task*" \
            --query 'SecurityGroups[0].GroupId' --output text --region $AWS_REGION 2>/dev/null)
    fi

    if [ -z "$CATALOG_SG_ID" ] || [ "$CATALOG_SG_ID" == "None" ]; then
        print_error "Could not find catalog task security group."
        exit 1
    fi
fi

print_info "RDS Security Group: $RDS_SG_ID"
print_info "Catalog Task Security Group: $CATALOG_SG_ID"

# Check if rule already exists
EXISTING_RULE=$(aws ec2 describe-security-group-rules \
    --filters "Name=group-id,Values=$RDS_SG_ID" \
    --query "SecurityGroupRules[?ReferencedGroupInfo.GroupId=='$CATALOG_SG_ID' && FromPort==\`3306\`].SecurityGroupRuleId" \
    --output text --region $AWS_REGION 2>/dev/null)

if [ -n "$EXISTING_RULE" ] && [ "$EXISTING_RULE" != "None" ]; then
    print_info "Security group rule already exists: $EXISTING_RULE"
else
    aws ec2 authorize-security-group-ingress \
        --group-id $RDS_SG_ID \
        --protocol tcp \
        --port 3306 \
        --source-group $CATALOG_SG_ID \
        --region $AWS_REGION > /dev/null 2>&1 || echo "Rule may already exist"
    print_success "Added security group rule allowing MySQL (3306) from catalog to RDS"
fi

# Force catalog service to reconnect
aws ecs update-service --cluster $ECS_CLUSTER_NAME --service catalog --force-new-deployment --region $AWS_REGION > /dev/null

# Cleanup temp files
rm -f /tmp/ecs_lab_*.txt

print_success "Security group rule restored! Catalog should connect to database shortly."
echo "   Wait 1-2 minutes for the new tasks to start."
