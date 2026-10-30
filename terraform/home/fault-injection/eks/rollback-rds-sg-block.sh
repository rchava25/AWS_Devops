#!/bin/bash
# RDS Security Group Rollback Script
# Restores ingress rules allowing EKS services to connect to RDS instances
# Handles both security group-based and CIDR-based rules

set -e

REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT_NAME="devops-agent-eks"
VPC_CIDR="10.0.0.0/16"

echo "=== RDS Security Group Rollback ==="
echo ""

# Use script directory for backup file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_FILE="$SCRIPT_DIR/rds-sg-ids.json"

# Check if backup file exists
if [ ! -f "$BACKUP_FILE" ]; then
  echo "WARNING: No backup file found at $BACKUP_FILE"
  echo "Attempting automatic discovery and restoration..."
  echo ""
  
  # Discover RDS clusters and restore CIDR rules
  echo "[1/5] Discovering RDS clusters..."
  RDS_INFO=$(AWS_PAGER="" aws rds describe-db-clusters --region $REGION \
    --query "DBClusters[?contains(DBClusterIdentifier, '${ENVIRONMENT_NAME}')].[DBClusterIdentifier,VpcSecurityGroups[0].VpcSecurityGroupId,Port]" \
    --output json 2>/dev/null)
  
  if [ -z "$RDS_INFO" ] || [ "$RDS_INFO" == "[]" ]; then
    echo "ERROR: No RDS clusters found for environment $ENVIRONMENT_NAME"
    exit 1
  fi
  
  echo "  Found RDS clusters:"
  echo "$RDS_INFO" | jq -r '.[] | "    - \(.[0]) (SG: \(.[1]), Port: \(.[2]))"'
  echo ""
  
  echo "[2/5] Restoring CIDR rules ($VPC_CIDR)..."
  RESTORED=0
  FAILED=0
  
  for row in $(echo "$RDS_INFO" | jq -r '.[] | @base64'); do
    _jq() {
      echo ${row} | base64 --decode | jq -r ${1}
    }
    
    DB_ID=$(_jq '.[0]')
    RDS_SG=$(_jq '.[1]')
    DB_PORT=$(_jq '.[2]')
    
    echo "  Restoring: $DB_ID (SG: $RDS_SG, Port: $DB_PORT)"
    
    if AWS_PAGER="" aws ec2 authorize-security-group-ingress \
      --group-id $RDS_SG \
      --protocol tcp \
      --port $DB_PORT \
      --cidr $VPC_CIDR \
      --region $REGION 2>/dev/null; then
      echo "    ✓ CIDR rule restored from $VPC_CIDR"
      RESTORED=$((RESTORED + 1))
    else
      echo "    ✗ Failed to restore (may already exist)"
      FAILED=$((FAILED + 1))
    fi
  done
  
  echo ""
  echo "Restored: $RESTORED rules"
  echo "Failed/Existing: $FAILED rules"
  
  # Skip to pod restart section
  SKIP_BACKUP_RESTORE=true
else
  SKIP_BACKUP_RESTORE=false
fi

