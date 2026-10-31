# Networking: the LAN, Tailscale and DNS

The LAN (local area network), the tailnet Tailscale builds over it, and the
names that point at the nuc.

### Should Tailscale SSH be turned off?

*2026-10-18*

> Should I disable tailscale ssh?

<details>
<summary>Answer</summary>

It was never on for the nuc: a device runs Tailscale SSH only when started with
`tailscale up --ssh`, the nuc's configuration does not do that, and the VM
(virtual machine) test asserts `RunSSH` is false. Nothing else here can serve
it either: Windows and Android are only Tailscale SSH clients.

The access policy's `"ssh"` section, which decides who may log in to devices
that do run it, was emptied anyway (`"ssh": []`). Tailscale SSH logs in with
the Tailscale identity rather than the ops key, and `tailscaled` answers it
itself, so the firewall never sees it. With no rules, even a mistaken
`tailscale set --ssh` would let nobody in. There is no tailnet-wide switch;
being opt-in per device, the empty rule list is the equivalent.

</details>

### What is the tailnet name, and can the nuc have a domain name of my own?

*2026-10-18*

> What do you mean by tailnet name? The assigned IP? Can I assign a local
> domain name?

<details>
<summary>Answer</summary>

Not the IP. The tailnet name is the DNS (Domain Name System) suffix Tailscale
gives the whole tailnet, of the form `tail1a2b3c.ts.net`, shown on the admin
console's DNS page; each device's full MagicDNS name sits under it, such as
`nuc.<tailnet name>.ts.net`.

MagicDNS names always end in `.ts.net`, so a domain of your own is not
possible there; the console only offers to swap the random suffix for a
generated word pair. The short form comes from elsewhere: a `Host nuc` alias in
the workstation's `~/.ssh/config` pointing at the full name, which is what
`ssh nuc` and `just deploy` use. The full name beats the 100.x address for
that, because it survives a reinstall, while the address belongs to the device
entry.

The name stays out of this public repository: it identifies the tailnet.

</details>

### Is it a problem that the console says the nuc's Tailscale is out of date?

*2026-10-18*

> Our tailscale vbersion is apparently out of date on the nuc

<details>
<summary>Answer</summary>

Not on its own. The nuc runs 1.98.10 because that is what NixOS 26.05's stable
branch ships, today and not only in this repo's lock file, so updating
`flake.lock` would not change it. Upstream was at 1.104.1. Stable branches take
a new upstream version for security fixes that matter broadly, and otherwise at
the next release.

The question that matters is whether the newer versions fix anything that
applies. Tailscale's 2026 bulletins after 1.98.9 were two: TS-2026-010 needs
Tailscale SSH, which the nuc does not run, and TS-2026-011 needs 4via6 subnet
routing, which it does not do. Taking Tailscale from `nixos-unstable` instead
would mean a second nixpkgs input and a network daemon built outside the stable
set: more risk than the console's notice is worth. Revisit when a bulletin
affects plain clients.

</details>

### Could sops keep the tailnet's name private if Grafana used HTTPS through Serve?

*2026-10-27*

> Could we encrypt the DNS with Sops? Similar to the Minecraft usernames and webhooks?

<details>
<summary>Answer</summary>

No. The name wouldn't leak from the repo; Serve's configuration needs only
ports. It leaks from the certificate. To serve HTTPS, Tailscale gets a Let's
Encrypt certificate for `nuc.<tailnet name>.ts.net`, and every public CA
(certificate authority) must record what it issues in the Certificate
Transparency logs, which anyone can search (crt.sh, for example). Once the
certificate exists, the name is public, whatever is encrypted on our side.

The name alone doesn't let anyone in: the tailnet still needs a login and the
access policy. But keeping it private is the rule here, so Grafana uses Serve
over plain HTTP. There's no certificate, and the traffic is still encrypted end
to end by Tailscale's WireGuard tunnel; the browser's "Not secure" label is the
only cost.

</details>

### Could our own DNS server give the admin pages HTTPS?

*2026-10-27*

> Could we not use a self hosted DNS like the nas on the tailscale network to have our own https? Like unbound or technitium?

<details>
<summary>Answer</summary>

Half of it. A DNS (Domain Name System) server on the tailnet, with Tailscale's
split DNS pointing a domain at it, gives the nuc a private name such as
`grafana.home.arpa`. HTTPS also needs a certificate the browser trusts, and
there are two ways to get one without the tailnet's name going public:

- **A private CA** (certificate authority) on the nuc, such as Caddy's
  built-in one or step-ca. Nothing is published, but every device that opens
  the pages has to install its root certificate.
