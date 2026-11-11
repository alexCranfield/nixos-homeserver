# The unfree packages this configuration allows, by name: Claude Code alone,
# for the tenant's dev VM (./dev.nix, #200). The VMs are built from the
# host's nixpkgs (./default.nix), so the host sets this; a test node that
# builds a dev VM's module on its own nixpkgs imports it too.
{ lib, ... }:
{
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "claude-code" ];
}
