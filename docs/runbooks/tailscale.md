# Tailscale

Admin access to the nuc goes over a Tailscale tailnet, a private network
between your own devices (ADR (Architecture Decision Record) 0005). Ticket 1.5
(#12). The configuration is `modules/base/tailscale.nix`.

## How it fits together

- **SSH is the ordinary OpenSSH server.** It takes keys only and refuses root
  (`modules/base/ssh.nix`). Tailscale carries the connection; Tailscale SSH is
  not used, so a login still needs the ops key, even from a device already on
  the tailnet.
- **Port 22 is open on `tailscale0`.** Every other port is closed to the
  tailnet by the firewall, as to the LAN (local area network), with one
  exception below.
- **`tailscaled` answers one port itself: its peer API.** It listens on a
  random high port on the tailnet address, for Taildrop and similar features.
  `tailscaled` handles those connections inside its own network stack, so the
  packets never reach the firewall, which cannot close the port. Tailscale SSH
  and Tailscale Serve work the same way when turned on. Only the tailnet's
  access rules decide which devices reach them. See the source,
  `wgengine/netstack/netstack.go`, `shouldProcessInbound`. To see the port:
  `ss -ltnp src <the nuc's 100.x address>`.
- **The nuc keeps its own DNS (Domain Name System).** It runs
  `tailscale up --accept-dns=false`, so its name lookups go to the router and
  do not depend on Tailscale. Other devices still find it by name.
- **Until ticket 1.7 (#14), SSH is also open on the LAN.** The nuc joins the
  tailnet with an auth key, which is a sops secret, and the nuc can only
  decrypt secrets from #14 on. Until then Tailscale runs logged out on it.
  #14 adds the key, checks the nuc joins by itself, then closes 22 on the LAN.
  After that, if the tailnet is down, getting in means a monitor and keyboard.

## In the Tailscale admin console

Once, before #14. Menu names are from the admin console at
`login.tailscale.com` and may move.

1. **MagicDNS.** On the DNS page, check MagicDNS is on (it is by default for
   new tailnets). Devices then answer to their hostname, so the nuc is `nuc`,
   or `nuc.<tailnet name>.ts.net` in full.
2. **The `tag:server` tag.** A tag must have an owner before a key can carry
   it. In the access controls file, add:

   ```json
   "tagOwners": {
     "tag:server": ["autogroup:admin"],
   },
   ```

   A tagged device belongs to the tailnet rather than to your account, and
   Tailscale turns off key expiry for a device tagged when it logs in, so the
   nuc does not drop off after 180 days. Check the Machines page shows the nuc
   with its key expiry disabled once it has joined.
3. **The auth key**, at #14 rather than now: keys expire after at most 90
   days, and the nuc cannot use one before #14. Under Settings, then Keys,
   generate an auth key that is:
   - **not reusable**: it adds one device, so a leaked copy adds no more;
   - **pre-approved**, if device approval is on for the tailnet;
   - **tagged `tag:server`**;
   - not ephemeral: an ephemeral device is removed when it goes offline.

   The key goes straight into sops (`just secrets-edit`, see
   [secrets.md](secrets.md)), never into a file or a chat.

## Joining the workstation and the phone

**Phone.** Install the Tailscale app and sign in with the same account.

**Workstation.** The workstation is WSL2 (Windows Subsystem for Linux) on
Windows. Install Tailscale on Windows and sign in. Under WSL's default NAT
(network address translation) mode, WSL's traffic leaves through Windows, so
`ssh` from WSL is expected to reach the tailnet through it. Check, from WSL:

```bash
getent hosts nuc             # a 100.x.y.z address, from MagicDNS
ssh ops@nuc 'echo $SSH_CONNECTION'   # the third field is the nuc's 100.x address
```

If WSL cannot resolve `nuc`, it is not using Windows' DNS: try the full name
`nuc.<tailnet name>.ts.net`, or the 100.x address from `tailscale status` on
Windows. Running Tailscale inside WSL instead is possible, but needs systemd in
WSL and is a second device on the tailnet.

## Checking it (at #14)

These are #12's acceptance criteria, which need the real nuc on the tailnet:

1. With the workstation on another network (a phone hotspot, LAN cable out),
   `ssh ops@nuc` from WSL logs in.
2. After #14 closes port 22 on the LAN, a scan from the LAN finds nothing:

   ```bash
   nmap -Pn -p- -T4 nuc.home.arpa    # expect every port filtered
   ```

## Reinstalling

A reinstall gives the nuc a new identity, and the single-use key is spent.
Remove the old `nuc` from the Machines page, generate a new key as above,
replace it in sops, and rebuild. If the new machine shows up as `nuc-1`, the
old entry was still there.

## Tested in a VM

`nix build .#checks.x86_64-linux.tailscale` runs three VMs (virtual machines):
the nuc's real configuration on a LAN, a client on a separate network with no
route to it, and Headscale, an open-source implementation of Tailscale's
control server, on both. It checks that:

- the nuc joins from an auth key in a file, single-use as the real one is;
- the nuc does not take Tailscale's DNS;
- the client cannot reach the nuc's LAN address, yet logs in as ops over the
  tailnet by the nuc's MagicDNS name, and the nuc sees the login arrive on its
  tailnet address;
- a full TCP scan over the tailnet finds exactly 22 and `tailscaled`'s peer
  API port, while a test service listens on 8080; as a negative control,
  opening 8080 on `tailscale0` makes the scan report it;
- Tailscale SSH is off;
- 22 is open on `lan0` and `tailscale0` only, and still answers on the LAN.

The real tailnet, the tag and key expiry are not covered: they live in
Tailscale's service, and are checked at #14.
