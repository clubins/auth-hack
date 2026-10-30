# Logto OSS — the Clubins customer OIDC issuer — as podman containers.
#
# Two containers on a shared podman network:
#   logto           Logto core (OIDC provider), published on 127.0.0.1 only
#   logto-postgres  PostgreSQL 16 for Logto's datastore
#
# Secrets (DB_URL with its password, POSTGRES_PASSWORD) never appear in this
# file: both containers read them from a single SOPS-managed dotenv file
# consumed via environmentFiles. See infra/nixos/README.md and .sops.yaml.
{ config, lib, ... }:
let
  cfg = config.clubins.logto;
in
{
  options.clubins.logto = {
    enable = lib.mkEnableOption "the Logto OSS issuer (podman containers)";

    image = lib.mkOption {
      type = lib.types.str;
      default = "svhd/logto:1.45.0";
      description = ''
        Logto image, pinned to current stable v1.x (v1.45.0 per the
        self-hosted IdP research, 2026-10-30). Bump deliberately, never
        automatically — Logto database migrations are one-way.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3301;
      description = ''
        Host port forwarding to Logto's core service (container port 3001).
        Bound to 127.0.0.1 only — public traffic arrives via Caddy
        (clubins.caddy.logtoPort must match this).
      '';
    };

    endpoint = lib.mkOption {
      type = lib.types.str;
      example = "https://login.clubins.de";
      description = ''
        Public URL of the Logto service (ENDPOINT env). Per Logto docs this
        becomes the OIDC issuer identifier, so it must match the Go API's
        ISSUER config. Issuers differ local vs. prod — config, never code.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets/logto-env";
      description = ''
        Path of the SOPS-decrypted dotenv file (sops-nix secret `logto-env`)
        holding DB_URL and POSTGRES_PASSWORD. Passed to both containers as
        --env-file. Never inline secret values anywhere in this module.
      '';
    };

    network = lib.mkOption {
      type = lib.types.str;
      default = "logto";
      description = ''
        Podman network shared by Logto and its Postgres container, so the
        DB_URL hostname (logto-postgres) resolves by container name. Create
        it once on the host: `podman network create logto`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # oci-containers already defaults to podman on stateVersion >= 22.05;
    # pinning it here (softly) keeps the backend from drifting with the host.
    virtualisation.oci-containers.backend = lib.mkDefault "podman";

    virtualisation.oci-containers.containers.logto-postgres = {
      image = "postgres:16-alpine";
      autoStart = true;
      environment = {
        POSTGRES_DB = "logto";
        POSTGRES_USER = "logto";
        # POSTGRES_PASSWORD is read from the SOPS environment file — never
        # inline it here.
      };
      environmentFiles = [ cfg.environmentFile ];
      volumes = [ "logto-pgdata:/var/lib/postgresql/data" ];
      networks = [ cfg.network ];
    };

    virtualisation.oci-containers.containers.logto = {
      image = cfg.image;
      autoStart = true;
      dependsOn = [ "logto-postgres" ];
      environment = {
        # Behind Caddy, Logto must trust X-Forwarded-* headers, and its
        # issuer (ENDPOINT) must be the public URL, not a localhost:port.
        TRUST_PROXY_HEADER = "1";
        ENDPOINT = cfg.endpoint;
        # DB_URL (with credentials) comes from the SOPS environment file.
      };
      environmentFiles = [ cfg.environmentFile ];
      ports = [ "127.0.0.1:${toString cfg.port}:3001" ];
      networks = [ cfg.network ];
    };
  };
}
