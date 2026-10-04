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

1. **The drive leaves without the machine:** a replacement, resale or disposal
   of the drive alone.
2. **The whole machine leaves:** stolen in a burglary, or sent away whole for a
   warranty repair.
3. **Someone tampers with it in place** and returns it. Not a realistic threat
   for a home server; listed so it is set aside on purpose.

Against that, the architecture depends on **unattended boot**. The BIOS (Basic
Input/Output System) firmware restores power after an outage, comin applies
kernel updates and reboots in a maintenance window (#18), and nobody is at the
console. Any unlock that needs a human turns every power cut into an outage that
lasts until someone gets home.

Encryption has to be decided before partitioning (#9). Adding it later means
wiping the drive and reinstalling.

## Options

| | Drive leaves alone | Whole machine leaves | Unattended boot | Cost |
|---|---|---|---|---|
| A. No encryption | not protected | not protected | yes | none; disposal needs a secure erase |
| B. LUKS (Linux Unified Key Setup), passphrase at the console | protected | protected | **no** | a human at every boot |
| C. LUKS, passphrase over SSH in the initrd (early boot environment) | protected | protected | **no** | as B, but from the sofa; LAN only |
| D. LUKS, key sealed in the TPM | protected | **not yet**; partly after Secure Boot (#47) | yes | one enrolment step after install |
| E. LUKS, key released by a Tang server on the LAN | protected | protected, unless the Tang server is taken too | yes, while the LAN and that server are up | a service on another always-on device |
| F. Encrypt only `/srv/data` | host key not protected | host key not protected | yes | does not address this ADR's problem |

Notes on the less obvious cells:

- **D without Secure Boot.** The key is sealed to PCR (Platform Configuration
  Register) 7, which records the Secure Boot state and keys. With Secure Boot
  off, a thief who boots their own USB stick reproduces the same PCR 7 value
  and the TPM releases the key. So D protects scenario 1 at once, and does not
  yet protect scenario 2.
- **D with Secure Boot, and what it still leaves.** #47 turns on Secure Boot with
  Alex's own keys and turns off the boot menu editor, which otherwise allows
  `init=/bin/sh` once the disk is unlocked. That closes the boot-time routes to
  a root shell. A stolen machine still boots, unlocks itself and runs, so three
  routes remain:
  - **A swapped root.** An attacker can replace the root partition with one
    they control. PCR 7 is never extended after unlock, so their code can still
    unseal the real key. The fix is to measure the unlocked volume into PCR 15
    and bind the key to PCR 7 and 15 together; #47 does that.
  - **DMA (Direct Memory Access) through USB4 or Thunderbolt.** This needs the
    IOMMU (input-output memory management unit) on. VT-d is enabled in the BIOS
    checklist; #45 confirms the kernel uses it.
  - **The running services.** A powered-on server is a target like any other.
    Hardening them is #45's subject, not this ADR's.
  So after #47, a whole machine is *partly* protected: the easy routes are
  closed, and the remaining ones need real effort or a vulnerability.
- **Why PCR 7 and not more.** PCR 7 does not change when the kernel or the NixOS
  generation changes, so comin's updates never break the unlock. PCR 4 changes
  with every kernel update, and PCRs 0 and 2 with every firmware update, so
  binding to them would turn routine updates into locked reboots.
- **What does change PCR 7.** Any change to the Secure Boot variables: turning
  Secure Boot on or off, new keys, or a revocation-list (dbx) update, which BIOS
  releases often carry even with Secure Boot off. A firmware release can also
  change how those events are measured. Every such change sends the next boot
  to the recovery prompt, so firmware updates are attended events (see
  Consequences).
- **E's catch.** It needs another always-on device to run Tang; the existing
  NAS (network-attached storage) is the obvious candidate, which puts work in
  that separate project. After a power cut, the nuc can unlock only once that
  device is back up. On NixOS, Clevis, the client side, unlocks from its own
  encrypted secret file, so adding E to D later means a separate key slot, not
  one combined policy.
- **Every LUKS option keeps a recovery passphrase** in a second key slot. If
  the automatic unlock fails, the boot stops at a passphrase prompt instead of
  failing outright.

The pinned nixpkgs already supports all of this: systemd in the initrd is on
(`boot.initrd.systemd.enable = true`, with `tpm2.enable = true`, which loads the
`tpm-crb` driver Intel's firmware TPM uses), Clevis exists
(`boot.initrd.clevis`), and disko's LUKS type takes a passphrase file and
`settings` for `boot.initrd.luks.devices`. disko does not enrol TPM keys, so D
adds one command after the first boot.

## Recommendation

**D, if the survey finds a TPM 2.0 (Intel PTT, Platform Trust Technology):**
LUKS2 for the whole root, unlocked by a TPM key sealed to PCR 7, with a recovery
passphrase kept offline like the age key backup.

- It is the only option that keeps unattended boot and protects scenario 1
  from day one.
- #47 extends it to partial protection of scenario 2, with the acceptance
  criteria listed under Decision.
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

What goes with the decision:

- **#47 (Secure Boot) carries the criteria that make D protect a stolen
  machine.** They are in that issue's acceptance criteria:
  - Secure Boot on, with Alex's own keys enrolled;
  - the boot menu editor off;
  - the unlocked volume measured into PCR 15, with the TPM key bound to PCRs 7
    and 15;
  - re-enrolment with `systemd-cryptenroll --wipe-slot=tpm2`. Adding a new TPM
    key without wiping the old one leaves a key that still unseals with Secure
    Boot turned off, which undoes the rest.

  Turning Secure Boot on changes PCR 7, so that one boot stops at the recovery
  prompt and is attended.
- **#9's layout and #13's install implement it,** as the consequences below
  describe.
- **A VM (virtual machine) test proves the unlock before the real install,** as
  #57 requires.

## Consequences

- **Install (#13).** The recovery passphrase is generated before the install
  and is the first key slot: nixos-anywhere copies it to the target with
  `--disk-encryption-keys <remote path> <local file>`, disko's `passwordFile`
  points at that path, and the local file is deleted once the passphrase is in
  the offline backup. After the first boot, ops runs
  `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7` on the LUKS partition.
  The reinstall runbook (#15) records both steps.
- **Layout (#9).** The btrfs subvolumes go inside one LUKS2 container. The ESP
  (EFI System Partition) stays unencrypted, as it must. Discards (TRIM) are
  allowed for the SSD's sake, which reveals which blocks are in use but nothing
  of their content.
- **Testing.** QEMU (Quick Emulator) can emulate a TPM
  (`virtualisation.tpm.enable`), but its default direct kernel boot skips the
  firmware, so nothing is measured into PCR 7. #9's test needs a measured boot:
  `useBootLoader`, `useEFIBoot` and `efi.OVMF = pkgs.OVMFFull`, as in nixpkgs'
  `systemd-initrd-luks-tpm2` test. That test enrols with no PCRs at all, so
  copying it would prove nothing about PCR 7. The negative control is a key
  enrolled against a different PCR 7 value, which must fall back to the
  passphrase prompt.
- **Firmware updates are attended.** The BIOS is updated before the install
  (hardware runbook). After that, any firmware or revocation-list update is done
  with someone at the console: the next boot stops at the recovery prompt, the
  passphrase is typed, and the TPM key is re-enrolled with
  `systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7` (plus
  15 once #47 lands). The hardware runbook carries this rule.
- **Sending the machine away.** Before a warranty repair or sale of the whole
  NUC, wipe the TPM key slot (`systemd-cryptenroll --wipe-slot=tpm2`) or clear
  the TPM in the BIOS. The machine then stops at the passphrase prompt instead
  of unlocking for whoever has it.
- **Failure mode.** If the TPM refuses the key for any reason, the server waits
  at the recovery prompt until someone types the passphrase at the console.
  That is an outage, not data loss.
- **Performance.** AES (Advanced Encryption Standard) runs in hardware on this
  CPU. The survey can measure the cost with `cryptsetup benchmark`; it is not
  expected to matter for game servers or model loading.
- **ADR 0004.** Its consequences gain a line: the host key is protected at rest
  only as far as this ADR protects the disk.
