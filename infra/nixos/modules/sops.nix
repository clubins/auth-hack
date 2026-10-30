# sops-nix scaffolding for the Clubins auth stack.
#
# The host must import the sops-nix NixOS module itself — this repo does
# not vendor it. In the host flake: inputs.sops-nix.url =
# "github:Mic92/sops-nix" and pass sops-nix.nixosModules.sops in the
# module list. Walkthrough: infra/nixos/README.md.
{ config, lib, ... }:
let
  cfg = config.clubins.sops;
in
{
  options.clubins.sops = {
    enable = lib.mkEnableOption "sops-nix secret scaffolding for the Clubins stack";

    ageKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/sops-nix/key.txt";
      description = ''
        Host path of the age PRIVATE key sops-nix decrypts with. Provision
        it once (README: age-keygen -o /var/lib/sops-nix/key.txt), then
        register the public key (recipient) in the repo-root .sops.yaml —
        a placeholder sits there until then.
      '';
    };

    logtoEnvFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        SOPS-encrypted dotenv file for the Logto stack (DB_URL,
        POSTGRES_PASSWORD). Create with `sops infra/secrets/logto-env.enc.env`
        after replacing the placeholder recipient in .sops.yaml. SOPS files
        are ciphertext and safe to commit.
      '';
    };

    restartUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "podman-logto.service" ];
      description = ''
        Units restarted when the logto-env secret changes. The
        oci-containers podman backend names services
        `<backend>-<container>`, hence podman-logto.service.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # mkDefault so a host that already manages sops-nix can override.
    sops.age.keyFile = lib.mkDefault cfg.ageKeyFile;

    sops.secrets."logto-env" = lib.mkIf (cfg.logtoEnvFile != null) {
      sopsFile = cfg.logtoEnvFile;
      format = "dotenv";
      mode = "0400";
      restartUnits = cfg.restartUnits;
    };
  };
}
