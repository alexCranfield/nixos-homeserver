# Shell behaviour and Unix conventions

### What is the benefit of `type` over `which`?

*2026-09-07*

> What's the benefit of `type` over `which`?

<details>
<summary>Answer</summary>

`which` is a separate program, `/usr/bin/which` on Ubuntu. Being a separate
process, it cannot see the shell that called it. All it does is walk PATH looking
for a file.

That matters because PATH is the *last* place the shell looks. Aliases,
functions, and builtins all take precedence, so `which` can confidently report a
path that is not what runs. Tested on this machine, it returned nothing and
exited 1 for `cd` (a builtin), `ll` (an alias), and a shell function, all three
of which the shell knows perfectly well.

`type` is a shell builtin, so it answers the more useful question: what will
actually happen if I type this word. It identifies builtins, expands aliases, and
prints function bodies.

The feature worth remembering is `type -a`, which lists every candidate in
precedence order:

```
echo is a shell builtin
echo is /usr/bin/echo
echo is /bin/echo
```

That is the tool for "why is the wrong version running", which becomes a weekly
occurrence once Nix profiles, the system PATH, and dev shells all supply the same
binary names.

For anything committed, use neither. `command -v` is the POSIX (Portable
Operating System Interface) form, and unlike `type` its output format is
specified, so it can be relied on. It stays quiet, returns a usable value, and
works for builtins and functions as well as files. That is why the direnv hook in
`~/.bashrc` reads:

```bash
command -v direnv >/dev/null 2>&1 && eval "$(direnv hook bash)"
```

Using `which` there would have been a latent bug, since a false negative would
silently skip the hook.

The rule: `type` when asking as a human, `type -a` when something is shadowing
something else, `command -v` in anything committed. `which` has no remaining
niche.

</details>

### What is POSIX, and why is `which` not in it?

*2026-09-07*

> What is POSIX and why is which not in there?

<details>
<summary>Answer</summary>

POSIX is the Portable Operating System Interface, published as IEEE Std 1003.1
and simultaneously as The Open Group Base Specifications. It exists because by
the early 1980s Unix had fragmented into System V, BSD, and a dozen vendor
variants, and code written for one would not build on another. Work began in
1984. The standard defines a contract: the C system call interface, the shell
language, and utilities with specified options, exit statuses, and output
formats. Write to the contract and the program works on Linux, macOS, the BSDs,
Solaris, and busybox.

The current edition is POSIX.1-2024, Issue 8, published June 2024, maintained by
the Austin Group, a joint working group of IEEE, The Open Group, and ISO.

The name is Richard Stallman's. The committee wanted IEEEIX; he objected that it
sounds like a scream of terror and proposed POSIX instead.

As for `which`, the standard's own rationale answers it. Three shells had already
solved this problem three incompatible ways: `type` in the System V shell,
`whence` in the KornShell, and `which` in the C shell. POSIX standardises
existing practice, and here there was no agreed practice to standardise. Rather
than bless one faction and break the other two, the committee enhanced the
existing `command` utility with `-v` and `-V`, and left all three historical
tools untouched. That is why `command -v` feels like an odd spelling for such a
common operation: it is a deliberately neutral third option invented to end a
three-way argument.

There is a design reason it turned out better, not just a diplomatic one.
`command` is a shell builtin, so it can see aliases, functions, and builtins and
be correct by construction. `which` came from the C shell world as an external
program, and an external program can never see the shell that called it. It was
structurally incapable of giving the right answer.

Because none of the three were standardised, every system reimplemented `which`
differently, which is why Debian has been trying to demote theirs from essential
to optional for years.

Worth holding onto: POSIX and Nix solve the same underlying problem, that
software does not move between machines, in opposite directions. POSIX says write
to a minimal common contract and rely on the target providing it. Nix says assume
nothing about the target and carry every dependency with you, pinned. That is why
a flake locks its inputs rather than checking what is installed.

Sources: [POSIX rationale for the shell utilities](https://pubs.opengroup.org/onlinepubs/9799919799/xrat/V4_xcu_chap01.html),
[the 2024 base specifications](https://pubs.opengroup.org/onlinepubs/9799919799.2024edition/mindex.html),
[Stallman on the name](https://www.stallman.org/articles/posix.html).

</details>

### What does `ssh -n` do, and why did the VM test need it?

*2026-10-03*

> Why did we need to background the ssh process with -n?

<details>
<summary>Answer</summary>

Nothing was backgrounded. `-n` points ssh's standard input at `/dev/null`, so
ssh never reads any. It still runs in the foreground: the caller waits for it,
and its output and exit code come back as usual.

By default ssh reads its standard input and forwards it to the remote command,
which is what makes `echo hi | ssh nuc cat` work. The `base-ssh` VM (virtual
machine) test ran ssh inside the client VM, from a root shell that the NixOS
test driver controls by writing commands to that shell's standard input. The
test therefore hung at random:

1. ssh closes its own standard output as soon as the remote side signals
   end-of-file, a moment before it receives the exit status and quits.
2. The driver sees the output is complete and writes its next line,
   `echo ${PIPESTATUS[0]}`, to ask for the exit code.
3. ssh is still alive, reads that line, and forwards it to the nuc.
4. The client's shell never sees the line, and the driver waits forever.

It only struck when the timing lined up, which is more likely in slow software
emulation without KVM (Kernel-based Virtual Machine) acceleration. A remote
command that closes its output and then keeps the session open,
`'echo early; exec >&- 2>&-; sleep 10'`, made it hang every time without `-n`
and pass with it.

The man page links `-n` with backgrounding because a background ssh that read
the terminal would steal your typing. That is the same problem in another form.
It also works the other way round: bash gives a command started with `&` an
empty standard input when job control is off, as it is in scripts. A debugging
wrapper that backgrounded ssh would have hidden the bug.

Rule of thumb: when ssh runs from a script and is not meant to receive piped
input, use `-n` or `< /dev/null`. The classic victim is
`while read host; do ssh "$host" uptime; done < hosts.txt`, which reaches only
the first host, because ssh swallows the rest of the file.

</details>
