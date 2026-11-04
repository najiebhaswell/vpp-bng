#!/bin/bash
# PPPoE throughput with TRex, from the machine that reaches both hosts. The physical lab must be down (this script
# brings it up with accel-ppp-lab-tput.conf).
#   trex-run.sh <run-name> <sessions> "<ip-size> <up|down|bi> <mult per port>" ...
#   e.g. trex-run.sh tput-trex 512 "1400 bi 40gbps" "imix bi 30gbps" "46 up 10mpps"
# Default: subscribers and network on BondEthernet0, which then has to be in static (xor) mode since TRex speaks no
# LACP; per-session streams over both ports. With ACCESS_IF=cx5-0 NET_IF=cx5-1 (TRex port 0 and 1) instead:
# subscribers on port 0 (PPPOE_VLAN/QINQ as for lab-phys-up.sh), network on port 1, one stream per direction.
#   ACCESS_IF=cx5-0 NET_IF=cx5-1 PPPOE_VLAN=none QINQ="100-104:dot1q:1-1000 200-204:dot1ad:1-1000" \
#     CFG_BASE=blaster/qinq-10k.json trex-run.sh tput-trex-qinq 10000 "1400 bi 4.46mpps"
# HANDOFF=0 takes worker-handoff off the access port, for NICs that spread PPPoE over their RX queues themselves
# (E810 with the comms DDP package).
# BNG Blaster sets the sessions up (CFG_BASE, default blaster/cap-pppoe.json as a static LAG) and is then killed
# (no PADT); with LCP echo off the sessions stay. Output: captures/<run-name>/test.log with one JSON result per test
# and the router's view of it. SHOTDIR=<dir>, run inside xterm: window dumps <dir>/NN.xwd as in tput-run.sh.
. "$(dirname "$0")/../lab-env.sh"
NAME=$1; COUNT=$2; shift 2
ACC=${ACCESS_IF:-BondEthernet0}; NET=${NET_IF:-$ACC}; PV=${PPPOE_VLAN:-300}; NV=${NET_VLAN:-301}
LABENV="ACCESS_IF=$ACC NET_IF=$NET PPPOE_VLAN=$PV NET_VLAN=$NV QINQ='${QINQ:-}'"
BIN=${BB_DPDK_BIN:-/opt/bngblaster-upstream/bin}; SOCK=/tmp/bb-trex.sock; R=/tmp/bb-trex
TREX=/opt/trex/v3.08; TREX_MAC=${TREX_MAC:-b8:ce:f6:1d:63:32}; WINDOW=${WINDOW:-10}
[ $NET != BondEthernet0 ] && TREX_MAC=${TREX_NET_MAC:-b8:ce:f6:1d:63:33}
OUT=$LAB/captures/$NAME; mkdir -p $OUT
exec > >(tee $OUT/test.log) 2>&1
N=0
shot() {
  [ -n "${SHOTDIR:-}" ] || return 0
  sleep 1; N=$((N + 1)); xwd -silent -id $WINDOWID -out $SHOTDIR/$(printf %02d $N).xwd; clear > /dev/tty
}
sec() { case $1 in 0.*) ;; *) shot ;; esac; echo; echo "################ $* ($(date +%T))"; }
bbq() { ssh $BB "bash -s" <<< "$1"; }
brq() { ssh $BR "sudo bash -s" <<< "$1"; }
cli() { bbq "sudo $BIN/bngblaster-cli $SOCK $*"; }
counter() { cli session-counters 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['session-counters'].get('$1', 0))" 2>/dev/null || echo 0; }
# physical ports whose rx_missed counts: the bond members, or the access and network ports
PORTS="cx5-0 cx5-1"; [ $ACC = BondEthernet0 ] || PORTS="$ACC $NET"
missed() { brq "for i in $PORTS; do vppctl show hardware \$i; done" | awk '/rx_missed_errors/ {s += $2} END {print s + 0}'; }

sec "0. Router"
if [ $ACC = BondEthernet0 ]; then
  MODE=$(brq "vppctl show bond" | awk '$1 == "BondEthernet0" {print $3}')
  echo "BondEthernet0 mode: $MODE"
  [ "$MODE" = xor ] || { echo "the bond must be in xor (static) mode: TRex does not speak LACP"; exit 1; }
fi
brq "$LABENV ACCEL_TEMPLATE=accel-ppp-lab-tput.conf bash $BR_DIR/lab-phys-up.sh | tail -1
if [ ${HANDOFF:-1} = 1 ]; then
  vppctl show int features $ACC | grep -q worker-handoff || vppctl set interface handoff $ACC workers 0-11
