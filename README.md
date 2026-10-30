# auth-hack

Clubins' customer-auth reference implementation: a self-hosted Logto OSS issuer
at `login.clubins.de`, a Go REST API that validates Logto-issued JWTs with
strict RS256/JWKS/issuer/audience/scope checks, and a Flutter client that signs
in through Logto's hosted UI with authorization code + PKCE. Time-limited renter
access (8–24 hours, read-only) is enforced application-side as venue access
grants in the Go API — no paid Logto features. Local development runs the stack
with Docker Compose; prod-shaped NixOS modules (oci-containers, Caddy, SOPS)
mirror that layout.

## Quickstart (placeholder)

The runnable stack is not wired up yet — this seed carries the skeleton, CI,
and docs only. Component tasks land against this base next.

| Component    | Path        | Check                                                |
| ------------ | ----------- | ---------------------------------------------------- |
| Go API       | `backend/`  | `go test ./...`                                      |
| Flutter app  | `frontend/` | `flutter pub get && flutter analyze && flutter test` |
| Logto config | `idp/`      | placeholder                                          |
| Infra        | `infra/`    | placeholder                                          |
| Spike tools  | `scripts/`  | placeholder                                          |
