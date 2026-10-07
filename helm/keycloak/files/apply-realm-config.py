#!/usr/bin/env python3
"""Reconcile an EXISTING realm's clients and roles against the chart's realm JSON.

WHY THIS EXISTS
---------------
`--import-realm` applies ONLY to an empty realm. On every subsequent boot Keycloak
skips the import entirely, so a realm that predates a change to realm.json never
gains what was added — new clients, new realm roles, new service accounts.

That gap used to be closed by renaming the realm aside and re-importing it from
scratch, which changes the issuer URL and therefore forces every user to log in
again. This script closes it in place instead: no rename, no issuer change, no
re-login, no user migration.

WHAT IT RECONCILES
------------------
1. Clients, realm roles and client roles, via Keycloak's own `partialImport`
   with `ifResourceExists: SKIP`. Using the built-in importer rather than
   hand-rolled client creation means the client definitions have exactly ONE
   source of truth (the chart's realm.json) and we inherit Keycloak's own
   validation. Client roles (`roles.client`) are part of the payload so that a
   client added to realm.json arrives together with the roles callers are
   granted on it (e.g. notification-service's notify:send / templates:admin).

2. Client-role grants on each service-account user, for ANY client: the
   `realm-management` admin roles aggregator-api and signals-api need, and
   equally an application client's roles such as notification-service
   notify:send for signals-api. Creating a client with `serviceAccountsEnabled`
   auto-creates its `service-account-<clientId>` user but grants it nothing, and
   a grant on an already-existing service account is never applied by import.
   Driven off each `.users[]` entry that has a `serviceAccountClientId`, reading
   its `clientRoles` map `{<clientId>: [role, ...]}`, so this too has a single
   source of truth. Only missing roles are granted; existing grants are never
   removed. A referenced client or role that does not exist after step 1 is a
   hard failure: realm.json and Keycloak disagree.

WHAT IT DELIBERATELY DOES NOT DO
--------------------------------
- `ifResourceExists: SKIP`, never OVERWRITE. Re-creating an existing client would
  change its service-account user id, and those ids are referenced from the
  aggregator database. Existing clients are left exactly as they are.
- It does not import `.users[]`. The only users in realm.json are service
  accounts, which Keycloak creates itself from the client definitions. Importing
  them as ordinary users would create duplicates that shadow the real ones.
- It does not touch realm-level settings, flows or flow bindings. SMTP and the
  user profile are apply-user-profile.sh's job; the portal entitlement flow is
  apply-portal-gate.py's.

Idempotent: safe on every `helm upgrade`. A fully-reconciled realm is a no-op.

Env:
  KC_URL           base URL incl. relative path, e.g. http://kc:8080/auth
  KC_REALM         realm to reconcile
  KC_ADMIN_USERNAME / KC_ADMIN_PASSWORD   master-realm admin credentials
  RENDERED_REALM   path to the rendered (placeholders substituted) realm JSON

Exits non-zero on any failure — a silently half-reconciled realm is the thing
this replaces.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

KC = os.environ.get("KC_URL", "http://localhost:8080").rstrip("/")
REALM = os.environ["KC_REALM"]
USER = os.environ.get("KC_ADMIN_USERNAME", "admin")
PASS = os.environ["KC_ADMIN_PASSWORD"]
REALM_FILE = os.environ.get("RENDERED_REALM", "/rendered/realm.json")

TAG = "[realm-config]"


def log(msg):
    print(f"{TAG} {msg}", flush=True)


def die(msg):
    print(f"{TAG} ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def request(method, path, token=None, body=None, form=None):
    """One HTTP call. Returns (status, parsed-json-or-raw-text)."""
    url = f"{KC}{path}"
    headers = {}
    data = None
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read().decode() or "{}"
            try:
                return r.status, json.loads(raw)
            except json.JSONDecodeError:
                return r.status, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, raw
    except urllib.error.URLError as e:
        die(f"cannot reach Keycloak at {url}: {e.reason}")


def admin_token():
    status, body = request(
        "POST",
        "/realms/master/protocol/openid-connect/token",
        form={
            "grant_type": "password",
            "client_id": "admin-cli",
            "username": USER,
            "password": PASS,
        },
    )
    if status != 200 or "access_token" not in body:
        die(f"admin login failed (HTTP {status}): {body}")
    return body["access_token"]


def main():
    if not os.path.isfile(REALM_FILE):
        die(f"rendered realm not found at {REALM_FILE}")
    with open(REALM_FILE) as fh:
        try:
            realm = json.load(fh)
        except json.JSONDecodeError as e:
            die(f"{REALM_FILE} is not valid JSON: {e}")

    # A surviving placeholder means the render step did not run or did not
    # complete. Importing it would install a literal "__X__" as a client secret.
    raw = json.dumps(realm)
    if "__" in raw:
        leftovers = sorted(
            {t for t in raw.split('"') if t.startswith("__") and t.endswith("__")}
        )
        if leftovers:
            die(f"unsubstituted placeholder(s) in {REALM_FILE}: {leftovers}")

    token = admin_token()

    status, _ = request("GET", f"/admin/realms/{REALM}", token=token)
    if status == 404:
        die(
            f"realm '{REALM}' does not exist. This script reconciles an EXISTING "
            "realm; a new realm is created by --import-realm on first boot. A 404 "
            "here usually means KEYCLOAK_REALM does not match the deployed realm."
        )
    if status != 200:
        die(f"cannot read realm '{REALM}' (HTTP {status})")

    clients = realm.get("clients", [])
    realm_roles = realm.get("roles", {}).get("realm", [])
    client_roles = realm.get("roles", {}).get("client", {})

    # Drop authenticationFlowBindingOverrides before importing.
    #
    # A binding references a flow by ID. If that flow does not exist in the target
    # realm yet, Keycloak rejects the whole request with an opaque HTTP 500
    # ("unknown_error", detail only in the server log) — confirmed against 26.5.5.
    # That is reachable here: apply-portal-gate.py, which CREATES the portal flow,
    # runs after this script.
    #
    # Dropping it is safe and correct rather than a workaround: the gate binding is
    # apply-portal-gate.py's responsibility and it reconciles that binding on every
    # run, verify-first and fail-closed. So the binding still lands, just from its
    # owner. In practice this only matters for a realm missing aggregator-portal
    # entirely, since existing clients are skipped, not rewritten.
    stripped = [c["clientId"] for c in clients if c.get("authenticationFlowBindingOverrides")]
    if stripped:
        clients = [
            {k: v for k, v in c.items() if k != "authenticationFlowBindingOverrides"}
            for c in clients
        ]
        log(
            f"dropped flow-binding override(s) from {stripped} — "
            "apply-portal-gate.py owns those bindings"
        )

    # ── 1. clients + realm roles ────────────────────────────────────────────
    n_client_roles = sum(len(v) for v in client_roles.values())
    log(
        f"reconciling {len(clients)} clients, {len(realm_roles)} realm roles and "
        f"{n_client_roles} client roles into '{REALM}' "
        "(existing resources are skipped, never overwritten)"
    )
    roles = {"realm": realm_roles}
    if client_roles:
        roles["client"] = client_roles
    payload = {
        "ifResourceExists": "SKIP",
        "clients": clients,
        "roles": roles,
    }
    status, body = request(
        "POST", f"/admin/realms/{REALM}/partialImport", token=token, body=payload
    )
    if status not in (200, 201):
        die(f"partialImport failed (HTTP {status}): {body}")

    added = body.get("added", 0) if isinstance(body, dict) else 0
    skipped = body.get("skipped", 0) if isinstance(body, dict) else 0
    log(f"partialImport: added={added} skipped={skipped}")
    if isinstance(body, dict):
        for r in body.get("results", []):
            if r.get("action") == "ADDED":
                log(f"  added {r.get('resourceType')} {r.get('resourceName')}")

    # ── 2. service-account client-role grants (any client) ──────────────────
    # Client creation makes the service-account user but grants it nothing, and
    # partialImport never touches an existing service account's mappings.
    wanted = [
        (u["serviceAccountClientId"], u["username"], u.get("clientRoles") or {})
        for u in realm.get("users", [])
        if u.get("serviceAccountClientId") and u.get("clientRoles")
    ]
    if not wanted:
        log("no service-account role grants declared — done")
        return

    uuid_cache = {}

    def client_uuid(client_id):
        """Internal id of `client_id`; dies if the client does not exist."""
        if client_id not in uuid_cache:
            status, found = request(
                "GET",
                f"/admin/realms/{REALM}/clients?"
                + urllib.parse.urlencode({"clientId": client_id}),
                token=token,
            )
            if status != 200:
                die(f"cannot look up client '{client_id}' (HTTP {status}): {found}")
            match = [c for c in found if c.get("clientId") == client_id]
            if not match:
                die(
                    f"client '{client_id}' does not exist after import — "
                    "realm.json and Keycloak disagree"
                )
            uuid_cache[client_id] = match[0]["id"]
        return uuid_cache[client_id]

    for owner, username, grants in sorted(wanted, key=lambda w: w[0]):
        status, sa = request(
            "GET",
            f"/admin/realms/{REALM}/clients/{client_uuid(owner)}/service-account-user",
            token=token,
        )
        if status != 200 or not isinstance(sa, dict) or "id" not in sa:
            die(f"{username}: no service-account user on '{owner}' (HTTP {status}): {sa}")

        for target, role_names in sorted(grants.items()):
            target_id = client_uuid(target)
            mapping_path = (
                f"/admin/realms/{REALM}/users/{sa['id']}/role-mappings/clients/{target_id}"
            )
            status, current = request("GET", mapping_path, token=token)
            if status != 200:
                die(f"cannot read {username}'s '{target}' role mappings (HTTP {status}): {current}")
            have = {r["name"] for r in current}
            missing = [r for r in role_names if r not in have]
            if not missing:
                log(f"  {username}: {target} roles already granted — skip")
                continue

            grant = []
            for name in missing:
                status, role = request(
                    "GET",
                    f"/admin/realms/{REALM}/clients/{target_id}/roles/"
                    + urllib.parse.quote(name, safe=""),
                    token=token,
                )
                if status == 404:
                    die(
                        f"client '{target}' does not define role '{name}' — "
                        "realm.json and Keycloak disagree"
                    )
                if status != 200:
                    die(f"cannot read role '{target}/{name}' (HTTP {status}): {role}")
                grant.append(role)

            status, body = request("POST", mapping_path, token=token, body=grant)
            if status not in (200, 204):
                die(f"granting {target} {missing} to {username} failed (HTTP {status}): {body}")
            log(f"  {username}: granted {target} {sorted(missing)}")

    log("realm config reconciled")


if __name__ == "__main__":
    main()
