# Test script for tests/reboot-window.nix. `nuc` is the test driver's machine;
# KERNEL_LATEST and KERNEL_OTHER are defined by the Nix file in front of it.
#
# The driver starts QEMU with -no-reboot, so a reboot inside the VM ends the
# QEMU process: wait_for_shutdown() returning is the proof that it rebooted.

import re
import time

assert KERNEL_LATEST != KERNEL_OTHER, (KERNEL_LATEST, KERNEL_OTHER)


def wait_console(pattern, timeout, since=0):
    """The first match of `pattern` on the console after offset `since`,
    waiting up to `timeout` s.

    Not wait_for_console_text(timeout=...): that takes one queued console line
    per second, and with the whole boot log still queued it misses a line
    printed in time. The full log is searched instead.
    """
    deadline = time.monotonic() + timeout
    while not (m := re.compile(pattern, re.M).search(nuc.get_console_log(), since)):
        assert time.monotonic() < deadline, f"{pattern!r} not on the console in {timeout} s"
        time.sleep(1)
    return m


def window():
    """Run the window's service once and return its log for this run."""
    nuc.succeed("systemctl start reboot-window.service")
    # -I: the latest invocation only.
    return nuc.succeed("journalctl -u reboot-window.service -I -o cat --no-pager")


def switch(name):
    # As comin does, minus the boot entry: switch the running system.
    nuc.succeed(
        f"/run/booted-system/specialisation/{name}/bin/switch-to-configuration test"
    )


nuc.wait_for_unit("multi-user.target")

with subtest("the timer fires on Tuesdays at 10:00 UTC and is not made up at boot"):
    timer = nuc.succeed(
        "systemctl show reboot-window.timer -P TimersCalendar -P Persistent"
    )
    print(timer)
    assert "OnCalendar=Tue *-*-* 10:00:00" in timer, timer
    assert timer.strip().splitlines()[-1] == "no", timer
    nuc.succeed("systemctl is-active reboot-window.timer")
    nxt = nuc.succeed("systemd-analyze calendar --iterations=1 'Tue *-*-* 10:00:00'")
    print(nxt)
    assert "Tue" in nxt and "10:00:00 UTC" in nxt, nxt

with subtest("nothing changed: no reboot"):
    log = window()
    print(log)
    assert "unchanged since boot: no reboot" in log, log

with subtest("a configuration-only change deploys and does not reboot"):
    switch("config")
    # The new banner is live: the switch took effect without a reboot.
    banner = nuc.succeed("cat $(grep -o 'motd=[^ ]*' /etc/pam.d/sshd | cut -d= -f2)")
    assert "a configuration-only change" in banner, banner
    log = window()
    print(log)
    assert "unchanged since boot: no reboot" in log, log
    assert KERNEL_LATEST in nuc.succeed("uname -r"), "kernel changed without a reboot?"

with subtest("a kernel change does not reboot at the switch; the window's service then does"):
    switch("kernel")
    # Switching alone does not reboot: the machine keeps running the old kernel.
    nuc.succeed("sleep 5")
    assert KERNEL_LATEST in nuc.succeed("uname -r")
    nuc.succeed("systemctl start --no-block reboot-window.service")
    # The pre-reboot commands run, in order, and a failing one does not stop
    # the reboot.
    rebooting = wait_console(r"reboot-window-start\[\d+\]: rebooting\s*$", 120)
    # The quotes, the unset variable and the backtick reached bash intact.
    first = wait_console(r"reboot-window-start\[\d+\]: hook-one-ran \[\] `x`", 0)
    failed = wait_console(r"pre-reboot command failed \(exit 1, 124 if stopped\); rebooting anyway", 0)
    assert first.start() < failed.start() < rebooting.start(), "hooks out of order"
    nuc.wait_for_shutdown()

with subtest("after the reboot the machine comes back"):
    # QEMU boots the configuration the test was built with again, not the
    # specialisation; on the real host the boot entry would carry the new one.
    nuc.start()
    nuc.wait_for_unit("multi-user.target")
    log = window()
    print(log)
    assert "unchanged since boot: no reboot" in log, log

with subtest("a kernel parameter change also reboots"):
    switch("params")
    since = len(nuc.get_console_log())
    nuc.succeed("systemctl start --no-block reboot-window.service")
    wait_console(r"reboot-window-start\[\d+\]: [^\n]*parameters differ", 120, since)
    nuc.wait_for_shutdown()
