# Acceptance test for ticket 1.5 (#12): ops logs in to the nuc over the tailnet
# from another network, and the tailnet sees only SSH.
#
# Three VMs (virtual machines) on two networks:
#
#  - `nuc` runs the real host configuration, on network 1, the LAN (local area
#    network).
#  - `client` stands in for the workstation on a phone hotspot: network 2, with
#    no route to network 1.
#  - `headscale` stands in for Tailscale's own servers. Headscale is an
#    open-source implementation of Tailscale's control server; here it also
#    runs the relay that carries traffic between the two networks. It sits on
#    both, as the internet would.
#
# The real tailnet cannot be used: the build sandbox has no internet, and a
# test must not hold a real auth key. What differs from the real thing: the
# login server (`--login-server`), and the auth key, which the test writes to a
# file where #14 will point `authKeyFile` at a sops secret. Tags (`tag:server`)
# live in the real tailnet's access rules and are not tested here.
{
  pkgs,
  inputs,
  lib,
}:
let
  lanIp = "192.168.1.50";
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
  # As in nixpkgs' own headscale test: Tailscale talks to its control server
  # over HTTPS only, so the stand-in needs a certificate the others trust.
  tlsCert = pkgs.runCommand "headscale-cert" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
      -out cert.pem -keyout key.pem \
      -subj '/CN=headscale' -addext "subjectAltName=DNS:headscale"
    mkdir -p $out
    cp key.pem cert.pem $out
  '';
  trustCert = {
    security.pki.certificateFiles = [ "${tlsCert}/cert.pem" ];
  };
  # QEMU's address for a test VM's port, as in tests/network.nix.
  testMac =
    net: machine:
    "52:54:00:12:${lib.fixedWidthString 2 "0" (toString net)}:${
      lib.fixedWidthString 2 "0" (toString machine)
    }";
in
pkgs.testers.runNixOSTest {
  name = "tailscale";
  node.specialArgs = { inherit inputs; };
  # As in base-ssh.nix: the host sets `nixpkgs.hostPlatform`.
  node.pkgsReadOnly = false;

  nodes.nuc =
    { config, ... }:
    {
      imports = [
        ../hosts/nuc
        trustCert
      ];

      # One port on the LAN, renamed lan0 as on the real machine, with a fixed
      # address in place of the router's reservation (tests/network.nix covers
      # DHCP).
      virtualisation.interfaces.eth1.vlan = 1;
      systemd.network.links."10-lan".matchConfig.PermanentMACAddress = lib.mkForce (
        testMac 1 config.virtualisation.test.nodeNumber
      );
      systemd.network.networks."10-lan" = {
        networkConfig.DHCP = lib.mkForce "no";
        address = [ "${lanIp}/24" ];
      };

      # Where #14 puts the sops secret's path. The test writes the key here.
      services.tailscale.authKeyFile = "/run/ts-authkey";
      services.tailscale.extraUpFlags = [ "--login-server=https://headscale" ];

      users.users.ops.openssh.authorizedKeys.keys = [ keys.snakeOilPublicKey ];

      # A listener the firewall should hide from the tailnet.
      systemd.services.probe = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8080";
      };
    };

  nodes.client = {
    imports = [ trustCert ];
    virtualisation.vlans = [ 2 ];
    services.tailscale.enable = true;
    environment.systemPackages = [ pkgs.nmap ];
  };

  nodes.headscale = {
    virtualisation.vlans = [
      1
      2
    ];
    services.headscale = {
      enable = true;
      port = 8080;
      settings = {
        server_url = "https://headscale";
        prefixes.v4 = "100.64.0.0/10";
        derp = {
          server = {
            enabled = true;
            region_id = 999;
            stun_listen_addr = "0.0.0.0:3478";
          };
          urls = [ ];
        };
        # MagicDNS: each device answers to <its hostname>.tailnet.
        dns = {
          magic_dns = true;
          base_domain = "tailnet";
          override_local_dns = false;
        };
      };
    };
    services.nginx = {
      enable = true;
      virtualHosts.headscale = {
        addSSL = true;
        sslCertificate = "${tlsCert}/cert.pem";
        sslCertificateKey = "${tlsCert}/key.pem";
        locations."/" = {
          proxyPass = "http://127.0.0.1:8080";
          proxyWebsockets = true;
        };
      };
    };
    networking.firewall = {
      allowedTCPPorts = [
        80
        443
      ];
      allowedUDPPorts = [ 3478 ];
    };
    environment.systemPackages = [
      pkgs.headscale
      pkgs.nmap
    ];
  };

  testScript = ''
    LAN_IP = ${builtins.toJSON lanIp}
    SNAKEOIL_KEY = ${builtins.toJSON "${keys.snakeOilPrivateKey}"}
  ''
  + builtins.readFile ./tailscale.py;
}
