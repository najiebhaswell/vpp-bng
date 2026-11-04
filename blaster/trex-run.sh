#!/bin/bash
# PPPoE throughput with TRex, from the machine that reaches both hosts. Needs the bond in static (xor) mode,
# since TRex speaks no LACP, and the physical lab down (this script brings it up with accel-ppp-lab-tput.conf).
#   trex-run.sh <run-name> <sessions> "<ip-size> <up|down|bi> <mult per port>" ...
#   e.g. trex-run.sh tput-trex 512 "1400 bi 40gbps" "imix bi 30gbps" "46 up 10mpps"
# BNG Blaster sets the sessions up through a static LAG and is then killed (no PADT); with LCP echo off the
# sessions stay. Output: captures/<run-name>/test.log with one JSON result per test and the router's view of it.
. "$(dirname "$0")/../lab-env.sh"
NAME=$1; COUNT=$2; shift 2
BIN=${BB_DPDK_BIN:-/opt/bngblaster-upstream/bin}; SOCK=/tmp/bb-trex.sock; R=/tmp/bb-trex
TREX=/opt/trex/v3.08; TREX_MAC=${TREX_MAC:-b8:ce:f6:1d:63:32}; WINDOW=10
OUT=$LAB/captures/$NAME; mkdir -p $OUT
exec > >(tee $OUT/test.log) 2>&1
sec() { echo; echo "################ $* ($(date +%T))"; }
bbq() { ssh $BB "bash -s" <<< "$1"; }
brq() { ssh $BR "sudo bash -s" <<< "$1"; }
cli() { bbq "sudo $BIN/bngblaster-cli $SOCK $*"; }
counter() { cli session-counters 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['session-counters'].get('$1', 0))" 2>/dev/null || echo 0; }
missed() { brq "for i in cx5-0 cx5-1; do vppctl show hardware \$i; done" | awk '/rx_missed_errors/ {s += $2} END {print s + 0}'; }

sec "0. Router"
MODE=$(brq "vppctl show bond" | awk '$1 == "BondEthernet0" {print $3}')
echo "BondEthernet0 mode: $MODE"
[ "$MODE" = xor ] || { echo "the bond must be in xor (static) mode: TRex does not speak LACP"; exit 1; }
brq "ACCEL_TEMPLATE=accel-ppp-lab-tput.conf bash $BR_DIR/lab-phys-up.sh | tail -1
vppctl show int features BondEthernet0 | grep -q worker-handoff || vppctl set interface handoff BondEthernet0 workers 0-11
for i in cx5-0 cx5-1 BondEthernet0; do echo \"\$i handoff \$(vppctl show int features \$i | sed -n '/^device-input:/,/^\$/p' | grep -c worker-handoff)\"; done"
bbq "sudo systemctl stop trex 2>/dev/null; sudo systemctl reset-failed trex 2>/dev/null; true"

sec "1. $COUNT sessions through BNG Blaster (static LAG)"
python3 - "$LAB/blaster/cap-pppoe.json" "$COUNT" <<'EOF' | subst /dev/stdin | ssh $BB "cat > $R.json"
import json, sys
c = json.load(open(sys.argv[1]))
c["sessions"].update({"count": int(sys.argv[2]), "start-rate": 400, "stop-rate": 400, "max-outstanding": 1600})
c["interfaces"]["lag"] = [dict(l, lacp=False) for l in c["interfaces"]["lag"]]
c.pop("session-traffic", None)
print(json.dumps(c, indent=4))
EOF
bbq "sudo rm -f $SOCK; sudo setsid nohup $BIN/bngblaster -C $R.json -S $SOCK -L $R.log -l info -b -f > $R.out 2>&1 < /dev/null &"
for i in $(seq 1 100); do bbq "sudo test -S $SOCK" && break; sleep 0.3; done
LAST=-1; SINCE=$SECONDS
while :; do
  EST=$(counter sessions-established)
  [ "$EST" -ge "$COUNT" ] && break
  [ "$EST" != "$LAST" ] && { LAST=$EST; SINCE=$SECONDS; }
  [ $((SECONDS - SINCE)) -ge 60 ] && { echo "STALLED at $EST"; break; }
  sleep 3
