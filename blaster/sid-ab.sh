#!/bin/bash
# A/B for the PPPoE session id release fix: for each accel-pppd build, bring the physical lab up with it, run
# churn-run.sh (random terminations, BNG Blaster logs in again) and, right after the churn, count session ids
# that accel-pppd has handed out twice and the "no free sid" warnings.
#   sid-ab.sh <sessions> <restarts per second> <churn seconds> <name>=<accel-pppd path> ...
#   e.g. sid-ab.sh 10000 300 120 base=/opt/accel-base/sbin/accel-pppd sid=/opt/accel-sid/sbin/accel-pppd
. "$(dirname "$0")/../lab-env.sh"
COUNT=$1; RATE=$2; SECS=$3; shift 3
LOG=/var/log/accel-ppp-lab/accel-ppp.log
for v in "$@"; do
  NAME=${v%%=*}; ABIN=${v#*=}; RUN=sid-$NAME-$COUNT-$RATE; OUT=$LAB/captures/$RUN
  echo "=== $NAME: $ABIN"
  ssh $BR "sudo bash $BR_DIR/lab-phys-down.sh >/dev/null 2>&1; sudo truncate -s0 $LOG 2>/dev/null
sudo env ACCEL_TEMPLATE=accel-ppp-lab-cap.conf ACCEL_BIN=$ABIN bash $BR_DIR/lab-phys-up.sh | tail -1
systemctl show accel-ppp-lab -p ExecStart --value | grep -oE 'path=[^ ;]+'"
  bash $LAB/blaster/churn-run.sh $RUN $COUNT $RATE $SECS >/dev/null 2>&1 &
  CH=$!
  until grep -q "^################ 3. After churn" $OUT/test.log 2>/dev/null; do
    kill -0 $CH 2>/dev/null || break; sleep 2
  done
  ssh $BR 'sudo bash -s' > $OUT/sid.txt <<EOF
s=\$(accel-cmd -p 2001 show sessions sid | awk 'NR > 2 && \$1 ~ /^[0-9]+\$/ {print \$1}')
echo "sessions listed: \$(echo "\$s" | grep -c .), session ids used twice or more: \$(echo "\$s" | sort | uniq -d | wc -l)"
echo "no free sid warnings: \$(grep -c 'no free sid' $LOG)"
EOF
  wait $CH
  { cat $OUT/sid.txt; grep -E "^terminates|lowest|Lowest|^established|leak" $OUT/test.log | tail -6; } | tee -a $OUT/sid.txt | sed 's/^/  /'
done
