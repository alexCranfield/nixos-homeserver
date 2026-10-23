# Docker, rootful, as ADR (Architecture Decision Record) 0006 decides; ticket
# 3.1 (#22). Compose stacks arrive as systemd units in 3.2 (#23).
#
# Docker publishes ports with NAT (network address translation) rules that run
# before the NixOS firewall, so a port Docker publishes on every interface is
# open to the LAN whatever the firewall says. The two settings below make a
# port published without an address bind to 127.0.0.1 instead, so forgetting
# closes a port rather than opening it. Docker keeps that default in two
# places, and both are needed:
#
#  - `ip` covers only the built-in `bridge` network, used by a bare
#    `docker run`;
#  - `default-network-opts` covers every bridge network created afterwards,
#    including the `<project>_default` network each Compose project creates.
#
# A network keeps the address it was created with, so changing either setting
# later does not move an existing network (docs/runbooks/docker.md).
#
# Nobody is in the `docker` group, ops included: membership is root without a
# password. Use `sudo docker`.
#
# Left at the NixOS defaults, on purpose: container logs go to journald, so
# journald's limits are their retention; the storage driver is the one Docker
# picks, recorded in the runbook. Compose is part of NixOS's Docker
# package, as the `docker compose` plugin.
{ ... }:
{
  virtualisation.docker = {
    enable = true;
    daemon.settings = {
      ip = "127.0.0.1";
      default-network-opts.bridge."com.docker.network.bridge.host_binding_ipv4" = "127.0.0.1";
      # A process in a container cannot gain privileges through a setuid
      # binary or file capabilities. An image that needs it opts out per
      # container with `security_opt: ["no-new-privileges=false"]`.
      no-new-privileges = true;
      # Containers keep running while the daemon restarts, which a deploy
      # does whenever Docker or these settings change. Off, every container
      # stops then, and only those with `restart: unless-stopped` or `always`
      # come back (measured on the nuc, 2026-10-23). A reboot stops them
      # either way. Published ports still miss new connections until the
      # daemon is back (docs/runbooks/docker.md). Docker supports it across
      # patch releases only. Not compatible with Docker Swarm, not used here.
      live-restore = true;
    };
    # `docker system prune --force` once a week: stopped containers, unused
    # networks, dangling images and dangling build cache. Not volumes, and not
    # tagged images, used or not. Stack data lives in bind mounts under
    # /srv/data (3.3, #24), which prune never touches.
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

  # The firewall drops forwarded traffic (modules/base/firewall.nix). Let
  # containers start connections out through their bridges, `docker0` and the
  # `br-<id>` of each network created later: pulling, updates, the NAS. A
  # network given its own `com.docker.network.bridge.name` is not covered.
  # Replies and published ports need no rule here.
  networking.firewall.extraForwardRules = ''
    iifname "docker0" accept
    iifname "br-*" accept
  '';
}
