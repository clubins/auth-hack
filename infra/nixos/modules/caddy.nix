# Caddy TLS termination for the Clubins auth stack.
#
#   login.clubins.de  -> Logto's hosted sign-in   (127.0.0.1:<logtoPort>)
#   api.clubins.de    -> Go API                   (127.0.0.1:<apiPort>)
#
# Certificates come from ACME (Let's Encrypt); Caddy obtains and renews
# them automatically once the domains point at the host and ports 80/443
# are reachable.
{ config, lib, ... }:
let
  cfg = config.clubins.caddy;
in
{
  options.clubins.caddy = {
    enable = lib.mkEnableOption "Caddy vhosts for the Clubins auth stack";

    acmeEmail = lib.mkOption {
      type = lib.types.str;
      example = "admin@clubins.de";
      description = "ACME account email — Let's Encrypt expiry notices land here.";
    };

    logtoHost = lib.mkOption {
      type = lib.types.str;
      default = "login.clubins.de";
      description = "Public domain of the Logto issuer.";
    };

    apiHost = lib.mkOption {
      type = lib.types.str;
      default = "api.clubins.de";
      description = "Public domain of the Go API.";
    };

    logtoPort = lib.mkOption {
      type = lib.types.port;
      default = 3301;
      description = "Loopback port of the Logto core service — keep in sync with clubins.logto.port.";
    };

    apiPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Loopback port of the Go API.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.caddy = {
      enable = true;
      email = cfg.acmeEmail;

      # Caddy's virtualHosts entries imply TLS via ACME; no manual
      # tls directive needed for public domains.
      virtualHosts."${cfg.logtoHost}".extraConfig = ''
        reverse_proxy 127.0.0.1:${toString cfg.logtoPort}
      '';

      virtualHosts."${cfg.apiHost}".extraConfig = ''
        reverse_proxy 127.0.0.1:${toString cfg.apiPort}
      '';
    };
  };
}
