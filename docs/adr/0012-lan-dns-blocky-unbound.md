# ADR 0012: The LAN's DNS is Blocky in front of Unbound on the nuc, declared in Nix

Date: 2026-10-30. Status: accepted.

## Context

The house's LAN (local area network) has one DNS (Domain Name System) server, which is a Pi-hole container on the NAS
(network-attached storage), set up by hand. DHCP (Dynamic Host Configuration
Protocol), on the router, hands out that one server and no second one, so
every device depends on it, and so do the nuc's Discord alerts and the NAS's
own alert emails. A broken Pi-hole can silence the alert that would report it.
Its blocklists and settings live in a web page and in the NAS, not in a
repository, so nothing says what they should be, and the NAS cannot be
rebuilt without taking the house offline.

Ticket #164 moves the server to the nuc, with the NAS's Pi-hole left as the
secondary. The design is in
`docs/superpowers/specs/2026-10-29-lan-dns-design.md`. Alex wants to see, out
of curiosity, which devices are noisy and whether anything makes suspicious
connections, so the query view matters as much as the yes or no of "is
blocking working".

## Decision

1. **Blocky answers the LAN** on port 53 of the nuc's LAN address, UDP (User
   Datagram Protocol) and TCP (Transmission Control Protocol), and only on
   `lan0`. It blocks the six blocklists the Pi-hole used, answers the local
   names declared in Nix and the private ones from sops, and sends the rest
   to Unbound.
2. **Unbound resolves recursively** behind it, on 127.0.0.1, from the root
   servers, with DNSSEC (DNS Security Extensions) validation enforced,
   prefetch and serve-expired. There is no encrypted upstream: the lookups go
   from the nuc to the authoritative servers, so no single resolver sees all
   of them.
3. **Both are native NixOS services** (`services.blocky`, `services.unbound`),
   not containers. ADR (Architecture Decision Record) 0006 keeps Docker for the game servers.
4. **Blocky's query log goes to a local PostgreSQL** over its socket with peer
   authentication, so there is no password and no new secret. Grafana reads
   it with a read-only role. The log keeps 14 days, with a size cap.
5. **The configuration is all in the repo.** The blocklists are plain Nix
   (public URLs; encrypting them would hide nothing and make every change an
   unreadable diff). Only the private local names and the NAS's address are in
   sops (`secrets/dns.yaml`), because the NAS's name and address never enter
   this public repository.
6. **The nuc and the NAS resolve through the router,** not through either
   blocking server, so the paths that raise alerts never depend on the server
   they watch.
7. **The NAS keeps its Pi-hole as the secondary,** unchanged, until it moves
   to NixOS and runs the same module.
8. **DNS watching goes through the existing alerting** (#27): the servers'
   health, blocking, threat-list hits, bursts of "no such name" answers and
   new devices. Details are in `docs/runbooks/dns.md`.

### Why Blocky, and not Pi-hole or AdGuard Home

| | Pi-hole | AdGuard Home | Blocky |
|---|---|---|---|
| Configuration | A web page and its database; v6 accepts more settings as files, but not clearly the blocklists | A web page; a NixOS module exists, but a setting changed in the page is lost at the next restart once the rest is declared | All of it in Nix (`services.blocky`); nothing to click, nothing to drift |
| Runs as | A Docker stack on the nuc | A NixOS service | A NixOS service |
| Metrics | Needs an exporter | Needs an exporter | Prometheus metrics built in |
| Query view | Its own page | Its own page, with an "allow" button | None of its own: a PostgreSQL log read in Grafana, beside the other dashboards |
| State needed to answer | A database | A database | None |
| Same module on the NAS later | No | Possible | Yes |

What is given up is the web page: unblocking a site is a one-line change in
the repo, merged and deployed by comin, rather than a click. The query log
needs a small PostgreSQL, one more service to run. Alex looks at the blocking
for curiosity, not to fix broken sites, so Grafana serves the use.

Unbound over a forwarder: forwarding every lookup to one public resolver over
TLS (Transport Layer Security) would hand the whole household's lookups to
one company. Recursing from the root servers asks each authoritative server
only about its own names.

## Consequences

- Blocking, names and settings are reviewed in pull requests and tested in a
  VM (virtual machine) test, `tests/dns.nix`, with a negative control for each
  check. The recursion and DNSSEC cannot be tested there, since the VM has no
  internet; they are checked on the nuc after deploy
  (`docs/runbooks/dns.md`).
- The query log holds the whole household's browsing. It stays on the nuc,
  keeps 14 days, is readable by Blocky, Grafana and the alert queries alone,
  and the household is told it exists. It is not backed up: the backups
  ticket (#26) must exclude `/var/lib/postgresql`.
- The monitoring sees most lookups, not all. Devices that send some of their
  lookups to the NAS secondary leave no trace in the log until the NAS runs
  this module.
- Failover is not instant. While the nuc reboots, many devices wait a second
  or two on it before asking the NAS, so the network feels slow for a few
  minutes, mostly on Tuesday mornings.
- Blocky 0.29 reads hosts files, domain lists and `*.` wildcards, but only
  half-reads the adblock syntax (`||name^`). Two of the Pi-hole's lists were
  swapped for the same lists in a format Blocky reads in full
  (`modules/dns/lists.nix`).
- DNSSEC is enforced. A real domain whose owner has broken its signatures
  stops resolving until someone adds it to `homeserver.dns.insecureDomains`.
- Blocky starts without waiting for its lists, so at boot it resolves first
  and blocks a few seconds later (fail open). If PostgreSQL is down at its
  start it logs to the console instead and a timer restarts it onto the
  database within about five minutes. DNS availability beats the log.
- Port 53 is open on `lan0` only, never on the tailnet. DNS for devices away
  from home, which would reverse that, is a separate decision.
- IPv4 only. The router hands out no IPv6 DNS server today. Turning IPv6 on
  at the router would advertise the router itself as one, a leak that breaks
  nothing visibly, so it is done together with a change here (#175).
- Some devices have DNS servers built in. The router's rules that block
  outbound DNS on ports 53 and 853 force them through the nuc; DNS over
  HTTPS (Hypertext Transfer Protocol Secure) cannot be blocked that way and
  is accepted.
