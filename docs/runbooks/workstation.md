# Workstation setup (WSL)

The workstation is Ubuntu 24.04 under WSL2 on Windows. It builds and checks every
change before the server sees it, so it needs Nix with flakes and direnv.

Completed 2026-09-07 (ticket 0.1). Versions installed: Determinate Nix 3.22.3
(Nix 2.35.2), direnv 2.37.1, nix-direnv 3.2.0.

## Why Nix goes straight onto the OS

Nix is not a project-scoped package. It needs the store at `/nix`, a build daemon
and a set of build users, so it installs at the system level. It does not live
inside pixi, conda or a virtualenv.

Once Nix is present it replaces pixi for this project. The repo's dev shell
(ticket 0.7) provides `just`, `sops`, `age`, `nixfmt` and `nixos-anywhere`, and
direnv loads it on `cd`. That is the same ergonomics as `pixi run` in the
ansible-nas repo, except the same flake also builds the server, so there
is one toolchain definition rather than two. This repo has no `pyproject.toml`.

## Prerequisites

WSL must run systemd so the Nix daemon can be a normal service. Check:

```bash
ps -p 1 -o comm=          # expect: systemd
cat /etc/wsl.conf         # expect: [boot] systemd=true
```

If systemd is off, add the `[boot]` section and run `wsl --shutdown` from
PowerShell before continuing.

## Install Nix

The Determinate installer is used rather than the upstream script: it enables
flakes and `nix-command` by default, installs the daemon as a systemd unit, and
provides a clean uninstall.

```bash
curl -fsSL https://install.determinate.systems/nix | sh -s -- install
```

**Run this in a real terminal window.** It prompts twice, once for its own
confirmation and once for sudo. Neither prompt can be answered from a
non-interactive context, and the installer exits without touching the system if
it cannot ask. Append `--no-confirm` to skip the first prompt; the sudo prompt
still needs a terminal.

Open a new shell afterwards so the profile script is sourced.

## Install direnv

```bash
nix profile add nixpkgs#direnv nixpkgs#nix-direnv
mkdir -p ~/.config/direnv
printf 'source $HOME/.nix-profile/share/nix-direnv/direnvrc\n' > ~/.config/direnv/direnvrc
```

Nix 2.35 renamed `nix profile install` to `nix profile add`. The old name still
works but warns.

`nix-direnv` is what makes `use flake` fast: it caches the evaluated shell and
adds a GC root, so entering a directory does not re-evaluate the flake every
time. A cold load of a two-package shell took about 90 seconds (mostly fetching
stdenv); the cached load after that took 0.07 seconds. Both come from Nix rather
than apt so they track the same nixpkgs.

The shell hook lives in `~/.bashrc`, guarded so the shell still starts cleanly
if direnv is absent:

```bash
command -v direnv >/dev/null 2>&1 && eval "$(direnv hook bash)"
```

## Verify

```bash
nix flake --version                             # Determinate Nix 3.22.3 (Nix 2.35.2)
nix run nixpkgs#hello                           # Hello, world!
grep experimental-features /etc/nix/nix.conf    # extra-experimental-features = nix-command flakes

mkdir -p /tmp/nix-direnv-test && cd /tmp/nix-direnv-test
# flake.nix with a devShell exporting TICKET_0_1_SHELL and providing hello
echo "use flake" > .envrc && direnv allow
direnv exec . bash -c 'echo $TICKET_0_1_SHELL; hello'   # loaded / Hello, world!
```

## WSL specifics

- **PATH is only wired for login shells.** The installer writes
  `/etc/profile.d/nix.sh` and appends to `/etc/bash.bashrc`. Non-login,
  non-interactive shells (scripts, CI runners, editor tasks, coding agents) get
  neither, so `nix` appears missing. Source it explicitly at the top of any such
  script:

  ```bash
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  ```

- **Keep the store on the WSL ext4 disk.** Never put `/nix` or a checkout under
  `/mnt/c`. The 9p filesystem makes builds several times slower and breaks
  hardlinking in the store. Confirm with `stat -f -c '%T' /nix`, which should
  report an ext filesystem rather than `v9fs`.
- **`wsl --shutdown` stops the daemon.** It restarts with systemd on the next
  launch; nothing to do by hand.
- **Disk growth.** The store was 1.2 GB after this ticket and grows without bound
  until collected. The VHDX does not shrink on its own, so run `nix store gc`
  periodically and compact the disk from Windows if space matters. Root
  filesystem baseline: 7.2 GB used of 1007 GB.
- **Windows PATH bleed.** WSL appends the Windows PATH, so collisions can shadow
  tools. Not an issue for Nix, but worth knowing when a dev shell tool resolves
  to something unexpected.

## Uninstall

```bash
/nix/nix-installer uninstall
```

Restores the shell profiles and removes `/nix`. The `~/.bashrc` backup made
before this ticket is at `~/.bashrc.bak-preNix-20260907`.
