# Test for ticket 3.3 (#24): a stack with a `dataDir` gets its own btrfs
# subvolume, owned by a user and group fixed in Nix, and the stack's
# containers write as that user. A path that is already a plain directory
# fails the data unit rather than being used.
#
# `node` imports compose-stack.nix (not hosts/nuc), so the test owns its disks:
# one extra disk holds a btrfs filesystem with the subvolumes `@srv` and
# `@snapshots`, mounted as on the nuc. A oneshot formats it on first boot,
# before any mount. The build sandbox has no internet, so the image is built by
# Nix and loaded by a test-only unit, as in tests/compose-stack.nix.
#
# The rules that fail at evaluation (the path, the owner, a clash between
# stacks, the id range) cannot be VM subtests, since a VM that fails to
# evaluate never boots. They are evaluated here, in a list of cases, and the
# test script compares what came out with what each case must produce.
{
  pkgs,
  inputs,
  lib,
}:
let
  # Busybox as an image, as in tests/compose-stack.nix; here it only has to
  # keep running.
  image = pkgs.dockerTools.buildImage {
    name = "probe";
    tag = "test";
    copyToRoot = pkgs.buildEnv {
      name = "probe-root";
      paths = [ pkgs.busybox ];
    };
  };

  stacks.keeper = {
    composeFile = pkgs.writeText "compose.yml" ''
      services:
        app:
          image: probe:test
          pull_policy: never
          user: "''${STACK_UID}:''${STACK_GID}"
          volumes:
            - /srv/data/keeper:/data
          command: ["sh", "-c", "echo hello > /data/hello && exec sleep 100000"]
    '';
    services = [ "app" ];
    dataDir = "/srv/data/keeper";
    uid = 40010;
    gid = 40010;
    after = [ "test-setup.service" ];
  };

  # Starts without a dataDir; the `lateData` specialisation gives it one while
  # it runs, as a deploy gives the live hello stack its first.
  stacks.late = {
    composeFile = pkgs.writeText "compose.yml" ''
      services:
        app:
          image: probe:test
          pull_policy: never
          command: ["sleep", "100000"]
    '';
    services = [ "app" ];
    after = [ "test-setup.service" ];
  };

  # Evaluation cases: a stack set each, and what the test script expects.
  # The module is evaluated inside a bare NixOS configuration; only the
  # messages of this module's assertions are read.
  evaluate =
    stackSet:
    (pkgs.nixos {
      imports = [
        inputs.sops-nix.nixosModules.sops
        inputs.comin.nixosModules.comin
        ../modules/base/notify.nix
        ../modules/containers/docker.nix
        ../modules/containers/compose-stack.nix
      ];
      homeserver.stacks = stackSet;
    }).config;

  failures =
    stackSet:
    map (a: a.message) (
      lib.filter (a: !a.assertion && lib.hasPrefix "homeserver.stacks" a.message)
        (evaluate stackSet).assertions
    );

  stub = {
    composeFile = pkgs.writeText "compose.yml" "";
    services = [ "app" ];
  };

  cases = {
    valid = failures {
      a = stub // {
        dataDir = "/srv/data/a";
        uid = 40001;
        gid = 40001;
      };
    };
    wrongPath = failures {
      a = stub // {
        dataDir = "/srv/data/elsewhere";
        uid = 40001;
        gid = 40001;
      };
    };
    noOwner = failures {
      a = stub // {
        dataDir = "/srv/data/a";
      };
    };
    sharedUid = failures {
      a = stub // {
        dataDir = "/srv/data/a";
        uid = 40010;
        gid = 40001;
      };
      b = stub // {
        dataDir = "/srv/data/b";
        uid = 40010;
        gid = 40002;
      };
    };
    sharedGid = failures {
      a = stub // {
        dataDir = "/srv/data/a";
        uid = 40001;
        gid = 40010;
      };
      b = stub // {
        dataDir = "/srv/data/b";
        uid = 40002;
        gid = 40010;
      };
    };
    # The type check throws when the value is read.
    uid1000Rejected =
      !(builtins.tryEval (
        (evaluate {
          a = stub // {
            dataDir = "/srv/data/a";
            uid = 1000;
            gid = 40001;
          };
        }).homeserver.stacks.a.uid
      )).success;
    gid41000Rejected =
      !(builtins.tryEval (
        (evaluate {
          a = stub // {
            dataDir = "/srv/data/a";
            uid = 40001;
            gid = 41000;
          };
        }).homeserver.stacks.a.gid
      )).success;
  };
in
pkgs.testers.runNixOSTest {
  name = "stack-data";
  node.specialArgs = { inherit inputs; };

  nodes.machine = {
    imports = [
      inputs.sops-nix.nixosModules.sops
      inputs.comin.nixosModules.comin
      ../modules/base/notify.nix
      ../modules/containers/docker.nix
      ../modules/containers/compose-stack.nix
    ];
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
    virtualisation.emptyDiskImages = [ 1024 ];

    # What the installer's disk layout gives the nuc (modules/disk): one btrfs
    # filesystem, `@srv` on /srv and `@snapshots` on /.snapshots. Formatted
    # on first boot, subvolumes first and the label last: the mounts wait for
    # the labelled device, so they cannot run on a half-made filesystem.
    systemd.services.test-format = {
      wantedBy = [ "local-fs-pre.target" ];
      before = [ "local-fs-pre.target" ];
      after = [ "dev-vdb.device" ];
      requires = [ "dev-vdb.device" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig.Type = "oneshot";
      serviceConfig.RemainAfterExit = true;
      path = [
        pkgs.btrfs-progs
        pkgs.util-linux
      ];
      script = ''
        if ! blkid /dev/vdb; then
          mkfs.btrfs /dev/vdb
          work=$(mktemp -d /run/test-format.XXXXXX)
          mount /dev/vdb "$work"
          btrfs subvolume create "$work/@srv" "$work/@snapshots"
          umount "$work"
          btrfs filesystem label /dev/vdb test-data
        fi
      '';
    };
    # Through `virtualisation.fileSystems`: the test VM overrides `fileSystems`
    # itself (qemu-vm.nix) and keeps only what is set here.
    virtualisation.fileSystems."/srv" = {
      device = "/dev/disk/by-label/test-data";
      fsType = "btrfs";
      options = [ "subvol=@srv" ];
    };
    virtualisation.fileSystems."/.snapshots" = {
      device = "/dev/disk/by-label/test-data";
      fsType = "btrfs";
      options = [ "subvol=@snapshots" ];
    };

    homeserver.stacks = stacks;

    specialisation.lateData.configuration.homeserver.stacks.late = {
      dataDir = "/srv/data/late";
      uid = 40020;
      gid = 40020;
    };

    # Loads the image, as the registry would.
    systemd.services.test-setup = {
      wantedBy = [ "multi-user.target" ];
      after = [ "docker.service" ];
      wants = [ "docker.service" ];
      serviceConfig.Type = "oneshot";
      serviceConfig.RemainAfterExit = true;
      path = [ pkgs.docker ];
      script = "docker load < ${image}";
    };
  };

  testScript = ''
    import json

    CASES = json.loads(${builtins.toJSON (builtins.toJSON cases)})
  ''
  + builtins.readFile ./stack-data.py;
}
