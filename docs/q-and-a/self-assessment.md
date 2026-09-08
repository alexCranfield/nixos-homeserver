# Self-assessment log

Questions put to Alex during the build, his answers at the time, and the
feedback. Both are collapsed, so re-reading this file gives a set of questions to
re-attempt without seeing the answers.

Assessments record what was wrong or missing as plainly as what was right. A log
of successes only would be useless for tracking development.

---

### What are a flake's two top-level attributes, and what problem does `flake.lock` solve?

*2026-09-07, before starting issue #3. Set after reading Zero to Nix and Tony
Finn parts 4 and 7.*

**Verdict:** Pass. Core understanding sound. One important gap, on `outputs`
being a function rather than data.

<details>
<summary>Answer given at the time</summary>

> Flake has inputs and outputs as its top level attrs, the inputs describe
> dependencies needed for the flake's build (and they can be pulled from various
> sources). The other attr is outputs, which describe what this flake will
> produce. This can include packages, dev envs, OS configs, or nix templates
> (used to help init new flakes). The lock file attempts to solve the
> reproduceability problem, such that re-runs of the build of the flake will
> always produce the same output from a given lock file. The lock file can be
> re-resolved.

</details>

<details>
<summary>Feedback</summary>

Right on all the main points: both attributes named, a good spread of output
types, and the purpose of the lock file correctly identified, including that it
can be regenerated.

**The gap that matters: `outputs` is a function, not data.** Nix reports its type
as `lambda`. `inputs` is an attribute set you write down; `outputs` is a function
that receives the resolved inputs and returns an attribute set. That is why the
line reads `outputs = { self, nixpkgs }: { ... }` — the part before the colon is
destructuring the function argument, not declaring output names. It explains why
`self` is available without being declared, and why `inputs` is only reachable
inside `outputs` through that parameter.

**The question was leading.** There are more than two top-level attributes. The
test flake has three, because `description` is present, and `nixConfig` is also
permitted. Inputs and outputs are the two that do the work, but "two" was the
question's framing rather than the schema's.

**Sharpen what the lock stores.** Not a version, but a translation from a mutable
reference to an immutable one. `github:NixOS/nixpkgs/nixos-26.05` names a branch,
which moves as commits land. The lock resolved it to revision `c257840` plus a
hash of the contents, which never moves. That mechanism is what lets ADR
(Architecture Decision Record) 0007 claim the Nix version gap between workstation
and server is safe: identical locked revisions give identical derivations
whichever Nix reads them.

**Two things not yet met.** The lock is transitive, pinning inputs' inputs
recursively, which is why `follows` exists to stop several copies of nixpkgs
appearing. And identical inputs give an identical *derivation*, which is subtly
weaker than a bit-identical *build output*; Nix approaches the latter but does
not guarantee it, since some builds embed timestamps.

</details>
