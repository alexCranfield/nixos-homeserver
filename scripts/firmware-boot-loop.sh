#!/usr/bin/env bash
# Boot the disk-tpm test's firmware many times and count the boots that fail,
# to measure whether this machine's KVM (Kernel-based Virtual Machine) can run
# the test reliably. Issue #80; docs/runbooks/ci.md explains the results.
#
# Each boot uses the same QEMU (Quick Emulator), OVMF (Open Virtual Machine
# Firmware) build, SMM (System Management Mode) setting and emulated TPM
# (Trusted Platform Module) as the test, taken from the flake's pinned nixpkgs,
# but no disk: with nothing to boot, healthy firmware reaches its UEFI (Unified
# Extensible Firmware Interface) shell in a few seconds. A boot counts as:
#   ok     the shell, or "No bootable option", appeared on the serial console
#   crash  the firmware printed an "X64 Exception Type" line
#   died   QEMU exited by itself mid-boot (its error is shown)
#   hang   none of these before the timeout
#
# Usage: scripts/firmware-boot-loop.sh [runs] [kvm|tcg] [extra QEMU args...]
#   runs  boots to attempt (default 20)
#   kvm   hardware virtualisation, as the test uses it (default)
#   tcg   TCG (Tiny Code Generator), QEMU's software emulation: the control,
#         with no KVM involved
# FWLOOP_TIMEOUT sets the seconds before a boot counts as hung (default 40;
# a healthy boot takes about 3, under KVM or TCG).
# Run from the repo root, with Nix on PATH. Exit status: 0 if every boot was
# ok, 1 if any failed, 2 if the run itself could not be set up.
set -euo pipefail

runs=${1:-20}
accel=${2:-kvm}
shift $(($# < 2 ? $# : 2))
timeout_s=${FWLOOP_TIMEOUT:-40}

# One named output each: a bare package name can print several store paths.
pkg() { nix build --no-link --print-out-paths --inputs-from . "nixpkgs#$1"; }
# qemu_test is the build `nix flake check` runs VM tests with.
qemu=$(pkg 'qemu_test^out' || exit 2)/bin/qemu-system-x86_64
swtpm=$(pkg 'swtpm^out' || exit 2)/bin/swtpm
fv=$(pkg 'OVMFFull^fd' || exit 2)/FV
for f in "$qemu" "$swtpm" "$fv/OVMF_CODE.fd" "$fv/OVMF_VARS.fd"; do
  [ -e "$f" ] || {
    echo "missing: $f" >&2
    exit 2
  }
done

# Short, because swtpm's control socket path must be under 108 bytes.
work=$(mktemp -d /tmp/fwloop.XXXXXX)
# Stop any QEMU and swtpm still running, however the script ends.
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$work"' EXIT

ok=0 crash=0 died=0 hang=0
for i in $(seq 1 "$runs"); do
  run=$work/$i
  mkdir -p "$run/tpm"
  cp "$fv/OVMF_VARS.fd" "$run/vars.fd"
  chmod u+w "$run/vars.fd"
  : >"$run/serial.log"

  "$swtpm" socket --tpm2 --terminate --tpmstate dir="$run/tpm" \
    --ctrl type=unixio,path="$run/tpm/sock" &
  tpm_pid=$!
  for _ in $(seq 50); do
    [ -S "$run/tpm/sock" ] && break
    sleep 0.1
  done

  # The flags the NixOS test VM uses that matter here; see the nuc VM's
  # run-nuc-vm script for the full set.
  timeout -k 5 "$timeout_s" "$qemu" \
    -machine q35,smm=on,accel="$accel" -cpu max -m 2048 -smp 1 \
    -object memory-backend-memfd,id=mem0,size=2048M,share=on \
    -machine memory-backend=mem0 \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$fv/OVMF_CODE.fd" \
    -drive if=pflash,format=raw,unit=1,readonly=off,file="$run/vars.fd" \
    -global driver=cfi.pflash01,property=secure,value=on \
    -chardev socket,id=chrtpm,path="$run/tpm/sock" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0 \
    -nic none -display none -monitor none -serial file:"$run/serial.log" \
    "$@" 2>"$run/qemu.err" &
  qemu_pid=$!

  result=hang polls=0
  for _ in $(seq $((timeout_s * 4))); do
    if grep -aq 'Exception Type' "$run/serial.log"; then
      result=crash
      break
    fi
    if grep -aqE 'Shell>|UEFI Interactive Shell|No bootable option' "$run/serial.log"; then
      result=ok
      break
    fi
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
      # timeout(1) exits 124 when it stopped QEMU itself: that is a hang.
      qemu_rc=0
      wait "$qemu_pid" 2>/dev/null || qemu_rc=$?
      [ "$qemu_rc" -eq 124 ] || result=died
      break
    fi
    polls=$((polls + 1))
    sleep 0.25
  done
  kill "$qemu_pid" "$tpm_pid" 2>/dev/null || true
  wait "$qemu_pid" "$tpm_pid" 2>/dev/null || true

  detail=""
  case $result in
  ok) ok=$((ok + 1)) ;;
  crash)
    crash=$((crash + 1))
    detail=$(grep -ao 'Exception Type - [0-9A-F]*([^)]*)' "$run/serial.log" | head -1 || true)
    ;;
  died)
    # Gone within a second, with nothing on the console and no complaint
    # from KVM, is QEMU refusing its arguments: a broken run, not a
    # measurement. A KVM error that early still counts as a failed boot.
    if [ "$polls" -lt 4 ] && [ ! -s "$run/serial.log" ] &&
      ! grep -qi kvm "$run/qemu.err"; then
      echo "QEMU failed to start:" >&2
      cat "$run/qemu.err" >&2
      exit 2
    fi
    died=$((died + 1))
    detail=$(head -c 200 "$run/qemu.err" | tr '\n' ' ')
    ;;
  hang)
    hang=$((hang + 1))
    detail="$(wc -c <"$run/serial.log") bytes of console output"
    ;;
  esac
  echo "boot $i: $result${detail:+ ($detail)}"
done

echo "$accel: $ok ok, $crash crashed, $died died, $hang hung, of $runs"
[ $((crash + died + hang)) -eq 0 ]
