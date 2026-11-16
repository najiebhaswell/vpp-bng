#!/bin/bash
# Session counters under RADIUS interim accounting with a given accel-pppd build: brings the physical lab up with
# accel-ppp-lab-acct.conf (interim every 30 s) and ACCEL_BIN, runs storm-run.sh, and adds what the counters did:
# sessions whose counters are still 0 after two interims, accel-pppd CPU time, and the accel log lines about the
# counters and terminations. Output: captures/<run-name>/ as storm-run.sh, plus acct.txt.
# ACCT_INTERIM=<s> interim interval (default 30; with 64k sessions use 300, 30 s overloads the lab RADIUS).
#   acct-run.sh <run-name> <accel-pppd path on the router> <sessions> <rate> [hold-seconds]
#   e.g. acct-run.sh acct-pr42-10k /opt/accel-pr42/sbin/accel-pppd 10000 200
# Same lab as storm-run.sh: ACCESS_IF=e810-0 NET_IF=cx5-1 PPPOE_VLAN=none QINQ="100-109:dot1q:1-10 200-209:dot1ad:1-10".
. "$(dirname "$0")/../lab-env.sh"
NAME=$1; ABIN=$2; COUNT=$3; RATE=$4; HOLD=${5:-90}
QINQ=${QINQ:-100-109:dot1q:1-10 200-209:dot1ad:1-10}; export QINQ
OUT=$LAB/captures/$NAME; mkdir -p $OUT
ENV="ACCESS_IF=${ACCESS_IF:-e810-0} NET_IF=${NET_IF:-cx5-1} PPPOE_VLAN=${PPPOE_VLAN:-none}"
LOG=/var/log/accel-ppp-lab/accel-ppp.log
ssh $BR "sudo env $ENV bash $BR_DIR/lab-phys-down.sh >/dev/null 2>&1; sudo truncate -s0 $LOG 2>/dev/null
sudo env $ENV QINQ='$QINQ' ACCT_INTERIM=${ACCT_INTERIM:-30} ACCEL_TEMPLATE=accel-ppp-lab-acct.conf ACCEL_BIN=$ABIN bash $BR_DIR/lab-phys-up.sh | tail -1
systemctl show accel-ppp-lab -p ExecStart --value | grep -oE 'path=[^ ;]+'"

# two interims into the hold: how many sessions still show no traffic (every session sends 1 pps each way)
(
  until grep -q "^holding" $OUT/test.log 2>/dev/null; do sleep 2; done
  sleep 70
  ssh $BR "sudo accel-cmd -p 2001 show sessions username,rx-bytes-raw,tx-bytes-raw | tr -d '\r'" |
    awk -F'|' 'NR > 2 && NF >= 3 {gsub(/ /, ""); n++; if ($2 + 0 == 0 || $3 + 0 == 0) z++}
         END {printf "after two interims: %d sessions, %d with a 0 counter\n", n, z}' > $OUT/acct-hold.txt
) &
HPID=$!

PORTS="${PORTS:-e810-0 cx5-1}" bash $LAB/blaster/storm-run.sh $NAME $COUNT $RATE $HOLD
wait $HPID 2>/dev/null

{
  echo "accel-pppd: $ABIN"
  cat $OUT/acct-hold.txt 2>/dev/null
  ssh $BR "sudo bash -s" <<EOF
P=\$(systemctl show accel-ppp-lab -p MainPID --value)
echo "accel-pppd CPU time over the run: \$(ps -o cputimes= -p \$P) s, RSS \$(ps -o rss= -p \$P) kB"
echo "accel log lines: \$(wc -l < $LOG)"
for p in baseline vppstats 'NAS-Error|nas-error|NAS_ERROR' 'Lost-Carrier|lost-carrier|LOST_CARRIER' 'counter' 'statistics' 'no free sid' 'error'; do
  printf '  %-40s %s\n' "\$p" "\$(grep -ciE "\$p" $LOG)"
done
echo "most frequent warnings/errors (numbers stripped):"
grep -iE 'warn|error|fail|baseline|vppstats' $LOG | sed -E 's/^\[[^]]*\]//; s/[0-9]+/N/g' | sort | uniq -c | sort -rn | head -12
EOF
} | tee $OUT/acct.txt
