# Acceptance test for ticket 1.3 (#10): the nuc configuration accepts its admin
# over SSH by key only.
#
# Two VMs (virtual machines): `nuc` runs the real host configuration, and
# `client` tries to log in. The login key is nixpkgs' published test key
# ("snake oil"), added to the test VM only, so no real private key is needed
# and the real host never trusts it.
{
  pkgs,
  inputs,
  nixpkgs,
}:
let
  keys = import "${nixpkgs}/nixos/tests/ssh-keys.nix" pkgs;
  # `-n`: never read stdin. The test driver talks to the guest's root shell over
  # stdin, and ssh closes its stdout before it exits. The driver then sends its
  # next line, ssh forwards that line to the nuc, and the driver waits forever.
  ssh = "ssh -n -i key -o StrictHostKeyChecking=no -o BatchMode=yes";
in
pkgs.testers.runNixOSTest {
  name = "base-ssh";
  node.specialArgs = { inherit inputs; };
  # The host sets `nixpkgs.hostPlatform`, as a real host must. The test
  # framework otherwise supplies a read-only `pkgs` and rejects that option.
  node.pkgsReadOnly = false;

  nodes.nuc = {
    imports = [ ../hosts/nuc ];
    users.users.ops.openssh.authorizedKeys.keys = [ keys.snakeOilPublicKey ];
    # Lets the test show that root is refused even holding a valid key.
    users.users.root.openssh.authorizedKeys.keys = [ keys.snakeOilPublicKey ];
  };

  nodes.client = { };

  testScript = ''
    start_all()
    nuc.wait_for_unit("sshd.service")
    client.succeed("install -m 600 ${keys.snakeOilPrivateKey} key")
    client.wait_until_succeeds("${ssh} ops@nuc true", timeout=60)

    with subtest("ops logs in with the key and runs 26.05 on the latest kernel"):
        version = client.succeed("${ssh} ops@nuc nixos-version").strip()
        print(f"nixos-version: {version}")
        assert version.startswith("26.05"), version
        print("kernel: " + client.succeed("${ssh} ops@nuc uname -r").strip())

    with subtest("passwords are not offered at all"):
        status, out = client.execute(
            "${ssh} -o PubkeyAuthentication=no ops@nuc true 2>&1"
        )
        print(out)
        assert status != 0, "login without a key succeeded"
        assert "Permission denied (publickey)." in out, out

    with subtest("root is refused even with an authorised key"):
        status, out = client.execute("${ssh} root@nuc true 2>&1")
        print(out)
        assert status != 0, "root logged in"
        assert "Permission denied" in out, out

    with subtest("ops can sudo without a password, and is not in docker"):
        client.succeed("${ssh} ops@nuc sudo -n true")
        groups = client.succeed("${ssh} ops@nuc id -nG").split()
        print(f"groups: {groups}")
        assert "wheel" in groups and "docker" not in groups, groups

    with subtest("the only host key is ed25519"):
        nuc.succeed("test -e /etc/ssh/ssh_host_ed25519_key")
        # Each test separately: `ls a b` fails if either is missing, so it would
        # pass with an RSA key present.
        nuc.succeed("test ! -e /etc/ssh/ssh_host_rsa_key")
        nuc.succeed("test ! -e /etc/ssh/ssh_host_ecdsa_key")
  '';
}
