# Test-only module. Proves sops-nix actually decrypts, without a real machine.
#
# A VM built by `system.build.vm` regenerates its SSH host keys on every boot,
# so it can never be a recipient of anything encrypted beforehand. This hands it
# a throwaway age key through a shared directory instead, so no private key
# enters the repository or the Nix store. `.sops.yaml` scopes that key to
# secrets/test.yaml alone, so it cannot decrypt a real secret even if it leaks.
#
# Everything that could affect a running machine lives under
# `virtualisation.vmVariant`, so importing this module into a real host cannot
# add the power-off service to its closure.
{ config, lib, ... }:
{
  options.vmSecrets.keyDir = lib.mkOption {
    type = lib.types.str;
    default = "/run/user/1000/nixos-vm-age";
    description = ''
      Directory on the host holding the throwaway age key, shared into the VM.
      Defaults to the per-user runtime directory, which is mode 0700 and cannot
      be pre-created by another local user, unlike a path under /tmp.
    '';
  };

  config = {
    # The VM has no usable host key, so read the age key from a file instead.
    sops.age.sshKeyPaths = [ ];
    sops.age.keyFile = "/run/vm-age/vm-test.txt";
    sops.age.generateKey = false;

    sops.secrets.test.sopsFile = ../../secrets/test.yaml;

    virtualisation.vmVariant = {
      # `sharedDirectories` is declared by the QEMU module, which exists only in
      # the VM build. `vmVariant` is the supported way in.
      virtualisation.sharedDirectories.vmAgeKey = {
        source = config.vmSecrets.keyDir;
        target = "/run/vm-age";
      };
      virtualisation.graphics = false;

      systemd.services.sops-proof = {
        description = "Report whether the test secret decrypted, then power off";
        wantedBy = [ "multi-user.target" ];
        # No `after` on sops-install-secrets.service: that unit only exists when
        # systemd.sysusers or services.userborn is enabled. Here sops-nix uses
        # the activation-script path, which completes before any unit starts.
        serviceConfig = {
          Type = "oneshot";
          # Otherwise the result goes to the journal and never reaches the
          # serial console, which is all the runner captures.
          StandardOutput = "journal+console";
          StandardError = "journal+console";
        };
        script = ''
          if value=$(cat ${config.sops.secrets.test.path} 2>&1); then
            echo "SOPS-PROOF-OK: $value"
          else
            echo "SOPS-PROOF-FAILED: $value"
          fi
          ${config.systemd.package}/bin/systemctl poweroff
        '';
      };
    };
  };
}
