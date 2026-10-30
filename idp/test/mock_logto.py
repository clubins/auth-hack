#!/usr/bin/env python3
"""Mock of the Logto OSS Management API surface that idp/seed.sh uses.

Implements exactly the endpoints the seed touches, with Logto's response
shapes and status codes (422 on duplicates, 200 for app/user creation,
201 for resource/scope creation, token endpoint on /oidc/token), so the
idempotency harness can prove create-if-absent behavior without Docker.

State is in-memory and per-process. GET /__state is a test-only
introspection endpoint that the seed never calls.
"""

import argparse
import base64
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DEFAULT_PAGE_SIZE = 20


class MockLogto:
    def __init__(self, m2m_id: str, m2m_secret: str):
        self.lock = threading.Lock()
        self.m2m_id = m2m_id
        self.m2m_secret = m2m_secret
        self.tokens: set[str] = set()
        self.resources: list[dict] = [
            {
                "id": "builtin-management-api",
                "name": "Logto Management API",
                "indicator": "https://default.logto.app/api",
            }
        ]
        # A decoy in the default tenant's application list: the seed must
        # match on its own app name, not trip over unrelated registrations.
        self.applications: list[dict] = [
            {
                "id": "decoy-m2m-app",
                "name": "Decoy Service",
                "type": "MachineToMachine",
                "description": None,
                "oidcClientMetadata": {"redirectUris": [], "postLogoutRedirectUris": []},
            }
        ]
        self.users: list[dict] = []
        self.counters = {"resource": 0, "scope": 0, "application": 0, "user": 0}
        self.token_requests = 0

    def next_id(self, kind: str) -> str:
        self.counters[kind] += 1
        return f"{kind}-{self.counters[kind]}"

    def creations(self) -> int:
        return sum(self.counters.values())


class ApiError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


def paginate(items: list, qs: dict) -> list:
    page = int(qs.get("page", ["1"])[0])
    size = int(qs.get("page_size", [str(DEFAULT_PAGE_SIZE)])[0])
    start = (page - 1) * size
    return items[start : start + size]


