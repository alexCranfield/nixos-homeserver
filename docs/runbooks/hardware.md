# Hardware: assembly, BIOS (Basic Input/Output System) and survey

Ticket 1.1 (#8). This covers turning the parts into a machine that boots the
live USB, and recording what it is. Installing NixOS is ticket 1.6 (#13); do
not install until the disk-encryption decision (#57) and the disk layout (#9)
exist, because changing either afterwards means reinstalling.

## The live USB

The stock NixOS minimal ISO (disk image) boots the LTS (long-term support)
kernel, which may not drive Panther Lake's Xe3 iGPU (integrated graphics) or
its NICs (network interface cards). A survey on that kernel says little about
the installed system, which runs `linuxPackages_latest`; see ADR (Architecture
Decision Record) 0001. `hosts/installer` builds an ISO with the latest kernel,
the survey tools, and `keys/ops.pub` authorised for root, so the survey can run
over SSH from the workstation.

```bash
just iso                                   # prints /nix/store/...-nixos-minimal-....iso
cp -L "$(just iso)"/iso/*.iso /mnt/c/Users/<you>/Downloads/
```

Write it to a USB stick from Windows with Rufus (choose **DD image** mode when
asked) or balenaEtcher. Any stick of 2 GB or more; it is wiped.

Boot it on the nuc from the firmware's boot menu. Then find its address, either
from the router's DHCP (Dynamic Host Configuration Protocol) lease list or with
`ip -4 addr` on the console, and from WSL (Windows Subsystem for Linux):

```bash
ssh -i ~/.ssh/id_nuc -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@<ip>
```

The two `-o` options apply to the live USB only. It generates a new host key on
every boot, so remembering it would just produce a mismatch warning next time.
Never use them against the installed server.

## Assembly

- [ ] Both DDR5 SO-DIMMs (laptop-size memory modules) seated.
- [ ] NVMe (Non-Volatile Memory Express) drive in the **primary** M.2 slot.
      The second slot stays empty for now.
- [ ] Photograph the labels before closing the case: RAM part numbers, NVMe
      model and serial.

## BIOS

Photograph every screen you change.

- [ ] **Record the BIOS version first.** If ASRock has a newer release, update
      now, before anything is installed. If #57 chooses a TPM-sealed disk key,
      a later firmware update changes the TPM's measurements and can block
      automatic unlock.
- [ ] Restore on AC (alternating current) power loss: **power on**.
- [ ] VT-x and VT-d: **on**.
- [ ] TPM (Trusted Platform Module) 2.0 / Intel PTT (Platform Trust
      Technology): record whether it exists, and turn it **on**. This decides
      #57.
- [ ] Secure Boot: **off**. Record whether custom keys can be enrolled, for
      #47 later.
- [ ] Boot order: USB, then NVMe, for now. After the install (#13), put NVMe
      first: a stick left in after a power cut would otherwise boot the live
      system, which also accepts the ops key, instead of the server.
- [ ] Fan profile suitable for running 24/7.

## Survey

Run on the live USB, over SSH, and keep the output for the record below.

```bash
uname -r; nixos-version
dmidecode -s bios-version; dmidecode -s bios-release-date
dmidecode -t memory | grep -E 'Size|Part Number|Speed' | grep -v 'No Module'
free -g
lspci -k                                    # driver bound to the iGPU (xe) and NICs (igc)
ip -br link                                 # interface names and MAC (hardware) addresses
for i in $(ls /sys/class/net | grep -v lo); do echo "$i: $(ethtool "$i" | grep -E 'Speed|Link detected' | tr -d '\t')"; done
nvme list
smartctl -a /dev/nvme0n1 | head -40
ls /sys/class/tpm/ && tpm2_getcap properties-fixed | head -20
bootctl status 2>/dev/null | head -15       # Secure Boot state, firmware
dmesg | grep -iE 'firmware|xe |igc|error' | head -40
```

## Lost ops key

`ops` has no password, so the ops key is the only way in. Back up
`~/.ssh/id_nuc` the way the age key is backed up. Without it:

1. Make a new key, put its public half in `keys/ops.pub`, and merge that.
2. Boot this live USB (rebuilt with the new key), mount the installed root, and
   append the new public key to `etc/ssh/authorized_keys.d/ops` under it.
   NixOS rewrites that file on every activation, so the edit only has to last
   until step 3.
3. Log in as ops and rebuild from `main`, which installs the key for good.

The bootloader menu's editor (`init=/bin/sh`) is another way in. It is also
open to anyone at the console, which is why turning it off belongs with Secure
Boot (#47); after that the live USB is the only route.

## Record

Filled in from the survey output when ticket 1.1 closes.

| Item | Value |
|---|---|
| BIOS version and date | |
| RAM modules (size, part number, speed) | |
| `free -g` total | |
| NVMe model, firmware, size | |
| iGPU driver bound (`lspci -k`) | |
| NIC 1: interface, MAC, driver | |
| NIC 2: interface, MAC, driver | |
| TPM 2.0 present | |
| Secure Boot custom keys possible | |
| Kernel used for the survey | |
| `dmesg` firmware or driver errors | |
