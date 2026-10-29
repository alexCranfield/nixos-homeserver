# Notifications: Discord

Ticket 2.5 (#20). The nuc posts to two Discord channels through webhooks:

- **the alerts channel**, Alex's own: failures, with their logs, pinging
  `@nuc-mods`. The configuration is `modules/base/notify.nix`, and most of
  this runbook is about it.
- **the public channel** (#161), for everyone who uses the nuc: updates,
  restarts and announcements, also shown in the Minecraft server's chat.
  The configuration is `modules/base/announce.nix`; see
  [The public channel](#the-public-channel) below.

The nuc's secrets for both are wired in `hosts/nuc/notify.nix`.

## What posts

Four things post to the alerts channel, each for what the others cannot see:

- **the failure notifier** (`notify-failure@`): a watched unit that fails;
- **comin's deploy hook**: a failed deployment;
- **the stack watcher** (`modules/containers/stack-watch.sh`): a Compose stack's
  container that crashes;
- **Alertmanager, through the alert relay** (#27): what Prometheus's rules
  catch, such as a target that stops answering, a disk filling or a container
  short of memory. Its messages are 🔴 with a ✅ when the problem clears, and
  the rules, silences and troubleshooting are in the
  [observability runbook](observability.md#alerts).

The rules skip what the first three already report, so one problem is one
message. The table below covers the first two, the boot messages and shutdowns.

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

Each title carries the time it was sent, in UTC (Coordinated Universal Time),
for example `🔴 [2026-10-22T22:57:34Z] nuc: drill-broken.service failed`.
Discord itself shows only the time of day, in the reader's zone, and none on
messages grouped under one heading. A failure message shows the failed run's
log only, not earlier runs or boots.

Messages longer than Discord's 2,000 characters keep their end, where the error
usually is. Only the one role can be pinged: each message tells Discord so
(`allowed_mentions`), and a zero-width space after every `@` in log text keeps
`@everyone` or `@here` from even looking like a mention. Discord highlights
`@everyone` in text it will not ping; checked from the workstation on
2026-10-21, Discord recorded the test message as pinging the role and not
everyone (`mention_everyone: false`).

A deploy does not post here (the public channel announces it): switching
configuration leaves the up and down unit
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
  failure there is the nuc's disk or network. The alert rules `CominFetchFailed`,
  `CominEvalFailed` and `CominBuildFailed` (#27) watch comin's metrics and post
  these; `comin status` on the nuc also shows it ([deploy.md](deploy.md)).
- **Being down.** The nuc cannot report an outage while it lasts; the boot
  message says afterwards that the last boot ended badly, not when. A check
  from outside is #112.
- **A failed alert post.** The alert relay cannot tell Discord that Discord is
  unreachable. It logs the failure (`journalctl -u alert-relay -b`) and
  Alertmanager retries; a phone push as a second channel is #170.

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
   set in Discord, not here; the nuc's is `nucbot`.
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

## The public channel

Ticket #161. Short status messages for everyone who uses the nuc, in a second
channel, `nuc-alerts-public`, and in the chat of each Minecraft server that is
running. Discord gets the icon and the time in UTC; the game gets
`[nuc] <text>`, with any link as a clickable "More info".

| When | Message | In game |
|---|---|---|
| comin is about to deploy a merge | 🔵 `Applying update. Services on the nuc may restart briefly. More info: <pull request>` | yes |
| The deploy finished | 🟢 `Update complete. More info: <pull request>` | yes |
| The deploy failed | 🔴 `Update failed; the server is unchanged. More info: <pull request>`; the error goes to the alerts channel | no |
| The reboot window is about to reboot (Tuesday 09:55 UTC) | 🟠 `Scheduled maintenance: the nuc restarts at 10:00 UTC (in 5 minutes).` | yes, plus `The nuc restarts in 1 minute.` |
| The nuc has booted (within its first 10 minutes, so not the deploy that adds the unit) | 🟢 `The nuc is back up.` | no, nobody is connected yet |
| `sudo nuc-announce "TEXT" [LINK]` on the nuc | 📢 the text | yes |

- **No pings, nothing private.** Nobody is ever mentioned: `@everyone` in a
  message stays text, though Discord highlights it. No message carries a
  log, a unit name, a hostname or the kernel version. Discord formats the
  text as Markdown, inside bold, so `*` or `_` in an announcement may render
  as formatting; keep announcements under about 1,900 characters, Discord's
  limit less the time and icon.
- **Every update gets the same wording,** whether or not it restarts
  anything. Updates are applied at once, with no warning before one restarts
  a game (Alex, 2026-10-27). For a big change, announce it first by hand.
- **"Applying update" comes from comin's build hook.** comin has no hook
  before it deploys; its build hook runs just before, after the build. A
  build of the system already running (a merge that changes only docs, or
  comin starting again) is not announced. The link is the pull request from
  the `(#N)` at the end of the squash merge's subject, or else the commit.
- **An outcome is posted only for an announced update.** The build hook
  leaves a marker in `/run/announce-comin` for each build it announces, and
  the deployment hook posts "complete" or "failed" only for one with a
  marker. Without that, a docs-only merge right after a real update would
  post a bare "Update complete": comin 0.14.0 compares a new build with the
  deployment *before* the last one (`IsAlreadyDeployed`), so it switches
  again to the system already running, which changes nothing.
- **Posting holds comin up for a moment.** Its hooks run in line: a post
  that Discord or a game server is slow to take holds the deploy for up to
  about a minute (curl's 30 seconds of retries, 20 seconds per server), then
  is logged and given up.
- **Known gaps.** Two merges in quick succession can post "Applying" twice
  and "complete" once, when the second replaces the first before it
  deploys. After a failed deploy and then a reboot, comin builds the failed
  commit again and does not redeploy it, so "Applying" can appear with
  nothing after it. And "the server is unchanged" is the agreed wording, but
  a switch that fails partway may have changed some services.
- **The reboot window warns only when it will reboot.** It checks for a
  pending reboot first, as it always has. With public messages on, its timer
  starts at 09:55, and the reboot follows the five-minute warning, at about
  10:00 (`homeserver.announce.rebootWarning`).
- **The game.** Each server in `homeserver.announce.minecraftContainers` gets
  the message through `rcon-cli tellraw`, as the snapshot hooks reach RCON
  (remote console). The Minecraft stack adds `minecraft-server-1`. A server
  that is stopped or still starting is skipped; a refusal is logged.

To announce something, such as planned maintenance:

```bash
ssh nuc 'sudo nuc-announce "Down Saturday 14:00 UTC for a disk swap" https://github.com/alexCranfield/nixos-homeserver/issues/<n>'
```

**Setting it up.** In Discord, make the channel readable by everyone, with
only the webhook able to post. Edit it, Integrations, Webhooks, New Webhook,
Copy Webhook URL, then add the URL as `discord-public-webhook` with
`just secrets-edit notify.yaml`. The URL is handled as the alerts channel's is.

**Checking it.** A failed post is in the journal of whatever sent it:
`comin-post-build` or `comin-post-deployment` (`journalctl -t <name>`), the
reboot window, or `announce-online.service`. A message the game refused is
logged the same way, with the server's reply.

## Record

| | |
|---|---|
| Set up | 2026-10-21: role `@nuc-mods`, webhook `nucbot`; `secrets/notify.yaml` re-encrypted by Alex at 23:24:36 UTC |
| First message from the nuc | 2026-10-22, at comin's deploy of #114: `nuc is up, kernel 7.2.3` |
| Forced failure on the phone | 2026-10-22 22:09:38 UTC, the `notify-check` command above: `nuc: notify-check.service failed`, pinging `@nuc-mods`; the handler took 314 ms |
| A real failed deploy | 2026-10-22, the #19 drill (#118): merged 22:05:49, unit failure posted 22:06:43 (54 s), then `nuc: comin deployment failed` with exit status 4 |
