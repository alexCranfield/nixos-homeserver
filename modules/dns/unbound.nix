# Unbound, the recursive resolver behind Blocky, ticket #164.
#
# Asks the root, TLD (top-level domain) and authoritative servers itself, so
# no public resolver sees the house's lookups, and validates DNSSEC (DNS
# Security Extensions) signatures with the root trust anchor. It answers
# Blocky alone, on 127.0.0.1 (./default.nix).
#
# Settings checked against unbound.conf(5) of Unbound 1.26.1.
{
  config,
  lib,
  ...
}:
let
  cfg = config.homeserver.dns;
in
{
  options.homeserver.dns.insecureDomains = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "broken-dnssec.example" ];
    description = ''
      Real domains whose DNSSEC is broken by their owner, so validation
      fails and they don't resolve. Unbound skips validation for these
      (`domain-insecure`) and keeps enforcing it everywhere else. Added by
      hand when one breaks, never pre-emptively.
    '';
  };

  config = lib.mkIf (cfg.listenAddresses != [ ]) {
    services.unbound = {
      enable = true;
      # The nuc's own resolver stays the router (hosts/nuc/network.nix).
      resolveLocalQueries = false;
      # DNSSEC validation: fetch and keep the root key up to date. Enforced:
      # a bogus answer is SERVFAIL, never passed on (no val-permissive-mode).
      enableRootTrustAnchor = true;
      # The control socket, for the Prometheus exporter (Task 6): point
      # `services.prometheus.exporters.unbound.unbound.host` at
      # "unix:///run/unbound/unbound.ctl" and set its `ca`, `certificate`
      # and `key` to null, as a local socket uses no TLS. The exporter runs
      # as the unbound user, which owns the socket.
      localControlSocketPath = "/run/unbound/unbound.ctl";
      settings.server = {
        interface = [ "127.0.0.1@${toString cfg.unboundPort}" ];
        access-control = [ "127.0.0.0/8 allow" ];
        # Two threads; the caches' slabs are left to Unbound, which sets
        # them to a power of two near the thread count.
        num-threads = 2;
        # Room for the house's names well beyond the 4 MB defaults.
        msg-cache-size = "64m";
        rrset-cache-size = "128m";
        # Refresh popular names before they expire.
        prefetch = true;
        # Serve stale answers when the authoritative servers can't be
        # reached (RFC 8767: Request for Comments 8767, serve-stale): try for
        # a fresh answer for 1.8 seconds first, and never serve one expired
        # more than a day. Both are 1.26's defaults, set so they stay put.
        serve-expired = true;
        serve-expired-ttl = 86400;
        serve-expired-client-timeout = 1800;
        # Answer "no such name" from the signed NSEC (Next Secure) records
        # already cached, without asking again. Also 1.26's default.
        aggressive-nsec = true;
        # DNS rebinding protection: a public name may not answer with a
        # private address, which would let a web page reach devices on the
        # LAN through the browser. home.arpa and the LAN's reverse names go
        # from Blocky to the router, not here, so they keep theirs.
        private-address = [
          "10.0.0.0/8"
          "172.16.0.0/12"
          "192.168.0.0/16"
          "169.254.0.0/16"
          "fd00::/8"
          "fe80::/10"
        ];
        # Say in the journal why a lookup failed, DNSSEC failures included.
        log-servfail = true;
        # Per-type and per-code counters for the exporter.
        extended-statistics = true;
        domain-insecure = map (domain: ''"${lib.removeSuffix "." domain}."'') cfg.insecureDomains;
        # NXDOMAIN (no such name) tells Firefox not to switch on its own DNS
        # over HTTPS, which would go around the blocking. Pi-hole answered
        # this by default.
        local-zone = [ ''"use-application-dns.net." always_nxdomain'' ];
      };
    };
  };
}