# Load backup info and restore from backup file
if [ "$SKIP_BACKUP_RESTORE" != "true" ]; then
  REGION=$(jq -r '.region' "$BACKUP_FILE")
  REVOKED_RULES=$(jq -r '.revoked_rules' "$BACKUP_FILE")

  echo "Region: $REGION"
  echo ""

  RULE_COUNT=$(echo "$REVOKED_RULES" | jq 'length')
  if [ "$RULE_COUNT" -eq 0 ]; then
    echo "No rules to restore. Backup file shows no rules were revoked."
    exit 0
  fi

  echo "[1/5] Restoring $RULE_COUNT security group rules..."
  echo ""

  RESTORED=0
  FAILED=0

  # Restore each revoked rule
  for row in $(echo "$REVOKED_RULES" | jq -r '.[] | @base64'); do
    _jq() {
      echo ${row} | base64 --decode | jq -r ${1}
    }
    
    RDS_SG=$(_jq '.rds_sg')
    RULE_TYPE=$(_jq '.type')
    SOURCE=$(_jq '.source')
    PORT=$(_jq '.port')
    DB_ID=$(_jq '.db_id')
    
    echo "  Restoring: $DB_ID (RDS SG: $RDS_SG, Type: $RULE_TYPE, Source: $SOURCE, Port: $PORT)"
    
    if [ "$RULE_TYPE" == "sg" ]; then
      # Restore security group-based rule
      if AWS_PAGER="" aws ec2 authorize-security-group-ingress \
        --group-id $RDS_SG \
        --protocol tcp \
        --port $PORT \
        --source-group $SOURCE \
        --region $REGION 2>/dev/null; then
        echo "    ✓ SG rule restored from $SOURCE"
        
        # Add description to the rule
        AWS_PAGER="" aws ec2 update-security-group-rule-descriptions-ingress \
          --group-id $RDS_SG \
          --ip-permissions "IpProtocol=tcp,FromPort=$PORT,ToPort=$PORT,UserIdGroupPairs=[{GroupId=$SOURCE,Description=From allowed SGs}]" \
          --region $REGION 2>/dev/null || true
        
        RESTORED=$((RESTORED + 1))
      else
        echo "    ✗ Failed to restore SG rule (may already exist)"
        FAILED=$((FAILED + 1))
      fi
    elif [ "$RULE_TYPE" == "cidr" ]; then
      # Restore CIDR-based rule
      if AWS_PAGER="" aws ec2 authorize-security-group-ingress \
        --group-id $RDS_SG \
        --protocol tcp \
        --port $PORT \
        --cidr $SOURCE \
        --region $REGION 2>/dev/null; then
        echo "    ✓ CIDR rule restored from $SOURCE"
        
        # Add description to the rule
        AWS_PAGER="" aws ec2 update-security-group-rule-descriptions-ingress \
          --group-id $RDS_SG \
          --ip-permissions "IpProtocol=tcp,FromPort=$PORT,ToPort=$PORT,IpRanges=[{CidrIp=$SOURCE,Description=From VPC CIDR}]" \
          --region $REGION 2>/dev/null || true
        
        RESTORED=$((RESTORED + 1))
      else
        echo "    ✗ Failed to restore CIDR rule (may already exist)"
        FAILED=$((FAILED + 1))
      fi
    else
      echo "    ✗ Unknown rule type: $RULE_TYPE"
      FAILED=$((FAILED + 1))
    fi
  done

  echo ""
  echo "Restored: $RESTORED rules"
  echo "Failed: $FAILED rules"
fi

# Restart pods to reconnect to database
echo ""
echo "[3/5] Restarting application pods..."

if kubectl get deployment -n catalog catalog &>/dev/null; then
  kubectl rollout restart deployment -n catalog catalog 2>/dev/null && echo "  ✓ Restarted catalog deployment"
fi

if kubectl get deployment -n orders orders &>/dev/null; then
  kubectl rollout restart deployment -n orders orders 2>/dev/null && echo "  ✓ Restarted orders deployment"
fi

echo ""
echo "Waiting 45 seconds for pods to restart..."
sleep 45

# Check pod status
echo ""
echo "[4/5] Checking pod status..."
echo ""
echo "  Catalog pods:"
kubectl get pods -n catalog -l app.kubernetes.io/name=catalog --no-headers 2>/dev/null | sed 's/^/    /' || echo "    No catalog pods found"
echo ""
echo "  Orders pods:"
kubectl get pods -n orders -l app.kubernetes.io/name=orders --no-headers 2>/dev/null | sed 's/^/    /' || echo "    No orders pods found"

# Check connectivity
echo ""
echo "[5/5] Checking service connectivity..."

check_service() {
  local namespace=$1
  local service=$2
  local local_port=$3
  local endpoint=$4
  
  kubectl port-forward -n $namespace svc/$service $local_port:80 &>/dev/null &
  local pf_pid=$!
  sleep 2
  
  if kill -0 $pf_pid 2>/dev/null; then
    local status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$local_port$endpoint" 2>/dev/null)
    kill $pf_pid 2>/dev/null
    if [ "$status" == "200" ] || [ "$status" == "201" ]; then
      echo "  ✓ $service: HTTP $status (healthy)"
    else
      echo "  ⚠ $service: HTTP $status"
    fi
  else
    echo "  ✗ $service: Could not connect"
  fi
}

check_service "catalog" "catalog" 8082 "/catalogue"
check_service "orders" "orders" 8080 "/orders"

echo ""
echo "=== Rollback Complete ==="
