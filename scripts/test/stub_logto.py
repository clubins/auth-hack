#!/usr/bin/env python3
"""Stub of the Logto OSS v1.45.0 surface that scripts/spike.sh exercises.

Docker-free counterpart to a live compose stack: serves the discovery
document, JWKS, the /oidc/token endpoint (client_credentials with Basic
auth, and authorization_code with a real S256 PKCE check), the authorize
endpoint, and the /api/experience routes (init, password verification,
identification, submit) with interaction-session cookies.

The tokens it mints are structurally real three-part base64url JWTs whose
signature is a fake blob — nothing here is verifiable cryptography, by
design: the stub tests script logic, not protocol fidelity. Logto response
shapes follow the v1.45.0 source (packages/core/src/routes/experience).

State is in-memory and per-process. --port 0 binds a free port and the
first stdout line reports the base URL ("listening http://127.0.0.1:PORT").
"""

import argparse
import base64
import hashlib
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

INTERACTION_COOKIE = "stub_interaction"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def b64url_json(payload: dict) -> str:
    return b64url(json.dumps(payload).encode())


class StubLogto:
    def __init__(self, m2m_id: str, m2m_secret: str, test_email: str, test_password: str):
        self.lock = threading.Lock()
        self.m2m_id = m2m_id
        self.m2m_secret = m2m_secret
        self.test_email = test_email
        self.test_password = test_password
        self.base = ""
        self.interactions: dict[str, dict] = {}  # uid -> {redirect_uri, code_challenge, resource, scope, state}
        self.codes: dict[str, str] = {}  # code -> uid
        self.experience_ready: set[str] = set()  # uids through PUT /api/experience
        self.verifications: dict[str, str] = {}  # verificationId -> uid

    # -- token minting ------------------------------------------------------

    def mint_token(self, aud: str, scope: str, sub: str) -> str:
        now = int(time.time())
        header = {"alg": "RS256", "kid": "stub-1", "typ": "JWT"}
        payload = {
            "iss": f"{self.base}/oidc",
            "aud": aud,
            "sub": sub,
            "iat": now,
            "exp": now + 3600,
            "scope": scope,
        }
        signature = b64url(b"stub-signature-not-verified")
        return f"{b64url_json(header)}.{b64url_json(payload)}.{signature}"


class ApiError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


