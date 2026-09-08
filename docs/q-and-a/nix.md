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
