#!/usr/bin/env bash
# install_tarutek.sh
# Installs and configures the TaruTek agents and TaruTek proxy.
 
set -euo pipefail
 
REPO_PKG="zabbix-release_latest_7.0+debian13_all.deb"
REPO_URL="https://repo.zabbix.com/zabbix/7.0/raspbian/pool/main/z/zabbix-release/${REPO_PKG}"
 
# Must run as root (or via sudo)
if [[ $EUID -ne 0 ]]; then
    echo "Please run as root: sudo bash $0"
    exit 1
fi
 
echo "[1/4] Downloading GO3C repository package..."
wget -O "/tmp/${REPO_PKG}" "${REPO_URL}"
 
echo "[2/4] Installing repository package..."
dpkg -i "/tmp/${REPO_PKG}"
 
echo "[3/4] Updating package lists..."
apt update
 
echo "[4/4] Installing TaruTek agents and TaruTek proxy (SQLite3)..."
apt install -y zabbix-agent2
apt install -y zabbix-proxy-sqlite3
 
rm -f "/tmp/${REPO_PKG}"
 
# ---------------------------------------------------------------------------
# Helper: set_kv FILE KEY VALUE
#   - replaces an active "KEY=" line if present
#   - else uncomments/replaces the first commented "# KEY=" line
#   - else appends "KEY=VALUE" to the end of the file
# ---------------------------------------------------------------------------
set_kv() {
    local file="$1" key="$2" val="$3"
    local esc="${val//&/\\&}"
    if grep -qE "^${key}=" "${file}"; then
        sed -i -E "s|^${key}=.*|${key}=${esc}|" "${file}"
    elif grep -qE "^#[[:space:]]*${key}=" "${file}"; then
        sed -i -E "0,/^#[[:space:]]*${key}=/{s|^#[[:space:]]*${key}=.*|${key}=${esc}|}" "${file}"
    else
        echo "${key}=${val}" >> "${file}"
    fi
}
 
# Helper: keep "Hostname=" commented out (HostnameItem is used instead)
comment_out_hostname() {
    local file="$1"
    if grep -qE "^Hostname=" "${file}"; then
        sed -i -E "s|^Hostname=|#Hostname=|" "${file}"
    elif ! grep -qE "^#Hostname=" "${file}"; then
        echo "#Hostname=" >> "${file}"
    fi
}
 
# TaruTek proxy keeps its SQLite3 database in this directory
DB_DIR="/var/lib/zabbix"
 
echo "Checking ${DB_DIR}..."
if [[ ! -d "${DB_DIR}" ]]; then
    echo "${DB_DIR} not found, creating it..."
    mkdir -p "${DB_DIR}"
else
    echo "${DB_DIR} already exists."
fi
 
# Owned by the zabbix user so the proxy can create/write the SQLite3 DB file.
# (root can always access it, so the service can also be started as root.)
chown zabbix:zabbix "${DB_DIR}"
chmod 750 "${DB_DIR}"
 
# If a proxy DB file already exists, make sure the zabbix user owns it
if [[ -f "${DB_DIR}/zabbix_proxy.sqlite" ]]; then
    chown zabbix:zabbix "${DB_DIR}/zabbix_proxy.sqlite"
    chmod 640 "${DB_DIR}/zabbix_proxy.sqlite"
fi
 
# ---------------------------------------------------------------------------
# TaruTek agent configuration
# ---------------------------------------------------------------------------
CONF="/etc/zabbix/zabbix_agent2.conf"
 
echo "Configuring ${CONF}..."
cp -a "${CONF}" "${CONF}.bak.$(date +%Y%m%d%H%M%S)"
 
set_kv "${CONF}" "Server"        "127.0.0.1,ciq.tarutek.com"
set_kv "${CONF}" "ServerActive"  "127.0.0.1,ciq.tarutek.com"
set_kv "${CONF}" "HostnameItem"  "system.hostname"
 
# Hostname must stay commented out (HostnameItem is used instead)
comment_out_hostname "${CONF}"
 
