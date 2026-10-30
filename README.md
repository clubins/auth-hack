# auth-hack

Clubins' customer-auth reference implementation: a self-hosted Logto OSS issuer
at `login.clubins.de`, a Go REST API that validates Logto-issued JWTs with
strict RS256/JWKS/issuer/audience/scope checks, and a Flutter client that signs
in through Logto's hosted UI with authorization code + PKCE. Time-limited renter
access (8–24 hours, read-only) is enforced application-side as venue access
grants in the Go API — no paid Logto features. Local development runs the stack
with Docker Compose; prod-shaped NixOS modules (oci-containers, Caddy, SOPS)
mirror that layout.

## Quickstart (local stack)

```bash
cd infra && cp .env.example .env && docker compose up -d --build
curl -fsS http://localhost:3301/oidc/.well-known/openid-configuration  # issuer discovery
curl -fsS http://localhost:8080/healthz                                # Go API
```

Details and issuer wiring: [infra/README.md](infra/README.md).

| Component    | Path        | Check                                                |
| ------------ | ----------- | ---------------------------------------------------- |
| Go API       | `backend/`  | `go test ./...`                                      |
| Flutter app  | `frontend/` | `flutter pub get && flutter analyze && flutter test` |
| Local stack  | `infra/`    | `docker compose up -d --build` (see quickstart above) |
| Prod infra   | `infra/nixos/` | `bash scripts/check-nix.sh` (Nix parse gate — no Nix runner in CI yet) |
| Logto config | `idp/`      | placeholder                                          |
| Spike tools  | `scripts/`  | placeholder                                          |
