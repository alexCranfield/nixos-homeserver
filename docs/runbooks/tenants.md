# Tenant VMs

The tenant's dev environment and job runner, two microVMs (virtual machines)
on the nuc: `tenant-dev` and `tenant-run`. Why they are VMs, and what they may
reach, is ADR (Architecture Decision Record) 0013. The code is in
`modules/tenants/` and `hosts/nuc/tenants.nix`.

This runbook grows with tickets 6.7 to 6.12 (#197 to #202). So far, 6.7:
the network and the state directory. The VMs themselves arrive in 6.8 (#198).

## The network

| VM | Tap on the host | Address | Gateway |
|---|---|---|---|
| `tenant-dev` | `vm-tenant-dev` | 10.88.0.2/32 | 10.88.0.1 |
| `tenant-run` | `vm-tenant-run` | 10.88.0.3/32 | 10.88.0.1 |

The taps are routed, not bridged. The host holds 10.88.0.1/32 on each, with
a route to the VM's /32, and masquerades 10.88.0.0/24 out of `lan0`. A tap
exists only while its VM runs; boot doesn't wait for one.

A VM reaches the internet, and Blocky's port 53 on 192.168.1.131. Nothing
else, IPv4 only. The `tenant-isolation` nftables table drops the rest:

```bash
sudo nft list table inet tenant-isolation
sudo nft list counter inet tenant-isolation forward-drops
sudo nft list counter inet tenant-isolation input-drops
```

- **forward**: private, shared (100.64/10, the tailnet's), link-local,
  multicast and reserved destinations, so the LAN (local area network), the
  router, Docker's networks and published ports, the tailnet and the other
  VM; any exit but `lan0`; all IPv6; and new connections to a VM.
- **input**: everything to the nuc itself except DNS (Domain Name System) to
  Blocky's address.

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

### DNS

The VMs' lookups are filtered and logged like any LAN device's. They show
in the query log, the DNS dashboard and the DNS alerts as `tenant-dev` and
`tenant-run` (`homeserver.dns.clientNames`), not as 10.88 addresses. The
first lookups from each fire `DnsNewClient` once.

## The state directory

microvm.nix keeps each VM's runner and disk images under
`/var/lib/microvms`. It is its own btrfs subvolume with copy-on-write off
(NOCOW), so the images don't fragment, and it is left out of snapshots of
the root and of backups: no customer data from the tenant's jobs reaches the
NAS (network-attached storage).

`microvm-state.service` checks both before any VM starts. If it fails, the
VMs don't start and the failure posts to Discord:

```bash
systemctl status microvm-state.service
sudo btrfs subvolume show /var/lib/microvms
lsattr -d /var/lib/microvms        # a C among the flags means NOCOW
```

If the directory became a plain one, with no VMs on it yet:

```bash
sudo rmdir /var/lib/microvms        # refuses if anything is inside
sudo systemd-tmpfiles --create --prefix=/var/lib/microvms
sudo systemctl restart microvm-state.service
```

If images are already inside, stop the VMs and move the images out first;
NOCOW applies only to files created after it is set.
