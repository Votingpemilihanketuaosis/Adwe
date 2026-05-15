#!/bin/bash
LOG_FILE="/var/log/zivpn-expired.log"
CONFIG_DIR="/etc/zivpn"
DB_FILE="${CONFIG_DIR}/users.db"
CONFIG_FILE="${CONFIG_DIR}/config.json"
TMP_CONFIG_FILE="${CONFIG_FILE}.tmp"
USERS_DB_LOCK_FILE="${DB_FILE}.lock"
function log() {
echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}
function restart_zivpn() {
systemctl restart zivpn.service --no-block
}
function delete_user_from_db() {
local pass="$1"
awk -F: -v p="$pass" '$1 != p' "$DB_FILE" > "${DB_FILE}.tmp" && mv "${DB_FILE}.tmp" "$DB_FILE"
}
function delete_user_from_config() {
local pass="$1"
if [ -f "$CONFIG_FILE" ]; then
jq --arg p "$pass" 'if .auth.config then .auth.config |= map(select(. != $p)) else . end' "$CONFIG_FILE" > "$TMP_CONFIG_FILE" && mv "$TMP_CONFIG_FILE" "$CONFIG_FILE"
fi
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
function _delete_expired_accounts() {
local lock_fd
local current_date=$(date +%s)
local expired_accounts=()
if [ ! -f "$DB_FILE" ]; then
log "Database file tidak ditemukan: $DB_FILE"
return 0
fi
acquire_users_db_lock "$USERS_DB_LOCK_FILE" lock_fd || {
log "Gagal lock database"
return 1
}
while IFS=':' read -r password expiry_date; do
[[ -z "$password" ]] && continue
[[ "$expiry_date" =~ ^[0-9]+$ ]] || continue
if [ "$expiry_date" -le "$current_date" ]; then
expired_accounts+=("$password")
fi
done < "$DB_FILE"
if [ "${#expired_accounts[@]}" -gt 0 ]; then
for pass in "${expired_accounts[@]}"; do
delete_user_from_db "$pass"
done
fi
release_users_db_lock "$lock_fd"
if [ -f "$CONFIG_FILE" ]; then
for pass in "${expired_accounts[@]}"; do
delete_user_from_config "$pass"
done
else
log "Config file tidak ditemukan: $CONFIG_FILE"
fi
if [ "${#expired_accounts[@]}" -gt 0 ]; then
log "Menghapus ${#expired_accounts[@]} akun expired: ${expired_accounts[*]}"
restart_zivpn
log "Service zivpn direstart"
else
log "Tidak ada akun expired"
fi
}
_delete_expired_accounts