# AllowKey can be repeated, so only add it if this exact line is missing
if ! grep -qxF "AllowKey=system.run[*]" "${CONF}"; then
    echo "AllowKey=system.run[*]" >> "${CONF}"
fi
 
# ---------------------------------------------------------------------------
# TaruTek custom user parameters (Raspberry Pi metrics)
# ---------------------------------------------------------------------------
AGENT_D_DIR="/etc/zabbix/zabbix_agent2.d"
TARUTEK_CONF="${AGENT_D_DIR}/tarutek.conf"
 
echo "Writing ${TARUTEK_CONF}..."
mkdir -p "${AGENT_D_DIR}"
 
# Quoted heredoc: nothing inside is expanded by the shell (keeps $2, \1 intact).
# The file is rewritten on every run, so re-running the installer is safe.
cat > "${TARUTEK_CONF}" << 'TARUTEK_EOF'
# CPU Temperature (°C)
UserParameter=system.cpu.temp,vcgencmd measure_temp | sed -n 's/temp=\([0-9]*\.[0-9]*\)[^0-9]*$/\1/p'
 
# Under-voltage / Throttling status bitmask
UserParameter=system.pi.throttled,vcgencmd get_throttled | awk -F'=' '{print $2}'
TARUTEK_EOF
 
chmod 644 "${TARUTEK_CONF}"
 
# ---------------------------------------------------------------------------
# TaruTek MQTT plugin session
# ---------------------------------------------------------------------------
MQTT_CONF="/etc/zabbix/zabbix_agent2.d/plugins.d/mqtt.conf"
MQTT_LINE="Plugins.MQTT.Sessions.TaruTek.Url=tcp://localhost"
 
echo "Configuring ${MQTT_CONF}..."
mkdir -p "$(dirname "${MQTT_CONF}")"
touch "${MQTT_CONF}"
 
if grep -qxF "${MQTT_LINE}" "${MQTT_CONF}" \
   && [[ "$(grep -cE '^Plugins\.MQTT\.Sessions\.[^=]*\.Url=' "${MQTT_CONF}")" -eq 1 ]]; then
    echo "MQTT session already configured."
elif grep -qE '^Plugins\.MQTT\.Sessions\.[^=]*\.Url=' "${MQTT_CONF}"; then
    # An active Sessions.*.Url line exists: replace the first one with ours
    # and drop any other active Sessions.*.Url lines so only one remains.
    echo "Existing MQTT session Url found, updating..."
    cp -a "${MQTT_CONF}" "${MQTT_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    tmp="$(mktemp)"
    awk -v new="${MQTT_LINE}" '
        /^Plugins\.MQTT\.Sessions\.[^=]*\.Url=/ {
            if (!done) { print new; done=1 }
            next
        }
        { print }
    ' "${MQTT_CONF}" > "${tmp}"
    cat "${tmp}" > "${MQTT_CONF}"
    rm -f "${tmp}"
else
    echo "${MQTT_LINE}" >> "${MQTT_CONF}"
fi
 
# ---------------------------------------------------------------------------
# Mosquitto MQTT broker (install, configure, enable, start)
# ---------------------------------------------------------------------------
MOSQ_CONF="/etc/mosquitto/mosquitto.conf"
 
echo "Installing Mosquitto..."
apt install -y mosquitto
 
echo "Configuring ${MOSQ_CONF}..."
touch "${MOSQ_CONF}"
cp -a "${MOSQ_CONF}" "${MOSQ_CONF}.bak.$(date +%Y%m%d%H%M%S)"
 
# Remove any active copies of these lines, then append them in the right order
# ("allow_anonymous" must come after "listener" to apply to that listener).
sed -i -E '/^[[:space:]]*allow_anonymous[[:space:]]/d' "${MOSQ_CONF}"
sed -i -E '/^[[:space:]]*listener[[:space:]]+1883([[:space:]]|$)/d' "${MOSQ_CONF}"
{
    echo "listener 1883 127.0.0.1"
    echo "allow_anonymous true"
} >> "${MOSQ_CONF}"
 
