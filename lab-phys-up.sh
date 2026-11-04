#!/bin/bash
# Physical BNG lab towards the BNG Blaster host (ens1f0np0/ens1f1np1 <-> cx5-0/cx5-1 = Eth-Trunk0/BondEthernet0, LACP).
# DP: new BondEthernet0 sub-interfaces. CP: plain tap950 (host "pb" in the root netns, bond MAC) with the same VLANs,
# because LCPs of BondEthernet0 sub-interfaces have to stay in netns dataplane with bond0. accel runs in the root netns.
# Existing BondEthernet0 sub-interfaces are not touched; lab-phys-down.sh removes only what this script adds.
#   PPPOE_VLAN=300                         single-tag PPPoE VLAN (sub-interface id 300)
#   NET_VLAN=301                           network side, 172.31.98.1/30 (bngblaster is .2)
#   QINQ="100:dot1q:10-59 200:dot1ad:10-59" S-VLAN:type:C-VLAN range, sub-interface ids S*10000+C
#   ACCEL_TEMPLATE=accel-ppp-lab-cap.conf  accel config template (default accel-ppp-lab-phys.conf)
set -eu
. "$(dirname "$0")/lab-env.sh"
PV=${PPPOE_VLAN:-300}; NV=${NET_VLAN:-301}; B=BondEthernet0
MAC=$(vppctl show hardware-interfaces $B | awk '/Ethernet address/{print $3; exit}')
[ -e /run/netns/rootns ] || ip netns attach rootns 1
vppctl create tap id 950 host-if-name pb host-mac-addr $MAC host-ns rootns >/dev/null
vppctl set int state tap950 up
# frames from accel are addressed to the subscriber's MAC, not to tap950
vppctl set interface promiscuous on tap950
ip link set pb up
# DP sub-interface on the bond and CP sub-interface on tap950 with the same tags, mapped to each other
pair() {
  vppctl create sub-interfaces $B $1 $2 exact-match >/dev/null
  vppctl create sub-interfaces tap950 $1 $2 exact-match >/dev/null
  vppctl set int state $B.$1 up; vppctl set int state tap950.$1 up
  vppctl create pppoe map dp $B.$1 cp tap950.$1
}
pair $PV "dot1q $PV"
ip link add link pb name pb.$PV type vlan id $PV; ip link set pb.$PV up
for q in ${QINQ:-}; do
  IFS=: read S T R <<< "$q"; C1=${R%-*}; C2=${R#*-}
  PROTO=802.1Q; [ $T = dot1ad ] && PROTO=802.1ad
  ip link add link pb name pb.$S type vlan proto $PROTO id $S; ip link set pb.$S up
  for C in $(seq $C1 $C2); do
    pair $((S * 10000 + C)) "$T $S inner-dot1q $C"
    ip link add link pb.$S name pb.$S.$C type vlan id $C; ip link set pb.$S.$C up
  done
done
vppctl create sub-interfaces $B $NV dot1q $NV exact-match >/dev/null
vppctl set int ip address $B.$NV 172.31.98.1/30; vppctl set int state $B.$NV up
vppctl show pppoe control-plane binding | tail -n +3 | wc -l | sed 's/^/pppoe mappings: /'
mkdir -p /var/log/accel-ppp-lab
install_conf $LAB/${ACCEL_TEMPLATE:-accel-ppp-lab-phys.conf} /etc/accel-ppp-lab-phys.conf
systemd-run -q --unit=accel-ppp-lab --property=AllowedCPUs=0,14-17 /usr/local/sbin/accel-pppd -c /etc/accel-ppp-lab-phys.conf -p /run/accel-ppp-lab.pid
