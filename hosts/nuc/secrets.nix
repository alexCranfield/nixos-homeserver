# The nuc's secrets, ticket 1.7 (#14).
#
# sops-nix decrypts them at activation with the age identity derived from the
# host's ed25519 SSH key, which `.sops.yaml` lists as the `nuc` recipient. The
# key was converted with ssh-to-age from the public key whose fingerprint Alex
# checked at the nuc's console on 2026-10-18.
#
# Only the bootstrap test secret lives here: it proves the machine can decrypt,
# and holds nothing sensitive. Real secrets are declared beside the service
# that needs them (modules/base/default.nix), such as the Tailscale auth key in
# hosts/nuc/tailscale.nix.
{
  sops.secrets.test.sopsFile = ../../secrets/test.yaml;
}
