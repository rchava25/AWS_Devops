#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

init_ecs_lab

# Discover UI service ALB
print_info "Discovering UI service load balancer..."
TARGET_GROUP_ARN=$(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" \
  --services ui --region "$AWS_REGION" \
  --query 'services[0].loadBalancers[0].targetGroupArn' --output text 2>/dev/null)

if [[ -z "$TARGET_GROUP_ARN" || "$TARGET_GROUP_ARN" == "None" ]]; then
  print_error "Could not find target group for UI service"
  exit 1
fi

ALB_ARN=$(aws elbv2 describe-target-groups --target-group-arns "$TARGET_GROUP_ARN" \
  --region "$AWS_REGION" --query 'TargetGroups[0].LoadBalancerArns[0]' --output text 2>/dev/null)

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --region "$AWS_REGION" --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null)

if [[ -z "$ALB_DNS" || "$ALB_DNS" == "None" ]]; then
  print_error "Could not discover ALB DNS name"
  exit 1
fi

URL="http://${ALB_DNS}"

echo "=========================================="
echo "Heavy Load Test - 10 Minutes"
echo "=========================================="
echo "URL: $URL"
echo "Start time: $(date)"
echo ""

# Run for 10 minutes (600 seconds)
END=$((SECONDS+600))
COUNT=0
SUCCESS=0
ERRORS=0

while [ $SECONDS -lt $END ]; do
    COUNT=$((COUNT+1))
    
    # Show progress every 10 requests
    if [ $((COUNT % 10)) -eq 0 ]; then
        ELAPSED=$((SECONDS))
        REMAINING=$((600 - ELAPSED))
        echo "$(date +%H:%M:%S) - Requests: $COUNT | Errors: $ERRORS | Success: $SUCCESS | Time remaining: ${REMAINING}s"
    fi
    
    # Browse home page
    curl -s -o /dev/null "$URL/" &
    
    # Browse catalog
    curl -s -o /dev/null "$URL/catalogue" &
    
    # View products
    curl -s -o /dev/null "$URL/catalogue/6d62d909-f957-430e-8689-b5129c0bb75e" &
    curl -s -o /dev/null "$URL/catalogue/510a0d7e-8e83-4193-b483-e27e09ddc34d" &
    
    # Add to cart
    curl -s -o /dev/null -X POST "$URL/carts/items" \
        -H "Content-Type: application/json" \
        -d '{"itemId":"6d62d909-f957-430e-8689-b5129c0bb75e","quantity":1,"unitPrice":100}' &
    
    # Try checkout (this triggers the error)
    HTTP_CODE=$(curl -s -w "%{http_code}" -o /dev/null -X POST "$URL/checkout" \
        -H "Content-Type: application/json" \
        -d '{}')
    
    if [ "$HTTP_CODE" = "500" ]; then
        ERRORS=$((ERRORS+1))
    else
        SUCCESS=$((SUCCESS+1))
    fi
    
    # Wait for background jobs to complete
    wait
    
    # Small delay between iterations (1 second = ~6 requests/sec)
    sleep 1
done

echo ""
echo "=========================================="
echo "Load Test Complete"
echo "=========================================="
echo "End time: $(date)"
echo "Total requests: $COUNT"
echo "Checkout errors (500): $ERRORS"
echo "Checkout success: $SUCCESS"
echo ""
echo "Check Dynatrace for failure rate and problem detection."
