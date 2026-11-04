#!/bin/bash
# Session churn with the DPDK BNG Blaster (LACP) against the physical lab (ACCEL_TEMPLATE=accel-ppp-lab-cap.conf):
#   churn-run.sh <run-name> <sessions> <restarts per second> <churn seconds>
# Brings the sessions up with 1 pps of traffic each, then the router terminates random sessions at the given
# rate and Blaster logs them in again through RADIUS. Samples both ends every 10 s and checks afterwards that VPP holds exactly one
# interface, two policers and one /32 per session (no leaks). Output: captures/<run-name>/
. "$(dirname "$0")/../lab-env.sh"
NAME=$1; COUNT=$2; RATE=$3; SECS=$4
BIN=${BB_DPDK_BIN:-/opt/bngblaster-upstream/bin}; SOCK=/tmp/bb-churn.sock; R=/tmp/bb-churn
OUT=$LAB/captures/$NAME; mkdir -p $OUT
exec > >(tee $OUT/test.log) 2>&1
sec() { echo; echo "################ $* ($(date +%T))"; }
bbq() { ssh $BB "bash -s" <<< "$1"; }
cli() { bbq "sudo $BIN/bngblaster-cli $SOCK $*"; }
counters() { cli session-counters 2>/dev/null | python3 -c "
import json, sys
c = json.load(sys.stdin)['session-counters']
print(c.get('sessions-established', 0), c.get('sessions-flapped', 0), c.get('session-traffic-flows-verified', 0))" 2>/dev/null || echo "0 0 0"; }
brstate() {
  ssh $BR 'sudo bash -s' <<'EOF'
s=$(accel-cmd -p 2001 show stat)
st() { echo "$s" | awk -v k="$1" '$1 == k":" {print $2; exit}'; }
q=$(echo "$s" | awk '/auth avg query time/ {print $NF; exit}' | cut -d/ -f2)
p=$(ps -o %cpu=,rss= -C accel-pppd | awk '{printf "cpu %s%% rss %dM", $1, $2/1024}')
v=$(vppctl show pppoe session | head -1 | grep -oE '[0-9]+' || echo 0)
m=$(for i in cx5-0 cx5-1; do vppctl show hardware $i; done | awk '/rx_missed_errors/ {s += $2} END {print s + 0}')
echo "accel starting $(st starting) active $(st active), $p, radius ${q}ms | vpp sessions $v, rx_missed $m"
EOF
}
leaks() {
  ssh $BR 'sudo bash -s' <<'EOF'
a=$(accel-cmd -p 2001 show stat | awk '$1 == "active:" {print $2; exit}')
v=$(vppctl show pppoe session | head -1 | grep -oE '[0-9]+' || echo 0)
i=$(vppctl show int | grep -c '^pppoe_session')
p=$(vppctl show policer | grep -c '^Name')
f=$(vppctl show ip fib | grep -cE '^100\.6[4-6]\.[0-9]+\.[0-9]+/32')
echo "accel active $a | vpp sessions $v, session interfaces $i, policers $p, /32 routes $f"
EOF
}

python3 - "$LAB/blaster/cap-pppoe.json" "$COUNT" <<'EOF' | subst /dev/stdin | ssh $BB "cat > $R.json"
import json, sys
c = json.load(open(sys.argv[1]))
c["sessions"].update({"count": int(sys.argv[2]), "start-rate": 400, "stop-rate": 400, "max-outstanding": 1600})
c["pppoe"]["reconnect"] = True
print(json.dumps(c, indent=4))
EOF

sec "0. Before"
echo "sessions $COUNT, churn $RATE restarts/s for $SECS s"
leaks

sec "1. Sessions up"
bbq "sudo rm -f $SOCK; sudo setsid nohup $BIN/bngblaster -C $R.json -S $SOCK -L $R.log -l info -b -f > $R.out 2>&1 < /dev/null &"
for i in $(seq 1 100); do bbq "sudo test -S $SOCK" && break; sleep 0.3; done
LAST=-1; SINCE=$SECONDS
while :; do
  read EST FLAP VER <<< "$(counters)"
  [ "$EST" -ge "$COUNT" ] && break
  [ "$EST" != "$LAST" ] && { LAST=$EST; SINCE=$SECONDS; }
  [ $((SECONDS - SINCE)) -ge 60 ] && { echo "STALLED at $EST"; break; }
  sleep 3
done
sleep 20
read EST FLAP VER <<< "$(counters)"
echo "established $EST/$COUNT, flapped $FLAP, flows verified $VER"
echo "router: $(brstate)"
leaks
IF0=$(ssh $BR "sudo vppctl show int | grep -c '^pppoe_session'")

sec "2. Churn: $RATE random session restarts per second for $SECS s"
# the router terminates random sessions (as a RADIUS Disconnect would) and BNG Blaster logs them in again;
# Blaster's control socket answers only ~10 commands/s, too slow to drive the churn from that side
ssh $BR "cat > /tmp/churn.py" <<'EOS'
import random, subprocess, sys, time
user, count, rate, secs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
procs = []; t0 = time.time(); n = 0
while time.time() - t0 < secs:
    procs.append(subprocess.Popen(["accel-cmd", "-p", "2001", "terminate", "username", f"{user}{random.randint(1, count)}"],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    procs = [p for p in procs if p.poll() is None]
    n += 1
    time.sleep(max(0, t0 + n / rate - time.time()))
print("terminates", n, "rate", round(n / (time.time() - t0), 1), "/s")
EOS
ssh $BR "sudo nohup python3 /tmp/churn.py $SUB_USER $COUNT $RATE $SECS > /tmp/churn.out 2>&1 &"
for i in $(seq 1 $(( SECS / 10 ))); do
  sleep 10
  read EST FLAP VER <<< "$(counters)"
  printf '%4ds blaster established %6s flapped %6s | %s\n' $((i * 10)) $EST $FLAP "$(brstate)"
done
sleep 5; ssh $BR "cat /tmp/churn.out"

sec "3. After churn"
LAST=-1; SINCE=$SECONDS
while :; do
  read EST FLAP VER <<< "$(counters)"
  [ "$EST" -ge "$COUNT" ] && break
  [ "$EST" != "$LAST" ] && { LAST=$EST; SINCE=$SECONDS; }
  [ $((SECONDS - SINCE)) -ge 60 ] && { echo "not all sessions back: $EST"; break; }
  sleep 3
done
sleep 15
read EST FLAP VER <<< "$(counters)"
echo "established $EST/$COUNT, flapped $FLAP, flows verified $VER"
echo "router: $(brstate)"
leaks
echo "pppoe session interfaces before churn $IF0, after $(ssh $BR "sudo vppctl show int | grep -c '^pppoe_session'")"
ssh $BR "sudo vppctl show errors | grep -vE '^\s+0 ' | grep -iE 'drop|full|miss|fail|congest' | head -6"

sec "4. Teardown"
cli terminate >/dev/null
for i in $(seq 1 600); do bbq "pgrep -x bngblaster >/dev/null" || break; sleep 1; done
for i in $(seq 1 60); do [ "$(ssh $BR 'sudo vppctl show pppoe session | head -1' | grep -oE '[0-9]+' || echo 0)" = 0 ] && break; sleep 2; done
leaks
ssh $BB "sudo cat $R.out" > $OUT/bngblaster.out
grep -E -A3 'Sessions PPPoE|Flapped|Session Traffic' $OUT/bngblaster.out | head -12
