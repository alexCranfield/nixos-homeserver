# tenant-dev, where the tenant develops, ticket 6.10 (#200); ADR
# (Architecture Decision Record) 0013. A guest module, beside
# ./guest-base.nix:
#
#  - The user `tenant`, who logs in over SSH with the key the host passes in
#    from sops (the credential `tenant-ssh-key`) and no other, has sudo and Docker, and
#    keeps their home in /var, the VM's one persistent volume; the rest of
#    the root is rebuilt at every boot.
#  - Their tools: git, gh, sops, age, Node.js, Python, uv and Claude Code,
#    and nix-ld for programs built outside Nix (#219). Claude Code is
#    unfree, allowed by name alone (./unfree.nix, applied by the host). It comes from nixpkgs, so
#    it updates with this repository's nixpkgs, not by itself.
#  - Its own tailscaled, joined once with a single-use auth key tagged
#    `tag:tenant-dev` (the credential `tailscale-auth-key`). Alex shares the
#    device with the tenant, and the tailnet's policy lets share recipients
#    reach its port 22 and gives the tag nothing as a source
#    (docs/runbooks/tailscale.md). Its state is in /var, so the key is used
#    once.
#  - tenant-dev-keys makes two keys on first boot, in the tenant's home: an
#    SSH key that Alex adds to the private repo as a deploy key with write
#    access, so the VM can push to that repo and nothing else on GitHub;
#    and an age key, which Alex adds to the repo's rule for secrets/dev.yaml,
#    never prod.yaml. Their public halves are copied to
#    /var/lib/tenant-dev/{deploy_key,age}.pub for Alex to read.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homeserver.tenantDev;
  home = "/var/home/tenant";
  state = "/var/lib/tenant-dev";
  ageKey = "${home}/.config/sops/age/keys.txt";
  deployKey = "${home}/.ssh/id_ed25519";
in
{
  options.homeserver.tenantDev = {
    sshKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        A file holding the tenant's SSH public key. Null: the system
        credential `tenant-ssh-key`, which the host passes into the VM from
        sops. Tests set a file.
      '';
    };
    tailscaleAuthKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "/run/credentials/@system/tailscale-auth-key";
      description = ''
        The auth key tailscaled joins with, the first time. The default is
        the system credential the host passes in from sops. Null: tailscaled
        runs logged out, as in tests.
      '';
    };
  };

  config = {
    users.users.tenant = {
      isNormalUser = true;
      description = "The tenant";
      inherit home;
      # Made by tmpfiles below, once /var is mounted: activation, which
      # would otherwise make it, runs before.
      createHome = false;
      extraGroups = [
        "wheel"
        "docker"
      ];
    };
    systemd.tmpfiles.settings."10-tenant-dev" = {
      "/var/home".d.mode = "0755";
      ${home}.d = {
        mode = "0700";
        user = "tenant";
        group = "users";
      };
      ${state}.d.mode = "0755";
    };

    # The tenant's key comes from sops alone, through a file in /run they
    # can't edit, and no ~/.ssh/authorized_keys is read: a key added there
    # would outlive a key replaced in sops. The ops key stays in /etc.
    services.openssh.authorizedKeysFiles = [ "/run/tenant-ssh/%u" ];
    services.openssh.authorizedKeysInHomedir = false;
    systemd.services.tenant-ssh-key = {
      description = "Install the tenant's SSH public key from its credential";
      wantedBy = [ "multi-user.target" ];
      before = [ "sshd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        LoadCredential =
          "tenant-ssh-key" + lib.optionalString (cfg.sshKeyFile != null) ":${cfg.sshKeyFile}";
      };
      path = [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.openssh
      ];
      script = ''
        key=$CREDENTIALS_DIRECTORY/tenant-ssh-key
        # One public key, nothing else: ssh-keygen refuses anything that
        # isn't one, a private key included.
        [ "$(grep -c . "$key")" = 1 ] || {
          echo "tenant-ssh-key must hold exactly one public key" >&2
          exit 1
        }
        ssh-keygen -l -f "$key"
        install -d -m 0755 /run/tenant-ssh
        install -m 0644 "$key" /run/tenant-ssh/tenant
      '';
    };

    systemd.services.tenant-dev-keys = {
      description = "Make tenant-dev's deploy key and age key, once";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      path = [
        pkgs.openssh
        pkgs.age
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "tenant";
        UMask = "0077";
        # As root, after: the public halves where Alex can read them, from
        # the tenant's home, which only they can.
        ExecStartPost =
          "+"
          + pkgs.writeShellScript "tenant-dev-keys-publish" ''
            set -eu
            ${pkgs.coreutils}/bin/install -m 0644 ${deployKey}.pub ${state}/deploy_key.pub
            ${pkgs.age}/bin/age-keygen -y ${ageKey} >${state}/age.pub
            ${pkgs.coreutils}/bin/chmod 0644 ${state}/age.pub
            echo "deploy key: $(${pkgs.coreutils}/bin/cat ${state}/deploy_key.pub)"
            echo "age recipient: $(${pkgs.coreutils}/bin/cat ${state}/age.pub)"
          '';
      };
      script = ''
        if [ ! -e ${deployKey} ]; then
          mkdir -p ${home}/.ssh
          rm -f ${deployKey}.new ${deployKey}.new.pub
          ssh-keygen -q -t ed25519 -N "" -C "tenant-dev deploy key" -f ${deployKey}.new
          mv ${deployKey}.new.pub ${deployKey}.pub
          mv ${deployKey}.new ${deployKey}
        fi
        # A public half deleted on its own is made again from the key.
        if [ ! -e ${deployKey}.pub ]; then
          ssh-keygen -y -f ${deployKey} >${deployKey}.pub
        fi
        if [ ! -e ${ageKey} ]; then
          mkdir -p "$(dirname ${ageKey})"
          rm -f ${ageKey}.new
          age-keygen -o ${ageKey}.new 2>/dev/null
          mv ${ageKey}.new ${ageKey}
        fi
      '';
    };

    # GitHub's published host key, so the first push can't be intercepted.
    programs.ssh.knownHosts."github.com".publicKey =
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";

    virtualisation.docker = {
      enable = true;
      daemon.settings.log-driver = "local";
    };

    environment.systemPackages = [
      pkgs.git
      pkgs.gh
      pkgs.sops
      pkgs.age
      pkgs.nodejs
      pkgs.jq
      pkgs.claude-code
      # The private repo's jobs are Python, run through uv (#219). uv uses
      # this Python for a project that asks for 3.13.
      pkgs.python313
      pkgs.uv
    ];
    # Standalone programs built for any Linux, not NixOS, run: the binaries
    # `uv sync` installs from PyPI (ruff), and a Python uv downloads for a
    # project that wants another version. Not a native wheel imported by the
    # Nix Python: its loader ignores nix-ld's libraries (runbook). The store
    # is read-only to the tenant, so this is their way to add a tool; the VM
    # is the boundary, not the store.
    programs.nix-ld.enable = true;

    services.tailscale = {
      enable = true;
      useRoutingFeatures = "none";
      authKeyFile = cfg.tailscaleAuthKeyFile;
      # Lookups stay on the tenants' own filtered Blocky (./dns.nix), not
      # MagicDNS.
      extraUpFlags = [ "--accept-dns=false" ];
      disableTaildrop = true;
    };
    # SSH from the tailnet; the policy lets share recipients alone that far.
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 22 ];
  };
}
