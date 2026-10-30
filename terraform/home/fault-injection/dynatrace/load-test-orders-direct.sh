#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

init_ecs_lab

# This script runs INSIDE an ECS task to directly hit the orders service
# via Service Connect (internal service mesh)

echo "=========================================="
echo "Direct Orders Service Load Test - 10 Minutes"
echo "=========================================="
echo "Target: orders service (internal)"
echo "Start time: $(date)"
echo ""

# Get a task ARN to exec into
TASK_ARN=$(aws ecs list-tasks --cluster "$ECS_CLUSTER_NAME" \
  --service-name ui --region "$AWS_REGION" --query 'taskArns[0]' --output text)

if [ -z "$TASK_ARN" ] || [ "$TASK_ARN" = "None" ]; then
  echo "ERROR: Could not find UI task to exec into"
  exit 1
fi

echo "Using task: $TASK_ARN"
echo ""

# Create the load test command to run inside the container
cat > /tmp/orders-load-test.sh << 'INNERSCRIPT'
#!/bin/bash
END=$((SECONDS+600))
COUNT=0
ERRORS=0
SUCCESS=0

while [ $SECONDS -lt $END ]; do
    COUNT=$((COUNT+1))
    
    if [ $((COUNT % 10)) -eq 0 ]; then
        ELAPSED=$((SECONDS))
        REMAINING=$((600 - ELAPSED))
        echo "$(date +%H:%M:%S) - Requests: $COUNT | Errors: $ERRORS | Success: $SUCCESS | Remaining: ${REMAINING}s"
    fi
    
    # Hit orders service directly via Service Connect
    HTTP_CODE=$(curl -s -w "%{http_code}" -o /dev/null -X POST "http://orders/orders" \
        -H "Content-Type: application/json" \
        -d '{"customerId":"test-user","items":[{"productId":"prod-1","quantity":1}]}')
    
    if [ "$HTTP_CODE" = "500" ]; then
        ERRORS=$((ERRORS+1))
    else
        SUCCESS=$((SUCCESS+1))
    fi
    
    sleep 1
done

echo ""
echo "Direct orders test complete: $COUNT requests, $ERRORS errors, $SUCCESS success"
INNERSCRIPT

# Copy script into container and execute
echo "Copying script to container..."
aws ecs execute-command --cluster devops-agent-workshop-ecs-cluster \
  --task "$TASK_ARN" \
  --container ui-service \
  --region us-east-1 \
  --interactive \
  --command "bash -c 'cat > /tmp/test.sh && chmod +x /tmp/test.sh && /tmp/test.sh'" \
  < /tmp/orders-load-test.sh

echo ""
echo "Direct orders load test complete."
