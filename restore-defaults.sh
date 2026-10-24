#!/bin/sh
# restore-defaults.sh - undo the X-WRT speed tuning on a Tenda BE12 Pro.
#
# Usage (on the router):
#   scp restore-defaults.sh root@192.168.1.1:/tmp/
#   ssh root@192.168.1.1 'sh /tmp/restore-defaults.sh'
#
# Requires: root on the router.

echo "==> Restoring /etc/rc.local"
[ -f /etc/rc.local.bak ] && cp /etc/rc.local.bak /etc/rc.local && chmod 755 /etc/rc.local

echo "==> Restoring network UCI"
[ -f /etc/config/network.bak ] && cp /etc/config/network.bak /etc/config/network
uci -q delete network.globals.packet_steering
uci -q delete network.globals.steering_flows
uci commit network

echo "==> Restoring natcap log level"
[ -f /etc/config/natcapd.bak ] && cp /etc/config/natcapd.bak /etc/config/natcapd
echo debug=3 > /dev/natcap_ctl 2>/dev/null || true

echo "==> Removing /etc/init.d/router-speed"
/etc/init.d/router-speed disable 2>/dev/null || true
rm -f /etc/init.d/router-speed
rm -f /etc/rc.d/*router-speed

echo "==> Re-applying stock packet steering"
/etc/init.d/packet_steering reload

echo "==> Done. Reboot to fully return to defaults."
