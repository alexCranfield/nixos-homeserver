# Deploys: comin pulls `main`

Ticket 2.1 (#16), ADR (Architecture Decision Record) 0003. The nuc deploys
itself: nothing is pushed to it, and nothing on it listens for deploys.

## How a change reaches the nuc

1. A pull request merges to `main` once CI (continuous integration) is green
   and Alex has reviewed it ([ci.md](ci.md)).
2. comin on the nuc fetches
   `https://github.com/alexCranfield/nixos-homeserver.git` every 60 seconds.
   The repository is public, so it needs no credential.
3. On a new commit on `main`, comin evaluates and builds
   `nixosConfigurations.nuc` on the nuc, fetching what it can from
   cache.nixos.org, then runs `switch-to-configuration switch`.

The configuration is `modules/base/comin.nix`, which also says why each
setting differs from comin's default.

- **Only `main` deploys.** comin's testing branch, `testing-nuc`, is turned
  off: anything pushed there would reach the nuc without review. comin still
  fetches every branch, but never selects one other than `main`. The flake
  check `comin` pushes `testing-nuc` and confirms comin ignores it.
- **Commits are not signature-checked.** GitHub makes and signs the squash
  merges, so the check would prove nothing the ruleset does not. The risk
  accepted: whoever controls the GitHub account, or GitHub itself, can deploy
  to the nuc as root (ADR 0003).
- **`main` only moves forward.** comin refuses a `main` that is not on top of
  the last `main` commit it accepted, so a history rewrite stops deploys
  rather than rolling the nuc back. See "After a history rewrite" below.
- **Its own boot entries.** comin switches with `switch-to-configuration`
  under its own profile, `/nix/var/nix/profiles/system-profiles/comin`, not
  the usual `system` profile, which only `just deploy` moves. The boot menu
  lists both, each up to the ten-generation limit, which applies per profile.
  comin is set to keep ten (its default is three); the weekly garbage
  collection also removes most generations older than 14 days from both
  profiles, so with few merges there are fewer.
- **Do not use `nixos-rebuild --rollback` on the nuc.** It switches to the
  `system` profile's previous generation, which may be older than what comin
  deployed, and comin does not correct it until the next merge, since it
  compares against its own last deployment. Rollback is ticket 2.4 (#19).
- **Metrics on 127.0.0.1:4243.** comin's Prometheus exporter, for phase 3
  (#25); not reachable from the LAN (local area network) or the tailnet.
- **A local control socket.** `comin status` and the other subcommands talk to
  comin over `/var/lib/comin/grpc.sock`, which comin makes writable by every
  local user, so `comin status` works as ops without sudo. Any local account could also suspend comin or ask it
  to fetch; tightening that is #101.

## Is it working?

```bash
ssh nuc 'systemctl is-active comin; comin status'
git ls-remote origin main   # the commit comin should report as deployed
```

`comin status` shows when the remote was last fetched, the generation it built
and the deployment, with its commit. `journalctl -u comin` on the nuc has the
detail, including a failed evaluation or build.

A failed evaluation or build changes nothing on the nuc. A failed
*activation* is different: `switch-to-configuration` has already installed the
boot entry, and it carries on restarting services, so the nuc runs the new
configuration with whatever part failed (a secret it cannot decrypt, say) left
as it was. comin records the deployment as failed.

## Manual deploy

`just deploy` builds the current checkout and switches the nuc to it over SSH.
It is for emergencies, such as fixing comin itself. It does not stop comin:
the next commit on `main` replaces the manual deploy, so anything that should
stay must also merge.

The first deploy of comin is one of these, since comin cannot install itself.

## After a history rewrite

comin reports `this branch has been hard reset` and deploys nothing. Rewrites
need Alex's explicit instruction (`CLAUDE.md`), so this is expected only
after one. Once `main` is confirmed correct, comin's record of the last
deployed commit has to be cleared, which lives in `/var/lib/comin` with its
deployment history. The next deployment after clearing it drops the boot
entries of earlier comin deployments, keeping only the booted and current
ones. Not yet done on the nuc; check
comin's own documentation (`docs/howtos.md`, "What happen on /var/lib/comin
deletion") before doing it, and note the steps here when it is.

## Record

| | |
|---|---|
| comin | 0.14.0, from the comin flake input (`ffeadf34`) |
| First deploy | 2026-10-20: `just deploy` of `main` (`e6d25b7`) installed comin at 14:56:43 UTC; comin fetched `main` at 14:57:44, one poll period later, found the system already built (`jaj4lsqv…`) and switched to it under `system-profiles/comin-1-link` at 14:57:52. `comin status` works as ops without sudo |
| Merge to running, `users.motd` | to be filled in after the merge |
| `comin` active after a reboot | to be filled in after the merge |
