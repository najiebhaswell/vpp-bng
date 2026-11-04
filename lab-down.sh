#!/bin/bash
# Removes everything lab-up.sh / lab-blaster-up.sh created (tap and older af_packet variants). Safe to run twice.
pkill -x pppd; pkill -x iperf3; pkill -x bngblaster; sleep 1
systemctl stop accel-ppp-lab 2>/dev/null; systemctl reset-failed accel-ppp-lab 2>/dev/null
# the pppoe plugin keeps DP/CP mappings after interface delete, so remove them first
vppctl show pppoe control-plane binding | awk 'NR>2 && NF==2{print $1, $2}' | while read dp cp; do vppctl create pppoe map dp $dp cp $cp del; done
# QinQ LCPs first (C-VLAN, then S-VLAN), the parent pair last
vppctl show lcp | awk '$3 ~ /^tap900\.[0-9]+$/ {print $3}' | sort -t. -k2,2nr | while read i; do vppctl lcp delete $i; done
for i in tap900 host-vbsub; do vppctl lcp delete $i 2>/dev/null; done
vppctl show int | awk '$1 ~ /^tap900\.[0-9]+$/ {print $1}' | sort -t. -k2,2nr | while read i; do vppctl delete sub-interface $i; done
vppctl delete tap tap900 2>/dev/null; vppctl delete tap tap901 2>/dev/null
vppctl delete host-interface name vbsub 2>/dev/null; vppctl delete host-interface name vbsrv 2>/dev/null
ip link del vbsub 2>/dev/null; ip link del vbsrv 2>/dev/null
ip netns del bngsub 2>/dev/null; ip netns del bngsrv 2>/dev/null; ip netns del bngbl 2>/dev/null
rm -f /etc/accel-ppp-lab.chap-secrets
# only drops the name; the root netns itself stays
ip netns del rootns 2>/dev/null
