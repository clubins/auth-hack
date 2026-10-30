# Example NixOS host consuming the Clubins auth modules.
#
# One-time host prerequisites (walkthrough in infra/nixos/README.md):
#   1. age key pair: private key at /var/lib/sops-nix/key.txt, public key
#      registered in the repo-root .sops.yaml (placeholder until then)
#   2. `podman network create logto`
#   3. `sops infra/secrets/logto-env.enc.env` — creates the encrypted env
#      file; SOPS files are ciphertext and safe to commit
#   4. the host flake imports sops-nix and this module directory:
#        imports = [
#          inputs.sops-nix.nixosModules.sops
#          /path/to/auth-hack/infra/nixos
#        ];
#
# Eval note: fully evaluating this file before step 3 fails on the missing
# sopsFile — that is the forcing function, not a bug. --parse passes
# regardless.
{ ... }:
let
  # Single source of truth for the ports Caddy and Logto must agree on.
  logtoPort = 3301;
  apiPort = 8080;
in
{
  imports = [ ../default.nix ];

  # Let ACME reach us and serve TLS.
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  clubins.logto = {
    enable = true;
    port = logtoPort;
    endpoint = "https://login.clubins.de"; # the OIDC issuer the Go API trusts
  };

  clubins.caddy = {
    enable = true;
    acmeEmail = "admin@clubins.de"; # replace with the real ops address
    logtoPort = logtoPort;
    apiPort = apiPort;
  };

  clubins.sops = {
    enable = true;
    logtoEnvFile = ../../secrets/logto-env.enc.env;
    # oci-containers podman services are named podman-<container>.
    restartUnits = [ "podman-logto.service" ];
  };
}