else
  vppctl show int features $ACC | grep -q worker-handoff && vppctl set interface handoff $ACC workers 0-11 disable
fi
for i in \$(echo $PORTS BondEthernet0 | tr ' ' '\n' | sort -u); do echo \"\$i handoff \$(vppctl show int features \$i | sed -n '/^device-input:/,/^\$/p' | grep -c worker-handoff)\"; done"
bbq "sudo systemctl stop trex 2>/dev/null; sudo systemctl reset-failed trex 2>/dev/null; true"

sec "1. $COUNT sessions through BNG Blaster"
python3 - "${CFG_BASE:-$LAB/blaster/cap-pppoe.json}" "$COUNT" <<'EOF' | subst /dev/stdin | ssh $BB "cat > $R.json"
import json, sys
c = json.load(open(sys.argv[1]))
c["sessions"].update({"count": int(sys.argv[2]), "start-rate": 400, "stop-rate": 400, "max-outstanding": 1600})
if "lag" in c["interfaces"]:
    c["interfaces"]["lag"] = [dict(l, lacp=False) for l in c["interfaces"]["lag"]]
c.pop("session-traffic", None)
print(json.dumps(c, indent=4))
EOF
bbq "sudo rm -f $SOCK; sudo setsid nohup $BIN/bngblaster -C $R.json -S $SOCK -L $R.log -l info -b -f > $R.out 2>&1 < /dev/null &"
for i in $(seq 1 100); do bbq "sudo test -S $SOCK" && break; sleep 0.3; done
LAST=-1; SINCE=$SECONDS; T0=$SECONDS
while :; do
  EST=$(counter sessions-established)
  [ "$EST" -ge "$COUNT" ] && break
  [ "$EST" != "$LAST" ] && { LAST=$EST; SINCE=$SECONDS; echo "  $((SECONDS - T0))s established $EST"; }
  [ $((SECONDS - SINCE)) -ge 60 ] && { echo "STALLED at $EST"; break; }
  sleep 3
done
echo "established $EST/$COUNT in $((SECONDS - T0))s; killing bngblaster without teardown"
bbq "sudo pkill -9 -x bngblaster; for i in \$(seq 1 30); do pgrep -x bngblaster >/dev/null || break; sleep 1; done; pgrep -x bngblaster && echo still running || echo gone"
brq "accel-cmd -p 2001 show stat | grep -A3 '^sessions:'; vppctl show pppoe session | grep -c session-id | sed 's/^/vpp pppoe sessions: /'"

sec "2. Session list and network neighbor"
BNGMAC=$(brq "vppctl show hardware $ACC" | awk '/Ethernet address/ {print $3; exit}' | tr -dc '0-9a-f:')
NETMAC=$(brq "vppctl show hardware $NET" | awk '/Ethernet address/ {print $3; exit}' | tr -dc '0-9a-f:')
brq "vppctl show pppoe session; echo ===; accel-cmd -p 2001 show sessions calling-sid,ip,inbound-if" |
  BNGMAC=$BNGMAC NETMAC=$NETMAC SJSON=$OUT/sessions.json SPLIT=$([ $ACC != $NET ] && echo 1) PV=$PV NV=$NV \
  QINQ="${QINQ:-}" python3 -c "
import json, os, re, sys
vpp, accel = sys.stdin.read().split('===')
sid = {m.group(2): int(m.group(1)) for m in re.finditer(r'session-id (\d+) .*?client-mac (\S+)', vpp, re.S)}
# S-VLAN -> TPID from QINQ (S-VLAN[-range]:type:C-VLAN range)
tpid = {}
for q in os.environ['QINQ'].split():
    sr, t, _ = q.split(':'); s1, _, s2 = sr.partition('-')
    for s in range(int(s1), int(s2 or s1) + 1):
        tpid[s] = 0x88a8 if t == 'dot1ad' else 0x8100
sessions = []
for line in accel.splitlines():
    f = [x.strip() for x in line.split('|')]
    if len(f) == 3 and f[0] in sid and re.match(r'\d+\.\d+\.\d+\.\d+$', f[1]):
        # inbound-if pb.<S> or pb.<S>.<C>
        tags = [int(x) for x in f[2].split('.')[1:]]
        vlans = [[tpid.get(tags[0], 0x8100), tags[0]]] + [[0x8100, c] for c in tags[1:]]
        sessions.append({'mac': f[0], 'sid': sid[f[0]], 'ip': f[1], 'vlans': vlans})
