# ADR 0009: Disk encryption on the nuc

Date: 2026-10-03. Status: accepted, on condition that the hardware survey (#8)
finds a TPM (Trusted Platform Module) 2.0.

## Context

The nuc's age identity, which decrypts every server secret, is derived from
`/etc/ssh/ssh_host_ed25519_key` (ADR 0004, ticket 1.7). On an unencrypted
NVMe (Non-Volatile Memory Express) drive, whoever holds the drive holds that
key, and with it the Tailscale auth key, the restic repository password, the
game servers' RCON (remote console) passwords, and every secret added later.
sops cannot help, because the key that opens it all is in plaintext.

The ways the drive or the machine leave Alex's control, most likely first:

1. **The drive leaves without the machine:** a warranty return, a replacement,
   resale or disposal.
2. **The whole machine is stolen** in a burglary.
3. **Someone tampers with it in place** and returns it. Not a realistic threat
   for a home server; listed so it is set aside on purpose.

Against that, the architecture depends on **unattended boot**. The BIOS
restores power after an outage, comin applies kernel updates and reboots in a
maintenance window (#18), and nobody is at the console. Any unlock that needs a
human turns every power cut into an outage that lasts until someone gets home.

Encryption has to be decided before partitioning (#9). Adding it later means
wiping the drive and reinstalling.

## Options

| | Drive leaves alone | Machine stolen | Unattended boot | Cost |
|---|---|---|---|---|
| A. No encryption | not protected | not protected | yes | none; disposal needs a secure erase |
| B. LUKS (Linux Unified Key Setup), passphrase at the console | protected | protected | **no** | a human at every boot |
| C. LUKS, passphrase over SSH in the initrd (early boot environment) | protected | protected | **no** | as B, but from the sofa; LAN only |
| D. LUKS, key sealed in the TPM | protected | **not yet**; protected after Secure Boot (#47) | yes | one enrolment step after install |
| E. LUKS, key released by a Tang server on the LAN | protected | protected, unless the Tang server is taken too | yes, while the LAN and that server are up | a service on another always-on device |
| F. Encrypt only `/srv/data` | host key not protected | host key not protected | yes | does not address this ADR's problem |

Notes on the less obvious cells:

- **D without Secure Boot.** The key is sealed to PCR (Platform Configuration
  Register) 7, which records the Secure Boot state. With Secure Boot off, a
  thief who boots their own USB stick reproduces the same PCR 7 value and the
  TPM releases the key. So D protects a drive that leaves *without* its TPM,
  which is scenario 1, at once. It protects against scenario 2 only once #47
  enables Secure Boot with Alex's own keys and turns off the boot menu editor,
  which otherwise allows `init=/bin/sh` after the disk is unlocked.
- **Why PCR 7 and not more.** PCR 7 does not change when the kernel or the
  NixOS generation changes, so comin's updates never break the unlock. Binding
  to the firmware or bootloader registers (0, 2, 4) would make every update a
  locked reboot. A firmware update that resets the Secure Boot keys does change
  PCR 7. That is why the hardware runbook says to update the BIOS before
  anything is installed.
- **E's catch.** It needs another always-on device to run Tang; the existing
  NAS (network-attached storage) is the obvious candidate, which puts work in that separate project. After
  a power cut, the nuc can unlock only once that device is back up. Clevis, the
  client side, can also combine methods, so E can be added on top of D later.
- **Every LUKS option keeps a recovery passphrase** in a second key slot. If
  the automatic unlock fails, for example after a BIOS reset, the boot stops at
  a passphrase prompt instead of failing outright.

The pinned nixpkgs already supports all of this: systemd in the initrd is on
(`boot.initrd.systemd.enable = true`, with `tpm2.enable = true`), Clevis exists
(`boot.initrd.clevis`), and disko's LUKS type takes a passphrase file and
`settings` for `boot.initrd.luks.devices`. disko does not enrol TPM keys, so D
adds one command after the first boot.

## Recommendation

**D, if the survey finds a TPM 2.0 (Intel PTT, Platform Trust Technology):**
LUKS2 for the whole root, unlocked by a TPM key sealed to PCR 7, with a recovery
passphrase kept offline like the age key backup.

- It is the only option that keeps unattended boot and protects scenario 1
  from day one.
- It becomes protection against theft once #47 lands. #47 gets the specific
  acceptance criteria to make that true: Secure Boot on with enrolled keys, the
  editor off, PCR 7 re-enrolled.
- The irreversible part, the encrypted container, is done now. The
  strengthening is configuration that does not need a reinstall.

**If there is no TPM:** choose between E (needs the Tang service elsewhere) and
A (no encryption, with a secure erase in the disposal path). B and C are ruled
out by unattended boot.

## Decision

**D.** Alex chose it on 2026-10-03. The whole root goes in a LUKS2 container,
unlocked at boot by a TPM key sealed to PCR 7, with a recovery passphrase in a
second key slot, kept offline like the age key backup.

The one condition is the TPM itself. If the survey in #8 finds no TPM 2.0, or
one the firmware cannot enable, this ADR is reopened to choose between E and A.
It does not fall back to either silently.

Three things go with the decision:

- **#47 (Secure Boot) gets the criteria that make D protect against theft:**
  Secure Boot on with Alex's own keys, the boot menu editor off, and the TPM key
  re-enrolled against the new PCR 7.
- **#9's layout and #13's install implement it,** as the consequences below
  describe.
- **A VM test proves the unlock before the real install,** as #57 requires.

## Consequences

- **Install (#13).** nixos-anywhere passes the initial passphrase with
  `--disk-encryption-keys`, and disko formats the LUKS container with it. After
  the first boot, ops runs `systemd-cryptenroll --tpm2-device=auto
  --tpm2-pcrs=7` on the partition, and the reinstall runbook (#15) records the
  command.
- **Layout (#9).** The btrfs subvolumes go inside one LUKS2 container. The
  EFI (Extensible Firmware Interface) system partition stays
  unencrypted, as it must. Discards (TRIM) are allowed for the SSD's sake,
  which reveals which blocks are in use but nothing of their content.
- **Testing.** The QEMU (Quick Emulator) VM (virtual machine) supports an
  emulated TPM (`virtualisation.tpm.enable`), so #9 can test the boot path,
  unlock included, in a VM before the real install. #57's acceptance criteria
  require that.
- **Failure mode.** If the TPM refuses, after a BIOS reset or a Secure Boot key
  change, the server waits at a passphrase prompt until someone types the
  recovery passphrase at the console. That is an outage, not data loss.
- **Performance.** AES (Advanced Encryption Standard) runs in hardware on this
  CPU. The survey can measure the cost with `cryptsetup benchmark`; it is not
  expected to matter for game servers or model loading.
- **ADR 0004.** Its consequences gain a line: the host key is protected at
  rest only as far as this ADR's choice protects it.
