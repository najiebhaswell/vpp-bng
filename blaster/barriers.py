#!/usr/bin/env python3
# Worker barriers from a VPP event log ("event-logger trace api barrier", "show event-logger all"):
#   barriers.py <elog.txt> <barriers.txt>
# Writes one line per barrier (time, API message or caller, entry/refork/total µs the workers were held) and prints
# a summary per API message and per 10 s of the log.
import re
import sys

ev = []
for line in open(sys.argv[1]):
    m = re.match(r"\s*([\d.]+): (.*)", line)
    if m:
        ev.append((float(m.group(1)), m.group(2).strip()))
ev.sort()

name, caller, rows = None, {}, []
for t, e in ev:
    if e.startswith("api-msg: "):
        name = e[len("api-msg: "):]
    elif e.startswith("bar-trace-"):
        m = re.match(r"bar-trace-(.*)-#(\d+)", e)
        caller[m.group(2)] = name if m.group(1) == "vl_msg_api_barrier_sync" and name else m.group(1)
    elif e.startswith("bar-rel-"):
        m = re.match(r"bar-rel-#(\d+)-e(\d+)-u(\d+)-t(\d+)", e)
        if m:
            n, en, up, tot = m.groups()
            rows.append((t, caller.get(n, "?"), int(en), int(up), int(tot)))
    elif e.startswith("api-msg-done"):
        name = None

with open(sys.argv[2], "w") as f:
    for r in rows:
        f.write("%.6f %-40s e %6d u %6d t %6d\n" % r)
if not rows:
    sys.exit("no barriers in the log")

per = {}
for _, c, _, u, tot in rows:
    p = per.setdefault(c, [0, 0, 0, 0])
    p[0] += 1; p[1] += tot; p[2] = max(p[2], tot); p[3] += u
print("%-40s %8s %10s %9s %9s %9s" % ("barrier caller", "count", "held ms", "avg µs", "refork µs", "max µs"))
for c, (n, tot, mx, u) in sorted(per.items(), key=lambda x: -x[1][1])[:12]:
    print("%-40s %8d %10.1f %9.0f %9.0f %9d" % (c, n, tot / 1e3, tot / n, u / n, mx))

t0 = rows[0][0]
print("\n%8s %9s %12s %9s %9s %9s" % ("time s", "barriers", "held ms/s", "% held", "avg µs", "max µs"))
b = {}
for t, _, _, _, tot in rows:
    x = b.setdefault(int((t - t0) // 10), [0, 0, 0])
    x[0] += 1; x[1] += tot; x[2] = max(x[2], tot)
for k in sorted(b):
    n, tot, mx = b[k]
    print("%8d %9d %12.1f %8.1f%% %9.0f %9d" % (k * 10, n, tot / 1e4, tot / 1e5, tot / n, mx))
