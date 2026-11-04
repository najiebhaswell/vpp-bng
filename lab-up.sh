#!/bin/bash
# Temporary PPPoE lab with VPP taps: bngsub ns (pppd) --tap900-- VPP --tap901-- bngsrv ns (iperf3)
set -eu
. "$(dirname "$0")/lab-env.sh"
ip netns add bngsub; ip netns add bngsrv
vppctl create tap id 900 host-if-name vbsub-p host-ns bngsub
vppctl create tap id 901 host-if-name vbsrv-p host-ns bngsrv host-ip4-addr 172.31.99.2/30 host-ip4-gw 172.31.99.1
ip netns exec bngsub ip link set lo up; ip netns exec bngsub ip link set vbsub-p up
ip netns exec bngsrv ip link set lo up; ip netns exec bngsrv ip link set vbsrv-p up
vppctl set int state tap900 up; vppctl set int ip address tap901 172.31.99.1/30; vppctl set int state tap901 up
# pppoe0 lives in the root netns so accel-pppd (PPPoE + RADIUS/CoA over eno1) runs there; BIRD stays in dataplane
[ -e /run/netns/rootns ] || ip netns attach rootns 1
vppctl lcp create tap900 host-if pppoe0 netns rootns
modprobe pppoe; modprobe ppp_generic
ip link set pppoe0 up
CP=$(vppctl show lcp | awk '$3=="tap900"{print $4}')
vppctl create pppoe map dp tap900 cp $CP
vppctl show pppoe control-plane binding
mkdir -p /var/log/accel-ppp-lab
printf 'bngtest * test123 *\n' > /etc/accel-ppp-lab.chap-secrets; chmod 600 /etc/accel-ppp-lab.chap-secrets
cp $LAB/accel-ppp-lab.conf /etc/accel-ppp-lab.conf
install_conf $LAB/accel-ppp-lab-radius.conf /etc/accel-ppp-lab-radius.conf
systemd-run -q --unit=accel-ppp-lab --property=AllowedCPUs=0,14-17 /usr/local/sbin/accel-pppd -c ${ACCEL_CONF:-/etc/accel-ppp-lab.conf} -p /run/accel-ppp-lab.pid
