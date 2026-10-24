#!/bin/sh
# Interleaved A/B of WAN download throughput vs the RPS mask, using 50 MB
# transfers. Larger transfers reach a higher per-flow rate, which is where the
# CPU bottleneck actually shows up.
#
# Usage: wan-ab-50mb.sh [rounds_per_config] [requests_per_round]
#
# Env:
#   ROUTER   ssh target for the router   (default: root@192.168.1.1)
#
# NOTE: speed.cloudflare.com serves at most 50 MB per request and applies a
# per-request size limit / byte quota to the client IP. If requests start
# failing with HTTP 429, fall back to wan-ab-5mb.sh.
set -u

ROUNDS="${1:-6}"
REQS="${2:-10}"
ROUTER="${ROUTER:-root@192.168.1.1}"
RAW="${TMPDIR:-/tmp}/wan_ab50_raw.txt"

r() { ssh ${ROUTER_SSH_OPTS:-} -o StrictHostKeyChecking=accept-new "$ROUTER" "$@"; }

set_mask() {
  r "for i in eth0 eth1 eth2; do echo $1 > /sys/class/net/\$i/queues/rx-0/rps_cpus; done" >/dev/null 2>&1
}

: > "$RAW"
round=1
while [ "$round" -le "$ROUNDS" ]; do
  for cfg in 4 f; do
    set_mask "$cfg"
    i=1
    while [ "$i" -le "$REQS" ]; do
      curl -4 -sL -o /dev/null -w "$cfg %{http_code} %{speed_download}\n" --max-time 90 \
        "https://speed.cloudflare.com/__down?bytes=52428800" >> "$RAW"
      i=$((i + 1))
    done
    printf "."
  done
  echo
  round=$((round + 1))
done
echo

summarize() {
  grep "^$1 200 " "$RAW" | awk '{print $3*8/1000000}' | sort -n | awk -v c="$1" '
    { v[NR]=$1; s+=$1 }
    END { if (!NR) { print c": no data"; exit }
          printf "rps_cpus=%s  n=%-4d mean=%7.0f Mbps  median=%7.0f  max=%7.0f\n",
                 (c=="4" ? "4 (CPU2 only)" : "f (all 4 CPUs)"), NR, s/NR, v[int((NR+1)/2)], v[NR] }'
}
summarize 4
summarize f
echo
AM=$(grep "^4 200 " "$RAW" | awk '{s+=$3} END{printf "%.0f", s/NR*8/1000000}')
BM=$(grep "^f 200 " "$RAW" | awk '{s+=$3} END{printf "%.0f", s/NR*8/1000000}')
awk -v a="$AM" -v b="$BM" 'BEGIN{
  if (a > 0) printf "delta (mean): %+.1f%%\n", (b/a-1)*100 }'