echo "Enabling and starting Mosquitto..."
systemctl enable mosquitto
systemctl restart mosquitto
 
sleep 1
if systemctl is-active --quiet mosquitto; then
    echo "Mosquitto service is running."
else
    echo "WARNING: Mosquitto service is not running. Recent log:"
    journalctl -u mosquitto -n 20 --no-pager || true
fi
 
echo "Restarting TaruTek agents..."
systemctl enable zabbix-agent2
systemctl restart zabbix-agent2
 
# ---------------------------------------------------------------------------
# TaruTek proxy configuration
# ---------------------------------------------------------------------------
PROXY_CONF="/etc/zabbix/zabbix_proxy.conf"
PSK_FILE="/etc/zabbix/zabbix_proxy.psk"
PROXY_HOSTNAME="$(hostname)"
 
echo "Configuring ${PROXY_CONF}..."
cp -a "${PROXY_CONF}" "${PROXY_CONF}.bak.$(date +%Y%m%d%H%M%S)"
 
set_kv "${PROXY_CONF}" "Server"               "ciq.tarutek.com"
 
# Hostname stays commented out; HostnameItem is active instead
comment_out_hostname "${PROXY_CONF}"
set_kv "${PROXY_CONF}" "HostnameItem"         "system.hostname"
 
set_kv "${PROXY_CONF}" "DBName"               "${DB_DIR}/zabbix_proxy.sqlite"
set_kv "${PROXY_CONF}" "ProxyOfflineBuffer"   "48"
set_kv "${PROXY_CONF}" "EnableRemoteCommands" "1"
 
# PSK encryption (identity = this system's hostname)
set_kv "${PROXY_CONF}" "TLSConnect"           "psk"
set_kv "${PROXY_CONF}" "TLSAccept"            "psk"
set_kv "${PROXY_CONF}" "TLSPSKIdentity"       "${PROXY_HOSTNAME}"
set_kv "${PROXY_CONF}" "TLSPSKFile"           "${PSK_FILE}"
 
# Proxy config file permission
chmod 755 "${PROXY_CONF}"
 
# Generate a 64-character hex PSK (256-bit). An existing valid key is kept so
# that re-running this script does not break a proxy that is already registered.
if [[ -s "${PSK_FILE}" ]] && grep -qE '^[0-9a-fA-F]{64}$' "${PSK_FILE}"; then
    echo "Existing PSK found in ${PSK_FILE}, keeping it."
else
    echo "Generating new PSK in ${PSK_FILE}..."
    umask 077
    openssl rand -hex 32 > "${PSK_FILE}"
fi
 
# Readable only by the zabbix user (the service account); root can always read it
chown zabbix:zabbix "${PSK_FILE}"
chmod 600 "${PSK_FILE}"
 
echo "Enabling and starting TaruTek proxy..."
systemctl enable zabbix-proxy
systemctl restart zabbix-proxy
 
sleep 2
if systemctl is-active --quiet zabbix-proxy; then
    echo "TaruTek proxy service is running."
else
    echo "WARNING: TaruTek proxy service is not running. Recent log:"
    journalctl -u zabbix-proxy -n 20 --no-pager || true
fi
 
# ---------------------------------------------------------------------------
# Show the PSK details needed to configure the proxy on the TaruTek side
# ---------------------------------------------------------------------------
PSK_VALUE="$(tr -d '[:space:]' < "${PSK_FILE}")"
 
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    BOLD=""; RESET=""
fi
 
echo
echo "=============================================================="
echo " TaruTek Proxy - PSK details (use these to configure the proxy)"
echo "=============================================================="
echo " PSK Identity : ${BOLD}${PROXY_HOSTNAME}${RESET}"
echo " PSK Key      : ${BOLD}${PSK_VALUE}${RESET}"
echo " HOST Name    : ${BOLD}$(hostname)${RESET}"
echo "=============================================================="
echo
 
echo "TaruTek install complete."