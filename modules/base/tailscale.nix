# Admin access over the tailnet, ticket 1.5 (#12) and ADR (Architecture
# Decision Record) 0005.
#
# SSH stays OpenSSH (ssh.nix): keys only, no root. Tailscale carries it, and
# Tailscale SSH is not turned on, so a login still needs the ops key even from
# a device already on the tailnet.
#
# The join itself, `services.tailscale.authKeyFile`, is set by the host from its
# sops secret in ticket 1.7 (#14), once the host can decrypt one: a host that
# declares a secret it cannot decrypt fails the rebuild (see default.nix). Until
# then the daemon runs logged out, and SSH on the LAN (local area network) is
# the way in; #14 removes it.
{
  services.tailscale = {
    enable = true;
    # Left at "none", not "client": "client" loosens reverse-path filtering so
    # the machine can use exit nodes and subnet routes, and the nuc uses
    # neither.
    useRoutingFeatures = "none";
    # Keep the server's own DNS (Domain Name System) on the router, so name
    # lookups do not depend on Tailscale being up. Other devices still reach it
    # by its MagicDNS name. Applied by `tailscale up`, so only once a host sets
    # authKeyFile.
    extraUpFlags = [ "--accept-dns=false" ];
  };

  # SSH only, rather than `trustedInterfaces = [ "tailscale0" ]`, which would
  # open every port to the tailnet. Admin web interfaces will reach it through
  # Tailscale Serve (ADR 0006), not through open ports.
  #
  # The firewall does not see everything that arrives over the tailnet.
  # tailscaled answers some TCP (Transmission Control Protocol) ports on the
  # tailnet address itself, inside its own network stack, so those packets
  # never reach nftables: its peer API (application programming interface; a
  # random port, always on), and Tailscale SSH and Serve when turned on. The
  # tailnet's access policy limits SSH and Serve; the peer API it lets through
  # on purpose, and checks each request itself (docs/runbooks/tailscale.md).
  # tests/tailscale.nix checks that the peer API is the only such port, and
  # that it refuses a device with no access.
  #
  # Tailscale's own UDP (User Datagram Protocol) port, 41641, stays closed.
  # Direct connections usually still form, since the nuc sends first and the
  # firewall lets the replies back in; when they do not, traffic goes through
  # Tailscale's DERP (Designated Encrypted Relay for Packets) servers, slower
  # but working.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 22 ];
}
