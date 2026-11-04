#!/bin/bash
# RADIUS test of the BNG lab (lab-up.sh with ACCEL_CONF=/etc/accel-ppp-lab-radius.conf), run from the machine that
# reaches both hosts: router steps via radius-steps.sh, CoA/DM from the RADIUS host via its coa.sh.
# Output: captures/<run>/test.log here; radius.pcap and accel logs in captures/<run> on the router.
. "$(dirname "$0")/lab-env.sh"
RUN=radius-$(date +%Y%m%d-%H%M%S); U=$SUB_USER; P=$SUB_PASS
OUT=$LAB/captures/$RUN; mkdir -p $OUT
exec > >(tee $OUT/test.log) 2>&1
sec() { echo; echo "################ $* ($(date +%T))"; }
br() { ssh $BR "sudo RUN=$RUN bash $BR_DIR/radius-steps.sh $*"; }
rad() { echo "rad\$ $*"; ssh $RAD "$*" 2>&1 | mask; echo; }
coa() { rad "cd $COA_DIR && ./coa.sh $*"; }
# last <n> accounting records of user <u> in the newest radacct detail file
detail() {
  rad "sudo awk 'BEGIN{RS=\"\"} /User-Name = \"$1\"/ {r[++n]=\$0} END{for(i=(n>$2?n-$2+1:1);i<=n;i++) print r[i] \"\\n\"}' \$(sudo sh -c 'ls -t $COA_DIR/logs/radacct/*/detail-*' | head -1) | grep -E '^[A-Z][a-z]{2} |User-Name|Acct-Status-Type|Acct-Session-Time|Octets|Terminate-Cause|NAS-Identifier|Framed-IP'"
}

br start
sec "0. Environment"; br env
sec "1. RADIUS reachable from the router's root netns (radtest)"; br radtest

sec "2. PAP login ${U}2, rate from Mikrotik-Rate-Limit"
br mark; br login ${U}2 $P; br show; br traffic 6; br radshow

sec "3. Interim accounting with octets from VPP counters"
br mark; br acctwait 2; br radshow

sec "4. CoA from the RADIUS server: Mikrotik-Rate-Limit 5M/5M"
br mark; coa coa ${U}2 "'Mikrotik-Rate-Limit = \"5M/5M\"'"; br pol; br traffic 5; br radshow

sec "5. CoA Mikrotik-Rate-Limit 1G/1G (unit suffix check)"
coa coa ${U}2 "'Mikrotik-Rate-Limit = \"1G/1G\"'"; br pol

sec "6. Disconnect-Request from the RADIUS server"
br mark; coa disconnect ${U}2; br waitgone 10; br state; br radshow

sec "7. Accounting records stored on the RADIUS server (${U}2)"; detail ${U}2 4

sec "8. Framed-IP-Address from RADIUS (${U}1)"
br mark; br login ${U}1 $P; br ip 100.64.200.1; br logout; br waitgone 10; br radshow

sec "9. Wrong password (Access-Reject)"
br mark; br login ${U}4 wrong-password; br state; br radshow; br pppdlog 6

sec "10. CHAP-MD5 (${U}5) and MS-CHAPv2 (${U}6)"
br mark; br login ${U}5 $P refuse-pap refuse-eap refuse-mschap refuse-mschap-v2; br pppdlog 7; br logout
br login ${U}6 $P refuse-pap refuse-eap refuse-chap refuse-mschap; br pppdlog 7; br logout; br waitgone 10; br radshow

sec "11. Session-Timeout 120 from RADIUS (${U}3)"
br mark; br login ${U}3 $P; br show; br waitgone 150; br state; br radshow; br pppdlog 4
detail ${U}3 2

sec "12. Idle-Timeout 60 from RADIUS (${U}4): busy for 130 s, then idle"
br mark; br login ${U}4 $P; br pingbg 130; br pingwait 150; br waitgone 150; br state; br radshow
detail ${U}4 1

sec "13. Router state after test"; br final
echo "run $RUN done"
