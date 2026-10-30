#!/bin/bash
# =============================================================================
# Verify ECS CPU/memory alarms use percentage metrics and behave sanely.
# =============================================================================
# Context: the ecs-{service}-cpu-high / -memory-high alarms previously used
# CpuUtilized / MemoryUtilized (absolute CPU units / megabytes) compared to a
# percent-style threshold (default 80), so every service alarmed permanently.
# They must use TaskCpuUtilization / TaskMemoryUtilization (Unit: Percent,
# Container Insights enhanced observability).
#
# Run this in a deployed workshop account (e.g., from the IDE terminal):
#   bash ~/scripts/verify-ecs-alarms.sh
#
# Checks per alarm:
#   1. Metric name is the percentage metric (not the absolute one)
#   2. The metric is actually publishing datapoints (enhanced CI enabled)
#   3. Recent datapoints are in the sane 0-100 percent range
#   4. Reports current alarm state (expect OK once enough periods elapse;
#      alarms use 3 x 5-minute periods, so allow ~15 minutes after deploy)
#
# Exits non-zero if any alarm still uses the wrong metric or the percentage
# metric has out-of-range values.

set -uo pipefail

PREFIX="${ALARM_PREFIX:-devops-agent-workshop-ecs}"
REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}"
FAILURES=0

echo "=============================================="
echo " ECS alarm metric verification ($REGION)"
echo "=============================================="

ALARMS=$(aws cloudwatch describe-alarms --region "$REGION" \
  --alarm-name-prefix "$PREFIX" \
  --query "MetricAlarms[?contains(AlarmName, 'cpu-high') || contains(AlarmName, 'memory-high')].[AlarmName,MetricName,Threshold,StateValue,Namespace]" \
  --output text)

if [ -z "$ALARMS" ]; then
  echo "[ERROR] No cpu-high/memory-high alarms found with prefix '$PREFIX'."
  echo "        Check the prefix (override with ALARM_PREFIX=...) and region."
  exit 1
fi

while IFS=$'\t' read -r NAME METRIC THRESHOLD STATE NAMESPACE; do
  echo ""
  echo "Alarm: $NAME"
  echo "  metric=$METRIC threshold=$THRESHOLD state=$STATE"

  # 1) Correct (percentage) metric?
  case "$NAME" in
    *cpu-high*)    EXPECTED="TaskCpuUtilization" ;;
    *memory-high*) EXPECTED="TaskMemoryUtilization" ;;
  esac
  if [ "$METRIC" != "$EXPECTED" ]; then
    echo "  [FAIL] uses '$METRIC' (absolute units) - expected '$EXPECTED' (percent)"
    FAILURES=$((FAILURES + 1))
    continue
  fi
  echo "  [OK] uses percentage metric $EXPECTED"

  # Pull the alarm's dimensions to query the exact same metric series
  DIMS=$(aws cloudwatch describe-alarms --region "$REGION" --alarm-names "$NAME" \
    --query "MetricAlarms[0].Dimensions" --output json)
  CLUSTER=$(echo "$DIMS" | grep -A1 '"ClusterName"' | grep Value | sed 's/.*: *"\(.*\)".*/\1/')
  SERVICE=$(echo "$DIMS" | grep -A1 '"ServiceName"' | grep Value | sed 's/.*: *"\(.*\)".*/\1/')

  # 2+3) Metric publishing, and values in 0-100?
  STATS=$(aws cloudwatch get-metric-statistics --region "$REGION" \
    --namespace "$NAMESPACE" --metric-name "$METRIC" \
    --dimensions Name=ClusterName,Value="$CLUSTER" Name=ServiceName,Value="$SERVICE" \
    --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 300 --statistics Average \
    --query "Datapoints[].Average" --output text)

  if [ -z "$STATS" ]; then
    echo "  [WARN] no datapoints in the last hour - if the stack just deployed,"
    echo "         wait a few minutes; otherwise confirm Container Insights is 'enhanced'"
    continue
  fi

  BAD=0
  for v in $STATS; do
    # percentage sanity: 0 <= v <= 100
    awk -v x="$v" 'BEGIN { exit !(x >= 0 && x <= 100) }' || BAD=1
  done
  if [ "$BAD" -eq 1 ]; then
    echo "  [FAIL] datapoints outside 0-100 range: $STATS"
    echo "         (values like 128/256/512 suggest the absolute MB/units metric)"
    FAILURES=$((FAILURES + 1))
  else
    echo "  [OK] datapoints are percentages: $(echo $STATS | tr '\t' ' ')"
    echo "  [INFO] state=$STATE (expect OK ~15 min after deploy unless usage is genuinely >$THRESHOLD%)"
  fi
done <<< "$ALARMS"

echo ""
echo "=============================================="
if [ "$FAILURES" -gt 0 ]; then
  echo " RESULT: $FAILURES check(s) FAILED"
  exit 1
fi
echo " RESULT: all alarm metric checks passed"
echo "=============================================="
