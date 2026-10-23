# Ways of working

### What does ADR mean?

*2026-09-07*

> What does ADR mean?

<details>
<summary>Answer</summary>

Architecture Decision Record. A short document capturing one significant
technical decision: the situation that forced a choice, what was chosen, and what
living with that choice costs.

The value is in the third part. Six months on, the reasoning behind a decision is
gone, so people either follow a rule nobody understands or quietly reverse it and
reintroduce the original problem. Writing down the tradeoff you accepted makes a
future reversal a deliberate act with evidence rather than an accident.

The format comes from Michael Nygard's 2011 post
[Documenting Architecture Decisions](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions).
His template gives each record a title, status, context, decision, and
consequences.

They are numbered and never deleted. If one turns out wrong, a note is added to
its consequences and a new record supersedes it, so the history shows what was
believed and when. Numbers are permanent identifiers, so gaps in the sequence are
left alone rather than renumbered.

Note the expansion is Architecture **Decision** Record, not Design Record. The
distinction matters: the document records a decision and its cost, not a design.

</details>

### Can I approve my own pull requests on GitHub, as Bitbucket allows?

*2026-09-27*

> A question about the repo now, could we add a ruleset to allow me to self
> approve PRs? Or is that a hard "no" for github? I've done it in bitbucket before

<details>
<summary>Answer</summary>

A hard no. GitHub never counts an approval from a pull request's author, and no
ruleset or repository setting changes that. Bitbucket makes it a per-repository
toggle; GitHub treats review as necessarily a second person.

It bites here for a less obvious reason: the pull requests Claude opens use
Alex's token, so GitHub records Alex as the author of work he did not write. So
ruleset `main` requires zero approvals, and "Alex approves before merge" (#58)
is a convention GitHub does not enforce.

The fix is to change who the author is, not the rule. A machine user, a second
GitHub account operated by a human (GitHub allows one free one per person), gets
Write access and opens Claude's pull requests. Alex's approval then counts, the
ruleset can require one, and "require approval of the most recent push" stops a
change sneaking in after approval. Alex keeps a bypass for his own pull
requests. The history also becomes accurate about who wrote and who reviewed
each change. Tracked as ticket 0.9 (#61).

A GitHub App is the heavier alternative: short-lived tokens and clearly labelled
bot activity, at the cost of more setup.

</details>

### Can the server tell us when it goes down?

*2026-10-21*

> Would it be possible to have downtime messages, online messages?

<details>
<summary>Answer</summary>

Partly, and the part it cannot do is the important one to understand.

A planned shutdown or reboot can be announced: a unit that is running until
shutdown is stopped on the way down, before the network, so its stop command
can post `nuc is rebooting`. And coming up can be announced by a unit that
starts at boot.

An unplanned stop cannot: after a power cut, a crash or a hang, nothing on the
machine runs to say so. What the machine can do is notice afterwards. The nuc
keeps a marker file from boot until a clean shutdown removes it; if the marker
is still there at the next boot, the last one did not end cleanly, and the boot
message says so. That reports the outage only once it is over, and not when it
began.

Reporting an outage while it lasts needs something outside the machine that
expects to hear from it: a "dead man's switch" (the nuc checks in every few
minutes; a service alerts when it stops) or a monitor elsewhere that checks the
nuc. That is #112.

</details>
