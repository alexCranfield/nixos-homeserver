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
#    which is the gate the `main` ruleset exists to enforce. An empty name
#    makes comin skip the branch.
#  - No commit signature check. Squash merges are committed by GitHub and
#    signed with GitHub's own key, so trusting that key only proves a commit
#    came through GitHub, which the ruleset already ensures for `main`.
#    Requiring Alex's key instead would mean merging locally and pushing to
#    `main`, which the ruleset forbids. See ADR 0003.
#  - Ten boot entries. comin keeps its deployments in its own profile,
#    /nix/var/nix/profiles/system-profiles/comin, and deletes all but three
#    of them by default, which would undercut the ten generations the boot menu
#    is meant to offer (system.nix).
#  - The metrics exporter on loopback. The firewall already denies it from
#    outside; binding it to 127.0.0.1 means a firewall mistake cannot expose it.
#    Phase 3 (#25) may scrape it locally.
{ inputs, ... }:
{
  imports = [ inputs.comin.nixosModules.comin ];

  services.comin = {
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
