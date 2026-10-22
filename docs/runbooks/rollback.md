# Rollback: a bad change on `main`

Ticket 2.4 (#19). How to undo a change comin has deployed
([deploy.md](deploy.md)), depending on how badly it broke the nuc.

**The fix is always a revert on `main`.** comin deploys whatever `main` holds,
so anything done on the nuc alone is temporary: the boot menu gets a broken
nuc running again, but only a new commit on `main` changes what it boots by
default and what comin deploys next.

## Which case is this?

| The nuc | Do |
|---|---|
| Up, with a service failing (Discord: `nuc: <unit> failed`, `nuc: comin deployment failed`) | [Revert on GitHub](#revert-on-github); a revert of the latest deploy also needs comin restarted (step 4). |
| Up, but unreachable over SSH or the tailnet | Revert on GitHub; comin still pulls, since it needs no SSH. If it does not recover, the boot menu. |
| Not booting (it stops in emergency mode, or never posts `nuc is up`) | [The boot menu](#the-boot-menu), at the nuc's console, then revert on GitHub. |

Do not use `nixos-rebuild --rollback` on the nuc: it moves the `system`
profile, which comin does not use ([deploy.md](deploy.md)).

## Revert on GitHub

1. Open the pull request that broke it and press **Revert**. GitHub opens a
   pull request that undoes it.
2. Wait for `check` to pass, and merge it. A revert is a change like any
   other: the ruleset still needs CI (continuous integration) green.
3. comin deploys it within about a minute of the merge. Confirm as in
   [deploy.md](deploy.md), "Is it working?", and see that the unit that failed
   is gone or running:

   ```bash
   ssh nuc 'comin status; systemctl --failed --no-legend'
   ```

4. **If `comin status` still shows the broken commit as deployed, restart
   comin.** A revert of the *latest* deploy builds the configuration from
   before it again, and comin 0.14.0 skips that as "already deployed": its
   check compares a new build with the deployment before the current one, not
   with the current one (#123). Its log says `skipping deployment of
   generation …: … has already been deployed`. A restart resets that, and
   comin deploys the revert on its next poll, within about a minute:

   ```bash
   ssh nuc 'sudo systemctl restart comin'
   ```

   Not needed when the revert builds something new, for example when other
   changes have merged since the bad one.

A revert deploys a new generation. It does not restart the nuc: a change that
only a reboot undoes (a kernel, say) waits for the reboot window
([updates.md](updates.md)), or for a reboot by hand.

## The boot menu

For a nuc that no longer boots. Needs a keyboard and a screen on the nuc.

1. Power the nuc on, or reboot it. systemd-boot shows its menu for 5 seconds
   (`boot.loader.timeout`); press an arrow key to stop the countdown.
2. Pick the comin generation before the newest: the entries name their
   generation number, and the default, highlighted, is the broken one.
3. It boots: unlock is still by the TPM (Trusted Platform Module), so no
   passphrase, unless the broken change was to the boot itself.

The nuc now runs the older generation, but:

- **The default entry is still the broken one.** The next reboot, by hand or
  by the reboot window, boots it again.
- **comin leaves it alone until `main` changes.** It compares each build with
  its own last deployment, not with what is booted (comin 0.14.0,
  `internal/deployer/deployer.go`, `IsAlreadyDeployed`). `main` still builds to
  the broken generation, which comin has already deployed, so it does nothing.

So revert on GitHub next, as above. The revert builds to a new generation,
which comin deploys and makes the default.

## Prevented by CI

`disk-tpm` boots the nuc's real disk layout with every filesystem the host
declares, and fails if a mount stops the boot (`Dependency failed for Local
File Systems`). Before #19 it mounted only disko's filesystems, and a mount
added anywhere else that could not succeed passed CI. Drill pull requests #115
(without the fix: green) and #116 (with it: red) show the difference.

CI does not catch a service that fails only on the real hardware, or anything
the VM (virtual machine) tests do not exercise. That is what the alerts are
for ([notifications.md](notifications.md)).

## Record

| | |
|---|---|
| Boot-breaking mount in CI | 2026-10-22: passed CI before the fix (#115), failed with it in 15½ min (#116) |
| Broken service, merge to alert | 2026-10-22, #118: merged 22:05:49 UTC, comin fetched at 22:06:36, the switch failed and Discord had `nuc: drill-broken.service failed` at 22:06:43 (54 s), then `nuc: comin deployment failed` (exit status 4). sshd untouched (running since 2026-10-21, 0 restarts) |
| Broken service, revert to recovered | revert #119 merged 22:31:22; comin built it at 22:31:41 and **skipped it** (#123); after `systemctl restart comin` at 22:39:59 it deployed at 22:41:01, `drill-broken` gone, no failed units. Merge to recovered: 9 min 39 s, of which 1 min 2 s after the restart |
| Boot menu, broken boot to running on the older entry | to be filled in |
