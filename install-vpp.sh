#!/bin/bash
# Installs the VPP debs of one build (e.g. 26.10.0-13~gcc25d3db9), holds them and restarts VPP.
# Tears the lab down first; prints router state (BIRD protocols, L3 addresses, LCP pairs) before and after.
V=${1:?version}; LAB=$(cd "$(dirname "$0")" && pwd); D=$LAB/vpp/build-root
# routers managed by clixon-vppcfg: a VPP restart must not happen with uncommitted edits pending
if [ -e /var/lib/clixon-vppcfg/running_db ]; then
  cmp -s /var/lib/clixon-vppcfg/candidate_db /var/lib/clixon-vppcfg/running_db && echo candidate-clean || { echo CANDIDATE-DIFFERS; exit 1; }
fi
bash $LAB/lab-down.sh >/dev/null 2>&1
st() { echo "bird=$(ip netns exec dataplane birdc show protocols | awk 'NR>2{print $1, $4}' | sort | md5sum | cut -c1-8) l3=$(vppctl show int addr | grep -c L3) lcp=$(vppctl show lcp | grep -c itf-pair)"; }
echo "before: $(st)"
P="vpp vpp-plugin-core vpp-plugin-dpdk vpp-crypto-engines vpp-drivers vpp-dev libvppinfra libvppinfra-dev python3-vpp-api"
apt-mark unhold $P >/dev/null
(cd $D && dpkg -i --force-confold $(for p in $P; do echo ${p}_${V}_amd64.deb; done) >/tmp/dpkg-bng.log 2>&1); echo "dpkg_rc=$?"
apt-mark hold $P >/dev/null
systemctl restart vpp; for i in $(seq 1 45); do vppctl show version >/dev/null 2>&1 && break; sleep 1; done; sleep 15
echo "after:  $(st)"
dpkg-query -W -f='${Version}\n' vpp; systemctl is-active vpp bird clixon-vppcfg
