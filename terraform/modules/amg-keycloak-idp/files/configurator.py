"""Bootstrap Keycloak realm + SAML client for AMG and provision AMP/CloudWatch
data sources in Grafana. Invoked synchronously by aws_lambda_invocation."""

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

import boto3

secrets = boto3.client("secretsmanager")
grafana = boto3.client("grafana")


def _http(method, url, headers=None, body=None, timeout=30):
    data = body
    h = dict(headers or {})
    if isinstance(body, (dict, list)):
        data = json.dumps(body).encode("utf-8")
        h.setdefault("Content-Type", "application/json")
    elif isinstance(body, str):
        data = body.encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        resp = urllib.request.urlopen(req, timeout=timeout)
        return resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()


def _wait_for_keycloak(url, attempts=60, delay=10):
    for _ in range(attempts):
        try:
            status, _, _ = _http("GET", f"{url}/realms/master")
            if status == 200:
                return
        except Exception:  # noqa: BLE001
            pass
        time.sleep(delay)
    raise RuntimeError(f"Keycloak at {url} did not become ready")


def _admin_token(url, password):
    status, _, body = _http(
        "POST",
        f"{url}/realms/master/protocol/openid-connect/token",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        body=urllib.parse.urlencode({
            "client_id": "admin-cli",
            "username": "admin",
            "password": password,
            "grant_type": "password",
        }),
    )
    if status >= 300:
        raise RuntimeError(f"Token request failed: {status} {body!r}")
    return json.loads(body)["access_token"]


def _bootstrap_realm(kc_url, headers, realm, amg_admin_pwd, amg_editor_pwd, workspace_endpoint):
    _http("POST", f"{kc_url}/admin/realms", headers=headers, body={"realm": realm, "enabled": True})

    for g in ("admin", "editor"):
        _http("POST", f"{kc_url}/admin/realms/{realm}/groups", headers=headers,
              body={"name": g, "attributes": {"role": [g]}})

    _, _, gb = _http("GET", f"{kc_url}/admin/realms/{realm}/groups", headers=headers)
    group_ids = {g["name"]: g["id"] for g in json.loads(gb)}

    users = [
        ("admin", "admin@example.com", amg_admin_pwd, "admin"),
        ("editor", "editor@example.com", amg_editor_pwd, "editor"),
    ]
    for username, email, password, group in users:
        status, hdrs, _ = _http("POST", f"{kc_url}/admin/realms/{realm}/users", headers=headers, body={
            "username": username, "email": email, "enabled": True,
            "credentials": [{"type": "password", "value": password, "temporary": False}],
        })
        if status == 201 and group in group_ids:
            uid = hdrs.get("Location").split("/")[-1]
            _http("PUT", f"{kc_url}/admin/realms/{realm}/users/{uid}/groups/{group_ids[group]}", headers=headers)

    _http("POST", f"{kc_url}/admin/realms/{realm}/clients", headers=headers, body={
        "clientId": f"https://{workspace_endpoint}/saml/metadata",
        "name": "Amazon Managed Grafana",
        "protocol": "saml",
        "enabled": True,
        "baseUrl": f"https://{workspace_endpoint}",
        "redirectUris": [f"https://{workspace_endpoint}/saml/acs"],
        "webOrigins": [f"https://{workspace_endpoint}"],
        "attributes": {
            "saml.assertion.signature": "true",
            "saml.server.signature": "true",
            "saml.client.signature": "false",
            "saml.authnstatement": "true",
            "saml.force.post.binding": "true",
            "saml_name_id_format": "username",
            "saml_signature_canonicalization_method": "http://www.w3.org/2001/10/xml-exc-c14n#",
        },
        "protocolMappers": [
            {"name": "role", "protocol": "saml", "protocolMapper": "saml-user-attribute-mapper",
                "config": {"attribute.nameformat": "Basic", "user.attribute": "role",
                    "aggregate.attrs": "false", "attribute.name": "role"}},
            {"name": "email", "protocol": "saml", "protocolMapper": "saml-user-property-mapper",
                "config": {"attribute.nameformat": "Basic", "user.attribute": "email", "attribute.name": "email"}},
            {"name": "name", "protocol": "saml", "protocolMapper": "saml-user-property-mapper",
                "config": {"attribute.nameformat": "Basic", "user.attribute": "username", "attribute.name": "name"}},
        ],
    })


def _wire_amg_saml(workspace_id, kc_public, realm):
    grafana.update_workspace_authentication(
        workspaceId=workspace_id,
        authenticationProviders=["SAML"],
        samlConfiguration={
            "idpMetadata": {"url": f"{kc_public}/realms/{realm}/protocol/saml/descriptor"},
            "assertionAttributes": {"name": "name", "login": "name", "email": "email", "role": "role"},
            "roleValues": {"admin": ["admin"], "editor": ["editor"]},
        },
    )


