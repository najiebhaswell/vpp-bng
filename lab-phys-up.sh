#!/bin/bash
# Physical BNG lab towards the BNG Blaster host. DP: new sub-interfaces on the access interface (default the bond
# BondEthernet0, or a port such as ACCESS_IF=cx5-0). CP: plain tap950 (host "pb" in the root netns, MAC of the
# access interface) with the same VLANs, because LCPs of bond sub-interfaces have to stay in netns dataplane with
# bond0. accel runs in the root netns. Existing sub-interfaces are not touched; lab-phys-down.sh removes only what
# this script adds (use the same ACCESS_IF/NET_IF there).
#   ACCESS_IF=BondEthernet0                PPPoE side
#   NET_IF=<ACCESS_IF>                     network side
#   PPPOE_VLAN=300                         single-tag PPPoE VLAN (sub-interface id 300), "none" for QinQ only
#   NET_VLAN=301                           network side, 172.31.98.1/30 (bngblaster is .2)
#   QINQ="100:dot1q:10-59 200-204:dot1ad:1-1000"  S-VLAN[-range]:type:C-VLAN range, sub-interface ids S*10000+C
#   ACCEL_TEMPLATE=accel-ppp-lab-cap.conf  accel config template (default accel-ppp-lab-phys.conf)
set -eu
. "$(dirname "$0")/lab-env.sh"
PV=${PPPOE_VLAN:-300}; NV=${NET_VLAN:-301}; ACC=${ACCESS_IF:-BondEthernet0}; NET=${NET_IF:-$ACC}
MAC=$(vppctl show hardware-interfaces $ACC | awk '/Ethernet address/{print $3; exit}')
# a port outside the router config (e.g. a NIC added for the lab) comes up admin down
vppctl set int state $ACC up; vppctl set int state $NET up
[ -e /run/netns/rootns ] || ip netns attach rootns 1
vppctl create tap id 950 host-if-name pb host-mac-addr $MAC host-ns rootns >/dev/null
vppctl set int state tap950 up
# frames from accel are addressed to the subscriber's MAC, not to tap950
vppctl set interface promiscuous on tap950
ip link set pb up
# thousands of sub-interfaces: one vppctl exec and one ip -batch instead of a command each
V=$(mktemp); K=$(mktemp); trap 'rm -f $V $K' EXIT
# DP sub-interface on the access interface and CP sub-interface on tap950 with the same tags, mapped to each other
pair() {
  echo "create sub-interfaces $ACC $1 $2 exact-match"
  echo "create sub-interfaces tap950 $1 $2 exact-match"
  echo "set int state $ACC.$1 up"
  echo "set int state tap950.$1 up"
  echo "create pppoe map dp $ACC.$1 cp tap950.$1"
} >> $V
if [ "$PV" != none ]; then
  pair $PV "dot1q $PV"
  echo "link add link pb name pb.$PV type vlan id $PV" >> $K; echo "link set pb.$PV up" >> $K
fi
for q in ${QINQ:-}; do
  IFS=: read SR T R <<< "$q"; S1=${SR%-*}; S2=${SR#*-}; C1=${R%-*}; C2=${R#*-}
  PROTO=802.1Q; [ $T = dot1ad ] && PROTO=802.1ad
  for S in $(seq $S1 $S2); do
    echo "link add link pb name pb.$S type vlan proto $PROTO id $S" >> $K; echo "link set pb.$S up" >> $K
    for C in $(seq $C1 $C2); do
      pair $((S * 10000 + C)) "$T $S inner-dot1q $C"
      echo "link add link pb.$S name pb.$S.$C type vlan id $C" >> $K; echo "link set pb.$S.$C up" >> $K
    done
  done
done
{
  echo "create sub-interfaces $NET $NV dot1q $NV exact-match"
  echo "set int ip address $NET.$NV 172.31.98.1/30"
  echo "set int state $NET.$NV up"
} >> $V
vppctl exec $V >/dev/null
ip -batch $K
vppctl show pppoe control-plane binding | tail -n +3 | wc -l | sed 's/^/pppoe mappings: /'
mkdir -p /var/log/accel-ppp-lab
install_conf $LAB/${ACCEL_TEMPLATE:-accel-ppp-lab-phys.conf} /etc/accel-ppp-lab-phys.conf
systemd-run -q --unit=accel-ppp-lab --property=AllowedCPUs=0,14-17 /usr/local/sbin/accel-pppd -c /etc/accel-ppp-lab-phys.conf -p /run/accel-ppp-lab.pid
