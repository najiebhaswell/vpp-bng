#!/bin/bash
# Removes what lab-phys-up.sh added: accel, PPPoE mappings, tap950 with its sub-interfaces, pb* VLAN devices and the
# BondEthernet0 sub-interfaces it created (PPPOE_VLAN, NET_VLAN, QinQ ids >= 10000). Other sub-interfaces stay.
PV=${PPPOE_VLAN:-300}; NV=${NET_VLAN:-301}; B=BondEthernet0
systemctl stop accel-ppp-lab 2>/dev/null; systemctl reset-failed accel-ppp-lab 2>/dev/null
vppctl show pppoe control-plane binding | awk 'NR>2 && NF==2 && $2 ~ /^tap950/ {print $1, $2}' | while read dp cp; do vppctl create pppoe map dp $dp cp $cp del; done
vppctl show int | awk -v b="$B" -v pv="$PV" -v nv="$NV" '{split($1, a, ".")} a[1]==b && (a[2]==pv || a[2]==nv || a[2]+0 >= 10000) {print $1}' \
  | while read i; do vppctl delete sub-interface $i; done
vppctl show int | awk '$1 ~ /^tap950\./ {print $1}' | while read i; do vppctl delete sub-interface $i; done
vppctl delete tap tap950 2>/dev/null
ip link del pb 2>/dev/null
true
