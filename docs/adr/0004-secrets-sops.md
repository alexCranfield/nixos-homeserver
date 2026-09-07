# ADR 0004: Secrets with sops-nix and age

Date: 2026-09-07. Status: accepted.

## Context
The NAS project used Ansible Vault with a password file on the workstation. This repo is public and the server must decrypt its own secrets at boot without a human present.

## Decision
Encrypt secrets with sops using age. Recipients are the workstation key and each host's key derived from its SSH host key. sops-nix decrypts at activation into `/run/secrets` with per-secret ownership. Compose stacks receive secrets as env files rendered from `/run/secrets`, never from the repo.

## Consequences
- Ciphertext is safe to commit; a public-repo secret scan should only ever see sops envelopes.
- Adding a host means adding its age public key and re-encrypting; documented in the reinstall runbook.
- Losing both the workstation key and the host key loses the secrets; back the workstation key up to the NAS.
