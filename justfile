# Task runner for this repo. Tools come from the flake's devShell, which direnv
# loads on `cd` (see .envrc). `just` with no arguments lists these targets.
#
# Longer explanation of each lives in README.md. Keep the comment directly above
# each recipe to ONE line: just shows only that line in `just --list`.

# The VM writes a disk image into the working directory, so keep it out of the tree.
vm_dir := ".vm"

# List the available targets.
default:
    @just --list

# Format every file in place.
fmt:
    nix fmt

# Which checks each CI job builds; ci.yml reads the same file for its matrix.
shards_file := ".github/ci-shards.json"

# Everything CI runs, here in one go; CI splits it into shards (.github/ci-shards.json).
check: _eval
    # The union of every shard. `_eval` has just checked that it is every
    # flake check, each once.
    just _build $(jq -r '[.[].checks[]] | join(" ")' '{{ shards_file }}')
    just _lint

# What one CI job runs, e.g. `just check-shard alerting`; `lint` also evaluates and lints.
[positional-arguments]
check-shard shard:
    #!/usr/bin/env bash
    set -euo pipefail
    # The shard name arrives as $1, not pasted into the script's text, so no
    # name can change what the script does.
    names=$(jq -er --arg s "$1" \
        'if has($s) then .[$s].checks | join(" ") else error("no shard \($s) in {{ shards_file }}") end' \
        '{{ shards_file }}')
    test -n "$names"
    # The whole flake is evaluated, and the shards checked against it, by one
    # shard only: every VM shard would otherwise spend the same minute and
    # 10 GB on it, all to evaluate checks it does not build.
    if [ "$1" = lint ]; then just _eval; fi
    # Word splitting is wanted: the names are checked in `_build`.
    # shellcheck disable=SC2086
    just _build $names
    if [ "$1" = lint ]; then just _lint; fi

