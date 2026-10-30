"""
AWS DevOps Agent → Jira Outbound Integration
Lambda function that receives EventBridge events from the DevOps Agent
and creates corresponding Jira issues via REST API.

Event Sources:
  - source: "aws.aidevops"
  - detail-type: "Investigation Completed" | "Investigation Failed"

Jira Configuration:
  - Credentials stored in AWS Secrets Manager
  - Secret name: "devops-agent/jira-credentials"
  - Required keys: email, api_token, base_url
"""

import json
import logging
import os
from datetime import datetime, timezone
from typing import Any
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError
import base64

import boto3
from botocore.exceptions import ClientError

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Environment variables
SECRET_NAME = os.environ.get("JIRA_SECRET_NAME", "devops-agent/jira-credentials")
JIRA_PROJECT_KEY = os.environ.get("JIRA_PROJECT_KEY", "KAN")
# Set the AGENT_SPACE_ID env var to your DevOps Agent Space ID (found in the
# console URL, e.g. #/agent-spaces/<id>). Only affects the "view investigation"
# deep link in the Jira ticket, not ticket creation — safe to leave unset.
AGENT_SPACE_ID = os.environ.get("AGENT_SPACE_ID", "UNSET")

# Priority mapping: DevOps Agent priority → Jira priority name
PRIORITY_MAP = {
    "CRITICAL": "Highest",
    "HIGH": "High",
    "MEDIUM": "Medium",
    "LOW": "Low",
}

# Issue type mapping: detail-type → Jira issue type
ISSUE_TYPE_MAP = {
    "Investigation Completed": "Task",
    "Investigation Failed": "Bug",
}


def get_jira_credentials() -> dict:
    """
    Retrieve Jira credentials from AWS Secrets Manager.
    
    Returns:
        dict with keys: email, api_token, base_url
    
    Raises:
        ClientError: If secret retrieval fails
        KeyError: If required keys are missing from the secret
    """
    client = boto3.client("secretsmanager")
    
    try:
        response = client.get_secret_value(SecretId=SECRET_NAME)
    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        logger.error(f"Failed to retrieve secret '{SECRET_NAME}': {error_code}")
        raise

    secret = json.loads(response["SecretString"])
    
    # Validate required keys
    required_keys = ["email", "api_token", "base_url"]
    missing = [k for k in required_keys if k not in secret]
    if missing:
        raise KeyError(f"Secret is missing required keys: {missing}")
    
    return secret


def build_jira_description(event_detail: dict, detail_type: str) -> dict:
    """
    Build an Atlassian Document Format (ADF) description for the Jira issue.
    
    Args:
        event_detail: The EventBridge event detail payload
        detail_type: The event detail-type (Investigation Completed/Failed)
    
    Returns:
        dict in Atlassian Document Format (ADF) v1
    """
    task_id = event_detail.get("task_id", "unknown")
    priority = event_detail.get("priority", "MEDIUM")
    status = event_detail.get("status", detail_type.split()[-1])
    summary_record_id = event_detail.get("summary_record_id", "N/A")
    timestamp = event_detail.get("timestamp", datetime.now(timezone.utc).isoformat())

    # Build the DevOps Agent investigation deep link. Prefer the agent_space_id
    # carried on the event itself (detail.metadata.agent_space_id) so the link
    # always points at the space that actually ran the investigation; fall back
    # to the AGENT_SPACE_ID env var only when the event omits it.
    agent_space_id = event_detail.get("agent_space_id") or AGENT_SPACE_ID
    agent_url = (
        f"https://{agent_space_id}.aidevops.global.app.aws"
        f"/investigation/{task_id}"
    )
    
    # Atlassian Document Format (ADF) for rich description
    return {
        "version": 1,
        "type": "doc",
        "content": [
            {
                "type": "heading",
                "attrs": {"level": 3},
                "content": [
                    {"type": "text", "text": "Investigation Details"}
                ],
            },
            {
                "type": "table",
                "attrs": {"isNumberColumnEnabled": False, "layout": "default"},
                "content": [
                    _table_row("Task ID", task_id),
                    _table_row("Status", status),
                    _table_row("Priority", f"{priority} → Jira: {PRIORITY_MAP.get(priority, 'Medium')}"),
                    _table_row("Summary Record ID", summary_record_id),
                    _table_row("Timestamp", timestamp),
                    _table_row("Event Type", detail_type),
                ],
            },
            {
                "type": "heading",
                "attrs": {"level": 3},
                "content": [
                    {"type": "text", "text": "Links"}
                ],
            },
            {
                "type": "paragraph",
                "content": [
                    {"type": "text", "text": "🔗 "},
                    {
                        "type": "text",
                        "text": "View Investigation in DevOps Agent",
                        "marks": [
                            {
                                "type": "link",
                                "attrs": {"href": agent_url},
                            }
                        ],
                    },
                ],
            },
            {
                "type": "panel",
                "attrs": {"panelType": "info"},
                "content": [
                    {
                        "type": "paragraph",
                        "content": [
                            {
                                "type": "text",
                                "text": "This issue was automatically created by the AWS DevOps Agent "
                                        "outbound integration via EventBridge → Lambda → Jira.",
                            }
                        ],
                    }
                ],
            },
        ],
    }


