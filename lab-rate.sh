#!/bin/bash
# Usage: lab-rate.sh <down/up kbps | none>. Restarts accel with that limit and measures both directions.
RATE=$1; S="ip netns exec bngsub"; D="ip netns exec bngsrv"
pkill -x pppd; sleep 1; systemctl stop accel-ppp-lab 2>/dev/null; systemctl reset-failed accel-ppp-lab 2>/dev/null; sleep 1
if [ "$RATE" = none ]; then sed -i 's/^rate-limit=.*/#rate-limit=none/' /etc/accel-ppp-lab.conf; else sed -i "s|^#\?rate-limit=.*|rate-limit=$RATE|" /etc/accel-ppp-lab.conf; fi
systemd-run -q --unit=accel-ppp-lab --property=AllowedCPUs=0,14-17 /usr/local/sbin/accel-pppd -c /etc/accel-ppp-lab.conf -p /run/accel-ppp-lab.pid; sleep 2
$S pppd plugin pppoe.so nic-vbsub-p user bngtest password test123 noauth noipdefault defaultroute mtu 1492 mru 1492 lcp-echo-interval 0 logfile /var/log/accel-ppp-lab/pppd.log persist maxfail 0 >/dev/null 2>&1
for i in $(seq 1 20); do $S ip -br addr show ppp0 2>/dev/null | grep -q 100.64 && break; sleep 1; done
echo "=== rate $RATE: $($S ip -br addr show ppp0 | awk '{print $3}')"
pkill -x iperf3; sleep 0.3; $D iperf3 -s -D; sleep 1
$S ping -c2 -W2 172.31.99.2 >/dev/null
echo "upload:   $(timeout 20 $S iperf3 -c 172.31.99.2 -t 6 -f m 2>&1 | grep receiver | awk '{print $7,$8}')"
sleep 1
echo "download: $(timeout 20 $S iperf3 -c 172.31.99.2 -R -t 6 -f m 2>&1 | grep -E ' sender' | awk '{print $7,$8}') / rcv $(timeout 1 true)"
vppctl show policer | grep -E '^Name|conform [0-9]|exceed [0-9]|violate [0-9]' | cut -c1-70
vppctl show int features pppoe_session0 2>/dev/null | grep -E -A2 '^(ip4-unicast|ip4-output|ip6-unicast|ip4-multicast):' | grep -v '^--' | cut -c1-50
pkill -x iperf3
