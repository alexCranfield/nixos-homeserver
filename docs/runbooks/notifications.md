# Notifications: Discord

Ticket 2.5 (#20). The nuc posts to one Discord channel through a webhook. The
configuration is `modules/base/notify.nix`, with the nuc's secrets wired in
`hosts/nuc/notify.nix`.

## What posts

| Event | Message | Pings `@nuc-mods` |
|---|---|---|
| A watched unit fails | 🔴 `nuc: <unit> failed`, with its last 20 log lines | yes |
| comin's deployment fails | 🔴 `nuc: comin deployment failed`, with the commit and comin's error | yes |
| The nuc comes up | 🟢 `nuc is up, kernel <version>` | no |
| The nuc comes up after an unclean shutdown (power cut, crash or hang) | 🔴 `nuc is up after an unclean shutdown, kernel <version>` | yes |
| The nuc shuts down or reboots cleanly | 🟠 `nuc is shutting down` or `nuc is rebooting` | no |

**At most one failure message per unit every 10 minutes.** systemd runs the
handler on every failure, including each one followed by an automatic restart
(measured in the VM test on systemd 260), so a service stuck in a crash loop
would otherwise post every few seconds. Failures inside the 10 minutes are
counted, and the next message's title says how many were not posted
(`homeserver.notify.cooldown`). The count is a floor: a failure while the last
post is still being sent is not counted. And it waits for the next failure, so
a crash loop that ends with systemd giving up (its start limit) shows as one
message; `systemctl --failed` on the nuc shows what stayed down.

The watched units are comin, sshd, nix-gc, tailscaled, tailscaled-autoconnect,
fstrim, logrotate and reboot-window, each only where it exists on the host. A
module adds its own with `homeserver.notify.units = [ "<service>" ];` beside
the unit.

Messages longer than Discord's 2,000 characters keep their end, where the error
usually is. Only the one role can be pinged: each message tells Discord so
(`allowed_mentions`), and a zero-width space after every `@` in log text keeps
`@everyone` or `@here` from even looking like a mention. Discord highlights
`@everyone` in text it will not ping; checked from the workstation on
2026-10-21, Discord recorded the test message as pinging the role and not
everyone (`mention_everyone: false`).

A deploy does not post: switching configuration leaves the up and down unit
running even when the deploy changes it (`restartIfChanged = false`, tested),
and successful deployments are left quiet so the channel shows only what needs
attention. The exceptions are deploys that add or remove the unit itself: the
deploy of #20 posts `nuc is up` once, as the unit starts for the first time,
and one that turned notifications off would post `nuc is shutting down`.

`nuc is rebooting` covers a reboot, a kexec and a soft reboot; anything else is
`shutting down`. Each post gives up after about 30 seconds, so a Discord outage
delays shutdown or comin's next deployment by that much at most; the boot
message is not waited for.

## What does not post

- **A failed fetch, evaluation or build of `main` on the nuc.** comin runs no
  hook after a failed evaluation, and its build hook reports a build cancelled
  by a newer commit the same way as a failed one, and once per retry. CI
  (continuous integration) builds the same configuration before merge, so a
  failure there is the nuc's disk or network. Until phase 3's alert rules (#27)
  watch comin's metrics, `comin status` on the nuc shows it
  ([deploy.md](deploy.md)).
- **Being down.** The nuc cannot report an outage while it lasts; the boot
  message says afterwards that the last boot ended badly, not when. A check
  from outside is #112.

How the boot message knows: `notify-online.service` keeps a marker file,
`/var/lib/notify-online/running`, from start to stop, and syncs the disk each
time. If the marker is there at boot, the last boot ended before the unit was
stopped, so before a clean shutdown. A failed post does not fail the unit, so a
Discord outage at boot cannot make the next boot look unclean.

## Setting it up

1. **The role.** In the Discord server, Server Settings, Roles, create
   `nuc-mods` and give it to whoever should be pinged. It needs no
   permissions, but if the alerts channel is private, give the role View
   Channel there, or its members are not notified. With Developer Mode on
   (User Settings, App Settings, Advanced), right-click the role and Copy Role
   ID.
2. **The webhook.** Edit the alerts channel, Integrations, Webhooks, New
   Webhook, Copy Webhook URL. Messages show the webhook's name and picture,
   set in Discord, not here; the nuc's is `nuccy`.
3. **The secret.** In the repository:

   ```bash
   just secrets-edit notify.yaml
   ```

   ```yaml
   discord-webhook: https://discord.com/api/webhooks/<id>/<token>
   discord-role: "<role id>"
   ```

   The role id is in quotes so YAML keeps it as text. Merge the change; comin
   deploys it.

The URL is the credential: anyone holding it can post to the channel, though
not read it. It is never put on a command line, where any local user could read
it from `/proc`, and never in the Nix store, which every local user can read
(the build fails if it is). sops-nix decrypts both values into `/run/secrets`,
readable by root. `notify-failure@` runs as a throwaway user and gets them from
systemd as credentials; `notify-online` and comin's hook run as root and read
them in place, because the credentials could not be read when stopping a unit.

**If the URL leaks**, delete the webhook in Discord (that is the revocation),
make a new one, and replace it with `just secrets-edit notify.yaml`.

## Checking it

```bash
ssh nuc 'systemctl status notify-online; journalctl -u "notify-failure@*" -n 20 --no-pager'
```

To send a test failure, run a throwaway unit that fails, with the same handler
attached; it touches nothing else:

```bash
ssh nuc 'sudo systemd-run --unit=notify-check -p OnFailure=notify-failure@notify-check.service.service sh -c "echo test failure; exit 1"'
```

`nuc: notify-check.service failed` arrives within seconds, pinging the role.
The test unit stays listed as failed until cleared:
`ssh nuc 'sudo systemctl reset-failed notify-check'`.

A post that fails (Discord down, the URL revoked) is in the journal of the unit
that sent it, as curl's error, without the URL: `notify-failure@<unit>.service`
(which is then failed) or `notify-online.service`. comin keeps its hook's
output to itself, so the deployment hook logs under its own name:

```bash
ssh nuc 'journalctl -t notify-comin-deployment -n 20 --no-pager'
```

## Record

| | |
|---|---|
| Set up | 2026-10-21: role `@nuc-mods`, webhook `nuccy`; `secrets/notify.yaml` re-encrypted by Alex at 23:24:36 UTC |
| First message from the nuc | 2026-10-22, at comin's deploy of #114: `nuc is up, kernel 7.2.3` |
| Forced failure on the phone | 2026-10-22 22:09:38 UTC, the `notify-check` command above: `nuc: notify-check.service failed`, pinging `@nuc-mods`; the handler took 314 ms |
| A real failed deploy | 2026-10-22, the #19 drill (#118): merged 22:05:49, unit failure posted 22:06:43 (54 s), then `nuc: comin deployment failed` with exit status 4 |
