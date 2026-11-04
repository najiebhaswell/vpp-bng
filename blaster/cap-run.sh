#!/bin/bash
# Session scale run with the DPDK BNG Blaster on the tester against the physical lab
# (ACCEL_TEMPLATE=accel-ppp-lab-cap.conf lab-phys-up.sh on the router):
#   cap-run.sh <config.json> <run-name> <sessions> <start-rate> [hold-seconds]
# Samples setup progress, accel (state, CPU, RSS, RADIUS query time) and VPP every 5 s; checks that every session
# passes traffic; tears down at the same rate. Output: captures/<run-name>/ (test.log, report.json, bngblaster.out)
. "$(dirname "$0")/../lab-env.sh"
CFG=$1; NAME=$2; COUNT=$3; RATE=$4; HOLD=${5:-30}
BIN=${BB_DPDK_BIN:-/opt/bngblaster-upstream/bin}; SOCK=/tmp/bb-cap.sock; R=/tmp/bb-cap
OUT=$LAB/captures/$NAME; mkdir -p $OUT
exec > >(tee $OUT/test.log) 2>&1
sec() { echo; echo "################ $* ($(date +%T))"; }
br() { echo "\$ $1"; ssh $BR "sudo bash -s" <<< "$1"; echo; }
bbq() { ssh $BB "bash -s" <<< "$1"; }
cli() { bbq "sudo $BIN/bngblaster-cli $SOCK $*"; }
counter() { cli session-counters 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['session-counters'].get('$1', 0))" 2>/dev/null || echo 0; }
# one line of router state: accel sessions, accel CPU% (since start) and RSS, RADIUS auth time, VPP sessions/heap
brstate() {
  ssh $BR 'sudo bash -s' <<'EOF'
s=$(accel-cmd -p 2001 show stat)
st() { echo "$s" | awk -v k="$1" '$1 == k":" {print $2; exit}'; }
q=$(echo "$s" | awk '/auth avg query time/ {print $NF; exit}' | cut -d/ -f2)
p=$(ps -o %cpu=,rss= -C accel-pppd | awk '{printf "cpu %s%% rss %dM", $1, $2/1024}')
v=$(vppctl show pppoe session | head -1 | grep -oE '[0-9]+' || echo 0)
h=$(vppctl show memory main-heap | awk '/total:/ {print $4; exit}' | tr -d ,)
m=$(for i in cx5-0 cx5-1; do vppctl show hardware $i; done | awk '/rx_missed_errors/ {s += $2} END {print s + 0}')
echo "accel starting $(st starting) active $(st active), $p, radius auth $q ms | vpp sessions $v, heap used $h, rx_missed $m"
EOF
}
vppstate() {
  br "vppctl show pppoe session | head -1; echo policers \$(vppctl show policer | grep -c '^Name'); echo fib-32 \$(vppctl show ip fib | grep -cE '^100\.6[4-6]\.[0-9]+\.[0-9]+/32'); vppctl show memory main-heap | grep -E 'total:'; vppctl show int | wc -l | sed 's/^/vpp interfaces: /'"
}

python3 - "$CFG" "$COUNT" "$RATE" > $OUT/config.json <<'EOF'
import json, sys
c = json.load(open(sys.argv[1]))
c["sessions"].update({"count": int(sys.argv[2]), "start-rate": int(sys.argv[3]), "stop-rate": int(sys.argv[3]),
                      "max-outstanding": max(800, 4 * int(sys.argv[3]))})
print(json.dumps(c, indent=4))
EOF
subst $OUT/config.json | ssh $BB "cat > $R.json"

sec "0. Before"
bbq "sudo $BIN/bngblaster -v | head -1"
echo "sessions $COUNT, start-rate/stop-rate $RATE/s, CHAP via RADIUS, VLAN 300 N:1, session traffic 1 pps each way"
br "accel-cmd -p 2001 show stat | grep -E -A3 '^sessions:'; systemctl show accel-ppp-lab -p AllowedCPUs; grep -E '^thread-count' /etc/accel-ppp-lab-phys.conf"
vppstate

sec "1. Session setup"
bbq "sudo rm -f $SOCK $R-report.json; sudo setsid nohup $BIN/bngblaster -C $R.json -S $SOCK -J $R-report.json -j sessions -L $R.log -l info -b -f > $R.out 2>&1 < /dev/null &"
for i in $(seq 1 100); do bbq "sudo test -S $SOCK" && break; sleep 0.3; done
T0=$(date +%s.%N); LAST=-1; SINCE=$SECONDS
while :; do
  EST=$(counter sessions-established); NOW=$(date +%s.%N)
  printf '%6.1fs blaster established %6s/%s | %s\n' $(echo "$NOW - $T0" | bc) $EST $COUNT "$(brstate)"
  [ "$EST" -ge "$COUNT" ] && break
  [ "$EST" != "$LAST" ] && { LAST=$EST; SINCE=$SECONDS; }
  [ $((SECONDS - SINCE)) -ge 60 ] && { echo "STALLED: no new session for 60 s"; break; }
  [ $(echo "$NOW - $T0 > 1800" | bc) = 1 ] && { echo "TIMEOUT"; break; }
  sleep 5
done
T1=$(date +%s.%N)
echo "all $EST sessions established after $(echo "$T1 - $T0" | bc | cut -c1-6) s ($(echo "$EST / ($T1 - $T0)" | bc) sessions/s overall)"

sec "2. All sessions up, ${HOLD} s of session traffic"
sleep $HOLD
cli session-counters | grep -E '"(sessions|sessions-established|sessions-flapped|sessions-terminated|setup-time|setup-rate|setup-rate-min|setup-rate-avg|setup-rate-max|session-traffic-flows|session-traffic-flows-verified)"'
echo "router: $(brstate)"
vppstate
br "accel-cmd -p 2001 show stat | sed -n '/^radius/,\$p' | head -14; ps -o pid,%cpu,rss,nlwp,cmd -C accel-pppd"
br "vppctl show errors | grep -iE 'no free|full|drop|miss|fail' | grep -vE '^\s+0 ' | head -8; for i in cx5-0 cx5-1; do vppctl show hardware \$i | grep -E 'rx_missed|imissed'; done"

sec "3. Teardown"
T2=$(date +%s.%N)
cli terminate
for i in $(seq 1 3600); do bbq "pgrep -x bngblaster >/dev/null" || break; sleep 1; done
echo "bngblaster finished $(echo "$(date +%s.%N) - $T2" | bc | cut -c1-6) s after terminate"
for i in $(seq 1 120); do [ "$(brstate | grep -oE 'vpp sessions [0-9]+' | grep -oE '[0-9]+$')" = 0 ] && break; sleep 2; done
echo "router: $(brstate)"
vppstate
bbq "sudo grep -E -A8 'Verified Traffic Flows' $R.out; sudo grep -E -A6 'Violations' $R.out"
ssh $BB "sudo cat $R-report.json" > $OUT/report.json
ssh $BB "sudo cat $R.out" > $OUT/bngblaster.out
