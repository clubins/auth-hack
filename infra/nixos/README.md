# NixOS modules — prod shape

The NixOS side of the Clubins auth stack. Mirrors the Docker Compose dev
layout: Logto OSS (the customer OIDC issuer) and its Postgres in podman
containers, Caddy in front for TLS, SOPS for secrets. These modules are
meant to be imported into a host's NixOS configuration.

| File | Role |
| ---- | ---- |
| `modules/logto.nix` | Logto OSS + Postgres containers (`virtualisation.oci-containers`, podman backend); core service published on 127.0.0.1 only |
| `modules/caddy.nix` | TLS termination: `login.clubins.de` → Logto, `api.clubins.de` → Go API; ACME email as an option |
| `modules/sops.nix` | sops-nix scaffolding: age key path + the `logto-env` dotenv secret |
| `examples/host.nix` | Example host config consuming all three |
| `../../.sops.yaml` | SOPS creation rule (placeholder age recipient — replace before encrypting) |
| `../../scripts/check-nix.sh` | Parse gate for every tracked `.nix` file |

## What runs

- **Logto** (`svhd/logto:1.45.0`, pinned — bump deliberately, migrations are
  one-way): core service on container port 3001, published to
  `127.0.0.1:<port>` (default 3301). `ENDPOINT` sets the public issuer URL
  (must match the Go API's `ISSUER` config); `TRUST_PROXY_HEADER=1` because
  Caddy terminates TLS. Secrets (`DB_URL`, `POSTGRES_PASSWORD`) come from a
  SOPS-decrypted dotenv file, never from inline config.
- **Postgres** (`postgres:16-alpine`): named volume `logto-pgdata` for the
  datastore.
- Both containers sit on a user-defined podman network (`logto` by default)
  so `DB_URL`'s `logto-postgres` hostname resolves by container name.

## Applying to a host (one-time setup)

1. **Import the modules.** Make this repo available to your host flake
   (flake input, `fetchTarball`, or vendored copy) and import sops-nix
   alongside it:

   ```nix
   # flake.nix of the host
   {
     inputs.sops-nix.url = "github:Mic92/sops-nix";

     # inside nixosConfigurations.<host>:
     #   modules = [
     #     inputs.sops-nix.nixosModules.sops
     #     /path/to/auth-hack/infra/nixos
     #   ];
   }
   ```

2. **Provision the age key** on the host; keep the private key at
   `/var/lib/sops-nix/key.txt` (0600, root-owned):

   ```console
   $ nix shell nixpkgs#age -c age-keygen -o /var/lib/sops-nix/key.txt
   Public key: age1...   # ← the recipient for step 3
   ```

3. **Register the recipient**: replace the placeholder in the repo-root
   `.sops.yaml` with the public key from step 2.

4. **Create the secret**:

   ```console
   $ sops infra/secrets/logto-env.enc.env
   ```

   with content:

   ```dotenv
   DB_URL=postgres://logto:<password>@logto-postgres:5432/logto
   POSTGRES_PASSWORD=<password>
   ```

   SOPS files are ciphertext and safe to commit.

5. **Create the podman network** (idempotent; must exist before the
   containers start):

   ```console
   $ podman network create logto
   ```

6. **Point DNS**: `login.clubins.de` and `api.clubins.de` → the host's
   public IPv4/IPv6. Caddy obtains certificates on first start; ports 80
   and 443 must be reachable (open them as in `examples/host.nix`).

7. **Set the host config** — see `examples/host.nix` for the full shape:

   ```nix
   clubins.logto = {
     enable = true;
     endpoint = "https://login.clubins.de";
   };
   clubins.caddy = {
     enable = true;
     acmeEmail = "admin@clubins.de";
   };
   clubins.sops = {
     enable = true;
     logtoEnvFile = ./secrets/logto-env.enc.env;
     # oci-containers names podman services podman-<container>.
     restartUnits = [ "podman-logto.service" ];
   };
   ```

## Operations

- Logs: `journalctl -u podman-logto -f` (service name =
  `<backend>-<container>`).
- First start may briefly restart Logto while Postgres initialises —
  expected; systemd restarts the container on failure.
- Rotate the DB password: edit the secret
  (`sops infra/secrets/logto-env.enc.env`) and redeploy — `restartUnits`
  restarts Logto with the new env.
- Port changes: keep `clubins.logto.port` and `clubins.caddy.logtoPort` in
  sync — the example host shares one `let` binding for exactly this reason.

## Verification

CI has no Nix runner yet. Wherever Nix is available, run:

```console
$ bash scripts/check-nix.sh
```

It parse-checks every tracked `.nix` file (`nix-instantiate --parse`) and
exits nonzero on the first failure. Full-system eval of `examples/host.nix`
additionally needs the encrypted secret from step 4.
