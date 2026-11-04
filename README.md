# vpp-bng

A PPPoE BNG lab on [VPP](https://fd.io) **26.10** with [accel-ppp-ng](https://github.com/accel-ppp/accel-ppp-ng)
as the control plane: VPP patches, build and install scripts, lab setups and test runners, including
[BNG Blaster](https://github.com/rtbrick/bngblaster) runs over a real 2×100G LACP bond.

accel-ppp-ng terminates PPPoE in its usual way on Linux "control-plane" (CP) interfaces, and hands every session
to VPP through its `vyos_vpp` hooks. VPP then forwards subscriber traffic in the data plane, with per-session
policers set from RADIUS. The VPP side is the PPPoE plugin with the VyOS BNG patches, ported to 26.10 and
extended (QinQ, worker spreading, bug fixes).

Status: lab only. Tested on one router (Xeon Gold 6254, 12 VPP workers, ConnectX-5 2×100G in an LACP bond).

## Contents

| Path | What |
|---|---|
| `vpp-patches/` | 14 patches on VPP commit `5db7b9abb` (26.10) |
| `build-vpp.sh` | clone VPP, apply the patches, build the .debs |
| `install-vpp.sh <version>` | install and hold the built .debs, restart VPP, print router state before/after |
| `build-accel.sh` | build and install accel-ppp-ng from the fork branch with the VPP 26.10 fixes |
| `lab-env.sh`, `lab.env.example` | site settings (hosts, RADIUS, subscriber names) used by every script |
| `accel-ppp-lab*.conf` | accel-ppp configs: static (`chap-secrets`), RADIUS, physical; `@VAR@` filled in from `lab.env` |
| `lab-up.sh` / `lab-down.sh` | tap lab: pppd client netns → VPP → iperf3 server netns |
| `lab-blaster-up.sh` | tap lab for BNG Blaster on the router itself, optional QinQ |
| `lab-phys-up.sh` / `lab-phys-down.sh` | physical lab: PPPoE over VLAN/QinQ sub-interfaces of a VPP bond |
| `capture-test.sh`, `lab-rate.sh` | static-config tests: login, rate limits, teardown, pcaps |
| `radius-test-run.sh` + `radius-steps.sh` | RADIUS test: PAP/CHAP/MS-CHAPv2, reject, rate attribute, CoA, DM, accounting, timeouts |
| `blaster/` | BNG Blaster configs and runners (`blaster-run.sh` tap lab, `phys-run.sh` physical, `cap-run.sh` session scale with the DPDK build) |
| `accel-ppp-lab-cap.conf` | capacity variant of the physical config: verbose logging off, ~135k address pool |
| `xwd2png.py` | converts xterm window dumps (`phys-run.sh` with `SHOTDIR`) to PNG |

## VPP patches

| # | Patch | Origin |
|---|---|---|
| 0001 | pppoe: automated session management | VyOS (Denys Haryachyy) |
| 0002 | pppoe: option `enable-pass-nd-and-dhcpv6` | VyOS |
| 0003 | IPv6 ICMP RA punt shortcut | VyOS |
| 0004 | removed PPPoE-input feature setup | VyOS |
| 0005 | PPPoE `cp_binding_dump` API call | VyOS |
| 0006 | policer: multicast arc features for PPPoE sessions | VyOS patch, reduced to the multicast arcs |
| 0007 | pppoe: use `vlib_rpc_call_main_thread` (26.10 rename) | new |
| 0008 | pppoe: look up the DP hw interface by `sw_if_index` | new |
| 0009 | pppoe: remove DP/CP mappings when an interface is deleted | new |
| 0010 | pppoe: QinQ and 802.1ad tags in the session rewrite (downstream was sent untagged) | new |
| 0011 | pppoe: parse session packets behind any VLAN tags (QinQ sessions stuck after PADS) | new |
| 0012 | hash: spread PPPoE frames over workers by client MAC | new |
| 0013 | handoff: do not crash when the RX interface has no handoff config (SIGSEGV with handoff on bond members) | new |
| 0014 | adj: a midchain on an interface-tx DPO counts the packet once (every downstream PPPoE packet was counted twice on the session, so RADIUS Acct-Output-Octets were doubled) | new |

The accel-ppp-ng fixes live in the fork
[najiebhaswell/accel-ppp-ng, branch `vpp-2610-fixes`](https://github.com/najiebhaswell/accel-ppp-ng/tree/vpp-2610-fixes):
policer-input enabled twice, burst in bytes, PPPoE interface options dropped after `net=`/`vpp-cp=`, session
counters from the VPP stats segment (without it every VPP session died with Lost-Carrier at the first RADIUS
interim, and octets were 0), the shaper `G` suffix (it was ×10), and reading those counters in place: the first
version re-mapped the stats segment for every new session, which capped setup at ~65 sessions/s and made accel
exit at 5120 sessions.

## Build and install

On the router, with this repository checked out and `lab.env` filled in:

```sh
./build-vpp.sh                         # VPP .debs in vpp/build-root
sudo ./install-vpp.sh 26.10.0-15~gf80f6d55b
./build-accel.sh                       # accel-pppd to /usr/local
```

`install-vpp.sh` restarts VPP. On a production box, look at what that restart does to the routing first.

## Spreading PPPoE over the workers

NIC RSS cannot hash PPPoE, so without handoff every subscriber's upstream lands on one worker. Patch 0012 makes
the `handoff-eth` hash key PPPoE by client MAC (untagged, dot1q and QinQ). Enable it on the bond first, then on
its members; for example in a VPP startup exec file that runs after the bond is created:

```
set interface handoff BondEthernet0 workers 0-11
set interface handoff cx5-0 workers 0-11
set interface handoff cx5-1 workers 0-11
```

## Bond MAC

VPP gives a bond a random `02:fe:…` MAC. Member NICs with unicast filtering (mlx5 with promiscuous off) drop
every unicast frame to it, so PADR and session traffic never arrive while broadcasts still do. Give the bond the
MAC of its first member when it is created (`create bond ... hw-addr <mac>`). With linux-cp sync on, set a later
change on the Linux side of the bond's LCP; a MAC set only in VPP is overwritten from Linux.

## Labs

**Tap lab** (`lab-up.sh`): `pppd` in netns `bngsub` → `tap900` → VPP → `tap901` → iperf3 in netns `bngsrv`
(172.31.99.2). The CP of `tap900` is `pppoe0` in the root netns, so accel-pppd and its RADIUS/CoA traffic
use the host's normal network. `ACCEL_CONF=/etc/accel-ppp-lab-radius.conf ./lab-up.sh` uses RADIUS instead of
`chap-secrets`.

**BNG Blaster on the router** (`lab-blaster-up.sh`): both taps in netns `bngbl` for bngblaster.
`QINQ="100:dot1q:10-59 200:dot1ad:10-59"` adds S-VLAN/C-VLAN sub-interfaces with their LCPs and mappings.

**Physical** (`lab-phys-up.sh`): BNG Blaster on a separate host, cabled to the two bond members, with its
own LACP LAG. The DP sides are new `BondEthernet0` sub-interfaces: VLAN 300 for PPPoE, VLAN 301 for the network
side (172.31.98.1/30), and with `QINQ=` one per S/C pair. The CP sides are sub-interfaces with the same tags on a
plain tap (`pb` in the root netns). `lab-phys-down.sh` removes only what the up script added. `ACCESS_IF=cx5-0
NET_IF=cx5-1` puts the sub-interfaces on the ports themselves instead of the bond; thousands of them are created
in one batch (10k QinQ pairs in ~30 s).

## RADIUS test subscribers

`radius-test-run.sh` expects these users on the RADIUS server, all with password `SUB_PASS`:

| User | Attributes |
|---|---|
| `<SUB_USER>1` | `Framed-IP-Address = 100.64.200.1` |
| `<SUB_USER>2` | `Mikrotik-Rate-Limit = "10M/20M"`, `Acct-Interim-Interval = 30` |
| `<SUB_USER>3` | `Session-Timeout = 120` |
| `<SUB_USER>4` | `Idle-Timeout = 60` |
| `<SUB_USER>5` and up | none (accel's default `rate-limit`) |

`COA_DIR` on the RADIUS host holds a `coa.sh coa|disconnect <user> [attributes]` script (radclient to the
router's `dae-server`), and `logs/radacct/` with FreeRADIUS detail files.

## Results

All with accel-ppp-ng from the fork, VPP with the patches, RADIUS (FreeRADIUS 3.2) for every login,
10 pps per session in each direction.

| Test | Result |
|---|---|
| RADIUS: PAP, CHAP-MD5, MS-CHAPv2, Access-Reject | pass |
| Mikrotik-Rate-Limit → VPP policers, CoA rate change, Disconnect-Request | pass |
| Framed-IP-Address, Session-Timeout, Idle-Timeout, interim/stop octets from VPP counters | pass |
| Tap lab, BNG Blaster 1000 sessions untagged | ~14 s, 2000/2000 flows (small loss = tap TX ring) |
| Physical, 1000 sessions VLAN 300 | 11.3 s, 2000/2000 flows, 0 loss, PPPoE upstream on all 12 workers |
| Physical, 100 sessions QinQ (dot1q + dot1ad S-VLAN) | 2.6 s, 200/200 flows, 0 loss, tag order 0x88a8/0x8100 on the wire |
| Physical, 4000 sessions VLAN 300 | 27–30 s, 8000 policers, 8000/8000 flows; ~0.1% loss from NIC rx_missed while the runner polled 4000 sessions over the CLI (0 without that loop) |

### Session scale

BNG Blaster (upstream build with DPDK, LAG/LACP over both ports) on a separate host, PPPoE N:1 on VLAN 300, CHAP
via RADIUS, 1 pps of session traffic per session each way, `cap-run.sh`:

| Sessions @ start rate | Up after | Setup rate (Blaster avg) | Flows verified | accel CPU / RSS | VPP heap |
|---|---|---|---|---|---|
| 10k @ 200/s | 59.6 s | 192/s | 20000/20000 | 7% / 83 MB | 669 MB |
| 10k @ 500/s | 27.5 s | 473/s | 20000/20000 | 7% | |
| 10k @ 1000/s | 22.1 s | 912/s | 20000/20000 | 9% | |
| 64k @ 200/s | 411 s (63992 up, 8 failed, no retry) | 192/s | 127986/128000 | 48% / 720 MB | 1.0 GB of 4 GB, 128k policers |
| 64k @ 1000/s | peaked at 59.7k, then ~6.7k sessions dropped | | | | |

Every session costs VPP several API calls (interface, features, two policers, a route), each under the worker
barrier, and creating an interface gets slower as their number grows. Past ~35k sessions a fast setup or teardown
stalls the workers long enough to overflow the NIC RX rings (`rx_missed_errors`); at 1000/s that loses LCP
echoes and sessions drop. With sessions up and steady there are no misses. For tens of thousands of subscribers
keep the setup rate around 200-400/s.

### Throughput

TRex (`blaster/trex-run.sh` + `trex/pppoe-trex.py`) with 512 sessions set up by BNG Blaster: one upstream PPPoE
and one downstream IPv4 stream per session, both directions on both 100G ports. TRex speaks no LACP, so the bond
ran in static (xor) mode for these runs. Loss includes the policer of the one RADIUS user limited to 10M/20M.

| Traffic | Offered | Forwarded | Loss |
|---|---|---|---|
| 1400 B, both directions | 96.1 Gbps (8.30 Mpps) | 8.29 Mpps | 0.20% |
| 46 B IP, downstream only | 20.0 Mpps | 19.94 Mpps | 0.30% |
| 46 B IP, upstream only | 12.0 Mpps | 11.98 Mpps | 0.14% |
| 46 B IP, upstream only | 16.0 Mpps | 13.2 Mpps | 17.8% |
| IMIX (46/576/1400, 7:4:1), both directions | 42 / 63 / 84 Gbps | 13.96 / 20.78 / 23.41 Mpps | 0.04% / 0.79% / 16% |

The NIC cannot RSS-hash PPPoE, so all upstream PPPoE arrives on RX queue 0 of each port and is handed off to the
other workers from there. With both queues 0 on the same worker (the default placement) upstream saturates at
~8 Mpps and IMIX loses 10% at 42 Gbps; give each port's queue 0 its own worker:

```
set interface rx-placement cx5-1 queue 0 worker 6
```

1400-byte traffic is at the PCIe Gen3 limit of the single 2×100G card; downstream scales over all workers through
RSS and did not reach its limit.

**10k QinQ sessions on the physical ports.** Subscribers on `cx5-0` directly (no bond), S-VLAN 100–104 (802.1Q)
and 200–204 (802.1ad) × C-VLAN 1–1000, network on `cx5-1` VLAN 301:

```
ACCESS_IF=cx5-0 NET_IF=cx5-1 PPPOE_VLAN=none QINQ="100-104:dot1q:1-1000 200-204:dot1ad:1-1000" \
  CFG_BASE=blaster/qinq-10k.json blaster/trex-run.sh tput-trex-qinq 10000 "1400 bi 4.46mpps/0.893mpps"
```

With separate access and network ports, TRex sends one stream per direction whose field engine steps through the
sessions (MAC, S/C tags, PPPoE session id, IP) packet by packet, so every session gets the same rate and the
profile loads at once; `<down mult>/<up mult>` sets the directions separately. Rates per session, 1400-byte IP
packets:

| Downstream / upstream | Received per session | Loss down / up |
|---|---|---|
| 5 / 5 Mbit/s (4.46 Mpps each way offered) | 4.66 / 4.66 Mbit/s (TRex max 4.16 Mpps per port, 96 Gbps) | 0.04% / 0.14% |
| 5 / 1 Mbit/s | 4.99 / 1.0 Mbit/s | 0.045% / 0.094% |
| 5 / 2.5 Mbit/s | 4.99 / 2.49 Mbit/s | 0.091% / 0.169% |
| 5 / 4 Mbit/s | 4.99 / 3.99 Mbit/s | 0.042% / 0.122% |

5 Mbit/s both ways for 10k sessions needs ~104 Gbps L1 per direction through one card; the CX5 Ex runs at PCIe
Gen3 x16 on both hosts, so that needs the access and network ports on separate cards. Upstream loss is
`rx_missed` on queue 0 of `cx5-0`, which takes all upstream PPPoE (~4 Mpps) before handing it off.
BNG Blaster's own DPDK streams (`blaster/tput-run.sh`) reached only ~1.9 Mpps for the same setup.

### Churn

10k sessions with 1 pps of traffic each; the router terminates random sessions (`accel-cmd terminate`, as a
RADIUS Disconnect would) and BNG Blaster logs them in again through RADIUS (`blaster/churn-run.sh`):

| Churn for 120 s | Terminated / logged in again | Lowest number of sessions up | NIC rx_missed | Afterwards |
|---|---|---|---|---|
| 100/s | 12000 / 11847 | ~9870 | 0 | 10000/10000 up, 20000/20000 flows, no leaked interface, policer or route |
| 300/s | 36000 / 33275 | 8084 (~1250 logins queued) | 0 | 10000/10000 up, 20000/20000 flows, no leaks |

Use `down-burst-factor=0.5` (or more) in `[shaper]` with VPP policers: they drop without a queue, and with the
default 0.1 TCP gets about half of the configured rate.

## Not tested

IPv6 / DHCPv6-PD, more than 4000 sessions, a VPP restart with sessions up, other NICs.

## Credits

VPP PPPoE BNG patches 0001–0006 come from [VyOS](https://github.com/vyos) (authors in each patch header).
accel-ppp-ng from the [accel-ppp](https://github.com/accel-ppp) project; BNG Blaster from RtBrick.

## License

Apache-2.0 (see `LICENSE`). The VPP patches follow VPP's Apache-2.0 license.
