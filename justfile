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

# Everything CI runs. #4's workflow should call this rather than restate it.
check:
    nix flake check
    nix build --no-link '.#nixosConfigurations.nuc.config.system.build.toplevel'
    nix fmt -- --ci

# Build the nuc system closure and print its store path.
build:
    nix build --print-out-paths '.#nixosConfigurations.nuc.config.system.build.toplevel'

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

# Emergency manual deploy to the nuc. Normally comin pulls main itself.
deploy:
    nixos-rebuild switch --flake '.#nuc' --target-host ops@nuc --elevate sudo

# Edit an encrypted secret in $EDITOR, re-encrypting on save.
secrets-edit file:
    EDITOR="${EDITOR:-vi}" sops 'secrets/{{ file }}'

# Print a secret without opening an editor, so it cannot be rewritten.
secrets-show file:
    sops -d 'secrets/{{ file }}'

# Re-encrypt a secret to the current recipients after editing .sops.yaml.
secrets-rekey file:
    sops updatekeys 'secrets/{{ file }}'
