# Check for ticket #27: the unit tests of the Alertmanager-to-Discord relay
# (modules/observability/alert-relay.py). Plain Python `unittest` with fake
# senders, so no VM (virtual machine) is needed; the end-to-end path is in
# tests/alerting.nix.
{ pkgs }:
pkgs.runCommand "alert-relay" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  cp ${../modules/observability/alert-relay.py} alert-relay.py
  cp ${./alert-relay/test_relay.py} test_relay.py
  RELAY=$PWD/alert-relay.py python3 -I -m unittest discover -v -s . -p "test_*.py"
  touch $out
''
