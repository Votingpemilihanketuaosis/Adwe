#!/bin/bash
set -e
CACHE_DIR="/etc/zivpn"
IP_FILE="$CACHE_DIR/ip.txt"
ISP_FILE="$CACHE_DIR/isp.txt"
mkdir -p "$CACHE_DIR"
IP=$(curl -4 -s ifconfig.me || curl -4 -s icanhazip.com)
ISP=$(curl -s ipinfo.io/org | cut -d " " -f 2-10)
IP=${IP:-N/A}
ISP=${ISP:-N/A}
echo "$IP"  > "$IP_FILE"
echo "$ISP" > "$ISP_FILE"
chmod 644 "$IP_FILE" "$ISP_FILE"
echo "================================="
echo "IP  : $IP"
echo "ISP : $ISP"
echo "Saved:"
echo " - $IP_FILE"
echo " - $ISP_FILE"
echo "================================="
echo
echo "================================="
echo "🚀 MEMULAI INSTALASI ZIVPN MANAGER"
echo "================================="
echo
sleep 2
wget -q https://raw.githubusercontent.com/arivpnstores/udp-zivpn/main/zivpn-manager -O /usr/local/bin/zivpn-manager
chmod +x /usr/local/bin/zivpn-manager
/usr/local/bin/zivpn-manager
