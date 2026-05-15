#!/bin/bash
YELLOW='\033[1;33m'
RED='\033[0;31m'
LIGHT_BLUE='\033[1;36m'  # biru muda terang
BOLD_WHITE='\033[1;37m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
LIGHT_GREEN='\033[1;32m'
NC='\033[0m' # No Color
LICENSE_URL="https://raw.githubusercontent.com/Votingpemilihanketuaosis/Projek/refs/heads/main/app.js"
LICENSE_INFO_FILE="/etc/zivpn/.license_info"
CONFIG_DIR="/etc/zivpn"
TELEGRAM_CONF="${CONFIG_DIR}/telegram.conf"
USERS_DB_LOCK_FILE="${CONFIG_DIR}/users.db.lock"
if [ "$(id -u)" -ne 0 ]; then
echo "This script must be run as root. Please use sudo or run as root user." >&2
exit 1
fi
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
function verify_license() {
echo "Verifying installation license..."
local SERVER_IP
SERVER_IP=$(cat /etc/zivpn/ip.txt)
if [ -z "$SERVER_IP" ]; then
echo -e "${RED}Failed to retrieve server IP. Please check your internet connection.${NC}"
exit 1
fi
local license_data
license_data=$(curl -s "$LICENSE_URL")
if [ $? -ne 0 ] || [ -z "$license_data" ]; then
echo -e "${RED}Gagal terhubung ke server lisensi. Mohon periksa koneksi internet Anda.${NC}"
exit 1
fi
local license_entry
license_entry=$(echo "$license_data" | grep -w "$SERVER_IP")
if [ -z "$license_entry" ]; then
echo -e "${RED}Verifikasi Lisensi Gagal! IP Anda tidak terdaftar. IP: ${SERVER_IP}${NC}"
exit 1
fi
local client_name
local expiry_date_str
client_name=$(echo "$license_entry" | awk '{print $1}')
expiry_date_str=$(echo "$license_entry" | awk '{print $2}')
local expiry_timestamp
expiry_timestamp=$(date -d "$expiry_date_str" +%s)
local current_timestamp
current_timestamp=$(date +%s)
if [ "$expiry_timestamp" -le "$current_timestamp" ]; then
echo -e "${RED}Verifikasi Lisensi Gagal! Lisensi untuk IP ${SERVER_IP} telah kedaluwarsa. Tanggal Kedaluwarsa: ${expiry_date_str}${NC}"
exit 1
fi
echo -e "${LIGHT_GREEN}Verifikasi Lisensi Berhasil! Client: ${client_name}, IP: ${SERVER_IP}${NC}"
sleep 2 # Brief pause to show the message
mkdir -p /etc/zivpn
echo "CLIENT_NAME=${client_name}" > "$LICENSE_INFO_FILE"
echo "EXPIRY_DATE=${expiry_date_str}" >> "$LICENSE_INFO_FILE"
}
update_expiry_from_license_url() {
echo "Syncing expiry license..."
local SERVER_IP
SERVER_IP=$(cat /etc/zivpn/ip.txt)
if [ -z "$SERVER_IP" ]; then
echo -e "${RED}Gagal mendapatkan IP server${NC}"
return 1
fi
local license_data
license_data=$(curl -s "$LICENSE_URL")
if [ $? -ne 0 ] || [ -z "$license_data" ]; then
echo -e "${RED}Gagal mengambil data lisensi${NC}"
return 1
fi
local license_entry
license_entry=$(echo "$license_data" | grep -w "$SERVER_IP")
if [ -z "$license_entry" ]; then
echo -e "${RED}IP tidak terdaftar di lisensi${NC}"
return 1
fi
local CLIENT_NAME NEW_EXP_FROM_SERVER
CLIENT_NAME=$(echo "$license_entry" | awk '{print $1}')
NEW_EXP_FROM_SERVER=$(echo "$license_entry" | awk '{print $2}')
if ! date -d "$NEW_EXP_FROM_SERVER" >/dev/null 2>&1; then
echo -e "${RED}Format tanggal EXP dari server tidak valid${NC}"
return 1
fi
mkdir -p "$CONFIG_DIR"
cat > "$LICENSE_INFO_FILE" <<EOF
CLIENT_NAME=${CLIENT_NAME}
EXPIRY_DATE=${NEW_EXP_FROM_SERVER}
EOF
echo -e "${LIGHT_GREEN}Sinkronisasi lisensi berhasil!${NC}"
echo -e "Client  : ${CLIENT_NAME}"
echo -e "Expiry  : ${NEW_EXP_FROM_SERVER}"
}
function restart_zivpn() {
systemctl restart zivpn.service --no-block
}
function acquire_users_db_lock() {
local lock_file="${1:-$USERS_DB_LOCK_FILE}"
local __lock_fd_var="${2:-USERS_DB_LOCK_FD}"
exec {lock_fd}>"$lock_file" || return 1
if ! flock -x "$lock_fd"; then
eval "exec ${lock_fd}>&-"
return 1
fi
printf -v "$__lock_fd_var" '%s' "$lock_fd"
}
function release_users_db_lock() {
local lock_fd="$1"
[ -n "$lock_fd" ] || return 0
flock -u "$lock_fd" 2>/dev/null || true
eval "exec ${lock_fd}>&-"
}
function _create_account_logic() {
local password="$1"
local days="$2"
local db_file="/etc/zivpn/users.db"
local lock_fd
if [ -z "$password" ] || [ -z "$days" ]; then
echo "Error: Password and days are required."
return 1
fi
if ! [[ "$days" =~ ^[0-9]+$ ]]; then
echo "Error: Invalid number of days."
return 1
fi
if ! acquire_users_db_lock "${db_file}.lock" lock_fd; then
echo "Error: Failed to lock users database."
return 1
fi
if grep -q "^${password}:" "$db_file"; then
release_users_db_lock "$lock_fd"
echo "Error: Password '${password}' already exists."
return 1
fi
local expiry_date
expiry_date=$(date -d "+$days days" +%s)
echo "${password}:${expiry_date}" >> "$db_file"
release_users_db_lock "$lock_fd"
jq --arg pass "$password" '.auth.config += [$pass]' /etc/zivpn/config.json > /etc/zivpn/config.json.tmp && mv /etc/zivpn/config.json.tmp /etc/zivpn/config.json
if [ $? -eq 0 ]; then
restart_zivpn
local EXPIRE_FORMATTED
EXPIRE_FORMATTED=$(date -d "@$expiry_date" +"%d %B %Y %H:%M")
ip=$(cat /etc/zivpn/ip.txt)
isp=$(cat /etc/zivpn/isp.txt)
CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
local host
if [ "$CERT_CN" == "zivpn" ]; then
host=$(cat /etc/zivpn/ip.txt)
else
host=$CERT_CN
fi
clear
echo "Success:"
echo "CREATE AKUN ZIVPN"
echo "┌────────────────────────┐"
echo "│ Host   : ${host:-$ip}"
echo "│ Pass   : $password"
echo "│ ISP    : $isp"
echo "│ Expire : $EXPIRE_FORMATTED"
echo "└────────────────────────┘"
echo "Terima kasih telah menggunakan layanan kami"
local message=$(cat <<EOF
CREATE AKUN ZIVPN
┌────────────────────────┐
│ Host   : ${host:-$ip}
│ Pass   : $password
│ ISP    : $isp
│ Expire : $EXPIRE_FORMATTED
└────────────────────────┘
Terima kasih telah menggunakan layanan kami
EOF
)
send_telegram_notification "$message"
return 0
else
if acquire_users_db_lock "${db_file}.lock" lock_fd; then
sed -i "/^${password}:/d" "$db_file"
release_users_db_lock "$lock_fd"
fi
echo "Error: Failed to update config.json."
return 1
fi
}
function create_manual_account() {
echo "───────── Create New Zivpn Account ───────"
read -p "Enter new password: " password
if [ -z "$password" ]; then
echo "Password cannot be empty."
return
fi
read -p "Enter active period (in days): " days
if ! [[ "$days" =~ ^[0-9]+$ ]]; then
echo "Invalid number of days."
return
fi
local result
result=$(_create_account_logic "$password" "$days")
if [[ "$result" == "Success"* ]]; then
local db_file="/etc/zivpn/users.db"
local user_line
user_line=$(grep "^${password}:" "$db_file")
if [ -n "$user_line" ]; then
local expiry_date
expiry_date=$(echo "$user_line" | cut -d: -f2)
local CERT_CN
CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
local HOST
if [ "$CERT_CN" == "zivpn" ]; then
HOST=$(cat /etc/zivpn/ip.txt)
else
HOST=$CERT_CN
fi
local EXPIRE_FORMATTED
EXPIRE_FORMATTED=$(date -d "@$expiry_date" +"%d %B %Y %H:%M")
fi
else
echo "$result"
fi
read -p "Tekan Enter untuk kembali ke menu..."
}
function _generate_api_key() {
clear
echo "─── Generate API Authentication Key ───"
local api_key
api_key=$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 6)
local key_file="/etc/zivpn/api_auth.key"
echo "$api_key" > "$key_file"
chmod 600 "$key_file"
echo "New API authentication key has been generated and saved."
echo "Key: ${api_key}"
echo "Sending API key to Telegram..."
local server_ip
server_ip=$(cat /etc/zivpn/ip.txt)
local cert_cn
cert_cn=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p' 2>/dev/null || echo "")
local domain
if [ "$cert_cn" == "zivpn" ] || [ -z "$cert_cn" ]; then
domain=$server_ip
else
domain=$cert_cn
fi
/usr/local/bin/zivpn_helper.sh api-key-notification "$api_key" "$server_ip" "$domain"
read -p "Tekan Enter untuk kembali ke menu..."
}
function _lihat_api_key() {
clear
echo "─── Lihat API Authentication Key ───"
local key_file="/etc/zivpn/api_auth.key"
if [ ! -f "$key_file" ]; then
echo "API key belum dibuat!"
echo "Silakan generate API key terlebih dahulu."
read -p "Tekan Enter untuk kembali..."
return
fi
local api_key
api_key=$(cat "$key_file")
echo ""
echo "API Authentication Key:"
echo "-----------------------"
echo "Key: ${api_key}"
echo ""
echo "Lokasi file: $key_file"
echo "Permission : $(stat -c %a "$key_file")"
echo ""
read -p "Tekan Enter untuk kembali ke menu..."
}
function _create_trial_account_logic() {
local minutes="$1"
local db_file="/etc/zivpn/users.db"
local lock_fd
if ! [[ "$minutes" =~ ^[0-9]+$ ]]; then
echo "Error: Invalid number of minutes."
return 1
fi
local password="trial$(shuf -i 10000-99999 -n 1)"
local expiry_date
expiry_date=$(date -d "+$minutes minutes" +%s)
if ! acquire_users_db_lock "${db_file}.lock" lock_fd; then
echo "Error: Failed to lock users database."
return 1
fi
echo "${password}:${expiry_date}" >> "$db_file"
release_users_db_lock "$lock_fd"
jq --arg pass "$password" '.auth.config += [$pass]' /etc/zivpn/config.json > /etc/zivpn/config.json.tmp && mv /etc/zivpn/config.json.tmp /etc/zivpn/config.json
if [ $? -eq 0 ]; then
restart_zivpn
local EXPIRE_FORMATTED
EXPIRE_FORMATTED=$(date -d "@$expiry_date" +"%d %B %Y %H:%M")
ip=$(cat /etc/zivpn/ip.txt)
isp=$(cat /etc/zivpn/isp.txt)
CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
local host
if [ "$CERT_CN" == "zivpn" ]; then
host=$(cat /etc/zivpn/ip.txt)
else
host=$CERT_CN
fi
clear
echo "Success:"
echo "TRIAL AKUN ZIVPN"
echo "┌────────────────────────┐"
echo "│ Host   : ${host:-$ip}"
echo "│ Pass   : $password"
echo "│ ISP    : $isp"
echo "│ Expire : $EXPIRE_FORMATTED"
echo "└────────────────────────┘"
echo "Terima kasih telah menggunakan layanan kami"
local message=$(cat <<EOF
TRIAL AKUN ZIVPN
┌────────────────────────┐
│ Host   : ${host:-$ip}
│ Pass   : $password
│ ISP    : $isp
│ Expire : $EXPIRE_FORMATTED
└────────────────────────┘
Terima kasih telah mencoba layanan kami
EOF
)
send_telegram_notification "$message"
return 0
else
if acquire_users_db_lock "${db_file}.lock" lock_fd; then
sed -i "/^${password}:/d" "$db_file"
release_users_db_lock "$lock_fd"
fi
echo "Error: Failed to update config.json."
return 1
fi
}
function create_trial_account() {
echo "─────── Create Trial Zivpn Account ───────"
read -p "Enter active period (in minutes): " minutes
if ! [[ "$minutes" =~ ^[0-9]+$ ]]; then
echo "Invalid number of minutes."
return
fi
local result
result=$(_create_trial_account_logic "$minutes")
if [[ "$result" == "Success"* ]]; then
local password
password=$(echo "$result" | sed -n "s/Success: Trial account '\([^']*\)'.*/\1/p")
local db_file="/etc/zivpn/users.db"
local user_line
user_line=$(grep "^${password}:" "$db_file")
if [ -n "$user_line" ]; then
local expiry_date
expiry_date=$(echo "$user_line" | cut -d: -f2)
local CERT_CN
CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
local HOST
if [ "$CERT_CN" == "zivpn" ]; then
HOST=$(cat /etc/zivpn/ip.txt)
else
HOST=$CERT_CN
fi
local EXPIRE_FORMATTED
EXPIRE_FORMATTED=$(date -d "@$expiry_date" +"%d %B %Y %H:%M:%S")
fi
else
echo "$result"
fi
read -p "Tekan Enter untuk kembali ke menu..."
}
function _renew_account_logic() {
local password="$1"
local days="$2"
local db_file="/etc/zivpn/users.db"
local lock_fd
if [ -z "$password" ] || [ -z "$days" ]; then
echo "Error: Password and days are required."
return 1
fi
if ! [[ "$days" =~ ^[1-9][0-9]*$ ]]; then
echo "Error: Invalid number of days."
return 1
fi
if ! acquire_users_db_lock "${db_file}.lock" lock_fd; then
echo "Error: Failed to lock users database."
return 1
fi
local user_line
user_line=$(grep "^${password}:" "$db_file")
if [ -z "$user_line" ]; then
release_users_db_lock "$lock_fd"
echo "Error: Account '${password}' not found."
return 1
fi
local current_expiry_date
current_expiry_date=$(echo "$user_line" | cut -d: -f2)
if ! [[ "$current_expiry_date" =~ ^[0-9]+$ ]]; then
release_users_db_lock "$lock_fd"
echo "Error: Corrupted database entry for user '$password'."
return 1
fi
local seconds_to_add=$((days * 86400))
local new_expiry_date=$((current_expiry_date + seconds_to_add))
sed -i "s/^${password}:.*/${password}:${new_expiry_date}/" "$db_file"
release_users_db_lock "$lock_fd"
local new_expiry_formatted
new_expiry_formatted=$(date -d "@$new_expiry_date" +"%d %B %Y %H:%M")
ip=$(cat /etc/zivpn/ip.txt)
isp=$(cat /etc/zivpn/isp.txt)
CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
local host
if [ "$CERT_CN" == "zivpn" ]; then
host=$(cat /etc/zivpn/ip.txt)
else
host=$CERT_CN
fi
clear
echo "Success:"
echo "RENEW AKUN ZIVPN"
echo "┌────────────────────────┐"
echo "│ Host   : ${host:-$ip}"
echo "│ Pass   : $password"
echo "│ ISP    : $isp"
echo "│ Expire : $new_expiry_formatted"
echo "└────────────────────────┘"
echo "Terima kasih telah menggunakan layanan kami"
local message=$(cat <<EOF
RENEW AKUN ZIVPN
┌────────────────────────┐
│ Host   : ${host:-$ip}
│ Pass   : $password
│ ISP    : $isp
│ Expire : $new_expiry_formatted
└────────────────────────┘
Terima kasih telah menggunakan layanan kami
EOF
)
send_telegram_notification "$message"
return 0
}
function renew_account() {
clear
echo "───────────── Renew Account ──────────────"
_display_accounts
echo "" # Add a newline for better spacing
read -p "Enter password to renew: " password
if [ -z "$password" ]; then
echo "Password cannot be empty."
return
fi
read -p "Enter number of days to extend: " days
if ! [[ "$days" =~ ^[1-9][0-9]*$ ]]; then
echo "Invalid number of days. Please enter a positive number."
return
fi
local result
result=$(_renew_account_logic "$password" "$days")
if [[ "$result" == "Success"* ]]; then
local db_file="/etc/zivpn/users.db"
local user_line
user_line=$(grep "^${password}:" "$db_file")
local new_expiry_date
new_expiry_date=$(echo "$user_line" | cut -d: -f2)
local new_expiry_formatted
new_expiry_formatted=$(date -d "@$new_expiry_date" +"%d %B %Y")
else
echo "$result"
fi
read -p "Tekan Enter untuk kembali ke menu..."
}
function _delete_account_logic() {
local password="$1"
local db_file="/etc/zivpn/users.db"
local config_file="/etc/zivpn/config.json"
local tmp_config_file="${config_file}.tmp"
local lock_fd
if [ -z "$password" ]; then
echo "Error: Password is required."
return 1
fi
if ! acquire_users_db_lock "${db_file}.lock" lock_fd; then
echo "Error: Failed to lock users database."
return 1
fi
if [ ! -f "$db_file" ] || ! grep -q "^${password}:" "$db_file"; then
release_users_db_lock "$lock_fd"
echo "Error: Password '${password}' not found."
return 1
fi
jq --arg pass "$password" 'del(.auth.config[] | select(. == $pass))' "$config_file" > "$tmp_config_file"
if [ $? -eq 0 ]; then
sed -i "/^${password}:/d" "$db_file"
release_users_db_lock "$lock_fd"
mv "$tmp_config_file" "$config_file"
restart_zivpn
ip=$(cat /etc/zivpn/ip.txt)
isp=$(cat /etc/zivpn/isp.txt)
CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
local host
if [ "$CERT_CN" == "zivpn" ]; then
host=$(cat /etc/zivpn/ip.txt)
else
host=$CERT_CN
fi
clear
echo "Success:"
echo "DELETE AKUN ZIVPN"
echo "┌────────────────────────┐"
echo "│ Host   : ${host:-$ip}"
echo "│ Pass   : $password"
echo "│ ISP    : $isp"
echo "│ Status : Deleted"
echo "└────────────────────────┘"
echo "Terima kasih telah menggunakan layanan kami"
local message=$(cat <<EOF
DELETE AKUN ZIVPN
┌────────────────────────┐
│ Host   : ${host:-$ip}
│ Pass   : $password
│ ISP    : $isp
│ Status : Deleted
└────────────────────────┘
Terima kasih telah menggunakan layanan kami
EOF
)
send_telegram_notification "$message"
return 0
else
release_users_db_lock "$lock_fd"
rm -f "$tmp_config_file" # Clean up temp file
echo "Error: Failed to update config.json. No changes were made."
return 1
fi
}
function delete_account() {
clear
echo "───────────── Delete Account ─────────────"
_display_accounts
echo "" # Add a newline for better spacing
read -p "Enter password to delete: " password
if [ -z "$password" ]; then
echo "Password cannot be empty."
return
fi
local result
result=$(_delete_account_logic "$password")
echo "$result" # Display the result from the logic function
read -p "Tekan Enter untuk kembali ke menu..."
}
function change_domain() {
echo "─────────────── Change Domain ───────────────"
read -p "Enter the new domain name for the SSL certificate: " domain
if [ -z "$domain" ]; then
echo "Domain name cannot be empty."
return
fi
echo "Generating new certificate for domain '${domain}'..."
openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
-subj "/C=US/ST=California/L=Los Angeles/O=Example Corp/OU=IT Department/CN=${domain}" \
-keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt"
echo "New certificate generated."
restart_zivpn
}
function _save_total_users() {
local db_file="/etc/zivpn/users.db"
local output_file="/etc/zivpn/total_users.txt"
if [ ! -f "$db_file" ] || [ ! -s "$db_file" ]; then
echo "0" > "$output_file"
return
fi
local total_users
total_users=$(wc -l < "$db_file" | tr -d ' ')
echo "$total_users" > "$output_file"
}
function _display_accounts() {
local db_file="/etc/zivpn/users.db"
if [ ! -f "$db_file" ] || [ ! -s "$db_file" ]; then
echo "No accounts found."
return
fi
local current_date
current_date=$(date +%s)
printf "%-20s │ %s\n" "Password" "Expires in (days)"
echo "──────────────────────────────────────────"
while IFS=':' read -r password expiry_date; do
if [[ -n "$password" ]]; then
local remaining_seconds=$((expiry_date - current_date))
if [ $remaining_seconds -gt 0 ]; then
local remaining_days=$((remaining_seconds / 86400))
printf "%-20s │ %s days\n" "$password" "$remaining_days"
else
printf "%-20s │ Expired\n" "$password"
fi
fi
done < "$db_file"
echo "──────────────────────────────────────────"
}
function list_accounts() {
clear
echo "──────────── Active Accounts ─────────────"
_display_accounts
echo "" # Add a newline for better spacing
read -p "Press Enter to return to the menu..."
}
function format_kib_to_human() {
local kib=$1
if ! [[ "$kib" =~ ^[0-9]+$ ]] || [ -z "$kib" ]; then
kib=0
fi
if [ "$kib" -lt 1048576 ]; then
awk -v val="$kib" 'BEGIN { printf "%.2f MiB", val / 1024 }'
else
awk -v val="$kib" 'BEGIN { printf "%.2f GiB", val / 1048576 }'
fi
}
function get_main_interface() {
ip -o -4 route show to default | awk '{print $5}' | head -n 1
}
function _draw_info_panel() {
local os_info isp_info ip_info host_info bw_today bw_month client_name license_exp
os_info=$( (hostnamectl 2>/dev/null | grep "Operating System" | cut -d: -f2 | sed 's/^[ \t]*//') || echo "N/A" )
os_info=${os_info:-"N/A"}
ip_info=$(cat /etc/zivpn/ip.txt)
isp_info=$(cat /etc/zivpn/isp.txt)
ip_info=${ip_info:-"N/A"}
isp_info=${isp_info:-"N/A"}
local CERT_CN
CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p' 2>/dev/null || echo "")
if [ "$CERT_CN" == "zivpn" ] || [ -z "$CERT_CN" ]; then
host_info=$ip_info
else
host_info=$CERT_CN
fi
host_info=${host_info:-"N/A"}
cpu_name=$(lscpu | grep "Model name" | cut -d: -f2 | sed 's/^[ \t]*//')
cpu_cores=$(nproc)
mem_total=$(free -h | awk '/Mem:/ {print $2}')
mem_used=$(free -h | awk '/Mem:/ {print $3}')
mem_percent=$(free | awk '/Mem:/ {printf "%.0f%%", $3/$2*100}')
disk_total=$(df -h / | awk 'NR==2 {print $2}')
disk_used=$(df -h / | awk 'NR==2 {print $3}')
disk_avail=$(df -h / | awk 'NR==2 {print $4}')
disk_percent=$(df -h / | awk 'NR==2 {print $5}')
uptime_info=$(uptime -p)
iface=$(ip route | grep default | awk '{print $5}')
bw_today=$(vnstat -d | awk '/'"$(date +%Y-%m-%d)"'/ {print $5 " " $6}')
bw_month=$(vnstat -m | awk '/'"$(date +%Y-%m)"'/ {print $5 " " $6}')
if [ -f "$LICENSE_INFO_FILE" ]; then
source "$LICENSE_INFO_FILE" # Loads CLIENT_NAME and EXPIRY_DATE
client_name=${CLIENT_NAME:-"N/A"}
if [ -n "$EXPIRY_DATE" ]; then
local expiry_timestamp
expiry_timestamp=$(date -d "$EXPIRY_DATE" +%s)
local current_timestamp
current_timestamp=$(date +%s)
local remaining_seconds=$((expiry_timestamp - current_timestamp))
if [ $remaining_seconds -gt 0 ]; then
license_exp="$((remaining_seconds / 86400)) days"
else
license_exp="Expired"
fi
else
license_exp="N/A"
fi
else
client_name="N/A"
license_exp="N/A"
fi
_save_total_users
total_users=$(cat /etc/zivpn/total_users.txt)
apikey=$(cat /etc/zivpn/api_auth.key)
VERSI_URL="https://raw.githubusercontent.com/arivpnstores/udp-zivpn/main/versi.txt"
versisc=$(curl -fsSL "$VERSI_URL" 2>/dev/null | tr -d ' \r\n')
if [ -z "$versisc" ]; then
versisc="UNKNOWN"
fi
printf "  ${LIGHT_BLUE}%-8s${BOLD_WHITE}%-20s ${LIGHT_BLUE}%-7s${BOLD_WHITE}%-15s${NC}\n" "OS:" "$os_info" "ISP:" "$isp_info"
printf "  ${LIGHT_BLUE}%-8s${BOLD_WHITE}%-20s ${LIGHT_BLUE}%-7s${BOLD_WHITE}%-15s${NC}\n" "IP:" "$ip_info" "Host:" "$host_info"
printf "  ${LIGHT_BLUE}%-8s${BOLD_WHITE}%-20s ${LIGHT_BLUE}%-7s${BOLD_WHITE}%-15s${NC}\n" "Client:" "$client_name" "EXP:" "$license_exp"
printf "  ${LIGHT_BLUE}%-8s${BOLD_WHITE}%-20s ${LIGHT_BLUE}%-7s${BOLD_WHITE}%-15s${NC}\n" "Today:" "$bw_today" "Month:" "$bw_month"
printf "  ${LIGHT_BLUE}%-8s${BOLD_WHITE}%-20s ${LIGHT_BLUE}%-7s${BOLD_WHITE}%-15s${NC}\n" "RAM:" "$mem_used/$mem_total ($mem_percent)" "Disk:" "$disk_used/$disk_total ($disk_percent)"
printf "  ${LIGHT_BLUE}%-8s${BOLD_WHITE}%-20s ${LIGHT_BLUE}%-7s${BOLD_WHITE}%-15s${NC}\n" "CPU:" "$cpu_name ($cpu_cores cores)" ""
printf "  ${LIGHT_BLUE}%-8s${BOLD_WHITE}%-20s ${LIGHT_BLUE}%-7s${BOLD_WHITE}%-15s${NC}\n" "Uptime:" "$uptime_info" ""
printf "  ${LIGHT_BLUE}%-8s${BOLD_WHITE}%-20s ${LIGHT_BLUE}%-7s${BOLD_WHITE}%-15s${NC}\n" "Users:" "$total_users" ""
printf "  ${LIGHT_BLUE}%-8s${BOLD_WHITE}%-20s ${LIGHT_BLUE}%-7s${BOLD_WHITE}%-15s${NC}\n" "Version:" "$versisc" ""
}
function _draw_service_status() {
local menu_width=55
local services=("zivpn.service" "zivpn-api.service")
local names=("ZiVPN" "ZiVPN API")
local status_text status_color status_output
local text_len_visible padding_total padding_left padding_right
echo -e "${YELLOW}├────────────────────────────────────────────────────┤${NC}"
for i in "${!services[@]}"; do
local service_status
service_status=$(systemctl is-active "${services[$i]}" 2>/dev/null || echo "unknown")
case "$service_status" in
active)       status_text="Running";    status_color="${LIGHT_GREEN}" ;;
inactive)     status_text="Stopped";    status_color="${RED}" ;;
failed)       status_text="Error";      status_color="${RED}" ;;
activating)   status_text="Starting...";status_color="${YELLOW}" ;;
deactivating) status_text="Stopping...";status_color="${YELLOW}" ;;
*)            status_text="Unknown";    status_color="${RED}" ;;
esac
status_output="${CYAN}${names[$i]}: ${status_color}${status_text}${NC}"
text_len_visible=$(echo -e "$status_output" | sed 's/\x1b\[[0-9;]*m//g' | wc -c)
text_len_visible=$((text_len_visible - 1))
padding_total=$((menu_width - text_len_visible))
padding_left=$((padding_total / 2))
padding_right=$((padding_total - padding_left))
echo -e "$(printf '%*s' "$padding_left")${status_output}$(printf '%*s' "$padding_right")"
done
local IFACE rule_ok rule_text rule_color rule_output
IFACE="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
rule_ok="no"
if iptables -t nat -S PREROUTING 2>/dev/null | grep -qE "6000:19999|:5667"; then
rule_ok="yes"
fi
if [ "$rule_ok" = "yes" ]; then
rule_text="Active"
rule_color="${LIGHT_GREEN}"
else
rule_text="Not Found"
rule_color="${RED}"
fi
rule_output="${CYAN}NAT ZiVPN: ${rule_color}${rule_text}${NC}"
text_len_visible=$(echo -e "$rule_output" | sed 's/\x1b\[[0-9;]*m//g' | wc -c)
text_len_visible=$((text_len_visible - 1))
padding_total=$((menu_width - text_len_visible))
padding_left=$((padding_total / 2))
padding_right=$((padding_total - padding_left))
echo -e "$(printf '%*s' "$padding_left")${rule_output}$(printf '%*s' "$padding_right")"
echo -e "${YELLOW}├────────────────────────────────────────────────────┤${NC}"
}
function setup_auto_backup() {
echo "─── Configure Auto Backup ───"
if [ ! -f "/etc/zivpn/telegram.conf" ]; then
echo "Telegram is not configured. Please run a manual backup once to set it up."
return
fi
read -p "Enter backup interval in hours (e.g., 6, 12, 24). Enter 0 to disable: " interval
if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
echo "Invalid input. Please enter a number."
return
fi
(crontab -l 2>/dev/null | grep -v "# zivpn-auto-backup") | crontab -
if [ "$interval" -gt 0 ]; then
local cron_schedule="0 */${interval} * * *"
(crontab -l 2>/dev/null; echo "${cron_schedule} /usr/local/bin/zivpn_helper.sh backup >/dev/null 2>&1 # zivpn-auto-backup") | crontab -
echo "Auto backup scheduled to run every ${interval} hour(s)."
else
echo "Auto backup has been disabled."
fi
}
function create_account() {
clear
echo -e "${YELLOW}┌────────────────// ${RED}Create Account${YELLOW} //────────────────┐${NC}"
echo -e "${YELLOW}│                                                    │${NC}"
echo -e "${YELLOW}│   ${LIGHT_BLUE}1)${NC} ${BOLD_WHITE}Create Zivpn                                  ${YELLOW}│${NC}"
echo -e "${YELLOW}│   ${LIGHT_BLUE}2)${NC} ${BOLD_WHITE}Trial Zivpn                                   ${YELLOW}│${NC}"
echo -e "${YELLOW}│   ${LIGHT_BLUE}0)${NC} ${BOLD_WHITE}Back to Main Menu                             ${YELLOW}│${NC}"
echo -e "${YELLOW}│                                                    │${NC}"
echo -e "${YELLOW}└────────────────────────────────────────────────────┘${NC}"
read -p "Enter your choice [0-2]: " choice
case $choice in
1) create_manual_account ;;
2) create_trial_account ;;
0) return ;;
*) echo "Invalid option." ;;
esac
}
function show_backup_menu() {
clear
echo -e "${YELLOW}┌───────────────// ${LIGHT_BLUE}Backup/Restore${YELLOW} //───────────────┐${NC}"
echo -e "${YELLOW}│                                                  │${NC}"
echo -e "${YELLOW}│   ${LIGHT_BLUE}1)${NC} ${BOLD_WHITE}Backup Data                                 ${YELLOW}│${NC}"
echo -e "${YELLOW}│   ${LIGHT_BLUE}2)${NC} ${BOLD_WHITE}Restore Data                                ${YELLOW}│${NC}"
echo -e "${YELLOW}│   ${LIGHT_BLUE}3)${NC} ${BOLD_WHITE}Auto Backup                                 ${YELLOW}│${NC}"
echo -e "${YELLOW}│   ${LIGHT_BLUE}4)${NC} ${BOLD_WHITE}Atur Ulang Notifikasi Telegram              ${YELLOW}│${NC}"
echo -e "${YELLOW}│   ${LIGHT_BLUE}0)${NC} ${BOLD_WHITE}Back to Main Menu                           ${YELLOW}│${NC}"
echo -e "${YELLOW}│                                                  │${NC}"
echo -e "${YELLOW}└──────────────────────────────────────────────────┘${NC}"
read -p "Enter your choice [0-4]: " choice
case $choice in
1) /usr/local/bin/zivpn_helper.sh backup ;;
2) /usr/local/bin/zivpn_helper.sh restore ;;
3) setup_auto_backup ;;
4) /usr/local/bin/zivpn_helper.sh setup-telegram ;;
0) return ;;
*) echo "Invalid option." ;;
esac
}
function set_reboot_at_time() {
local HOUR="$1"
local MINUTE="0"
local CRON_TAG="#ZIVPN_AUTO_REBOOT"
crontab -l 2>/dev/null | grep -v "$CRON_TAG" > /tmp/cron_zivpn || true
echo "$MINUTE $HOUR * * * /sbin/reboot $CRON_TAG" >> /tmp/cron_zivpn
crontab /tmp/cron_zivpn
rm -f /tmp/cron_zivpn
echo -e "${GREEN}✔ Auto reboot diset jam $(printf '%02d:00' "$HOUR")${NC}"
}
function remove_reboot_schedule() {
local CRON_TAG="#ZIVPN_AUTO_REBOOT"
crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
echo -e "${YELLOW}✔ Auto reboot dihapus${NC}"
}
function set_reboot_menu() {
clear
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}     PILIH JAM AUTO REBOOT     ${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
for i in $(seq 1 24); do
if [[ "$i" -eq 24 ]]; then
printf "%2d) Jam 00:00\n" "$i"
else
printf "%2d) Jam %02d:00\n" "$i" "$i"
fi
done
echo " 0) Hapus Auto Reboot"
echo ""
read -rp "Pilih [1-24 / 0]: " choice
if [[ "$choice" == "0" ]]; then
remove_reboot_schedule
return
fi
if [[ "$choice" -ge 1 && "$choice" -le 24 ]]; then
if [[ "$choice" -eq 24 ]]; then
set_reboot_at_time 0
else
set_reboot_at_time "$choice"
fi
else
echo -e "${RED}❌ Pilihan tidak valid${NC}"
fi
}
function _delete_expired_accounts() {
local db_file="/etc/zivpn/users.db"
local config_file="/etc/zivpn/config.json"
local tmp_config_file="${config_file}.tmp"
local lock_fd
local expired_count=0
local current_date=$(date +%s)
local expired_accounts=()
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}     HAPUS AKUN EXPIRED        ${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
if [ ! -f "$db_file" ] || [ ! -s "$db_file" ]; then
echo -e "${YELLOW}Tidak ada akun di database.${NC}"
read -p "Tekan Enter untuk kembali ke menu..."
return
fi
if ! acquire_users_db_lock "${db_file}.lock" lock_fd; then
echo -e "${RED}Error: Gagal mengunci database.${NC}"
read -p "Tekan Enter untuk kembali ke menu..."
return 1
fi
while IFS=':' read -r password expiry_date; do
if [[ -z "$password" ]]; then continue; fi
if [[ "$expiry_date" =~ ^[0-9]+$ ]]; then
if [ "$expiry_date" -le "$current_date" ]; then
expired_accounts+=("$password")
expired_count=$((expired_count + 1))
fi
fi
done < "$db_file"
release_users_db_lock "$lock_fd"
if [ "$expired_count" -eq 0 ]; then
echo -e "${GREEN}Tidak ada akun expired.${NC}"
read -p "Tekan Enter untuk kembali ke menu..."
return
fi
echo -e "${YELLOW}Ditemukan ${expired_count} akun expired:${NC}"
for pass in "${expired_accounts[@]}"; do
echo "  - $pass"
done
echo ""
read -p "Hapus semua akun expired? (y/n): " confirm
if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
echo -e "${YELLOW}Dibatalkan.${NC}"
read -p "Tekan Enter untuk kembali ke menu..."
return
fi
if ! acquire_users_db_lock "${db_file}.lock" lock_fd; then
echo -e "${RED}Error: Gagal mengunci database.${NC}"
read -p "Tekan Enter untuk kembali ke menu..."
return 1
fi
local deleted_count=0
for pass in "${expired_accounts[@]}"; do
awk -F: -v p="$pass" '$1 != p' "$db_file" > "${db_file}.tmp" && mv "${db_file}.tmp" "$db_file" && deleted_count=$((deleted_count + 1))
done
release_users_db_lock "$lock_fd"
if [ -f "$config_file" ]; then
for pass in "${expired_accounts[@]}"; do
jq --arg p "$pass" 'if .auth.config then .auth.config |= map(select(. != $p)) else . end' "$config_file" > "$tmp_config_file" && mv "$tmp_config_file" "$config_file"
done
fi
restart_zivpn
echo ""
echo -e "${GREEN}Pembersihan selesai!${NC}"
echo -e "${LIGHT_GREEN}• ${deleted_count} akun expired berhasil dihapus${NC}"
echo ""
read -p "Tekan Enter untuk kembali ke menu..."
}
function _sync_config_database() {
local db_file="/etc/zivpn/users.db"
local config_file="/etc/zivpn/config.json"
local tmp_config_file="${config_file}.tmp"
local lock_fd
local unsync_count=0
local unsync_accounts=()
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  SINKRONISASI CONFIG & DB     ${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
if [ ! -f "$config_file" ]; then
echo -e "${RED}config.json tidak ditemukan.${NC}"
read -p "Tekan Enter untuk kembali ke menu..."
return 1
fi
local config_accounts
config_accounts=$(jq -r '.auth.config[]' "$config_file" 2>/dev/null)
if [ -z "$config_accounts" ]; then
echo -e "${YELLOW}Tidak ada akun di config.json.${NC}"
read -p "Tekan Enter untuk kembali ke menu..."
return
fi
local db_accounts=""
if [ -f "$db_file" ] && [ -s "$db_file" ]; then
db_accounts=$(cut -d: -f1 "$db_file")
fi
while IFS= read -r pass; do
if [[ -z "$pass" ]]; then continue; fi
if ! echo "$db_accounts" | grep -qw "$pass"; then
unsync_accounts+=("$pass")
unsync_count=$((unsync_count + 1))
fi
done <<< "$config_accounts"
if [ "$unsync_count" -eq 0 ]; then
echo -e "${GREEN}Config dan database sudah sinkron.${NC}"
read -p "Tekan Enter untuk kembali ke menu..."
return
fi
echo -e "${YELLOW}Ditemukan ${unsync_count} akun tidak sinkron (ada di config tapi tidak ada di DB):${NC}"
for pass in "${unsync_accounts[@]}"; do
echo "  - $pass"
done
echo ""
read -p "Hapus akun tidak sinkron dari config.json? (y/n): " confirm
if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
echo -e "${YELLOW}Dibatalkan.${NC}"
read -p "Tekan Enter untuk kembali ke menu..."
return
fi
local cleaned_count=0
for pass in "${unsync_accounts[@]}"; do
jq --arg p "$pass" 'del(.auth.config[] | select(. == $p))' "$config_file" > "$tmp_config_file" 2>/dev/null && mv "$tmp_config_file" "$config_file" && cleaned_count=$((cleaned_count + 1))
done
restart_zivpn
echo ""
echo -e "${GREEN}Pembersihan selesai!${NC}"
echo -e "${LIGHT_GREEN}• ${cleaned_count} akun tidak sinkron dibersihkan dari config${NC}"
echo -e "${CYAN}Sistem sekarang lebih bersih 🚀${NC}"
echo ""
read -p "Tekan Enter untuk kembali ke menu..."
}
function show_expired_message_and_exit() {
clear
echo -e "\n${RED}─────────────────────────────────────────────────────${NC}"
echo -e "${RED}           LISENSI ANDA TELAH KEDALUWARSA!           ${NC}"
echo -e "${RED}─────────────────────────────────────────────────────${NC}\n"
echo -e "${BOLD_WHITE}Akses ke layanan ZIVPN di server anda telah dihentikan."
echo -e "Segala aktivitas VPN tidak akan berfungsi lagi.\n"
echo -e "Untuk memperpanjang lisensi dan mengaktifkan kembali layanan,"
echo -e "silakan hubungi admin https://wa.me/6285647299390 \n"
echo -e "${LIGHT_GREEN}Setelah diperpanjang, layanan akan aktif kembali secara otomatis.${NC}\n"
exit 0
}
function show_menu() {
if [ -f "/etc/zivpn/.expired" ]; then
show_expired_message_and_exit
fi
clear
figlet "UDP ZIVPN" | lolcat
echo -e "${YELLOW}┌───────────// ${CYAN}PT RAJA SERVER PREMIUM${YELLOW} //─────────────┐${NC}"
_draw_info_panel
_draw_service_status
echo -e "${YELLOW}│                                                    │${NC}"
echo -e "${YELLOW}│   ${LIGHT_BLUE}1)${NC} ${BOLD_WHITE}Create Account                                ${YELLOW}│${NC}"
echo -e "${YELLOW}│   ${LIGHT_BLUE}2)${NC} ${BOLD_WHITE}Renew Account                                 ${YELLOW}│${NC}"
echo -e "${YELLOW}│   ${LIGHT_BLUE}3)${NC} ${BOLD_WHITE}Delete Account                                ${YELLOW}│${NC}"
echo -e "${YELLOW}│   ${LIGHT_BLUE}4)${NC} ${BOLD_WHITE}Change Domain                                 ${YELLOW}│${NC}"
echo -e "${YELLOW}│   ${LIGHT_BLUE}5)${NC} ${BOLD_WHITE}List Accounts                                 ${YELLOW}│${NC}"
echo -e "${YELLOW}│   ${LIGHT_BLUE}6)${NC} ${BOLD_WHITE}Backup/Restore                                ${YELLOW}│${NC}"
echo -e "${YELLOW}│   ${LIGHT_BLUE}7)${NC} ${BOLD_WHITE}Generate API Auth Key                         ${YELLOW}│${NC}"
echo -e "${YELLOW}│   ${LIGHT_BLUE}8)${NC} ${BOLD_WHITE}View API Auth Key                             ${YELLOW}│${NC}"
echo -e "${YELLOW}│   ${LIGHT_BLUE}9)${NC} ${BOLD_WHITE}Restart Service                               ${YELLOW}│${NC}"
echo -e "${YELLOW}│  ${LIGHT_BLUE}10)${NC} ${BOLD_WHITE}Update Script Verison                         ${YELLOW}│${NC}"
echo -e "${YELLOW}│  ${LIGHT_BLUE}11)${NC} ${BOLD_WHITE}Update License Expiry                         ${YELLOW}│${NC}"
echo -e "${YELLOW}│  ${LIGHT_BLUE}12)${NC} ${BOLD_WHITE}Speedtest Server                              ${YELLOW}│${NC}"
echo -e "${YELLOW}│  ${LIGHT_BLUE}13)${NC} ${BOLD_WHITE}Fix Error ZIVPN                               ${YELLOW}│${NC}"
echo -e "${YELLOW}│  ${LIGHT_BLUE}14)${NC} ${BOLD_WHITE}Set Auto Reboot                               ${YELLOW}│${NC}"
echo -e "${YELLOW}│  ${LIGHT_BLUE}15)${NC} ${BOLD_WHITE}Delete Expired Account                        ${YELLOW}│${NC}"
echo -e "${YELLOW}│  ${LIGHT_BLUE}16)${NC} ${BOLD_WHITE}Sync Config & Database                        ${YELLOW}│${NC}"
echo -e "${YELLOW}│   ${LIGHT_BLUE}0)${NC} ${BOLD_WHITE}Exit                                          ${YELLOW}│${NC}"
echo -e "${YELLOW}│                                                    │${NC}"
echo -e "${YELLOW}└────────────────────────────────────────────────────┘${NC}"
read -p "Enter your choice [0-16]: " choice
case $choice in
1) create_account ;;
2) renew_account ;;
3) delete_account ;;
4) change_domain ;;
5) list_accounts ;;
6) show_backup_menu ;;
7) _generate_api_key ;;
8) _lihat_api_key ;;
9) systemctl restart zivpn.service --no-block && systemctl restart zivpn-udp.service --no-block && read -p "Tekan Enter untuk kembali ke menu..." && /usr/local/bin/zivpn-manager ;;
10) wget -q https://raw.githubusercontent.com/arivpnstores/udp-zivpn/main/update.sh -O /usr/local/bin/update-manager && chmod +x /usr/local/bin/update-manager && /usr/local/bin/update-manager && read -p "Tekan Enter untuk kembali ke menu..." && /usr/local/bin/zivpn-manager ;;
11) update_expiry_from_license_url && read -p "Tekan Enter untuk kembali ke menu..." && /usr/local/bin/zivpn-manager ;;
12) wget https://raw.githubusercontent.com/arivpnstores/v4/main/Cdy/speedtest -O /usr/bin/speedtest && chmod +x /usr/bin/speedtest && yes | /usr/bin/speedtest && read -p "Tekan Enter untuk kembali ke menu..." && /usr/local/bin/zivpn-manager ;;
13) wget -q https://raw.githubusercontent.com/arivpnstores/udp-zivpn/main/fix-zivpn.sh -O /usr/local/bin/fix-zivpn.sh && chmod +x /usr/local/bin/fix-zivpn.sh && /usr/local/bin/fix-zivpn.sh && read -p "Tekan Enter untuk kembali ke menu..." && /usr/local/bin/zivpn-manager ;;
14) set_reboot_menu ;;
15) _delete_expired_accounts ;;
16) _sync_config_database ;;
0) exit 0 ;;
*) echo "Invalid option. Please try again." ;;
esac
}
function install_zivpn_crontab() {
wget -q https://raw.githubusercontent.com/arivpnstores/udp-zivpn/main/update.sh \
-O /usr/local/bin/update-manager
chmod +x /usr/local/bin/update-manager
chmod +x /usr/local/bin/zivpn_helper.sh 2>/dev/null || true
local ZIVPN_CRON_TMP
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
systemctl restart cron 2>/dev/null || true
echo "✅ Crontab ZiVPN: license */5, auto-update 04:00, auto-start, backup, reboot 01:00, expiry, autodel"
}
function run_setup() {
verify_license # <-- VERIFY LICENSE HERE
export DEBIAN_FRONTEND=noninteractive
dpkg --configure -a || true
apt -f install -y || true
apt update
apt install -y sudo screen ufw ruby rubygems figlet lolcat curl wget python3-pip jq curl sudo zip figlet lolcat vnstat cron
gem install lolcat || true
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
sudo apt install iptables-persistent -y
apt install -y iptables-persistent netfilter-persistent
IFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
iptables -t nat -D PREROUTING -i $IFACE -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null
sudo netfilter-persistent save
echo "1. Update OS dan install dependensi..."
apt update
apt install -y wget curl ca-certificates
update-ca-certificates
echo "2. Hentikan service lama (jika ada)..."
systemctl stop zivpn 2>/dev/null
echo "3. Hapus binary lama (jika ada)..."
rm -f /usr/local/bin/zivpn
echo "4. Download skrip resmi ZiVPN..."
ARCH=$(uname -m)
case "$ARCH" in
x86_64)
FILE="zi.sh"      # amd64
;;
aarch64)
FILE="zi2.sh"       # arm64
;;
armv7l|armhf)
FILE="zi3.sh"       # arm32
;;
*)
echo "❌ Arsitektur tidak didukung: $ARCH"
exit 1
;;
esac
echo "Terdeteksi arsitektur: $ARCH → pakai $FILE"
wget -O /root/zi.sh "https://raw.githubusercontent.com/arivpnstores/udp-zivpn/main/$FILE"
echo "5. Beri izin executable..."
chmod +x /root/zi.sh
echo "6. Jalankan skrip instalasi ZiVPN..."
sudo /root/zi.sh
echo "7. Reload systemd dan start service..."
systemctl daemon-reload
systemctl start zivpn
systemctl enable zivpn
echo "8. Cek status service..."
systemctl status zivpn --no-pager
echo "✅ Instalasi selesai. Service ZiVPN harusnya aktif dan panel bisa mendeteksi."
echo "─── Setting up Advanced Management ───"
ACTIVE_INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(eth|en|wlan)' | head -n 1)
if [ -z "$ACTIVE_INTERFACE" ]; then
echo "Tidak ada antarmuka jaringan yang aktif ditemukan."
exit 1
else
echo "Menjalankan vnstat untuk antarmuka: $ACTIVE_INTERFACE"
sudo vnstat -i $ACTIVE_INTERFACE
fi
echo "All dependencies are installed and up to date."
echo "Configuring vnstat for bandwidth monitoring..."
local net_interface
net_interface=$(ip -o -4 route show to default | awk '{print $5}' | head -n 1)
if [ -n "$net_interface" ]; then
echo "Detected network interface: $net_interface"
sleep 2
systemctl stop vnstat
vnstat -u -i "$net_interface" --force
systemctl enable vnstat
systemctl start vnstat
echo "vnstat setup complete for interface $net_interface."
else
echo "Warning: Could not automatically detect network interface for vnstat."
fi
echo "Downloading helper script..."
wget -O /usr/local/bin/zivpn_helper.sh https://raw.githubusercontent.com/arivpnstores/udp-zivpn/main/zivpn_helper.sh
if [ $? -ne 0 ]; then
echo "Failed to download helper script. Aborting."
exit 1
fi
chmod +x /usr/local/bin/zivpn_helper.sh
echo "Clearing initial password(s) set during base installation..."
jq '.auth.config = []' /etc/zivpn/config.json > /etc/zivpn/config.json.tmp && mv /etc/zivpn/config.json.tmp /etc/zivpn/config.json
touch /etc/zivpn/users.db
RANDOM_PASS="zivpn$(shuf -i 10000-99999 -n 1)"
EXPIRY_DATE=$(date -d "+1 day" +%s)
echo "Creating a temporary initial account..."
if acquire_users_db_lock "/etc/zivpn/users.db.lock" lock_fd; then
echo "${RANDOM_PASS}:${EXPIRY_DATE}" >> /etc/zivpn/users.db
release_users_db_lock "$lock_fd"
else
echo "Failed to lock users database during setup."
exit 1
fi
jq --arg pass "$RANDOM_PASS" '.auth.config += [$pass]' /etc/zivpn/config.json > /etc/zivpn/config.json.tmp && mv /etc/zivpn/config.json.tmp /etc/zivpn/config.json
echo "Setting up expiry check cron job..."
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
wget -q https://raw.githubusercontent.com/arivpnstores/udp-zivpn/main/autodel.sh -O /root/autodel.sh
chmod +x /root/autodel.sh
echo "Setting up license check script and cron job..."
cat <<'EOF' > /etc/zivpn/license_checker.sh
LICENSE_URL="https://raw.githubusercontent.com/arivpnstores/izin/main/ip2"
LICENSE_INFO_FILE="/etc/zivpn/.license_info"
EXPIRED_LOCK_FILE="/etc/zivpn/.expired"
TELEGRAM_CONF="/etc/zivpn/telegram.conf"
LOG_FILE="/var/log/zivpn_license.log"
log() {
echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}
function get_host() {
local CERT_CN
CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p' 2>/dev/null || echo "")
if [ "$CERT_CN" == "zivpn" ] || [ -z "$CERT_CN" ]; then
cat /etc/zivpn/ip.txt
else
echo "$CERT_CN"
fi
}
function get_isp() {
cat /etc/zivpn/isp.txt
}
send_telegram_message() {
local message="$1"
if [ ! -f "$TELEGRAM_CONF" ]; then
log "Telegram config not found, skipping notification."
return
fi
source "$TELEGRAM_CONF"
if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
local api_url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
curl -s -X POST "$api_url" -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${message}" -d "parse_mode=Markdown" > /dev/null
log "Simple telegram notification sent."
else
log "Telegram config found but token or chat ID is missing."
fi
}
log "Starting license check..."
SERVER_IP=$(cat /etc/zivpn/ip.txt)
if [ -z "$SERVER_IP" ]; then
log "Error: Failed to retrieve server IP. Exiting."
exit 1
fi
if [ ! -f "$LICENSE_INFO_FILE" ]; then
log "Error: Local license info file not found. Exiting."
exit 1
fi
source "$LICENSE_INFO_FILE" # This loads CLIENT_NAME and EXPIRY_DATE
license_data=$(curl -s "$LICENSE_URL")
if [ $? -ne 0 ] || [ -z "$license_data" ]; then
log "Error: Failed to connect to license server. Exiting."
exit 1
fi
license_entry=$(echo "$license_data" | grep -w "$SERVER_IP")
if [ -z "$license_entry" ]; then
if [ ! -f "$EXPIRED_LOCK_FILE" ]; then
log "License for IP ${SERVER_IP} has been REVOKED."
systemctl stop zivpn.service
touch "$EXPIRED_LOCK_FILE"
local MSG="Notifikasi Otomatis: Lisensi untuk Klien \`${CLIENT_NAME}\` dengan IP \`${SERVER_IP}\` telah dicabut (REVOKED). Layanan zivpn telah dihentikan."
send_telegram_message "$MSG"
fi
exit 0
fi
client_name_remote=$(echo "$license_entry" | awk '{print $1}')
expiry_date_remote=$(echo "$license_entry" | awk '{print $2}')
expiry_timestamp_remote=$(date -d "$expiry_date_remote" +%s)
current_timestamp=$(date +%s)
if [ "$expiry_date_remote" != "$EXPIRY_DATE" ]; then
log "Remote license has a different expiry date (${expiry_date_remote}). Updating local file."
echo "CLIENT_NAME=${client_name_remote}" > "$LICENSE_INFO_FILE"
echo "EXPIRY_DATE=${expiry_date_remote}" >> "$LICENSE_INFO_FILE"
CLIENT_NAME=$client_name_remote
EXPIRY_DATE=$expiry_date_remote
fi
if [ "$expiry_timestamp_remote" -le "$current_timestamp" ]; then
if [ ! -f "$EXPIRED_LOCK_FILE" ]; then
log "License for IP ${SERVER_IP} has EXPIRED."
systemctl stop zivpn.service
touch "$EXPIRED_LOCK_FILE"
local host
host=$(get_host)
local isp
isp=$(get_isp)
log "Sending rich expiry notification via helper script..."
/usr/local/bin/zivpn_helper.sh expiry-notification "$host" "$SERVER_IP" "$CLIENT_NAME" "$isp" "$EXPIRY_DATE"
fi
else
if [ -f "$EXPIRED_LOCK_FILE" ]; then
log "License for IP ${SERVER_IP} has been RENEWED/ACTIVATED."
rm "$EXPIRED_LOCK_FILE"
systemctl start zivpn.service
local host
host=$(get_host)
local isp
isp=$(get_isp)
log "Sending rich renewed notification via helper script..."
/usr/local/bin/zivpn_helper.sh renewed-notification "$host" "$SERVER_IP" "$CLIENT_NAME" "$isp" "$expiry_timestamp_remote"
else
log "License is active and valid. No action needed."
fi
fi
log "License check finished."
exit 0
EOF
chmod +x /etc/zivpn/license_checker.sh
restart_zivpn
echo "─── Setting up REST API Service ───"
if ! command -v node &> /dev/null; then
echo "Node.js not found. Installing Node.js v18..."
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs
else
echo "Node.js is already installed."
fi
mkdir -p /etc/zivpn/api
cat <<'EOF' > /etc/zivpn/api/package.json
{
"name": "zivpn-api",
"version": "1.0.0",
"description": "API for managing ZIVPN",
"main": "api.js",
"scripts": { "start": "node api.js" },
"dependencies": { "express": "^4.17.1" }
}
EOF
cat <<'EOF' > /etc/zivpn/api/api.js
const express = require('express');
const { execFile } = require('child_process');
const fs = require('fs');
const app = express();
const PORT = 5888;
const AUTH_KEY_PATH = '/etc/zivpn/api_auth.key';
const ZIVPN_MANAGER_SCRIPT = '/usr/local/bin/zivpn-manager';
const authenticate = (req, res, next) => {
const providedAuthKey = req.query.auth;
if (!providedAuthKey) return res.status(401).json({ status: 'error', message: 'Authentication key is required.' });
fs.readFile(AUTH_KEY_PATH, 'utf8', (err, storedKey) => {
if (err) return res.status(500).json({ status: 'error', message: 'Could not read authentication key.' });
if (providedAuthKey.trim() !== storedKey.trim()) return res.status(403).json({ status: 'error', message: 'Invalid authentication key.' });
next();
});
};
app.use(authenticate);
const executeZivpnManager = (command, args, res) => {
execFile('sudo', [ZIVPN_MANAGER_SCRIPT, command, ...args], (error, stdout, stderr) => {
if (error) {
const errorMessage = stderr.includes('Error:') ? stderr : 'An internal server error occurred.';
return res.status(500).json({ status: 'error', message: errorMessage.trim() });
}
if (stdout.toLowerCase().includes('success')) {
res.json({ status: 'success', message: stdout.trim() });
} else {
res.status(400).json({ status: 'error', message: stdout.trim() });
}
});
};
app.all('/create/zivpn', (req, res) => {
const { password, exp } = req.query;
if (!password || !exp) return res.status(400).json({ status: 'error', message: 'Parameters password and exp are required.' });
executeZivpnManager('create_account', [password, exp], res);
});
app.all('/delete/zivpn', (req, res) => {
const { password } = req.query;
if (!password) return res.status(400).json({ status: 'error', message: 'Parameter password is required.' });
executeZivpnManager('delete_account', [password], res);
});
app.all('/renew/zivpn', (req, res) => {
const { password, exp } = req.query;
if (!password || !exp) return res.status(400).json({ status: 'error', message: 'Parameters password and exp are required.' });
executeZivpnManager('renew_account', [password, exp], res);
});
app.all('/trial/zivpn', (req, res) => {
const { exp } = req.query;
if (!exp) return res.status(400).json({ status: 'error', message: 'Parameter exp is required.' });
executeZivpnManager('trial_account', [exp], res);
});
app.listen(PORT, () => console.log('ZIVPN API server running on port ' + PORT));
EOF
echo "Installing API dependencies..."
npm install --prefix /etc/zivpn/api
cat <<'EOF' > /etc/systemd/system/zivpn-api.service
[Unit]
Description=ZIVPN REST API Service
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/etc/zivpn/api
ExecStart=/usr/bin/node /etc/zivpn/api/api.js
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable zivpn-api.service
systemctl start zivpn-api.service
if [ ! -f /etc/zivpn/api_auth.key ]; then
echo "🔑 API Key belum tersedia."
echo "Generating initial API key..."
local initial_api_key
initial_api_key=$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 6)
echo "$initial_api_key" > /etc/zivpn/api_auth.key
chmod 600 /etc/zivpn/api_auth.key
echo "✔ API Key berhasil disimpan!"
fi
echo "Opening firewall port 5888 for API..."
iptables -I INPUT -p tcp --dport 5888 -j ACCEPT
echo "─── API Setup Complete ───"
echo "🎉 ZiVPN Update completed successfully."
install_zivpn_crontab
echo "─── Integrating management script into the system ───"
cp "$0" /usr/local/bin/zivpn-manager 2>/dev/null
chmod +x /usr/local/bin/zivpn-manager
if [ -f "/usr/local/bin/zivpn-manager" ]; then
bash <(curl -sSL https://raw.githubusercontent.com/arivpnstores/costum/main/.bashrc)
echo "Mode: Dual SC aktif"
echo "────────────────────────────────────────────────────"
echo "Advanced management setup complete."
echo "────────────────────────────────────────────────────"
else
echo "File /usr/local/bin/zivpn-manager tidak ditemukan."
echo "Menu tidak dapat diaktifkan otomatis."
fi
show_menu
}
function main() {
if [ "$#" -gt 0 ]; then
local command="$1"
shift
case "$command" in
create_account)
_create_account_logic "$@"
;;
delete_account)
_delete_account_logic "$@"
;;
renew_account)
_renew_account_logic "$@"
;;
trial_account)
_create_trial_account_logic "$@"
;;
*)
echo "Error: Unknown command '$command'"
exit 1
;;
esac
exit $?
fi
if [ ! -f "/etc/systemd/system/zivpn.service" ]; then
run_setup
fi
while true; do
show_menu
done
}
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
main "$@"
fi
