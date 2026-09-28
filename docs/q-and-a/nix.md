# Nix and NixOS

### Do we install Nix inside a pixi environment, or straight onto the operating system?

*2026-09-07*

> How do we plan to install nix? Within a pixi env or just straight onto the OS?

<details>
<summary>Answer</summary>

Straight onto the operating system. Nix is not a project-scoped package that can
be wrapped: it needs the store at `/nix`, a build daemon, and a set of build
users, so it installs at the system level. Pixi manages conda-forge packages
inside a project, which is the wrong layer entirely.

The second reason is that once Nix exists, it takes over pixi's job. The repo's
dev shell provides `just`, `sops`, `age` and the rest, and direnv loads it on
`cd`. That is the same ergonomics as `pixi run` in the earlier Ansible project,
except the same flake also builds the server, so there is one toolchain
definition instead of two. This repo has no `pyproject.toml`.

Pixi stays where it is for the Ansible NAS (network-attached storage) repo.

</details>

### What is Determinate Nix, and are we using it?

*2026-09-07*

> I'm reading the quickstart guide first, what's determinate nix and are we using it?

<details>
<summary>Answer</summary>

Yes, we are using it. The version string on the workstation reads
`nix (Determinate Nix 3.22.3) 2.35.2`.

Determinate Nix is a downstream *distribution* of Nix, not a wrapper or an
installer flavour. Determinate Systems rebase it continuously on upstream Nix
and add features on top, so 3.22.3 is their versioning built on upstream 2.35.2.
They stopped shipping plain upstream Nix through their installer in early 2026.

Three of their additions are live in `/etc/nix/nix.conf`, a file whose own header
warns it will be overwritten, so custom settings belong in `nix.custom.conf`
beside it.

- `lazy-trees = true` avoids copying whole repositories into the store during
  evaluation.
- `eval-cores = 0` enables parallel evaluation.
- `extra-nix-path` rewires the bare name `nixpkgs` to a FlakeHub weekly
  snapshot, served from a binary cache their installer added to the trusted
  substituters.

That third one matters most. When `nix run nixpkgs#hello` was used as an
acceptance test, it did **not** use the NixOS channel. It used Determinate's
snapshot. This is exactly why our flake pins `nixpkgs` by explicit URL rather
than the bare name: with the pin, the workstation and the server evaluate
identical sources. Without it, they would silently diverge.

Two practical notes. Documentation saying "requires Nix 2.4 or later" applies,
since 3.x is Determinate's own numbering rather than a claim about upstream. And
if something behaves in a way no tutorial describes, lazy trees is the first
thing to suspect, being the most invasive of the changes.

</details>

### Should the workstation and the server run matching Nix versions?

*2026-09-07*

> Should we commit to matching nix versions between the workstation and NUC?

<details>
<summary>Answer</summary>

No. Match the inputs, not the versions. The workstation runs upstream 2.35.2 via
Determinate; the server will run 2.34.8, which is what `nixos-26.05` ships. One
minor version apart, and it self-corrects, because bumping the flake to the next
NixOS release moves the server's Nix forward too.

Matching is the wrong target because which Nix evaluates a flake is not what
determines the result. The pinned nixpkgs is. The same locked inputs produce the
same derivations and store paths on both machines, which is why binary cache hits
work across versions at all.

Committing to matching would mean adding Determinate's NixOS module as an input
on the server, putting a third-party flake on the critical path of an unattended
machine that rebuilds itself from `main`, and adding one more thing to the weekly
lock bump that could break a deploy. It would also make the server stop
resembling the documentation you will be reading when it breaks.

The one real risk runs in the awkward direction: the workstation is newer, so
something can evaluate locally and fail on the server. The architecture absorbs
that. comin's build fails, the previous generation keeps running, and the failure
notification fires. A deploy does not land; the machine does not break.

Recorded as ADR (Architecture Decision Record) 0007.

</details>

### Is `just vm` a real virtual machine, and is Nix or Docker running it?

