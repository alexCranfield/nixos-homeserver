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
