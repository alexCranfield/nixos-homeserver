# Nix itself on every host. `nix.package` is deliberately left at the NixOS
# default (ADR 0007); the flake check devshell-nix-matches-server enforces it.
{ ... }:
{
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # Trusted users may set substituters and import unsigned paths, which is
    # what a remote `nixos-rebuild --target-host` from the workstation needs.
    # Merged with the NixOS default, which already trusts root.
    trusted-users = [ "ops" ];
    # Hard-links identical files in the store as they are added.
    auto-optimise-store = true;
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
}
