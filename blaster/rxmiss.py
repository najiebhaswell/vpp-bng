#!/usr/bin/env python3
# rx-miss of VPP's physical ports (no sub-interfaces, taps or sessions), summed over threads, from the stats
# segment: no worker barrier, unlike "vppctl show hardware". Prints one number.
from vpp_papi.vpp_stats import VPPStats

s = VPPStats("/run/vpp/stats.sock")
s.connect()
names, miss = s["/if/names"], s["/if/rx-miss"]
phys = [i for i, n in enumerate(names)
        if n and "." not in n and not n.startswith(("pppoe", "tap", "local", "loop", "Bond"))]
print(sum(t[i] for t in miss for i in phys))
