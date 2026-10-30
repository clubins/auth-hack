#!/usr/bin/env python3
"""Stub of the Logto OSS v1.45.0 surface that scripts/spike.sh exercises.

Docker-free counterpart to a live compose stack: serves the discovery
document, JWKS, the /oidc/token endpoint (client_credentials with Basic
auth, and authorization_code with a real S256 PKCE check), the authorize
endpoint, and the /api/experience routes (init, password verification,
identification, submit) with interaction-session cookies.

The tokens it mints are REAL RS256 JWTs: the stub generates an RSA-2048
keypair at boot (pure-stdlib crypto, see the rs256 section below), signs
every token with it, and serves the public half via the JWKS endpoint —
so the Go API's verifier (backend/internal/auth) accepts these tokens for
real. What stays stubbed is everything AROUND the crypto: response shapes
are simplified, state is in-memory and per-process, and nothing here is
Logto. Logto response shapes follow the v1.45.0 source
(packages/core/src/routes/experience).

State is in-memory and per-process. --port 0 binds a free port and the
first stdout line reports the base URL ("listening http://127.0.0.1:PORT").
"""

import argparse
import base64
import hashlib
import hmac
import json
import math
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

INTERACTION_COOKIE = "stub_interaction"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def b64url_json(payload: dict) -> str:
    return b64url(json.dumps(payload).encode())


# -- RS256 in pure stdlib ----------------------------------------------------
#
# The backend verifies signatures for real (backend/internal/auth: RS256
# against the JWKS), so the stub signs with a genuine RSA-2048 key generated
# at boot: Miller-Rabin prime search, PKCS#1 v1.5 padding per RFC 8017 §9.2
# with the SHA-256 DigestInfo. No third-party dependencies — the stub must
# run anywhere python3 runs.

# DER prefix that wraps a SHA-256 digest inside a PKCS#1 v1.5 signature.
_SHA256_DIGEST_INFO = bytes.fromhex("3031300d060960864801650304020105000420")


def _sieve_primes(limit: int) -> list[int]:
    flags = [True] * (limit + 1)
    flags[0] = flags[1] = False
    for i in range(2, int(limit**0.5) + 1):
        if flags[i]:
            for j in range(i * i, limit + 1, i):
                flags[j] = False
    return [i for i, is_prime in enumerate(flags) if is_prime]


# Trial division by these rejects most composites before Miller-Rabin runs.
_SMALL_PRIMES = _sieve_primes(1000)


def _is_probable_prime(n: int, rounds: int = 40) -> bool:
    if n < 2:
        return False
    for p in _SMALL_PRIMES:
        if n == p:
            return True
        if n % p == 0:
            return False
    d = n - 1
    r = 0
    while d % 2 == 0:
        d //= 2
        r += 1
    for _ in range(rounds):
        a = secrets.randbelow(n - 3) + 2  # random base in [2, n-2]
        x = pow(a, d, n)
        if x in (1, n - 1):
            continue
        for _ in range(r - 1):
            x = (x * x) % n
            if x == n - 1:
                break
        else:
            return False
    return True


def _gen_prime(bits: int) -> int:
    while True:
        # Top bit set makes it exactly `bits` wide; the |= 1 keeps it odd.
        candidate = secrets.randbits(bits) | (1 << (bits - 1)) | 1
        if _is_probable_prime(candidate):
            return candidate


