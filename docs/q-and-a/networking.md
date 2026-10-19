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
