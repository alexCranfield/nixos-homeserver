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
- A third class of recipient exists as of ticket 0.5: a throwaway key scoped by
  `.sops.yaml` to the bootstrap test file alone, so a local VM can prove
  decryption without any real secret being at risk.
- A host that declares a secret it cannot decrypt fails the rebuild, but not the
  boot: at boot the secret is simply absent and the unit that needs it starts
  anyway. Services must check for their secret rather than assume it arrived.
- Rotation means issuing a new value, not re-encrypting the old one. Every
  ciphertext pushed to a public repository can be archived by anyone, so
  re-encryption leaves the old material in the wild.
