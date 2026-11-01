# Test for ticket 2.3 (#18): the reboot window reboots only for a new kernel
# or new kernel parameters.
#
# One VM (virtual machine) runs the real host configuration with three
# specialisations, variants built alongside it that the test switches to as
# comin would switch to a new commit: `config` changes only the login banner,
# `kernel` changes the kernel series, `params` adds a kernel parameter. The
# test starts the window's service by hand rather than waiting for Tuesday,
# and checks the timer's schedule separately.
{
  pkgs,
  inputs,
  lib,
}:
pkgs.testers.runNixOSTest {
  name = "reboot-window";
  node.specialArgs = { inherit inputs; };
  # As in base-ssh.nix: the host sets `nixpkgs.hostPlatform`, and every
  # machine shares the test's `pkgs`.
  node.pkgsReadOnly = false;
  defaults.nixpkgs.pkgs = pkgs;

  nodes.nuc = {
    imports = [
      ../hosts/nuc
      # No sops secret here; the notifier posts to a sink.
      ./notify-sink.nix
      (import ./grafana-password.nix { inherit pkgs; }).module
    ];
    # The host's stacks pull images, and the build sandbox has no internet;
    # tests/compose-stack.nix covers them.
    homeserver.stacks = lib.mkForce { };
    # The LAN's DNS server would bind the real nuc's address, which this VM
    # doesn't have; tests/dns.nix covers it.
    homeserver.dns.listenAddresses = lib.mkForce [ ];
    # As in base-ssh.nix: the sops secret cannot be decrypted here.
    services.tailscale.authKeyFile = lib.mkForce null;
    # Nor can any other: the VM has no key. At boot that failure is silent,
    # but a switch reports it (exit 2), and switching is what this test does,
    # so the decryption step is left out.
    system.activationScripts.setupSecrets = lib.mkForce "";
    # The window on its own: public messages (#161) move its timer to 09:55
    # and add a warning before each reboot. tests/announce.nix covers those.
    homeserver.announce.webhookFile = lib.mkForce null;
    # The hook #31 will use. The first command has quotes, an unset variable
    # and a backtick, which must reach bash intact rather than break the
    # script; the second fails, and the reboot must go ahead regardless.
    homeserver.rebootWindow.preReboot = [
      "echo \"hook-one-ran\" \"[$UNSET_IN_HOOK]\" '`x`'"
      "false"
    ];
    specialisation.config.configuration.users.motd = lib.mkForce "a configuration-only change";
    # The host uses linuxPackages_latest; the long-term series is a different
    # kernel, and cached, so nothing is compiled.
    specialisation.kernel.configuration.boot.kernelPackages = lib.mkForce pkgs.linuxPackages;
    # Same kernel, one more kernel parameter: also needs a reboot.
    specialisation.params.configuration.boot.kernelParams = [ "reboot-window-test" ];
  };

  testScript = ''
    KERNEL_LATEST = ${builtins.toJSON pkgs.linuxPackages_latest.kernel.version}
    KERNEL_OTHER = ${builtins.toJSON pkgs.linuxPackages.kernel.version}
  ''
  + builtins.readFile ./reboot-window.py;
}
