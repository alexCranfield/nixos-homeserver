# Install

Installing the nuc from this repo with nixos-anywhere and disko, from the live
USB. Ticket 1.6 (#13); first done on 2026-10-18. The install wipes the system
drive. The reinstall runbook (ticket 1.8, #15) builds on this one and adds
restoring the data.

The disk is LUKS2 (Linux Unified Key Setup) encrypted (ADR (Architecture
Decision Record) 0009). Every boot after the install unlocks it with a key
sealed in the TPM (Trusted Platform Module); the passphrase set here is the
recovery key for when that fails.

## Before

- The live USB is built and boots: [hardware.md](hardware.md), "The live USB".
  Use a USB-A port for it and for the keyboard.
- The router reserves the nuc's address and name: [network.md](network.md).
  The cable is in the I226-V's socket.
- A keyboard and screen are on the nuc. The first boot asks for the passphrase
  there, and the live USB's console is where the passphrase is typed.
- The ops key is in an SSH agent on the workstation. The live USB lets root in
  with it. It makes a new host key on every boot, so every `ssh root@…` below
  takes `-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no`, as in
  [hardware.md](hardware.md); without them, a reinstall fails on the installed
  server's key, which `known_hosts` holds under the same name. Never use them
  against the installed server.
- `main` holds what is to be installed, CI (continuous integration) is green on
  it, and it builds locally:
  `nix build .#nixosConfigurations.nuc.config.system.build.toplevel`.
- The commands on the workstation run in the repo's dev shell (direnv, or
  `nix develop`), which provides `nixos-anywhere`.

## 1. Read-only checks on the live USB

Nothing here changes the machine. From WSL (Windows Subsystem for Linux), with
the agent loaded:

```bash
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@nuc.home.arpa \
  'lsblk -o NAME,SIZE,TYPE,MODEL; ip -br link; ls /dev/tpmrm0; systemd-analyze pcrs 7'
```

- `lsblk` shows one NVMe (Non-Volatile Memory Express) drive, `nvme0n1`, the
  name `hosts/nuc/disko.nix` wipes. If there are two, stop: see
  [hardware.md](hardware.md), "The second M.2 slot".
- `enp45s0` is UP; `enp44s0` has no carrier.
- The TPM is there, and PCR (Platform Configuration Register) 7 is not all
  zeros, so the firmware measures the boot and a key sealed to it means
  something.

## 2. The hardware configuration

`hosts/nuc/hardware-configuration.nix` is the output of the command below, run
on the nuc. On new hardware, or a board replaced under warranty, run it and
compare before installing; a difference goes in by pull request, so the install
builds from a reviewed commit.

```bash
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@nuc.home.arpa \
  nixos-generate-config --show-hardware-config --no-filesystems
```

It lists `usb_storage` and `sd_mod` because the live USB stick is plugged in,
and writes `hardware.cpu.intel.npu.enable = true;`, which the file leaves out on
purpose (its header says why).

## 3. The passphrase

Type it **at the nuc's keyboard**, on the live USB's console, not in WSL. The
console uses the same keyboard layout as the passphrase prompt at boot, so the
bytes saved are the bytes the prompt will get. Typing it twice catches a typo
that nothing would show:

```bash
read -rsp 'new: ' a; echo; read -rsp 'again: ' b; echo
[ -n "$a" ] && [ "$a" = "$b" ] && printf %s "$a" > /tmp/disk.key && chmod 600 /tmp/disk.key && echo saved || echo "empty or no match, run it again"
unset a b
```

`printf %s` leaves out the trailing newline. disko would drop one anyway (it
reads the file through `$(cat …)`), but `cryptsetup --key-file` in step 5 reads
the file byte for byte, and a newline there would fail the check on a good
disk. Store the passphrase in the password manager and in the offline backup
now, before installing.

`hosts/nuc/disko.nix` reads the passphrase from `/tmp/disk.key` on the target
while formatting. nixos-anywhere can copy a file there from the workstation
(`--disk-encryption-keys /tmp/disk.key <local file>`), which is what ADR 0009
first planned. Do not: on 2026-10-18 a passphrase typed once into a file on the
workstation came out different from the one intended, the first boot could not
unlock, and the file had been overwritten, so the install was repeated.

## 4. Install

From the repo on `main`, in WSL:

```bash
nixos-anywhere --flake .#nuc --target-host root@nuc.home.arpa --phases kexec,disko,install
```

- `kexec` is skipped by nixos-anywhere itself: the live USB is already a NixOS
  installer (`VARIANT_ID=installer` in `/etc/os-release`).
- `disko` partitions and formats `nvme0n1`, with the passphrase file as the
  first LUKS key slot.
- `install` copies the system across and installs systemd-boot.
- `reboot` is left out, so the next step can check the result before it
  matters.

## 5. Before the first boot

```bash
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@nuc.home.arpa
cryptsetup open --test-passphrase --key-file /tmp/disk.key /dev/disk/by-partlabel/disk-main-luks && echo unlocks
efibootmgr
```

- The key file unlocks the disk.
- `efibootmgr` lists a "Linux Boot Manager" entry on the new ESP (EFI System
  Partition). The firmware put it **after** the USB stick both times, so put it
  first: `efibootmgr -o <its number>,<the USB's>`, which also drops any entry
  not listed from the boot order (list any other to keep). A reinstall leaves
  the old install's entries behind, pointing at a partition that no longer
  exists (compare the GUID (globally unique identifier) in each entry with
  `lsblk -no PARTUUID /dev/disk/by-partlabel/disk-main-ESP`); delete those with
  `efibootmgr -b <number> -B`.
- `shred -u /tmp/disk.key`.

Then pull the USB stick and reboot. To check the host key on this boot (step 6),
press an arrow key at the systemd-boot menu to stop its 5-second countdown,
then `e`, and add ` systemd.debug_shell` to the end of the line. At the prompt
on the nuc's screen, type the passphrase.

## 6. After the first boot

**Since #14 this step needs a way in.** The installed system opens SSH on
`tailscale0` only, and a new install has a new host key, so it cannot decrypt
its Tailscale auth key and stays off the tailnet. The commands below were run
on 2026-10-18, before #14 closed the LAN. For a reinstall, the reinstall
runbook (#15) decides how the first login happens: carrying the old host key
over, re-encrypting the secrets to the new one first, or opening the LAN for
that one boot.

The installed system has new SSH host keys, so clear the live USB's from the
workstation first:

```bash
ssh-keygen -R nuc.home.arpa; ssh-keygen -R 192.168.1.131
```

Check the new host key out of band before trusting it. Asking the server for
its own key over SSH proves nothing, and two fetches over the LAN (local area
network) agreeing is only trust on first use. The console has no login (ops
has no password and root is locked), but the boot menu gives a root shell:
with ` systemd.debug_shell` added at the menu (step 5, or any later reboot),
press Ctrl+Alt+F9 once the system is up and run

```bash
/run/current-system/sw/bin/ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

The full path is needed: the debug shell's `PATH` holds only systemd's own
tools. Compare the fingerprint with what the first `ssh ops@nuc.home.arpa`
shows. The shell restarts if closed and stays on tty9 for the rest of that
boot, so reboot once the check is done.

Enrol the TPM key. It asks for the passphrase, so run it in a terminal of your
own:

```bash
ssh -t ops@nuc.home.arpa sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/disk-main-luks
```

`sudo systemd-cryptenroll /dev/disk/by-partlabel/disk-main-luks` then lists
slot 0 `password` and slot 1 `tpm2`. Reboot: it should come back without the
prompt, with `systemd-cryptsetup@cryptroot.service` finishing about half a
second into the boot.

## 7. Checks

On the nuc, as ops:

```bash
nixos-version; systemctl is-system-running; systemctl --failed
for d in 00:02.0 2c:00.0 2d:00.0; do echo "$d $(basename "$(readlink /sys/bus/pci/devices/0000:$d/driver)")"; done
sudo dmesg | grep -iE 'firmware' | grep -iE 'fail|missing|direct'   # expect nothing
findmnt -t btrfs,vfat; swapon --show
```

Expect `xe` on `00:02.0` and `igc` on both NICs (network interface cards).
`lspci` is not installed; `nix-shell -p pciutils --run 'lspci -k'` gives the
full listing. Then the
network checks in [network.md](network.md).

## If the first boot stops

"Cannot open access to console, the root account is locked" means emergency
mode: something in the boot failed, and the root shell it offers is refused
because root has no password. The lines above it usually name the failure. To
see more:

1. Reboot (Ctrl+Alt+Del), and at the systemd-boot menu press an arrow key, then
   `e`. Add ` rd.systemd.debug_shell` to the end of the line and press Enter.
   This lasts one boot, and covers the initrd (early boot environment), where
   the disk is unlocked and mounted: the failure of 2026-10-18 was there. A
   failure after the switch to the installed system, such as a mount under
   `/srv`, needs ` systemd.debug_shell` instead; adding both is harmless.
2. When emergency mode comes up, press Ctrl+Alt+F9 for a root shell.
3. `systemctl --failed --no-pager` and
   `journalctl -b -p warning --no-pager | tail -40`.

`Failed to activate with specified passphrase` from `systemd-cryptsetup` means
the typed passphrase is not the one the disk was formatted with. With the
passphrase file gone, nothing reads the disk; reinstall from step 3.

The boot menu editor that step 1 above and the host key check use is open to
anyone at the keyboard; #47 turns it off along with Secure Boot, after which
the live USB is the only way to a shell at the console.

## Record

| | 2026-10-18 |
|---|---|
| Installed from | `main` at `8e9f070`, NixOS `26.05.20260907.93108a5`, kernel 7.2.3 |
| nixos-anywhere | 1.13.0 |
| Live USB | NixOS 26.05, kernel 7.2.3 |
| Disk | Seagate FireCuda 530, 931.5 GiB: 1 GiB ESP (56 MiB used, one generation), 930.5 GiB LUKS2 (AES (Advanced Encryption Standard) in XTS mode, Argon2id) |
| TPM unlock | PCR 7, `f18e3c69…eedcc9` with Secure Boot off; unattended boot back on SSH in about 30 s |
| Drivers | `xe` with its graphics microcontroller firmware (GuC 70.72.1, HuC 10.3.3, GSC 105.0.2.1397, DMC v2.36), `igc` on both I226s, `intel_vpu` on the NPU (neural processing unit) |
| `dmesg` errors | none for the GPU (graphics processor), NICs or firmware; Bluetooth `gp1 mailbox interrupt` and SoundWire bus clashes, as in the survey |
| NVMe health after the install | SMART (Self-Monitoring, Analysis and Reporting Technology) passed, 0 % used, no media errors. Error log 43 entries (13 at the survey), all `Invalid Field in Command` on the admin queue: the host asking for features the drive does not support, not data errors. Unsafe shutdowns 9 (8 at the survey), most likely the emergency-mode boot |
| Firewall from the LAN | IPv4: nmap, only 22 open. IPv6, the ULA (unique local address) from the router: a scan from Windows, only 22 open. Negative control: a listener on 8080 shows as filtered on both, then open on both after `nixos-firewall-tool open tcp 8080`, then filtered again after `reset` |
