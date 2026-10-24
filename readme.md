# X-WRT Speed Optimization Guide for Tenda BE12 Pro (MediaTek MT7988)

> **Read [Part 2](#part-2--x-wrt-2604_b202608221937-kernel-61844) if you are on
> X-WRT 26.04_b202608221937 or newer.**
>
> Part 1 below targets **X-WRT 26.04_b202606240712** (kernel 6.18.36). On the
> newer build the `/etc/rc.local` recipe **silently stops working**: the
> firmware's `packet_steering` service rewrites `rps_cpus` after boot and pins
> every port back to a single CPU, which is the one setting that fixes the
> download path. Part 2 has the corrected approach plus `install.sh`.

## Problem

The Tenda BE12 Pro running **X-WRT 26.04** (kernel 6.18.36) exhibited asymmetric network throughput:

| Metric | Before | After | Improvement |
|---|---|---|---|
| Download | ~1,800 Mbps | ~2,200 Mbps | **+400 Mbps** |
| Upload | ~2,340 Mbps | ~2,340 Mbps | Unchanged |
| Gap | 540 Mbps | 140 Mbps | Within test variance ✅ |

A different router on the same ISP connection achieved **2,300/2,300 Mbps** symmetrically, confirming the issue was specific to this router's X-WRT configuration.

---

## Hardware Context

- **Router:** Tenda BE12 Pro
- **SoC:** MediaTek MT7988 (4× Cortex-A53 @ 2.0 GHz)
- **WiFi:** MediaTek MT7992E (WiFi 7 / EHT)
- **WAN PHY:** Airoha EN8811H (2.5 GbE)
- **LAN PHY:** MediaTek MT7987 (2.5 GbE)
- **Ethernet driver:** `mtk_soc_eth` — all 3 ports (eth0/eth1/eth2) share a **single IRQ and DMA engine**
- **Firmware:** X-WRT 26.04_b202606240712 ("Resolute"), apk-based package manager
- **Flow offload:** `natflow` (X-WRT's custom hardware NAT acceleration, replaces standard `nf_flow_table`)

The single DMA engine architecture means all RX/TX for WAN and LAN goes through one shared DMA channel — making CPU-side tuning critical for throughput.

---

## Issues Found & Fixes

### 1. natflow Hardware Offload Causing Kernel Errors

**Finding:** The `natflow` kernel module was producing continuous kernel warnings:

```
Virtual device eth2 asks to queue packet!
```

This error appeared repeatedly in `dmesg` and indicated that natflow's virtual device was trying to bypass the normal TX path and queue packets directly — which the kernel rejected. This corrupted the DMA pipeline and added latency to packet processing.

**Fix:** Unload `natflow` entirely. Pure software routing with GRO/GSO performs better on this hardware than natflow's buggy hardware offload path.

```bash
rmmod natflow
```

### 2. Receive Packet Steering (RPS) Locked to Single CPU

**Finding:** RPS was set to `4` (bitmask = CPU2 only), meaning **all incoming network processing was pinned to one core**. The softirq distribution confirmed CPU2 was handling 433K NET_RX vs CPU3 at only 304:

```
NET_RX:      30941     122162     433216        304
```

This caused a hard CPU bottleneck on the download path, while upload benefited from TSO hardware offload and didn't hit the same constraint.

**Fix:** Spread RX processing across all 4 CPUs (bitmask `f` = CPUs 0,1,2,3):

```bash
echo f > /sys/class/net/eth2/queues/rx-0/rps_cpus
echo f > /sys/class/net/eth1/queues/rx-0/rps_cpus
```

Also increase RPS flow table entries for better flow distribution:

```bash
echo 2048 > /proc/sys/net/core/rps_sock_flow_entries
echo 2048 > /sys/class/net/eth2/queues/rx-0/rps_flow_cnt
```

### 3. GRO/GSO Disabled on Ethernet Interfaces

**Finding:** Generic Receive Offload (GRO) and Generic Segmentation Offload (GSO) were **OFF** on both `eth2` (WAN) and `eth1` (LAN). This meant every single packet was processed individually by the CPU, creating unnecessary overhead — especially on the download (receive) path.

- **GRO:** Batches incoming packets before passing them up the network stack, reducing per-packet CPU cost
- **GSO:** Batches outgoing packet segmentation, reducing TX overhead

Note: TSO was already ON (hardware TCP segmentation for upload), which explains why upload was fine while download suffered.

**Fix:** Enable on all relevant interfaces:

```bash
ethtool -K eth2 gro on
ethtool -K eth2 gso on
ethtool -K eth1 gro on
ethtool -K eth1 gso on
ethtool -K br-lan gro on
ethtool -K br-lan gso on
```

### 4. Insufficient TCP/NAPI Buffers for 2.5 Gbps

The default buffer sizes were fine for gigabit but insufficient for 2.5 Gbps throughput, especially with BBR congestion control (which likes to keep the pipe full).

| Parameter | Default | Tuned |
|---|---|---|
| `tcp_rmem` | 4K / 131K / 3.9M | 4K / 87K / 64M |
| `tcp_wmem` | 4K / 16K / 3.9M | 4K / 65K / 64M |
| `netdev_budget` | 300 | 600 |
| `dev_weight` | 64 | 128 |
| `netdev_max_backlog` | 1,000 | 10,000 |
| `gro_flush_timeout` | 0 | 200,000 (200 µs) |
| `napi_defer_hard_irqs` | 0 | 2 |

```bash
sysctl -w net.ipv4.tcp_rmem='4096 87380 67108864'
sysctl -w net.ipv4.tcp_wmem='4096 65536 67108864'
sysctl -w net.core.netdev_budget=600
sysctl -w net.core.dev_weight=128
sysctl -w net.core.netdev_max_backlog=10000
echo 200000 > /sys/class/net/eth2/gro_flush_timeout
echo 2 > /sys/class/net/eth2/napi_defer_hard_irqs
```

---

## Complete `/etc/rc.local`

> **On X-WRT 26.04_b202608221937 and newer this file alone is not enough** — see
> [Part 2](#part-2--x-wrt-2604_b202608221937-kernel-61844). The `rps_cpus`
> lines below get reverted by `/etc/init.d/packet_steering` on the next network
> or firewall reload, and `eth0` (the DSA switch CPU port for LAN 3–5) is
> missing from the offload list. Use `install.sh` instead.

All changes are applied on boot via `/etc/rc.local`:

```bash
# 1. Disable natflow (causes kernel errors)
rmmod natflow 2>/dev/null

# 2. GRO/GSO on all interfaces
ethtool -K eth2 gro on 2>/dev/null
ethtool -K eth2 gso on 2>/dev/null
ethtool -K eth1 gro on 2>/dev/null
ethtool -K eth1 gso on 2>/dev/null
ethtool -K br-lan gro on 2>/dev/null
ethtool -K br-lan gso on 2>/dev/null

# 3. RPS: spread RX across all 4 CPUs
echo f > /sys/class/net/eth2/queues/rx-0/rps_cpus 2>/dev/null
echo f > /sys/class/net/eth1/queues/rx-0/rps_cpus 2>/dev/null
echo 2048 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
echo 2048 > /sys/class/net/eth2/queues/rx-0/rps_flow_cnt 2>/dev/null

# 4. TCP/NAPI tuning for 2.5Gbps
sysctl -w net.ipv4.tcp_rmem='4096 87380 67108864' >/dev/null 2>&1
sysctl -w net.ipv4.tcp_wmem='4096 65536 67108864' >/dev/null 2>&1
sysctl -w net.core.netdev_budget=600 >/dev/null 2>&1
sysctl -w net.core.dev_weight=128 >/dev/null 2>&1
sysctl -w net.core.netdev_max_backlog=10000 >/dev/null 2>&1
echo 200000 > /sys/class/net/eth2/gro_flush_timeout 2>/dev/null
echo 2 > /sys/class/net/eth2/napi_defer_hard_irqs 2>/dev/null

# Start other services
/etc/init.d/cloudflared start
exit 0
```

---

## Things That Were Already OK

These were already correctly configured and did NOT need changes:
- **Bridge netfilter:** Already disabled (`bridge-nf-call-iptables = 0`)
- **Reverse path filter:** Already disabled (`rp_filter = 0`)
- **BBR congestion control:** Already active (`tcp_congestion_control = bbr`)
- **Flow control:** Already on (but not negotiated with ISP/switch — typical)
- **iptables rules:** Empty (fw4 uses nftables, no legacy iptables overhead)
- **No packet drops:** Interface and driver stats showed zero drops

---

## Limitations

- The MediaTek frame engine shares a **single IRQ (#69)** across all 3 ethernet ports (eth0/eth1/eth2). This is a hardware limitation of the MT7988 SoC — the single DMA channel can become a throughput bottleneck for concurrent bidirectional traffic regardless of software tuning.
- With these optimizations, download went from 1,800 → 2,200 Mbps. The remaining ~140 Mbps gap vs upload is likely due to the asymmetric way the single DMA engine handles RX vs TX queuing.
- natflow hardware NAT acceleration was **detrimental** to performance on this hardware revision. Future X-WRT updates may fix the natflow driver for this chipset — test with `modprobe natflow` after firmware upgrades.
- The `qdisc fq` (recommended for BBR) is **not compatible** with the `mq` multi-queue hardware. The default `fq_codel` child qdiscs per TX queue work fine.

---

## Diagnostic Commands

```bash
# Check kernel errors
dmesg | grep -i "Virtual device"

# Check RPS status
cat /sys/class/net/eth2/queues/rx-0/rps_cpus

# Check offload status
ethtool -k eth2 | grep -E 'generic-receive|generic-segmentation'

# Check CPU softirq distribution
cat /proc/softirqs | head -10

# Check natflow status (Part 1 firmware only - natflow was removed in Part 2)
lsmod | grep natflow

# Check interface statistics
ethtool -S eth2
ethtool -S eth1
```

---

# Part 2 — X-WRT 26.04_b202608221937 (kernel 6.18.44)

The guide above was written against **X-WRT 26.04_b202606240712** (kernel 6.18.36).
This section covers the newer build, and it matters: **on the newer build the
`/etc/rc.local` recipe above silently stops working**, because the firmware
overwrites the RPS setting after boot.

## TL;DR — why the rc.local recipe regressed

`/etc/init.d/packet_steering` (START=25) runs
`/usr/libexec/network/packet-steering.uc`, which **writes `rps_cpus` for every
physical netdev**. It is re-triggered by:

```sh
procd_add_reload_trigger "network"
procd_add_reload_trigger "firewall"
procd_add_raw_trigger "interface.*" 1000 /etc/init.d/packet_steering reload
```

With `network.globals.packet_steering` unset it defaults to `1` = "Enabled
(single CPU per device)", so it pins **all three** ethernet ports to one core:

```
eth0 rps_cpus=4     # bitmask 0x4 = CPU2 only
eth1 rps_cpus=4
eth2 rps_cpus=4
```

`echo f > /sys/class/net/eth2/queues/rx-0/rps_cpus` in `/etc/rc.local` runs at
boot, but the very next network/firewall reload or interface event reverts it.
The tuning therefore disappears at runtime — the sysctl and GRO/GSO parts
survive (they are not managed by the firmware), but **the RPS part does not**,
and RPS is the part that fixes the download path.

Measured on the router's own `/proc/softirqs`, with identical WAN traffic:

| `rps_cpus` | NET_RX on CPU0 | CPU1 | CPU2 | CPU3 |
|---|---|---|---|---|
| `4` (stock) | 2.5% | 0.5% | **95.5%** | 1.4% |
| `f` (all CPUs) | 12.8% | 26.3% | 12.2% | 48.7% |

## The fix — use the firmware's own knob

Do not fight `packet_steering`; configure it. When `packet_steering=2`
("Enabled (all CPUs)") the script writes `0xf` and the flow-table size itself,
on every re-trigger:

```sh
uci set network.globals.packet_steering='2'   # LuCI: Network > Interfaces > Global
uci set network.globals.steering_flows='2048'
uci commit network
/etc/init.d/packet_steering reload
```

`cpu_mask(-1)` in `packet-steering.uc` yields `(1 << ncpu) - 1` = `0xf`, and
`rps_flow_cnt` is set from the `-l <steering_flows>` argument.

## Other changes needed on the newer build

**1. `natflow` no longer exists — `natcap` replaced it.**

`natcap` is built into the kernel (`(O)` in `/proc/modules`), so it cannot be
unloaded, and `/dev/natflow_ctl` is gone, which makes `/etc/init.d/natflow-boot`
inert (its `disable_gro_gso` never runs). There are no
`Virtual device eth2 asks to queue packet!` errors on this build, so
`rmmod natflow` is a harmless no-op and there is no hardware offload to
disable.

**2. `eth0` had GRO/GSO off.** The original guide only covered eth1/eth2/br-lan.
`eth0` is the DSA switch CPU port that carries LAN ports 3–5 (`lan3/4/5@eth0`),
so traffic on those ports was doing per-packet processing.

**3. Per-interface sysfs knobs die with the interface.**
`gro_flush_timeout` and `napi_defer_hard_irqs` are per-netdev, so a WAN
reconnect or `/etc/init.d/network reload` recreates the netdev and wipes them.
They need to be re-applied on interface events.

**4. Do not put multi-value sysctls in `/etc/sysctl.d/*.conf`.**
X-WRT's `/etc/init.d/sysctl` runs:

```sh
cat /etc/sysctl.d/*.conf /etc/sysctl.conf | grep -v "^#" | while read line; do sysctl -qw $line; done
```

The unquoted `$line` is word-split, so `net.ipv4.tcp_rmem=4096 87380 67108864`
becomes three arguments and the buffer is set to **4096** — catastrophically
small. Keep the multi-value settings in an init script with proper quoting.

**5. `natcap` kernel log spam.** `natcapd.default.debug=3` is `error|warn`, and
the warn level emitted a `natcap_common_cone_out_hook()` line for every NAT
mapping update. `debug=1` keeps errors only.

## Install

```sh
scp router-speed install.sh root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'sh /tmp/install.sh'
```

`router-speed` is an init script (S96) with the same trigger set as
`packet_steering`, so the per-interface settings are re-applied whenever the
network stack reloads. `/etc/rc.local` is reduced to a single call into it.

To undo: `scp restore-defaults.sh root@192.168.1.1:/tmp/ && ssh root@192.168.1.1 'sh /tmp/restore-defaults.sh'`

## Measured result on the newer build

Same router, same ISP line (HKT, AS4760), alternating `rps_cpus=4` and
`rps_cpus=f` between rounds so ISP time-of-day variance hits both equally.

**1. RPS redistribution (decisive, no internet quota needed):**

| `rps_cpus` | NET_RX on CPU0 | CPU1 | CPU2 | CPU3 |
|---|---|---|---|---|
| `4` (stock) | 2.5% | 0.5% | **95.5%** | 1.4% |
| `f` (fixed) | 24.8% | 26.1% | 24.1% | 25.1% |

The single-core concentration is real and it is gone.

**2. Throughput, interleaved A/B** (aliyun mirror, 4 x 50 MB streams, ~1 Gbps):

| Config | n | mean | median | stdev |
|---|---|---|---|---|
| `rps_cpus=4` | 6 | 1045 Mbps | 1026 | 94 |
| `rps_cpus=f` | 6 | 1059 Mbps | 1052 | 42 |
| | | **+1.3% (t=0.33, not significant)** | | |

**3. Why the gain is ~0 on this firmware.** The router is not CPU-bound:

- peak aggregate CPU busy during a ~1 Gbps WAN download: **21.8%** (softirq ~10%)
- WAN throughput plateaus at **~1,050 Mbps** whether you use 4, 8, 16 or 24 streams

So there is no single-core softirq ceiling left for RPS to lift. The remaining
gap to a 2 Gbps+ line is **not** software — it is the ISP line, the peering to
your target, or the shared DMA engine.

**Still worth doing.** The fix costs nothing measured (0.00% on iperf3) and
removes a latent bottleneck: the moment per-flow rates or flow counts rise
enough for one core to matter, 95% of RX work landing on a single core is the
wrong shape to be in.

> **Correction.** An earlier draft of this section quoted a +24% / +27% gain.
> Those numbers came from a **non-interleaved** run (all of config A, then all
> of config B) against a CDN that was rate-limiting the client IP, and they did
> not replicate under a properly interleaved, low-variance test. The numbers
> above supersede them. If you measured the 1,800 -> 2,200 Mbps in Part 1 with
> a local or well-peered target, re-running the same target against the
> `b202608221937` build would be the fair comparison — the Part 1 and Part 2
> firmwares differ in NAT offload, not just in kernel version.

The LAN-local path is unaffected (2.33 -> 2.31 Gbps on iperf3, i.e. flat at the
2.5 Gbps line rate) — consistent with the original finding that the
*forwarding* (download) path was the asymmetric one, not the local stack.

## Diagnostic commands (newer build)

```sh
# Is RPS still pinned to one CPU? (should print f)
cat /sys/class/net/eth2/queues/rx-0/rps_cpus

# What does the firmware think packet steering should be?
uci get network.globals.packet_steering

# Who will overwrite rps_cpus next?
grep -n "procd_add" /etc/init.d/packet_steering

# natcap log level (3 = error|warn, 1 = error only)
uci get natcapd.default.debug

# Per-CPU NET_RX distribution
grep NET_RX /proc/softirqs
```
