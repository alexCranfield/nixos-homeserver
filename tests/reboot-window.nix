# Test for ticket 2.3 (#18): the reboot window reboots only for a new kernel.
#
# One VM (virtual machine) runs the real host configuration with two
# specialisations, variants built alongside it that the test switches to as
# comin would switch to a new commit: `config` changes only the login banner,
# `kernel` changes the kernel series. The test starts the window's service by
# hand rather than waiting for Tuesday, and checks the timer's schedule
# separately.
{
  pkgs,
  inputs,
  lib,
}:
pkgs.testers.runNixOSTest {
  name = "reboot-window";
  node.specialArgs = { inherit inputs; };
  # As in base-ssh.nix: the host sets `nixpkgs.hostPlatform`.
  node.pkgsReadOnly = false;

  nodes.nuc = {
    imports = [ ../hosts/nuc ];
    # As in base-ssh.nix: the sops secret cannot be decrypted here.
    services.tailscale.authKeyFile = lib.mkForce null;
    # Nor can any other: the VM has no key. At boot that failure is silent,
    # but a switch reports it (exit 2), and switching is what this test does,
    # so the decryption step is left out.
    system.activationScripts.setupSecrets = lib.mkForce "";
    # The hook #31 will use, here with one command that fails: the reboot must
    # go ahead regardless.
    homeserver.rebootWindow.preReboot = [
      "echo hook-one-ran"
      "false"
    ];
    specialisation.config.configuration.users.motd = lib.mkForce "a configuration-only change";
    # The host uses linuxPackages_latest; the long-term series is a different
    # kernel, and cached, so nothing is compiled.
    specialisation.kernel.configuration.boot.kernelPackages = lib.mkForce pkgs.linuxPackages;
  };

  testScript = ''
    KERNEL_LATEST = ${builtins.toJSON pkgs.linuxPackages_latest.kernel.version}
    KERNEL_OTHER = ${builtins.toJSON pkgs.linuxPackages.kernel.version}
  ''
  + builtins.readFile ./reboot-window.py;
}
