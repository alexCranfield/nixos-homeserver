# The unfree packages this configuration allows, by name: Claude Code alone,
# for the tenant's dev VM (./dev.nix, #200). A predicate for
# `nixpkgs.config.allowUnfreePredicate`, not a module: the VMs are built from
# the host's nixpkgs (./default.nix), so the real host sets it, while a test
# node that imports the host gets the test's read-only nixpkgs, which refuses
# any `nixpkgs.config`. tests/tenant-dev.nix sets it on its own node.
lib: pkg: builtins.elem (lib.getName pkg) [ "claude-code" ]
