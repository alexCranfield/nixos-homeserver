# Check for ticket 3.2 (#23): compose files under stacks/ keep ADR
# (Architecture Decision Record) 0006's rules on ports, networks and mounts,
# against what each stack declares in Nix (scripts/check_compose.py).
#
# The checker first runs on the fixtures in tests/compose-check/: `good` must
# pass, and every other case breaks exactly one rule and must fail naming it,
# so a rule that stops working fails this check rather than passing quietly.
# Then it runs on the real stacks/, with the nuc's declarations.
{
  pkgs,
  manifest,
  stacks,
}:
let
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  real = pkgs.writeText "manifest.json" (builtins.toJSON manifest);
in
pkgs.runCommand "compose-check"
  {
    nativeBuildInputs = [ python ];
  }
  ''
    check() { python3 ${../scripts/check_compose.py} "$@"; }
    fixtures=${./compose-check}

    echo "good:"
    check $fixtures/manifest.json $fixtures/good

    for dir in $fixtures/*/; do
      case=$(basename "$dir")
      [ "$case" = good ] && continue
      # The rule a case breaks is its name, up to any `--variant`.
      rule=''${case%%--*}
      if result=$(check $fixtures/manifest.json "$dir" 2>&1); then
        echo "$case: passed, but breaks $rule" >&2
        exit 1
      fi
      if ! grep -q ": $rule: " <<< "$result"; then
        echo "$case: failed without naming $rule:" >&2
        echo "$result" >&2
        exit 1
      fi
      echo "$case: $(grep ": $rule: " <<< "$result" | head -1)"
    done

    echo "stacks/:"
    check ${real} ${stacks}
    touch $out
  ''
