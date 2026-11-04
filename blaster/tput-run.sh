#!/bin/bash
# Throughput run with the DPDK BNG Blaster against the physical lab (ACCEL_TEMPLATE=accel-ppp-lab-cap.conf):
#   tput-run.sh <run-name> <sessions> <downstream pps per session> <upstream pps per session> <frame length> [seconds]
# Brings the sessions up (no traffic), starts one downstream and one upstream stream per session, samples Blaster
# and VPP while they run, stops them and reports loss per direction. Output: captures/<run-name>/
. "$(dirname "$0")/../lab-env.sh"
NAME=$1; COUNT=$2; DS=$3; US=$4; LEN=$5; SECS=${6:-30}
BIN=${BB_DPDK_BIN:-/opt/bngblaster-upstream/bin}; SOCK=/tmp/bb-tput.sock; R=/tmp/bb-tput
OUT=$LAB/captures/$NAME; mkdir -p $OUT
exec > >(tee $OUT/test.log) 2>&1
sec() { echo; echo "################ $* ($(date +%T))"; }
bbq() { ssh $BB "bash -s" <<< "$1"; }
cli() { bbq "sudo $BIN/bngblaster-cli $SOCK $*"; }
counter() { cli session-counters 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['session-counters'].get('$1', 0))" 2>/dev/null || echo 0; }

python3 - "$LAB/blaster/cap-pppoe.json" "$COUNT" "$DS" "$US" "$LEN" > $OUT/config.json <<'EOF'
import json, sys
c = json.load(open(sys.argv[1]))
n, ds, us, ln = (int(x) for x in sys.argv[2:6])
c["sessions"].update({"count": n, "start-rate": 400, "stop-rate": 400, "max-outstanding": 1600})
c.pop("session-traffic", None)
c["traffic"] = {"autostart": False}
for link in c["interfaces"]["links"]:
    link.update({"rx-threads": 4, "tx-threads": 6})
c["streams"] = [s for s in (
    {"name": "DS", "stream-group-id": 1, "type": "ipv4", "direction": "downstream", "pps": ds, "length": ln},
    {"name": "US", "stream-group-id": 1, "type": "ipv4", "direction": "upstream", "pps": us, "length": ln},
) if s["pps"] > 0]
print(json.dumps(c, indent=4))
EOF
subst $OUT/config.json | ssh $BB "cat > $R.json"
MBPS() { echo "scale=1; $1 * $2 * $LEN * 8 / 1000000" | bc; }
echo "sessions $COUNT, per session downstream $DS pps + upstream $US pps, frame length $LEN (Blaster stream length)"
echo "offered: downstream $(( COUNT * DS )) pps ~$(MBPS $COUNT $DS) Mbps, upstream $(( COUNT * US )) pps ~$(MBPS $COUNT $US) Mbps"

sec "1. Sessions up"
bbq "sudo rm -f $SOCK $R-report.json; sudo setsid nohup $BIN/bngblaster -C $R.json -S $SOCK -J $R-report.json -j streams -L $R.log -l info -b -f > $R.out 2>&1 < /dev/null &"
for i in $(seq 1 100); do bbq "sudo test -S $SOCK" && break; sleep 0.3; done
LAST=-1; SINCE=$SECONDS
while :; do
  EST=$(counter sessions-established)
  [ "$EST" -ge "$COUNT" ] && break
  [ "$EST" != "$LAST" ] && { LAST=$EST; SINCE=$SECONDS; }
  [ $((SECONDS - SINCE)) -ge 60 ] && { echo "STALLED at $EST"; break; }
  sleep 3
done
echo "established $EST/$COUNT"; sleep 5

