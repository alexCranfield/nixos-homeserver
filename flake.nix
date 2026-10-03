{
  description = "Declarative NixOS home server on an ASRock NUC BOX-358H";

  inputs = {
    # Pinned by explicit URL, never the bare name `nixpkgs`. ADR 0007: the
    # workstation's Determinate Nix rewrites the bare name to a FlakeHub
    # snapshot, which would make the workstation and the server disagree.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Declared now so the lock file is complete and later tickets only wire
    # them up. `follows` keeps a single nixpkgs in the lock rather than one
    # per input.
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
      # `follows` only redirects the input named, not that input's own inputs.
      # comin's formatter tooling otherwise pulls nixpkgs-unstable into the lock
      # as a second full nixpkgs, which the weekly lock bump would then churn on.
      inputs.treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # `outputs` is a function. It receives the resolved inputs and returns the
  # attribute set that becomes this flake's outputs.
  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      # Both the workstation (WSL) and the server are x86_64-linux, so there is
      # no need for a multi-system helper here.
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      nixosConfigurations.nuc = nixpkgs.lib.nixosSystem {
        # Makes `inputs` available to every module, for the disko, sops-nix and
        # comin modules imported in later tickets.
        specialArgs = { inherit inputs; };
        modules = [ ./hosts/nuc ];
      };

      # The nuc configuration plus a throwaway key, so a local VM can actually
      # decrypt the test secret. Build and run it with `just vm-secrets` once
      # ticket 0.7 lands; until then see docs/runbooks/secrets.md.
      nixosConfigurations.nuc-vmtest = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/nuc
          ./modules/dev/vm-secrets.nix
        ];
      };

      # Live USB for the hardware survey and the install, with the latest
      # kernel and the ops key. Build with `just iso`; see hosts/installer.
      nixosConfigurations.installer = nixpkgs.lib.nixosSystem {
        modules = [ ./hosts/installer ];
      };

      # Toolchain for working on this repo. direnv loads it on `cd` via .envrc,
      # so `just` and `sops` are on PATH without `nix shell` each time. Pinned
      # by flake.lock like everything else, per ADR 0007.
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          # The Nix the server runs: NixOS defaults `nix.package` to this same
          # package. Everything run in this shell, including `just check` in CI,
          # evaluates the flake with the Nix comin will use (ADR 0007). Taken
          # from pkgs rather than from the nuc configuration, so a broken host
          # config cannot stop the shell, and its tools, from starting. The
          # `devshell-nix-matches-server` check catches the two drifting apart.
          nix
          just # task runner; see ./justfile
          sops # edit and decrypt secrets/
          age # generate and inspect age keys
          ssh-to-age # host SSH key -> age recipient, needed by ticket 1.7 (#14)
          nixfmt-tree # the formatter, also reachable as `nix fmt`
          editorconfig-checker # enforces .editorconfig in `just check`
          nixos-anywhere # bare-metal install, ticket 1.6 (#13)
          nixos-rebuild # manual deploy escape hatch, `just deploy`
        ];
      };

      # `nix fmt`. RFC 166 style, so the code matches what is read everywhere
      # else. nixfmt-tree rather than bare nixfmt: `nix fmt` invokes the
      # formatter with no arguments, which bare nixfmt reads as empty stdin and
      # rejects. The wrapper walks the tree instead.
      formatter.${system} = pkgs.nixfmt-tree;

      # `nix flake check` evaluates these, and builds any not already built or
      # cached, so a broken configuration fails in CI before it reaches the
      # server.
      checks.${system} = {
        toplevel = self.nixosConfigurations.nuc.config.system.build.toplevel;

        # Fails `nix flake check` if the server stops using the dev shell's Nix,
        # for example after a `nix.package` override on the host.
        devshell-nix-matches-server =
          let
            server = self.nixosConfigurations.nuc.config.nix.package;
          in
          if server.outPath == pkgs.nix.outPath then
            pkgs.emptyFile
          else
            throw "the dev shell has ${pkgs.nix.name} but nuc runs ${server.name}; use pkgs.nix on the host (ADR 0007: no nix.package override) or update devShells.default to match";
      };
    };
}
