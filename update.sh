#!/bin/bash
chattr -i /etc/resolv.conf 2>/dev/null
chattr -i /etc/sysctl.conf 2>/dev/null
wget -q https://raw.githubusercontent.com/arivpnstores/udp-zivpn/main/autodel.sh -O /root/autodel.sh
chmod +x /root/autodel.sh
echo "🔄 Updating ZiVPN Manager..."
wget -q https://raw.githubusercontent.com/arivpnstores/udp-zivpn/main/install.sh \
-O /usr/local/bin/install.sh
chmod +x /usr/local/bin/install.sh
wget -q https://raw.githubusercontent.com/arivpnstores/udp-zivpn/main/zivpn-manager \
-O /usr/local/bin/zivpn-manager
chmod +x /usr/local/bin/zivpn-manager
wget -q https://raw.githubusercontent.com/arivpnstores/udp-zivpn/main/zivpn_helper.sh \
-O /usr/local/bin/zivpn_helper.sh
chmod +x /usr/local/bin/zivpn_helper.sh
wget -q https://raw.githubusercontent.com/arivpnstores/udp-zivpn/main/update.sh \
-O /usr/local/bin/update-manager
chmod +x /usr/local/bin/update-manager
echo "🎉 ZiVPN Update completed successfully."
echo "Setting up expiry check cron job..."
mkdir -p /etc/zivpn
cat <<'EOF' > /etc/zivpn/expire_check.sh
DB_FILE="/etc/zivpn/users.db"
CONFIG_FILE="/etc/zivpn/config.json"
TMP_DB_FILE="${DB_FILE}.tmp"
LOCK_FILE="${DB_FILE}.lock"
CURRENT_DATE=$(date +%s)
SERVICE_RESTART_NEEDED=false
LOCK_FD=""
acquire_lock() {
exec {lock_fd}>"$LOCK_FILE" || return 1
if ! flock -x "$lock_fd"; then
eval "exec ${lock_fd}>&-"
return 1
fi
LOCK_FD="$lock_fd"
}
release_lock() {
[ -n "$LOCK_FD" ] || return 0
flock -u "$LOCK_FD" 2>/dev/null || true
eval "exec ${LOCK_FD}>&-"
LOCK_FD=""
}
cleanup() {
[ -n "$TMP_DB_FILE" ] && rm -f "$TMP_DB_FILE"
release_lock
}
trap cleanup EXIT
if [ ! -f "$DB_FILE" ]; then exit 0; fi
if ! acquire_lock; then exit 1; fi
> "$TMP_DB_FILE"
while IFS=':' read -r password expiry_date; do
if [[ -z "$password" ]]; then continue; fi
if ! [[ "$expiry_date" =~ ^[0-9]+$ ]]; then
echo "${password}:${expiry_date}" >> "$TMP_DB_FILE"
continue
fi
if [ "$expiry_date" -le "$CURRENT_DATE" ]; then
echo "User '${password}' has expired. Deleting permanently."
jq --arg pass "$password" 'del(.auth.config[] | select(. == $pass))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
SERVICE_RESTART_NEEDED=true
else
echo "${password}:${expiry_date}" >> "$TMP_DB_FILE"
fi
done < "$DB_FILE"
mv "$TMP_DB_FILE" "$DB_FILE"
TMP_DB_FILE=""
if [ "$SERVICE_RESTART_NEEDED" = true ]; then
echo "User(s) removed, but skipping service restart to avoid disconnecting active users."
echo "Use menu 15 or 16 for manual cleanup with restart when needed."
fi
exit 0
EOF
chmod +x /etc/zivpn/expire_check.sh
echo "🧩 Checking ZiVPN NAT rule..."
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y iptables-persistent netfilter-persistent >/dev/null 2>&1 || true
systemctl enable netfilter-persistent >/dev/null 2>&1 || true
IFACE="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
if [ -z "${IFACE:-}" ]; then
echo "⚠️  No default interface detected. Skip NAT."
else
if iptables -t nat -C PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null; then
echo "✅ NAT rule already exists."
else
echo "➕ NAT rule missing. Adding..."
iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667
fi
echo "🧹 Cleaning duplicate NAT rules (keep one)..."
while true; do
COUNT="$(iptables -t nat -S PREROUTING 2>/dev/null | grep -c -- "--dport 6000:19999" || true)"
if [ "${COUNT:-0}" -le 1 ]; then
break
fi
iptables -t nat -D PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null || break
done
if netfilter-persistent save >/dev/null 2>&1; then
echo "✅ netfilter-persistent saved."
else
echo "⚠️  Failed to save netfilter-persistent (check permission/service)."
fi
fi
ZIVPN_CRON_TMP="$(mktemp)"
{
crontab -l 2>/dev/null || true
} | grep -v '# zivpn-license-check' \
| grep -v '# zivpn-auto-update' \
| grep -v '# zivpn-auto-start' \
| grep -v '# zivpn-expiry-check' \
| grep -v '# zivpn-autodel' \
| grep -v '# zivpn-auto-backup' \
| grep -v '#ZIVPN_AUTO_REBOOT' \
| grep -vF 'zivpn_helper.sh backup' \
| grep -vF '0 1 * * * /sbin/reboot' \
| grep -vF '/root/autodel.sh' \
| grep -vF '/etc/zivpn/expire_check.sh' \
| grep -vF '/etc/zivpn/license_checker.sh' \
| grep -vF '/usr/local/bin/update-manager' \
| grep -v 'systemctl is-active --quiet zivpn || systemctl start zivpn' \
> "$ZIVPN_CRON_TMP" || true
cat <<'EOF' >> "$ZIVPN_CRON_TMP"
*/5 * * * * /etc/zivpn/license_checker.sh # zivpn-license-check
0 4 * * * /usr/local/bin/update-manager # zivpn-auto-update
*/2 * * * * systemctl is-active --quiet zivpn || systemctl start zivpn # zivpn-auto-start
0 * * * * /usr/local/bin/zivpn_helper.sh backup >> /var/log/zivpn_backup.log 2>&1
0 1 * * * /sbin/reboot
* * * * * /etc/zivpn/expire_check.sh # zivpn-expiry-check
0 0 * * * /bin/bash /root/autodel.sh # zivpn-autodel
EOF
crontab "$ZIVPN_CRON_TMP"
rm -f "$ZIVPN_CRON_TMP"
systemctl restart cron || true
echo "✅ Crontab ZiVPN: license */5, auto-update 04:00, auto-start, backup, reboot 01:00, expiry, autodel"
/usr/local/bin/zivpn-manager