def _table_row(label: str, value: str) -> dict:
    """Helper to build an ADF table row with label and value cells."""
    return {
        "type": "tableRow",
        "content": [
            {
                "type": "tableHeader",
                "content": [
                    {
                        "type": "paragraph",
                        "content": [
                            {"type": "text", "text": label, "marks": [{"type": "strong"}]}
                        ],
                    }
                ],
            },
            {
                "type": "tableCell",
                "content": [
                    {
                        "type": "paragraph",
                        "content": [{"type": "text", "text": str(value)}],
                    }
                ],
            },
        ],
    }


def create_jira_issue(credentials: dict, event_detail: dict, detail_type: str) -> dict:
    """
    Create a Jira issue via REST API (POST /rest/api/3/issue).
    
    Args:
        credentials: Jira credentials (email, api_token, base_url)
        event_detail: EventBridge event detail payload
        detail_type: The event detail-type string
    
    Returns:
        dict with Jira API response (id, key, self)
    
    Raises:
        HTTPError: If the Jira API returns an error
        URLError: If the connection fails
    """
    task_id = event_detail.get("task_id", "unknown")
    status = event_detail.get("status", detail_type.split()[-1])
    priority = event_detail.get("priority", "MEDIUM")
    
    # Determine issue type based on event detail-type
    issue_type = ISSUE_TYPE_MAP.get(detail_type, "Task")
    
    # Map priority to Jira priority name
    jira_priority = PRIORITY_MAP.get(priority.upper(), "Medium")
    
    # Build the issue payload
    payload = {
        "fields": {
            "project": {"key": JIRA_PROJECT_KEY},
            "summary": f"[DevOps Agent] {status}: Investigation {task_id}",
            "description": build_jira_description(event_detail, detail_type),
            "issuetype": {"name": issue_type},
            "priority": {"name": jira_priority},
            "labels": ["devops-agent", "automated", f"priority-{priority.lower()}"],
        }
    }
    
    # Prepare the API request
    base_url = credentials["base_url"].rstrip("/")
    url = f"{base_url}/rest/api/3/issue"
    
    # Basic auth: email:api_token → base64
    auth_string = f"{credentials['email']}:{credentials['api_token']}"
    auth_bytes = base64.b64encode(auth_string.encode("utf-8")).decode("utf-8")
    
    headers = {
        "Authorization": f"Basic {auth_bytes}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    
    data = json.dumps(payload).encode("utf-8")
    
    logger.info(f"Creating Jira issue: type={issue_type}, priority={jira_priority}, task_id={task_id}")
    
    req = Request(url, data=data, headers=headers, method="POST")
    
    try:
        with urlopen(req, timeout=30) as response:
            response_body = json.loads(response.read().decode("utf-8"))
            logger.info(f"Jira issue created successfully: {response_body.get('key')}")
            return response_body
    except HTTPError as e:
        error_body = e.read().decode("utf-8") if e.fp else "No response body"
        logger.error(f"Jira API error {e.code}: {error_body}")
        raise
    except URLError as e:
        logger.error(f"Connection error to Jira: {e.reason}")
        raise


def normalize_detail(detail: dict) -> dict:
    """
    Flatten an AWS DevOps Agent event `detail` into the flat shape the rest of
    this handler expects.

    Real DevOps Agent events nest fields:
        detail.metadata.{agent_space_id, task_id, execution_id}
        detail.data.{task_type, priority, status, created_at, updated_at, summary_record_id}

    Older/synthetic events used a flat `detail` (task_id/status/priority/... at
    the top level). This normalizer accepts both: nested values win, falling
    back to any top-level values for backward compatibility.
    """
    metadata = detail.get("metadata") or {}
    data = detail.get("data") or {}

    def pick(key, *fallback_keys):
        # nested (metadata/data) first, then top-level flat, then any extra fallbacks
        for src in (metadata, data, detail):
            if key in src and src[key] not in (None, ""):
                return src[key]
        for fk in fallback_keys:
            if fk in detail and detail[fk] not in (None, ""):
                return detail[fk]
        return None

    return {
        "task_id": pick("task_id"),
        "status": pick("status"),
        "priority": pick("priority"),
        "summary_record_id": pick("summary_record_id"),
        "timestamp": pick("updated_at", "timestamp", "created_at"),
        "agent_space_id": pick("agent_space_id"),
    }


def lambda_handler(event: dict, context: Any) -> dict:
    """
    AWS Lambda entry point.
    
    Receives EventBridge events from source "aws.aidevops" with detail-types:
      - "Investigation Completed"
      - "Investigation Failed"
    
    Creates a corresponding Jira issue in the configured project.
    
    Args:
        event: EventBridge event envelope
        context: Lambda context object
    
    Returns:
        dict with statusCode and body
    """
    logger.info(f"Received event: {json.dumps(event)}")
    
    # Extract event metadata
    detail_type = event.get("detail-type", "Unknown")
    source = event.get("source", "")
    raw_detail = event.get("detail", {})

    # Validate the event source
    if source != "aws.aidevops":
        logger.warning(f"Unexpected event source: {source}. Skipping.")
        return {
            "statusCode": 400,
            "body": json.dumps({"error": f"Unexpected source: {source}"}),
        }

    # Validate the detail-type
    valid_detail_types = ["Investigation Completed", "Investigation Failed"]
    if detail_type not in valid_detail_types:
        logger.warning(f"Unexpected detail-type: {detail_type}. Skipping.")
        return {
            "statusCode": 400,
            "body": json.dumps({"error": f"Unexpected detail-type: {detail_type}"}),
        }

    # Normalize the DevOps Agent event detail (nested metadata/data → flat),
    # accepting both the real nested schema and the legacy flat shape.
    detail = normalize_detail(raw_detail)

    # Validate required fields (task_id is required; status falls back to the
    # detail-type, e.g. "Completed"/"Failed", if the event omits it)
    if not detail.get("task_id"):
        logger.error("Event detail missing required field: task_id (checked metadata/data/top-level)")
        return {
            "statusCode": 400,
            "body": json.dumps({"error": "Missing field: task_id"}),
        }

    try:
        # Retrieve Jira credentials from Secrets Manager
        credentials = get_jira_credentials()

        # Create the Jira issue
        result = create_jira_issue(credentials, detail, detail_type)
        
        logger.info(
            f"Successfully created Jira issue {result.get('key')} "
            f"for investigation {detail.get('task_id')}"
        )
        
        return {
            "statusCode": 201,
            "body": json.dumps({
                "message": "Jira issue created successfully",
                "jira_key": result.get("key"),
                "jira_id": result.get("id"),
                "jira_url": result.get("self"),
                "task_id": detail.get("task_id"),
                "detail_type": detail_type,
            }),
        }
        
    except ClientError as e:
        logger.error(f"AWS Secrets Manager error: {e}")
        return {
            "statusCode": 500,
            "body": json.dumps({"error": "Failed to retrieve Jira credentials"}),
        }
    except HTTPError as e:
        return {
            "statusCode": 502,
            "body": json.dumps({
                "error": "Jira API request failed",
                "status_code": e.code,
            }),
        }
    except URLError as e:
        return {
            "statusCode": 502,
            "body": json.dumps({
                "error": "Failed to connect to Jira",
                "reason": str(e.reason),
            }),
        }
    except Exception as e:
        logger.error(f"Unexpected error: {e}", exc_info=True)
        return {
            "statusCode": 500,
            "body": json.dumps({"error": "Internal error", "message": str(e)}),
        }
