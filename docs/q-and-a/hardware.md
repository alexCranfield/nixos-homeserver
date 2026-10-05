# Hardware, firmware and boot media

### Is the UEFI version the BIOS version?

*2026-10-03*

> I see a UEFI version, is that the BIOS? NUC-358H P1.00

<details>
<summary>Answer</summary>

Yes. UEFI (Unified Extensible Firmware Interface) is the firmware standard that
replaced the original BIOS (Basic Input/Output System) on PCs. Almost every
machine since about 2012 runs UEFI, but the old name stuck, so "BIOS", "UEFI"
and "firmware" are used for the same thing: the setup screens and the code
that runs before the operating system.

The difference matters in a few places in this repo. Secure Boot, the boot
menu systemd-boot uses, and the EFI (Extensible Firmware Interface) System
Partition all exist only under UEFI. The TPM's (Trusted Platform Module's)
measurements of the boot are made by the UEFI firmware too.

</details>

### Does the firmware's checksum apply to the extracted file?

*2026-10-03*

> The has dooesn't match

<details>
<summary>Answer</summary>

Usually not. A vendor publishes the checksum of the file it serves, here a
zip. The firmware file inside the zip is different bytes, so it has a different
hash. Hash the download itself, before extracting it. If that matches, the
download arrived intact, and so did everything inside it.

On Windows: `Get-FileHash <file> -Algorithm SHA1` in PowerShell, or
`certutil -hashfile <file> SHA1`. In WSL (Windows Subsystem for Linux):
`sha1sum /mnt/c/Users/<you>/Downloads/<file>`. Letter case doesn't matter
when comparing.

A checksum from the same page as the download proves the file arrived
undamaged. It proves less about tampering: anyone able to change the file on
that server could change the checksum next to it. A signature checked with a
key you got elsewhere protects against that; a checksum does not.

</details>

### What is the difference between Rufus's DD mode and ISO mode?

*2026-10-03*

> Whats the difference between dd and iso mode

<details>
<summary>Answer</summary>

**DD mode copies the image byte for byte.** The stick becomes an exact copy of
the ISO, with the same partitions, file system, label and bootloader. The name
comes from `dd`, the Unix block-copy tool. Nothing is reinterpreted, so what
boots is exactly what the image's makers built and tested. Windows may then
call the stick unreadable and offer to format it; don't let it.

**ISO mode rebuilds the stick.** Rufus formats it as FAT32, copies the files
out of the ISO, and installs its own boot setup. The stick stays a normal
readable drive, which suits Windows installers. But anything the image relied
on beyond its files can be lost. Here it was the volume label: NixOS's early
boot waits for the disk labelled `nixos-minimal-26.05-x86_64`, FAT32 labels
hold 11 characters, and the boot timed out. Rufus asks which mode to use in a
prompt after START. The file system and cluster size fields in its main window
show up either way, so they are not a sign of ISO mode; DD mode ignores them.

Rule of thumb: use DD mode for Linux images. Most are "hybrid" images, made to
be copied raw onto a stick. ISO mode is Rufus guessing how to rebuild one; for
many distributions it guesses right, which is why it is the default.

</details>

### Is the TPM setting under Secure Boot?

*2026-10-03*

> TPM would be under secure boot tight?

<details>
<summary>Answer</summary>

Usually not: they are separate settings, often on separate menus. On AMI
(American Megatrends) firmware like this nuc's, the TPM is usually under
Advanced (often a "Trusted Computing" page), and Secure Boot under Security or
Boot. On firmware P1.10 the TPM setting Alex found was labelled "TPM 2.0", with
no mention of PTT (Platform Trust Technology).

They are related, which is why it's easy to assume they go together:

- **Secure Boot** decides what is allowed to run: the firmware refuses a
  bootloader not signed by a trusted key.
- **The TPM** records what did run. Each boot stage is measured into its PCRs
  (Platform Configuration Registers), and the TPM releases a sealed secret, such
  as ADR (Architecture Decision Record) 0009's disk key, only when those
  measurements match.

Each is weak alone. ADR 0009 seals its key to PCR 7, which records the Secure
Boot state rather than the exact software booted. Without Secure Boot, an
attacker can boot their own software and still reproduce PCR 7. Without the TPM,
nothing ties the disk key to the boot at all. ADR 0009 and #47 combine them.

</details>

### Is a 1 GiB EFI System Partition big enough?

*2026-10-04*

> Is 1GB large enough for the EF00 drive?

<details>
<summary>Answer</summary>

Yes, with room to spare. `EF00` is the GPT (GUID Partition Table) type code
for the ESP (EFI System Partition), a partition rather than a drive. It holds
only what the firmware must read before anything is decrypted:

- the systemd-boot loader, well under 1 MB;
- one kernel and one initrd (the early boot environment) per boot menu entry.

NixOS names those files by their content, so generations with the same kernel
and initrd share one copy, and only a kernel update or an initrd change adds a
new pair. A pair is roughly 50 to 70 MB; the disk test's kernel reported about
42 MB for the initrd alone. `boot.loader.systemd-boot.configurationLimit = 10`
caps the menu at ten entries, so even ten different kernels come to about
700 MB.

If it ever filled up, `nixos-rebuild` would fail while installing the boot
loader, and the machine would still boot from what is already there. Actual
usage is measured after the install (#13).

</details>