- **A domain you own.** Let's Encrypt issues a wildcard certificate, proved
  through the DNS provider's API. The public logs show only the wildcard, and
  every device trusts it with nothing to install. It costs a domain and an API
  token in sops.

Either way a reverse proxy on the nuc replaces Serve, with 443 open on
`tailscale0` only. Tracked in #163, alongside moving the LAN's DNS to the nuc
(#164), so that one DNS server does both jobs.

</details>

### Can the DNS alerts still arrive when the DNS server is down?

*2026-10-29*

> I get alert emails, but if the DNS is down I'm not sure that'll work

<details>
<summary>Answer</summary>

The worry is right. Whatever reports a DNS (Domain Name System) failure must
not need that DNS server to send the report: an alert looks up its
destination's name before it sends anything, so with the only DNS server
down, the alert can fail with no error anyone sees. Both the alert emails sent from the NAS (network-attached storage) and
the nuc's Discord posts were in that position, because both
resolved through the Pi-hole.

The fix in #164 is to break the loop. The nuc ignores the DNS server DHCP
(Dynamic Host Configuration Protocol) offers and resolves through the router,
and the NAS is changed to do the same, so neither alert path depends on the
server it watches. Each server is also probed separately from the nuc.

</details>

### Are there other projects like Pi-hole and Unbound worth adding?

*2026-10-29*

> Are there any other open source/useful projects like pihole and unbound we can add to our networking setup? Anything that improves speed, efficiency, privacy, etc?

<details>
<summary>Answer</summary>

A few, and most fit inside #164:

- **DNSSEC (DNS Security Extensions) validation in Unbound.** It checks the
  signatures on answers, so a forged one is rejected. Free once Unbound runs.
- **Prefetch and serve-expired.** Prefetch refreshes popular names just
  before they expire; serve-expired answers at once from a slightly stale
  copy while a fresh one is fetched. The gain here is small: about
  two-thirds of the house's lookups were already answered from the Pi-hole's
  cache.
- **Stopping browsers going around the blocking.** Firefox and Chrome can
  send DNS to a public resolver over HTTPS (Hypertext Transfer Protocol
  Secure), skipping the blocking. Answering NXDOMAIN (no such name) for
  `use-application-dns.net` tells Firefox not to. Pi-hole does it by default;
  Blocky has to be told.
- **Checking IPv6.** If the router advertises its own DNS server over IPv6,
  some devices bypass the blocking unseen.
- **Metrics:** query rate, share blocked, cache hits, upstream time, in
  Grafana.

Better as its own ticket: blocking for phones away from home, by pointing
tailnet devices at the nuc. It reverses #164's "port 53 not on the tailnet",
so it is a deliberate separate decision.

Not worth it: encrypting the upstream (DNS over TLS, Transport Layer Security, to a public resolver).
Unbound already stops one provider seeing every lookup; forwarding over TLS
would hand them all to a different one. Seeing actual connections, not just
lookups (ntopng, Zeek), needs the house's traffic copied to the nuc, which is
a different project.

</details>

### Is Blocky a better choice than Pi-hole?

*2026-10-29*

> I do occasionally check it to see what's being blocked, is blocky a better solution?

<details>
<summary>Answer</summary>

For this setup, yes, and the "what's being blocked" view moves to Grafana.

- **The whole configuration is Nix** (`services.blocky`): lists, local names
  and upstreams are in the repo. Nothing is changed by clicking, so nothing
  drifts, and the NAS can later run the same module.
- **It exports its own Prometheus metrics**, so the dashboard and the "is it
  blocking" alert need no extra exporter.
- **It has no state it needs to answer**, and restarts in a second or two.
- **What was in the Pi-hole's page** becomes panels over Blocky's query log in
  PostgreSQL: busiest devices, top blocked names, one device's lookups.

The costs: the query log needs a small PostgreSQL on the nuc, and unblocking
a site is a one-line change in the repo rather than a click.

AdGuard Home sits between them: a web page and a NixOS module, but once the
rest is declared, a setting changed in the page is lost at the next restart,
so the page ends up for looking at. Pi-hole as a Docker stack is the option
Alex already knows; I was not sure its blocklists could be declared as
configuration at all.

Recorded in [ADR 0012](../adr/0012-lan-dns-blocky-unbound.md).

</details>

### Do the blocklists belong in sops?

*2026-10-29*

> Blocky and unbound sounds perfect. Can you see the block lists I've loaded on the pihole? And should we encrypt these in sops?

<details>
<summary>Answer</summary>

No. They are public URLs anyone can look up, so encrypting them hides
nothing, makes every change an unreadable encrypted diff, and stops CI
(continuous integration) validating them. They go in the repo as plain Nix.

What does need protecting:

- **Private local names**, such as the NAS's own name, which this public repo
  never holds. They go in a sops secret that Blocky reads at start, never
  through the Nix store.
- **The query log**, which holds every device's browsing. It stays on the nuc,
  readable only by Blocky and Grafana, and is never in the repo.

The first plan also had a database password in sops. The built design needs
none: PostgreSQL uses its local socket and maps the operating-system user to
the database role, so there is no password to store.

</details>

### Is IPv6 worth turning on at the router?

*2026-10-29*

> I think later we can turn on ipv6 from the router, would it be worth it to?

<details>
<summary>Answer</summary>

It would bring something, but not much for this house. Some devices could
reach some sites directly instead of through the router's address
translation, which is occasionally a little quicker, and Tailscale finds
direct connections more easily. The games already go over Tailscale and IPv4
works, so neither matters much here.

It matters for DNS because UniFi, once IPv6 is on, normally advertises the
router itself as an IPv6 DNS server. Devices then have two routes for
lookups, and any sent to the router skip the blocking and never reach the
query log, with nothing visibly broken. So three things must happen together:

1. Blocky listens on a fixed IPv6 ULA (unique local address) for the nuc, not
   one from the ISP's (internet service provider's) prefix, which can change.
