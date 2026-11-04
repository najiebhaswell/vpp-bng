#!/bin/bash
# Removes what lab-phys-up.sh added: accel, PPPoE mappings, tap950 with its sub-interfaces, pb* VLAN devices and the
# sub-interfaces it created on ACCESS_IF/NET_IF (PPPOE_VLAN, NET_VLAN, QinQ ids >= 10000). Other sub-interfaces stay.
PV=${PPPOE_VLAN:-300}; NV=${NET_VLAN:-301}; ACC=${ACCESS_IF:-BondEthernet0}; NET=${NET_IF:-$ACC}
V=$(mktemp); trap 'rm -f $V' EXIT
systemctl stop accel-ppp-lab 2>/dev/null; systemctl reset-failed accel-ppp-lab 2>/dev/null
vppctl show pppoe control-plane binding | awk 'NR>2 && NF==2 && $2 ~ /^tap950/ {print "create pppoe map dp", $1, "cp", $2, "del"}' >> $V
vppctl show int | awk -v a="$ACC" -v n="$NET" -v pv="$PV" -v nv="$NV" '{split($1, x, ".")}
  (x[1] == a || x[1] == n) && (x[2] == pv || x[2] == nv || x[2] + 0 >= 10000) {print "delete sub-interface", $1}' >> $V
vppctl show int | awk '$1 ~ /^tap950\./ {print "delete sub-interface", $1}' >> $V
[ -s $V ] && vppctl exec $V >/dev/null 2>&1
vppctl delete tap tap950 2>/dev/null
# the VLAN devices on pb go with it
ip link del pb 2>/dev/null
true
