# Network

How the nuc joins the LAN (local area network): which port, which address,
which name, and what the firewall lets in. Ticket 1.4 (#11). The configuration
is `hosts/nuc/network.nix` and `modules/base/firewall.nix`.

## The ports

| Port | Kernel name | MAC | Use |
|---|---|---|---|
| Intel I226-V | `enp45s0`, renamed `lan0` | `9c:6b:00:5c:46:52` | the server's LAN port |
| Intel I226-LM | `enp44s0` | `9c:6b:00:5c:46:51` | held down, and kept unplugged |

The cable goes in the I226-V's port. Which physical socket that is was not
recorded in the hardware survey (#8); check it with a cable the first time,
by watching which port `ip -br link` shows as `UP`.

The I226-LM is the variant that usually carries Intel AMT (Active Management
Technology), a remote management engine in firmware. NixOS holds that port
down, but AMT runs below the operating system, so an unplugged port is what
actually keeps it off the network.

systemd-networkd renames the I226-V to `lan0` by its MAC address, so the
firewall and anything else can name the port without depending on its PCI
(Peripheral Component Interconnect) slot. A replaced board or NIC (network
interface card) has a new MAC address: update `lanMac` in
`hosts/nuc/network.nix` before moving the disk across, or the machine comes up
with no network.

## The router

The router is a UniFi Dream Router 7. Two settings live there, not in this
repository: the DHCP (Dynamic Host Configuration Protocol) reservation and the
name. Menu names below are from the UniFi Network application and may move
between versions.

1. **Check the LAN's domain.** Settings, then Networks, then the LAN network:
   the domain name field should read `home.arpa`. With it set, UniFi is
   expected to answer DNS (Domain Name System) queries for
   `<client hostname>.home.arpa` from the names DHCP clients send; another
   machine already reachable as `<name>.home.arpa` is a quick check.
2. **Reserve the address.** Client Devices, the device with MAC
   `9c:6b:00:5c:46:52` (seen when the survey booted the live USB), its
   settings, then Fixed IP Address. Pick an address in the LAN's subnet and
   record it in the table below.
3. **Pin the name.** In the same settings, turn on the local DNS record and
   set it to `nuc.home.arpa`. The nuc sends the hostname `nuc` itself, but the
   live USB sends `nixos`; the record makes the name hold either way, which
   the install (#13) relies on.

Check it from the workstation:

```bash
getent hosts nuc.home.arpa     # the reserved address
ping -c 3 nuc.home.arpa
```

| Setting | Value |
|---|---|
| Reserved address | not yet set |
| Local DNS record | not yet set |

## The firewall

Default deny, on nftables. Nothing is open on any interface except:

| Port | Interface | Why | Until |
|---|---|---|---|
| TCP 22 (SSH) | `lan0` | admin access | Tailscale works (ticket 1.5, #12) |
| TCP 22 (SSH) | `eth0`, `just vm` only | the 127.0.0.1:2222 forward into the VM (virtual machine) | |

NixOS's firewall also lets in, on any interface:

- ping (ICMP echo request; ICMP is the Internet Control Message Protocol);
- ICMPv6 (ICMP for IPv6), apart from redirects and node information queries,
  since IPv6 needs it to find neighbours and routers;
- UDP port 546 sent to a link-local address (`fe80::/64`): replies to the
  DHCPv6 client, in case the router hands out IPv6 addresses that way;
- anything in the `temp-ports` set, which `nixos-firewall-tool` fills to open
  a port by hand until the next reboot. It is empty unless someone does that.

`services.openssh.openFirewall` is off, so sshd does not open 22 everywhere on
its own; each host opens it where it wants it. To see the live rules on the
nuc:

```bash
sudo nft list chain inet nixos-fw input-allow
```

Check from the LAN with a full scan. It takes a few minutes, because a
default-deny firewall drops probes rather than refusing them, so nmap waits on
each port:

```bash
nmap -Pn -p- -T4 nuc.home.arpa    # expect 22/tcp open, everything else filtered
```

Docker publishes container ports around this firewall (ADR 0006), so the scan
is worth re-running once stacks arrive.

## Tested in a VM

`nix build .#checks.x86_64-linux.network` boots the nuc configuration with two
ports beside a stand-in router running dnsmasq, and checks that:

- the LAN port is renamed `lan0` by its MAC address, and takes the reserved
  address;
- the second port stays down with no address;
- `nuc.home.arpa` resolves on the router from the hostname the nuc sends;
- a full TCP scan from the LAN finds only 22, while a test service listens on
  8080 behind the firewall;
- as a negative control, opening 8080 in the firewall makes the scan report
  it, so the scan can see an open port when there is one;
- the only UDP rule is NixOS's DHCPv6 client rule, and `temp-ports` is empty.

The test starts `network-online.target` itself: nothing on the nuc asks for it
yet, so systemd would otherwise never run `systemd-networkd-wait-online`.
