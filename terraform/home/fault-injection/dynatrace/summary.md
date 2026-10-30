# Dynatrace Integration - Complete Workflow

This document provides a high-level overview of the Dynatrace OTEL integration setup, testing, and teardown process.

## Prerequisites (Before You Start)

1. **ECS infrastructure deployed** - Retail store services running on ECS
2. **Dynatrace tenant** - Active tenant with OTLP ingest enabled
3. **Dynatrace API token** - With scopes: `openTelemetryTrace.ingest`, `metrics.ingest`, `logs.ingest`
4. **AWS credentials** - Permissions for ECS, Secrets Manager, CloudWatch

---

## Phase 1: Deploy Dynatrace Integration (5-10 minutes)

```bash
cd ~/environment/terraform/home/fault-injection/dynatrace/

# Step 1: Deploy OTEL sidecars to all services
./prepare-dynatrace-environment.sh
```

**What it does:**
- Prompts for Dynatrace OTLP endpoint and API token
- Stores token in AWS Secrets Manager
- Updates all 5 ECS services (ui, catalog, carts, checkout, orders) with:
  - OTEL collector sidecar container
  - Init container to download Java agent
  - Environment variables to activate OTEL instrumentation
- Waits for services to stabilize

**Result:** All services now send telemetry to Dynatrace

---

## Phase 2: Verify Integration (2-3 minutes)

```bash
# Step 2: Check that OTEL sidecars are running
./check-dynatrace-status.sh
```

**What it checks:**
- State file exists
- Secret is in Secrets Manager
- OTEL collector in all task definitions
- Collector containers are running
- Export activity in logs

**Result:** Confirms telemetry pipeline is working

---

## Phase 3: Establish Baseline (5 minutes)

**Why:** Dynatrace Davis AI needs healthy traffic to establish a baseline before it can detect anomalies

**What to do:**
- Wait 5 minutes with normal traffic flowing
- Or manually browse the application
- Davis AI learns what "normal" looks like

**Important:** Without a baseline, Davis AI cannot detect anomalies

---

## Phase 4: Inject Fault (1 minute)

```bash
# Step 3: Break the orders service
./inject-orders-db-broken.sh
```

**What it does:**
- Overrides RabbitMQ host to `nonexistent-mq-host.invalid` in orders service
- Forces immediate task restart
- Orders service starts but fails when trying to publish messages

**Result:** Checkout operations return HTTP 500 errors

---

## Phase 5: Generate Traffic (10 minutes)

```bash
# Step 4: Generate sustained traffic to trigger errors
./load-test-script.sh
```

**Why:** Davis AI needs sustained error traffic to detect the anomaly and open a problem

**What it does:**
- Simulates users browsing and checking out
- Generates ~6 requests/second for 10 minutes
- Each checkout attempt fails with 500 error

**Result:** Continuous stream of failures for Davis AI to analyze

**Alternative (direct orders targeting):**
```bash
./load-test-orders-direct.sh
```
- Requires ECS exec enabled
- Hits orders service directly via Service Connect

---

## Phase 6: Monitor Dynatrace (1-2 minutes)

**Go to Dynatrace UI:**

1. **Services** → Check `ui` and `orders` for elevated failure rates
2. **Traces** → Look for error spans with RabbitMQ connection failures
3. **Problems** → Wait for "Failure rate increase" problem to open
4. **DevOps Agent** (if configured) → Check for investigation notebook

**Expected timeline:**
- **Immediate:** Traces and metrics start appearing
- **1-2 minutes:** Davis AI detects anomaly
- **2-3 minutes:** Problem opens with details

**Why UI service shows failures:**
- The `/checkout` endpoint is hosted by UI service
- UI/checkout calls orders service internally via Service Connect
- Orders service fails due to broken RabbitMQ connection
- Error propagates back to UI/checkout, which returns 500 to client
- Both services show failures in Dynatrace

---

