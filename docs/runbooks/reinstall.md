# Reinstall

Wiping the nuc and installing it again from this repo, so that it comes back on
the tailnet by itself. Ticket 1.8 (#15). This is the baseline for disaster
recovery (#44), which will add restoring data once there is data to restore
(phase 3); for now nothing on the nuc lives outside this repo.

Follow it for any install from now on, not only a reinstall:
[install.md](install.md) is the procedure underneath, and this runbook says
where to depart from it.

## Why a reinstall needs its own procedure

Since ticket 1.7 (#14) the installed nuc opens SSH on the tailnet only, and it
joins the tailnet with an auth key it decrypts with an age identity derived
from its SSH host key. A plain install would make a new host key on the first
boot. The nuc could not decrypt the auth key with it, would stay off the
tailnet, and with SSH closed on the LAN (local area network) nothing could
reach it.

So the new host key is made on the workstation **before** the install:

1. Its age recipient replaces the old one in `.sops.yaml`, and every secret is
   re-encrypted to it, along with a fresh auth key.
2. nixos-anywhere copies the key into the new system (`--extra-files`).
3. The first boot decrypts its secrets and joins the tailnet on its own.
4. The workstation's copy is deleted.

The key is never backed up. Every secret is also encrypted to the workstation
key, which is backed up, so a lost host key costs a reinstall, not a secret.
The key exists off the nuc only in the workstation's memory, for the minutes of
the install. Because it was made here, its fingerprint is known in advance, so
there is no host key to check at the console (install.md, step 6). ADR
(Architecture Decision Record) 0004 records the choice; the issue (#15) lists
the alternatives it was chosen over.

Wiping the disk destroys the old host key, so the old recipient's copies of
the secrets in git history become unreadable to anything but the workstation
key.

## What this rebuilds, ticket by ticket

| Ticket | What | Where it comes back |
|---|---|---|
| 1.1 (#8) | The live USB | Built from the repo, [hardware.md](hardware.md); steps 4 and 5 |
| 1.2 (#9) | The disk layout and LUKS (Linux Unified Key Setup) encryption | disko, during step 7 |
| 1.3 (#10) | The base system and SSH | the install, step 7 |
| 1.4 (#11) | The network and firewall | the install; checked in step 11 |
| 1.5 (#12) | Tailscale | the first boot, step 9 |
| 1.6 (#13) | The install itself, the TPM (Trusted Platform Module) unlock | steps 6 to 10 |
| 1.7 (#14) | Secrets decrypted with the host key | the first boot; steps 1 and 2 prepare it |

## Before

Everything in install.md's "Before" section, and:

- The Tailscale admin console is open in a browser.
- The workstation key's passphrase is to hand: re-encrypting asks for it.
- Note the start time. The goal is under an hour from step 1 to the last
  check in step 11.

## 1. Make the host key

On the workstation, in the repo's dev shell. The key goes in `/dev/shm`, which
is memory, not disk, and is gone when WSL (Windows Subsystem for Linux) stops:

```bash
hk=$(mktemp -d /dev/shm/nuc-hostkey.XXXXXX)
install -d -m 755 "$hk/etc" "$hk/etc/ssh"
ssh-keygen -q -t ed25519 -N '' -C root@nuc -f "$hk/etc/ssh/ssh_host_ed25519_key"
ssh-keygen -lf "$hk/etc/ssh/ssh_host_ed25519_key.pub"   # the fingerprint: note it
ssh-to-age -i "$hk/etc/ssh/ssh_host_ed25519_key.pub"   # the new recipient
echo "$hk"   # the path, for a second terminal
```

The directory mirrors where the files will sit on the nuc. nixos-anywhere
copies its contents to the new system's root, owned by root, with the modes
they have here: 600 for the private key, 644 for the public one.

## 2. Re-encrypt to the new key, with a new auth key

1. In `.sops.yaml`, replace the `&nuc` recipient with the new one. Update its
   comment: the fingerprint, the date, and "made on the workstation at
   reinstall".
2. Re-encrypt every secret. `updatekeys` adds the new recipient and drops the
   old one, and asks before changing each file:

   ```bash
   for f in secrets/*.yaml; do just secrets-rekey "$(basename "$f")"; done
   ```

3. In the Tailscale admin console, generate an auth key: single use,
   pre-approved, tagged `tag:server`, not ephemeral
   ([tailscale.md](tailscale.md), "The auth key"). Put it in sops at once with
   `just secrets-edit tailscale.yaml`, replacing the old, spent one.
4. Check that each file lists exactly the workstation and the new nuc (and, for
   `test.yaml`, the VM (virtual machine) test key):

   ```bash
   grep -h 'recipient:' secrets/*.yaml | sort | uniq -c
   ```

5. Commit to a branch, open a pull request, and merge it once CI (continuous
   integration) is green and it has been reviewed, so the install builds from
   `main` as install.md expects.

Until the reinstall finishes, the running nuc (if there is one) keeps working:
it decrypted its secrets at its last boot, and nothing deploys to it
automatically yet. Once comin pulls `main` (#16), a merged re-key will reach
the old nuc, which can no longer decrypt; do this step just before the install.

## 3. Hardware and the live USB

install.md's step 1 (read-only checks), and step 2 if the hardware changed.

## 4. The passphrase

install.md's step 3: typed twice at the nuc's console into `/tmp/disk.key`.

## 5. Remove the old machine from the tailnet

On the Machines page, remove the old `nuc`. If it stayed, the new one would
join as `nuc-1`, and the MagicDNS name `ssh nuc` uses would still point at the
old, dead entry. The old system is no longer running by now; it was replaced by
the live USB in step 3.

## 6. Clear the old host key from the workstation

```bash
ssh-keygen -R "$(ssh -G nuc | awk '/^hostname /{print $2}')"
```

`ssh -G nuc` prints what the `nuc` alias resolves to, the MagicDNS name, so the
tailnet's name never needs typing here.

## 7. Install, with the host key

From the repo on `main`, in WSL:

```bash
nixos-anywhere --flake .#nuc --target-host root@nuc.home.arpa \
  --phases kexec,disko,install --extra-files "$hk"
```

As install.md, step 4, with one addition: nixos-anywhere prints
`Copying extra files` between uploading the system and installing it.

## 8. Before the first boot

install.md's step 5, and check that the key arrived intact. The new system is
still mounted at `/mnt`:

```bash
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@nuc.home.arpa \
  'ls -l /mnt/etc/ssh; ssh-keygen -lf /mnt/etc/ssh/ssh_host_ed25519_key.pub'
```

Expect the private key `-rw------- root root`, and the fingerprint noted in
step 1. Then, on the workstation, trust that key for the nuc and delete the
workstation's copy:

```bash
printf '%s %s\n' "$(ssh -G nuc | awk '/^hostname /{print $2}')" \
  "$(cut -d' ' -f1,2 "$hk/etc/ssh/ssh_host_ed25519_key.pub")" >> ~/.ssh/known_hosts
rm -rf "$hk"; unset hk
```

Pull the USB stick and reboot. At the prompt on the nuc's screen, type the
passphrase. `systemd.debug_shell` is not needed: there is no key to read at the
console.

## 9. On the tailnet by itself

Shortly after the passphrase (time it; the record wants the number), the nuc appears on the Machines page as
`nuc`, tagged `tag:server`, with key expiry disabled. Then, from WSL:

```bash
ssh nuc 'echo $SSH_CONNECTION'   # third field: the nuc's new 100.x address
```

It logs in with no host key prompt: `known_hosts` already holds the key from
step 8. A prompt here, or `REMOTE HOST IDENTIFICATION HAS CHANGED`, means the
nuc is not presenting the key made in step 1. Stop and find out why before
answering it.

If the nuc never joins, the console is the only way in: the boot menu's
`systemd.debug_shell` (install.md, "If the first boot stops"), then
`journalctl -b -u initrd-nixos-activation -u tailscaled -u tailscaled-autoconnect`.
sops-nix decrypts during `initrd-nixos-activation`, because the initrd runs
systemd; a key it cannot use shows there.

## 10. The TPM key

install.md's step 6, from "Enrol the TPM key", over the tailnet:

```bash
ssh -t nuc sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/disk-main-luks
ssh nuc sudo systemctl reboot
```

It comes back without the prompt and rejoins the tailnet: `ssh nuc true`
succeeds again. The first install measured about 30 seconds to SSH.

## 11. Smoke tests

From WSL. Every one must pass.

```bash
# SSH over Tailscale: the third field is the nuc's 100.x address.
ssh nuc 'echo $SSH_CONNECTION'

# Secrets decrypt: the test secret (not sensitive) and the auth key exist.
ssh nuc 'sudo cat /run/secrets/test; sudo test -s /run/secrets/tailscale-authkey && echo authkey present'

# The kernel is linuxPackages_latest: the two versions match.
ssh nuc uname -r
nix eval --raw .#nixosConfigurations.nuc.config.boot.kernelPackages.kernel.version; echo

# The disk unlocked from the TPM: no prompt at the last boot, and both slots.
ssh nuc 'sudo systemd-cryptenroll /dev/disk/by-partlabel/disk-main-luks'

# Nothing failed.
ssh nuc 'systemctl is-system-running; systemctl --failed --no-legend'
```

**The firewall is closed on the LAN.** From WSL, on the LAN:

```bash
nmap -Pn -p- --min-rate 3000 nuc.home.arpa   # expect "Not shown: 65535 filtered tcp ports"
```

`--min-rate` keeps the scan to minutes; a scan whose host timeout fires reports
no open ports either, so the "Not shown" line, counting every port, is the
check ([network.md](network.md) has the method, the IPv6 scan, and a negative
control).

**`nix flake check` on the host.** The nuc checks the commit it runs:

```bash
rev=$(git rev-parse HEAD)   # main, as installed
ssh nuc "nix flake check github:alexCranfield/nixos-homeserver/$rev"
```

This runs the VM tests on the nuc's own KVM (Kernel-based Virtual Machine),
which, unlike the workstation's, is not nested (#80), so a `disk-tpm` failure
here is a real one. Expect it to take a while: on the workstation the
`network` test alone takes about twenty minutes.

## Record

Add a column for each reinstall.

| | |
|---|---|
| Date | |
| Installed from | `main` at |
| Time, step 1 to the end of step 11 | |
| Host key fingerprint | |
| Smoke tests | |
| Surprises | |
