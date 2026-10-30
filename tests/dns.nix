# Acceptance test for ticket #164: the nuc serves the LAN's (local area
# network's) DNS (Domain Name System) with Blocky in front of Unbound. A client
# on the LAN resolves through it; names on each blocklist group are blocked and
# an allowlisted one is not; a declared and a private local name answer, the
# private one without passing through Blocky's configuration; Firefox's canary
# gets NXDOMAIN (no such name); home.arpa and reverse lookups go to the router;
# only port 53 is reachable from the LAN; the nuc's own resolver is not Blocky;
# and Blocky is back after a reboot.
#
# Three VMs (virtual machines). `nuc` runs the real host configuration, its
# address from the router's DHCP (Dynamic Host Configuration Protocol)
# reservation as in tests/network.nix. `router` stands in for the UniFi router
# and for the internet: dnsmasq hands out the reservation, answers home.arpa
# names and their reverse names, and gives fixed answers for the test's
# "internet" names. `client` is a LAN device the router has no name for.
#
# What it does not cover: Unbound's recursion and DNSSEC (DNS Security
# Extensions) validation, which need the internet and are checked on the nuc
# after deploy, and the real blocklists, which the build sandbox can't
# download (modules/dns/lists.nix records how their formats were checked).
{
  pkgs,
  inputs,
  lib,
}:
let
  reservedIp = "192.168.1.50";
  # As in tests/network.nix: QEMU's (Quick Emulator's) MAC (hardware) address
  # for a test VM's port.
  testMac =
    net: machine:
    "52:54:00:12:${lib.fixedWidthString 2 "0" (toString net)}:${
      lib.fixedWidthString 2 "0" (toString machine)
    }";

  # The test's blocklists, one per group, with a name on each. `allowed.test`
  # is also on the allowlist, which must win. `adsyntax.test` is in adblock
  # syntax, to record whether Blocky reads it; nothing is asserted about it.
  adsList = pkgs.writeText "dns-test-ads.txt" ''
    ad.test
    allowed.test
    ||adsyntax.test^
  '';
  threatsList = pkgs.writeText "dns-test-threats.txt" ''
    threat.test
  '';
  # The private record, as sops would write it on the real machine. In the
  # store only because a test has no sops; the name is unique so the test can
  # tell this file apart from anything Blocky's configuration carries.
  privateHosts = pkgs.writeText "dns-test-private-hosts-fixture" ''
    192.168.1.88 secret-host.home.arpa
  '';