## Phase 7: Rollback (1 minute)

```bash
# Step 5: Restore orders service to healthy state
./rollback-orders-db-broken.sh
```

**What it does:**
- Restores orders service to previous task definition (before fault)
- Keeps OTEL sidecar active
- Service recovers within 1-2 minutes

**Result:** Failure rate drops to 0%, problem auto-closes

---

## Phase 8: Cleanup (1 minute)

```bash
# Step 6: Remove Dynatrace integration when done
./cleanup-dynatrace.sh
```

**What it does:**
- Restores all services to original task definitions (no sidecars)
- Deletes Dynatrace token from Secrets Manager
- Removes state file

**Result:** Services back to pre-Dynatrace state

---

## Quick Reference Commands

```bash
# Full workflow
cd ~/environment/terraform/home/fault-injection/dynatrace/

./prepare-dynatrace-environment.sh    # Deploy integration
./check-dynatrace-status.sh           # Verify it's working
# Wait 5 minutes for baseline
./inject-orders-db-broken.sh          # Break orders service
./load-test-script.sh                 # Generate traffic (10 min)
# Check Dynatrace UI for problem
./rollback-orders-db-broken.sh        # Fix orders service
./cleanup-dynatrace.sh                # Remove integration
```

---

## Key Points

1. **Order matters** - Baseline before fault, traffic after fault
2. **Patience required** - Davis AI needs time to learn and detect
3. **Sustained traffic** - A few requests won't trigger detection
4. **Service propagation** - Failures in orders show up in UI/checkout too
5. **OTEL agent is critical** - Without it, no detailed traces or error context

---

## Telemetry Flow