class Handler(BaseHTTPRequestHandler):
    mock: MockLogto

    # -- plumbing ---------------------------------------------------------

    def log_message(self, fmt, *args):  # keep harness logs quiet
        pass

    def _json(self, status: int, payload) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return {}
        return json.loads(raw)

    def _bearer(self) -> str:
        header = self.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            raise ApiError(401, "authentication required")
        token = header[len("Bearer ") :]
        if token not in self.mock.tokens:
            raise ApiError(401, "invalid or expired token")
        return token

    # -- routes -----------------------------------------------------------

    def do_GET(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        path = parsed.path.rstrip("/") or "/"
        try:
            if path == "/__state":
                with self.mock.lock:
                    self._json(
                        200,
                        {
                            "creations": self.mock.creations(),
                            "token_requests": self.mock.token_requests,
                            "resources": [r["id"] for r in self.mock.resources],
                            "resource_scopes": {
                                r["id"]: len(r.get("scopes", []))
                                for r in self.mock.resources
                            },
                            "applications": [a["id"] for a in self.mock.applications],
                            "users": [u["id"] for u in self.mock.users],
                        },
                    )
                return
            self._bearer()
            if path == "/api/resources":
                with self.mock.lock:
                    self._json(200, paginate(self.mock.resources, qs))
                return
            match = re.fullmatch(r"/api/resources/([^/]+)/scopes", path)
            if match:
                resource = self._resource(match.group(1))
                with self.mock.lock:
                    self._json(200, paginate(resource.get("scopes", []), qs))
                return
            if path == "/api/applications":
                types = qs.get("types", [""])[0]
                wanted = {t for t in types.split(",") if t}
                with self.mock.lock:
                    apps = [
                        a
                        for a in self.mock.applications
                        if not wanted or a["type"] in wanted
                    ]
                    self._json(200, paginate(apps, qs))
                return
            match = re.fullmatch(r"/api/users/([^/]+)", path)
            if match:
                with self.mock.lock:
                    user = next(
                        (u for u in self.mock.users if u["id"] == match.group(1)),
                        None,
                    )
                if user is None:
                    raise ApiError(404, "user not found")
                self._json(200, user)
                return
            raise ApiError(404, f"no mock route for GET {path}")
        except ApiError as err:
            self._json(err.status, {"message": err.message})

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        try:
            if path == "/oidc/token":
                self._token()
                return
            self._bearer()
            if path == "/api/resources":
                self._create_resource()
                return
            match = re.fullmatch(r"/api/resources/([^/]+)/scopes", path)
            if match:
                self._create_scope(match.group(1))
                return
            if path == "/api/applications":
                self._create_application()
                return
            if path == "/api/users":
                self._create_user()
                return
            raise ApiError(404, f"no mock route for POST {path}")
        except ApiError as err:
            self._json(err.status, {"message": err.message})

    # -- handlers ---------------------------------------------------------

    def _token(self):
        self.mock.token_requests += 1
        auth = self.headers.get("Authorization", "")
        expected = base64.b64encode(
            f"{self.mock.m2m_id}:{self.mock.m2m_secret}".encode()
        ).decode()
        form = parse_qs(
            self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode()
        )
        if auth != f"Basic {expected}":
            raise ApiError(401, "invalid_client")
        if form.get("grant_type", [""])[0] != "client_credentials":
            raise ApiError(400, "unsupported_grant_type")
        if not form.get("resource", [""])[0]:
            raise ApiError(400, "missing resource indicator")
        token = f"mock-mgmt-token-{self.mock.token_requests}"
        self.mock.tokens.add(token)
        self._json(
            200,
            {
                "access_token": token,
                "expires_in": 3600,
                "token_type": "Bearer",
                "scope": "all",
            },
        )

    def _resource(self, resource_id: str) -> dict:
        resource = next(
            (r for r in self.mock.resources if r["id"] == resource_id), None
        )
        if resource is None:
            raise ApiError(404, "resource not found")
        return resource

    def _create_resource(self):
        payload = self._read_json()
        if not payload.get("name") or not payload.get("indicator"):
            raise ApiError(422, "name and indicator are required")
        if any(r["indicator"] == payload["indicator"] for r in self.mock.resources):
            raise ApiError(422, "resource indicator already exists")
        resource = {"id": self.mock.next_id("resource"), **payload, "scopes": []}
        self.mock.resources.append(resource)
        self._json(201, resource)

    def _create_scope(self, resource_id: str):
        resource = self._resource(resource_id)
        payload = self._read_json()
        if not payload.get("name"):
            raise ApiError(422, "scope name is required")
        scopes = resource.setdefault("scopes", [])
        if any(s["name"] == payload["name"] for s in scopes):
            raise ApiError(422, "scope name already exists for this resource")
        scope = {"id": self.mock.next_id("scope"), **payload}
        scopes.append(scope)
        self._json(201, scope)

    def _create_application(self):
        payload = self._read_json()
        metadata = payload.get("oidcClientMetadata") or {}
        if not payload.get("name") or not payload.get("type"):
            raise ApiError(422, "name and type are required")
        if not metadata.get("redirectUris"):
            raise ApiError(422, "redirectUris are required")
        app = {
            "id": self.mock.next_id("application"),
            "description": None,
            **payload,
            "oidcClientMetadata": {
                "redirectUris": metadata.get("redirectUris", []),
                "postLogoutRedirectUris": metadata.get("postLogoutRedirectUris", []),
            },
        }
        self.mock.applications.append(app)
        self._json(200, app)  # Logto returns 200 for application creation

    def _create_user(self):
        payload = self._read_json()
        if any(u["id"] == payload.get("id") for u in self.mock.users):
            raise ApiError(422, "user id already exists")
        email = payload.get("primaryEmail")
        if email and any(u.get("primaryEmail") == email for u in self.mock.users):
            raise ApiError(422, "primary email already exists")
        user = {
            "id": self.mock.next_id("user"),
            "username": None,
            "primaryEmail": None,
            "primaryPhone": None,
            "name": None,
            **payload,
        }
        self.mock.users.append(user)
        self._json(200, user)  # Logto returns 200 for user creation


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--m2m-id", required=True)
    parser.add_argument("--m2m-secret", required=True)
    args = parser.parse_args()

    Handler.mock = MockLogto(args.m2m_id, args.m2m_secret)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"mock logto listening on 127.0.0.1:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
