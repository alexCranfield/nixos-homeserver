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

---

### In a NixOS module, what is the difference between declaring an option and setting config?

*2026-09-08, before starting issue #3.*

**Verdict:** Needs work. The shorthand rule was right, but the central model of
what a module is needs replacing before writing one.

<details>
<summary>Answer given at the time</summary>

> NixOS is highly configurable, thanks to the configuration.nix file. The
> diufference between declaring an option and setting a config is that they are
> seperate modules. A module can be an import, a config, or an option. The config
> key can be omitted if there is no options declared in the config. A conf9g
> descriped how an import should be set-up, and contains a collection of options
> which are passed to the import for the given module.

</details>

<details>
<summary>Feedback</summary>

**Right:** the shorthand rule. If a module declares no `options`, the `config`
wrapper can be omitted and the attributes written at the top level, so
`{ services.openssh.enable = true; }` means `{ config = { ... }; }`. Correctly
stated.

**Wrong, and this is the one that matters.** Three related errors, all from the
same mistaken picture.

*"They are separate modules."* No. A module is an attribute set that may contain
`imports`, `options` and `config` **at the same time**. Demonstrated by
evaluating a single module that declares `greeting` and sets it in one place.
Declarations and definitions usually appear in different modules in practice,
because nixpkgs declares and you only define, but that is a habit, not a rule.

*"A module can be an import, a config, or an option."* Not a choice between
three. Those are three optional keys, and a module may carry all of them.

*"Config describes how an import should be set up, and contains options which are
passed to the import."* Imports are not parameterised and nothing is passed to
them. `imports` only says "include these modules as well".

**The model to replace it with.** The module system runs in two phases over a
flat, shared namespace.

1. Every `options` block from every module is collected into one schema. A
   declaration says an option exists, what type it has, and its default.
2. Every `config` block from every module is merged against that schema,
   type-checked, and conflicts resolved by priority (`mkDefault`, `mkForce`).

So `options` is the schema and `config` is the data. Both feed one shared pool
rather than one configuring the other. This is why setting an undeclared option
gives `The option 'neverDeclared' does not exist`, and why a bad value gives
`A definition for option 'port' is not of type '16 bit unsigned integer'` — the
type came from the declaration, in a different module entirely.

**The grain of truth.** A module may be a *function*,
`{ config, lib, pkgs, ... }: { ... }`, and those arguments are supplied by the
module system, not by whoever imported it. The `config` passed in is the **final
merged result**, which is what allows one module to branch on another's settings.
That is the closest thing to the "passed in" intuition, and it is worth
understanding, but it flows from the system to the module rather than from an
importer to an import.

</details>

---

### What does `nixpkgs.lib.nixosSystem` actually give you back?

*2026-09-08, before starting issue #3.*

**Verdict:** Half right. Named two of the three surviving attributes, but
repeated the assumption that modules stay separate after evaluation.

<details>
<summary>Answer given at the time</summary>

> returns the attrs of declared modules? i.e., and config, options, and imports
> set for each module?

</details>

<details>
<summary>Feedback</summary>

**Right:** `config` and `options` do both survive at the top level.

**Wrong: "for each module."** There is exactly one `config` and one `options`,
not a set per module. Merging is the point of the module system, and afterwards
the individual modules have no separate existence. Ten modules and one module
produce the same shape of result. This is the same misconception as the previous
question, so it is worth deliberately re-testing.

**Wrong: `imports`.** It does not survive at all. `imports` is an instruction to
the evaluator meaning "find these modules too". It is consumed during evaluation
and discarded, never readable afterwards.

**What actually comes back**, evaluated against nixpkgs 26.05:

```
[ "_module" "_type" "class" "config" "extendModules" "extraArgs"
  "graph" "lib" "options" "pkgs" "type" ]
```

The three worth knowing:

- `config` — the single merged configuration tree.
- `options` — the single merged schema, metadata intact. This is where error
  messages get their content; querying `options.networking.hostName.type.description`
  returns the validation pattern.
- `pkgs` — the instantiated package set for the target platform.

Also useful: `extendModules`, which produces a variant of the system with extra
modules layered on. That is the mechanism behind `build-vm`, and therefore behind
the `just vm` target planned in ticket 0.7.

**The payoff.** What you actually want out of all this is a derivation:
`config.system.build.toplevel`, an entire operating system as one buildable
object. This makes ticket 0.3's acceptance criterion readable rather than
incantation:

```
nix build .#nixosConfigurations.nuc.config.system.build.toplevel
```

`nixosConfigurations.nuc` is the return value of `lib.nixosSystem`, `.config` is
the merged tree, `.system.build.toplevel` is the derivation for the whole
machine. The same object is what `nixos-rebuild` builds, what CI (continuous
integration) builds, and what comin builds before switching.

</details>

---

### What is `system.stateVersion` for, and why is casually bumping it a mistake?

*2026-09-08, before starting issue #3. Asked alongside "how would I test this?",
which is the better question.*

**Verdict:** Pass, and the strongest answer so far. Mechanism and example class
both correct. One framing correction, and the rule is stricter than stated.

<details>
<summary>Answer given at the time</summary>

> How would I invoke/test system.stateVersion to answer this? I think checking a
> configiration.nix it looked like the value of the system.stateVersion
> determines which NixOS release should be compatible with. This avoids the
> breakages of certain softwares, such as database servers or libs. We should
> only change it if the release notes say we should

</details>

<details>
<summary>Feedback</summary>

**Right:** the mechanism. It exists so software that cannot migrate its own data
is not silently handed a newer version. And "database servers" is the canonical
case, not a lucky guess — `services/databases/postgresql.nix` branches four ways
on this value.

**Framing correction.** It does not determine which release you are compatible
with. It records the release at which this machine's *persistent state* was first
created. The option's own documentation is emphatic that changing it does not
upgrade the system, and that a low value does not mean the system is out of date,
out of support, or vulnerable. Upgrading NixOS means changing the nixpkgs input;
`stateVersion` never moves. The two are independent, which is what confuses
everyone.

**The rule is stricter.** Not "when the release notes say", but *never*, for any
reason, even when upgrading NixOS releases, unless every resulting change has
been inspected manually and the data migrated by hand.

**Why bumping breaks things**, shown by evaluating two systems identical but for
this one string:

```
{ installed_at_22_05 = "14.24"; installed_at_26_05 = "17.11"; }
```

Same nixpkgs. Bump a live machine from 22.05 to 26.05 and PostgreSQL 17 starts
against a data directory written by version 14. Nothing migrates it; the service
fails.

**Three ways to interrogate any option**, which was the more valuable half of the
question:

1. *Ask the option about itself.* The merged schema carries `description`,
   `type`, `default`, and `declarations`, the last giving the exact source file
   (here `nixos/modules/misc/version.nix`). The options tab of
   `search.nixos.org` is the browser version of this query.
2. *Grep nixpkgs for consumers.* Fifty-four modules reference `stateVersion`;
   the idiom is `versionOlder config.system.stateVersion "24.05"`. Shows the
   blast radius.
3. *Evaluate two systems differing only in the value.* Proof rather than
   inference, and the method that settles arguments.

**For this project:** `hosts/nuc` gets `system.stateVersion = "26.05"` at install
in ticket 1.6, and it still reads 26.05 years later, including after the move to
NixOS 26.11.

</details>
