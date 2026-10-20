# Test for ticket 2.1 (#16): comin follows `main` and nothing else.
#
# One VM (virtual machine) runs the real host configuration, with comin's
# remote pointed at a Git repository inside the VM, since the build sandbox has
# no internet. Everything else about the remote, the branches above all, is
# copied from the real configuration, so the test checks what the nuc runs.
#
# What it proves: comin runs after boot, fetches `main`, and ignores a
# `testing-nuc` branch pushed on top of it, which comin would otherwise deploy
# without review (modules/base/comin.nix). It does not prove a deploy: the
# repository holds no flake, because building a system needs the internet.
# The real deploy is checked on the nuc itself (docs/runbooks/deploy.md).
{
  pkgs,
  inputs,
  lib,
}:
let
  repo = "/var/lib/comin-test-repo";
  real = inputs.self.nixosConfigurations.nuc.config.services.comin;
in
pkgs.testers.runNixOSTest {
  name = "comin";
  node.specialArgs = { inherit inputs; };
  # As in base-ssh.nix: the host sets `nixpkgs.hostPlatform`.
  node.pkgsReadOnly = false;

  nodes.nuc = {
    imports = [ ../hosts/nuc ];
    # As in base-ssh.nix: the sops secret cannot be decrypted here.
    services.tailscale.authKeyFile = lib.mkForce null;
    # The real remote with a local URL and a 2 s poll, so the test does not
    # wait a minute per fetch.
    services.comin.remotes = lib.mkForce (
      map (
        r:
        r
        // {
          url = repo;
          poller = r.poller // {
            period = 2;
          };
        }
      ) real.remotes
    );
  };

  testScript = ''
    REPO = ${builtins.toJSON repo}
    REAL_URL = ${builtins.toJSON (builtins.head real.remotes).url}
  ''
  + builtins.readFile ./comin.py;
}
