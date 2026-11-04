#!/bin/bash
# Router side of the RADIUS test, one step per call: radius-steps.sh <step> [args]. Called by radius-test-run.sh.
. "$(dirname "$0")/lab-env.sh"
OUT=$LAB/captures/${RUN:?}; mkdir -p $OUT
S="ip netns exec bngsub"; D="ip netns exec bngsrv"; PCAP=${PCAP:-$OUT/radius.pcap}
run() { echo "\$ $*"; eval "$@"; echo; }
ses() { accel-cmd -p 2001 show sessions ifname,username,ip,rate-limit,rx-bytes,tx-bytes,uptime; }
# decoded RADIUS packets captured after the last "mark"
radshow() {
  tcpdump -nn -vv -r $PCAP 2>/dev/null | awk -v skip=$(cat $OUT/mark 2>/dev/null || echo 0) '
    /^[0-9]/ { n++; ts = substr($1, 1, 8); next }
    n <= skip { next }
    / > [0-9a-f.:]+: / { hdr = ts " " $1 " > " $3; sub(/:$/, "", hdr); next }
    /(Request|Accept|Reject|Response|ACK|NAK) \(/ { sub(/^[ \t]+/, ""); sub(/, Authenticator.*/, ""); print hdr "  " $0; next }
    /User-Name|Framed-IP|Vendor Attribute|Session-Timeout|Idle-Timeout|Acct-Interim|Acct-Status|Octets|Session-Time|Terminate|Error-Cause|Reply-Message/ {
      sub(/^[ \t]+/, ""); sub(/ Attribute \([0-9]+\), length: [0-9]+, Value:/, ":"); print "        " $0 }'
}
login() {
  local u=$1 p=$2; shift 2
  $S pppd plugin pppoe.so nic-vbsub-p user $u password $p noauth noipdefault defaultroute mtu 1492 mru 1492 \
    lcp-echo-interval 0 logfile /var/log/accel-ppp-lab/pppd.log "$@" >/dev/null 2>&1
  for i in $(seq 1 15); do
    $S ip -br addr show ppp0 2>/dev/null | grep -q 100.64 && { echo "login $u OK"; return 0; }
    pgrep -x pppd >/dev/null || break; sleep 1
  done
  echo "login $u FAILED"; return 1
}
# pppd_login = pppd plugin pppoe.so nic-vbsub-p user <u> password <p> ... (client in netns bngsub, no persist)
step=$1; shift
case $step in
start)
  : > $OUT/mark; pkill -x pppd; sleep 1
  nohup tcpdump -i eno1 -nn -s0 -U -w $PCAP 'udp and (port 1812 or port 1813 or port 3799)' >/dev/null 2>&1 & echo $! > $OUT/tcpdump.pid
  sleep 1 ;;
accelrestart)
  pkill -x pppd; systemctl stop accel-ppp-lab; systemctl reset-failed accel-ppp-lab 2>/dev/null; sleep 1
  systemd-run -q --unit=accel-ppp-lab --property=AllowedCPUs=0,14-17 /usr/local/sbin/accel-pppd -c /etc/accel-ppp-lab-radius.conf -p /run/accel-ppp-lab.pid
  sleep 2 ;;
env)
  run "hostname; date -R"
  run "dpkg-query -W -f='\${Package} \${Version}\n' vpp"
  run "git -C $LAB/accel-ppp-ng log --oneline -5"
  run "grep -A12 '^\[radius\]' /etc/accel-ppp-lab-radius.conf | mask"
  run "grep -E '^(interface|vendor|attr)=' /etc/accel-ppp-lab-radius.conf"
  run "vppctl show lcp | grep pppoe0"
  run "ps -o pid,cmd -C accel-pppd; readlink /proc/\$(pgrep -x accel-pppd)/ns/net /proc/self/ns/net"
  run "ss -lunp | grep 3799" ;;
radtest)
  run "radtest ${SUB_USER}4 $SUB_PASS $RADIUS_SERVER 0 \$RADIUS_SECRET | mask"
  run "radtest ${SUB_USER}4 wrong-password $RADIUS_SERVER 0 \$RADIUS_SECRET | mask" ;;
mark) tcpdump -nn -r $PCAP 2>/dev/null | wc -l > $OUT/mark ;;
radshow) sleep 1; run radshow ;;
login) echo "\$ pppd_login $*"; login "$@"; echo ;;
show)
  run "$S ip -br addr show ppp0"
  run ses
  run "vppctl show pppoe session"
  run "vppctl show policer | grep -E '^Name'" ;;
pol) run ses; run "vppctl show policer | grep -E '^Name|^cir'" ;;
ip)
  run "$S ip addr show ppp0"
  run "vppctl show ip fib $1/32 | head -9"
  run "$S ping -c3 -i0.3 -W2 172.31.99.2" ;;
traffic)
  pkill -x iperf3; sleep 0.3; $D iperf3 -s -D; sleep 1
  run "$S iperf3 -c 172.31.99.2 -t ${1:-6} -f m | grep -E 'sender|receiver'"
  run "$S iperf3 -c 172.31.99.2 -R -t ${1:-6} -f m | grep -E 'sender|receiver'"
  pkill -x iperf3 ;;
acctwait)
  echo "\$ # wait for $1 Interim-Update after the mark"
  timeout 150 bash -c "until [ \$(bash $0 radshow | grep -c Interim-Update) -ge $1 ]; do sleep 2; done"
  run ses
  run "vppctl show int pppoe_session0" ;;
pingbg)
  echo "\$ $S ping -i 0.5 -w $1 -q 172.31.99.2 &   # keeps the session busy for $1 s"
  nohup $S ping -i 0.5 -w $1 -q 172.31.99.2 > $OUT/pingbg.log 2>&1 &
  echo ;;
pingwait)
  echo "\$ # wait for the background ping to finish"
  timeout $(( ${1:-150} )) bash -c "while pgrep -x ping >/dev/null; do sleep 2; done"
  run "tail -2 $OUT/pingbg.log"
  run ses ;;
logout) run "pkill -x pppd; sleep 3" ;;
waitgone)
  echo "\$ # wait until the session is gone (max ${1:-20}s)"
  timeout ${1:-20} bash -c "until ! vppctl show pppoe session | grep -q sw-if-index; do sleep 1; done"; date +%T; echo ;;
state)
  run ses
  run "vppctl show pppoe session"
  run "vppctl show policer | grep -c '^Name'"
  run "pgrep -x pppd || echo 'pppd exited'" ;;
pppdlog) run "tail -${1:-8} /var/log/accel-ppp-lab/pppd.log" ;;
final)
  run "ip netns exec dataplane birdc show protocols | awk 'NR>2{print \$1, \$4}' | md5sum"
  run "vppctl show int addr | grep -c L3; vppctl show lcp | grep -c itf-pair"
  run "systemctl is-active vpp bird clixon-vppcfg accel-ppp-lab"
  kill $(cat $OUT/tcpdump.pid) 2>/dev/null; sleep 1
  cp /var/log/accel-ppp-lab/accel-ppp.log /var/log/accel-ppp-lab/pppd.log $OUT/
  chown -R ${SUDO_USER:-root}: $OUT ;;
esac
