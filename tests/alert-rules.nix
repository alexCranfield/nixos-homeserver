# Check for ticket #27: the alert rules (modules/observability/rules.nix) are
# valid, and each fires when its condition has held for its `for` and stays
# quiet just short of it or just below its threshold. promtool (Prometheus's
# command-line tool) evaluates the rules against synthetic series in
# tests/alert-rules/*.yml, so no VM (virtual machine) is needed.
{ pkgs }:
let
  inherit (pkgs) lib;
  rules = import ../modules/observability/rules.nix;
  rendered = pkgs.writeText "rules.yml" (
    builtins.toJSON (
      rules.mkRules {
        inherit lib;
        thresholds = rules.defaults;
        nasProbed = true;
        dnsServed = true;
        watchedUnits = [
          "sshd"
          "tailscaled"
          "cadvisor"
          "comin"
        ];
      }
    )
  );
in
pkgs.runCommand "alert-rules" { nativeBuildInputs = [ pkgs.prometheus.cli ]; } ''
  cp ${rendered} rules.yml
  cp ${./alert-rules}/*.yml .
  promtool check rules rules.yml
  promtool test rules events.yml host.yml stacks.yml dns.yml
  touch $out
''
