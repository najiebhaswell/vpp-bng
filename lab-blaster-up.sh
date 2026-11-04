#!/bin/bash
# BNG Blaster lab: tap900 (access) and tap901 (network) both in netns bngbl for bngblaster; pppoe0 (LCP of tap900)
# and accel in the root netns (CPUs 0,14-15; bngblaster gets 16-17). Optional QinQ:
#   QINQ="100:dot1q:10-59 200:dot1ad:10-59" creates S-VLAN sub-interfaces with one C-VLAN sub-interface each,
#   their LCPs pppoe0.<S>.<C> and the PPPoE DP/CP mappings. Sub-interface ids are S*10000+C.
set -eu
. "$(dirname "$0")/lab-env.sh"
ip netns add bngbl
vppctl create tap id 900 host-if-name vbsub-p host-ns bngbl
vppctl create tap id 901 host-if-name vbsrv-p host-ns bngbl
for i in lo vbsub-p vbsrv-p; do ip netns exec bngbl ip link set $i up; done
# bngblaster owns 172.31.99.2 on vbsrv-p, the kernel must not answer for it
ip netns exec bngbl sysctl -qw net.ipv6.conf.all.disable_ipv6=1
vppctl set int state tap900 up; vppctl set int ip address tap901 172.31.99.1/30; vppctl set int state tap901 up
[ -e /run/netns/rootns ] || ip netns attach rootns 1
vppctl lcp create tap900 host-if pppoe0 netns rootns
ip link set pppoe0 up
cp_of() { vppctl show lcp | awk -v p="$1" '$3==p{print $4}'; }
vppctl create pppoe map dp tap900 cp $(cp_of tap900)
for q in ${QINQ:-}; do
  IFS=: read S T R <<< "$q"; C1=${R%-*}; C2=${R#*-}
  vppctl create sub-interfaces tap900 $S $T $S exact-match >/dev/null
  vppctl set int state tap900.$S up
  vppctl lcp create tap900.$S host-if pppoe0.$S netns rootns
  ip link set pppoe0.$S up
  for C in $(seq $C1 $C2); do
    ID=$((S * 10000 + C))
    vppctl create sub-interfaces tap900 $ID $T $S inner-dot1q $C exact-match >/dev/null
    vppctl set int state tap900.$ID up
    vppctl lcp create tap900.$ID host-if pppoe0.$S.$C netns rootns
    ip link set pppoe0.$S.$C up
    vppctl create pppoe map dp tap900.$ID cp $(cp_of tap900.$ID)
  done
done
vppctl show pppoe control-plane binding | tail -n +3 | wc -l | sed 's/^/pppoe mappings: /'
mkdir -p /var/log/accel-ppp-lab
install_conf $LAB/accel-ppp-lab-radius.conf /etc/accel-ppp-lab-radius.conf
systemd-run -q --unit=accel-ppp-lab --property=AllowedCPUs=${ACCEL_CPUS:-0,14-15} /usr/local/sbin/accel-pppd -c /etc/accel-ppp-lab-radius.conf -p /run/accel-ppp-lab.pid
