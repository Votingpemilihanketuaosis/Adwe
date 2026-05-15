#!/bin/bash
echo -e "Uninstalling ZiVPN Old..."
svc="zivpn.service"
systemctl stop $svc 1>/dev/null 2>/dev/null
systemctl disable $svc 1>/dev/null 2>/dev/null
rm -f /etc/systemd/system/$svc 1>/dev/null 2>/dev/null
echo "Removed service $svc"
if pgrep "zivpn" >/dev/null; then
killall zivpn 1>/dev/null 2>/dev/null
echo "Killed running zivpn processes"
fi
[ -d /etc/zivpn ] && rm -rf /etc/zivpn
[ -f /usr/local/bin/zivpn ] && rm -f /usr/local/bin/zivpn
if ! pgrep "zivpn" >/dev/null; then
echo "Server Stopped"
else
echo "Server Still Running"
fi
if [ ! -f /usr/local/bin/zivpn ]; then
echo "Files successfully removed"
else
echo "Some files remain, try again"
fi
echo "Cleaning Cache"
echo 3 > /proc/sys/vm/drop_caches
sysctl -w vm.drop_caches=3
echo -e "Done."
