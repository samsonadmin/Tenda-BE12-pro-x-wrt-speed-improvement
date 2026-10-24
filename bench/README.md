# Measurement harness

Scripts used to verify the tuning on a Tenda BE12 Pro (MT7988) running X-WRT.
Run them from a **wired 2.5 GbE client** on the LAN (e.g. a Mac on en19), with
SSH access to the router.

No credentials are stored in these scripts or in this repo. The router
password is only ever typed at the `ssh` prompt.

```sh
# default target is root@192.168.1.1; override if needed:
export ROUTER=root@192.168.1.1

# optional extra ssh flags (key file, control socket, ...)
export ROUTER_SSH_OPTS="-i ~/.ssh/id_ed25519"
```

`softirq-probe.sh` is the important one: it needs no internet quota and shows
directly whether RX work is spread across the 4 cores or pinned to one.

## `softirq-probe.sh` — the decisive check

```sh
./softirq-probe.sh "before" 9 5
```

Prints the per-CPU `NET_RX` softirq delta while pushing WAN traffic.

| Result | Meaning |
|---|---|
| ~95% on CPU2 | RPS pinned to one core — the bottleneck is present |
| spread over all 4 CPUs | RPS is spread — the bottleneck is gone |

Compare against the live RPS mask:

```sh
ssh root@192.168.1.1 'cat /sys/class/net/eth2/queues/rx-0/rps_cpus'
```

## `wan-ab-5mb.sh` — interleaved throughput A/B

```sh
./wan-ab-5mb.sh 8 25
```

Alternates `rps_cpus=4` and `rps_cpus=f` between rounds (so ISP time-of-day
variance hits both equally) and reports mean/median per-request download
speed. Uses 5 MB requests because Cloudflare's `speed.cloudflare.com` endpoint
rate-limits larger per-request transfers.

## `wan-ab-50mb.sh` — same A/B with 50 MB transfers

```sh
./wan-ab-50mb.sh
```

Larger transfers reach a higher per-flow rate, which is where the CPU
bottleneck actually shows. Needs the Cloudflare per-request quota to be
available — it is generous but exhausts after a few hundred MB.

## Benchmarking pitfalls on this setup

Read this before trusting any number you measure here.

**1. `speed.cloudflare.com` rate-limits by client IP.** It serves at most
50 MB per request and applies a byte quota. Once you have pulled a few
hundred MB it starts returning HTTP 429, and requests fail *silently* if you
only look at the aggregate. Worse, the quota depletes *during* a test run, so
the first half of a long benchmark is fast and the second half is slow — which
looks exactly like ISP time-of-day drift.

Compare, measured at the same moment on the same line:

```
A: cloudflare only      336 Mbps
B: mixed origins        792 Mbps
C: non-cloudflare      1028 Mbps
```

Prefer origins that support HTTP range requests so you can control the size:
`mirrors.aliyun.com`, `dl.google.com`, `registry.npmjs.org`. Check per-origin
speed first — `mirrors.aliyun.com` sustains ~470 Mbps on one connection,
`speed.cloudflare.com` ~600 Mbps, `mirrors.tuna.tsinghua.edu.cn` ~236 Mbps.

**2. Interleave the A and B configs.** Running all of A, then all of B, lets
ISP drift masquerade as an effect. Alternate per round.

**3. `date +%s` has 1-second resolution.** A round that finishes in 0.4 s
rounds to 0 or 1 s and the aggregate is garbage (you get values quantised to
395/790 Mbps). Use `python3 -c 'import time;print(time.time())'` for the
timestamps.

**4. Report a t-statistic, not just a mean.** ISP variance on this line runs
16–28% coefficient of variation, so a "+14%" difference from 5 samples is
noise. With 5 rounds per config you need roughly |t| > 2.3 to claim anything.

**5. speedtest.net is not usable from this line.** The nearest servers in its
list are ~1,120 km away in the Philippines — there are no HK servers — so its
numbers reflect a cross-Pacific path, not the local line. The same applies to
`speedtest-cli`.

## Why the LAN path is not the test

`iperf3 -c 192.168.1.1` measures traffic *terminating on* the router. It sits
at the 2.5 Gbps line rate both before and after the fix (2.33 -> 2.31 Gbps),
because the local stack was never the bottleneck. The asymmetric path is the
**forwarding** path (WAN -> NAT -> LAN), so the test has to go out to the
internet.
