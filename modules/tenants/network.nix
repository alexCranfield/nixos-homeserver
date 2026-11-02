# The tenant VMs' network, ticket 6.7 (#197); ADR (Architecture Decision
# Record) 0013, decision 2.
#
# Each VM gets a tap interface, `vm-<name>`, routed rather than bridged, as in
# microvm.nix's "routed network" page: the host holds 10.88.0.1/32 on every
# tap and a /32 route to each VM's 10.88.0.<index>. Nothing joins the taps at
# layer 2, so a VM's traffic to anything, the other VM included, passes the
# host's forward rules. The VMs' traffic leaves masqueraded as the nuc's LAN
# (local area network) address.
#
# A VM may reach two things: the internet, and Blocky's port 53 on the nuc's
# LAN address. Everything else is dropped by the `tenant-isolation` table:
#
#  - forward: any private, shared, link-local, multicast or reserved
#    destination, which covers the LAN, the router, Docker's networks
#    (including a published port, whose destination Docker has rewritten to a
#    container's 172.x address by then), the tailnet and the other VM; any
#    exit but lan0; all IPv6; and any new connection *to* a VM, such as one
#    from a container, which Docker's `br-*` rule in
#    modules/containers/docker.nix would otherwise accept.
#  - input: anything to the nuc itself except DNS to Blocky's address.
#
# The table only drops. An accept in one nftables table doesn't decide for
# another, so what is let through is opened where NixOS opens everything
# else: port 53 on the taps in the firewall, and the forward accept that
# `networking.nat` adds for 10.88.0.0/24 leaving on lan0. The drops win
# whatever is opened later, a global `allowedTCPPorts` included.
#
# Never give an interface here a name starting `br-`: Docker's forward rule
# accepts everything from those. The `tenant-` prefix the names must have
# (./default.nix) rules it out.
{
  config,
  lib,
  ...
}:
let
  cfg = config.homeserver.tenants;
  enabled = cfg.vms != { };
  tap = name: "vm-${name}";
  address = vm: "${cfg.subnet}.${toString vm.index}";
  # IPv4 only, like the VMs.
  blocky = lib.filter (a: !lib.hasInfix ":" a) config.homeserver.dns.listenAddresses;

  # Destinations a VM never reaches, in IANA's (Internet Assigned Numbers
  # Authority's) special-purpose registry: this network, private (10/8,
  # 172.16/12, 192.168/16), shared address space (100.64/10, also the
  # tailnet's), loopback, link-local, multicast, and reserved with the
  # broadcast address.
  closed = [
    "0.0.0.0/8"
    "10.0.0.0/8"
    "100.64.0.0/10"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "224.0.0.0/4"
    "240.0.0.0/4"
  ];
in
{
  config = lib.mkIf enabled {
    systemd.network.networks = lib.mapAttrs' (
      name: vm:
      lib.nameValuePair "30-${tap name}" {
        matchConfig.Name = tap name;
        address = [ "${cfg.hostAddress}/32" ];
        routes = [ { Destination = "${address vm}/32"; } ];
        networkConfig = {
          IPv4Forwarding = true;
          # IPv4 only (ADR 0013): no link-local IPv6 address, no router
          # advertisements, so nothing on the tap speaks IPv6 at all.
          LinkLocalAddressing = "no";
          IPv6AcceptRA = false;
          # The tap exists only while its VM runs; boot doesn't wait for it.
          ConfigureWithoutCarrier = true;
        };
        linkConfig.RequiredForOnline = "no";
      }
    ) cfg.vms;

    networking.nat = {
      enable = true;
      internalIPs = [ "${cfg.subnet}.0/24" ];
      externalInterface = "lan0";
    };

    # DNS to Blocky, the only service on the nuc a VM reaches. The table
    # below limits it to Blocky's address.
    networking.firewall.interfaces = lib.mapAttrs' (
      name: _:
      lib.nameValuePair (tap name) (
        lib.mkIf (blocky != [ ]) {
          allowedUDPPorts = [ 53 ];
          allowedTCPPorts = [ 53 ];
        }
      )
    ) cfg.vms;

    # Names for the query log and the DNS alerts in place of 10.88 addresses,
    # which the router's reverse lookups don't know.
    homeserver.dns.clientNames = lib.mapAttrs (_: vm: [ (address vm) ]) cfg.vms;

    networking.nftables.tables.tenant-isolation = {
      family = "inet";
      content = ''
        set closed {
          type ipv4_addr
          flags interval
          elements = { ${lib.concatStringsSep ", " closed} }
        }

        # Read by tests/tenant-net.py, to tell this table's drops apart from
        # the stack-ports table's.
        counter forward-drops {}
        counter input-drops {}

        chain forward {
          # Before NixOS's own forward chain (priority filter) and Docker's.
          type filter hook forward priority filter - 20; policy accept;
          iifname "vm-tenant-*" meta nfproto ipv6 counter name "forward-drops" drop
          oifname "vm-tenant-*" meta nfproto ipv6 counter name "forward-drops" drop
          iifname "vm-tenant-*" ip daddr @closed counter name "forward-drops" drop
          iifname "vm-tenant-*" oifname != "lan0" counter name "forward-drops" drop
          oifname "vm-tenant-*" ct state established,related return
          oifname "vm-tenant-*" counter name "forward-drops" drop
        }

        chain input {
          type filter hook input priority filter - 10; policy accept;
          iifname "vm-tenant-*" ct state established,related return
          ${lib.optionalString (blocky != [ ]) ''
            iifname "vm-tenant-*" ip daddr { ${lib.concatStringsSep ", " blocky} } meta l4proto { tcp, udp } th dport 53 return
          ''}
          iifname "vm-tenant-*" counter name "input-drops" drop
        }
      '';
    };
  };
}
