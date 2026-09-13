# Test-only module. Never imported by a real host.
#
# A VM built by `system.build.vm` generates fresh SSH host keys on every boot,
# so it can never be a recipient of anything encrypted beforehand. This gives it
# a throwaway age key instead, delivered through a shared directory so no
# private key enters the repository or the Nix store.
#
# The key is scoped in .sops.yaml to secrets/test.yaml alone, so it cannot
# decrypt a real secret even if it leaks.
{ lib, pkgs, ... }:
{
  # The VM has no usable host key, so read the age key from a file instead.
  sops.age.sshKeyPaths = lib.mkForce [ ];
  sops.age.keyFile = "/run/vm-age/vm-test.txt";
  sops.age.generateKey = false;

  sops.secrets.test = { };

  # `virtualisation.sharedDirectories` is declared by the QEMU module, which is
  # only present in the VM build. `vmVariant` is the supported way to add
  # configuration that applies to `system.build.vm` and nowhere else.
  virtualisation.vmVariant = {
    virtualisation.sharedDirectories.vmAgeKey = {
      source = "/tmp/nixos-vm-age";
      target = "/run/vm-age";
    };
    virtualisation.graphics = false;
  };

  # Prove decryption happened, then power off, so the whole check is one
  # non-interactive command.
  systemd.services.sops-proof = {
    description = "Print the decrypted test secret and power off";
    wantedBy = [ "multi-user.target" ];
    after = [ "sops-install-secrets.service" ];
    serviceConfig = {
      Type = "oneshot";
      # Without this the proof goes to the journal and never reaches the serial
      # console, which is the only thing the runner captures.
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    script = ''
      echo "SOPS-PROOF-BEGIN"
      cat /run/secrets/test || echo "SOPS-PROOF-DECRYPTION-FAILED"
      echo "SOPS-PROOF-END"
      ${pkgs.systemd}/bin/systemctl poweroff
    '';
  };
}
