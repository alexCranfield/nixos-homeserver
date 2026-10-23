# Default-deny firewall on every host, ticket 1.4 (#11).
#
# Nothing is open here. A port is opened next to whatever needs it, on the
# interface it is needed on: SSH on tailscale0 in modules/base/tailscale.nix,
# for example. ADR 0005: admin access moves to Tailscale, and only game ports
# are forwarded from the internet.
#
# Docker's published ports bypass this firewall (ADR 0006), so it is not the
# whole story once containers arrive.
{
  networking.firewall.enable = true;
  # The nftables backend rather than iptables: one ruleset, readable with
  # `nft list ruleset`.
  networking.nftables.enable = true;
  # Drop forwarded traffic too, unless a rule allows it. The nuc routes for
  # nothing, but Docker turns IPv4 forwarding on (NixOS sets the sysctl at
  # boot, so Docker leaves its own FORWARD policy at accept), which would
  # otherwise let a neighbour route through the nuc between the LAN, the
  # tailnet and the container bridges. Replies, and traffic Docker has
  # redirected to a published port (`ct status dnat`), are allowed by NixOS's
  # own rules; what else may be forwarded is added beside its cause, as in
  # modules/containers/docker.nix.
  networking.firewall.filterForward = true;
}
