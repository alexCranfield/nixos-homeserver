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
# A VM may reach two things: the internet, and port 53 on 10.88.0.1, the
# tenants' own Blocky (./dns.nix). Everything else is dropped by the
# `tenant-isolation` table:
#
#  - forward: any private, shared, link-local, multicast or reserved
#    destination, which covers the LAN, the router, Docker's networks
#    (including a published port, whose destination Docker has rewritten to a
#    container's 172.x address by then), the tailnet and the other VM; the
#    router's own public address (below); any exit but lan0; all IPv6; and
#    any new connection *to* a VM, such as one from a container, which
#    Docker's `br-*` rule in modules/containers/docker.nix would otherwise
#    accept.
#  - input: anything to the nuc itself except DNS to 10.88.0.1, the LAN's
#    Blocky included.
#
# The router answers on its public (WAN, wide area network) address from
# inside the LAN, its management console among it, so that address is closed
# too. It changes when the provider says so, so it can't be written here:
# `tenant-router-wan.service` looks it up every five minutes and keeps it in
# the set `router-wan`, and puts the last one back at once whenever the
# ruleset is reloaded, which empties the set.
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
  pkgs,
  ...
}:
let
  cfg = config.homeserver.tenants;
  enabled = cfg.vms != { };
  # False only when the table is switched off, as tests/tenant-net.nix does
  # for its negative control; the address has nowhere to go then.
  isolated = config.networking.nftables.tables.tenant-isolation.enable;
  tap = name: "vm-${name}";
  address = vm: "${cfg.subnet}.${toString vm.index}";

  # Puts the last known public address back, then looks it up again and
  # replaces it. A failed lookup leaves the last address in place. It fails
  # the unit, which posts, only once lookups have failed for 30 minutes since
  # boot or since the last success: the router's WAN comes up minutes after
  # its LAN after a power cut, and a short outage isn't worth a post. A VM
  # test, with no internet, never gets that far.
  routerWan = pkgs.writeShellScript "tenant-router-wan" ''
    set -euo pipefail
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.nftables
      ]
    }:$PATH
    state="$STATE_DIRECTORY/address"
    set=(inet tenant-isolation router-wan)
    valid() { grep -qxE '([0-9]{1,3}\.){3}[0-9]{1,3}' <<< "$1"; }
    if [ -s "$state" ] && valid "$(cat "$state")"; then
      nft add element "''${set[@]}" "{ $(cat "$state") }"
    fi
    if ! address=$(${cfg.routerWanCommand}) || ! valid "$address"; then
      echo "the lookup gave no IPv4 address: '$address'" >&2
      uptime=$(cut -d. -f1 /proc/uptime)
      last=$(stat -c %Y "$state" 2> /dev/null || echo 0)
      if [ "$uptime" -lt 1800 ] || [ $(($(date +%s) - last)) -lt 1800 ]; then
        echo "keeping the last address; trying again in 5 minutes" >&2
        exit 0
      fi
      echo "no successful lookup for 30 minutes" >&2
      exit 1
    fi
    nft flush set "''${set[@]}"
    nft add element "''${set[@]}" "{ $address }"
    echo "$address" > "$state"
    echo "router's public address closed to the tenant VMs"
  '';

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

    # DNS to the tenants' Blocky, the only service on the nuc a VM reaches.
    # The table below limits it to that Blocky's address.
    networking.firewall.interfaces = lib.mapAttrs' (
      name: _:
      lib.nameValuePair (tap name) {
        allowedUDPPorts = [ 53 ];
        allowedTCPPorts = [ 53 ];
      }
    ) cfg.vms;

    networking.nftables.tables.tenant-isolation = {
      family = "inet";
      content = ''
        set closed {
          type ipv4_addr
          flags interval
          elements = { ${lib.concatStringsSep ", " closed} }
        }

        # Filled by tenant-router-wan.service.
        set router-wan {
          type ipv4_addr
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
          iifname "vm-tenant-*" ip daddr @router-wan counter name "forward-drops" drop
          iifname "vm-tenant-*" oifname != "lan0" counter name "forward-drops" drop
          oifname "vm-tenant-*" ct state established,related return
          oifname "vm-tenant-*" counter name "forward-drops" drop
        }

        chain input {
          type filter hook input priority filter - 10; policy accept;
          iifname "vm-tenant-*" ct state established,related return
          iifname "vm-tenant-*" ip daddr ${cfg.hostAddress} meta l4proto { tcp, udp } th dport 53 return
          iifname "vm-tenant-*" counter name "input-drops" drop
        }
      '';
    };

    systemd.services.tenant-router-wan = lib.mkIf isolated {
      description = "Close the router's public address to the tenant VMs";
      # Runs once the ruleset is loaded, and again whenever it is reloaded
      # or restarted, which empties the set.
      wantedBy = [
        "nftables.service"
        "multi-user.target"
      ];
      after = [ "nftables.service" ];
      partOf = [ "nftables.service" ];
      unitConfig.ReloadPropagatedFrom = [ "nftables.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = routerWan;
        ExecReload = routerWan;
        StateDirectory = "tenant-router-wan";
      };
    };
    systemd.timers.tenant-router-wan = lib.mkIf isolated {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "5min";
        # A oneshot with RemainAfterExit would otherwise run only once.
        Unit = "tenant-router-wan-refresh.service";
      };
    };
    systemd.services.tenant-router-wan-refresh = lib.mkIf isolated {
      description = "Look up the router's public address again";
      serviceConfig = {
        Type = "oneshot";
        # A restart, not a reload: a failed reload leaves the unit active,
        # so OnFailure would never post. Stopping it doesn't touch the set.
        ExecStart = "${config.systemd.package}/bin/systemctl restart tenant-router-wan.service";
      };
    };
    homeserver.notify.units = lib.mkIf isolated [ "tenant-router-wan" ];
  };
}