done
echo "established $EST/$COUNT; killing bngblaster without teardown"
bbq "sudo pkill -9 -x bngblaster; for i in \$(seq 1 30); do pgrep -x bngblaster >/dev/null || break; sleep 1; done; pgrep -x bngblaster && echo still running || echo gone"

sec "2. Session list and network neighbor"
BNGMAC=$(brq "vppctl show hardware BondEthernet0" | awk '/Ethernet address/ {print $3; exit}' | tr -dc '0-9a-f:')
brq "vppctl show pppoe session; echo ===; accel-cmd -p 2001 show sessions calling-sid,ip" | BNGMAC=$BNGMAC SJSON=$OUT/sessions.json python3 -c "
import json, os, re, sys
vpp, accel = sys.stdin.read().split('===')
sid = {m.group(2): int(m.group(1)) for m in re.finditer(r'session-id (\d+) .*?client-mac (\S+)', vpp, re.S)}
sessions = []
for line in accel.splitlines():
    f = [x.strip() for x in line.split('|')]
    if len(f) == 2 and f[0] in sid and re.match(r'\d+\.\d+\.\d+\.\d+$', f[1]):
        sessions.append({'mac': f[0], 'sid': sid[f[0]], 'ip': f[1]})
json.dump({'bng-mac': os.environ['BNGMAC'], 'access-vlan': 300,
           'network-vlan': 301, 'network-ip': '172.31.98.2', 'sessions': sessions}, open(os.environ['SJSON'], 'w'))
print(len(sessions), 'sessions with MAC, PPPoE session id and IP')"
scp -q $OUT/sessions.json $BB:/tmp/trex-sessions.json
scp -q $LAB/trex/pppoe-trex.py $BB:/tmp/pppoe-trex.py
brq "vppctl set ip neighbor BondEthernet0.301 172.31.98.2 $TREX_MAC static; vppctl show ip neighbors BondEthernet0.301"

sec "3. TRex"
bbq "sudo systemd-run -q --unit=trex --working-directory=$TREX $TREX/t-rex-64 -i -c 16 --cfg /etc/trex_cfg.yaml --no-scapy-server --no-ofed-check"
for i in $(seq 1 60); do bbq "ss -ltn | grep -q ':4501 '" && break; sleep 2; done
sleep 5
for t in "$@"; do
  read SIZE DIR MULT <<< "$t"
  sec "size $SIZE, $DIR, $MULT per port"
  bbq "python3 /tmp/pppoe-trex.py /tmp/trex-sessions.json $SIZE $DIR $MULT $WINDOW > /tmp/trex-result.json 2>/tmp/trex-err.log" &
  TREXPID=$!
  sleep 7
  M0=$(missed); brq "vppctl clear runtime; vppctl clear errors"
  sleep $(( WINDOW - 3 ))
  brq "vppctl show runtime > /tmp/rt.txt
awk '/^Thread/ {t = \$3} /^  vector rates in/ {printf \"%-10s in %s\\n\", t, \$4}' /tmp/rt.txt | sed 's/,//' | paste -sd' ' | fold -w 200
awk '\$1 == \"worker-handoff\" || \$1 == \"pppoe-input\" || \$1 == \"ip4-midchain\" || \$1 == \"policer-output\" || \$1 == \"policer-input\" {v[\$1] += \$3; c[\$1] += \$3 * \$6} END {for (k in v) if (v[k]) printf \"%-15s %12d vectors %7.1f clocks/pkt\\n\", k, v[k], c[k] / v[k]}' /tmp/rt.txt
vppctl show errors | grep -vE '^\s+0 ' | grep -iE 'drop|full|miss|congest|no free|violate|exceed' | head -6"
  echo "router NIC rx_missed: +$(( $(missed) - M0 ))"
  # not a bare wait: that also waits for the tee behind exec
  wait $TREXPID
  bbq "cat /tmp/trex-result.json; tail -3 /tmp/trex-err.log"
done

sec "4. Cleanup"
bbq "sudo systemctl stop trex; sudo systemctl reset-failed trex 2>/dev/null; true"
brq "vppctl set ip neighbor del BondEthernet0.301 172.31.98.2 $TREX_MAC; bash $BR_DIR/lab-phys-down.sh >/dev/null 2>&1; vppctl show pppoe session | head -1"