2. The router advertises that address as the IPv6 DNS server instead of
   itself.
3. A check that nothing new is reachable from outside; the firewall already
   covers IPv6, and the router blocks incoming IPv6 by default.

#164 stays IPv4-only but keeps Blocky's listen addresses in one list option,
so adding IPv6 is one line plus the router setting. The rest is #175.

</details>

### How can the network watch for suspicious connections, beyond the router's own detection?

*2026-10-29*

> I'm also wondering if we can set up some form of sentry/monitor checking for suspicious connections. My unifi router does that somewhat already, but could we check internally within the network? I suppose the DNS block lists sort of do this, but they're not explicitly monitored

<details>
<summary>Answer</summary>

Three layers, cheapest first:

1. **Alerts from the DNS query log (built in #164).** The blocklists already
   stop known-bad names, but nobody is told when one is hit. The lists are
   split into `ads` (hits are normal and only counted) and `threats` (a hit
   means a device tried to reach known malware, phishing or
   command-and-control). Alerts name the device: a threat-list hit; a burst of
   NXDOMAIN answers, which malware generating random domain names to find its
   controller produces (broken devices do too); and a client address the log
   has never seen. Prometheus cannot query PostgreSQL, so a timer writes the
   counts to a text file node-exporter serves.
2. **The router's own detection (#176).** UniFi's threat management inspects
   real connections, which DNS cannot see: a device connecting straight to an
   address with no lookup. It can send events to a syslog server, so the nuc
   could alert on and graph them. What the Dream Router 7 exports is the
   first thing that ticket checks.
3. **Inspecting all traffic on the nuc (Zeek, Suricata).** Needs the traffic
   mirrored to the nuc, which means a managed switch. Only worth it if layers
   1 and 2 leave a real gap.

DNS only sees lookups that reach the nuc: those sent to the NAS secondary are
a blind spot until the NAS runs the same module.

</details>

### Are there other blocklists worth adding?

*2026-10-29*

> Are there any other block lists we should seek to add

<details>
<summary>Answer</summary>

A couple, but after the move rather than during it, and one finding affects
the move itself. Two of the Pi-hole's lists are in adblock syntax
(`||example.com^`): HaGeZi's Threat Intelligence Feeds and DandelionSprout's
anti-malware list. Blocky reads hosts files and plain domain lists, not that
syntax, so they would block nothing, or only half. Both projects publish the
same lists in plain formats, and a test fails if a list loads empty, so those
were swapped in the move.

Worth changing a week after the cutover, so the query log shows what is newly
blocked:

- **HaGeZi Multi Pro** replaces StevenBlack, EasyList and EasyPrivacy, which
  overlap heavily: one list instead of three, daily updates, few false
  positives.
- **HaGeZi's native tracker lists** for the devices in the house (Windows and
  Office, Apple), which block telemetry sent to the makers. This also lets
  them replace WindowsSpyBlocker.

Left out: more threat lists, since HaGeZi's already combines the well-known
feeds, and newly registered domains, which catch phishing but also break
legitimate new sites.

Not blocked, deliberately: Google devices (their telemetry shares domains
with their services, which is why HaGeZi publishes no Google list),
Nintendo consoles and the smart bulbs, whose apps need the cloud. These are
watched on the dashboard instead, which is where the noisiest cheap devices
show up. A separate IoT (Internet of Things) network for them is #177.

</details>
