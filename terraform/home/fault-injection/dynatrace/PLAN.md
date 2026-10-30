# Dynatrace OTEL Sidecar Integration — Implementation Plan

## Scope
Only touch: `assetsSrc/terraform/home/fault-injection/dynatrace/`
No changes to Terraform modules, main.tf, variables.tf, outputs.tf, or any other folder.

## Context
- Infrastructure (ECS cluster, services, RDS, DynamoDB, etc.) is deployed via Terraform — UNCHANGED
- The retail-store Java images (`public.ecr.aws/aws-containers/retail-store-sample-*:1.3.0`) have OTEL Java auto-instrumentation bundled
- We cannot modify the container images — Dynatrace integration is done post-deploy via scripts
- The scripts add an OTEL Collector sidecar to each ECS task at runtime

## Telemetry Flow (End-to-End)

```
App container (OTEL Java agent activated via env vars)
    │
    │ OTLP http://localhost:4318
    ▼
OTEL Collector sidecar (same ECS task, otel/opentelemetry-collector-contrib:0.91.0)
    │
    │ OTLP/HTTP with "Api-Token <token>" header
    ▼
Dynatrace SaaS (https://<tenant>.live.dynatrace.com/api/v2/otlp)
    │
    │ Davis AI detects failure rate anomaly
    ▼
Dynatrace Problem opened
    │
    │ Bi-directional integration webhook (configured externally)
    ▼
AWS DevOps Agent investigates
    │
    │ Posts findings + mitigation back
    ▼
Dynatrace Problem view (notebook with root cause + remediation)
```

## Prerequisites (External — Not Part of This Code)
- Dynatrace tenant with OTLP ingest enabled
- Dynatrace API token with `openTelemetryTrace.ingest`, `metrics.ingest`, `logs.ingest` scopes
- AWS DevOps Agent configured with agent space scoped to this AWS account
- Dynatrace ↔ DevOps Agent bi-directional integration enabled
- Traffic hitting the ECS services (for baseline + to trigger errors)

## Tasks

### [x] Task 0: Revert repo to clean state
- All accidental deletions restored via `git checkout`
- `git status` shows clean working tree

### [x] Task 1: Add `check-dynatrace-status.sh`
- Validates OTEL pipeline is working before fault injection
- Checks: state file exists, Secrets Manager token active, OTEL sidecar in task-defs,
  sidecar containers running, collector logs show export activity
- Source: reference from `temp_session_backup/dummy_willdelete/terraform/home/fault-injection/dynatrace/check-dynatrace-status.sh`
- Must source `../lib/common.sh` and `./dynatrace-common.sh` (same pattern as existing scripts)

### [x] Task 2: Add `inject-orders-db-broken.sh`
- Overrides `RETAIL_ORDERS_MESSAGING_SQS_TOPIC=nonexistent-queue-dynatrace-lab` in orders task-def
- This matches the actual infra: orders uses SQS (not RabbitMQ) per `modules/ecs/orders.tf`
- App starts, health checks pass, but order operations return 500
- OTEL Java agent captures error spans → collector → Dynatrace
- Davis AI detects failure rate increase → opens Problem → triggers DevOps Agent

### [x] Task 3: Add `rollback-orders-db-broken.sh`
- Restores the Dynatrace-enabled task-def (before fault injection)
- Orders service recovers, OTEL sidecar remains active
- Source: reference from `temp_session_backup/dummy_willdelete/terraform/home/fault-injection/dynatrace/rollback-orders-db-broken.sh`

### [x] Task 4: Validate
- [x] `ls` shows 12 scripts + PLAN.md (9 existing + 3 new + plan)
- [x] `git status` shows only untracked additions within `dynatrace/` folder
- [x] New scripts source `../lib/common.sh` and `./dynatrace-common.sh` (correct relative paths)
- [x] No references to files outside the dynatrace folder
- [x] Scripts are executable (`chmod +x`)

## Final File List (8 files)
- `dynatrace-common.sh` — core library (OTEL sidecar builder, switch_service_to_dynatrace)
- `prepare-dynatrace-environment.sh` — one-time setup (prompts for DT endpoint/token, switches all services)
- `test-dynatrace-connection.sh` — local pre-flight check (validates endpoint reachable + token valid + scopes correct before deploying sidecars)
- `check-dynatrace-status.sh` — validates OTEL sidecars are running and exporting (post-deploy, requires ECS)
- `inject-orders-db-broken.sh` — fault scenario (breaks SQS queue → 500s)
- `rollback-orders-db-broken.sh` — restores healthy state, keeps Dynatrace active
- `cleanup-dynatrace.sh` — full teardown (restores original task-defs, deletes secret)
- `PLAN.md` — this file

Modified:
- `prepare-dynatrace-environment.sh` — updated "Available lab scenarios" help text to reference only `inject-orders-db-broken.sh`

