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
1. Clients and realm roles, via Keycloak's own `partialImport` with
   `ifResourceExists: SKIP`. Using the built-in importer rather than hand-rolled
   client creation means the client definitions have exactly ONE source of truth
   (the chart's realm.json) and we inherit Keycloak's own validation.

2. `realm-management` client-role grants on each client's service-account user.
   Creating a client with `serviceAccountsEnabled` auto-creates its
   `service-account-<clientId>` user but does NOT grant it anything, so step 1
   alone would leave aggregator-api and signals-api unable to administer the
   realm. Driven off the `clientRoles` on the matching `.users[]` entry in
   realm.json, so this too has a single source of truth.

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
    log(
        f"reconciling {len(clients)} clients and {len(realm_roles)} realm roles "
        f"into '{REALM}' (existing resources are skipped, never overwritten)"
    )
    payload = {
        "ifResourceExists": "SKIP",
        "clients": clients,
        "roles": {"realm": realm_roles},
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

    # ── 2. service-account role grants ──────────────────────────────────────
    # Client creation makes the service-account user but grants it nothing.
    wanted = {
        u["username"]: u.get("clientRoles", {})
        for u in realm.get("users", [])
        if u.get("clientRoles")
    }
    if not wanted:
        log("no service-account role grants declared — done")
        return

    status, all_clients = request("GET", f"/admin/realms/{REALM}/clients", token=token)
    if status != 200:
        die(f"cannot list clients (HTTP {status})")
    by_id = {c["clientId"]: c for c in all_clients}

    for username, client_roles in sorted(wanted.items()):
        # realm.json names these `service-account-<clientId>` by convention.
        owner = username.removeprefix("service-account-")
        client = by_id.get(owner)
        if client is None:
            log(f"  {username}: client '{owner}' absent — skipping grants")
            continue

        status, sa = request(
            "GET",
            f"/admin/realms/{REALM}/clients/{client['id']}/service-account-user",
            token=token,
        )
        if status != 200 or "id" not in sa:
            log(f"  {username}: no service-account user (HTTP {status}) — skipping")
            continue

        for source_client, role_names in client_roles.items():
            src = by_id.get(source_client)
            if src is None:
                log(f"  {username}: source client '{source_client}' absent — skipping")
                continue

            status, current = request(
                "GET",
                f"/admin/realms/{REALM}/users/{sa['id']}"
                f"/role-mappings/clients/{src['id']}",
                token=token,
            )
            have = {r["name"] for r in current} if status == 200 else set()
            missing = [r for r in role_names if r not in have]
            if not missing:
                log(f"  {username}: {source_client} roles already granted — skip")
                continue

            status, available = request(
                "GET", f"/admin/realms/{REALM}/clients/{src['id']}/roles", token=token
            )
            if status != 200:
                die(f"cannot list roles of '{source_client}' (HTTP {status})")
            grant = [r for r in available if r["name"] in missing]
            found = {r["name"] for r in grant}
            if set(missing) - found:
                die(
                    f"{source_client} does not define role(s) "
                    f"{sorted(set(missing) - found)} — realm.json and Keycloak disagree"
                )

            status, body = request(
                "POST",
                f"/admin/realms/{REALM}/users/{sa['id']}"
                f"/role-mappings/clients/{src['id']}",
                token=token,
                body=grant,
            )
            if status not in (200, 204):
                die(f"granting {missing} to {username} failed (HTTP {status}): {body}")
            log(f"  {username}: granted {source_client} {sorted(found)}")

    log("realm config reconciled")


if __name__ == "__main__":
    main()
