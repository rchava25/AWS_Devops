#!/bin/bash
# Lab: Database Connectivity - Security Group Blocked
# Issue: Remove the RDS security group rule allowing catalog service access
# Symptom: Catalog service can't connect to MySQL, products don't load

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Initialize ECS lab environment
init_ecs_lab

# Derive environment name from cluster name (cluster name is ${env}-cluster)
ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-${ECS_CLUSTER_NAME%-cluster}}"

print_info "=============================================="
print_info "Lab: Database Security Group Blocked"
print_info "=============================================="
echo ""
print_info "Injecting network issue..."

# Find the RDS security group
RDS_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=tag:Name,Values=*${ENVIRONMENT_NAME}*catalog*db*" \
    --query 'SecurityGroups[0].GroupId' --output text --region $AWS_REGION 2>/dev/null)

if [ -z "$RDS_SG_ID" ] || [ "$RDS_SG_ID" == "None" ]; then
    RDS_SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=*catalog*rds*" \
        --query 'SecurityGroups[0].GroupId' --output text --region $AWS_REGION 2>/dev/null)
fi

if [ -z "$RDS_SG_ID" ] || [ "$RDS_SG_ID" == "None" ]; then
    print_info "Trying to find by RDS instance..."
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
        print_error "Could not find ECS RDS security group. Manual setup required."
        exit 1
    fi
fi

# Handle case where multiple SGs are returned (take only the first one)
RDS_SG_ID=$(echo "$RDS_SG_ID" | awk '{print $1}')

print_info "Found RDS Security Group: $RDS_SG_ID"

# Get the catalog service security group
CATALOG_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=tag:Name,Values=*${ENVIRONMENT_NAME}*catalog*task*" \
    --query 'SecurityGroups[0].GroupId' --output text --region $AWS_REGION 2>/dev/null)

if [ -z "$CATALOG_SG_ID" ] || [ "$CATALOG_SG_ID" == "None" ]; then
    CATALOG_SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=*catalog*task*" \
        --query 'SecurityGroups[0].GroupId' --output text --region $AWS_REGION 2>/dev/null)
fi

# If still not found, try to find any SG with inbound rule to RDS on port 3306
if [ -z "$CATALOG_SG_ID" ] || [ "$CATALOG_SG_ID" == "None" ]; then
    print_info "Trying to find catalog SG from RDS inbound rules..."
    CATALOG_SG_ID=$(aws ec2 describe-security-group-rules \
        --filters "Name=group-id,Values=$RDS_SG_ID" \
        --query "SecurityGroupRules[?FromPort==\`3306\` && ReferencedGroupInfo.GroupId!=null].ReferencedGroupInfo.GroupId | [0]" \
        --output text --region $AWS_REGION 2>/dev/null)
fi

if [ -z "$CATALOG_SG_ID" ] || [ "$CATALOG_SG_ID" == "None" ]; then
    print_error "Could not find catalog task security group."
    print_info "Listing all inbound rules on RDS SG for debugging:"
    aws ec2 describe-security-group-rules \
        --filters "Name=group-id,Values=$RDS_SG_ID" \
        --query "SecurityGroupRules[?IsEgress==\`false\`].{RuleId:SecurityGroupRuleId,Port:FromPort,SourceSG:ReferencedGroupInfo.GroupId,SourceCIDR:CidrIpv4}" \
        --output table --region $AWS_REGION 2>/dev/null || true
    exit 1
fi

print_info "Found Catalog Task Security Group: $CATALOG_SG_ID"

# Save for restoration
echo "$RDS_SG_ID" > /tmp/ecs_lab_rds_sg_id.txt
echo "$CATALOG_SG_ID" > /tmp/ecs_lab_catalog_sg_id.txt

# Find and remove the ingress rule from catalog to RDS
RULE_ID=$(aws ec2 describe-security-group-rules \
    --filters "Name=group-id,Values=$RDS_SG_ID" \
    --query "SecurityGroupRules[?ReferencedGroupInfo.GroupId=='$CATALOG_SG_ID'].SecurityGroupRuleId" \
    --output text --region $AWS_REGION 2>/dev/null)

if [ -n "$RULE_ID" ] && [ "$RULE_ID" != "None" ]; then
    echo "$RULE_ID" > /tmp/ecs_lab_rule_id.txt
    aws ec2 revoke-security-group-ingress --group-id $RDS_SG_ID --security-group-rule-ids $RULE_ID --region $AWS_REGION
    print_success "Removed security group rule: $RULE_ID"
else
    print_info "No rule found by SG reference, trying by port..."
    aws ec2 revoke-security-group-ingress --group-id $RDS_SG_ID \
        --protocol tcp --port 3306 --source-group $CATALOG_SG_ID --region $AWS_REGION 2>/dev/null && \
        print_success "Removed MySQL (3306) rule from catalog to RDS" || \
        print_warning "Could not remove rule - it may already be removed"
    echo "3306" > /tmp/ecs_lab_port.txt
fi

# Force catalog service to reconnect
print_info "Forcing catalog service redeployment..."
aws ecs update-service --cluster $ECS_CLUSTER_NAME --service catalog --force-new-deployment --region $AWS_REGION > /dev/null
print_success "Catalog service redeployment triggered"

echo ""
print_success "Issue injected successfully!"
echo ""
print_info "=============================================="
print_info "SCENARIO:"
print_info "=============================================="
echo "The product catalog suddenly stopped loading."
echo "The catalog service is running but returns errors."
echo "Database connection timeouts in the logs."
echo ""
print_info "YOUR TASK:"
echo "1. Use AWS DevOps Agent to investigate catalog service errors"
echo "2. Check CloudWatch logs for connection errors"
echo "3. Examine the network path between ECS and RDS"
echo "4. Identify the security group misconfiguration"
echo ""
print_info "HINTS:"
echo "- Check catalog service logs for MySQL connection errors"
echo "- Examine security groups attached to RDS and ECS tasks"
echo "- Verify inbound rules allow traffic on port 3306"
echo "- Use VPC Flow Logs if enabled"
echo ""
print_warning "Run 'rollback-service-discovery-broken.sh' when ready to restore"
print_info "=============================================="
