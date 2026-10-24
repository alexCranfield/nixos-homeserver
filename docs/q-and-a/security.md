# Secrets, keys and disclosure

### What does sops offer over Ansible Vault, and is it safe to trust?

*2026-09-13*

> I'd never heard of sops before, whats the benefit of it over say, ansible
> secrets, and is it safe to trust as a 3rd party tool? I see it has many github
> stars and is recently updated, but curious on the threat considerations here.

<details>
<summary>Answer</summary>

**Against Vault.** Vault uses one shared password for everyone and everything
that decrypts. sops is asymmetric: each identity has its own keypair, and each
file lists which public keys can open it. Three consequences matter here. The
server can decrypt without a human, because its identity is its own SSH host
key; with Vault the password must reach the machine somehow. Diffs stay
reviewable, because sops encrypts values and leaves keys readable. And removing
one recipient does not require re-keying everyone else.

**On trust.** The choice is not between trusting a third party and not; Ansible
is one too. The useful question is which layers do security-critical work.

- *The cryptography is not novel.* age is X25519 with ChaCha20-Poly1305, both
  standard. Its design deliberately omits algorithm negotiation, subkeys and a
  web of trust, which is where GPG's hazards live.
- *The implementations are where trust sits.* sops began at Mozilla in 2015 and
  moved to the CNCF (Cloud Native Computing Foundation) in 2023. sops-nix is a
  smaller community project, and it runs as root at activation.
- *The supply chain is the usual real risk, and Nix helps.* Sources are
  content-addressed and pinned in `flake.lock`, so you get exactly the bytes
  that hash to that value.
- *The blast radius is smaller than it looks.* A malicious sops could add an
  attacker's recipient, but recipients are listed in cleartext inside the
  encrypted file, so an extra one shows up in the pull request diff.

In March 2026 the CNCF opened a health review of sops because its MPL-2.0
(Mozilla Public License) licence was never approved for CNCF projects. The code
kept shipping releases throughout. Practical impact is near zero, since the file
format is documented and age keys work with plain `age`.

