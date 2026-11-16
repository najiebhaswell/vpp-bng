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
# (E810 with the comms DDP package); NET_HANDOFF=0 off a separate network port, which only sees plain IP.
# BNG Blaster sets the sessions up (CFG_BASE, default blaster/cap-pppoe.json as a static LAG) and is then killed
# (no PADT); with LCP echo off the sessions stay. Output: captures/<run-name>/test.log with one JSON result per test
# and the router's view of it. SHOTDIR=<dir>, run inside xterm: window dumps <dir>/NN.xwd as in tput-run.sh.
# N1=1: sessions N:1 over the QINQ pairs (blaster/qinq-n1.py) at START_RATE/s (default 1000) instead of CFG_BASE.
# NAT=1: the router's NAT44-ED (plugin and pool set up already) gets output-feature on the network sub-interface.
# REFLECT=1: TRex only sends upstream from port 0; dpdk-testpmd in 5tswap mode on the tester's network port sends
# every packet back (addresses and ports swapped), so the downstream goes through the router's out2in path;
# FLOWS=<n> source ports per session, DSTNET=<prefix> random destinations (routed to the reflector). Loss is
# then what does not come back to port 0.
. "$(dirname "$0")/../lab-env.sh"
NAME=$1; COUNT=$2; shift 2
ACC=${ACCESS_IF:-BondEthernet0}; NET=${NET_IF:-$ACC}; PV=${PPPOE_VLAN:-300}; NV=${NET_VLAN:-301}
LABENV="ACCESS_IF=$ACC NET_IF=$NET PPPOE_VLAN=$PV NET_VLAN=$NV QINQ='${QINQ:-}' ACCEL_CPUS=${ACCEL_CPUS:-0,14-17} VHOST_CPUS=${VHOST_CPUS:-}"
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
[ ${NAT:-0} = 1 ] && vppctl set interface nat44 out $NET.$NV output-feature && vppctl show nat44 interfaces | tail -1
[ -n \"${DSTNET:-}\" ] && vppctl ip route add ${DSTNET:-} via 172.31.98.2 $NET.$NV
[ ${NET_HANDOFF:-1} = 0 ] && [ $NET != $ACC ] && vppctl show int features $NET | grep -q worker-handoff && vppctl set interface handoff $NET workers 0-\$((\$(vppctl show threads | grep -c vpp_wk) - 1)) disable
if [ ${HANDOFF:-1} = 1 ]; then
  vppctl show int features $ACC | grep -q worker-handoff || vppctl set interface handoff $ACC workers 0-\$((\$(vppctl show threads | grep -c vpp_wk) - 1))
else
  vppctl show int features $ACC | grep -q worker-handoff && vppctl set interface handoff $ACC workers 0-\$((\$(vppctl show threads | grep -c vpp_wk) - 1)) disable
fi
for i in \$(echo $PORTS BondEthernet0 | tr ' ' '\n' | sort -u); do echo \"\$i handoff \$(vppctl show int features \$i | sed -n '/^device-input:/,/^\$/p' | grep -c worker-handoff)\"; done"
bbq "sudo systemctl stop trex 2>/dev/null; sudo systemctl reset-failed trex 2>/dev/null; true"

sec "1. $COUNT sessions through BNG Blaster"
if [ -n "${N1:-}" ]; then
  python3 $LAB/blaster/qinq-n1.py ${CFG_BASE:-$LAB/blaster/qinq-10k.json} "$COUNT" ${START_RATE:-1000} "${QINQ:?QINQ=...}" |
    python3 -c "import json, sys; c = json.load(sys.stdin); c.pop('session-traffic', None); c['pppoe']['reconnect'] = False; print(json.dumps(c))" |
    subst /dev/stdin | ssh $BB "cat > $R.json"
else
python3 - "${CFG_BASE:-$LAB/blaster/cap-pppoe.json}" "$COUNT" <<'EOF' | subst /dev/stdin | ssh $BB "cat > $R.json"
import json, sys
c = json.load(open(sys.argv[1]))
c["sessions"].update({"count": int(sys.argv[2]), "start-rate": 400, "stop-rate": 400, "max-outstanding": 1600})
if "lag" in c["interfaces"]:
    c["interfaces"]["lag"] = [dict(l, lacp=False) for l in c["interfaces"]["lag"]]
c.pop("session-traffic", None)
print(json.dumps(c, indent=4))
EOF
fi
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
TCFG=/etc/trex_cfg.yaml; TCORES=16
if [ ${REFLECT:-0} = 1 ]; then
  # TRex keeps port 0 (and the first 8 cores), the reflector takes the network port and cores 18-32
  bbq "sed 's/\"3b:00.1\"/\"dummy\"/' /etc/trex_cfg.yaml > /tmp/trex-reflect.yaml; grep interfaces /tmp/trex-reflect.yaml
sudo systemctl stop reflect 2>/dev/null; sudo systemctl reset-failed reflect 2>/dev/null
sudo systemd-run -q --unit=reflect dpdk-testpmd -l 18,20,22,24,26,28,30,32 --main-lcore 18 -a 0000:3b:00.1 --file-prefix reflect --socket-mem 2048 -- --forward-mode=5tswap --port-topology=loop --rxq=7 --txq=7 --nb-cores=7 --rxd=4096 --txd=4096 --rss-udp --auto-start --stats-period=60
sleep 5; systemctl is-active reflect"
  TCFG=/tmp/trex-reflect.yaml; TCORES=8
fi
bbq "sudo systemd-run -q --unit=trex --working-directory=$TREX $TREX/t-rex-64 -i -c $TCORES --cfg $TCFG --no-scapy-server --no-ofed-check"
for i in $(seq 1 60); do bbq "ss -ltn | grep -q ':4501 '" && break; sleep 2; done
sleep 5
for t in "$@"; do
  read SIZE DIR MULT <<< "$t"
  sec "size $SIZE, $DIR, $MULT per port"
  bbq "REFLECT=${REFLECT:-} FLOWS=${FLOWS:-} DSTNET=${DSTNET:-} python3 /tmp/pppoe-trex.py /tmp/trex-sessions.json $SIZE $DIR $MULT $WINDOW > /tmp/trex-result.json 2>/tmp/trex-err.log" &
  TREXPID=$!
  sleep 7
  brq "vppctl clear runtime; vppctl clear errors; vppctl clear hardware"; M0=$(missed)
  sleep $(( WINDOW - 3 ))
  brq "vppctl show runtime > /tmp/rt.txt
for i in $ACC $NET; do vppctl show hardware \$i | awk -v i=\$i '/rx_good_packets|tx_good_packets|rx_good_bytes|tx_good_bytes/ {v[\$1] = \$2} END {printf \"%-14s rx %6.2f Mpps %6.2f Gbps   tx %6.2f Mpps %6.2f Gbps   (avg over %ds)\\n\", i, v[\"rx_good_packets\"] / $((WINDOW - 3)) / 1e6, v[\"rx_good_bytes\"] * 8 / $((WINDOW - 3)) / 1e9, v[\"tx_good_packets\"] / $((WINDOW - 3)) / 1e6, v[\"tx_good_bytes\"] * 8 / $((WINDOW - 3)) / 1e9, $((WINDOW - 3))}'; done | sort -u
vppctl show hardware $ACC | awk '\$1 ~ /^rx_q[0-9]+_packets\$/ {sub(/_packets/, \"\", \$1); printf \"%s %.2fM  \", \$1, \$2 / $((WINDOW - 3)) / 1e6} END {print \"pps per RX queue of $ACC\"}' | fold -w 200
awk '/^Thread/ {t = \$3} /^  vector rates in/ {printf \"%-10s in %s\\n\", t, \$4}' /tmp/rt.txt | sed 's/,//' | paste -sd' ' | fold -w 200
awk '\$2 == \"active\" && \$4 > 0 && \$1 != \"dpdk-input\" && !/^Thread 0/ {v[\$1] += \$4; c[\$1] += \$4 * \$6; t += \$4 * \$6} END {for (k in v) printf \"%-34s %7.1f%% of worker clocks %7.1f clk/pkt %12d pkts\\n\", k, 100 * c[k] / t, c[k] / v[k], v[k]}' /tmp/rt.txt | sort -k2 -rn | head -${TOPNODES:-12}
vppctl show errors | grep -vE '^\s+0 ' | grep -iE 'drop|full|miss|congest|no free|violate|exceed|out of ports|max' | head -6
[ ${NAT:-0} = 1 ] && vppctl show nat44 summary | grep -m1 '^total sessions'"
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
    if 'reflected_mpps' in r:
        print(f\"  reflected {r['reflected_mpps']} Mpps back to the access port, loss {r['reflected_loss_pct']}%\")
    for d in ('up', 'down'):
        if d + '_loss_pct' in r:
            print(f\"  {d:4} {r[d + '_mbps_per_session']:6} Mbit/s per session received (IP), loss {r[d + '_loss_pct']}%\")"
done

sec "4. Cleanup"
bbq "sudo systemctl stop trex reflect 2>/dev/null; sudo systemctl reset-failed trex reflect 2>/dev/null; true"
brq "vppctl set ip neighbor del $NET.$NV 172.31.98.2 $TREX_MAC; $LABENV bash $BR_DIR/lab-phys-down.sh >/dev/null 2>&1; vppctl show pppoe session | head -1"
shot
