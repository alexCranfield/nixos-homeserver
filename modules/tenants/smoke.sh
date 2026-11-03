# The tenant VMs' (virtual machines') smoke test, run inside a VM by `just
# tenant-smoke` (docs/runbooks/tenants.md). Each probe either reaches what a
# VM may reach or fails to reach what it may not; the exit status is the
# number of probes that went the wrong way.
#
# Arguments: the router's LAN address, the nuc's tailnet address, and the
# other tenant VM's address. The tailnet address is looked up at run time, not
# written here, since this repository is public.
set -u
router=$1
tailnet=$2
other=$3
nuc=192.168.1.131
dns=10.88.0.1
wrong=0

pass() { printf 'ok    %s\n' "$1"; }
fail() {
  printf 'WRONG %s\n' "$1"
  wrong=$((wrong + 1))
}
# reaches <what> <command...>: the command must succeed.
reaches() {
  what=$1
  shift
  if "$@" > /dev/null 2>&1; then pass "reaches $what"; else fail "does not reach $what"; fi
}
# blocked <what> <command...>: the command must fail.
blocked() {
  what=$1
  shift
  if "$@" > /dev/null 2>&1; then fail "reaches $what"; else pass "blocked from $what"; fi
}
# shellcheck disable=SC2329 # called through "$@" in blocked
tcp() { nc -z -w 3 "$1" "$2"; }

echo "== $(hostname)"

wan=$(curl -s --max-time 5 https://1.1.1.1/cdn-cgi/trace | sed -n 's/^ip=//p')
if [ -n "$wan" ]; then pass "reaches the internet"; else fail "does not reach the internet"; fi

reaches "its Blocky" test -n "$(dig +short +time=3 +tries=1 @$dns example.com)"
answer=$(dig +short +time=3 +tries=1 @$dns doubleclick.net)
if [ "$answer" = 0.0.0.0 ]; then pass "its Blocky blocks ads"; else fail "its Blocky answered doubleclick.net with '$answer'"; fi
for name in nuc.home.arpa "-x $nuc" "-x $router"; do
  # shellcheck disable=SC2086 # the reverse lookups are two words on purpose
  status=$(dig +time=3 +tries=1 @$dns $name | grep -o 'status: [A-Z]*')
  if [ "$status" = "status: NXDOMAIN" ]; then pass "no LAN name for $name"; else fail "$name gave $status"; fi
done

blocked "the LAN's Blocky ($nuc:53)" dig +short +time=3 +tries=1 @$nuc example.com
blocked "the router ($router:443)" tcp "$router" 443
blocked "the router's console on its public address" curl -sk --max-time 5 -o /dev/null "https://$wan/"
blocked "the nuc's SSH on the tenant network" tcp "$dns" 22
blocked "the nuc on the tailnet" tcp "$tailnet" 22
blocked "a Docker published port (25565)" tcp "$nuc" 25565
blocked "the other tenant VM ($other:22)" tcp "$other" 22
blocked "the LAN by ping" ping -c 1 -W 2 "$router"

echo "== $(hostname): $wrong wrong"
exit "$wrong"
