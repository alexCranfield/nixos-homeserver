# Network

How the nuc joins the LAN (local area network): which port, which address,
which name, and what the firewall lets in. Ticket 1.4 (#11). The configuration
is `hosts/nuc/network.nix` and `modules/base/firewall.nix`.

## The ports

| Port | Kernel name | MAC (hardware) address | Use |
|---|---|---|---|
| Intel I226-V | `enp45s0`, renamed `lan0` | `9c:6b:00:5c:46:52` | the server's LAN port |
| Intel I226-LM | `enp44s0` | `9c:6b:00:5c:46:51` | held down, and kept unplugged |

The cable goes in the I226-V's port. The hardware survey (#8) did not record
which physical socket that is. On 2026-10-18 the router saw the I226-LM's
address with the cable in one socket, and the I226-V's after it moved to the
other, so the cable is now in the right one. Keep it there: once installed,
the nuc holds the I226-LM down, so a cable in the wrong socket leaves it off
the network with no screen to say why. To check again on the live USB, with
the cable in one socket:

```bash
ip -br link    # enp45s0 (the I226-V) should show UP; if enp44s0 does, swap
```

`ethtool -p`, the usual way to blink a port's light, does not work here: the
I226's driver, `igc`, does not support it.

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
   the domain name field should read `home.arpa` (it read `localdomain`, the
   default, until 2026-10-18). With it set, UniFi is
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
| Reserved address | `192.168.1.131`, set 2026-10-18 |
| Local DNS record | `nuc.home.arpa`, set 2026-10-18 |

**The LAN's DNS server is not the router.** DHCP hands out a Pi-hole on the
LAN as the DNS server, so clients ask it, not the router, and it did not know
the router's names: `nuc.home.arpa` resolved when asking the router directly
but not from the workstation. Pi-hole's reverse server setting (Settings, then
DNS, in expert mode; "conditional forwarding" before Pi-hole v6) now sends
`home.arpa` to the router:

```
true,192.168.1.0/24,192.168.1.1,home.arpa
```

The fourth field is what forwards names; without it only reverse lookups
(address to name) go to the router. Pi-hole still answers its own local
records first. If the Pi-hole is down, every name lookup on the LAN fails,
the nuc's own included. To tell the two apart:

```bash
nslookup nuc.home.arpa 192.168.1.1    # the router: the reserved address
nslookup nuc.home.arpa                # the LAN's DNS server: the same
```

## The firewall

Default deny, on nftables. Nothing is open on any interface except:

| Port | Interface | Why | Until |
|---|---|---|---|
| TCP 22 (SSH) | `tailscale0` | admin access over the tailnet; see [tailscale.md](tailscale.md) | |
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

Check from the LAN with a full scan. A default-deny firewall drops probes
rather than refusing them, so nmap gets no answer on any port and keeps
slowing itself down; a fixed minimum rate keeps it to about two minutes. nmap
reports no open ports both for a clean result and for a scan it gave up on, so
read the "Not shown" line too. nmap is not installed in WSL (Windows Subsystem
for Linux), and the dev shell does not provide it, so `nix shell` fetches it:

```bash
nix shell nixpkgs#nmap -c nmap -Pn -p- --min-rate 3000 --max-retries 1 nuc.home.arpa
# expect "Not shown: 65535 filtered tcp ports"
```

At that rate the scan still found a single port opened for the purpose
(2026-10-18, twice). Over the tailnet it did not: the same rate missed
`tailscaled`'s peer API port, which `tailscaled` answers itself, so scan the
tailnet address without `--min-rate`.

The firewall covers IPv6 as well (the `inet` table holds both). If the router
advertises an IPv6 prefix, `lan0` takes an IPv6 address from it too, so scan
that as well. The UniFi router advertises a ULA (unique local address) prefix,
`fd…/64`, reachable on the LAN only; on 2026-10-18 `lan0` had two addresses in
it. Find it with `ip -6 -br addr show lan0` on the nuc, then:

```bash
nmap -6 -Pn -p- -T4 <ULA address of the nuc>   # from a machine with nmap: expect nothing open
```

That needs a machine with nmap and an IPv6 route to the LAN. The workstation's WSL, in
its default NAT (network address translation) mode, has none; Windows itself
does, but has no nmap. So the scan runs from Windows PowerShell 5.1 instead (in
PowerShell 7, `Test-Connection` shows `Latency` rather than `ResponseTime`), as a
TCP connect to every port, 2,000 at a time, with a 1.5 second wait. A dropped
probe never connects, so only ports that complete the handshake count as open:

```powershell
$a = '<ULA address of the nuc>'
Test-Connection -ComputerName $a -Count 3 | Select-Object Address, ResponseTime
$open = @()
for ($s = 1; $s -le 65535; $s += 2000) {
  $e = [Math]::Min($s + 1999, 65535)
  $c = foreach ($p in $s..$e) { $t = New-Object System.Net.Sockets.TcpClient([System.Net.Sockets.AddressFamily]::InterNetworkV6); [pscustomobject]@{ P = $p; T = $t; K = $t.ConnectAsync($a, $p) } }
  Start-Sleep -Milliseconds 1500
  foreach ($x in $c) { if ($x.K.Status -eq 'RanToCompletion') { $open += $x.P }; $x.T.Dispose() }
}
"scanned 65535 ports, open: " + ($(if ($open) { $open -join ',' } else { 'none' }))
```

Expect `open: none`. A scan that cannot reach the nuc looks the same as a clean
one, so check that it arrived. `Test-Connection` must get replies, and the
nuc's own counters show the scan landing:

```bash
ssh nuc 'nstat -az Ip6InReceives Icmp6InEchos Icmp6OutEchoReplies'
```

The counters run from the nuc's last boot. On 2026-10-19, with one scan and
three pings since the boot, they read 131,104 IPv6 packets received, about two
per port (presumably Windows resending each unanswered SYN within the 1.5 s
wait), and 3 echo requests
answered.

Docker publishes container ports around this firewall (ADR 0006), so the scan
is worth re-running once stacks arrive.

## Tested in a VM

`nix build .#checks.x86_64-linux.network` boots the nuc configuration with two
ports beside a stand-in router running dnsmasq, and checks that:

- the LAN port is renamed `lan0` by its MAC address, and takes the reserved
  address;
- the second port stays down with no address;
- `nuc.home.arpa` resolves on the router from the hostname the nuc sends;
- a full TCP scan from the LAN finds nothing open, SSH included, while sshd
  and a test service on 8080 listen behind the firewall;
- as a negative control, opening 8080 in the firewall makes the scan report
  it, so the scan can see an open port when there is one;
- the only UDP rule is NixOS's DHCPv6 client rule, and `temp-ports` is empty.

The test starts `network-online.target` itself: nothing on the nuc asks for it
yet, so systemd would otherwise never run `systemd-networkd-wait-online`.