cfg = {'bng-mac': os.environ['BNGMAC'], 'access-vlan': int(os.environ['PV']) if os.environ['PV'] != 'none' else None,
       'network-vlan': int(os.environ['NV']), 'network-ip': '172.31.98.2', 'sessions': sessions}
if os.environ['SPLIT']:
    cfg.update({'access-port': 0, 'network-port': 1, 'network-mac': os.environ['NETMAC']})
json.dump(cfg, open(os.environ['SJSON'], 'w'))
depth = {}
for s in sessions:
    depth[len(s['vlans'])] = depth.get(len(s['vlans']), 0) + 1
print(len(sessions), 'sessions with MAC, PPPoE session id, IP and VLANs; by tag count', depth)"
scp -q $OUT/sessions.json $BB:/tmp/trex-sessions.json
scp -q $LAB/trex/pppoe-trex.py $BB:/tmp/pppoe-trex.py
brq "vppctl set ip neighbor $NET.$NV 172.31.98.2 $TREX_MAC static; vppctl show ip neighbors $NET.$NV"

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
  brq "vppctl clear runtime; vppctl clear errors; vppctl clear hardware"; M0=$(missed)
  sleep $(( WINDOW - 3 ))
  brq "vppctl show runtime > /tmp/rt.txt
for i in $ACC $NET; do vppctl show hardware \$i | awk -v i=\$i '/rx_good_packets|tx_good_packets|rx_good_bytes|tx_good_bytes/ {v[\$1] = \$2} END {printf \"%-14s rx %6.2f Mpps %6.2f Gbps   tx %6.2f Mpps %6.2f Gbps   (avg over %ds)\\n\", i, v[\"rx_good_packets\"] / $((WINDOW - 3)) / 1e6, v[\"rx_good_bytes\"] * 8 / $((WINDOW - 3)) / 1e9, v[\"tx_good_packets\"] / $((WINDOW - 3)) / 1e6, v[\"tx_good_bytes\"] * 8 / $((WINDOW - 3)) / 1e9, $((WINDOW - 3))}'; done | sort -u
vppctl show hardware $ACC | awk '\$1 ~ /^rx_q[0-9]+_packets\$/ {sub(/_packets/, \"\", \$1); printf \"%s %.2fM  \", \$1, \$2 / $((WINDOW - 3)) / 1e6} END {print \"pps per RX queue of $ACC\"}' | fold -w 200
awk '/^Thread/ {t = \$3} /^  vector rates in/ {printf \"%-10s in %s\\n\", t, \$4}' /tmp/rt.txt | sed 's/,//' | paste -sd' ' | fold -w 200
awk '\$1 == \"worker-handoff\" || \$1 == \"pppoe-input\" || \$1 == \"ip4-midchain\" || \$1 == \"policer-output\" || \$1 == \"policer-input\" {v[\$1] += \$3; c[\$1] += \$3 * \$6} END {for (k in v) if (v[k]) printf \"%-15s %12d vectors %7.1f clocks/pkt\\n\", k, v[k], c[k] / v[k]}' /tmp/rt.txt
vppctl show errors | grep -vE '^\s+0 ' | grep -iE 'drop|full|miss|congest|no free|violate|exceed' | head -6"
  echo "router NIC rx_missed: +$(( $(missed) - M0 ))"
  # not a bare wait: that also waits for the tee behind exec
  wait $TREXPID
  bbq "cat /tmp/trex-result.json; tail -3 /tmp/trex-err.log" | python3 -c "
import json, sys
for line in sys.stdin:
    try:
        r = json.loads(line)
    except ValueError:
        print(line, end=''); continue
    print(json.dumps(r))
    for d in ('up', 'down'):
        if d + '_loss_pct' in r:
            print(f\"  {d:4} {r[d + '_mbps_per_session']:6} Mbit/s per session received (IP), loss {r[d + '_loss_pct']}%\")"
done

sec "4. Cleanup"
bbq "sudo systemctl stop trex; sudo systemctl reset-failed trex 2>/dev/null; true"
brq "vppctl set ip neighbor del $NET.$NV 172.31.98.2 $TREX_MAC; $LABENV bash $BR_DIR/lab-phys-down.sh >/dev/null 2>&1; vppctl show pppoe session | head -1"
shot
