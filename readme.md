# X-WRT Speed Optimization Guide for Tenda BE12 Pro (MediaTek MT7988)

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

# Check natflow status
lsmod | grep natflow

# Check interface statistics
ethtool -S eth2
ethtool -S eth1
```
