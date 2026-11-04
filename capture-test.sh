#!/bin/bash
# Full test run with every command and its output logged, plus client-side pcaps. Assumes lab-up.sh ran.
# Output: captures/<timestamp>/{test.log,login.pcap,teardown.pcap,...}
. "$(dirname "$0")/lab-env.sh"
TS=$(date +%Y%m%d-%H%M%S); OUT=$LAB/captures/$TS; mkdir -p $OUT
S="ip netns exec bngsub"; D="ip netns exec bngsrv"; DP="ip netns exec dataplane"; CONF=/etc/accel-ppp-lab.conf
exec > >(tee $OUT/test.log) 2>&1
sec() { echo; echo "################ $* ($(date +%T))"; }
run() { echo "\$ $*"; eval "$@"; echo; }
pppd_up() {
  $S pppd plugin pppoe.so nic-vbsub-p user bngtest password test123 noauth noipdefault defaultroute mtu 1492 mru 1492 \
    lcp-echo-interval 0 logfile /var/log/accel-ppp-lab/pppd.log persist maxfail 0 >/dev/null 2>&1
  for i in $(seq 1 20); do $S ip -br addr show ppp0 2>/dev/null | grep -q 100.64 && return 0; sleep 1; done; return 1
}
accel_restart() {
  pkill -x pppd; sleep 1; systemctl stop accel-ppp-lab 2>/dev/null; systemctl reset-failed accel-ppp-lab 2>/dev/null; sleep 1
  if [ "$1" = none ]; then sed -i 's/^rate-limit=.*/#rate-limit=none/' $CONF; else sed -i "s|^#\?rate-limit=.*|rate-limit=$1|" $CONF; fi
  systemd-run -q --unit=accel-ppp-lab --property=AllowedCPUs=0,14-17 /usr/local/sbin/accel-pppd -c $CONF -p /run/accel-ppp-lab.pid
  sleep 2
}
iperf_pair() {
  pkill -x iperf3; sleep 0.3; $D iperf3 -s -D; sleep 1; $S ping -c2 -W2 172.31.99.2 >/dev/null
  run "timeout 25 $S iperf3 -c 172.31.99.2 -t 8 -f m"
  sleep 1
  run "timeout 25 $S iperf3 -c 172.31.99.2 -R -t 8 -f m"
  pkill -x iperf3
}

sec "0. Environment"
run "hostname; date -R; uname -r"
run "dpkg-query -W -f='\${Package} \${Version}\n' vpp vpp-plugin-core vpp-plugin-dpdk"
run "vppctl show version"
run "git -C $LAB/vpp log --oneline 5db7b9abb..HEAD"
run "git -C $LAB/accel-ppp-ng log --oneline -3"
run "grep -v '^\s*\$' $CONF"

sec "1. Router state before test"
run "$DP birdc show protocols"
run "vppctl show int addr"
run "vppctl show lcp"

sec "2. Lab topology"
run "vppctl show int tap900 tap901"
run "vppctl show pppoe control-plane binding"
run "$S ip -br link; $D ip -br addr"

sec "3. PPPoE login (limit 20M/20M, pcap login.pcap)"
accel_restart 20000/20000
$S tcpdump -i vbsub-p -nn -s 0 -U -w $OUT/login.pcap 'not (tcp port 5201)' 2>/dev/null & TD=$!; sleep 1
run "pppd_up && echo login OK || echo login FAILED"
run "$S ip addr show ppp0; $S ip route"
run "tail -25 /var/log/accel-ppp-lab/pppd.log"
run "accel-cmd -p 2001 show sessions"
run "grep -E 'bngtest|ppp0|pppoe' /var/log/accel-ppp-lab/accel-ppp.log | tail -20"
run "vppctl show pppoe session"
run "vppctl show ip fib 100.64.0.2/32"
run "vppctl show policer"
run "vppctl show int features pppoe_session0 | grep -E -A3 '^(ip4-unicast|ip4-output|ip4-multicast|ip6-unicast|ip6-output):'"

sec "4. Connectivity through VPP"
run "$S ping -c4 -i0.3 -W2 172.31.99.2"
[ -z "${EXT_PING:-}" ] || run "$S ping -c4 -i0.3 -W2 $EXT_PING"
run "$S ping -c2 -M do -s 1464 -W2 172.31.99.2"
run "$S ping -c2 -M do -s 1465 -W2 172.31.99.2"
sleep 1; kill $TD; wait $TD 2>/dev/null
run "$S tcpdump -nn -r $OUT/login.pcap 2>/dev/null | head -60"

sec "5. Rate limit 20M/20M (download/upload, kbps)"
run "vppctl clear policer counters 2>/dev/null; true"
iperf_pair
run "vppctl show policer"

for R in 100000/100000 none; do
  sec "6. Rate limit $R"
  accel_restart $R; run "pppd_up && echo login OK || echo login FAILED"
  run "vppctl show policer | grep -E '^Name|cir|eir|cb |eb '"
  iperf_pair
done

sec "7. Teardown (PADT, pcap teardown.pcap)"
accel_restart 100000/100000; pppd_up
$S tcpdump -i vbsub-p -nn -s 0 -U -w $OUT/teardown.pcap 2>/dev/null & TD=$!; sleep 1
run "vppctl show pppoe session; vppctl show policer | grep -c '^Name'"
run "pkill -x pppd; sleep 3"
kill $TD; wait $TD 2>/dev/null
run "$S tcpdump -nn -r $OUT/teardown.pcap 2>/dev/null"
run "vppctl show pppoe session"
run "vppctl show policer; vppctl show ip fib 100.64.0.2/32 | head -4"
run "tail -8 /var/log/accel-ppp-lab/accel-ppp.log"

sec "8. Stale mapping cleanup (VPP patch 0009)"
run "vppctl create tap id 950; vppctl set int state tap950 up"
run "vppctl create pppoe map dp tap950 cp tap901"
run "vppctl show pppoe control-plane binding"
run "vppctl delete tap tap950"
run "vppctl show pppoe control-plane binding"

sec "9. Router state after test"
run "$DP birdc show protocols"
run "vppctl show int addr | grep -c L3; vppctl show lcp | grep -c itf-pair"
run "systemctl is-active vpp bird clixon-vppcfg accel-ppp-lab"

cp /var/log/accel-ppp-lab/accel-ppp.log /var/log/accel-ppp-lab/pppd.log $OUT/ 2>/dev/null
chown -R ${SUDO_USER:-root}: $OUT; echo "captured to $OUT"
