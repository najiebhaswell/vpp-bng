#!/usr/bin/env python3
# BNG Blaster config for N:1 S/C VLAN pairs, from a base profile (its first access entry):
#   qinq-n1.py <base.json> <sessions> <rate> "<S-VLAN[-range]:dot1q|dot1ad:C-VLAN range> ..."
# One N:1 access entry per S/C pair, as lab-phys-up.sh creates them with the same QINQ; BNG Blaster spreads the
# sessions round-robin over them. Session group 1/2 alternates per entry, so every second session is in group 2.
import json
import sys

c = json.load(open(sys.argv[1]))
n, rate = int(sys.argv[2]), int(sys.argv[3])
base = c["interfaces"]["access"][0]
access = []
for q in sys.argv[4].split():
    sr, t, cr = q.split(":")
    s1, _, s2 = sr.partition("-")
    c1, _, c2 = cr.partition("-")
    for s in range(int(s1), int(s2 or s1) + 1):
        for cv in range(int(c1), int(c2 or c1) + 1):
            a = {k: v for k, v in base.items() if not k.endswith("-vlan-min") and not k.endswith("-vlan-max")}
            a.update({"vlan-mode": "N:1", "outer-vlan": s, "inner-vlan": cv, "qinq": t == "dot1ad",
                      "stream-group-id": 1, "session-group-id": len(access) % 2 + 1})
            access.append(a)
c["interfaces"]["access"] = access
c["sessions"].update({"count": n, "start-rate": rate, "stop-rate": rate, "max-outstanding": max(1600, 4 * rate)})
c["pppoe"]["reconnect"] = True
print(json.dumps(c, indent=4))