*2026-09-27*

> In PR 59, is the .vm a virtual machine? Is nix backing that? Or are we using docker?

<details>
<summary>Answer</summary>

It is a real virtual machine, run by QEMU (Quick Emulator), with KVM (Kernel-based
Virtual Machine) acceleration when `/dev/kvm` exists, which it does under WSL2.
Docker is not involved and is not installed on the workstation.

Nix builds the VM; QEMU runs it. `config.system.build.vm` is one more output of
the same NixOS configuration, next to `toplevel`. It is a store path containing a
single shell script, `bin/run-nuc-vm`, whose last line `exec`s
`qemu-system-x86_64` with the kernel and system closure built from the flake.
Read it yourself:

```sh
r=$(nix build --no-link --print-out-paths '.#nixosConfigurations.nuc.config.system.build.vm')
less "$r"/bin/run-nuc-vm
```

`.vm/` is only the working directory the script runs in. The script creates a
disk image, `nuc.qcow2`, in whatever directory it starts from, so `just vm`
changes into `.vm/` first and `.gitignore` keeps it out of the tree. That disk
holds only mutable state such as `/var` and home directories. The operating
system itself is not on it: the guest mounts the host's `/nix/store` read-only
over 9p (`-virtfs ... mount_tag=nix-store`). Deleting `.vm/` gives a fresh
machine next boot, but nothing needs rebuilding.

How this differs from a container: a container shares the host's kernel and
isolates processes. This VM boots its own NixOS kernel, runs systemd as PID 1 and
activates the configuration exactly as the NUC will, which is why it can test
boot-time behaviour such as sops-nix decrypting at activation (`just vm-secrets`).
It does not emulate the NUC's hardware: 1 CPU, 1 GiB RAM, virtio devices, no Arc
GPU, and the placeholder `hardware-configuration.nix` is overridden by the VM
module. Anything hardware-specific waits for the real machine.

</details>

### Is a VM more faithful than a container for mimicking a system?

*2026-09-27*

> Is QEMU more faithful/powerful than docker for mimicking a given system? I
> didn't know that a docker container still shares the host's kernel

<details>
<summary>Answer</summary>

More faithful for the *operating system*, yes. "More powerful" is the wrong frame:
the two isolate different things, and each costs what it buys.

A container is an ordinary process on the host kernel. The kernel gives it
namespaces, a private view of processes, mounts, network and hostname, and
cgroups (control groups), limits on CPU and memory. Nothing boots. `uname -r`
inside any container prints the host's kernel version, and an Alpine image on
an Ubuntu host is Alpine's userland on Ubuntu's kernel. Docker Desktop on
Windows or macOS works only because it quietly runs a Linux VM (virtual
machine) to supply that kernel.

A VM gets virtual hardware and boots its own kernel on it. On this workstation:

| | Kernel |
|---|---|
| WSL2 host, `uname -r` | `5.15.167.4-microsoft-standard-WSL2` |
| `nuc` config, `boot.kernelPackages.kernel.version` | `6.18.49` |

`just vm` runs the second kernel, not the first. (WSL2 is itself a Hyper-V VM,
hence the Microsoft kernel, and QEMU with KVM runs a VM inside it.)

So a VM can test what a container cannot: the kernel and its modules, `sysctl`
settings, systemd as PID 1, boot ordering, activation scripts, firewall rules,
users created at boot. That is the layer this repo declares, which is why NixOS
tests itself in QEMU (the `nixosTests` framework) and why `just vm-secrets`
exists.

The costs: a VM reserves memory, takes seconds to boot rather than milliseconds,
and still fakes the hardware. Neither tool reproduces the Arc GPU, the NPU or the
2.5GbE NICs. Containers win for packaging applications, and that is how the NUC
will use both: NixOS owns the kernel and OS, and Docker runs game servers and
Ollama on top of that one shared kernel, which also means a container escape is
a kernel-level problem (ticket 7.2).

</details>
