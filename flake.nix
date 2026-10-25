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
        # comin modules.
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
          actionlint # lints .github/workflows in `just check`
          shellcheck # actionlint runs it on each workflow's `run:` scripts
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

        # Ticket 1.3 (#10): key-only SSH as ops, root refused, 26.05 booted.
        base-ssh = import ./tests/base-ssh.nix { inherit pkgs inputs nixpkgs; };

        # Ticket 1.2 (#9): the partitioning script nixos-anywhere will run.
        disko-script = self.nixosConfigurations.nuc.config.system.build.diskoScript;

        # Tickets 1.2 (#9) and 1.0 (#57): the encrypted layout boots, asks for
        # the passphrase, then unlocks from the TPM, as ADR 0009 says.
        disk-tpm = import ./tests/disk-tpm.nix {
          inherit pkgs inputs;
          inherit (nixpkgs) lib;
        };

        # Ticket 1.4 (#11): reserved address on the right port, the name, and a
        # LAN scan that finds nothing open (SSH closed there in 1.7, #14).
        network = import ./tests/network.nix {
          inherit pkgs inputs;
          inherit (nixpkgs) lib;
        };

        # Ticket 1.5 (#12): ops logs in over the tailnet from another network,
        # and the tailnet sees only SSH.
        tailscale = import ./tests/tailscale.nix {
          inherit pkgs inputs;
          inherit (nixpkgs) lib;
        };

        # Ticket 2.1 (#16): comin runs, follows `main`, and ignores a
        # `testing-nuc` branch, which would bypass review.
        comin = import ./tests/comin.nix {
          inherit pkgs inputs;
          inherit (nixpkgs) lib;
        };

        # Ticket 2.3 (#18): a kernel change reboots in the window, a
        # configuration-only change does not.
        reboot-window = import ./tests/reboot-window.nix {
          inherit pkgs inputs;
          inherit (nixpkgs) lib;
        };

        # Ticket 2.5 (#20): failures reach the webhook, cut to Discord's limit
        # with mentions off, and a successful deploy stays quiet.
        notify = import ./tests/notify.nix {
          inherit pkgs inputs;
          inherit (nixpkgs) lib;
        };

        # Ticket 3.1 (#22): ports Docker publishes without an address bind
        # to loopback, on every network, and nobody has the docker group.
        docker = import ./tests/docker.nix {
          inherit pkgs inputs;
          inherit (nixpkgs) lib;
        };

        # Ticket 3.2 (#23): a stack becomes a systemd unit, keeps its
        # containers in its slice, survives a Docker restart and restarts
        # alone when its files change.
        compose-stack = import ./tests/compose-stack.nix {
          inherit pkgs inputs;
          inherit (nixpkgs) lib;
        };

        # Ticket 3.3 (#24): a stack's data directory is a btrfs subvolume
        # owned by the stack's fixed user, and a plain directory in its place
        # fails the data unit.
        stack-data = import ./tests/stack-data.nix {
          inherit pkgs inputs;
          inherit (nixpkgs) lib;
        };

        # Ticket 3.2 (#23): compose files under stacks/ publish only declared
        # ports, and mount neither the Docker socket nor anything outside
        # their stack's data directory (ADR 0006).
        compose-check = import ./tests/compose-check.nix {
          inherit pkgs;
          manifest = self.nixosConfigurations.nuc.config.homeserver.stacksManifest;
          stacks = ./stacks;
        };

        # Ticket 3.2 (#23): the crash watcher posts at least once per window
        # and pings at most once, at the crash cadences it lists.
        stack-watch = import ./tests/stack-watch.nix { inherit pkgs; };

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
