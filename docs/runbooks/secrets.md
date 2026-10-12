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
| `nuc` host | derived from its SSH host key | n/a, regenerated on reinstall | added in ticket 1.7 (#14) |

Recovery details, including where the workstation key is backed up, live in the
password manager rather than in this public repository. They are deliberately
not encrypted in-repo: you need them precisely when the key is gone, so a
sops-encrypted note would be unreadable at exactly the wrong moment.

The backup is restore-tested, not merely asserted. First verified 2026-09-13
by copying it into an isolated `HOME` and decrypting `secrets/test.yaml` with
that copy alone, with a no-key control confirming the isolation held. Re-run
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

**Day to day little changes.** The dev shell's sops (3.13) recognises an
encrypted identity file and asks for its passphrase. It asks through gpg-agent when it
finds one running, as it does on this workstation: pinentry prompts in the
terminal, and the agent then holds the passphrase in memory. With GnuPG's
defaults the entry expires 10 minutes after its last use, and after 2 hours
regardless. Nothing decrypted is written to disk. Without an agent, sops
prompts in the terminal on every run.

To make the agent forget the passphrase now, for example before leaving the
machine or before a test that must prompt:

```bash
gpg-connect-agent reloadagent /bye
```

The prompt needs a terminal on standard input, so piping into sops fails
rather than prompting. A wrong passphrase fails with `incorrect passphrase`
and clears the cached entry.

**If the passphrase is lost, the key is lost**, and the backup with it, since
the backup is the same encrypted file. That is the both-lost case above. The
passphrase is in the password manager beside the recovery note, so the key
survives as long as the password manager and the backup both do.

### Setting the passphrase

Done once, on 2026-10-0X. To change the passphrase, decrypt the file back to
`keys.txt.plain` with `age -d` and repeat from the `age -p` line.

Run every command here from the repository, in a terminal. `age` and `sops`
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
include `/mnt/c/Users` if the key was ever copied to the Windows side. Then:

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
gpg-connect-agent reloadagent /bye   # no cached passphrase to lean on
T=$(mktemp -d)
mkdir -p "$T/sops/age"
cp <the backup copy> "$T/sops/age/keys.txt"
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
nix shell nixpkgs#sops --command sops secrets/<name>.yaml
```

That opens an editor on the decrypted content and re-encrypts on save. It asks
for the workstation key's passphrase first, unless gpg-agent still holds it. In
the dev shell, `just secrets-edit <name>.yaml` does the same.

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
open it. Ticket 1.7 (#14) must add the `nuc` host key to *both* rules, or its
own acceptance criterion, reading `/run/secrets/test` on the nuc, will fail.
Recipients alone are not sufficient either: #14 must also declare
`sops.secrets.test` on the host in `hosts/nuc/`, since nothing declares it
today.

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
