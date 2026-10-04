# Test script for tests/disk-tpm.nix, which explains what the test proves.
#
# Not run on its own. The NixOS test driver runs it, and provides the names
# not defined here:
#   - from the driver: `nuc` (the VM), `subtest`;
#   - from the preamble disk-tpm.nix puts in front of this file: PASSPHRASE,
#     WRONG_PCR7, FORMAT_MOUNT, UNMOUNT and INSTALLED.
import re
import shlex
import time

# systemd names the disk by its partition label, then the mapping:
# "Please enter passphrase for disk disk-main-luks (cryptroot):".
PROMPT = r"Please enter passphrase for disk \S+ \(cryptroot\)"

BOOTED = "Reached target Multi-User System"

# The passphrase quoted for the guest's shell.
QUOTED = shlex.quote(PASSPHRASE)


def boot(expect_prompt, timeout=600):
    """Start the VM and see which comes first on the console: the passphrase
    prompt or the end of the boot. Bounded, so a wrong outcome fails in
    minutes instead of hanging until CI (continuous integration) gives up.
    Not wait_for_console_text(timeout=...), which reads one console line per
    second and falls behind a booting kernel."""
    nuc.start()
    deadline = time.monotonic() + timeout
    while True:
        console = nuc.get_console_log()
        prompted = re.search(PROMPT, console) is not None
        if prompted or BOOTED in console:
            break
        assert time.monotonic() < deadline, "neither a prompt nor a boot"
        time.sleep(1)
    assert prompted == expect_prompt, f"passphrase prompt shown: {prompted}"
    if prompted:
        nuc.send_console(PASSPHRASE + "\n")
    nuc.wait_for_unit("multi-user.target")


def reboot(expect_prompt):
    nuc.succeed("sync")
    nuc.crash()
    boot(expect_prompt)


with subtest("disko formats and mounts the blank disk"):
    nuc.wait_for_unit("multi-user.target")
    nuc.succeed(f"printf %s {QUOTED} > /tmp/disk.key")
    nuc.succeed(FORMAT_MOUNT)
    nuc.succeed(UNMOUNT)
    nuc.succeed("rm /tmp/disk.key")
    nuc.succeed(f"{INSTALLED}/bin/switch-to-configuration boot")
    # That adds the installed system as a second boot menu entry; the default
    # stays the test system. Make it the default, as on the NUC.
    entry = nuc.succeed(
        "ls /boot/loader/entries"
        " | grep -x 'nixos-generation-[0-9]*-specialisation-installed.conf'"
    ).strip()
    nuc.succeed(f"bootctl set-default {entry}")

with subtest("first boot stops at the passphrase prompt"):
    reboot(expect_prompt=True)

with subtest("the root is btrfs inside LUKS2"):
    source = nuc.succeed("findmnt -no SOURCE,FSTYPE /").strip()
    print(source)
    assert source == "/dev/mapper/cryptroot[/@root] btrfs", source
    nuc.succeed("cryptsetup luksDump /dev/vdb2 | grep -qx 'Version:.*2'")
    # Discards reach the disk (ADR 0009).
    nuc.succeed("dmsetup table cryptroot | grep -q allow_discards")

with subtest("every subvolume is mounted where disko.nix says"):
    mounts = {
        "/": "@root",
        "/nix": "@nix",
        "/home": "@home",
        "/srv": "@srv",
        "/var/lib/docker": "@docker",
        "/.snapshots": "@snapshots",
        "/.swapvol": "@swap",
    }
    for target, subvol in mounts.items():
        got = nuc.succeed(f"findmnt -no SOURCE {target}").strip()
        assert got == f"/dev/mapper/cryptroot[/{subvol}]", (target, got)

with subtest("16 GiB of swap, inside the encrypted volume"):
    swaps = nuc.succeed("swapon --show=NAME --noheadings").split()
    assert swaps == ["/.swapvol/swapfile"], swaps
    # The file's size: swapon reports one 4 KiB page less, the swap header.
    size = nuc.succeed("stat -c %s /.swapvol/swapfile").strip()
    assert size == str(16 * 1024**3), size

with subtest("the ESP is 1 GiB of vfat"):
    size = nuc.succeed("lsblk -bndo SIZE /dev/vdb1").strip()
    assert size == str(1024**3), size
    fstype = nuc.succeed("blkid -o value -s TYPE /dev/vdb1").strip()
    assert fstype == "vfat", fstype

with subtest("data is compressed with zstd"):
    # 64 MiB of one repeated byte compresses to almost nothing, if allowed.
    nuc.succeed("head -c 64M /dev/zero | tr '\\0' a > /srv/probe && sync")
    out = nuc.succeed("compsize -b /srv/probe")
    print(out)
    assert re.search(r"^zstd ", out, re.M), "/srv/probe was not compressed"

with subtest("PCR 7 holds a measurement, so the boot was measured"):
    # On kernel 7.2 the CRB driver is named tpm_crb_acpi; the TIS one, QEMU's
    # other interface, would be tpm_tis.
    driver = nuc.succeed(
        "basename $(readlink /sys/class/tpm/tpm0/device/driver)"
    ).strip()
    print(f"TPM driver: {driver}")
    assert driver.startswith("tpm_crb"), driver
    pcr7 = nuc.succeed("systemd-analyze pcrs 7 --json=short")
    print(pcr7)
    assert re.search(r'"sha256":"[0-9a-f]{64}"', pcr7), pcr7
    assert '"sha256":"' + "0" * 64 + '"' not in pcr7, "PCR 7 is all zeros"

with subtest("with a TPM key enrolled, the next boot is unattended"):
    # The enrolment command ADR 0009 gives for the install.
    nuc.succeed(
        f"PASSWORD={QUOTED} systemd-cryptenroll"
        " --tpm2-device=auto --tpm2-pcrs=7 /dev/vdb2"
    )
    reboot(expect_prompt=False)
    print(nuc.succeed("cryptsetup luksDump /dev/vdb2"))
    # The recovery passphrase keeps its own slot beside the TPM key.
    nuc.succeed("cryptsetup luksDump /dev/vdb2 | grep -q systemd-tpm2")
    nuc.succeed(
        f"printf %s {QUOTED} | cryptsetup open --test-passphrase /dev/vdb2 -"
    )

with subtest("a key sealed to a different PCR 7 falls back to the passphrase"):
    # What a Secure Boot or firmware change does to the real key.
    nuc.succeed(
        f"PASSWORD={QUOTED} systemd-cryptenroll --wipe-slot=tpm2"
        f" --tpm2-device=auto --tpm2-pcrs=7:sha256={WRONG_PCR7} /dev/vdb2"
    )
    reboot(expect_prompt=True)
    nuc.succeed("findmnt -no SOURCE / | grep -q '^/dev/mapper/cryptroot'")
    # --wipe-slot=tpm2 replaced the key rather than adding a second one.
    tokens = nuc.succeed(
        "cryptsetup luksDump /dev/vdb2 | grep -c systemd-tpm2"
    ).strip()
    assert tokens == "1", f"{tokens} TPM keys enrolled"
