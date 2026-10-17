# The nuc's LAN (local area network) connection, ticket 1.4 (#11).
#
# Two Intel 2.5 GbE (gigabit Ethernet) ports, surveyed in #8. The server uses
# the I226-V; the I226-LM is the variant that usually carries Intel AMT (Active
# Management Technology) remote management, so it stays down and unplugged.
#
# The address comes from the router: a DHCP (Dynamic Host Configuration
# Protocol) reservation for the I226-V's MAC (hardware) address, and the name
# nuc.home.arpa, both set on the UniFi Dream Router 7. See
# docs/runbooks/network.md.
{ ... }:
let
  # From the hardware survey (#8). The kernel's names for these, enp45s0 and
  # enp44s0, come from the PCI (Peripheral Component Interconnect) slot, so
  # they are matched by MAC address instead.
  lanMac = "9c:6b:00:5c:46:52"; # I226-V
  unusedMac = "9c:6b:00:5c:46:51"; # I226-LM
in
{
  # systemd-networkd rather than NixOS's scripted networking: the port is
  # matched by MAC address, named and configured in plain systemd files.
  networking.useNetworkd = true;
  # No DHCP on every interface by default; only lan0 below asks for an address.
  networking.useDHCP = false;
  networking.domain = "home.arpa";

  # Rename the server port to lan0, so the firewall and anything else can refer
  # to it by a name that does not depend on which slot the kernel found it in.
  systemd.network.links."10-lan" = {
    matchConfig.PermanentMACAddress = lanMac;
    linkConfig.Name = "lan0";
  };

  systemd.network.networks."10-lan" = {
    matchConfig.Name = "lan0";
    # IPv4 from the router's reservation. IPv6 router advertisements are left
    # at networkd's default, so the port also takes an IPv6 address if the
    # router offers one; the firewall covers both.
    networkConfig.DHCP = "ipv4";
    # Boot waits for this port alone, not for the unused one.
    linkConfig.RequiredForOnline = "routable";
  };

  # The I226-LM: held down, so nothing configures it even if a cable goes in.
  # AMT runs in firmware below the OS and is not stopped by this; keeping the
  # port unplugged is what stops it.
  systemd.network.networks."10-unused" = {
    matchConfig.PermanentMACAddress = unusedMac;
    linkConfig = {
      ActivationPolicy = "always-down";
      # systemd forces this for an always-down link anyway; said here so
      # boot visibly does not wait for this port.
      RequiredForOnline = "no";
    };
  };

  # SSH from the LAN as well as the tailnet (modules/base/tailscale.nix), until
  # the nuc joins the tailnet by itself: its auth key is a secret it can only
  # decrypt from ticket 1.7 (#14), which removes this. ADR 0005.
  networking.firewall.interfaces.lan0.allowedTCPPorts = [ 22 ];
}
