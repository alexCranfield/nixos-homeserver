# Tenant VMs

The tenant's dev environment and job runner, two microVMs (virtual machines)
on the nuc: `tenant-dev` and `tenant-run`. Why they are VMs, and what they may
reach, is ADR (Architecture Decision Record) 0013. The code is in
`modules/tenants/` and `hosts/nuc/tenants.nix`.

This runbook grows with tickets 6.7 to 6.12 (#197 to #202). So far: the VMs
(6.8), their network and the state directory (6.7). What runs in each comes
in 6.9 (the runner) and 6.10 (the dev environment).

## The VMs

| VM | vCPU | RAM | `/var` | Host-side memory ceiling |
|---|---|---|---|---|
| `tenant-dev` | 4 | 8 GB | 60 GB | 9 GB |
| `tenant-run` | 2 | 4 GB | 30 GB | 5 GB |

Each is a microvm.nix guest on qemu, built from `modules/tenants/guest-base.nix`
and run by `microvm@<name>.service`, which starts at boot. A VM's CPU and I/O
weights are half the default, so the game servers and LLMs win any
contention. A VM that fails posts to Discord.

```bash
systemctl status microvm@tenant-dev
sudo systemctl restart microvm@tenant-dev   # a reboot of the VM
journalctl -u microvm@tenant-dev            # qemu's side; the guest's own log is inside it
```

**Inside a VM:**
- **Root:** the root filesystem is tmpfs, rebuilt from the configuration at every boot.
- **What persists:** only `/var`, an ext4 image at `/var/lib/microvms/<name>/var.img` on the host. That covers the SSH host keys (`/var/lib/ssh`), the journal, and later Docker and the tenant's work.
- **Store:** the host's `/nix/store` is shared in read-only, so a deploy updates the VM's software, and the VM restarts when its configuration changes.

**SSH in.** A VM accepts SSH from the nuc's address alone, so go through the nuc:

```bash
ssh -J ops@nuc ops@10.88.0.2     # tenant-dev
ssh -J ops@nuc ops@10.88.0.3     # tenant-run
```

**Secrets** reach a VM as systemd credentials:
- The host names a file per credential (`microvm.credentialFiles` in the VM's configuration), and qemu passes it in. qemu runs as the `microvm` user, so a host-side secret must be readable by that user.
- Inside, the credential sits in `/run/credentials/@system`, readable by root. A unit that declares `LoadCredential=<name>` gets its own copy, readable by that unit alone.
- Until 6.9 and 6.10 the only one is `probe`, which isn't a secret; `tenant-credential-check.service` reads it to show the path works.

**Smoke test.** From the workstation, after any change to the tenant
network, firewall or DNS:

```bash
just tenant-smoke
```

This runs `modules/tenants/smoke.sh` inside each VM. That VM must reach:
- the internet;
- its own Blocky, which blocks ads and returns NXDOMAIN (no such name) for every LAN name.

It must not reach:
- the LAN's Blocky;
- the router, including its console on the public address;
- the nuc's SSH, on both the tenant network and the tailnet;
- a Docker published port;
- the other VM;
- the LAN by ping.

The recipe exits non-zero if any probe goes the wrong way.

## The network

| VM | Tap on the host | Address | Gateway |
|---|---|---|---|
| `tenant-dev` | `vm-tenant-dev` | 10.88.0.2/32 | 10.88.0.1 |
| `tenant-run` | `vm-tenant-run` | 10.88.0.3/32 | 10.88.0.1 |

The taps are routed, not bridged. The host holds 10.88.0.1/32 on each, with
a route to the VM's /32, and masquerades 10.88.0.0/24 out of `lan0`. A tap
exists only while its VM runs; boot doesn't wait for one.

A VM reaches the internet, and port 53 on 10.88.0.1, the tenants' own
Blocky (below). Nothing else, IPv4 only. The `tenant-isolation` nftables
table drops the rest:

```bash
sudo nft list table inet tenant-isolation
sudo nft list counter inet tenant-isolation forward-drops
sudo nft list counter inet tenant-isolation input-drops
```

- **forward**: private, shared (100.64/10, the tailnet's), link-local,
  multicast and reserved destinations, so the LAN (local area network), the
  router, Docker's networks and published ports, the tailnet and the other
  VM; the router's public address (below); any exit but `lan0`; all IPv6;
  and new connections to a VM.
- **input**: everything to the nuc itself except DNS (Domain Name System) to
  10.88.0.1, the LAN's Blocky included.

The table only drops. What a VM may do is opened in the usual places: port
53 on each tap in NixOS's firewall, and the forward accept `networking.nat`
adds. A port opened later to every interface still doesn't reach a VM.

Never name a new interface `br-…`: Docker's forward rule accepts all traffic
from those (`modules/containers/docker.nix`). VM names must start
`tenant-`, which the rules match and the flake check `tenant-names` enforces.

A rising drop counter means a VM tried something it may not. To see what, log
the drops for a while:

```bash
sudo nft insert rule inet tenant-isolation forward iifname '"vm-tenant-*"' log prefix '"tenant-drop "'
sudo journalctl -kf | grep tenant-drop
# remove it again (the handle is the number `nft -a` prints):
sudo nft -a list chain inet tenant-isolation forward
sudo nft delete rule inet tenant-isolation forward handle <n>
```

The next deploy also puts the table back as declared.

### The router's public address

The router answers on its public (WAN, wide area network) address from
inside the LAN, its console included, so that address is dropped too. It
changes, so it isn't in the configuration: `tenant-router-wan.service`
looks it up from Cloudflare's trace page (`https://1.1.1.1/cdn-cgi/trace`)
every five minutes and keeps it in the set `router-wan`. A reload of the
ruleset, as on every deploy that changes it, empties the set, and the
service puts the last address back at once from
`/var/lib/tenant-router-wan/address`.

```bash
sudo nft list set inet tenant-isolation router-wan   # one address
systemctl status tenant-router-wan.service
sudo systemctl reload tenant-router-wan.service       # look it up now
```

A failed lookup leaves the last address in place. Once lookups have failed
for 30 minutes since boot or since the last success, the unit fails, which
posts to Discord; a short outage, or the router's WAN coming up a few
minutes after its LAN after a power cut, doesn't. Between a change of
address and the next good lookup, the new address is open to the VMs.

### DNS

The VMs have a Blocky of their own, `blocky-tenant`, on 10.88.0.1 (also on
the dummy interface `tenant-dns`, so it can start before any VM). It has the
LAN Blocky's lists and asks the same Unbound, but answers none of the LAN's
names: no local records, no private hosts file, nothing forwarded to the
router. The LAN Blocky answers those before any per-client blocking, reverse
lookups included, so a VM that could ask it could read back the house's
device names; the VMs can't reach it.

It writes to the same query log, so the VMs show in the dashboard and the
DNS alerts as `tenant-dev` and `tenant-run`. The first lookups from each fire
`DnsNewClient` once.

```bash
systemctl status blocky-tenant.service
nix shell nixpkgs#dnsutils -c dig @10.88.0.1 example.com   # from the nuc, which has no dig
```

## The state directory

microvm.nix keeps each VM's runner and disk images under
`/var/lib/microvms`. It is its own btrfs subvolume with copy-on-write off
(NOCOW), so the images don't fragment, and it is left out of snapshots of
the root and of backups: no customer data from the tenant's jobs reaches the
NAS (network-attached storage).

`microvm-state.service` checks both when a VM first starts; every
`microvm@` unit requires it. If it fails, the VMs don't
start and the failure posts to Discord. To check by hand at any time:

```bash
sudo microvm-state-check
```

Never `systemctl restart microvm-state`: the restart passes on to every VM
that requires it. A deploy doesn't restart it either.

If the directory became a plain one, with no VMs on it yet:

```bash
sudo rmdir /var/lib/microvms        # refuses if anything is inside
sudo systemd-tmpfiles --create --prefix=/var/lib/microvms
sudo microvm-state-check
sudo systemctl reset-failed microvm-state.service
```

tmpfiles makes a subvolume there only because `/` is itself one (`@root`);
on a root that isn't, it quietly makes a plain directory, which the check
catches.

If images are already inside, stop the VMs and move the images out first;
NOCOW applies only to files created after it is set.
