# The data directory of each stack, ticket 3.3 (#24); the options are in
# compose-stack.nix, which imports this file.
#
# A stack with a `dataDir` gets, before it starts:
#
#  - a btrfs subvolume at /srv/data/<name>, so it can be snapshotted and rolled
#    back alone, owned by the fixed uid and gid the stack declares, mode 0750;
#  - a host user and group `stack-<name>` with those ids, so `ls -l` shows a
#    name. Compose gets the numbers as STACK_UID and STACK_GID;
#  - /.snapshots/stacks/<name>, where its snapshots go;
#  - /etc/stacks/<name>/snapshot.json, what the snapshot and rollback scripts
#    read: the stack's name, directory, ids, how many nightly snapshots to
#    keep, and the pre- and post-snapshot commands as scripts (or null).
#
# `stack-<name>-data.service` does the first and third, not tmpfiles: tmpfiles
# can only fall back to a plain directory, which cannot be snapshotted and says
# nothing. If the path exists but is not a subvolume (or /srv is not btrfs) the
# unit fails, the stack, which requires it, does not start, and the failure is
# posted when notifications are on.
#
# A changed unit is reloaded, not restarted: `Requires=` passes a restart on to
# the stack, which would run `down` on a deploy that only moved btrfs-progs'
# store path. The reload runs the same script again, which sets the owner and mode
# of the top directory only (no recursive chown), so files already inside keep
# their owner when a uid changes. The unit is also wanted by multi-user.target,
# and the stack's own reload starts it, so a stack given its first dataDir by a
# deploy gets its subvolume before `up` runs.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homeserver.stacks;
  withData = lib.filterAttrs (_: s: s.dataDir != null) cfg;

  btrfs = "${pkgs.btrfs-progs}/bin/btrfs";

  script =
    name: stack:
    pkgs.writeShellScript "stack-${name}-data" ''
      set -eu
      dir=${lib.escapeShellArg stack.dataDir}
      if [ -e "$dir" ]; then
        if ! ${btrfs} subvolume show "$dir" > /dev/null; then
          echo "$dir exists but is not a btrfs subvolume" >&2
          exit 1
        fi
      else
        install -d -m 0755 "$(dirname "$dir")"
        ${btrfs} subvolume create "$dir"
      fi
      chown ${toString stack.uid}:${toString stack.gid} "$dir"
      chmod 0750 "$dir"
      install -d -m 0700 /.snapshots/stacks/${name}
    '';

  command =
    name: kind: text:
    pkgs.writeShellScript "stack-${name}-${kind}-snapshot" text;

  settings =
    name: stack:
    pkgs.writeText "snapshot.json" (
      builtins.toJSON {
        inherit name;
        inherit (stack) dataDir uid gid;
        keep = 3;
        pre = lib.mapNullable (command name "pre") stack.snapshot.preCommand;
        post = lib.mapNullable (command name "post") stack.snapshot.postCommand;
      }
    );

  # Each of these is a list of [id, stack name], to find the stacks sharing one.
  duplicates =
    field:
    let
      pairs = lib.mapAttrsToList (n: s: {
        id = s.${field};
        inherit n;
      }) (lib.filterAttrs (_: s: s.${field} != null) withData);
    in
    lib.filter (p: lib.length (lib.filter (q: q.id == p.id) pairs) > 1) pairs;
in
{
  config = {
    assertions =
      lib.concatMap (
        { name, value }:
        [
          {
            assertion = value.dataDir == "/srv/data/${name}";
            message = "homeserver.stacks.${name}.dataDir is ${value.dataDir}, but must be /srv/data/${name}: the snapshot scripts look there.";
          }
          {
            assertion = value.uid != null && value.gid != null;
            message = "homeserver.stacks.${name} has a dataDir, so it needs both uid and gid.";
          }
        ]
      ) (lib.attrsToList withData)
      ++
        map
          (field: {
            assertion = duplicates field == [ ];
            message =
              "homeserver.stacks: ${field} must be unique across stacks, but "
              + lib.concatMapStringsSep ", " (p: "${p.n} has ${field} ${toString p.id}") (duplicates field);
          })
          [
            "uid"
            "gid"
          ];

    users.users = lib.mapAttrs' (
      name: stack:
      lib.nameValuePair "stack-${name}" {
        isSystemUser = true;
        inherit (stack) uid;
        group = "stack-${name}";
      }
    ) withData;
    users.groups = lib.mapAttrs' (
      name: stack: lib.nameValuePair "stack-${name}" { inherit (stack) gid; }
    ) withData;

    environment.etc = lib.mapAttrs' (
      name: stack: lib.nameValuePair "stacks/${name}/snapshot.json" { source = settings name stack; }
    ) withData;

    systemd.services = lib.mapAttrs' (
      name: stack:
      lib.nameValuePair "stack-${name}-data" {
        description = "Data directory of the ${name} stack";
        after = [ "local-fs.target" ];
        wantedBy = [ "multi-user.target" ];
        # Never make /srv/data on the root filesystem because /srv is not mounted.
        unitConfig.RequiresMountsFor = [
          "/srv"
          "/.snapshots"
        ];
        reloadIfChanged = true;
        restartIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = script name stack;
          ExecReload = script name stack;
        };
      }
    ) withData;
  };
}
