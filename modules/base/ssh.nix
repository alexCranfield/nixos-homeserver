# Remote access: one admin account, and an SSH daemon that accepts only its key.
#
# The account is `ops` on every host, so it lives here rather than per host.
{ ... }:
{
  users.users.ops = {
    isNormalUser = true;
    description = "Server administrator";
    # Not `docker`: membership is root without a password (ADR 0006). Use
    # `sudo docker` instead.
    extraGroups = [ "wheel" ];
    # No password at all, so the account cannot log in at a console or over
    # SSH except with this key. Losing it means recovering from a live USB; see
    # "Lost ops key" in docs/runbooks/hardware.md.
    openssh.authorizedKeys.keyFiles = [ ../../keys/ops.pub ];
  };

  # ops has no password to type, so sudo cannot ask for one. Single-admin box;
  # the security review, ticket 7.2 (#45), revisits this.
  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    # ed25519 only. sops-nix derives the host's age identity from this entry
    # (ADR 0004), and fewer key types means fewer to verify on first connect.
    hostKeys = [
      {
        type = "ed25519";
        path = "/etc/ssh/ssh_host_ed25519_key";
      }
    ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };
}
