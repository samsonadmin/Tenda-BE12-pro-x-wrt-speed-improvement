#!/bin/sh
# Measure per-CPU NET_RX softirq distribution while pushing WAN traffic.
#
# Usage: softirq-probe.sh <label> [requests] [sizeMB]
#
# Env:
#   ROUTER   ssh target for the router   (default: root@192.168.1.1)
#
# Uses plain ssh so the password is only ever typed at the prompt - never
# stored in this file, in the shell history, or passed on the command line.
set -u

LABEL="${1:-probe}"
REQS="${2:-8}"
SIZE="${3:-5}"
ROUTER="${ROUTER:-root@192.168.1.1}"

r() { ssh ${ROUTER_SSH_OPTS:-} -o StrictHostKeyChecking=accept-new "$ROUTER" "$@"; }

before=$(r 'grep NET_RX /proc/softirqs | awk "{print \$2,\$3,\$4,\$5}"')
i=1
while [ "$i" -le "$REQS" ]; do
  curl -4 -sL -o /dev/null --max-time 60 \
    "https://speed.cloudflare.com/__down?bytes=$((SIZE*1024*1024))" &
  i=$((i + 1))
  [ $((i % 3)) -eq 0 ] && wait
done
wait
after=$(r 'grep NET_RX /proc/softirqs | awk "{print \$2,\$3,\$4,\$5}"')

echo "=== $LABEL: NET_RX softirq deltas per CPU ==="
echo "$before" | awk '{b[1]=$1;b[2]=$2;b[3]=$3;b[4]=$4} END{print "before:",$1,$2,$3,$4}'
echo "$after"  | awk -v B="$before" '{
  split(B,b," ");
  d1=$1-b[1]; d2=$2-b[2]; d3=$3-b[3]; d4=$4-b[4];
  t=d1+d2+d3+d4;
  printf "delta:  CPU0=%-10d CPU1=%-10d CPU2=%-10d CPU3=%-10d  total=%d\n", d1,d2,d3,d4,t;
  if (t>0) printf "share:  CPU0=%.1f%%  CPU1=%.1f%%  CPU2=%.1f%%  CPU3=%.1f%%\n", d1*100/t, d2*100/t, d3*100/t, d4*100/t;
}'
