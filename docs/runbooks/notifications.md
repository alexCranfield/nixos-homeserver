# Notifications: Discord

Ticket 2.5 (#20). The nuc posts to one Discord channel through a webhook. The
configuration is `modules/base/notify.nix`, with the nuc's secrets wired in
`hosts/nuc/notify.nix`.

## What posts

| Event | Message | Pings `@server-mods` |
|---|---|---|
| A watched unit fails | `nuc: <unit> failed`, with its last 20 log lines | yes |
| comin's deployment fails | `nuc: comin deployment failed`, with the commit and comin's error | yes |
| The nuc comes up | `nuc is up, kernel <version>` | no |
| The nuc comes up after an unclean shutdown (power cut, crash or hang) | `nuc is up after an unclean shutdown, kernel <version>` | yes |
| The nuc shuts down or reboots cleanly | `nuc is shutting down` or `nuc is rebooting` | no |

The watched units are comin, sshd, nix-gc, tailscaled, tailscaled-autoconnect,
fstrim, logrotate and reboot-window, each only where it exists on the host. A
module adds its own with `homeserver.notify.units = [ "<service>" ];` beside
the unit.

Messages longer than Discord's 2,000 characters keep their end, where the error
usually is. Only the one role can be pinged: a log line containing `@everyone`
or `@here` stays text.

A deploy does not post: comin does not restart the up and down unit, and
successful deployments are left quiet so the channel shows only what needs
attention.

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
   `server-mods` and give it to whoever should be pinged. With Developer Mode on
   (User Settings, Advanced), right-click the role and Copy Role ID.
2. **The webhook.** Edit the alerts channel, Integrations, Webhooks, New
   Webhook, name it `nuc`, Copy Webhook URL.
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

A post that fails (Discord down, the URL revoked) is in the journal of the unit
that sent it: `notify-failure@<unit>.service`, `notify-online.service`, or
`comin.service` for the deployment hook.

## Record

| | |
|---|---|
| First notification on the phone | to be filled in |
