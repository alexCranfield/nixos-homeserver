# The host deploys itself from `main`, ticket 2.1 (#16), ADR (Architecture
# Decision Record) 0003.
#
# comin polls the public repository over HTTPS, so it needs no credential and
# nothing on the host listens for deploys. On a new commit on `main` it builds
# `nixosConfigurations.<hostName>` on the host and switches to it. `just deploy`
# stays as the emergency path; comin overwrites a manual deploy at the next
# commit on `main`, not before.
#
# Choices made here, each against comin's default:
#
#  - No testing branch. By default comin also deploys `testing-<hostname>`,
#    with `switch-to-configuration test`. Any push to that branch would reach
#    the host without a pull request, review or CI (continuous integration),
#    which is the gate the `main` ruleset exists to enforce. With an empty
#    name comin never selects or deploys it (it still fetches every branch).
#  - No commit signature check. Squash merges are committed by GitHub and
#    signed with GitHub's own key, so trusting that key only proves a commit
#    came through GitHub, which the ruleset already ensures for `main`.
#    Requiring Alex's key instead would mean merging locally and pushing to
#    `main`, which the ruleset forbids. Accepted: whoever controls the GitHub
#    account, or GitHub itself, can deploy as root. See ADR 0003.
#  - Ten boot entries. comin keeps its deployments in its own profile,
#    /nix/var/nix/profiles/system-profiles/comin, and deletes all but three
#    of them by default. The boot menu's limit of ten (system.nix) applies to
#    each profile, so ten here gives comin's deploys the same depth as manual
#    ones. Weekly garbage collection still removes most over 14 days old.
#  - The metrics exporter on loopback. The firewall already denies it from
#    outside; binding it to 127.0.0.1 means a firewall mistake cannot expose it.
#    Phase 3 (#25) may scrape it locally.
#
# comin takes one command per hook. `homeserver.comin.postBuild` and
# `postDeployment` collect commands from several modules (notify.nix,
# announce.nix) and run each in turn; one that fails is logged and does not
# stop the next.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.homeserver.comin;
  # comin keeps a hook's output to itself, logging only its exit status
  # (deployer.go in 0.14.0), so failures go to the journal from here.
  hook =
    name: commands:
    pkgs.writeShellScript name (
      ''
        exec 2> >(${pkgs.systemd}/bin/systemd-cat --identifier ${name} --priority err)
      ''
      + lib.concatMapStrings (cmd: ''
        ${cmd} || echo ${lib.escapeShellArg "${cmd}"} "failed (exit $?)" >&2
      '') commands
    );
  hookOption =
    when:
    lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Commands comin runs ${when}, in order, each with comin's `COMIN_*`
        variables in its environment.
      '';
    };
in
{
  imports = [ inputs.comin.nixosModules.comin ];

  options.homeserver.comin = {
    postBuild = hookOption "after each build of a commit, before deploying it (also when the build was already in the store)";
    postDeployment = hookOption "after each deployment";
  };

  config.services.comin = {
    postBuildCommand = lib.mkIf (cfg.postBuild != [ ]) (hook "comin-post-build" cfg.postBuild);
    postDeploymentCommand = lib.mkIf (cfg.postDeployment != [ ]) (
      hook "comin-post-deployment" cfg.postDeployment
    );
    enable = true;
    remotes = [
      {
        name = "origin";
        url = "https://github.com/alexCranfield/nixos-homeserver.git";
        branches.main.name = "main";
        branches.testing.name = "";
        poller.period = 60;
      }
    ];
    exporter.listen_address = "127.0.0.1";
    retention.deployment_boot_entry_capacity = 10;
  };
}
