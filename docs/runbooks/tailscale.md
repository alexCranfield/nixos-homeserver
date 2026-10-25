# Tailscale

Admin access to the nuc goes over a Tailscale tailnet, a private network
between your own devices (ADR (Architecture Decision Record) 0005). Ticket 1.5
(#12). The configuration is `modules/base/tailscale.nix`. Friends reach the
game servers over it too, through Tailscale's machine sharing (ADR 0011,
ticket 4.0, #135): see "Sharing the nuc with a friend" below, and
[game-access.md](game-access.md) for the friend's side.

## How it fits together

- **SSH is the ordinary OpenSSH server.** It takes keys only and refuses root
  (`modules/base/ssh.nix`). Tailscale carries the connection; Tailscale SSH is
  not used, so a login still needs the ops key, even from a device already on
  the tailnet.
- **Port 22 is open on `tailscale0`.** Every other port is closed to the
  tailnet by the firewall, as to the LAN (local area network), with two
  exceptions: the peer API below, and game ports.
- **Game ports are admitted from `tailscale0` only.** A game stack declares
  each port with `interface = "tailscale0"`, and the `stack-ports` table
  admits it from there and drops it from the LAN ([stacks.md](stacks.md)).
  The access policy decides who on the tailnet gets that far.
- **`tailscaled` answers one port itself: its peer API** (application
  programming interface). It listens on a random high port on the tailnet
  address, for Taildrop and similar features. `tailscaled` handles those
  connections inside its own network stack, so the packets never reach the
  firewall, which cannot close the port (`wgengine/netstack/netstack.go`,
  `shouldProcessInbound`). To see the port:
  `ss -ltnp src <the nuc's 100.x address>`. Tailscale SSH and Tailscale Serve
  work the same way when turned on.
- **The access policy (below) does not close the peer API either.**
  `tailscaled` lets connections to it past the policy on purpose, and checks
  each request itself, by what the asking device is allowed
  (`net/tstun/wrap.go`: "Let peerapi through the filter; its ACLs are handled
  at L7", layer 7 being the HTTP (Hypertext Transfer Protocol) requests). So
  any device the tailnet lists as the nuc's peer can connect to the port, and
  gets only what its permissions allow. The VM (virtual machine) test shows a
  request getting past the policy to that check, and being refused. Serve and
  Tailscale SSH get no such exception, so the policy does limit them.
- **The nuc keeps its own DNS (Domain Name System).** It runs
  `tailscale up --accept-dns=false`, so its name lookups go to the router and
  do not depend on Tailscale. Other devices still find it by name.
- **Taildrop is turned off** (`disableTaildrop`, Alex's choice). On the
  tagged nuc it is already off unless the policy grants
  `https://tailscale.com/cap/file-send`; this keeps `tailscaled` refusing
  incoming files even then. It does not close the peer API's port.
- **The nuc joins by itself** (ticket 1.7, #14): `hosts/nuc/tailscale.nix`
  points `authKeyFile` at the sops secret `tailscale-authkey` in
  `secrets/tailscale.yaml`, and `tailscaled-autoconnect` logs in with it when
  the nuc is logged out. SSH is closed on the LAN since #14, once the tailnet
  login had been shown to work from another network. If the tailnet is down,
  there is no console login to fall back on (ops has no password): the way in
  is the boot menu's debug shell or the live USB
  ([install.md](install.md)).

## In the Tailscale admin console

Once, before #14. Menu names are from the admin console at
`login.tailscale.com` and may move.

1. **MagicDNS.** On the DNS page, check MagicDNS is on (it is by default for
   new tailnets). Devices then answer to their hostname, so from a device on
   the tailnet the nuc is `nuc.<tailnet name>.ts.net`, or `nuc` where nothing
   else claims that name (on the LAN, the router does; see below).
2. **The access policy.** In the access controls file, give the
   `tag:server` tag an owner (a key cannot carry a tag without one), and
   replace the default rule, which lets every device reach every other on
   every port, tagged ones included:

   ```json
   "tagOwners": {
     "tag:server": ["autogroup:admin"],
   },
   "grants": [
     // Your own devices reach each other as before.
     {"src": ["autogroup:member"], "dst": ["autogroup:self"], "ip": ["*"]},
     // They reach the nuc on SSH and the game ports.
     {"src": ["autogroup:member"], "dst": ["tag:server"], "ip": ["tcp:22", "tcp:25565"]},
     // Everyone the nuc is shared with: the game ports and nothing else.
     {"src": ["autogroup:shared"], "dst": ["tag:server"], "ip": ["tcp:25565"]},
   ],
   ```

   The two game rules arrived with ticket 4.0 (#135). `tcp:25565` is
   Minecraft (#28). Each game server adds its own ports to both rules, for
   example `udp:8211` for Palworld, and nothing else does. Your own devices
   need them because the LAN path is closed to games (ADR 0011).
   `autogroup:shared` is Tailscale's selector for "every user who accepted a
   share", valid as a source on every plan (Tailscale's grants syntax
   reference, checked 2026-10-24), so no friend's email goes in the policy.

   The default rule is `"src": ["*"], "dst": ["*"]`, under `grants` or, in
   an older tailnet, `acls`; delete it. Nothing names `tag:server` as a
   source, so a compromised nuc reaches no other device. Tailscale Serve
   (ADR 0006) will add its ports to the second rule. The peer API stays
   reachable from every device whatever the policy says (above).

   Empty the policy's `"ssh"` section (`"ssh": [],`). Those rules are for
   Tailscale SSH, which nothing here uses (Windows and Android cannot serve
   it), and an empty list means nobody could log in through it even if it
   were turned on by mistake. A `"tests"` section with your login email, for
   example `{"src": "<email>", "accept": ["tag:server:22",
   "tag:server:25565"], "deny": ["tag:server:80"]}`, makes the console refuse later edits that would break
   the rules; it needs the real email, as a made-up one is no member. Done
   2026-10-18.

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

   The key goes straight into sops (`just secrets-edit tailscale.yaml`, see
   [secrets.md](secrets.md)), never into a file or a chat.

## Sharing the nuc with a friend

A share makes the nuc appear in the friend's own tailnet, and nothing else of
yours. They need a Tailscale account of their own, on any login it offers
(Google, Microsoft, Apple, GitHub and others), and Tailscale installed
([game-access.md](game-access.md) walks them through it).

**Share.** In the admin console, Machines, open the nuc's menu and choose
Share. Under Share by email, add the friend's email: they get a single-use
invite link. Or, under Copy invite link, copy one and send it to them
yourself; leave Reusable link off, so one link adds one person, and treat
it like a password. An unused link expires after 30 days. Once they accept,
their avatar and email show in the Share dialog, the nuc is listed in their
Tailscale app, and the policy's `autogroup:shared` rule lets them reach the
game ports.

**Tell them the address**: `nuc.<tailnet name>.ts.net`, the full name. A
shared machine does not answer to its short name in the friend's tailnet.
Its 100.x address there is usually the nuc's own, but Tailscale gives it
another if that address is taken in their tailnet, so for a fallback they
read it from their own app rather than from you.

**Revoke.** Machines, the nuc's Share option, then the friend's menu and
Revoke invite. That works for an accepted share too: they can no longer reach
the nuc, and coming back takes a new invite. (Tailscale's documentation
does not say how quickly a session already running drops; check it at
#135's close.)

**Limits.** A share does not count as a user of your tailnet (Tailscale's
"Inviting users vs sharing devices" page), the Personal plan allows six users
(the pricing page), and the sharing page gives no cap on how many people a
machine can be shared with (all checked 2026-10-24). A friend who
is sent an invite to the tailnet instead, from the Users page, becomes a user
with access to everything the policy gives `autogroup:member`, SSH included:
use Share, never Invite users.

## Joining the workstation and the phone

**Phone.** Install the Tailscale app and sign in with the same account.

**Workstation.** The workstation is WSL2 (Windows Subsystem for Linux) on
Windows. Install Tailscale on Windows and sign in. Under WSL's default NAT
(network address translation) mode, WSL's traffic leaves through Windows, so
`ssh` from WSL is expected to reach the tailnet through it. Check, from WSL:

```bash
getent hosts nuc.<tailnet name>.ts.net    # a 100.x.y.z address, from MagicDNS
ssh ops@nuc.<tailnet name>.ts.net 'echo $SSH_CONNECTION'   # third field: the nuc's 100.x address
```

Use the full MagicDNS name, or the 100.x address from `tailscale status` on
Windows. On the LAN, plain `nuc` resolves through the router's `home.arpa`
search domain to the LAN address (`192.168.1.131`), where SSH is closed. The
workstation's `~/.ssh/config` alias makes `ssh nuc` use the MagicDNS name
instead ([workstation.md](workstation.md), "Reaching the nuc").
`SSH_CONNECTION` shows which path a login took: its third field is the address
the nuc was reached on.

Running Tailscale inside WSL instead is possible, but needs systemd in WSL and
is a second device on the tailnet.

## Checking it (at #14)

These are #12's acceptance criteria, which need the real nuc on the tailnet:

1. With the workstation on another network (a phone hotspot, LAN cable out),
   `ssh ops@nuc.<tailnet name>.ts.net` from WSL logs in, and
   `SSH_CONNECTION`'s third field is the nuc's 100.x address.
2. After #14 closes port 22 on the LAN, a scan from the LAN finds nothing:

   ```bash
   nmap -Pn -p- -T4 nuc.home.arpa    # expect every port filtered
   ```

3. The access policy. A scan over the tailnet should find 22 and the peer
   API's port only (`ss -ltnp` on the nuc names it). And the phone's tailnet
   address should answer the workstation (the control) but not the nuc:

   ```bash
   nmap -Pn -p- -T4 <the nuc's 100.x address>   # from WSL, over the tailnet
   ping -c 1 -W 2 <the phone's 100.x address>               # answers
   ssh ops@<the nuc's 100.x address> ping -c 1 -W 2 <the phone's 100.x address>   # fails
   ```

## Reinstalling

A reinstall gives the nuc a new identity, and the single-use key is spent.
[reinstall.md](reinstall.md) does the whole thing in order. The Tailscale parts:

1. A new auth key, generated as above, goes into `secrets/tailscale.yaml`
   along with the re-encryption to the new host key (reinstall.md, step 2).
2. Remove the old `nuc` from the Machines page before the new one boots
   (step 5). If the new machine shows up as `nuc-1`, the old entry was still
   there.
3. The first boot decrypts the key and `tailscaled-autoconnect` logs in with
   it; no deploy is needed (step 9).

If `tailscaled`'s state is ever lost without a reinstall, autoconnect sends
the spent key, `tailscale up` refuses it, and the nuc stays logged out until
step 3 and a deploy.

Never run `tailscale down` on the nuc over the tailnet: it ends the session,
and with no SSH on the LAN the way back is the console. A reboot brings it up
again (autoconnect sees `Stopped` and runs `tailscale up`).

## Tested in a VM

`nix build .#checks.x86_64-linux.tailscale` runs three VMs:
the nuc's real configuration on a LAN, a client on a separate network with no
route to it, and Headscale, an open-source implementation of Tailscale's
control server, on both. It checks that:

- the nuc joins from an auth key in a file;
- both auth keys are single-use, as the real one is, and spent once used;
- the nuc does not take Tailscale's DNS, while the client, joined without
  `--accept-dns=false`, does;
- the client cannot reach the nuc's LAN address, yet logs in as ops over the
  tailnet by the nuc's MagicDNS name, and the nuc sees the login arrive on its
  tailnet address;
- a full TCP (Transmission Control Protocol) scan over the tailnet finds
  exactly 22 and `tailscaled`'s peer API port, while a test service listens
  on 8080; as a negative control, opening 8080 on `tailscale0` makes the scan
  report it;
- with the nuc tagged `tag:server` and the policy above (in Headscale's
  form), 8080 is closed again although the firewall still opens it, the peer
  API port is still open and still answers requests (refusing a debug one,
  as it did before the policy), and the nuc can no longer ping the client,
  as it could before the policy;
- Tailscale SSH is off;
- 22 is open on `tailscale0` only, and filtered from the LAN.

The real tailnet, Tailscale's own policy engine and the tag's key expiry are
not covered: they live in Tailscale's service, and are checked at #14.

`nix build .#checks.x86_64-linux.game-access` (ticket 4.0, #135) runs four:
the nuc with a stand-in game server on 25565 declared for `tailscale0`, a
`friend` on another network, a `member` on the LAN, and Headscale. Headscale
has no machine sharing, so the friend is a tailnet user held to the same rule
the real policy gives `autogroup:shared`, and the member to the
`autogroup:member` rule. It checks that:

- the friend reaches the game port over the tailnet by name, and the
  connection arrives on `tailscale0`, where `stack-ports` counts and logs it;
- a scan from the friend finds the game port and not 22, which the nuc's
  firewall opens on `tailscale0`, so the policy is what closes it;
- the member reaches 22 and the game port over the tailnet, but not the game
  port at the nuc's LAN address, which `stack-ports` drops and logs from
  `lan0`, although the LAN path itself answers;
- as negative controls, without the friend's rule the friend is shut out
  while the member is not, and with the port declared for `lan0` the LAN
  reaches it and the tailnet does not.

The real share, `autogroup:shared` itself and the friend's game client are
checked on the live tailnet at #135's close.