**Threats that apply to this project**, in order: the workstation key is the
crown jewel; the server's key will be its SSH host key on a disk that is not yet
encrypted (#57); and because the repo is public, every ciphertext ever pushed
can be archived, so a key leaked years from now exposes everything it ever
protected. Hence **rotation means issuing a new value, not re-encrypting the old
one.** Decrypted secrets live in `/run/secrets`, a tmpfs, so they do not persist
across reboots.

</details>

### Should the location of the key backup be written in the repo?

*2026-09-13*

> Commiting where our keys live into a public repo seems dangerous. We should
> likely only mention that it's being backed up offsite and not the location, or
> encrypt to location somehow

<details>
<summary>Answer</summary>

Right, but not uniformly.

The key's own path is the documented sops default. Anyone who knows sops knows
where age keys live, and anyone with filesystem access finds it with one `grep`.
Hiding it costs clarity and gains nothing.

Custom infrastructure paths are different: a backup host, an account name, a
directory layout. They are free reconnaissance for someone with a partial
foothold, and publishing them gains nothing. Descriptions of personal data flows
are worth keeping out for a separate reason, since they reveal something about
the person rather than the network.

**Encrypting the location cannot work**, because it is circular. You need that
note precisely when the key is gone, and a note encrypted to that key is then
unreadable. Recovery details belong in a password manager, which survives
workstation loss. The repo says "recorded in the password manager" and names
nothing.

</details>

### Should the encrypted secrets live in a separate private repo?

*2026-09-13*

> Maybe we should commit the secrets/encrypted keys to a private repo otuside of
> this one?

<details>
<summary>Answer</summary>

No. The instinct is right but the remedy costs more than it buys.

- **It breaks the deploy model.** The server pulls a public repo with no
  credentials (ADR, Architecture Decision Record, 0003). A private secrets repo means a deploy key on an
  unattended machine that rebuilds itself from the network.
- **It breaks reproducibility.** The private repo becomes a flake input, so
  public CI (continuous integration) cannot evaluate the flake and nobody can
  build what they are reading.
- **It defeats the reason for choosing sops**, whose whole premise is that
  encrypted values are safe beside the code.
- **Two repos must move in lockstep.** A secret is declared in one and its
  ciphertext lives in the other; update one without the other and activation
  fails on a machine nobody is watching.

The deepest objection: a private repository is not a strong boundary. Staff can
read it, a compromised account exposes it, and a visibility change publishes it.
This repository was itself private for six days by accident while everyone
believed it public. If age ciphertext is unsafe in public, a private repo is not
what saves you; rotation is.

One case would change the answer: if a secret's *name* were sensitive, since
`sops.secrets.<name>` is plaintext in the Nix code whatever the encryption.

</details>

### Does a force-push remove leaked content, and when is a disclosure worth chasing?

*2026-09-13 to 2026-09-15*

> Lets force push to remove any security vunerabilities

> Should I ask support? Or is the risk low enough?

<details>
<summary>Answer</summary>

**A force-push is not a removal mechanism.** It unlinks commits from a branch; it
does not delete them. After this repository's history was rewritten, the
pre-rewrite commits were still served by GitHub by hash and their files were
still readable. The closed pull request's timeline listed every old hash, which
is the discoverability path: normally you would have to guess a 40-character
hash, but the timeline hands them over. Only GitHub Support can purge
unreachable objects and cached views.

Two practical lessons from doing it. `git filter-repo --replace-text` skips
binary files, so strings inside a committed `.pyc` survived the first pass and
needed a second, path-based one. And prose needs its own replacement rules:
replacing paths left a sentence describing them intact until the branch was
squashed.

**Is it worth chasing?** The test is whether anything needs *rotating*. A leaked
key, token or password must be replaced regardless of history, because you can
never prove nobody copied it. Nothing here met that bar: what leaked was a
non-routable hostname, an account name on a machine with no internet-facing
SSH, some paths, and a personal data flow, all reachable only by reading a
closed pull request and constructing an API (application programming
interface) call by hash. Not worth a Support
request.

What *was* worth fixing was a personal email address in commit authorship,
because that lived in the current history and so in every clone ever made. That
took a third rewrite with `git filter-repo --mailmap`, pointing authorship at
the GitHub noreply address.

</details>

### How do I inspect an encrypted file, and how does sops find its key?

*2026-09-15*

> Say I wanted to inspect the contents of the sops keys in test.yaml, where is
> the keydir and the run command to check the contents in vi?

> Just so I understand that, nix shell spawns a nix shell process, calling the
> package sops, in command mode, were we pass it the "env" command to set the
> editor to vim, we then call sops to open the secrets/text.yaml? How is the key
> dir inferred?

<details>
<summary>Answer</summary>

**Two different directories.** The keys live in `~/.config/sops/age/`.
`vmSecrets.keyDir` is a staging directory that exists only while the VM proof
runs, holding a copy of the throwaway key.

**Reading versus editing.** `sops -d file` prints and exits. `sops file` opens
a decrypted copy in `$EDITOR` and re-encrypts on save, which rewrites the MAC
(message authentication code) and timestamp even when nothing changed, producing
a diff that claims a secret changed. To only look, use `-d`, or `:q!` out of the
editor. `just secrets-show` wraps the safe form.

**The command, corrected.** The reading was right except that `env` was
unnecessary. `nix shell nixpkgs#sops` builds an environment with sops on `PATH`;
`--command` runs one program in it instead of an interactive shell. It
*inherits* the parent environment, so this is equivalent and clearer:

```bash
EDITOR=vi nix shell nixpkgs#sops --command sops secrets/test.yaml
```

With the dev shell loaded by direnv, plain `sops` is already on `PATH`.

**Key discovery is pure convention.** sops tries `SOPS_AGE_KEY`, then
`SOPS_AGE_KEY_FILE`, then `$HOME/.config/sops/age/keys.txt`. Demonstrated by
setting `HOME` to an empty directory containing only that file: decryption
worked, and renaming it to `other.txt` in the same directory made it fail. The
filename is part of the convention. `SOPS_AGE_KEY_FILE` *adds* a key rather than
replacing the default, which makes naive scoping tests give false passes.

**`.sops.yaml` governs encryption only.** Decryption reads the recipient list
from inside the file and tries every identity it can find, which is why editing
`.sops.yaml` changes nothing until `sops updatekeys` runs.

</details>

### Should `keys.txt` be treated as sensitive?

*2026-09-15*

> SO the keys.txt should be treat as sensitive?

<details>
<summary>Answer</summary>

Yes. It is the most sensitive file in the project, and worse than a password.

A leaked password is rotated and the damage stops. This key decrypts every
secret in the repo, and because the repo is public every ciphertext ever pushed
can be archived by anyone. A leak is retroactive: anyone holding old copies can
decrypt everything the key ever protected. Recovery means reissuing every
credential it ever encrypted.

On this workstation the file's mode of `0600` is a Linux control, and WSL
(Windows Subsystem for Linux) exposes the Linux home directory to Windows
through `\\wsl$`. So the key is as well protected as the Windows account, not
as well as its mode suggests.

Keep it off anything that syncs, treat every copy as an event worth noticing,
and passphrase-protect it before the first real secret arrives (#56). The
server's equivalent risk is its host key on an unencrypted disk (#57).

Update 2026-10-11: done in #56. The key file is encrypted with a passphrase,
and gpg-agent caches the passphrase in memory; see `docs/runbooks/secrets.md`.

</details>

### Should the SSH key that reaches the server have a passphrase?

*2026-10-18*

> Should I add a passphrase to the key?

<details>
<summary>Answer</summary>

Yes. The ops key logs in as `ops`, who has sudo without a password, and as root
on the live USB, so whoever holds the file holds the server. Without a
passphrase, a copy taken from a backup, or by malware on Windows (which can read
the WSL home directory through `\\wsl$`), works straight away. With one, a copy
is useless until the passphrase is guessed. OpenSSH derives the file's
encryption key with bcrypt_pbkdf, 16 rounds by default (`ssh-keygen -a` raises
it): a modest slowdown per guess, far less than the Argon2id of LUKS (Linux
Unified Key Setup), so the passphrase itself has to be decent.

It costs little: `ssh-keygen -p -f ~/.ssh/id_nuc` re-encrypts only the private
file, so the public key, `keys/ops.pub`, stays the same. `ssh-add` asks for it
once per session when it loads the key into the agent, and `ssh-add -t 2h`
drops the key from the agent afterwards.

</details>

### How strong does the disk passphrase need to be, and is a random one better than a memorable one?

*2026-10-18*

> For this passphrase, would a 17 char alphanumeric string with special
> characters be sufficient? And would it be better than a smaller memorable
> password?

<details>
<summary>Answer</summary>

Seventeen characters is plenty, if a generator picked them. Drawn at random
from the roughly 94 printable keyboard characters, each carries about 6.5 bits,
so seventeen give about 111 bits: out of reach of brute force. LUKS2 also runs
every guess through Argon2id, a hash built to be slow and memory-hungry (by
default, about two seconds and up to a gigabyte per guess on the machine that
formatted the disk), which stops graphics cards scaling the attack.
A string a person makes up is much weaker than its length suggests, because
people follow patterns.

A short memorable password is the wrong trade here. The passphrase protects
the disk against someone who has the disk, who can guess offline for as long as
they like, with no lockout. Memorability buys little, because the TPM (Trusted
Platform Module) unlocks every normal boot; the passphrase is the recovery key,
typed only after a firmware update or a TPM failure. So it should be strong and
stored (a password manager and an offline copy), not remembered.

Two practical points decide between a random string and a passphrase of six
random words from the 7,776-word Diceware list (about 77 bits, also enough
with Argon2id):

- The prompt at boot uses a US keyboard layout. Symbols such as `@ " # \ |`
  can come out differently on another layout, and characters outside ASCII
  (the plain US keyboard set) may not be typeable at all.
- It is typed blind, rarely, often after something has gone wrong. Words are
  easier to get right.

On 2026-10-18 the install showed the bigger risk was neither: a passphrase
typed once, unseen, into a file did not match the one intended. Typing it
twice, at the machine's own console, now guards against both that and the
layout (`docs/runbooks/install.md`).

</details>

### Why check a server's SSH host key at its console?

*2026-10-18*

> The fingerprint matched, remind me why we had to do that manually, is it
> because via ssh someone could intercept/inject?

<details>
<summary>Answer</summary>

Yes. The host key is how SSH proves the machine answering is the one you
meant. Whatever arrives over the network can be faked by whoever sits on its
path, so the first time a key is seen, nothing over that network can vouch for
it. On a LAN (local area network) the path is short but not closed: ARP
(Address Resolution Protocol) spoofing, a compromised router, or a bad DNS
(Domain Name System) answer from the Pi-hole would each let another machine
answer as `nuc.home.arpa` with its own key.

Every network check repeats the weakness. `ssh-keyscan` and the first login
agreeing shows only that the same answer came twice. Asking the server for its
own fingerprint over SSH is circular: an impersonator replies with its own. The
console is a different channel: a screen attached to the machine, which no one
on the network can intercept. That is what "out of band" means.

What an impersonator gets, and what it does not:

- *Not the ops key.* Key login signs data bound to that one session, so the
  signature cannot be replayed to the real server, and the private key never
  leaves the workstation.
- *Anything typed into the session.* The TPM enrolment asked for the disk
  passphrase over SSH.
- *Future secrets.* Ticket 1.7 (#14) derives the server's age identity from
  this host key and encrypts secrets to it. A wrong key would mean encrypting
  them for the impersonator.

A reinstall makes this worse, not better: the "host key changed" warning is
expected, so it gets accepted by habit, which is the moment an attack would
also produce it.

</details>

### What is the nuc's age identity, and does it need a passphrase?

*2026-10-18*

> What will this identity be used for? If it's temporary I might set a simple
> passphrase

<details>
<summary>Answer</summary>

Neither identity in that step asked for a new passphrase.

- *The nuc's identity* (`age15ms6…`) is permanent and has no passphrase. It is
  derived from the nuc's SSH host key, whose private half stays on the nuc, and
  sops-nix uses it unattended at every boot to decrypt the server's secrets.
  Re-keying only adds its public half as a recipient.
- *The workstation identity* is what a prompt during `sops updatekeys` is for:
  to re-encrypt a file, sops first decrypts it with the workstation key, which
  has been passphrase-protected since #56. That prompt wants the existing
  passphrase.

A passphrase on the nuc's key would defeat its purpose: nobody is there to type
it at boot. Its protection is the encrypted disk (ADR 0009) and the TPM unlock
instead.

</details>

### Is it a problem that the nuc's console asks for a login nobody set up?

*2026-10-18*

> Before we do so, when I use the keyboard and monitor to check the nuc, it
> asks for a login and a password, I'm not sure we ever set one up other than
> the ssh access, is that a problem?

<details>
<summary>Answer</summary>

No, it is deliberate. Both accounts are locked (`passwd -S` shows `L`): `ops`
has only its SSH key, and root has nothing, so no name and password work at the
console. That gives one way in, with the hardest credential to steal; no
password hash on disk, in the repo or in sops; and it is what makes `ops`'s
passwordless sudo reasonable.

The trade-off is that the console cannot rescue a broken network. The ways in
then are the boot menu (edit the line, add `systemd.debug_shell`, Ctrl+Alt+F9
for a root shell), until #47 turns the editor off; the live USB; and choosing an
earlier generation at the boot menu.

`users.mutableUsers` is still `true`, so someone with root could add a password
that survives rebuilds; setting it `false` is noted on the security review,
#45.

</details>

### Does a reinstall need a new disk passphrase?

*2026-10-19*

> For step 4 should I use a new passphrase or is the old one okay?

<details>
<summary>Answer</summary>

The old one is fine. A passphrase needs changing for a reason, and a reinstall
is not one:

- It was never stored on the workstation by the 2026-10-18 install that
  worked: it was typed at the nuc's console, and kept in the password manager
  and the offline backup. The failed first attempt of 2026-10-18 went through
  a file in WSL; if that was the same passphrase, a trace of it may remain in
  WSL's disk image, and that would be a reason to change it.
- The disk does not give it away. LUKS never stores the passphrase, only key
  slots holding the volume key encrypted under a key derived from it with
  Argon2id, and the reinstall writes a new header with a new volume key, so
  through the drive's normal interface nothing left from the old install can
  be opened with it.
- It is already in the password manager and the offline backup. A new one
  means updating both before the install: one more step, with room for a
  mismatch.

Change it if it might have been exposed: written down somewhere untrusted, seen
by someone, or used elsewhere. Either way, it is typed twice at the console
(install.md step 3).

</details>

### Does a weekly lock update expose the server to supply-chain attacks like Shai-Hulud?

*2026-10-20*

> Let's move to 17, walk me through what will update. Are we considering
> payload attacks like the recent Shai hulud incidents? Are we pinning versions
> that are confirmed safe? Should we be performing scans/checks on CVEs before
> updating locks with monitoring emails?.

<details>
<summary>Answer</summary>

**What updates.** `flake.lock` pins each input to a commit and a content hash
(`narHash`). On 2026-10-20 an update would have moved nixpkgs (the
`nixos-26.05` channel) by 2,963 commits, six weeks' worth, taking the kernel
from 7.2.3 to 7.3, systemd from 260.2 to 260.5 and Nix from 2.34.8 to 2.34.9.
It would also have moved sops-nix, comin, disko and home-manager. Six weeks of
missed security fixes is itself the larger risk.

**What Shai-Hulud did.** The npm worm of 2025 and its 2026 waves spread through
install scripts that ran with developers' credentials, through hijacked
maintainer accounts (keyv, August 2026), through poisoned CI caches and
publishing tokens (May 2026), and through GitHub Actions referenced by tag,
which ran the malware again when two compromised action repositories came back
online (September 2026). These dates and details come from security vendors'
write-ups
([Akamai](https://www.akamai.com/blog/security-research/mini-shai-hulud-worm-returns-goes-public),
[Sygnia](https://www.sygnia.co/threat-reports-and-advisories/shai-hulud-returns-software-supply-chain-attack-npm-keyv/),
[Singapore's CSA (Cyber Security
Agency)](https://www.csa.gov.sg/alerts-and-advisories/advisories/ad-2026-009/),
[Aviatrix](https://aviatrix.ai/threat-research-center/compromised-github-actions-mini-shai-hulud-malware-2026/)),
not from npm's or GitHub's own reports.

**What Nix already blocks.** Nothing an input contains runs on the
workstation at install time with your credentials. A pin is a commit plus a
hash, so a moved tag or a republished version cannot change what arrives.
nixpkgs' channel only advances after Hydra, NixOS's build farm, has built and
tested it, and the binaries come signed by cache.nixos.org's key. CI pins its
Actions by commit, which is what defeats the September attack.

**What is still exposed.**

- Inputs other than nixpkgs are small repositories with one or a few
  maintainers, and their code runs as root on the nuc: comin deploys, sops-nix
  decrypts at boot. A hijacked maintainer account becomes root on the nuc at
  the next update. On 2026-10-20 disko's newest commit was hours old.
- The update workflow needs a token that can open pull requests, and `main`'s
  ruleset needs a green check but no approval, so anything holding that token
  could open and merge a malicious update, which comin would deploy.
- "Confirmed safe" is not something anyone issues. A pin guarantees you get
  what was reviewed, not that it was good.

**What #17 does about it.** nixpkgs updates weekly; the other inputs monthly,
and only to what their branch held at least seven days earlier, measured by
GitHub's log of when each push arrived rather than by commit dates, which an
attacker can backdate. The delay is a bet that a hijacked release is noticed and
reverted within a week, not a guarantee. The job that runs Nix and the new
inputs has a read-only token; the job that opens the pull request runs no
third-party code and refuses a lock that changes anything but each input's
commit and hash, or whose new commits are not descendants of the old ones on the
input's branch, which also rules out a commit that exists only in a fork. Each
pull request lists every input's source diff, the package changes (`nix store
diff-closures`) and the change in CVEs (Common Vulnerabilities and Exposures)
reported by vulnix. The CVE list informs rather than blocks: vulnix matches
package names against the NVD (National Vulnerability Database) and does not
know which fixes nixpkgs has patched in, so on 2026-10-20 it reported 100 CVE
ids against 21 packages in the nuc's runtime closure. The update of that day
would have taken it to 43, adding none, mostly through new openssl, curl,
libxml2, pcre2 and unbound releases. Nothing merges by itself, and GitHub's
email for each new pull request carries the summary. Alerts on a phone are
ticket 2.5 (#20). See `docs/runbooks/updates.md`.

</details>

### What does Determinate Systems' update-flake-lock action offer over our own?

*2026-10-20*

> What's the benefit of the determinate systems package compared to a home
> brewed solution?

<details>
<summary>Answer</summary>

Read at its release v29 (2026-09-09), the action is a compiled Node.js bundle
that runs `nix flake update` and commits, plus five more third-party actions
(GPG key import, two file read and write helpers, a template renderer and
`peter-evans/create-pull-request`), each pinned by commit.

**For it:** it is mature and maintained; it keeps one pull request and updates
it each week; its pull request lists each input's old and new revision; it can
sign commits; and maintaining it means bumping one pin.

**Against it, here:** all six run in one job that holds the token able to open,
and with our ruleset merge, pull requests, and GitHub cannot give steps of one
job different permissions. The bundle is built JavaScript, so a version bump is
hard to review. It always takes each input's newest commit, so it cannot apply
a monthly cooldown, and it reports neither package nor CVE changes.

**Our own** is under 300 lines of Python and a workflow that we maintain. The
job with the write token runs only GitHub's checkout and artifact actions, git,
`gh` and that script. The action suits a repository whose merges have a strong
gate; ours needs only a green check.

</details>

### Is a Discord webhook more secure than an ntfy topic?

*2026-10-21*

> Let's use discord webhooks, it's more secure.

<details>
<summary>Answer</summary>

For reading, yes. A message posted to an ntfy.sh topic can be read by anyone
who knows or guesses the topic's name; a Discord channel only by members of
the server who can see it. Alerts carry log lines, so who can read them
matters.

For posting, the two are alike. A webhook URL is a bearer secret: whoever
holds it can post to the channel as the webhook, with no other check, as
whoever holds an ntfy topic name can post to it. So the URL lives in sops
(`secrets/notify.yaml`), never on a command line or in the Nix store, and
revoking it means deleting the webhook in Discord and making a new one
(`docs/runbooks/notifications.md`).

Discord adds one risk of its own: a message can mention `@everyone`. The nuc's
messages allow only one role to be mentioned (`allowed_mentions`), so a log
line containing `@everyone` stays text; checked against the real Discord, which
recorded the test message as not mentioning everyone.

</details>

### Is Docker's live-restore a security risk, given its gaps?

*2026-10-23*

> What it doesn't cover: their published ports still miss new connections
> until the daemon is back, and loopback ports are down longer than LAN ones,
> because docker-proxy exits with the daemon. Docker supports live-restore
> across patch releases only. - Is this a potential security risk?

<details>
<summary>Answer</summary>

Mostly it is about availability, with two narrow security edges.

**Missed connections fail closed.** While the daemon restarts, a client gets
no answer; nothing is exposed that was not before. Docker rewrites its own
firewall rules as it comes back, but the forward filter
(`networking.firewall.filterForward`) lives in NixOS's own nftables table,
which a Docker restart does not touch, so traffic to container addresses is
still dropped unless Docker redirected it to a published port. That is
defence in depth for exactly this moment.

**The loopback gap allows port squatting.** A port on `127.0.0.1` is served
by `docker-proxy`, which exits with the daemon. Until it is back the port is
free, and on Linux any local user may bind an unprivileged port, so a process
already running on the host could take it. Whatever forwards to that port,
such as Tailscale Serve in front of an admin interface, would then talk to
the impostor, and `docker-proxy` would fail to bind. It needs an attacker
already executing code on the host, inside a window of seconds per deploy:
low risk, but a reason to alert when a stack's port fails to bind, and to
weigh how admin interfaces are reached (3.2, #23; 3.4, #25).

**Skipping releases can orphan containers.** Docker supports live-restore
across patch releases. After a larger jump the new daemon may fail to
reconnect to the running containers; they keep running, unmanaged, and drop
out of `docker ps`. A stack believed updated or stopped could keep running an
old image. The stable branch does take minor versions (Docker went from
29.7.2 to 29.9.1 within 26.05), so when the weekly update moves Docker by a
minor or major version, compare `sudo docker ps` with the
`containerd-shim` processes after the deploy (docs/runbooks/updates.md).

</details>

### Is a port forward safer than a public port?

*2026-10-24*

> So Lan with port forwarding, is that more secure than a public port?

<details>
<summary>Answer</summary>

No: they are the same thing. A router port forward is how a home server's
port becomes public. Internet traffic to that port is passed to the server
and arrives on its LAN (local area network) port, so the port is exactly as
exposed as any public one.

What "LAN only" decides is which of the server's own interfaces the firewall
opens the port on. Opening it on the LAN port alone, not on `tailscale0` as
well, admits the forwarded traffic and the home network, and nothing more; it
is the smallest opening that does the job, not a different level of
exposure.

The protection is in the layers around it: the router forwards only the
ports chosen, the server opens only ports declared in Nix (and its firewall
drops any other port Docker publishes), a forgotten port defaults to
loopback, and the compose check rejects risky settings. The exposed service
itself still faces the internet, so keeping it up to date and, for a game,
using its own whitelist, is what is left.

</details>

### Is an IP allowlist worth it for a game server?

*2026-10-24*

> Could we IP whitelist the server as a way to improve security? Or is that
> going to cause more headaches than its worth?

<details>
<summary>Answer</summary>

For friends playing from home, usually more trouble than it is worth.

Most home connections get a new public IP address now and then: after a
router restart, or whenever the ISP (internet service provider) decides.
Mobile networks and some ISPs put many customers behind one shared address
(carrier-grade NAT, network address translation). Each change locks a friend
out until the list is edited and deployed, and it fails exactly when they
want to play.

What an allowlist buys is protection from internet-wide scanning: the
constant probing of well-known ports, and exploits against the server
software before anyone logs in. Cheaper measures cover most of that:

- the game's own whitelist, here Minecraft's, plus `online-mode` so every
  player signs in with a real account: strangers cannot join or grief;
- keeping the server image updated: known exploits get patched;
- or, strongest, no public port at all: friends join the tailnet through
  Tailscale's machine sharing, which needs each to install Tailscale.

The compose-stack module can still restrict a port to listed sources
(`allowedSources`), off by default, for a case where the players' addresses
are stable.

</details>

### How much trouble is Tailscale for friends who just want to play?

*2026-10-24*

> How much of a hassle would tailscale be for users?

<details>
<summary>Answer</summary>

For a friend on a PC or phone it is a one-time setup of a few minutes: install
the Tailscale app, sign in with an existing Google, Microsoft, Apple or GitHub
account, and accept the share invite. After that they connect to the
server's tailnet name, which stays the same, unlike a home IP address.

The ongoing costs:

- Tailscale has to be running while they play. On a PC it sits in the
  background; on a phone it takes the single VPN (virtual private network)
  slot, so it cannot run beside another VPN, such as a work one.
- When a friend cannot connect, the usual cause is Tailscale being off, and
  the server's owner is their first line of support.

Where it does not work:

- Consoles (Xbox, PlayStation, Switch) cannot run Tailscale, so a console
  player cannot join this way.
- On a Steam Deck it works, but SteamOS has a read-only system, so the
  install is a one-off terminal job in Desktop Mode rather than an app
  store install, and may need redoing after a SteamOS update.
- Locked-down devices, such as a work laptop or school Chromebook, may not
  allow the install.

On the owner's side, sharing one machine (not the whole tailnet) plus an
access rule keeps share recipients to the game ports, away from SSH and
admin interfaces. One exception the rule cannot close: a share makes each
friend's device a peer, and `tailscaled` on the server answers its own peer
API to any peer, checking each request itself. Tailscale's plans limit
sharing, and the limits have changed over time, so check them against the
number of players.

The trade against a public port with a whitelist: friends do a little setup,
and in return nothing on the server faces the internet. Mixing the two buys
little, since one public port makes the server public. Here every player was
on a PC, phone or Steam Deck, so Tailscale won (ADR 0011).

</details>
