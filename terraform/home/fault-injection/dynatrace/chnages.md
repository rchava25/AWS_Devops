# Dynatrace Integration Fixes

## Problem
- Dynatrace showed 0% failure rate despite 500 errors being generated
- Catalog stopped sending data after initial burst

## Root Causes Found

1. **Metrics rejected by Dynatrace** — `http.server.request.duration` sent as cumulative histogram, but Dynatrace only accepts delta temporality. This metric is what Dynatrace uses to calculate failure rate.

2. **No Java Agent** — The container images don't bundle the OTEL Java Agent. Without it, the Spring Boot OTEL Starter produces basic metrics but no proper HTTP trace spans with status code attributes. `JAVA_TOOL_OPTIONS` was empty.

3. **Fault injection didn't work** — `inject-orders-db-broken.sh` set `RETAIL_ORDERS_MESSAGING_SQS_TOPIC` but the app uses `RETAIL_ORDERS_MESSAGING_PROVIDER=rabbitmq`, so the env var was ignored and orders kept working fine.

## Changes Made

### dynatrace-common.sh

- **Added `cumulativetodelta` processor** to OTEL collector config. Converts cumulative histograms/sums to delta temporality before export. Applied only to the metrics pipeline.
- **Added `otel-agent-init` container** — a busybox init container that downloads `opentelemetry-javaagent.jar` (v2.11.0) into a shared volume (`otel-agent`).
- **Added `JAVA_TOOL_OPTIONS=-javaagent:/opt/otel-agent/opentelemetry-javaagent.jar`** to the OTEL env vars injected into app containers.
- **Added `dependsOn` and `mountPoints`** so app containers wait for the agent download and mount the shared volume.

### inject-orders-db-broken.sh

- Changed fault from setting `RETAIL_ORDERS_MESSAGING_SQS_TOPIC` (no effect) to overriding `SPRING_RABBITMQ_HOST=nonexistent-mq-host.invalid`. This causes actual RabbitMQ connection failures when orders tries to publish messages, resulting in HTTP 500s visible in Dynatrace.

## Testing Performed (2026-05-16)

### Test Setup

**Dynatrace Configuration:**
- Tenant: `https://rbn31660.live.dynatrace.com`
- OTLP Endpoint: `https://rbn31660.live.dynatrace.com/api/v2/otlp`
- API Token: Stored in AWS Secrets Manager as `devops-agent-workshop-dynatrace-token-1778889043`

**Deployment Steps:**
1. Ran `cleanup-dynatrace.sh` — No previous state found (clean start)
2. Ran `prepare-dynatrace-environment.sh` — Successfully deployed OTEL sidecars to all 5 services:
   - ui (task-definition revision 3)
   - catalog (task-definition revision 5)
   - carts (task-definition revision 3)
   - checkout (task-definition revision 3)
   - orders (task-definition revision 4)
3. Waited ~3 minutes for services to stabilize and Java agents to download
4. Ran `inject-orders-db-broken.sh` — Injected RabbitMQ fault into orders service (task-definition revision 5)

### Traffic Generation

**Why traffic generation was needed:**
- Dynatrace Davis AI requires actual traffic to establish a baseline and detect anomalies
- Without traffic, no HTTP requests = no failure rate data = no problem detection
- Need sustained traffic (not just a few requests) for Davis AI to recognize a pattern

**Load Test Scripts Created:**

1. **`load-test-script.sh`** (Primary test script)
   - **Purpose:** Generate realistic user traffic through the UI that triggers the orders service failure
   - **Method:** Simulates user browsing → adding to cart → checkout flow
   - **Target:** `http://devops-agent-workshop-ecs-ui-276882089.us-east-1.elb.amazonaws.com/checkout`
   - **Duration:** 10 minutes (600 seconds)
   - **Request pattern:**
     - Browse home page
     - Browse catalog
     - View product details
     - Add items to cart
     - POST to `/checkout` (triggers orders service call → RabbitMQ failure → 500 error)
   - **Frequency:** ~6 requests/second (1 second delay between iterations)
   - **Why this approach:** Checkout service internally calls orders service via Service Connect, which then fails when trying to connect to RabbitMQ. This creates a realistic failure scenario that propagates through the service mesh.

2. **`load-test-orders-direct.sh`** (Alternative approach)
   - **Purpose:** Directly target orders service via ECS exec and Service Connect
   - **Method:** Exec into UI container, hit `http://orders/orders` endpoint directly
   - **Why created:** Provides option to isolate failures to orders service only (not UI/checkout)
   - **Limitation:** Requires ECS exec to be enabled, more complex setup

### Test Results

**Observed Behavior:**
- Checkout endpoint consistently returns HTTP 500 errors
- Error response: `{"timestamp":"...","path":"/checkout","status":500,"error":"Internal Server Error",...}`
- Errors are caused by orders service failing to connect to RabbitMQ at `nonexistent-mq-host.invalid`

**Dynatrace Observations:**
- Failure rate visible in UI service (checkout endpoint)
- OTEL Java agent capturing error spans with status codes
- Telemetry flowing to Dynatrace OTLP endpoint
- Davis AI should detect "Failure rate increase" problem within 1-2 minutes of sustained traffic

**Why UI service shows failures:**
- The `/checkout` endpoint is hosted by the UI service
- UI/checkout calls orders service internally via Service Connect
- Orders service fails due to broken RabbitMQ connection
- Error propagates back to UI/checkout, which returns 500 to the client
- Both services should show failures in Dynatrace:
  - **UI service:** High failure rate on `/checkout` endpoint
  - **Orders service:** RabbitMQ connection errors in traces

### Key Learnings

1. **Traffic is essential** — Dynatrace needs sustained traffic to detect anomalies. A few manual requests aren't enough.

2. **Service mesh propagation** — Failures in downstream services (orders) propagate to upstream services (UI/checkout). Both services will show elevated failure rates in Dynatrace.

3. **OTEL Java agent is critical** — Without the Java agent, Spring Boot OTEL Starter only produces basic metrics. The agent provides:
   - Detailed HTTP trace spans
   - Status code attributes
   - Error context and stack traces
   - Proper service-to-service correlation

4. **Delta vs cumulative temporality matters** — Dynatrace rejects cumulative histograms. The `cumulativetodelta` processor is required for metrics to be accepted.

5. **Realistic fault injection** — The fault must actually break something the app uses. Setting unused environment variables has no effect.

### Next Steps

- Monitor Dynatrace for problem detection (1-2 minutes after traffic starts)
- Check for DevOps Agent investigation notebook (if bi-directional integration is configured)
- Run `rollback-orders-db-broken.sh` to restore service
- Run `cleanup-dynatrace.sh` when testing is complete
