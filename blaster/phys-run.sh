#!/bin/bash
# Physical BNG Blaster run, from a machine that reaches both: bngblaster on the tester BB (bb$), accel/VPP state from the router BR ($).
#   phys-run.sh <config.json> <run-name> <session-count> [hold-seconds]
# The router must have lab-phys-up.sh applied. Output: captures/<run-name>/ (test.log, report.json, bngblaster.log, access.pcap)
CFG=$1; NAME=$2; COUNT=$3; HOLD=${4:-30}
. "$(dirname "$0")/../lab-env.sh"
SOCK=/tmp/bb-lab.sock; R=/tmp/bb-lab; BIN=$BB_BIN
OUT=$LAB/captures/$NAME; mkdir -p $OUT
exec > >(tee $OUT/test.log) 2>&1
# SHOTDIR=<dir>, run inside xterm: dump the window ($WINDOWID) to <dir>/NN.xwd and clear it before each part
N=0
shot() {
  [ -n "${SHOTDIR:-}" ] || return 0
  sleep 1; N=$((N + 1)); xwd -silent -id $WINDOWID -out $SHOTDIR/$(printf %02d $N).xwd; clear > /dev/tty
}
sec() { case $1 in 0.*) ;; *) shot ;; esac; echo; echo "################ $* ($(date +%T))"; }
br() { echo "\$ $1"; ssh $BR "sudo bash -s" <<< "$1"; echo; }
bb() { echo "bb\$ $1"; ssh $BB "bash -s" <<< "$1"; echo; }
bbq() { ssh $BB "bash -s" <<< "$1"; }
counter() { bbq "sudo $BIN/bngblaster-cli $SOCK session-counters" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['session-counters'].get('$1', 0))" 2>/dev/null || echo 0; }
rxmiss() { ssh $BR "sudo vppctl show hardware-interfaces cx5-0 cx5-1" | awk '/rx_missed_errors/{s+=$2} END{print s+0}'; }
vppstate() {
  br "vppctl show pppoe session | head -1; vppctl show policer | grep -c '^Name'; vppctl show ip fib | grep -cE '^100\.64\.[0-9]+\.[0-9]+/32'"
}

sec "0. Before"
bb "sudo $BIN/bngblaster -v | head -1; ip -br link show ens1f0np0; ip -br link show ens1f1np1"
br "vppctl show bond; vppctl show lacp | grep -E 'cx5|RX-state'"
br "accel-cmd -p 2001 show stat | grep -E -A3 '^sessions:'"
vppstate

MISS0=$(rxmiss)
sec "1. Session setup ($COUNT sessions)"
subst $CFG | ssh $BB "cat > $R.json"
echo "bb\$ sudo bngblaster -C $(basename $CFG) -c $COUNT -S $SOCK -J report.json -j sessions -L bngblaster.log -l info &"
bbq "sudo rm -f $SOCK $R-report.json; sudo setsid nohup $BIN/bngblaster -C $R.json -c $COUNT -S $SOCK -J $R-report.json -j sessions -L $R.log -l info -b -f > $R.out 2>&1 < /dev/null &"
for i in $(seq 1 50); do bbq "sudo test -S $SOCK" && break; sleep 0.3; done
T0=$(date +%s.%N)
while :; do
  EST=$(counter sessions-established); NOW=$(date +%s.%N)
  printf '%6.1fs established %s/%s\n' $(echo "$NOW - $T0" | bc) $EST $COUNT
  [ "$EST" -ge "$COUNT" ] && break
  [ $(echo "$NOW - $T0 > 300" | bc) = 1 ] && { echo "TIMEOUT"; break; }
  sleep 2
done
echo "all $EST sessions established after $(echo "$(date +%s.%N) - $T0" | bc | cut -c1-6) s (polled every ~2 s)"; echo

sec "2. State with all sessions up"
bb "sudo $BIN/bngblaster-cli $SOCK session-counters | grep -E 'sessions|setup|traffic' | grep -vE 'dhcp|l2tp|ipoe|stream'"
br "vppctl show lacp | grep -E 'cx5|RX-state'; vppctl show bond"
shot
br "accel-cmd -p 2001 show stat | sed -n '/^sessions:/,\$p'"
br "accel-cmd -p 2001 show sessions ifname,username,ip,rate-limit,state | head -6"
vppstate

sec "3. Session traffic (${HOLD} s, 10 pps per session each way)"
# remove the old capture first: tcpdump (running as user tcpdump) cannot overwrite it in /tmp and fails silently
bbq "sudo rm -f $R-access.pcap; sudo timeout 3 tcpdump -i ens1f0np0 -nn -e -s 128 -c 3000 -w $R-access.pcap 'ether src $(ssh $BR "sudo vppctl show hardware-interfaces BondEthernet0" | awk '/Ethernet address/{print $3; exit}')' >/dev/null 2>&1"
ssh $BR "sudo vppctl clear runtime"
sleep $HOLD
br "vppctl show runtime | awk '/^Thread/{t=\$3} /^pppoe-input /{printf \"%-10s pppoe-input vectors %s\\n\", t, \$4}'; vppctl show int features cx5-0 | sed -n '/^device-input:/,/^\$/p'"
bb "sudo $BIN/bngblaster-cli $SOCK session-traffic"
echo "bb\$ # downstream session packets from the router on ens1f0np0, one per VLAN layout"
bbq "sudo tcpdump -nn -e -r $R-access.pcap 2>/dev/null" | grep -E '172\.31\.98\.2[.0-9]* > 100\.64\.' \
  | awk '{k=$0; sub(/ PPPoE .*/, "", k); sub(/^[^ ]+ [^ ]+ > [^ ]+, /, "", k); gsub(/vlan [0-9]+/, "vlan N", k); gsub(/length [0-9]+/, "", k); if (!seen[k]++) print}' \
  | head -4 | cut -c1-230
echo
echo "# NIC rx_missed on cx5-0+cx5-1 during setup and traffic: +$(( $(rxmiss) - MISS0 ))"; echo
echo "bb\$ # traffic loss per session before teardown (bngblaster-cli session-info for every session)"
bbq "for id in \$(seq 1 $COUNT); do sudo $BIN/bngblaster-cli $SOCK session-info session-id \$id; done" | python3 -c "
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
br "vppctl show errors | grep -iE 'no free|full|drop|miss|fail' | grep -vE '^\s+0 ' | head -8; vppctl show int BondEthernet0 | grep -E 'drops|rx-miss|tx-error'"

sec "4. Teardown"
T2=$(date +%s.%N)
bb "sudo $BIN/bngblaster-cli $SOCK terminate"
for i in $(seq 1 300); do bbq "pgrep -x bngblaster >/dev/null" || break; sleep 0.5; done
echo "bngblaster finished $(echo "$(date +%s.%N) - $T2" | bc | cut -c1-6) s after terminate"; echo
br "for i in \$(seq 1 30); do vppctl show pppoe session | grep -q 'No pppoe' && break; sleep 1; done; accel-cmd -p 2001 show stat | grep -E -A3 '^sessions:'"
vppstate
shot
bb "sudo tail -22 $R.out"
ssh $BB "sudo cat $R-report.json" > $OUT/report.json
ssh $BB "sudo cat $R.log" > $OUT/bngblaster.log
ssh $BB "sudo cat $R.out" > $OUT/bngblaster.out
ssh $BB "sudo cat $R-access.pcap" > $OUT/access.pcap
shot
