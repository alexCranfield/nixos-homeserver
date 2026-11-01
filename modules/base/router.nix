# The LAN's (local area network's) router, as an option other modules read.
#
# The router is the default gateway and also the DNS (Domain Name System)
# server that knows the LAN's own names, such as nuc.home.arpa. One option
# holds its address, so the gateway ping in modules/observability/probes.nix,
# the nuc's own resolver (hosts/nuc/network.nix) and the LAN DNS server's
# forwarding of home.arpa names all agree on it.
{ lib, ... }:
{
  options.homeserver.network.router = lib.mkOption {
    type = lib.types.str;
    default = "192.168.1.1";
    description = ''
      The router's address on the LAN: the default gateway, and the DNS
      server for the LAN's own names.
    '';
  };
}
