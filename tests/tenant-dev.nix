# Test for ticket 6.10 (#200): the tenant's dev VM's own module
# (modules/tenants/dev.nix); ADR (Architecture Decision Record) 0013.
#
# CI (continuous integration) cannot boot the microVM itself (it would be a
# VM inside the test VM), so the module runs on a plain test node, `dev`, and
# `client` logs in to it as the tenant would. The tailnet side (the share,
# the tag's policy) is checked on the live tailnet instead
# (docs/runbooks/tenants.md): tailscaled runs logged out here.
{
  pkgs,
  lib,
}:
let
  # The tenant's key, and one that isn't theirs. Test keys only, so a private
  # half in the store is fine.
  keys = pkgs.runCommand "tenant-dev-test-keys" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir $out
    ssh-keygen -q -t ed25519 -N "" -C tenant -f $out/tenant
    ssh-keygen -q -t ed25519 -N "" -C stranger -f $out/stranger
  '';
  # A program built for any Linux, not NixOS: GNU hello, with the usual
  # /lib64 interpreter and no paths into the store, as a binary from PyPI
  # (ruff, say) or a downloaded Python is (#219).
  genericHello = pkgs.runCommand "generic-hello" { nativeBuildInputs = [ pkgs.patchelf ]; } ''
    cp ${pkgs.hello}/bin/hello $out
    chmod u+w $out
    patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 --remove-rpath $out
  '';
in
pkgs.testers.runNixOSTest {
  name = "tenant-dev";
  # Each node gets its own nixpkgs, which allows Claude Code, rather than
  # the test's read-only one.
  node.pkgsReadOnly = false;

  nodes.dev = {
    imports = [
      ../modules/base/ssh.nix
      ../modules/tenants/dev.nix
    ];
    nixpkgs.config.allowUnfreePredicate = import ../modules/tenants/unfree.nix lib;
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
    # nftables, as ./guest-base.nix gives the real VM.
    networking.nftables.enable = true;
    networking.firewall.allowedTCPPorts = [ 22 ];
    homeserver.tenantDev.sshKeyFile = "/etc/tenant-ssh-key";
    homeserver.tenantDev.tailscaleAuthKeyFile = null;
    environment.etc."tenant-ssh-key".source = "${keys}/tenant.pub";
    environment.etc."generic-hello".source = genericHello;
  };

  nodes.client = { };

  testScript = ''
    KEYS = "${keys}"
  ''
  + builtins.readFile ./tenant-dev.py;
}