in
pkgs.testers.runNixOSTest {
  name = "dns";
  node.specialArgs = { inherit inputs; };
  # As in base-ssh.nix: the host sets `nixpkgs.hostPlatform`, and every
  # machine shares the test's `pkgs`.
  node.pkgsReadOnly = false;
  defaults.nixpkgs.pkgs = pkgs;

  nodes.nuc =
    { config, nodes, ... }:
    let
      n = config.virtualisation.test.nodeNumber;
      routerIp = nodes.router.networking.primaryIPAddress;
    in
    {
      imports = [
        ../hosts/nuc
        # No sops secret here; the notifier posts to a sink. Without it units
        # that load the webhook fail, and switching to the specialisation
        # below would report them.
        ./notify-sink.nix
        (import ./grafana-password.nix { inherit pkgs; }).module
      ];
      # The host's stacks pull images, and the build sandbox has no internet;
      # tests/compose-stack.nix covers them.
      homeserver.stacks = lib.mkForce { };
      # No Tailscale key in a test; as in tests/network.nix.
      services.tailscale.authKeyFile = lib.mkForce null;
      # As in tests/docker.nix: no secret can be decrypted here, and the test
      # switches configuration, which would report it.
      system.activationScripts.setupSecrets = lib.mkForce "";

      # The LAN port, configured by the host itself, as in tests/network.nix.
      virtualisation.interfaces = {
        eth1.vlan = 1;
        eth2.vlan = 2;
      };
      systemd.network.links."10-lan".matchConfig.PermanentMACAddress = lib.mkForce (testMac 1 n);
      systemd.network.networks."10-unused".matchConfig.PermanentMACAddress = lib.mkForce (testMac 2 n);
      homeserver.network.router = routerIp;

      # Test overrides for DNS, each because the VM is not the real nuc.
      homeserver.dns = {
        # The address the router stand-in reserves for the nuc, in place of
        # the real one.
        listenAddresses = lib.mkForce [ reservedIp ];
        # The real lists are on the internet. Store files instead, plus a URL
        # that never answers (nothing listens there, and the router's firewall
        # drops it), as a list download that fails: Blocky must still resolve
        # and still block from the lists it has.
        lists = {
          ads = [
            "${adsList}"
            "http://${routerIp}:8000/unreachable.txt"
          ];
          threats = [ "${threatsList}" ];
        };
        allow = [ "allowed.test" ];
        records."svc.home.arpa" = [ "192.168.1.77" ];
        # Where sops would write it; copied there at boot below.
        privateHostsFile = "/run/dns-test/private-hosts";
        # Only to see it rendered into unbound.conf: with no trust anchor
        # here, nothing is validated anyway.
        insecureDomains = [ "example.test" ];
      };
      # Negative controls, switched to by the test: the same nuc without
      # Unbound's rebinding protection, and without the insecure domain.
      specialisation.unprotected.configuration = {
        services.unbound.settings.server.private-address = lib.mkForce [ ];
        homeserver.dns.insecureDomains = lib.mkForce [ ];
      };
      systemd.tmpfiles.rules = [
        "d /run/dns-test 0700 root root -"
        "C /run/dns-test/private-hosts 0400 root root - ${privateHosts}"
      ];

      services.unbound = {
        # No internet, so no root servers: forward everything to the router
        # stand-in, which plays the internet.
        settings.forward-zone = lib.mkForce [
          {
            name = ".";
            forward-addr = routerIp;
          }
        ];
        # The test's answers are unsigned, and without the internet there is
        # no root key to fetch. The real nuc validates (modules/dns/unbound.nix).
        enableRootTrustAnchor = lib.mkForce false;
        # Unbound answers `test.` itself (RFC 6761: Request for Comments 6761,
        # special-use names) with no such name. Let the test's names through.
        settings.server.local-zone = [ ''"test." nodefault'' ];
      };
      # Blocky does the same, and has no switch for one name alone: turn off
      # its special-use names. home.arpa and the LAN's reverse names reach the
      # router before this check, so the test still covers them.
      services.blocky.settings.specialUseDomains.enable = false;
    };

  nodes.router =
    { nodes, ... }:
    {
      services.dnsmasq = {
        enable = true;
        # Not the router's own resolver: its /etc/resolv.conf stays as the
        # test framework set it.
        resolveLocalQueries = false;
        settings = {
          interface = "eth1";
          bind-interfaces = true;
          # The nuc's reservation, as in tests/network.nix.
          dhcp-range = "192.168.1.100,192.168.1.200,1h";
          dhcp-host = "${testMac 1 nodes.nuc.virtualisation.test.nodeNumber},${reservedIp}";
          domain = "home.arpa";
          local = "/home.arpa/";
          # Names come from DHCP and from the record below, not from
          # /etc/hosts, where the test framework lists every VM: the client
          # has no name, as a device the router doesn't know.
          no-hosts = true;
          host-record = "router.home.arpa,${nodes.router.networking.primaryIPAddress}";
          # No upstream servers: anything not answered here is refused.
          no-resolv = true;
          # The "internet": fixed answers, from the documentation range
          # (192.0.2.0/24). use-application-dns.net has one too, so the
          # test shows Unbound's NXDOMAIN overrides a real answer.
          address = [
            "/example.test/192.0.2.10"
            "/allowed.test/192.0.2.11"
            "/ad.test/192.0.2.12"
            "/threat.test/192.0.2.13"
            "/adsyntax.test/192.0.2.14"
            "/use-application-dns.net/192.0.2.15"
            # A public-looking name, and its subdomains, answering with a LAN
            # address: a DNS rebinding attempt.
            "/rebind.test/192.168.1.66"
          ];
        };
      };
      networking.firewall.allowedUDPPorts = [
        53
        67
      ];
      networking.firewall.allowedTCPPorts = [ 53 ];
    };

  nodes.client = {
    virtualisation.vlans = [ 1 ];
    environment.systemPackages = [
      pkgs.dig
      pkgs.netcat
    ];
  };

  testScript =
    { nodes, ... }:
    ''
      NUC_IP = ${builtins.toJSON reservedIp}
      ROUTER_IP = ${builtins.toJSON nodes.router.networking.primaryIPAddress}
    ''
    + builtins.readFile ./dns.py;
}
