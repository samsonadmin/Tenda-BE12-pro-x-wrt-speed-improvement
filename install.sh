#!/bin/sh
# install.sh - apply the X-WRT speed tuning on a Tenda BE12 Pro running X-WRT.
#
# Usage (on the router):
#   scp router-speed install.sh root@192.168.1.1:/tmp/
#   ssh root@192.168.1.1 'sh /tmp/install.sh'
#
# Requires: root on the router.

set -e

echo "==> Backing up current configuration"
[ -f /etc/rc.local ] && cp /etc/rc.local /etc/rc.local.bak
[ -f /etc/config/network ] && cp /etc/config/network /etc/config/network.bak
[ -f /etc/config/natcapd ] && cp /etc/config/natcapd /etc/config/natcapd.bak

echo "==> Installing /etc/init.d/router-speed"
cp /tmp/router-speed /etc/init.d/router-speed
chmod 755 /etc/init.d/router-speed
/etc/init.d/router-speed enable

echo "==> Enabling RPS across all CPUs (durable, firmware-native)"
# This is the key part: /etc/init.d/packet_steering rewrites rps_cpus on
# every network/firewall reload and every interface event. Setting the UCI
# options makes *it* write the values we want instead of overwriting ours.
#   packet_steering=2 -> "Enabled (all CPUs)"  (LuCI: Network > Interfaces > Global)
#   steering_flows    -> size of the RPS flow steering table
uci set network.globals.packet_steering='2'
uci set network.globals.steering_flows='2048'
uci commit network

echo "==> Silencing natcap kernel log spam (debug 3 = error|warn -> 1 = error only)"
uci set natcapd.default.debug='1'
uci commit natcapd
echo debug=1 > /dev/natcap_ctl 2>/dev/null || true

echo "==> Pointing /etc/rc.local at the init script"
cat > /etc/rc.local <<'EOF'
# Router throughput tuning.
#
# The actual settings live in /etc/init.d/router-speed so they are re-applied
# whenever the network stack reloads (interface up/down, firewall reload),
# not only at boot.
#
# See: https://github.com/samsonadmin/Tenda-BE12-pro-x-wrt-speed-improvement

/etc/init.d/router-speed reload

/etc/init.d/cloudflared start
exit 0
EOF
chmod 755 /etc/rc.local

echo "==> Applying now"
/etc/init.d/packet_steering reload
/etc/init.d/router-speed start

echo "==> Verifying"
for i in eth0 eth1 eth2; do
	printf '  %-6s rps_cpus=%-3s rps_flow_cnt=%s\n' \
		"$i" \
		"$(cat /sys/class/net/$i/queues/rx-0/rps_cpus)" \
		"$(cat /sys/class/net/$i/queues/rx-0/rps_flow_cnt)"
done
for i in eth0 eth1 eth2 br-lan; do
	printf '  %-7s gro=%-4s gso=%s\n' \
		"$i" \
		"$(ethtool -k "$i" 2>/dev/null | awk '/generic-receive-offload/{print $2}')" \
		"$(ethtool -k "$i" 2>/dev/null | awk '/generic-segmentation-offload/{print $2}')"
done

echo "==> Done. Reboot to confirm persistence, then re-run the speed test."
