#!/usr/bin/env python3
# PPPoE throughput through the BNG with TRex: one upstream (PPPoE session) and one downstream (plain IPv4 on the
# network VLAN) stream per session, sessions spread over both ports. Runs on the TRex host, prints one JSON line
# per size.
#   pppoe-trex.py <sessions.json> <ip-size>[,<ip-size>|imix...] <up|down|bi> <mult per port> [window-seconds]
# sessions.json: {"bng-mac": ..., "access-vlan": 300, "network-vlan": 301, "network-ip": "172.31.98.2",
#                 "sessions": [{"mac": ..., "sid": <pppoe session id>, "ip": ...}, ...]}
# With access-port/network-port, <mult> may be <downstream mult>/<upstream mult>. REFLECT=1: the network port is
# a reflector, not TRex (see trex-run.sh); FLOWS=<n>: n UDP source ports per session; DSTNET=<prefix>: upstream
# destinations at random in that prefix.
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


def ip_int(a):
    return int.from_bytes(bytes(int(x) for x in a.split(".")), "big")


def lockstep(fields, ip_offset):
    # one value list per field, all as long as the session list and stepped together: packet n belongs to session n,
    # so a single stream gives every session the same rate (thousands of streams take TRex minutes to load)
    insts = []
    for name, size, offset, values in fields:
        insts += [STLVmFlowVar(name=name, size=size, op="inc", value_list=values),
                  STLVmWrFlowVar(fv_name=name, pkt_offset=offset)]
    # FLOWS=<n>: n source ports per session, so a NAT on the way holds sessions x n translations instead of a new
    # one for nearly every packet
    flows = int(os.environ.get("FLOWS", 0))
    insts += [STLVmFlowVar(name="sp", min_value=1024, max_value=1023 + flows if flows else 65000, size=2, op="random"),
              STLVmWrFlowVar(fv_name="sp", pkt_offset=ip_offset + 20)]
    # DSTNET=<a.b.c.d/len>: destinations at random in that prefix (upstream only), as many as real traffic has
    if os.environ.get("DSTNET") and ip_offset != 18:
        net, plen = os.environ["DSTNET"].split("/")
        lo = ip_int(net) & ~((1 << (32 - int(plen))) - 1) & 0xffffffff
        insts += [STLVmFlowVar(name="dip", min_value=lo + 1, max_value=lo + (1 << (32 - int(plen))) - 2, size=4,
                               op="random"),
                  STLVmWrFlowVar(fv_name="dip", pkt_offset=ip_offset + 16)]
    insts += [STLVmFixIpv4(offset=ip_offset)]
    return STLScVmRaw(insts)


def size_mix(size):
    # "1400", "imix" (46/576/1400 at 7:4:1) or "<len>x<weight>+..." such as "64x3+1400x7": [(ip length, share)]
    if size == "imix":
        size = "46x7+576x4+1400x1"
    parts = [p.split("x") for p in size.split("+")]
    mix = [(int(p[0]), float(p[1]) if len(p) > 1 else 1.0) for p in parts]
    total = sum(w for _, w in mix)
    return [(ln, w / total) for ln, w in mix]


def mean_len(size):
    return sum(ln * w for ln, w in size_mix(size))


def upstream_split(group, ip_len, share=1.0):
    # sessions with "vlans": [[tpid, vid], ...] (outer first), all with the same number of tags
    n = len(group[0]["vlans"])
    pkt = Ether(src=group[0]["mac"], dst=cfg["bng-mac"])
    for _ in range(n):
        pkt = pkt / Dot1Q()
    pkt = pkt / PPPoE(sessionid=1) / PPP(proto=0x0021) / IP(src="0.0.0.0", dst=cfg["network-ip"]) / \
        UDP(sport=1024, dport=5001, chksum=0)
    mac = [int(s["mac"].replace(":", ""), 16) for s in group]
    fields = [("mh", 2, 6, [m >> 32 for m in mac]), ("ml", 4, 8, [m & 0xffffffff for m in mac])]
    for t in range(n):
        fields += [(f"tp{t}", 2, 12 + 4 * t, [s["vlans"][t][0] for s in group]),
                   (f"vid{t}", 2, 14 + 4 * t, [s["vlans"][t][1] for s in group])]
    fields += [("sid", 2, 16 + 4 * n, [s["sid"] for s in group]),
               ("src", 4, 34 + 4 * n, [ip_int(s["ip"]) for s in group])]
    return STLStream(packet=STLPktBuilder(pkt=pad(pkt, ip_len), vm=lockstep(fields, 22 + 4 * n)),
                     mode=STLTXCont(pps=len(group) * share))


