#!/usr/bin/env python3
# PPPoE throughput through the BNG with TRex: one upstream (PPPoE session) and one downstream (plain IPv4 on the
# network VLAN) stream per session, sessions spread over both ports. Runs on the TRex host, prints one JSON line
# per size.
#   pppoe-trex.py <sessions.json> <ip-size>[,<ip-size>|imix...] <up|down|bi> <mult per port> [window-seconds]
# sessions.json: {"bng-mac": ..., "access-vlan": 300, "network-vlan": 301, "network-ip": "172.31.98.2",
#                 "sessions": [{"mac": ..., "sid": <pppoe session id>, "ip": ...}, ...]}
# Sizes are IPv4 packet lengths; imix gives sessions 46/576/1400 byte packets in a 7:4:1 ratio.
import json
import os
import sys
import time

sys.path.insert(0, os.environ.get("TREX_SHIM", "/home/well/vpp-test/py313-shim"))
sys.path.insert(0, os.environ.get("TREX_API", "/opt/trex/v3.08/automation/trex_control_plane/interactive"))
from trex.stl.api import *  # noqa: E402,F403
from scapy.layers.ppp import PPP, PPPoE  # noqa: E402

cfg = json.load(open(sys.argv[1]))
SIZES = sys.argv[2].split(",")
MODE = sys.argv[3]
MULT = sys.argv[4]
WINDOW = int(sys.argv[5]) if len(sys.argv) > 5 else 10
WARMUP = 5
IMIX = [46] * 7 + [576] * 4 + [1400]


def udp_vm(pkt_offset):
    # vary the UDP source port so the router's RSS spreads the downstream flows
    return STLScVmRaw([STLVmFlowVar(name="sp", min_value=1024, max_value=65000, size=2, op="random"),
                       STLVmWrFlowVar(fv_name="sp", pkt_offset=pkt_offset)])


def pad(pkt, ip_len):
    return pkt / (max(0, ip_len - 28) * "x")


def upstream(s, ip_len):
    pkt = (Ether(src=s["mac"], dst=cfg["bng-mac"]) / Dot1Q(vlan=cfg["access-vlan"]) /
           PPPoE(sessionid=s["sid"]) / PPP(proto=0x0021) /
           IP(src=s["ip"], dst=cfg["network-ip"]) / UDP(sport=1024, dport=5001, chksum=0))
    return STLStream(packet=STLPktBuilder(pkt=pad(pkt, ip_len), vm=udp_vm("UDP.sport")), mode=STLTXCont(pps=1))


def downstream(s, ip_len):
    pkt = (Ether(dst=cfg["bng-mac"]) / Dot1Q(vlan=cfg["network-vlan"]) /
           IP(src=cfg["network-ip"], dst=s["ip"]) / UDP(sport=1024, dport=5002, chksum=0))
    return STLStream(packet=STLPktBuilder(pkt=pad(pkt, ip_len), vm=udp_vm("UDP.sport")), mode=STLTXCont(pps=1))


c = STLClient(server="127.0.0.1")
c.connect()
c.reset(ports=[0, 1])
c.set_service_mode(ports=[0, 1], enabled=False)
c.set_port_attr(ports=[0, 1], promiscuous=True)
for size in SIZES:
    c.reset(ports=[0, 1])
    c.set_port_attr(ports=[0, 1], promiscuous=True)
    streams = {0: [], 1: []}
    for i, s in enumerate(cfg["sessions"]):
        ip_len = IMIX[i % len(IMIX)] if size == "imix" else int(size)
        if MODE in ("up", "bi"):
            streams[i % 2].append(upstream(s, ip_len))
        if MODE in ("down", "bi"):
            streams[(i + 1) % 2].append(downstream(s, ip_len))
    for p in (0, 1):
        if streams[p]:
            c.add_streams(streams[p], ports=[p])
    tx_ports = [p for p in (0, 1) if streams[p]]
    c.clear_stats()
    c.start(ports=tx_ports, mult=MULT, force=True)
    time.sleep(WARMUP)
    a = c.get_stats(); ta = time.time()
    time.sleep(WINDOW)
    b = c.get_stats(); tb = time.time()
    c.stop(ports=tx_ports)
    time.sleep(2)
    dt = tb - ta
    r = {"size": size, "mode": MODE, "mult": MULT, "sessions": len(cfg["sessions"])}
    tx = rx = txb = 0
    for p in (0, 1):
        dp = b[p]["opackets"] - a[p]["opackets"]; dr = b[p]["ipackets"] - a[p]["ipackets"]
        tx += dp; rx += dr; txb += (b[p]["obytes"] - a[p]["obytes"]) * 8 + dp * 160
        r[f"tx{p}_mpps"] = round(dp / dt / 1e6, 3)
        r[f"rx{p}_mpps"] = round(dr / dt / 1e6, 3)
    r["offered_mpps"] = round(tx / dt / 1e6, 3)
    r["offered_gbps_l1"] = round(txb / dt / 1e9, 2)
    r["received_mpps"] = round(rx / dt / 1e6, 3)
    r["loss_pct"] = round(100.0 * (tx - rx) / tx, 3) if tx else None
    print(json.dumps(r), flush=True)
c.disconnect()
