# Secrets

Secrets are encrypted with [sops](https://github.com/getsops/sops) using
[age](https://github.com/FiloSottile/age) keys, and decrypted by
[sops-nix](https://github.com/Mic92/sops-nix) at system activation into
`/run/secrets`. They never enter the Nix store, which is world readable. See
ADR 0004.

Ciphertext is safe to commit: sops encrypts *values* and leaves *keys* readable,
so an encrypted file still diffs sensibly in a pull request.

## Keys

| Key | Location | Backed up | Can decrypt |
|---|---|---|---|
| Workstation | `~/.config/sops/age/keys.txt` | `nas:/tank/data/nasops/secrets-backup/` | everything |
| VM test | `~/.config/sops/age/vm-test.txt` | no, throwaway | `secrets/test.yaml` only |
| `nuc` host | derived from its SSH host key | n/a, regenerated on reinstall | added in ticket 1.7 (#14) |

The backup lives under `nasops`, deliberately **not** under `/tank/data/alex`,
which Resilio Sync replicates to a phone and from there to Google Photos.

**If the workstation key is lost and the backup is gone**, every secret in this
repository is unrecoverable. There is no reset. Restore from the NAS, or if that
is also gone, generate a new key, re-create every secret by hand, and
`sops updatekeys` them.

## Adding a secret

```bash
nix shell nixpkgs#sops --command sops secrets/<name>.yaml
```

That opens an editor on the decrypted content and re-encrypts on save. Recipients
come from `.sops.yaml`, whose rules are evaluated in order with the first match
winning, so the narrow `secrets/test.yaml` rule must stay above the general one.

Then declare it in the module that needs it:

```nix
sops.secrets.<name> = {
  sopsFile = ../../secrets/<name>.yaml;
  owner = "someuser";   # defaults to root, mode 0400
};
```

The path to read at runtime is `config.sops.secrets.<name>.path`, not a
hardcoded `/run/secrets/<name>`.

**A host that declares a secret it cannot decrypt fails activation.** That is why
`modules/base` wires sops-nix but declares no secrets: a secret there would have
broken the first install in ticket 1.6 (#13), before the host key became a
recipient in 1.7 (#14). Declare secrets alongside the service that needs them.

## After changing `.sops.yaml`

Adding a recipient does not re-encrypt anything already on disk:

```bash
nix shell nixpkgs#sops --command sops updatekeys secrets/<file>.yaml
```

## Proving decryption actually works

A VM generates fresh SSH host keys each boot, so it can never be a recipient of
anything encrypted earlier. `modules/dev/vm-secrets.nix` gives it the throwaway
key through a shared directory instead, and prints the decrypted value to the
serial console before powering off.

```bash
mkdir -p /tmp/nixos-vm-age
cp ~/.config/sops/age/vm-test.txt /tmp/nixos-vm-age/
chmod 644 /tmp/nixos-vm-age/vm-test.txt

VM=$(nix build --no-link --print-out-paths \
  '.#nixosConfigurations.nuc-vmtest.config.system.build.vm')
cd "$(mktemp -d)" && "$(ls $VM/bin/run-*-vm)" -nographic
```

Expected on the console:

```
SOPS-PROOF-BEGIN
sops-nix bootstrap check, not a real secret
SOPS-PROOF-END
```

The VM writes a `nuc.qcow2` disk image into the working directory, so run it
somewhere disposable rather than in the repository.
