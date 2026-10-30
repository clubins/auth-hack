# Aggregate NixOS module for the Clubins auth stack.
#
# Importing this file pulls in the Logto, Caddy, and SOPS modules at once:
#
#   imports = [ /path/to/auth-hack/infra/nixos ];
#
# Per-module import works too:
#
#   imports = [ /path/to/auth-hack/infra/nixos/modules/logto.nix ];
#
# A host flake typically pairs this with sops-nix:
#   imports = [ inputs.sops-nix.nixosModules.sops /path/to/infra/nixos ];
{ imports = [
    ./modules/logto.nix
    ./modules/caddy.nix
    ./modules/sops.nix
  ];
}
