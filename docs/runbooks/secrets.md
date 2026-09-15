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
| Workstation | sops default path | off-machine, see password manager | everything |
| VM test | beside it, `vm-test.txt` | no, throwaway | `secrets/test.yaml` only |
| `nuc` host | derived from its SSH host key | n/a, regenerated on reinstall | added in ticket 1.7 (#14) |

Recovery details, including where the workstation key is backed up, live in the
password manager rather than in this public repository. They are deliberately
not encrypted in-repo: you need them precisely when the key is gone, so a
sops-encrypted note would be unreadable at exactly the wrong moment.

The backup is restore-tested, not merely asserted. Verified 2026-09-13 by
copying it into an isolated `HOME` and decrypting `secrets/test.yaml` with that
copy alone, with a no-key control confirming the isolation held. Re-run that
test whenever the key changes.

**If the workstation key and its backup are both lost**, every secret here is
unrecoverable. There is no reset. Generate a new key, re-create every secret by
hand, and `sops updatekeys` them.

**Rotation means issuing a new value, not re-encrypting the old one.** This
repository is public, so every ciphertext ever pushed can be archived by anyone.
Re-encrypting a compromised token leaves the old ciphertext in the wild against
the day the key leaks.

## Adding a secret

```bash
nix shell nixpkgs#sops --command sops secrets/<name>.yaml
```

That opens an editor on the decrypted content and re-encrypts on save.

Then declare it in the module that needs the secret, naming its file explicitly:

```nix
sops.secrets.<name> = {
  sopsFile = ../../secrets/<name>.yaml;
  owner = "someuser";   # defaults to root, mode 0400
};
```

Read it at runtime through `config.sops.secrets.<name>.path`, never a hardcoded
`/run/secrets/<name>`.

**A host that declares a secret it cannot decrypt fails activation.** That is
why `modules/base` imports sops-nix but declares nothing: a secret there would
have broken the first install in ticket 1.6 (#13), before the host key became a
recipient in 1.7 (#14).

`secrets/test.yaml` is a bootstrap artifact whose plaintext is published in this
runbook. Never put anything real in it.

## Recipients and rule order

`.sops.yaml` decides which keys can open which files. **Rules are first-match,
and they do not merge.** `secrets/test.yaml` is matched by the narrow rule and
never reaches the general one, so a key added only to the general rule cannot
open it. Ticket 1.7 (#14) must add the `nuc` host key to *both* rules, or its
own acceptance criterion — reading `/run/secrets/test` on the nuc — will fail.

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

A VM regenerates its SSH host keys each boot, so it can never be a recipient of
anything encrypted earlier. `modules/dev/vm-secrets.nix` hands it the throwaway
key through a shared directory instead, prints the result, and powers off.

```bash
KEYDIR="$XDG_RUNTIME_DIR/nixos-vm-age"          # mode 0700, per user, not /tmp
mkdir -p "$KEYDIR"
cp ~/.config/sops/age/vm-test.txt "$KEYDIR"/     # keep mode 0600; the 9p share
                                                 # maps the guest reader to root

VM=$(nix build --no-link --print-out-paths \
  '.#nixosConfigurations.nuc-vmtest.config.system.build.vm')
cd "$(mktemp -d)"
"$(ls $VM/bin/run-*-vm)" -nographic | tee vm.log

rm -rf "$KEYDIR"                                 # do not leave the key lying about
```

**Verify by grep, not by eye.** The console interleaves boot messages, so the
value will not sit neatly between markers:

```bash
grep -q 'SOPS-PROOF-OK: sops-nix bootstrap check' vm.log && echo PASS || echo FAIL
```

A failed decrypt prints `SOPS-PROOF-FAILED` and the VM still powers off with
exit status 0, so anything automating this — such as `just vm-secrets` in ticket
0.7 (#16) — must grep for the `OK` marker rather than trust the exit code.

The VM writes `nuc.qcow2` into the working directory, hence the `mktemp -d`.
