# Workstation setup (WSL)

The workstation is Ubuntu 24.04 under WSL2 on Windows. It builds and checks every
change before the server sees it, so it needs Nix with flakes and direnv.

## Why Nix goes straight onto the OS

Nix is not a project-scoped package. It needs the store at `/nix`, a build daemon
and a set of build users, so it installs at the system level. It does not live
inside pixi, conda or a virtualenv.

Once Nix is present it replaces pixi for this project. The repo's dev shell
(ticket 0.7) provides `just`, `sops`, `age`, `nixfmt` and `nixos-anywhere`, and
direnv loads it on `cd`. That is the same ergonomics as `pixi run` in the
ansible-nasberrypi repo, except the same flake also builds the server, so there
is one toolchain definition rather than two. This repo has no `pyproject.toml`.

## Prerequisites

WSL must run systemd, so the Nix daemon can be a normal service. Check:

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

It asks for sudo. Open a new shell afterwards so the profile script is sourced.

## Install direnv

```bash
nix profile install nixpkgs#direnv nixpkgs#nix-direnv
mkdir -p ~/.config/direnv
printf 'source $HOME/.nix-profile/share/nix-direnv/direnvrc\n' > ~/.config/direnv/direnvrc
```

`nix-direnv` is what makes `use flake` fast: it caches the evaluated shell and
adds a GC root, so entering a directory does not re-evaluate the flake every
time. Both come from Nix rather than apt so they track the same nixpkgs.

The shell hook is already in `~/.bashrc`, guarded so the shell starts cleanly
even if direnv is missing:

```bash
command -v direnv >/dev/null 2>&1 && eval "$(direnv hook bash)"
```

## Verify

```bash
nix flake --version                       # prints a version
nix run nixpkgs#hello                     # prints Hello, world!
grep experimental-features /etc/nix/nix.conf   # nix-command flakes

cd /tmp/nix-direnv-test && direnv allow    # first load builds the shell
echo $TICKET_0_1_SHELL                     # prints: loaded
hello                                      # provided only by the dev shell
```

## WSL specifics

- **Keep the store on the WSL ext4 disk.** Never put `/nix` or a checkout under
  `/mnt/c`. The 9p filesystem makes builds several times slower and breaks
  hardlinking in the store.
- **`wsl --shutdown` stops the daemon.** It restarts with systemd on the next
  launch; nothing to do by hand.
- **Disk growth.** The store grows without bound until collected. The VHDX does
  not shrink on its own, so run `nix store gc` periodically and compact the disk
  from Windows if space matters. Baseline before install: 6.9 GB used of 1007 GB.
- **Windows PATH bleed.** WSL appends the Windows PATH, so `where.exe`-style
  collisions can shadow tools. Not an issue for Nix, but worth knowing when a
  dev shell tool resolves to something unexpected.

## Uninstall

```bash
/nix/nix-installer uninstall
```

Restores the shell profiles and removes `/nix`. The `~/.bashrc` backup made
before this ticket is at `~/.bashrc.bak-preNix-<date>`.