def _gen_rsa_key(bits: int = 2048) -> tuple[int, int, int]:
    """Returns (n, e, d) for an RS256-capable RSA key."""
    e = 65537
    while True:
        p = _gen_prime(bits // 2)
        q = _gen_prime(bits // 2)
        if p == q:
            continue
        n = p * q
        lam = (p - 1) * (q - 1) // math.gcd(p - 1, q - 1)
        if math.gcd(e, lam) == 1:
            return n, e, pow(e, -1, lam)


def rs256_sign(signing_input: bytes, n: int, d: int) -> bytes:
    """Signs per JWS RS256: PKCS#1 v1.5 with the SHA-256 DigestInfo."""
    k = (n.bit_length() + 7) // 8
    digest_info = _SHA256_DIGEST_INFO + hashlib.sha256(signing_input).digest()
    padded = b"\x00\x01" + b"\xff" * (k - len(digest_info) - 3) + b"\x00" + digest_info
    m = int.from_bytes(padded, "big")
    return pow(m, d, n).to_bytes(k, "big")


class StubLogto:
    def __init__(self, m2m_id: str, m2m_secret: str, test_email: str, test_password: str):
        self.lock = threading.Lock()
        self.m2m_id = m2m_id
        self.m2m_secret = m2m_secret
        self.test_email = test_email
        self.test_password = test_password
        self.base = ""
        self.kid = "stub-1"
        # One real RSA-2048 key per process; every token is signed with it.
        self.rsa_n, self.rsa_e, self.rsa_d = _gen_rsa_key()
        self.interactions: dict[str, dict] = {}  # uid -> {redirect_uri, code_challenge, resource, scope, state}
        self.codes: dict[str, str] = {}  # code -> uid
        self.experience_ready: set[str] = set()  # uids through PUT /api/experience
        self.verifications: dict[str, str] = {}  # verificationId -> uid

    def jwks(self) -> dict:
        """The public half of the signing key, in JWK form."""
        n_bytes = self.rsa_n.to_bytes((self.rsa_n.bit_length() + 7) // 8, "big")
        e_bytes = self.rsa_e.to_bytes((self.rsa_e.bit_length() + 7) // 8, "big")
        return {
            "keys": [
                {
                    "kty": "RSA",
                    "use": "sig",
                    "alg": "RS256",
                    "kid": self.kid,
                    "n": b64url(n_bytes),
                    "e": b64url(e_bytes),
                }
            ]
        }

    # -- token minting ------------------------------------------------------

    def mint_token(self, aud: str, scope: str, sub: str) -> str:
        now = int(time.time())
        header = {"alg": "RS256", "kid": self.kid, "typ": "JWT"}
        payload = {
            "iss": f"{self.base}/oidc",
            "aud": aud,
            "sub": sub,
            "iat": now,
            "exp": now + 3600,
            "scope": scope,
        }
        signing_input = f"{b64url_json(header)}.{b64url_json(payload)}".encode()
        signature = b64url(rs256_sign(signing_input, self.rsa_n, self.rsa_d))
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
                self._json(200, self.stub.jwks())
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
        # RFC 7617 Basic auth, padding-tolerant: curl -u sends standard
        # base64 WITH padding; the old literal-comparison silently rejected
        # any credentials whose base64 needed it.
        auth = self.headers.get("Authorization", "")
        candidate = auth[len("Basic "):] if auth.startswith("Basic ") else ""
        try:
            decoded = base64.b64decode(candidate + "=" * (-len(candidate) % 4), validate=True).decode()
        except (ValueError, UnicodeDecodeError):
            raise ApiError(401, "invalid_client") from None
        expected = f"{self.stub.m2m_id}:{self.stub.m2m_secret}"
        if not hmac.compare_digest(decoded, expected):
            raise ApiError(401, "invalid_client")
        resource = form.get("resource", [""])[0]
        if not resource:
            raise ApiError(400, "missing resource indicator")
        # Simplification vs. Logto: a real Logto M2M token scopes itself by
        # the application's assigned role, not by an echoed request param.
        # The stub lets the caller ask for exactly the scope it wants so one
        # stub process can play both the venues-scoped user and the owner.
        scope = form.get("scope", ["all"])[0]
        self._json(
            200,
            {
                "access_token": self.stub.mint_token(resource, scope, self.stub.m2m_id),
                "expires_in": 3600,
                "token_type": "Bearer",
                "scope": scope,
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
