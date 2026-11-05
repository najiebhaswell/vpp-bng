#!/usr/bin/env python3
# Control-plane path over <seconds> (default 10): packets per second through the CP tap (VPP tx = to accel, rx =
# from accel), its "no free tx slots" drops, the host side's tx drops (accel -> VPP) and the CPU share of the
# control-plane processes. Stats segment only. With "-t", one line per second instead of the average.
#   cpstat.py [-t] [seconds] [tap] [host-if]
import os
import sys
import time

from vpp_papi.vpp_stats import VPPStats

args = [a for a in sys.argv[1:] if a != "-t"]
timeline = "-t" in sys.argv
secs = float(args[0]) if args else 10
tap = args[1] if len(args) > 1 else "tap950"
host = args[2] if len(args) > 2 else "pb"
s = VPPStats("/run/vpp/stats.sock")
s.connect()
idx = s["/if/names"].index(tap)


def sample():
    tx = sum(t[idx]["packets"] for t in s["/if/tx"])
    rx = sum(t[idx]["packets"] for t in s["/if/rx"])
    drops = 0
    for k in s.ls(["/err/%s-tx/" % tap]):
        drops += sum(s[k])
    hd = int(open("/sys/class/net/%s/statistics/tx_dropped" % host).read())
    return tx, rx, drops, hd


def cpu():
    # utime+stime per comm, for the processes and kernel threads of the control plane
    out = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            for tid in os.listdir("/proc/%s/task" % pid):
                f = open("/proc/%s/task/%s/stat" % (pid, tid)).read()
                comm = f[f.index("(") + 1:f.rindex(")")]
                if comm.startswith(("vhost", "accel", "govpp", "systemd-udevd", "ksoftirqd")):
                    key = comm.split("-")[0].split("/")[0] if comm.startswith(("vhost", "ksoftirqd")) else comm
                    v = f[f.rindex(")") + 2:].split()
                    out[key] = out.get(key, 0) + int(v[11]) + int(v[12])
        except (FileNotFoundError, ProcessLookupError, ValueError):
            pass
    return out


def line(a, b, ca, cb, dt):
    hz = os.sysconf("SC_CLK_TCK")
    c = ", ".join("%s %.0f%%" % (k, 100.0 * (cb[k] - ca.get(k, 0)) / hz / dt) for k in sorted(cb))
    return ("%s: to accel %.0f pps, from accel %.0f pps, no free tx slots %.0f/s, %s tx dropped %.0f/s | cpu %s" %
            (tap, (b[0] - a[0]) / dt, (b[1] - a[1]) / dt, (b[2] - a[2]) / dt, host, (b[3] - a[3]) / dt, c))


a, ca, t0 = sample(), cpu(), time.time()
if timeline:
    for i in range(int(secs)):
        time.sleep(1)
        b, cb, t1 = sample(), cpu(), time.time()
        print("%3d %s" % (i + 1, line(a, b, ca, cb, t1 - t0)), flush=True)
        a, ca, t0 = b, cb, t1
else:
    time.sleep(secs)
    b, cb, t1 = sample(), cpu(), time.time()
    print(line(a, b, ca, cb, t1 - t0))
