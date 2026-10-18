# Secrets

Secrets are encrypted with [sops](https://github.com/getsops/sops) using
[age](https://github.com/FiloSottile/age) keys, and decrypted by
[sops-nix](https://github.com/Mic92/sops-nix) at system activation into
`/run/secrets`, a tmpfs. They never enter the Nix store, which is world
readable. See ADR 0004.

Ciphertext is safe to commit: sops encrypts *values* and leaves *keys* readable,
so an encrypted file still diffs sensibly in a pull request.

## Keys

| Key | Location | Backed up | Can decrypt |
|---|---|---|---|
| Workstation | sops default path, encrypted with a passphrase | off-machine, the same encrypted file; see password manager | everything |
| VM test | beside it, `vm-test.txt` | no, throwaway | `secrets/test.yaml` only |
| `nuc` host | derived from its SSH host key, `/etc/ssh/ssh_host_ed25519_key` on the nuc | n/a, regenerated on reinstall | everything, since ticket 1.7 (#14) |

Recovery details, including where the workstation key is backed up, live in the
password manager rather than in this public repository. They are deliberately
not encrypted in-repo: you need them precisely when the key is gone, so a
sops-encrypted note would be unreadable at exactly the wrong moment.

The backup is restore-tested, not merely asserted. First verified 2026-09-13
by copying it into an isolated `HOME` and decrypting `secrets/test.yaml` with
that copy alone, with a no-key control confirming the isolation held, and
again on 2026-10-11 with the passphrase-protected copy (#56). Re-run
that test, as written under [Restore test](#restore-test), whenever the key or
its passphrase changes.

**If the workstation key and its backup are both lost**, every secret here is
unrecoverable. There is no reset. Generate a new key, re-create every secret by
hand, and `sops updatekeys` them.

**Rotation means issuing a new value, not re-encrypting the old one.** This
repository is public, so every ciphertext ever pushed can be archived by anyone.
Re-encrypting a compromised token leaves the old ciphertext in the wild against
the day the key leaks.

## The workstation key's passphrase

The workstation key file is itself encrypted with age, using a passphrase
(#56). The file alone no longer decrypts anything. This matters on WSL
(Windows Subsystem for Linux): Windows Explorer, and anything running as you on
Windows, can read the Linux home through `\\wsl$`, whatever the file's mode
says.

**Day to day, little changes.** The dev shell's sops (3.13) recognises an
encrypted identity file and asks for its passphrase. It asks through gpg-agent
when it finds one running, as it does on this workstation: pinentry prompts in
the terminal, and the agent then holds the passphrase in memory. With GnuPG's
defaults the entry expires 10 minutes after its last use, and after 2 hours
regardless. Nothing decrypted is written to disk. Without an agent, sops
prompts in the terminal on every run.

To make the agent forget the passphrase now, for example before leaving the
machine or before a test that must prompt:

```bash
gpg-connect-agent reloadagent /bye
```

When gpg-agent asks, standard input must be the terminal, so piping into sops
fails rather than prompting. Piping its output is fine. A wrong passphrase
fails with `incorrect passphrase` and clears the cached entry.

pinentry draws a box in the terminal, and needs room for it. In a short pane
sops fails with `gpg-agent passphrase request errored: ERR 83886381 Screen or
window too small <Pinentry>`; that happened here at 6 rows (`stty size`). Make
the pane taller and run it again. Alternatively, an empty `GPG_AGENT_INFO`
makes sops skip the agent and prompt on the terminal itself, without caching
(read from the sops source, not yet exercised here):

```bash
GPG_AGENT_INFO= sops -d secrets/test.yaml
```

**If the passphrase is lost, the key is lost**, and the backup with it, since
the backup is the same encrypted file. That is the both-lost case above. The
passphrase is in the password manager beside the recovery note, so the key
survives as long as the password manager and the backup both do.

### Setting the passphrase

Done once, on 2026-10-11. To change the passphrase, set `K` as in the first
block below, decrypt the file back with
`(umask 077; age -d -o "$K/keys.txt.plain" "$K/keys.txt")`, so the plaintext
is not created readable by others, and repeat from the `age -p` line. Then
replace the backup, re-run the restore test, and update the password manager.

Run every command here from the repository, in one terminal: the later blocks
use `$K` from the first. `age` and `sops`
come from the dev shell, which direnv loads only inside the repository, so
`cd`-ing into the key directory loses them. `age -p` asks for the passphrase
twice.

```bash
K=~/.config/sops/age
mv "$K/keys.txt" "$K/keys.txt.plain"   # out of the default path, or the next
                                       # check passes without the passphrase
(umask 077; age -p -a -o "$K/keys.txt" "$K/keys.txt.plain")   # -a: armored text
```

Check it, with a negative control:

```bash
gpg-connect-agent reloadagent /bye
sops -d secrets/test.yaml            # prompts; prints the test value
gpg-connect-agent reloadagent /bye
sops -d secrets/test.yaml            # type a wrong passphrase: must fail
```

Before deleting the plaintext, look for other copies of the secret line
anywhere you could have written one. Process substitution keeps the key off the
command line, where `ps` would show it:

```bash
grep -rlF -f <(grep '^AGE-SECRET-KEY-' "$K/keys.txt.plain") / \
  --exclude-dir={proc,sys,dev,nix,mnt} 2>/dev/null
```

The only hit should be `keys.txt.plain` itself. Directories you cannot read
are skipped, and you could not have written to them without sudo. `/mnt` is
excluded because it is the Windows drives, which take a long time to search;
include `/mnt/c/Users` if the key was ever copied to the Windows side.
`--exclude-dir` matches a directory name at any depth, so a `dev`, `nix` or
`mnt` directory inside your home is skipped too, and copies inside compressed
git objects are not visible to grep at all. Then:

```bash
shred -u "$K/keys.txt.plain"
```

`shred` overwrites before deleting. On ext4 inside the WSL disk image that is
a best effort, not a guarantee.

Then replace the backup with the encrypted `keys.txt`, and delete the old
plaintext copy there too. If the backup location keeps snapshots, the older
snapshots still hold the plaintext: delete them, or accept that and note it
with the recovery note. Then run the restore test.

### Restore test

What someone holding only the passphrase and the backup does. The backup's
location is in the password manager.

```bash
BACKUP=                              # the backup copy; see the password manager
gpg-connect-agent reloadagent /bye   # no cached passphrase to lean on
T=$(mktemp -d)
mkdir -p "$T/sops/age"
cp "$BACKUP" "$T/sops/age/keys.txt"  # or scp, for a copy on another machine
XDG_CONFIG_HOME="$T" sops -d secrets/test.yaml   # prompts; prints the test value
```

The control, which proves sops was not finding the usual key:

```bash
XDG_CONFIG_HOME="$(mktemp -d)" sops -d secrets/test.yaml   # must fail
rm -rf "$T"
```

For a real restore, put the file at `~/.config/sops/age/keys.txt` instead.

## Adding a secret

```bash
just secrets-edit <name>.yaml
```

That opens an editor on the decrypted content and re-encrypts on save. It asks
for the workstation key's passphrase first, unless gpg-agent still holds it.
Run it inside the repository, so `just` finds the dev shell's sops (3.13,
pinned by the flake); reading an encrypted key file needs a recent sops.

Then declare it in the module that needs the secret, naming its file explicitly:

```nix
sops.secrets.<name> = {
  sopsFile = ../../secrets/<name>.yaml;
  owner = "someuser";   # defaults to root, mode 0400
};
```

Read it at runtime through `config.sops.secrets.<name>.path`, never a hardcoded
`/run/secrets/<name>`.

**A host that declares a secret it cannot decrypt fails the rebuild.** That is
why `modules/base` imports sops-nix but declares nothing: a secret there would
have broken the first install in ticket 1.6 (#13), before the host key became a
recipient in 1.7 (#14).

The failure is asymmetric and worth knowing before you rely on it. A rebuild
stops. A *boot* does not: the activation script runs, the secret is simply
absent, and the unit that needs it starts anyway. Services must check for their
secret rather than assume it arrived.

`secrets/test.yaml` is a bootstrap artifact whose plaintext is published in this
runbook. Never put anything real in it.

## Recipients and rule order

`.sops.yaml` decides which keys can open which files. **Rules are first-match,
and they do not merge.** `secrets/test.yaml` is matched by the narrow rule and
never reaches the general one, so a key added only to the general rule cannot
open it. That is why the `nuc` host key is in *both* rules (ticket 1.7, #14).
Recipients alone are not sufficient either: the host must also declare each
secret, as `hosts/nuc/secrets.nix` does for `sops.secrets.test`.

## The nuc's key

The nuc decrypts with an age identity that sops-nix derives at activation from
its ed25519 SSH host key; nothing is copied to it by hand. Its public half, the
`&nuc` recipient in `.sops.yaml`, comes from the host's public key:

```bash
ssh ops@nuc.home.arpa cat /etc/ssh/ssh_host_ed25519_key.pub > nuc.pub
ssh-keygen -lf nuc.pub        # must match the fingerprint read at the console
ssh-to-age -i nuc.pub         # the recipient
```

Check the fingerprint against the one read at the nuc's console
([install.md](install.md), step 6) before trusting the recipient: a key fetched
over the network is only as good as that check. Then add the recipient to both
rules and re-encrypt each file with `just secrets-rekey <file>`; that step
decrypts with the workstation key, so it asks for its passphrase.

**A reinstall makes a new host key**, unless the old one is carried over. The
old recipient then decrypts nothing on the new machine, and every secret must
be re-encrypted to the new one before the first deploy that needs it. Remove
the old recipient in the same change.

To prove the nuc can decrypt a file without its secret leaving the machine:

```bash
sudo cat /run/secrets/test     # as deployed
# or any file: copy it over first (nothing keeps a checkout on the nuc),
# then decrypt it there with the nuc's own key, which is never printed:
scp secrets/test.yaml ops@nuc.home.arpa:/tmp/
sudo sh -c 'SOPS_AGE_KEY=$(ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key) sops -d /tmp/test.yaml'
```

Pointing sops at the SSH key itself (`SOPS_AGE_SSH_PRIVATE_KEY_FILE`) fails
with `Failed to get the data key`, although sops 3.13.3 supports it: an SSH
identity only opens files encrypted to an `ssh-ed25519` recipient, and
`.sops.yaml` lists the converted `age1…` recipient instead, as sops-nix
expects. So the private key is converted with `ssh-to-age` as well. Neither
tool is installed on the nuc; `nix-shell -p sops ssh-to-age` provides them.

The general pattern is `^secrets/[^/]+\.yaml$`, which deliberately excludes
`.yml`, subdirectories, and the `stacks/<name>/.env.sops` shape that ticket 3.2
(#25) plans. That is fail-closed: sops refuses with `no matching creation rules
found` rather than silently choosing a weaker recipient set. Extend the rules
when those paths arrive.

After changing recipients, existing files are **not** re-encrypted:

```bash
nix shell nixpkgs#sops --command sops updatekeys secrets/<file>.yaml
```

### Checking that a key cannot decrypt something

`SOPS_AGE_KEY_FILE` *adds* a key; it does not replace the default location. So
this gives a false pass, because sops also finds the workstation key:

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/vm-test.txt sops -d secrets/other.yaml   # wrong
```

Isolate `HOME` and `XDG_CONFIG_HOME` to test scoping honestly.

## Proving decryption actually works

The short version is `just vm-secrets`, which stages the key, boots the VM,
greps for the marker, cleans up, and exits non-zero on failure. The manual
procedure below is what it does, for when you need to watch it or change a step.

This uses the throwaway key, which is not passphrase-protected, so it runs
without a prompt. The workstation key is not involved.

A VM (virtual machine) regenerates its SSH host keys each boot, so it can never be a recipient of
anything encrypted earlier. `modules/dev/vm-secrets.nix` hands it the throwaway
key through a shared directory instead, prints the result, and powers off.

```bash
KEYDIR=/run/user/$(id -u)/nixos-vm-age          # must match vmSecrets.keyDir
mkdir -p "$KEYDIR"
cp ~/.config/sops/age/vm-test.txt "$KEYDIR"/     # keep mode 0600; the 9p share
                                                 # maps the guest reader to root

VM=$(nix build --no-link --print-out-paths \
  '.#nixosConfigurations.nuc-vmtest.config.system.build.vm')
cd "$(mktemp -d)"
timeout 300 "$(ls $VM/bin/run-*-vm)" -nographic | tee vm.log

rm -rf "$KEYDIR"                                 # do not leave the key lying about
```

**Verify by grep, not by eye.** The console interleaves boot messages, so the
value will not sit neatly between markers:

```bash
grep -q 'SOPS-PROOF-OK: sops-nix bootstrap check' vm.log && echo PASS || echo FAIL
```

A failed decrypt prints `SOPS-PROOF-FAILED` and the VM still powers off with
exit status 0, so anything automating this, such as `just vm-secrets` in ticket
0.7 (#16), must grep for the `OK` marker rather than trust the exit code.

The VM writes `nuc.qcow2` into the working directory, hence the `mktemp -d`.
