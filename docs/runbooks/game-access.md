# Playing on Alex's game servers

For friends. The game servers aren't on the open internet. You reach them
through Tailscale, a free app that puts the server on a private network
between it and you (ADR (Architecture Decision Record) 0011 has the reasons).
You set it up once per device; after that, turn Tailscale on whenever you
play.

You need:

- **A Tailscale account.** It's free. You sign in with an account you
  already have: Google, Microsoft, Apple, GitHub and others.
- **Alex's invite**, by email or as a link. Accepting it adds the server,
  and only the server, to your Tailscale.
- **The server's address**, which Alex sends you. It looks like
  `nuc.<something>.ts.net`.

## 1. Install Tailscale

Get it from [tailscale.com/download](https://tailscale.com/download), or:

- **Windows, macOS:** run the installer from that page, then sign in from the
  Tailscale icon in the taskbar or menu bar.
- **iPhone, iPad, Android:** install Tailscale from the App Store or Google
  Play and sign in. The app uses your phone's single VPN (virtual private
  network) slot, so turn off any other VPN app while you play.
- **Linux:** `curl -fsSL https://tailscale.com/install.sh | sh`, then
  `sudo tailscale up` and open the link it prints to sign in.
- **Steam Deck:** see below. It takes about ten minutes in Desktop Mode.

### Steam Deck

SteamOS's system files are read-only, so Tailscale goes in with a script that
Tailscale's own developers publish,
[`tailscale-dev/deck-tailscale`](https://github.com/tailscale-dev/deck-tailscale).
You do this once, in Desktop Mode (Steam button, Power, Switch to Desktop),
with a keyboard if you have one:

1. Open Konsole (the terminal, from the app menu).
2. If you've never set a password for the `deck` user, set one now with
   `passwd`. `sudo` needs it.
3. Run, one line at a time:

   ```bash
   git clone https://github.com/tailscale-dev/deck-tailscale.git ~/deck-tailscale
   sudo -i
   cd ~deck/deck-tailscale
   bash tailscale.sh
   source /etc/profile.d/tailscale.sh
   tailscale up --qr --operator=deck
   exit
   ```

   `tailscale up` shows a QR code: scan it with your phone and sign in there.
   The script's own instructions add `--ssh`, which lets other devices on
   your Tailscale log in to your Deck. You don't need that, so leave it out.

4. Return to Game Mode. Tailscale starts by itself when the Deck boots.

If it stops working after a SteamOS update, go back to Desktop Mode and run
the same lines again. To remove it, run `cd ~/deck-tailscale` and then
`sudo bash uninstall.sh`.

## 2. Accept the invite

Open Alex's invite link and sign in with your Tailscale account. The server
(`nuc`) then shows in your Tailscale app's list of machines, marked as shared
with you. You can reach the game servers on it and nothing else.

## 3. Connect

With Tailscale on, add the server in the game using the address Alex sent,
the full `nuc.<something>.ts.net` (the short name `nuc` doesn't work on
shared machines). For Minecraft (Java Edition): Multiplayer, Add Server,
and that address as the Server Address. Leave the port off; it's the
default, 25565.

If the game can't find it by name, use the server's `100.x.y.z` address
instead. Your Tailscale app shows it next to `nuc`. Use the one from your
own app, since it can differ from what someone else sees.

## Can't connect?

1. **Is Tailscale on?** That's nearly always the cause. On a phone, check
   that another VPN hasn't taken over.
2. **Is `nuc` in your Tailscale app's machine list?** If not, the invite
   wasn't accepted, or was revoked: ask Alex.
3. **Try the `100.x.y.z` address** instead of the name.
4. **Still nothing?** Tell Alex which device, which game, and what the error
   says. The server may be down for an update.

Your account on the game itself is separate: Minecraft also keeps a
whitelist, so Alex adds your player name there too.
