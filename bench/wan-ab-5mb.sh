#!/bin/sh
# Interleaved A/B of WAN download throughput vs the RPS mask.
# Alternates rps_cpus=4 (stock, single CPU) and rps_cpus=f (all CPUs) between
# rounds so ISP time-of-day variance hits both configurations equally.
#
# Usage: wan-ab-5mb.sh [rounds_per_config] [requests_per_round]
#
# Env:
#   ROUTER   ssh target for the router   (default: root@192.168.1.1)
#
# Uses 5 MB requests: speed.cloudflare.com rate-limits larger per-request
# transfers (HTTP 429) once you have pulled a few hundred MB.
set -u

ROUNDS="${1:-8}"
REQS="${2:-25}"
ROUTER="${ROUTER:-root@192.168.1.1}"
RAW="${TMPDIR:-/tmp}/wan_ab_raw.txt"

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
      curl -4 -sL -o /dev/null -w "$cfg %{http_code} %{speed_download}\n" --max-time 45 \
        "https://speed.cloudflare.com/__down?bytes=5242880" >> "$RAW"
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
          printf "rps_cpus=%s  n=%-4d mean=%7.0f Mbps  median=%7.0f  p90=%7.0f  max=%7.0f\n",
                 (c=="4" ? "4 (CPU2 only)" : "f (all 4 CPUs)"), NR, s/NR,
                 v[int((NR+1)/2)], v[int(NR*0.9)], v[NR] }'
}
summarize 4
summarize f
echo
A=$(grep "^4 200 " "$RAW" | awk '{print $3*8/1000000}' | sort -n | awk '{v[NR]=$1} END{print v[int((NR+1)/2)]}')
B=$(grep "^f 200 " "$RAW" | awk '{print $3*8/1000000}' | sort -n | awk '{v[NR]=$1} END{print v[int((NR+1)/2)]}')
AM=$(grep "^4 200 " "$RAW" | awk '{s+=$3} END{printf "%.0f", s/NR*8/1000000}')
BM=$(grep "^f 200 " "$RAW" | awk '{s+=$3} END{printf "%.0f", s/NR*8/1000000}')
awk -v a="$AM" -v b="$BM" -v am="$A" -v bm="$B" 'BEGIN{
  printf "delta (mean):   %+.1f%%\n", (b/a-1)*100
  printf "delta (median): %+.1f%%\n", (bm/am-1)*100 }'
