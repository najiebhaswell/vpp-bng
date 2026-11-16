#!/bin/bash
# CGNAT through the BNG (NAT44-ED with output-feature on the network side, see README): every session sends a UDP
# and a TCP (raw-tcp) stream both ways with BNG Blaster's NAT support, i.e. the network side learns each session's
# translated address and port from the upstream packets and sends the downstream there.
#   nat-run.sh <run-name> <sessions> <rate> <pps per stream and direction> [seconds] [ip length]
# Run against the physical lab with the same QINQ, N:1 as for storm-run.sh. Reports whether every flow came back
# (verified flows), the loss per direction, the router's NAT sessions and the control-plane load.
# SHOTDIR=<dir> in xterm as in tput-run.sh.
. "$(dirname "$0")/../lab-env.sh"
NAME=$1; COUNT=$2; RATE=$3; PPS=$4; SECS=${5:-30}; LEN=${6:-128}
BIN=${BB_DPDK_BIN:-/opt/bngblaster-upstream/bin}; SOCK=/tmp/bb-nat.sock; R=/tmp/bb-nat
OUT=$LAB/captures/$NAME; mkdir -p $OUT
exec > >(tee $OUT/test.log) 2>&1
N=0
shot() {
  [ -n "${SHOTDIR:-}" ] || return 0
  sleep 1; N=$((N + 1)); xwd -silent -id $WINDOWID -out $SHOTDIR/$(printf %02d $N).xwd; clear > /dev/tty
}
sec() { case $1 in 0.*) ;; *) shot ;; esac; echo; echo "################ $* ($(date +%T))"; }
bbq() { ssh $BB "bash -s" <<< "$1"; }
cli() { bbq "sudo $BIN/bngblaster-cli $SOCK $*"; }
counter() { cli session-counters 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['session-counters'].get('$1', 0))" 2>/dev/null || echo 0; }
flows() { cli stream-stats 2>/dev/null | python3 -c "
import json, sys
s = json.load(sys.stdin)['stream-stats']
print(s.get('total-flows', 0), s.get('verified-flows', 0))" 2>/dev/null || echo "0 0"; }
nat() { ssh $BR "sudo vppctl show nat44 summary" | tr -d '\r' | awk '/^total sessions/ {t = $3} /^(tcp|udp|icmp) sessions/ {p = $1} p && $1 == "total:" {v[p] = $2; p = ""} END {printf "nat sessions %s (tcp %s, udp %s)", t, v["tcp"] + 0, v["udp"] + 0}'; }

sec "0. Router"
ssh $BR "sudo vppctl show nat44 interfaces; sudo vppctl show nat44 addresses | grep -c '^[0-9]' | sed 's/^/pool addresses: /'; sudo vppctl show memory main-heap | grep total:"
python3 $LAB/blaster/qinq-n1.py $LAB/blaster/qinq-10k.json "$COUNT" "$RATE" "${QINQ:?QINQ=...}" |
  python3 -c "
import json, sys
c = json.load(sys.stdin)
pps, ln = int(sys.argv[1]), int(sys.argv[2])
c.pop('session-traffic', None)
c['traffic'] = {'autostart': True}
c['streams'] = [
    {'name': 'UDP', 'stream-group-id': 1, 'type': 'ipv4', 'direction': 'both', 'pps': pps, 'length': ln, 'nat': True},
    {'name': 'TCP', 'stream-group-id': 1, 'type': 'ipv4', 'direction': 'both', 'pps': pps, 'length': ln, 'nat': True,
     'raw-tcp': True},
]
print(json.dumps(c, indent=4))" "$PPS" "$LEN" > $OUT/config.json
subst $OUT/config.json | ssh $BB "cat > $R.json"
echo "sessions $COUNT (N:1 over $(python3 -c "import json; print(len(json.load(open('$OUT/config.json'))['interfaces']['access']))") S/C pairs), UDP + TCP stream per session, $PPS pps each way, IP length $LEN"

sec "1. Sessions up, streams through NAT"
bbq "sudo rm -f $SOCK; sudo setsid nohup $BIN/bngblaster -C $R.json -S $SOCK -L $R.log -l info -b -f > $R.out 2>&1 < /dev/null &"
for i in $(seq 1 100); do bbq "sudo test -S $SOCK" && break; sleep 0.3; done
T0=$SECONDS; LAST=-1; SINCE=$SECONDS
while :; do
  EST=$(counter sessions-established); read F V <<< "$(flows)"
  printf '%5ds established %6s/%s, flows verified %7s/%s | %s\n' $((SECONDS - T0)) $EST $COUNT $V $F "$(nat)"
  [ "$EST" -ge "$COUNT" ] && [ "$V" -ge "$F" ] && [ "$F" -gt 0 ] && break
  [ "$EST$V" != "$LAST" ] && { LAST=$EST$V; SINCE=$SECONDS; }
  [ $((SECONDS - SINCE)) -ge 60 ] && { echo "STALLED"; break; }
  [ $((SECONDS - T0)) -ge ${UP_MAX:-600} ] && { echo "TIMEOUT after ${UP_MAX:-600} s"; break; }
  sleep 5
done
echo "after $((SECONDS - T0)) s: established $EST/$COUNT, verified flows $V/$F"

sec "2. $SECS s of NAT traffic"
cli stream-reset > /dev/null
ssh $BR "sudo python3 $BR_DIR/blaster/cpstat.py $SECS | sed 's/, ksoftirqd [0-9]*%, systemd-udevd [0-9]*%//'"
echo "$(nat) | rx-miss $(ssh $BR "sudo python3 $BR_DIR/blaster/rxmiss.py")"
ssh $BR "sudo vppctl show errors | grep -iE 'nat|out of ports|no translation|max' | grep -vE '^\s+0 ' | head -8"

sec "3. Teardown"
cli terminate > /dev/null
for i in $(seq 1 900); do bbq "pgrep -x bngblaster >/dev/null" || break; sleep 1; done
ssh $BB "sudo cat $R.out" > $OUT/bngblaster.out
sed -n '/Traffic Streams/,/^$/p' $OUT/bngblaster.out | head -20
grep -E 'RX HW Missed' $OUT/bngblaster.out
echo "router: $(nat)"
shot