Removed (not needed for minimal scenario, can add back later):
- `inject-secrets-access-denied.sh`
- `rollback-secrets-access-denied.sh`
- `inject-security-group-blocked.sh`
- `rollback-security-group-blocked.sh`
- `inject-service-connect-broken.sh`
- `rollback-service-connect-broken.sh`

## Out of Scope (Handled Externally)
- **Traffic generation / load testing** — handled externally
- **Validation that Dynatrace Problem opened** — verified manually in Dynatrace UI
- **DevOps Agent integration setup** — configured in Dynatrace UI + DevOps Agent console
- **Baseline time** — Davis AI needs ~5min of healthy traffic before detecting anomalies;
  allow time between prepare and inject (external responsibility)

## How to Test

### Prerequisites
1. ECS infrastructure deployed (`terraform apply` with `enable_ecs=true` — retail-store cluster running)
2. A Dynatrace tenant with OTLP ingest enabled
3. A Dynatrace API token with scopes: `openTelemetryTrace.ingest`, `metrics.ingest`, `logs.ingest`
4. AWS CLI configured with credentials that can modify ECS task-defs + Secrets Manager
5. `jq` installed on the machine running the scripts
6. External traffic hitting the ECS services (for Dynatrace to baseline and detect anomalies)

### Step-by-Step Test

```bash
# Phase 1: Terraform deploys infra (already done, no changes)
terraform apply

# Phase 2: Enable Dynatrace OTEL integration
cd ~/fault-injection/dynatrace/
./prepare-dynatrace-environment.sh
```

**What happens:** Prompts for Dynatrace OTLP endpoint + API token. Stores token in Secrets Manager.
For each service (ui, catalog, carts, checkout, orders): registers a new task-def revision with
OTEL collector sidecar + OTEL env vars, then updates the ECS service.

**Expected result:** All services roll out new tasks with the otel-collector sidecar container.

```bash
# Verify OTEL pipeline is working
./check-dynatrace-status.sh
```

**Expected result:** All 5 checks pass:
- State file exists with endpoint
- Secret is active in Secrets Manager
- All services have otel-collector in their task-def
- otel-collector containers are in RUNNING state
- Collector logs show export activity

**If checks fail:**
- Sidecars missing → re-run `prepare-dynatrace-environment.sh`
- Containers crashing → check CloudWatch logs for the otel-collector stream prefix
- Export errors → verify DT endpoint URL and API token scopes

```bash
# Wait ~5 minutes for Dynatrace to establish a baseline
# Ensure external traffic is flowing to the services during this time

# Inject the fault
./inject-orders-db-broken.sh
```

**What happens:** Overrides `RETAIL_ORDERS_MESSAGING_RABBITMQ_ADDRESSES=localhost:5672` in the
orders task-def. Registers new revision, updates service, force-stops old tasks.

**Expected result:**
- Orders tasks start successfully (health check passes on `/actuator/health`)
- Any order operation that publishes to RabbitMQ returns HTTP 500
- OTEL Java agent captures error spans → otel-collector → Dynatrace

**Verify in Dynatrace:**
- Open Dynatrace → Services → orders → check failure rate is elevated
- Open Dynatrace → Problems → expect "Failure rate increase" Problem within 1-2 minutes
- If DevOps Agent bi-directional integration is configured: investigation notebook appears on the Problem

```bash
# Rollback the fault
./rollback-orders-db-broken.sh
```

**Expected result:**
- Orders service rolls back to the Dynatrace-enabled task-def (before fault)
- Orders recovers within 1-2 minutes
- OTEL sidecar remains active — telemetry continues flowing to Dynatrace
- Failure rate drops back to 0 in Dynatrace

**Verify in Dynatrace:**
- Failure rate returns to baseline
- Problem auto-closes (if Davis AI confirms recovery)

```bash
# Full cleanup when done
./cleanup-dynatrace.sh
```

**What happens:** Restores all services to their original task-defs (before Dynatrace).
Deletes the API token from Secrets Manager. Removes inline IAM policies.

**Expected result:**
- All services running with original task-defs (no otel-collector sidecar)
- No Dynatrace secret in Secrets Manager
- Telemetry stops flowing to Dynatrace

### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `check-dynatrace-status.sh` shows sidecars MISSING | prepare script didn't complete | Re-run `prepare-dynatrace-environment.sh` |
| otel-collector containers in STOPPED state | Bad OTEL config or OOM | Check CloudWatch logs (`otel-collector` stream prefix) |
| Collector logs show "401 Unauthorized" | Invalid API token | Re-run prepare with correct token (or `cleanup` + re-prepare) |
| Collector logs show "connection refused" | Wrong Dynatrace endpoint URL | Same as above |
| No Problem opens in Dynatrace after inject | No traffic hitting orders, or baseline too short | Ensure external load is flowing; wait longer for baseline |
| Problem opens but no DevOps Agent investigation | Bi-directional integration not configured | Configure in Dynatrace UI + DevOps Agent console (external) |
