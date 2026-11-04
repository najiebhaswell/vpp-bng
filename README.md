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
| `vpp-patches/` | 13 patches on VPP commit `5db7b9abb` (26.10) |
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
| `blaster/` | BNG Blaster configs and runners (`blaster-run.sh` tap lab, `phys-run.sh` physical) |
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

The accel-ppp-ng fixes live in the fork
[najiebhaswell/accel-ppp-ng, branch `vpp-2610-fixes`](https://github.com/najiebhaswell/accel-ppp-ng/tree/vpp-2610-fixes):
policer-input enabled twice, burst in bytes, PPPoE interface options dropped after `net=`/`vpp-cp=`, session
counters from the VPP stats segment (without it every VPP session died with Lost-Carrier at the first RADIUS
interim, and octets were 0), and the shaper `G` suffix (it was ×10).

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
plain tap (`pb` in the root netns). `lab-phys-down.sh` removes only what the up script added.

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

All with accel-ppp-ng from the fork, VPP with all 13 patches, RADIUS (FreeRADIUS 3.2) for every login,
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

Use `down-burst-factor=0.5` (or more) in `[shaper]` with VPP policers: they drop without a queue, and with the
default 0.1 TCP gets about half of the configured rate.

## Not tested

IPv6 / DHCPv6-PD, more than 4000 sessions, a VPP restart with sessions up, other NICs.

## Credits

VPP PPPoE BNG patches 0001–0006 come from [VyOS](https://github.com/vyos) (authors in each patch header).
accel-ppp-ng from the [accel-ppp](https://github.com/accel-ppp) project; BNG Blaster from RtBrick.

## License

Apache-2.0 (see `LICENSE`). The VPP patches follow VPP's Apache-2.0 license.