def _provision_data_sources(workspace_id, workspace_endpoint, amp_query_url, region):
    sa_id = grafana.create_workspace_service_account(
        workspaceId=workspace_id, grafanaRole="ADMIN", name=f"tf-bootstrap-{int(time.time())}"
    )["id"]
    sa_token = grafana.create_workspace_service_account_token(
        workspaceId=workspace_id,
        serviceAccountId=sa_id,
        name="tf-bootstrap-token",
        secondsToLive=900,
    )["serviceAccountToken"]["key"]

    headers = {"Authorization": f"Bearer {sa_token}", "Content-Type": "application/json"}
    base = f"https://{workspace_endpoint}/api"

    data_sources = [
        {"name": "Amazon Managed Prometheus", "type": "prometheus", "access": "proxy",
            "url": amp_query_url, "isDefault": True,
            "jsonData": {"sigV4Auth": True, "sigV4AuthType": "ec2_iam_role",
                "sigV4Region": region, "httpMethod": "POST"}},
        {"name": "CloudWatch", "type": "cloudwatch", "access": "proxy",
            "jsonData": {"authType": "default", "defaultRegion": region}},
        {"name": "CloudWatch Logs", "type": "cloudwatch", "access": "proxy",
            "jsonData": {"authType": "default", "defaultRegion": region, "logsTimeout": "30s"}},
    ]

    results = []
    ds_uids = {}
    for ds in data_sources:
        status, _, body = _http("POST", f"{base}/datasources", headers=headers, body=ds)
        results.append({"name": ds["name"], "status": status})
        if status >= 400 and status != 409:
            print(f"WARN datasource {ds['name']} returned {status}: {body!r}")
            continue
        s2, _, b2 = _http("GET", f"{base}/datasources/name/{urllib.parse.quote(ds['name'])}", headers=headers)
        if s2 == 200:
            ds_uids[ds["name"]] = json.loads(b2).get("uid")

    _import_dashboards(base, headers, ds_uids)

    try:
        grafana.delete_workspace_service_account(workspaceId=workspace_id, serviceAccountId=sa_id)
    except Exception as exc:  # noqa: BLE001
        print(f"cleanup: {exc}")

    return results


_DASHBOARDS = [
    {"id": 15757, "title": "Kubernetes / Compute Resources / Cluster"},
    {"id": 15758, "title": "Kubernetes / Compute Resources / Namespace (Pods)"},
    {"id": 15759, "title": "Kubernetes / Compute Resources / Namespace (Workloads)"},
    {"id": 15760, "title": "Kubernetes / Compute Resources / Node (Pods)"},
    {"id": 15761, "title": "Kubernetes / Compute Resources / Pod"},
    {"id": 15762, "title": "Kubernetes / Compute Resources / Workload"},
    {"id": 13770, "title": "Kubernetes / Views / Pods"},
    {"id": 13332, "title": "Kubernetes / Views / Nodes"},
    {"id": 1860, "title": "Node Exporter Full"},
]


def _import_dashboards(base, headers, ds_uids):
    prom_uid = ds_uids.get("Amazon Managed Prometheus")
    if not prom_uid:
        print("Prometheus DS UID not found - skipping dashboard import")
        return

    folder_uid = _ensure_folder(base, headers, "Kubernetes")

    for d in _DASHBOARDS:
        try:
            with urllib.request.urlopen(
                f"https://grafana.com/api/dashboards/{d['id']}/revisions/latest/download", timeout=30
            ) as resp:
                model = json.loads(resp.read())
        except Exception as exc:  # noqa: BLE001
            print(f"WARN: could not fetch dashboard {d['id']}: {exc}")
            continue

        _rewrite_datasource(model, prom_uid)

        body = {
            "dashboard": {**model, "id": None, "uid": None},
            "overwrite": True,
            "folderUid": folder_uid,
            "message": "Provisioned by terraform module amg-keycloak-idp",
        }
        status, _, b = _http("POST", f"{base}/dashboards/db", headers=headers, body=body)
        print(f"dashboard {d['id']} '{d['title']}' -> {status}")
        if status >= 400:
            print(f"  body: {b!r}")


def _ensure_folder(base, headers, title):
    status, _, body = _http("POST", f"{base}/folders", headers=headers, body={"title": title})
    if status in (200, 201):
        return json.loads(body).get("uid")
    if status in (409, 412):
        s2, _, b2 = _http("GET", f"{base}/folders", headers=headers)
        if s2 == 200:
            for f in json.loads(b2):
                if f.get("title") == title:
                    return f.get("uid")
    return None


def _rewrite_datasource(node, prom_uid):
    if isinstance(node, dict):
        ds = node.get("datasource")
        if isinstance(ds, dict) and ds.get("type") == "prometheus":
            ds["uid"] = prom_uid
        if node.get("type") == "datasource" and node.get("query") == "prometheus":
            node["current"] = {"selected": True, "text": "Amazon Managed Prometheus", "value": prom_uid}
        for v in node.values():
            _rewrite_datasource(v, prom_uid)
    elif isinstance(node, list):
        for v in node:
            _rewrite_datasource(v, prom_uid)


def handler(event, _context):
    print(json.dumps({"event": event}))

    kc_internal = os.environ["KEYCLOAK_INTERNAL_URL"]
    kc_public = os.environ["KEYCLOAK_PUBLIC_URL"]
    realm = os.environ["REALM_NAME"]
    workspace_id = os.environ["AMG_WORKSPACE_ID"]
    workspace_endpoint = os.environ["AMG_WORKSPACE_ENDPOINT"]
    amp_query_url = os.environ["AMP_QUERY_URL"]
    region = os.environ["REGION"]

    secret = json.loads(secrets.get_secret_value(SecretId=os.environ["CONSOLIDATED_SECRET"])["SecretString"])
    admin_pwd = secret["keycloak.master_admin.password"]
    amg_admin_pwd = secret["keycloak.admin.password"]
    amg_editor_pwd = secret["keycloak.editor.password"]

    _wait_for_keycloak(kc_internal)
    token = _admin_token(kc_internal, admin_pwd)
    auth_headers = {"Authorization": f"Bearer {token}"}

    _bootstrap_realm(kc_internal, auth_headers, realm, amg_admin_pwd, amg_editor_pwd, workspace_endpoint)
    _wire_amg_saml(workspace_id, kc_public, realm)
    ds = _provision_data_sources(workspace_id, workspace_endpoint, amp_query_url, region)

    return {"status": "ok", "data_sources": ds}
