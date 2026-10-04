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

Write it to a USB stick from Windows with Rufus or balenaEtcher. Any stick of
2 GB or more; it is wiped. In Rufus, after you press START, a prompt asks how
to write the image: choose **DD Image mode**, never the recommended ISO mode.
ISO mode rebuilds the stick as FAT32, whose 11-character label cannot hold
`nixos-minimal-26.05-x86_64`, and the boot stops with
`Timed out waiting for device /dev/disk/by-label/nixos-minimal-...`. The file
system and cluster size fields in Rufus's main window appear in both modes and
are ignored in DD mode, so they don't show which mode was used.

Use a **USB-A** port for the keyboard and the stick. Under Linux the nuc's
USB-C ports showed no devices in the survey (see the record below and #75).

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
      The second slot stays empty for now; see "The second M.2 slot" below.
- [ ] Photograph the labels before closing the case: RAM part numbers, NVMe
      model and serial.

## BIOS

Photograph every screen you change.

- [ ] **Record the BIOS version first.** The firmware screen calls it the UEFI
      (Unified Extensible Firmware Interface) version. If ASRock has a newer
      release, update now, before anything is installed. Check the download's
      SHA-1 against ASRock's page: their checksum is for the zip as
      downloaded, not the file inside it. The update resets most settings, so
      make the ones below afterwards. The disk key will be sealed in the
      TPM (Trusted Platform Module, ADR 0009). A later firmware update can
      change what the TPM measures and block the automatic unlock once, so
      treat every update as if it will.
- [ ] Restore on AC (alternating current) power loss: **power on**.
- [ ] VT-x and VT-d: **on**.
- [ ] TPM 2.0 / Intel PTT (Platform Trust Technology): record whether it
      exists, and turn it **on**. ADR 0009's disk encryption depends on it.
      On firmware P1.10 Alex found a "TPM 2.0" setting and no PTT option; the
      survey shows it is Intel's firmware TPM.
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
smartctl -H -A /dev/nvme0n1                 # health verdict and wear
ls /sys/class/tpm/ && tpm2_getcap properties-fixed | grep -A2 -E 'FAMILY_INDICATOR|MANUFACTURER'
tpm2_getcap pcrs                            # which PCR banks exist
ls /sys/class/iommu/                        # IOMMU active if dmar* listed
bootctl status 2>/dev/null | head -15       # Secure Boot state, firmware
cryptsetup benchmark                        # disk encryption speed (ADR 0009)
lsusb -t                                    # which USB controllers see devices
ls /sys/class/typec/                        # absent if Linux manages no USB-C port
for z in /sys/class/thermal/thermal_zone*; do echo "$(cat $z/type) $(($(cat $z/temp)/1000))C"; done
dmesg | grep -iE 'firmware|xe |igc|error' | head -40
```

## Firmware updates after the install

The disk unlocks itself with a key sealed in the TPM (ADR 0009). A BIOS update,
including one that only refreshes the Secure Boot revocation list, can change
what the TPM measures, and then the next boot stops at the recovery passphrase
prompt.
So a firmware update is never done remotely or unattended:

1. Update the firmware with someone at the console.
2. At the prompt, type the recovery passphrase from the offline backup.
3. SSH in as ops (it has no password, so the console login won't work) and
   replace the TPM key, wiping the old one:
   `sudo systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/disk-main-luks`.
   Once #47 lands, bind PCR (Platform Configuration Register) 15 to its
   pre-unlock value as well, which must be written out because it is no longer
   zero on a running system:
   `--tpm2-pcrs=7+15:sha256=0000000000000000000000000000000000000000000000000000000000000000`.
4. Reboot once more and confirm it comes up without the prompt.

Before sending the whole machine away, for a warranty repair or a sale, wipe
the TPM key slot the same way, without enrolling a new one, or clear the TPM in
the BIOS.

## The second M.2 slot

Empty, and kept for a future data disk: models for the local LLMs (large
language models) and game worlds once they outgrow the shared 1 TB.

`hosts/nuc/disko.nix` names the system drive `/dev/nvme0n1`. The kernel numbers
NVMe drives in the order it finds them, so with a second drive fitted that name
may point at the wrong one, and a reinstall would wipe it. Before fitting one:

1. Find the system drive's stable name: `ls -l /dev/disk/by-id/ | grep nvme`,
   the entry without a `-part` suffix that links to the current `nvme0n1`.
2. Put that path in `disko.nix` in place of `/dev/nvme0n1`, by pull request.

The installed system does not care: it finds its partitions by label
(`disk-main-ESP`, `disk-main-luks`), not by drive name. Only disko's
partitioning, at install, uses the name.

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

Surveyed on 2026-10-04 from the live USB, over SSH.

| Item | Value |
|---|---|
| BIOS version and date | P1.10, 2026-05-26 (updated from P1.00, as shipped) |
| CPU | Intel Core Ultra X7 358H: 16 cores, no hyper-threading, AES (Advanced Encryption Standard) in hardware |
| RAM modules (size, part number, speed) | 2 × 48 GB Micron `CT48G56C46S5.M16C1`, 5600 MT/s |
| `free -g` total | 93 |
| NVMe model, firmware, size | Seagate FireCuda 530 `ZP1000GM30023`, firmware `SU6SM003`, 1.00 TB; SMART (Self-Monitoring, Analysis and Reporting Technology) passed, 0 % used |
| iGPU driver bound (`lspci -k`) | `xe`; graphics microcontroller firmware loaded (GuC, HuC, GSC and DMC blobs) |
| NPU (neural processing unit) | `intel_vpu`, firmware loaded |
| NIC 1: interface, MAC, driver | `enp44s0`, Intel I226-LM, `9c:6b:00:5c:46:51`, `igc`; 2.5 Gb/s link, DHCP lease |
| NIC 2: interface, MAC, driver | `enp45s0`, Intel I226-V, `9c:6b:00:5c:46:52`, `igc`; 2.5 Gb/s link, DHCP lease |
| Wi-Fi and Bluetooth | Intel BE211, `iwlwifi` and `btintel_pcie` (unused) |
| TPM 2.0 present | Yes: family 2.0, manufacturer `INTC`, vendor `PTL` (Intel's firmware TPM); SHA-256 bank covers PCRs 0 to 23 |
| Secure Boot | Off. Whether custom keys can be enrolled was not checked; left to #47 |
| IOMMU (input-output memory management unit) | Active: DMA (direct memory access) remapping units `dmar0` to `dmar2` |
| `cryptsetup benchmark`, aes-xts 256-bit key | about 9,400 MiB/s each way |
| Kernel used for the survey | 7.2.3 |
| Temperatures at idle | CPU 46 °C, NVMe 23 °C |
| `dmesg` firmware or driver errors | SoundWire audio link 3: bus clashes and `Clock stop failed -110` (audio only, harmless on a server). `intel-hid: failed to enable HID power button`, yet one press of the button still powered off cleanly |
| USB | USB-A works (keyboard on `0000:00:14.0`). The USB-C ports' controller (`0000:00:0d.0`) logged nothing when a keyboard was plugged into either USB-C port; whether that was through a true USB-C plug is unconfirmed. The firmware reports the USB-C connector manager (`USBC000`, `\_SB_.UBTC`) as not present (`status=0`), which is consistent with `/sys/class/typec` being absent. See #75 |

The NVMe error log held 13 entries and 8 unsafe shutdowns at 0 power-on hours,
probably from factory testing and firmware-screen power cycles. Recheck after the
install (#13) that neither grows.
