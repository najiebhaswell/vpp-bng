#!/bin/bash
# One BNG Blaster run against the lab (lab-blaster-up.sh must be up):
#   blaster-run.sh <config.json> <run-name> [session-count] [hold-seconds]
# Output in captures/<run-name>: test.log, report.json, bngblaster.log, access.pcap
. "$(dirname "$0")/../lab-env.sh"
CFG=$1; NAME=$2; COUNT=${3:-}; HOLD=${4:-30}
OUT=$LAB/captures/$NAME; mkdir -p $OUT
SOCK=/run/bngblaster.sock; B="ip netns exec bngbl"
exec > >(tee $OUT/test.log) 2>&1
sec() { echo; echo "################ $* ($(date +%T))"; }
run() { echo "\$ $*"; eval "$@"; echo; }
cli() { bngblaster-cli $SOCK "$@"; }
counter() { cli session-counters 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['session-counters'].get('$1', 0))" 2>/dev/null || echo 0; }
vppstate() {
  run "vppctl show pppoe session | head -1"
  run "vppctl show policer | grep -c '^Name'"
  run "vppctl show ip fib | grep -cE '^100\.64\.[0-9]+\.[0-9]+/32'"
}

sec "0. Before"
subst $CFG > $OUT/config.json
run "grep -v '^\s*$' $CFG"
run "accel-cmd -p 2001 show stat | grep -E -A6 '^sessions:'"
vppstate

sec "1. Session setup${COUNT:+ ($COUNT sessions)}"
rm -f $SOCK
echo "\$ taskset -c 16,17 ip netns exec bngbl bngblaster -C $(basename $CFG)${COUNT:+ -c $COUNT} -S $SOCK -J report.json -L bngblaster.log -l info &"
nohup taskset -c 16,17 $B bngblaster -C $OUT/config.json ${COUNT:+-c $COUNT} -S $SOCK -J $OUT/report.json -j sessions -L $OUT/bngblaster.log -l info -b -f \
  > $OUT/bngblaster.out 2>&1 &
for i in $(seq 1 50); do [ -S $SOCK ] && break; sleep 0.2; done
T0=$(date +%s.%N); WANT=$(counter sessions)
while :; do
  EST=$(counter sessions-established); NOW=$(date +%s.%N)
  printf '%6.1fs established %s/%s\n' $(echo "$NOW - $T0" | bc) $EST $WANT
  [ "$EST" -ge "$WANT" ] && break
  [ $(echo "$NOW - $T0 > 300" | bc) = 1 ] && { echo "TIMEOUT"; break; }
  sleep 2
done
T1=$(date +%s.%N)
echo "all $EST sessions established after $(echo "$T1 - $T0" | bc | cut -c1-6) s"; echo

sec "2. State with all sessions up"
run "cli session-counters"
run "accel-cmd -p 2001 show stat"
run "accel-cmd -p 2001 show sessions ifname,username,ip,rate-limit,state | head -6"
vppstate
run "vppctl show pppoe control-plane binding | tail -n +3 | wc -l"

sec "3. Session traffic (${HOLD} s, 10 pps per session each way)"
$B timeout 3 tcpdump -i vbsub-p -nn -e -s 128 -c 2000 -w $OUT/access.pcap 'ether proto 0x8864 or vlan' >/dev/null 2>&1
sleep $HOLD
run "cli session-counters | grep -E 'traffic|flapped|established'"
run "cli session-traffic"
echo "\$ # downstream session packets on the access side (VPP -> subscriber), one per VLAN layout"
$B tcpdump -nn -e -r $OUT/access.pcap 2>/dev/null | grep -E '172\.31\.9[89]\.2[.0-9]* > 100\.64\.' \
  | awk '{k=$0; sub(/ PPPoE .*/, "", k); sub(/^[^ ]+ [^ ]+ > [^ ]+, /, "", k); gsub(/vlan [0-9]+/, "vlan N", k); gsub(/length [0-9]+/, "", k); if (!seen[k]++) print}' \
  | head -4 | cut -c1-230
echo

echo "\$ # traffic loss per session before teardown (bngblaster-cli session-info for every session)"
for id in $(seq 1 $WANT); do cli session-info session-id $id; done | python3 -c "
import json, sys
dec, txt, i = json.JSONDecoder(), sys.stdin.read(), 0
tot = dict(up_tx=0, up_rx=0, up_loss=0, down_tx=0, down_rx=0, down_loss=0); lossy = 0
while True:
    while i < len(txt) and txt[i].isspace(): i += 1
    if i >= len(txt): break
    o, i = dec.raw_decode(txt, i)
    t = o.get('session-info', {}).get('session-traffic', {})
    for d in ('up', 'down'):
        for k in ('tx', 'rx', 'loss'):
            tot[d + '_' + k] += t.get(d + 'stream-ipv4-' + (k + '-packets' if k != 'loss' else 'loss'), 0)
    lossy += bool(t.get('upstream-ipv4-loss') or t.get('downstream-ipv4-loss'))
print(tot, 'sessions with loss:', lossy)
"
echo

sec "4. Teardown"
T2=$(date +%s.%N)
run "cli terminate"
for i in $(seq 1 300); do pgrep -x bngblaster >/dev/null || break; sleep 0.5; done
T3=$(date +%s.%N)
echo "bngblaster finished $(echo "$T3 - $T2" | bc | cut -c1-6) s after terminate"; echo
for i in $(seq 1 30); do vppctl show pppoe session | grep -q 'No pppoe' && break; sleep 1; done
run "accel-cmd -p 2001 show stat | grep -E -A6 '^sessions:'"
vppstate
run "tail -25 $OUT/bngblaster.out"
chown -R ${SUDO_USER:-root}: $OUT