sec "2. Traffic for ${SECS} s"
MISS0=$(ssh $BR 'for i in cx5-0 cx5-1; do sudo vppctl show hardware $i; done' | awk '/rx_missed_errors/ {s += $2} END {print s + 0}')
cli traffic-start >/dev/null
sleep 5
ssh $BR "sudo vppctl clear runtime; sudo vppctl clear errors"
# Blaster packets sent/received on the two links, as "tx rx"
bbpkts() { cli interfaces | python3 -c "
import json, sys
d = [i for i in json.load(sys.stdin)['interfaces'] if i['name'] != 'lag0']
print(sum(i.get('tx-packets', 0) for i in d), sum(i.get('rx-packets', 0) for i in d))"; }
# router NIC packets received/sent on both bond members, as "rx tx"
brpkts() { ssh $BR 'for i in cx5-0 cx5-1; do sudo vppctl show hardware $i; done' | awk '/rx_good_packets/ {r += $2} /tx_good_packets/ {t += $2} END {print r + 0, t + 0}'; }
read TX0 RX0 <<< "$(bbpkts)"; read BRX0 BTX0 <<< "$(brpkts)"; T0=$(date +%s.%N)
for i in $(seq 1 $(( SECS / 5 ))); do
  sleep 5
  read TX1 RX1 <<< "$(bbpkts)"; read BRX1 BTX1 <<< "$(brpkts)"; T1=$(date +%s.%N)
  D=$(echo "$T1 - $T0" | bc)
  printf 'blaster tx %9d rx %9d pps | router nic rx %9d tx %9d pps\n' $(echo "($TX1 - $TX0) / $D" | bc) $(echo "($RX1 - $RX0) / $D" | bc) \
    $(echo "($BRX1 - $BRX0) / $D" | bc) $(echo "($BTX1 - $BTX0) / $D" | bc)
  TX0=$TX1; RX0=$RX1; BRX0=$BRX1; BTX0=$BTX1; T0=$T1
done
sec "3. VPP while the traffic runs"
ssh $BR 'sudo bash -s' <<'EOS'
vppctl show runtime > /tmp/rt.txt
awk '/^Thread/ {t = $3} /^  vector rates in/ {printf "%-10s in %s out %s drop %s\n", t, $4, $6, $8}' /tmp/rt.txt | sed 's/,//g'
awk '/^Thread/ {t = $3} $1 == "dpdk-input" || $1 == "pppoe-input" || $1 == "worker-handoff" || $1 == "ip4-midchain" || $1 == "policer-input" || $1 == "policer-output" {v[$1] += $3; c[$1] += $3 * $6} END {for (k in v) if (v[k]) printf "%-15s %12d vectors  %7.1f clocks/pkt\n", k, v[k], c[k] / v[k]}' /tmp/rt.txt
vppctl show errors | grep -vE '^\s+0 ' | grep -iE 'drop|full|miss|congest|no free|violate|exceed' | head -8
EOS
MISS1=$(ssh $BR 'for i in cx5-0 cx5-1; do sudo vppctl show hardware $i; done' | awk '/rx_missed_errors/ {s += $2} END {print s + 0}')
echo "router NIC rx_missed during traffic: +$(( MISS1 - MISS0 ))"
cli traffic-stop >/dev/null; sleep 3

sec "4. Loss"
cli stream-stats | python3 -c "
import json, sys
s = json.load(sys.stdin).get('stream-stats', {})
print({k: v for k, v in s.items() if any(x in k for x in ('flows', 'tx-packets', 'rx-packets', 'loss'))})" 2>/dev/null || cli stream-stats | head -30
cli stream-summary 2>/dev/null | python3 -c "
import json, sys
tot = {}
for s in json.load(sys.stdin).get('stream-summary', []):
    d = s.get('direction', '?'); t = tot.setdefault(d, [0, 0, 0])
    t[0] += s.get('tx-packets', 0); t[1] += s.get('rx-packets', 0); t[2] += s.get('loss', 0)
for d, (tx, rx, loss) in tot.items():
    print(f'{d:<11} tx {tx:>12} rx {rx:>12} loss {loss:>10} ({100.0 * loss / tx if tx else 0:.4f}%)')" 2>/dev/null

sec "5. Teardown"
cli terminate >/dev/null
for i in $(seq 1 600); do bbq "pgrep -x bngblaster >/dev/null" || break; sleep 1; done
ssh $BB "sudo cat $R.out" > $OUT/bngblaster.out
grep -E -A12 'Stream Traffic|Traffic Streams' $OUT/bngblaster.out | head -30
