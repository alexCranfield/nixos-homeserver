# ADR 0004: Secrets with sops-nix and age

Date: 2026-09-07. Status: accepted.

## Context
The NAS project used Ansible Vault with a password file on the workstation. This repo is public and the server must decrypt its own secrets at boot without a human present.

## Decision
Encrypt secrets with sops using age. Recipients are the workstation key and each host's key derived from its SSH host key. sops-nix decrypts at activation into `/run/secrets` with per-secret ownership. Compose stacks receive secrets as env files rendered from `/run/secrets`, never from the repo.

## Consequences
- Ciphertext is safe to commit; a public-repo secret scan should only ever see sops envelopes.
- Adding a host means adding its age public key and re-encrypting; documented in the reinstall runbook.
- Losing both the workstation key and the host key loses the secrets. The
  workstation key is backed up off-machine; the location is recorded in the
  password manager rather than here, since naming it in a public repository is
  free reconnaissance.
- The workstation key is itself encrypted with a passphrase (#56), so the file
  alone, or its backup, decrypts nothing. sops reads the encrypted file
  directly, and gpg-agent caches the passphrase in memory (with GnuPG's
  defaults, 10 minutes after last use, 2 hours at most); no decrypted copy
  is written to disk. The cost: losing the passphrase loses the key and its
  backup together, which is the both-lost case above. The
  passphrase is kept in the password manager with the recovery note. Note
  added 2026-10-11.
- A third class of recipient exists as of ticket 0.5: a throwaway key scoped by
  `.sops.yaml` to the bootstrap test file alone, so a local VM can prove
  decryption without any real secret being at risk.
- The host key is protected at rest only as far as ADR 0009 protects the disk:
  fully against a drive that leaves without the machine, from the install on;
  partly against theft of the whole machine, once Secure Boot (#47) is on.
  Note added 2026-10-03.
- A host that declares a secret it cannot decrypt fails the rebuild, but not the
  boot: at boot the secret is simply absent and the unit that needs it starts
  anyway. Services must check for their secret rather than assume it arrived.
- A host's SSH host key, and so its age identity, is made on the workstation
  at each install, not on the host. Its recipient goes into `.sops.yaml` and
  the secrets are re-encrypted before the install, nixos-anywhere hands the
  key to the new system with `--extra-files`, and the workstation's copy,
  held in memory only, is deleted once the key has arrived. The host key is
  not backed up: every secret is also encrypted to the workstation key, so
  losing it costs a reinstall, not a secret. This is what lets a host whose
  SSH is reachable over the tailnet only (#14) join the tailnet on its first
  boot. Carrying the old key over, or opening the LAN (local area network)
  for one boot, were the alternatives (#15). Note added 2026-10-18.
- Rotation means issuing a new value, not re-encrypting the old one. Every
  ciphertext pushed to a public repository can be archived by anyone, so
  re-encryption leaves the old material in the wild.
