#!/bin/bash
# Login storm on top of active sessions, as after the failure of the other BNG: brings <sessions> up at <rate>/s,
# then every second session (session group 2) goes at once and dials again at up to <rate>/s, and times how long it
# takes until all are up again. Group 1 keeps running: its flaps, from the per-session report, are sessions the storm
# broke. STORM=accel (default): the router terminates group 2 (a list taken once, 16 accel-cmd in parallel, so a
# session that is already back is not hit again) and BNG Blaster reconnects straight away. STORM=blaster: Blaster
# hangs group 2 up itself and dials after RECONNECT_DELAY s (default 5); its control loop stalls after that with
# 32k sessions (it sends ~20 pps with thousands of sessions outstanding), so the result is the tester's.
#   storm-run.sh <run-name> <sessions> <rate> [hold-seconds]
# Run against the physical lab with the same QINQ (S-VLAN[-range]:type:C-VLAN range): one N:1 access entry per
# S/C pair, sessions spread round-robin over them. Every session sends 1 pps each way.
#   ACCESS_IF=e810-0 NET_IF=cx5-1 PPPOE_VLAN=none QINQ="100-109:dot1q:1-10 200-209:dot1ad:1-10" \
#     ACCEL_TEMPLATE=accel-ppp-lab-cap.conf lab-phys-up.sh            (on the router)
#   QINQ=... PORTS="e810-0 cx5-1" storm-run.sh storm-64k 64000 1000
# Router state comes from the stats segment and accel only (vppctl show commands stop the workers). VPP worker
# barriers during the storm go to barriers.txt (see barriers.py). The storm ends when as many sessions are up as
# before it. SHOTDIR=<dir> in xterm as in tput-run.sh.
. "$(dirname "$0")/../lab-env.sh"
NAME=$1; COUNT=$2; RATE=$3; HOLD=${4:-30}
BIN=${BB_DPDK_BIN:-/opt/bngblaster-upstream/bin}; SOCK=/tmp/bb-storm.sock; R=/tmp/bb-storm
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
counters() { cli session-counters 2>/dev/null | python3 -c "
import json, sys
c = json.load(sys.stdin)['session-counters']
print(c.get('sessions-established', 0), c.get('sessions-flapped', 0), c.get('session-traffic-flows-verified', 0))" 2>/dev/null || echo "0 0 0"; }
brstate() {
  ssh $BR "sudo BR_DIR=$BR_DIR bash -s" <<'EOF'
s=$(accel-cmd -p 2001 show stat | tr -d '\r')
st() { echo "$s" | awk -v k="$1" '$1 == k":" {print $2; exit}'; }
q=$(echo "$s" | awk '/auth avg query time/ {print $(NF - 1); exit}' | cut -d/ -f2)
m=$(python3 $BR_DIR/blaster/rxmiss.py)
echo "accel starting $(st starting) active $(st active), radius $q ms, rx-miss $m"
EOF
}
missed() { brstate | grep -oE 'rx-miss [0-9]+' | grep -oE '[0-9]+$'; }

python3 - "$LAB/blaster/qinq-10k.json" "$COUNT" "$RATE" "${QINQ:?QINQ=...}" > $OUT/config.json <<'EOF'
import json, sys
c = json.load(open(sys.argv[1]))
n, rate = int(sys.argv[2]), int(sys.argv[3])
base = c["interfaces"]["access"][0]
access = []
for q in sys.argv[4].split():
    sr, t, cr = q.split(":")
    s1, _, s2 = sr.partition("-"); c1, _, c2 = cr.partition("-")
    for s in range(int(s1), int(s2 or s1) + 1):
        for cv in range(int(c1), int(c2 or c1) + 1):
            a = {k: v for k, v in base.items() if not k.endswith("-vlan-min") and not k.endswith("-vlan-max")}
            a.update({"vlan-mode": "N:1", "outer-vlan": s, "inner-vlan": cv, "qinq": t == "dot1ad",
                      "stream-group-id": 1, "session-group-id": len(access) % 2 + 1})
            access.append(a)
c["interfaces"]["access"] = access
c["sessions"].update({"count": n, "start-rate": rate, "stop-rate": rate, "max-outstanding": max(1600, 4 * rate)})
c["pppoe"]["reconnect"] = True
print(json.dumps(c, indent=4))
EOF
subst $OUT/config.json | ssh $BB "cat > $R.json"
echo "sessions $COUNT over $(python3 -c "import json; print(len(json.load(open('$OUT/config.json'))['interfaces']['access']))" ) S/C VLAN pairs (N:1), start-rate $RATE/s, reconnect on, 1 pps each way per session"

sec "1. $COUNT sessions up at $RATE/s"
bbq "sudo rm -f $SOCK $R-report.json; sudo setsid nohup $BIN/bngblaster -C $R.json -S $SOCK -J $R-report.json -j sessions -L $R.log -l info -b -f > $R.out 2>&1 < /dev/null &"
for i in $(seq 1 100); do bbq "sudo test -S $SOCK" && break; sleep 0.3; done
T0=$SECONDS; LAST=-1; SINCE=$SECONDS
while :; do
  read EST FLAP FLOWS <<< "$(counters)"
  printf '%5ds established %6s/%s | %s\n' $((SECONDS - T0)) $EST $COUNT "$(brstate)"
  [ "$EST" -ge "$COUNT" ] && break
  [ "$EST" != "$LAST" ] && { LAST=$EST; SINCE=$SECONDS; }
  [ $((SECONDS - SINCE)) -ge 60 ] && { echo "STALLED at $EST"; break; }
  sleep 5
done
echo "established $EST/$COUNT after $((SECONDS - T0)) s"
echo "holding $HOLD s"; sleep $HOLD
read EST FLAP FLOWS <<< "$(counters)"
echo "before the storm: established $EST, flapped $FLAP, verified flows $FLOWS | $(brstate)"
echo "control plane, 10 s of steady state:"; ssh $BR "sudo python3 $BR_DIR/blaster/cpstat.py 10"

sec "2. Storm (${STORM:-accel}): session group 2 (every second session) goes at once and dials again"
ssh $BR "sudo vppctl event-logger resize ${ELOG_EVENTS:-8000000} >/dev/null; sudo vppctl event-logger trace api barrier >/dev/null"
M0=$(missed); T1=$SECONDS; MIN=$EST; PRE=$EST
ssh $BR "sudo python3 $BR_DIR/blaster/cpstat.py -t ${CPSTAT_SECS:-90}" > $OUT/cpstat-storm.txt &
CPID=$!
if [ "${STORM:-accel}" = blaster ]; then
  cli session-restart session-group-id 2 reconnect-delay ${RECONNECT_DELAY:-5}
  TPID=
else
  # group 2 = even session ids (access entries alternate the group, sessions go round-robin over them)
  ssh $BR "sudo bash -s" > $OUT/terminate.txt 2>&1 <<'EOF' &
accel-cmd -p 2001 show sessions username | tr -d '\r' | awk 'NR > 2 && $1 ~ /[02468]$/ {print $1}' > /tmp/storm-users
echo "terminating $(wc -l < /tmp/storm-users) sessions"
xargs -a /tmp/storm-users -P16 -n1 accel-cmd -p 2001 terminate username > /dev/null
echo "terminations done after $SECONDS s"
EOF
  TPID=$!
fi
while :; do
  read EST FLAP FLOWS <<< "$(counters)"
  [ "$EST" -lt "$MIN" ] && MIN=$EST
  printf '%5ds established %6s/%s flapped %6s | %s\n' $((SECONDS - T1)) $EST $COUNT $FLAP "$(brstate)"
  [ $((SECONDS - T1)) -ge 10 ] && [ "$EST" -ge "$PRE" ] && { BACK=$((SECONDS - T1)); break; }
  [ $((SECONDS - T1)) -ge 900 ] && { echo "TIMEOUT"; BACK=$((SECONDS - T1)); break; }
  sleep 2
done
[ -n "$TPID" ] && { wait $TPID; cat $OUT/terminate.txt; }
wait $CPID; echo "control plane per second, first ${CPSTAT_SECS:-90} s of the storm (every 10th line; all in cpstat-storm.txt):"
awk 'NR % 10 == 1' $OUT/cpstat-storm.txt | cut -c1-190
echo "storm: lowest $MIN established, $EST/$PRE back after $BACK s, router rx-miss +$(( $(missed) - M0 ))"
ssh $BR "sudo vppctl event-logger trace api barrier disable >/dev/null"

sec "3. After the storm"
sleep 15
read EST FLAP FLOWS <<< "$(counters)"
echo "established $EST, flapped $FLAP, verified flows $FLOWS | $(brstate)"
ssh $BR "sudo vppctl show errors | grep -iE 'tap|no free|full|miss|drop' | grep -vE '^\s+0 ' | head -8"
cli terminate >/dev/null
for i in $(seq 1 900); do bbq "pgrep -x bngblaster >/dev/null" || break; sleep 1; done
for i in $(seq 1 120); do [ "$(brstate | grep -oE 'active [0-9]+' | grep -oE '[0-9]+$')" = 0 ] && break; sleep 2; done
bbq "sudo grep -E 'RX HW Missed|PADI   TX|PADR   TX|LCP Request|IPv4:' $R.out"
ssh $BB "sudo cat $R.out" > $OUT/bngblaster.out
echo "router after teardown: $(brstate)"

# after the traffic stopped: show event-logger holds the workers while it formats millions of events
ssh $BR "sudo vppctl show event-logger all | grep -E 'bar-trace|bar-rel|api-msg'" > $OUT/elog.txt
python3 $LAB/blaster/barriers.py $OUT/elog.txt $OUT/barriers.txt | grep -vE '^\?|nl_neigh|rpc_call|cli_dispatch' | head -30
ssh $BB "sudo cat $R-report.json" > $OUT/report.json
python3 - $OUT/report.json $OUT/config.json <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
ss = d.get("sessions") or d.get("report", {}).get("sessions") or []
pairs = len(json.load(open(sys.argv[2]))["interfaces"]["access"])
g = {}
for x in ss:
    # sessions go round-robin over the access entries, whose session group alternates 1/2
    k = x.get("session-group-id") or ((x.get("session-id", 1) - 1) % pairs) % 2 + 1
    v = g.setdefault(k, [0, 0, 0])
    v[0] += 1; v[1] += x.get("flapped", 0) > 0; v[2] += x.get("flapped", 0)
for k in sorted(g):
    print("session group %s: %d sessions, %d flapped (%d flaps)" % (k, *g[k]))
PYEOF
shot