# Fail unless every flake check is in exactly one shard of .github/ci-shards.json.
check-shards-complete:
    #!/usr/bin/env bash
    set -euo pipefail
    # attrNames does not evaluate the checks themselves, so this takes seconds.
    checks=$(nix eval --json '.#checks.x86_64-linux' --apply builtins.attrNames)
    test -n "$checks"
    # jq reads an empty file as no input and succeeds, and the problems below
    # would then come out empty too, a false pass; so check the shape first.
    if ! jq -e 'type == "object" and length > 0
            and all(.[]; type == "object" and (.checks | type) == "array")' \
            '{{ shards_file }}' >/dev/null; then
        echo "{{ shards_file }} is not an object of shards, each with a checks list" >&2
        exit 1
    fi
    # One line per problem. A check in no shard would never run in CI, and
    # one in two would run twice and be cached under both. A shard named in
    # the matrix but holding nothing would fail `_build`, so say so here.
    # Shard names go into cache keys as `nix-Linux-<shard>-<commit>-<attempt>`
    # and the restore matches by prefix; without a hyphen in any name, no
    # shard's prefix can match another shard's keys.
    problems=$(jq -r --argjson checks "$checks" '
        (to_entries | map(.key as $s | .value.checks[] | {check: ., shard: $s})) as $placed
        | [ ($checks[] | select(. as $c | any($placed[]; .check == $c) | not)
              | "not in any shard: \(.)"),
            ($placed | group_by(.check)[] | select(length > 1)
              | "in more than one shard: \(.[0].check) (\(map(.shard) | join(", ")))"),
            ($placed[].check | select(. as $c | any($checks[]; . == $c) | not)
              | "not a flake check: \(.)"),
            (keys[] | select(test("^[a-z0-9]+$") | not)
              | "shard name is not lower-case letters and digits only: \(.)"),
            (to_entries[] | select((.value.checks | length) == 0)
              | "shard has no checks: \(.key)"),
            (if has("lint") then empty
             else "no shard named lint, the one that evaluates the flake and lints" end)
          ] | unique[]' '{{ shards_file }}')
    if [ -n "$problems" ]; then
        echo "{{ shards_file }} does not match checks.x86_64-linux:" >&2
        echo "$problems" >&2
        exit 1
    fi
    echo "ok: $(jq length <<<"$checks") checks, each in exactly one of $(jq length '{{ shards_file }}') shards"

# Evaluate every output and check the shards; part of `check` and the lint shard.
_eval:
    # Evaluates every output, the checks included, without building, so an
    # error anywhere in the flake fails here (and only in the lint shard).
    nix flake check --no-build
    just check-shards-complete

# Build the named checks, writing `name drv` lines to $CHECK_DRVS when it is set.
[positional-arguments]
_build +names:
    #!/usr/bin/env bash
    set -euo pipefail
    # Read the checks' derivations, then build them in a second process. A
    # plain `nix flake check` keeps all 10 GB of evaluation while the VM
    # tests run, which ran the 16 GB CI runner out of memory (#141). The
    # names arrive as arguments, not pasted into this script, and go into a
    # Nix expression below, so only what a check name can hold is let through.
    list=""
    for n in "$@"; do
        [[ $n =~ ^[A-Za-z0-9_-]+$ ]] || { echo "not a check name: $n" >&2; exit 1; }
        list+="\"$n\" "
    done
    pairs=$(nix eval --json '.#checks.x86_64-linux' \
        --apply "cs: map (n: { name = n; drv = (builtins.getAttr n cs).drvPath; }) [ $list]" \
        | jq -r '.[] | "\(.name) \(.drv)"')
    test -n "$pairs"
    # The list CI's trim step keeps in the cache: each check that built, by
    # name. Printed as well, as evidence of what this job built.
    while read -r name drv; do echo "check-drv $name $drv"; done <<<"$pairs"
    if [ -n "${CHECK_DRVS:-}" ]; then printf '%s\n' "$pairs" > "$CHECK_DRVS"; fi
    # `^*` builds every output of each derivation; an array, so the `*` is
    # never seen by the shell as a glob.
    mapfile -t drvs < <(awk '{ print $2 "^*" }' <<<"$pairs")
    nix build --no-link "${drvs[@]}"

# Formatting and lint; part of `check` and the lint shard.
_lint:
    nix fmt -- --ci
    # Indent width is left to editors: Markdown lists, the GPL (GNU General
    # Public License) text and aligned Python continuation lines are correct
    # but not multiples of it.
    editorconfig-checker -disable-indent-size
    # Workflow syntax, expressions and permissions, and shellcheck on every
    # `run:` script. Fails if shellcheck is missing rather than skipping it.
    command -v shellcheck >/dev/null
    actionlint

# Run one VM test under software emulation, no KVM: slower, but avoids #80.
vm-test-tcg test:
    #!/usr/bin/env bash
    set -euo pipefail
    driver=$(nix build --no-link --print-out-paths '.#checks.x86_64-linux.{{ test }}.driver')
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    mkdir "$work/out"
    cd "$work"
    # QEMU applies the last -machine accel= it is given, and the test's VM
    # scripts append QEMU_OPTS after their own `accel=kvm:tcg`.
    QEMU_OPTS="-machine accel=tcg" "$driver/bin/nixos-test-driver" -o "$work/out"

# Build the nuc system closure and print its store path.
build:
    nix build --print-out-paths '.#nixosConfigurations.nuc.config.system.build.toplevel'

# Build the live USB image (latest kernel, ops key) and print its path.
iso:
    nix build --print-out-paths '.#nixosConfigurations.installer.config.system.build.isoImage'

# Boot the nuc configuration in a local VM. Quit with ctrl-a then x.
vm:
    #!/usr/bin/env bash
    set -euo pipefail
    runner=$(nix build --no-link --print-out-paths '.#nixosConfigurations.nuc.config.system.build.vm')
    mkdir -p {{ vm_dir }}
    cd {{ vm_dir }}
    exec "$(ls "$runner"/bin/run-*-vm)" -nographic

# Prove sops-nix decrypts in a VM. Exits non-zero on failure, so automation-safe.
vm-secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    # Read the directory from the module, so there is one source of truth.
    keydir=$(nix eval --raw '.#nixosConfigurations.nuc-vmtest.config.vmSecrets.keyDir')
    work=$(mktemp -d)
    trap 'rm -rf "$keydir" "$work"' EXIT
    mkdir -p "$keydir"
    cp ~/.config/sops/age/vm-test.txt "$keydir"/
    runner=$(nix build --no-link --print-out-paths '.#nixosConfigurations.nuc-vmtest.config.system.build.vm')
    cd "$work"
    timeout 300 "$(ls "$runner"/bin/run-*-vm)" -nographic </dev/null >vm.log 2>&1 || true
    if grep -aq 'SOPS-PROOF-OK: sops-nix bootstrap check' vm.log; then
        echo "PASS: sops-nix decrypted /run/secrets/test in the VM"
    else
        echo "FAIL: no OK marker on the console."
        grep -a 'SOPS-PROOF' vm.log || tail -20 vm.log
        exit 1
    fi

# Emergency deploy of this checkout over the tailnet; comin replaces it at the next merge (docs/runbooks/deploy.md).
deploy:
    nixos-rebuild switch --flake '.#nuc' --target-host ops@nuc --sudo

# Snapshot a stack's data now, kept until deleted (docs/runbooks/data-layout.md).
snapshot stack:
    ssh ops@nuc sudo stack-snapshot {{ stack }} manual

# List a stack's snapshots, or roll its data back to one (docs/runbooks/data-layout.md).
rollback stack *snapshot:
    ssh -t ops@nuc sudo stack-rollback {{ stack }} {{ snapshot }}

# Edit an encrypted secret in $EDITOR, re-encrypting on save.
secrets-edit file:
    EDITOR="${EDITOR:-vi}" sops 'secrets/{{ file }}'

# Print a secret without opening an editor, so it cannot be rewritten.
secrets-show file:
    sops -d 'secrets/{{ file }}'

# Re-encrypt a secret to the current recipients after editing .sops.yaml.
secrets-rekey file:
    sops updatekeys 'secrets/{{ file }}'
