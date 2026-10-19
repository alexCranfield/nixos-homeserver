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
}
