# Secrets, keys and disclosure

### What does sops offer over Ansible Vault, and is it safe to trust?

*2026-09-13*

> I'd never heard of sops before, whats the benefit of it over say, ansible
> secrets, and is it safe to trust as a 3rd party tool? I see it has many github
> stars and is recently updated, but curious on the threat considerations here.

<details>
<summary>Answer</summary>

**Against Vault.** Vault uses one shared password for everyone and everything
that decrypts. sops is asymmetric: each identity has its own keypair, and each
file lists which public keys can open it. Three consequences matter here. The
server can decrypt without a human, because its identity is its own SSH host
key; with Vault the password must reach the machine somehow. Diffs stay
reviewable, because sops encrypts values and leaves keys readable. And removing
one recipient does not require re-keying everyone else.

**On trust.** The choice is not between trusting a third party and not; Ansible
is one too. The useful question is which layers do security-critical work.

- *The cryptography is not novel.* age is X25519 with ChaCha20-Poly1305, both
  standard. Its design deliberately omits algorithm negotiation, subkeys and a
  web of trust, which is where GPG's hazards live.
- *The implementations are where trust sits.* sops began at Mozilla in 2015 and
  moved to the CNCF (Cloud Native Computing Foundation) in 2023. sops-nix is a
  smaller community project, and it runs as root at activation.
- *The supply chain is the usual real risk, and Nix helps.* Sources are
  content-addressed and pinned in `flake.lock`, so you get exactly the bytes
  that hash to that value.
- *The blast radius is smaller than it looks.* A malicious sops could add an
  attacker's recipient, but recipients are listed in cleartext inside the
  encrypted file, so an extra one shows up in the pull request diff.

In March 2026 the CNCF opened a health review of sops because its MPL-2.0
(Mozilla Public License) licence was never approved for CNCF projects. The code
kept shipping releases throughout. Practical impact is near zero, since the file
format is documented and age keys work with plain `age`.