```
App container (OTEL Java agent activated via env vars)
    │
    │ OTLP http://localhost:4318
    ▼
OTEL Collector sidecar (same ECS task)
    │
    │ Processes: cumulativetodelta (metrics only)
    │ OTLP/HTTP with "Api-Token <token>" header
    ▼
Dynatrace SaaS (https://<tenant>.live.dynatrace.com/api/v2/otlp)
    │
    │ Davis AI detects failure rate anomaly
    ▼
Dynatrace Problem opened
    │
    │ Bi-directional integration webhook (if configured)
    ▼
AWS DevOps Agent investigates
    │
    │ Posts findings + mitigation back
    ▼
Dynatrace Problem view (notebook with root cause + remediation)
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `check-dynatrace-status.sh` shows sidecars MISSING | prepare script didn't complete | Re-run `prepare-dynatrace-environment.sh` |
| otel-collector containers in STOPPED state | Bad OTEL config or OOM | Check CloudWatch logs (`otel-collector` stream prefix) |
| Collector logs show "401 Unauthorized" | Invalid API token | Re-run prepare with correct token |
| Collector logs show "connection refused" | Wrong Dynatrace endpoint URL | Re-run prepare with correct endpoint |
| No Problem opens in Dynatrace after inject | No traffic or baseline too short | Ensure load test is running; wait longer for baseline |
| Problem opens but no DevOps Agent investigation | Bi-directional integration not configured | Configure in Dynatrace UI + DevOps Agent console |
| Getting 404 on orders endpoint | Orders not exposed via load balancer | Use checkout endpoint instead (it calls orders internally) |

---

## Files in This Directory

- **`dynatrace-common.sh`** - Core library (OTEL sidecar builder, service switcher)
- **`prepare-dynatrace-environment.sh`** - One-time setup (deploys sidecars to all services)
- **`test-dynatrace-connection.sh`** - Pre-flight check (validates endpoint/token before deploy)
- **`check-dynatrace-status.sh`** - Post-deploy validation (checks sidecars are running)
- **`inject-orders-db-broken.sh`** - Fault injection (breaks RabbitMQ connection)
- **`rollback-orders-db-broken.sh`** - Restores healthy state
- **`cleanup-dynatrace.sh`** - Full teardown (removes all Dynatrace integration)
- **`load-test-script.sh`** - Traffic generator (10 min, hits checkout endpoint)
- **`load-test-orders-direct.sh`** - Alternative traffic generator (direct orders targeting)
- **`PLAN.md`** - Original implementation plan
- **`change.md`** - Detailed changes and test results
- **`summary.md`** - This file (high-level workflow)

---

## Technical Details

### What the Integration Adds

**To each ECS task definition:**

1. **Init container (`otel-agent-init`)**
   - Downloads OpenTelemetry Java agent v2.11.0
   - Stores in shared volume `/opt/otel-agent`
   - **Why needed:** The retail store container images (`public.ecr.aws/aws-containers/retail-store-sample-*:1.3.0`) don't bundle the OTEL Java agent. We cannot modify these images, so we must inject the agent at runtime. The init container downloads the agent before the app container starts, making it available via a shared volume.

2. **Sidecar container (`otel-collector`)**
   - Runs `otel/opentelemetry-collector-contrib:0.91.0`
   - Receives OTLP from app on `localhost:4318`
   - Applies `cumulativetodelta` processor to metrics
   - Exports to Dynatrace OTLP endpoint

3. **Environment variables (app container)**
   - `JAVA_TOOL_OPTIONS=-javaagent:/opt/otel-agent/opentelemetry-javaagent.jar`
   - `OTEL_SERVICE_NAME=<service-name>`
   - `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318`
   - `OTEL_METRICS_EXPORTER=otlp`
   - `OTEL_LOGS_EXPORTER=otlp`

4. **Volume mount**
   - Shared volume `otel-agent` mounted at `/opt/otel-agent`

5. **Dependencies**
   - App container depends on `otel-agent-init` (COMPLETE)

### Why Each Component is Needed

- **Java agent** - Spring Boot OTEL Starter alone doesn't provide detailed HTTP spans with status codes. The full OTEL Java agent provides:
  - Complete HTTP request/response instrumentation
  - Status code attributes on spans
  - Error context and stack traces
  - Service-to-service correlation via trace propagation
  
- **cumulativetodelta processor** - Dynatrace rejects cumulative histograms, requires delta temporality. Without this processor, metrics like `http.server.request.duration` are rejected, and failure rate calculation fails.

- **Init container** - Container images don't bundle the agent, must download at runtime. **Why this approach:**
  - We cannot modify the public ECR images (`public.ecr.aws/aws-containers/retail-store-sample-*:1.3.0`)
  - Building custom images would require maintaining forks and rebuilding on every update
  - Init container pattern allows zero-code-change instrumentation
  - Agent is downloaded once per task launch (~50MB, takes 5-10 seconds)
  - Shared volume makes agent available to app container via `JAVA_TOOL_OPTIONS`
  
- **Sidecar pattern** - No changes to application code or container images required. The OTEL collector runs as a separate container in the same task, receiving telemetry on `localhost:4318` and forwarding to Dynatrace.

---

## Success Criteria

✅ **Integration successful when:**
- All 5 services have OTEL collector sidecars running
- Collector logs show successful exports to Dynatrace
- Dynatrace UI shows services with incoming traces and metrics
- Failure rate metrics appear in Dynatrace after fault injection
- Davis AI opens a Problem for the failure rate increase
- Problem auto-closes after rollback

---

## Time Estimates

| Phase | Duration | Notes |
|-------|----------|-------|
| Deploy integration | 5-10 min | Includes service rollout time |
| Verify integration | 2-3 min | Quick validation checks |
| Establish baseline | 5 min | Required for Davis AI |
| Inject fault | 1 min | Immediate task restart |
| Generate traffic | 10 min | Sustained load for detection |
| Monitor Dynatrace | 1-2 min | Problem should appear |
| Rollback | 1 min | Service recovers quickly |
| Cleanup | 1 min | Full teardown |
| **Total** | **25-35 min** | End-to-end workflow |