def downstream_split(sessions, ip_len, share=1.0):
    pkt = (Ether(dst=cfg["network-mac"]) / Dot1Q(vlan=cfg["network-vlan"]) /
           IP(src=cfg["network-ip"], dst="0.0.0.0") / UDP(sport=1024, dport=5002, chksum=0))
    fields = [("dst", 4, 34, [ip_int(s["ip"]) for s in sessions])]
    return STLStream(packet=STLPktBuilder(pkt=pad(pkt, ip_len), vm=lockstep(fields, 18)),
                     mode=STLTXCont(pps=len(sessions) * share))


# "access-port"/"network-port" in sessions.json: subscribers on one port, network on the other, one stream per
# direction (per tag depth upstream). Without: per-session streams spread over both ports of a static bond.
SPLIT = "access-port" in cfg
CHUNK = 8000


def split_streams(size):
    acc, net = cfg["access-port"], cfg["network-port"]
    streams = {acc: [], net: []}
    if MODE in ("up", "bi"):
        depth = {}
        for s in cfg["sessions"]:
            depth.setdefault(len(s["vlans"]), []).append(s)
        # one stream per CHUNK sessions: a value list per field of every session in one request is too large for
        # TRex beyond ~10k sessions
        # one stream per packet length of the mix, its rate share of the packets
        streams[acc] = [upstream_split(g[i:i + CHUNK], ln, w) for ln, w in size_mix(size) for g in depth.values()
                        for i in range(0, len(g), CHUNK)]
    if MODE in ("down", "bi"):
        streams[net] = [downstream_split(cfg["sessions"][i:i + CHUNK], ln, w) for ln, w in size_mix(size)
                        for i in range(0, len(cfg["sessions"]), CHUNK)]
    return streams


# with REFLECT the network port is a dummy in the TRex config
PORTS = [cfg["access-port"]] if os.environ.get("REFLECT") else [0, 1]
c = STLClient(server="127.0.0.1")
c.connect()
c.reset(ports=PORTS)
c.set_service_mode(ports=PORTS, enabled=False)
c.set_port_attr(ports=PORTS, promiscuous=True)
for size in SIZES:
    c.reset(ports=PORTS)
    c.set_port_attr(ports=PORTS, promiscuous=True)
    streams = {0: [], 1: []}
    if SPLIT:
        streams = split_streams(size)
    for i, s in enumerate([] if SPLIT else cfg["sessions"]):
        ip_len = IMIX[i % len(IMIX)] if size == "imix" else int(size)
        if MODE in ("up", "bi"):
            streams[i % 2].append(upstream(s, ip_len))
        if MODE in ("down", "bi"):
            streams[(i + 1) % 2].append(downstream(s, ip_len))
    for p in PORTS:
        for st in streams[p]:
            c.add_streams(st, ports=[p])
    tx_ports = [p for p in PORTS if streams[p]]
    c.clear_stats()
    if SPLIT and "/" in MULT:
        # <downstream mult>/<upstream mult>
        down, up = MULT.split("/")
        for p, m in ((cfg["network-port"], down), (cfg["access-port"], up)):
            if streams[p]:
                c.start(ports=[p], mult=m, force=True)
    else:
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
    for p in PORTS:
        dp = b[p]["opackets"] - a[p]["opackets"]; dr = b[p]["ipackets"] - a[p]["ipackets"]
        tx += dp; rx += dr; txb += (b[p]["obytes"] - a[p]["obytes"]) * 8 + dp * 160
        r[f"tx{p}_mpps"] = round(dp / dt / 1e6, 3)
        r[f"rx{p}_mpps"] = round(dr / dt / 1e6, 3)
    r["offered_mpps"] = round(tx / dt / 1e6, 3)
    r["offered_gbps_l1"] = round(txb / dt / 1e9, 2)
    r["received_mpps"] = round(rx / dt / 1e6, 3)
    r["loss_pct"] = round(100.0 * (tx - rx) / tx, 3) if tx else None
    if SPLIT:
        acc, net = cfg["access-port"], cfg["network-port"]
        for d, src, dst in (("up", acc, net), ("down", net, acc)):
            if src not in PORTS or dst not in PORTS:
                continue
            t = b[src]["opackets"] - a[src]["opackets"]; rcv = b[dst]["ipackets"] - a[dst]["ipackets"]
            if t:
                r[f"{d}_loss_pct"] = round(100.0 * (t - rcv) / t, 3)
                r[f"{d}_mbps_per_session"] = round(rcv * (mean_len(size) * 8) / dt / 1e6 / len(cfg["sessions"]), 2)
        if os.environ.get("REFLECT"):
            # the network side reflects every packet: what comes back to the access port went up and down
            t = b[acc]["opackets"] - a[acc]["opackets"]; rcv = b[acc]["ipackets"] - a[acc]["ipackets"]
            if t:
                r["reflected_mpps"] = round(rcv / dt / 1e6, 3)
                r["reflected_loss_pct"] = round(100.0 * (t - rcv) / t, 3)
    print(json.dumps(r), flush=True)
c.disconnect()