**Threats that apply to this project**, in order: the workstation key is the
crown jewel; the server's key will be its SSH host key on a disk that is not yet
encrypted (#57); and because the repo is public, every ciphertext ever pushed
can be archived, so a key leaked years from now exposes everything it ever
protected. Hence **rotation means issuing a new value, not re-encrypting the old
one.** Decrypted secrets live in `/run/secrets`, a tmpfs, so they do not persist
across reboots.

</details>

### Should the location of the key backup be written in the repo?

*2026-09-13*

> Commiting where our keys live into a public repo seems dangerous. We should
> likely only mention that it's being backed up offsite and not the location, or
> encrypt to location somehow

<details>
<summary>Answer</summary>

Right, but not uniformly.

The key's own path is the documented sops default. Anyone who knows sops knows
where age keys live, and anyone with filesystem access finds it with one `grep`.
Hiding it costs clarity and gains nothing.

Custom infrastructure paths are different: a backup host, an account name, a
directory layout. They are free reconnaissance for someone with a partial
foothold, and publishing them gains nothing. Descriptions of personal data flows
are worth keeping out for a separate reason, since they reveal something about
the person rather than the network.

**Encrypting the location cannot work**, because it is circular. You need that
note precisely when the key is gone, and a note encrypted to that key is then
unreadable. Recovery details belong in a password manager, which survives
workstation loss. The repo says "recorded in the password manager" and names
nothing.

</details>

### Should the encrypted secrets live in a separate private repo?

*2026-09-13*

> Maybe we should commit the secrets/encrypted keys to a private repo otuside of
> this one?

<details>
<summary>Answer</summary>

No. The instinct is right but the remedy costs more than it buys.

- **It breaks the deploy model.** The server pulls a public repo with no
  credentials (ADR 0003). A private secrets repo means a deploy key on an
  unattended machine that rebuilds itself from the network.
- **It breaks reproducibility.** The private repo becomes a flake input, so
  public CI cannot evaluate the flake and nobody can build what they are reading.
- **It defeats the reason for choosing sops**, whose whole premise is that
  encrypted values are safe beside the code.
- **Two repos must move in lockstep.** A secret is declared in one and its
  ciphertext lives in the other; update one without the other and activation
  fails on a machine nobody is watching.

The deepest objection: a private repository is not a strong boundary. Staff can
read it, a compromised account exposes it, and a visibility change publishes it.
This repository was itself private for six days by accident while everyone
believed it public. If age ciphertext is unsafe in public, a private repo is not
what saves you; rotation is.

One case would change the answer: if a secret's *name* were sensitive, since
`sops.secrets.<name>` is plaintext in the Nix code whatever the encryption.

</details>

### Does a force-push remove leaked content, and when is a disclosure worth chasing?

*2026-09-13 to 2026-09-15*

> Lets force push to remove any security vunerabilities

> Should I ask support? Or is the risk low enough?

<details>
<summary>Answer</summary>

**A force-push is not a removal mechanism.** It unlinks commits from a branch; it
does not delete them. After this repository's history was rewritten, the
pre-rewrite commits were still served by GitHub by hash and their files were
still readable. The closed pull request's timeline listed every old hash, which
is the discoverability path: normally you would have to guess a 40-character
hash, but the timeline hands them over. Only GitHub Support can purge
unreachable objects and cached views.

Two practical lessons from doing it. `git filter-repo --replace-text` skips
binary files, so strings inside a committed `.pyc` survived the first pass and
needed a second, path-based one. And prose needs its own replacement rules:
replacing paths left a sentence describing them intact until the branch was
squashed.

**Is it worth chasing?** The test is whether anything needs *rotating*. A leaked
key, token or password must be replaced regardless of history, because you can
never prove nobody copied it. Nothing here met that bar: what leaked was a
non-routable hostname, an account name on a machine with no internet-facing
SSH, some paths, and a personal data flow, all reachable only by reading a
closed pull request and constructing an API call by hash. Not worth a Support
request.

What *was* worth fixing was a personal email address in commit authorship,
because that lived in the current history and so in every clone ever made. That
took a third rewrite with `git filter-repo --mailmap`, pointing authorship at
the GitHub noreply address.

</details>

### How do I inspect an encrypted file, and how does sops find its key?

*2026-09-15*

> Say I wanted to inspect the contents of the sops keys in test.yaml, where is
> the keydir and the run command to check the contents in vi?

> Just so I understand that, nix shell spawns a nix shell process, calling the
> package sops, in command mode, were we pass it the "env" command to set the
> editor to vim, we then call sops to open the secrets/text.yaml? How is the key
> dir inferred?

<details>
<summary>Answer</summary>

**Two different directories.** The keys live in `~/.config/sops/age/`.
`vmSecrets.keyDir` is a staging directory that exists only while the VM proof
runs, holding a copy of the throwaway key.

**Reading versus editing.** `sops -d file` prints and exits. `sops file` opens
a decrypted copy in `$EDITOR` and re-encrypts on save, which rewrites the MAC
(message authentication code) and timestamp even when nothing changed, producing
a diff that claims a secret changed. To only look, use `-d`, or `:q!` out of the
editor. `just secrets-show` wraps the safe form.

**The command, corrected.** The reading was right except that `env` was
unnecessary. `nix shell nixpkgs#sops` builds an environment with sops on `PATH`;
`--command` runs one program in it instead of an interactive shell. It
*inherits* the parent environment, so this is equivalent and clearer:

```bash
EDITOR=vi nix shell nixpkgs#sops --command sops secrets/test.yaml
```

With the dev shell loaded by direnv, plain `sops` is already on `PATH`.

**Key discovery is pure convention.** sops tries `SOPS_AGE_KEY`, then
`SOPS_AGE_KEY_FILE`, then `$HOME/.config/sops/age/keys.txt`. Demonstrated by
setting `HOME` to an empty directory containing only that file: decryption
worked, and renaming it to `other.txt` in the same directory made it fail. The
filename is part of the convention. `SOPS_AGE_KEY_FILE` *adds* a key rather than
replacing the default, which makes naive scoping tests give false passes.

**`.sops.yaml` governs encryption only.** Decryption reads the recipient list
from inside the file and tries every identity it can find, which is why editing
`.sops.yaml` changes nothing until `sops updatekeys` runs.

</details>

### Should `keys.txt` be treated as sensitive?

*2026-09-15*

> SO the keys.txt should be treat as sensitive?

<details>
<summary>Answer</summary>

Yes. It is the most sensitive file in the project, and worse than a password.

A leaked password is rotated and the damage stops. This key decrypts every
secret in the repo, and because the repo is public every ciphertext ever pushed
can be archived by anyone. A leak is retroactive: anyone holding old copies can
decrypt everything the key ever protected. Recovery means reissuing every
credential it ever encrypted.

On this workstation the file's mode of `0600` is a Linux control, and WSL
exposes the Linux home directory to Windows through `\\wsl$`. So the key is as
well protected as the Windows account, not as well as its mode suggests.

Keep it off anything that syncs, treat every copy as an event worth noticing,
and passphrase-protect it before the first real secret arrives (#56). The
server's equivalent risk is its host key on an unencrypted disk (#57).

</details>