class Handler(BaseHTTPRequestHandler):
    stub: StubLogto

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

    def _redirect(self, location: str, cookie: str | None = None) -> None:
        self.send_response(302)
        self.send_header("Location", location)
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0"))
        return self.rfile.read(length) if length else b""

    def _read_json(self) -> dict:
        raw = self._read_body()
        if not raw:
            return {}
        return json.loads(raw)

    def _cookie_uid(self) -> str:
        cookies = dict(
            part.strip().split("=", 1)
            for part in self.headers.get("Cookie", "").split(";")
            if "=" in part
        )
        uid = cookies.get(INTERACTION_COOKIE, "")
        if not uid:
            raise ApiError(400, f"missing {INTERACTION_COOKIE} cookie — start with the authorize request")
        return uid

    # -- routes -----------------------------------------------------------

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        try:
            if path == "/oidc/auth":
                self._authorize(parsed)
                return
            if path == "/oidc/.well-known/openid-configuration":
                self._json(
                    200,
                    {
                        "issuer": f"{self.stub.base}/oidc",
                        "jwks_uri": f"{self.stub.base}/oidc/jwks",
                        "token_endpoint": f"{self.stub.base}/oidc/token",
                        "authorization_endpoint": f"{self.stub.base}/oidc/auth",
                    },
                )
                return
            if path == "/oidc/jwks":
                self._json(
                    200,
                    {
                        "keys": [
                            {
                                "kty": "RSA",
                                "use": "sig",
                                "alg": "RS256",
                                "kid": "stub-1",
                                "n": b64url(b"stub-modulus-not-a-real-key"),
                                "e": "AQAB",
                            }
                        ]
                    },
                )
                return
            # Resume endpoint (redirectTo target): hand back the code.
            if path.startswith("/oidc/auth/"):
                self._resume(path.rsplit("/", 1)[-1], parsed)
                return
            raise ApiError(404, f"no stub route for GET {path}")
        except ApiError as err:
            self._json(err.status, {"message": err.message})

    def do_PUT(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        try:
            if path == "/api/experience":
                self._experience_init()
                return
            raise ApiError(404, f"no stub route for PUT {path}")
        except ApiError as err:
            self._json(err.status, {"message": err.message})

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        try:
            if path == "/oidc/token":
                self._token()
                return
            if path == "/api/experience/verification/password":
                self._experience_password()
                return
            if path == "/api/experience/identification":
                self._experience_identification()
                return
            if path == "/api/experience/submit":
                self._experience_submit()
                return
            raise ApiError(404, f"no stub route for POST {path}")
        except ApiError as err:
            self._json(err.status, {"message": err.message})

    # -- handlers ---------------------------------------------------------

    def _authorize(self, parsed) -> None:
        """GET /oidc/auth — validate params, register the interaction, and
        redirect to the sign-in UI with an interaction cookie."""
        qs = parse_qs(parsed.query)
        stub = self.stub
        required = ("response_type", "client_id", "redirect_uri", "code_challenge", "state")
        missing = [name for name in required if not qs.get(name, [""])[0]]
        if missing:
            raise ApiError(400, f"authorize missing params: {', '.join(missing)}")
        if qs["response_type"][0] != "code":
            raise ApiError(400, "response_type must be code")
        if qs.get("code_challenge_method", [""])[0] != "S256":
            raise ApiError(400, "code_challenge_method must be S256")
        uid = b64url(f"uid-{qs['state'][0]}".encode())
        with stub.lock:
            stub.interactions[uid] = {
                "redirect_uri": qs["redirect_uri"][0],
                "code_challenge": qs["code_challenge"][0],
                "resource": qs.get("resource", [""])[0],
                "scope": qs.get("scope", ["openid"])[0],
                "state": qs["state"][0],
            }
            stub.experience_ready.discard(uid)
        self._redirect(
            f"{stub.base}/sign-in?uid={uid}",
            cookie=f"{INTERACTION_COOKIE}={uid}; Path=/",
        )

    def _experience_init(self):
        self._cookie_uid()
        body = self._read_json()
        if body.get("interactionEvent") != "SignIn":
            raise ApiError(400, "interactionEvent must be SignIn")
        self._json(204, None)

    def _experience_password(self):
        uid = self._cookie_uid()
        body = self._read_json()
        identifier = body.get("identifier") or {}
        if identifier.get("type") != "email" or identifier.get("value") != self.stub.test_email:
            raise ApiError(422, "identifier not found")
        if body.get("password") != self.stub.test_password:
            raise ApiError(422, "incorrect credentials")
        with self.stub.lock:
            verification_id = f"{uid}:stub-verification"
            self.stub.verifications[verification_id] = uid
        self._json(200, {"verificationId": verification_id})

    def _experience_identification(self):
        uid = self._cookie_uid()
        body = self._read_json()
        verification_id = body.get("verificationId", "")
        with self.stub.lock:
            if self.stub.verifications.get(verification_id) != uid:
                raise ApiError(422, "verification record not found")
            self.stub.experience_ready.add(uid)
        self._json(204, None)

    def _experience_submit(self):
        uid = self._cookie_uid()
        with self.stub.lock:
            if uid not in self.stub.interactions:
                raise ApiError(404, "interaction not found")
            if uid not in self.stub.experience_ready:
                raise ApiError(400, "user not identified — run identification first")
            code = b64url(f"{uid}-code".encode())
            self.stub.codes[code] = uid
        self._json(200, {"redirectTo": f"{self.stub.base}/oidc/auth/{uid}"})

    def _resume(self, uid: str, parsed):
        qs = parse_qs(parsed.query)
        with self.stub.lock:
            interaction = self.stub.interactions.get(uid)
            code = next((c for c, u in self.stub.codes.items() if u == uid), None)
        if interaction is None or code is None:
            raise ApiError(404, "no pending interaction for this resume url")
        separator = "&" if urlparse(interaction["redirect_uri"]).query else "?"
        location = (
            f"{interaction['redirect_uri']}{separator}"
            f"code={code}&state={interaction['state']}&iss={self.stub.base}/oidc"
        )
        self._redirect(location)

    def _token(self):
        form = parse_qs(self._read_body().decode())
        grant_type = form.get("grant_type", [""])[0]
        if grant_type == "client_credentials":
            self._token_client_credentials(form)
            return
        if grant_type == "authorization_code":
            self._token_authorization_code(form)
            return
        raise ApiError(400, "unsupported_grant_type")

    def _token_client_credentials(self, form):
        auth = self.headers.get("Authorization", "")
        expected = f"Basic {b64url(f'{self.stub.m2m_id}:{self.stub.m2m_secret}'.encode())}"
        if auth != expected:
            raise ApiError(401, "invalid_client")
        resource = form.get("resource", [""])[0]
        if not resource:
            raise ApiError(400, "missing resource indicator")
        self._json(
            200,
            {
                "access_token": self.stub.mint_token(resource, "all", self.stub.m2m_id),
                "expires_in": 3600,
                "token_type": "Bearer",
                "scope": "all",
            },
        )

    def _token_authorization_code(self, form):
        client_id = form.get("client_id", [""])[0]
        code = form.get("code", [""])[0]
        verifier = form.get("code_verifier", [""])[0]
        redirect_uri = form.get("redirect_uri", [""])[0]
        with self.stub.lock:
            uid = self.stub.codes.pop(code, None)
        if uid is None:
            raise ApiError(400, "invalid_grant: unknown or consumed code")
        with self.stub.lock:
            interaction = self.stub.interactions.get(uid)
        if interaction is None:
            raise ApiError(400, "invalid_grant: interaction gone")
        if client_id != "spike-stub-native":
            raise ApiError(400, "invalid_grant: client mismatch")
        if redirect_uri != interaction["redirect_uri"]:
            raise ApiError(400, "invalid_grant: redirect_uri mismatch")
        challenge = hashlib.sha256(verifier.encode()).digest()
        if b64url(challenge) != interaction["code_challenge"]:
            raise ApiError(400, "invalid_grant: PKCE verification failed")
        self._json(
            200,
            {
                "access_token": self.stub.mint_token(
                    interaction["resource"], interaction["scope"], "stub-user"
                ),
                "id_token": self.stub.mint_token(client_id, "", "stub-user"),
                "expires_in": 3600,
                "token_type": "Bearer",
                "scope": interaction["scope"],
            },
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, required=True)  # 0 = pick a free port
    parser.add_argument("--m2m-id", required=True)
    parser.add_argument("--m2m-secret", required=True)
    parser.add_argument("--test-email", required=True)
    parser.add_argument("--test-password", required=True)
    args = parser.parse_args()

    Handler.stub = StubLogto(args.m2m_id, args.m2m_secret, args.test_email, args.test_password)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    port = server.server_address[1]
    Handler.stub.base = f"http://127.0.0.1:{port}"

    print(f"listening {Handler.stub.base}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
