# Working agreement for this repo

## What this is

Declarative NixOS configuration for a home server (ASRock NUC BOX-358H). The
whole system is a flake; the server pulls `main` and rebuilds itself. Read
`docs/PLAN.md` for the phased build and `docs/adr/` for why each major choice
was made.

Work is tracked as GitHub Issues, one per plan ticket, grouped by phase
milestone. Issue numbers map to ticket ids in order: 0.1 is #1, 8.4 is #52.
The issues are the source of truth for status, not `docs/PLAN.md`.

## Definition of done for an issue

Do all six before closing. Skipping the tail of this list is how a repo drifts
away from what it claims to be.

1. **Verify against the acceptance criteria.** Run the commands and read the
   output. Never claim something passes without evidence in the transcript. If
   a criterion cannot be met, say so plainly and leave the issue open.
2. **Commit and push.** No work sits uncommitted at the end of a ticket. Small
   commits during the work are fine; the tree must be clean and pushed at the
   end.
3. **Update the docs.** A ticket that changes how the system is operated updates
   its runbook in `docs/runbooks/`. A ticket that changes a decision updates the
   relevant ADR rather than silently diverging from it. A ticket that changes
   the shape of the repo updates `README.md`.
4. **Update memories.** Durable facts about the hardware, the decisions, or how
   the tooling behaves on this machine go into the project memory directory, not
   only into the transcript. Correct memories that turn out to be wrong.
5. **File follow-up issues for anything left behind.** See below.
6. **Close the issue with a comment** recording what was verified, with real
   version numbers and measurements, plus anything that surprised you. The next
   person reading the issue should not have to re-derive it.

## Filing follow-up issues

File a new issue, rather than fixing it inline or leaving it unsaid, when:

- Something has **drifted severely** from what an ADR or runbook describes.
- A fix needs a **complex refactor** that would balloon the current ticket.
- A decision recorded in an ADR turns out to be **wrong in practice**. File the
  issue and note it in the ADR's consequences; do not quietly reverse it.
- You find a **problem outside the current ticket's scope**.

Keep the ticket shape used everywhere else: Goal, Tasks, Acceptance criteria,
Depends on. Label it with a `phase:N` and at least one `area:*` label, and
attach it to the phase milestone it belongs to. `scripts/file_issues.py` is for
the original bulk import and is idempotent; ad-hoc follow-ups go straight to
GitHub.

The point is transparency. A known problem with an issue number is manageable.
A known problem living only in someone's head is not.

## Conventions

**Commits.** Imperative subject under 72 characters, naming the ticket where it
helps ("Record verified workstation setup for ticket 0.1"). Body explains why
when it is not obvious.

**Secrets.** Never in plaintext, never in a compose file, never in a commit.
Everything goes through sops with age (ADR 0004). This repo is public; assume
anything committed is public forever.

**Decisions.** The ADRs are settled. Do not re-open them mid-ticket. If one is
genuinely wrong, file an issue and amend the ADR.

**Nix on this workstation.** PATH is wired only for login shells. Any script,
CI step, or agent-run command must source the profile first or `nix` will look
like it is missing:

```bash
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
```

See `docs/runbooks/workstation.md` for the rest of the WSL caveats.

**Before touching the server.** Build it locally first. `nix flake check` and a
VM build catch most mistakes before comin deploys them to a machine running
other people's game worlds.
