#!/usr/bin/env bash
# install_tarutek.sh
# Installs and configures the TaruTek agents and TaruTek proxy.
#
# Every step is checked first:
#   [EXISTS] -> already present / already correct, no action taken
#   [ACTION] -> not available (or different), action taken
# Safe to re-run any number of times.

set -euo pipefail

REPO_VERSION="8.0"
REPO_PKG="zabbix-release_latest_${REPO_VERSION}+debian13_all.deb"
REPO_URL="https://repo.zabbix.com/zabbix/${REPO_VERSION}/release/raspbian/pool/main/z/zabbix-release/${REPO_PKG}"

# PSK settings shared by the agent and the proxy (same key file, same identity)
PSK_FILE="/etc/zabbix/zabbix_proxy.psk"
PROXY_HOSTNAME="$(hostname)"

# Must run as root (or via sudo)
if [[ $EUID -ne 0 ]]; then
    echo "Please run as root: sudo bash $0"
    exit 1
fi

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    G=""; Y=""; R=""; BOLD=""; RESET=""
fi

N_EXIST=0
N_ACTION=0

section() { echo; echo "${BOLD}== $* ==${RESET}"; }
exists()  { N_EXIST=$((N_EXIST + 1));   echo "  ${G}[EXISTS]${RESET} $1 - already exists, no action taken"; }
acted()   { N_ACTION=$((N_ACTION + 1)); echo "  ${Y}[ACTION]${RESET} $1 - not available, action taken: $2"; }
warn()    { echo "  ${R}[WARN]${RESET}  $1"; }
info()    { echo "  [INFO]  $1"; }

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------
declare -A BACKED_UP=()
backup_once() {
    local f="$1"
    if [[ -z "${BACKED_UP[$f]:-}" && -f "$f" ]]; then
        cp -a "$f" "$f.bak.$(date +%Y%m%d%H%M%S)"
        BACKED_UP[$f]=1
    fi
}

fsum() { { cat "$@" 2>/dev/null || true; } | sha256sum; }

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

APT_UPDATED=0
apt_update_once() {
    if (( APT_UPDATED == 0 )); then
        apt update
        APT_UPDATED=1
    fi
}

ensure_pkg() {
    local pkg="$1" label="$2"
    if pkg_installed "$pkg"; then
        exists "${label} (${pkg})"
    else
        apt_update_once
        apt install -y "$pkg"
        acted "${label} (${pkg})" "installed"
    fi
}

# set_kv FILE KEY VALUE
#   - replaces an active "KEY=" line if present
#   - else uncomments/replaces the first commented "# KEY=" line
#   - else appends "KEY=VALUE" to the end of the file
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

# ensure_kv FILE KEY VALUE : set only when the active value is missing/different
ensure_kv() {
    local file="$1" key="$2" val="$3"
    local cnt cur
    cnt="$(grep -cE "^${key}=" "${file}" || true)"
    cur="$(sed -nE "s/^${key}=//p" "${file}" | head -n1)"
    if [[ "${cnt}" -ge 1 && "${cur}" == "${val}" ]]; then
        exists "${key}=${val}"
    else
        backup_once "${file}"
        set_kv "${file}" "${key}" "${val}"
        acted "${key}" "set to ${val}"
    fi
}

# Keep "Hostname=" commented out (HostnameItem is used instead)
ensure_hostname_commented() {
    local file="$1"
    if grep -qE "^Hostname=" "${file}"; then
        backup_once "${file}"
        sed -i -E "s|^Hostname=|#Hostname=|" "${file}"
        acted "Hostname in ${file}" "commented out"
    elif grep -qE "^#Hostname=" "${file}"; then
        exists "Hostname is commented out in ${file}"
    else
        backup_once "${file}"
        echo "#Hostname=" >> "${file}"
        acted "Hostname in ${file}" "added as commented line"
    fi
}

# ensure_kv_commented FILE KEY VALUE : keep "KEY=VALUE" present but commented out (#KEY=VALUE)
ensure_kv_commented() {
    local file="$1" key="$2" val="$3"
    if grep -qE "^${key}=" "${file}"; then
        backup_once "${file}"
        sed -i -E "s|^${key}=|#${key}=|" "${file}"
        acted "${key} in ${file}" "commented out"
    elif grep -qxF -- "#${key}=${val}" "${file}"; then
        exists "#${key}=${val} is commented out in ${file}"
    else
        backup_once "${file}"
        echo "#${key}=${val}" >> "${file}"
        acted "${key} in ${file}" "added as commented line"
    fi
}

# ensure_line FILE LINE LABEL : exact line must exist (repeatable keys, e.g. AllowKey)
ensure_line() {
    local file="$1" line="$2" label="$3"
    if grep -qxF -- "${line}" "${file}"; then
        exists "${label}"
    else
        backup_once "${file}"
        echo "${line}" >> "${file}"
        acted "${label}" "added"
    fi
}

# ensure_userparam FILE KEY LINE COMMENT
ensure_userparam() {
    local file="$1" key="$2" line="$3" comment="$4" tmp
    if grep -qxF -- "${line}" "${file}"; then
        exists "UserParameter ${key}"
    elif grep -qF -- "UserParameter=${key}," "${file}"; then
        backup_once "${file}"
        tmp="$(mktemp)"
        grep -vF -- "UserParameter=${key}," "${file}" > "${tmp}" || true
        printf '\n%s\n%s\n' "${comment}" "${line}" >> "${tmp}"
        cat "${tmp}" > "${file}"
        rm -f "${tmp}"
        acted "UserParameter ${key}" "existing definition differed, replaced"
    else
        printf '\n%s\n%s\n' "${comment}" "${line}" >> "${file}"
        acted "UserParameter ${key}" "added"
    fi
}

ensure_owner() {
    local path="$1" want="$2" cur
    cur="$(stat -c '%U:%G' "${path}")"
    if [[ "${cur}" == "${want}" ]]; then
        exists "Owner of ${path} is ${want}"
    else
        chown "${want}" "${path}"
        acted "Owner of ${path}" "changed ${cur} -> ${want}"
    fi
}

ensure_mode() {
    local path="$1" want="$2" cur
    cur="$(stat -c '%a' "${path}")"
    if [[ "${cur}" == "${want}" ]]; then
        exists "Permission of ${path} is ${want}"
    else
        chmod "${want}" "${path}"
        acted "Permission of ${path}" "changed ${cur} -> ${want}"
    fi
}

# ensure_service SERVICE LABEL RESTART_NEEDED(0/1)
ensure_service() {
    local svc="$1" label="$2" restart="$3"
    if systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
        exists "${label} service enabled at boot"
    else
        systemctl enable "${svc}"
        acted "${label} service enable" "enabled at boot"
    fi

    if ! systemctl is-active --quiet "${svc}"; then
        systemctl restart "${svc}"
        sleep 2
        acted "${label} service running" "started"
    elif [[ "${restart}" == "1" ]]; then
        systemctl restart "${svc}"
        sleep 2
        acted "${label} service restart" "restarted to apply configuration changes"
    else
        exists "${label} service running"
    fi

    if ! systemctl is-active --quiet "${svc}"; then
        warn "${label} service is NOT running. Recent log:"
        journalctl -u "${svc}" -n 20 --no-pager || true
    fi
}

# ===========================================================================
# 1. Repository and packages
# ===========================================================================
section "1. TaruTek repository and packages"

REPO_INSTALLED_VER="$(dpkg-query -W -f='${Version}' zabbix-release 2>/dev/null || true)"

if pkg_installed zabbix-release && [[ "${REPO_INSTALLED_VER}" == *"${REPO_VERSION}"* ]]; then
    exists "TaruTek ${REPO_VERSION} repository package (zabbix-release ${REPO_INSTALLED_VER})"
else
    if [[ -n "${REPO_INSTALLED_VER}" ]]; then
        info "Installed repository package is ${REPO_INSTALLED_VER}, switching to ${REPO_VERSION}"
    fi
    wget -O "/tmp/${REPO_PKG}" "${REPO_URL}"
    dpkg -i "/tmp/${REPO_PKG}"
    rm -f "/tmp/${REPO_PKG}"
    APT_UPDATED=0
    apt_update_once
    acted "TaruTek ${REPO_VERSION} repository package (zabbix-release)" "downloaded, installed and package lists updated"
fi

ensure_pkg "zabbix-agent2"         "TaruTek agent"
ensure_pkg "zabbix-proxy-sqlite3"  "TaruTek proxy (SQLite3)"
ensure_pkg "mosquitto"             "Mosquitto MQTT broker"

# ===========================================================================
# 2. Proxy database directory
# ===========================================================================
section "2. TaruTek proxy database directory"

DB_DIR="/var/lib/zabbix"

if [[ -d "${DB_DIR}" ]]; then
    exists "Directory ${DB_DIR}"
else
    mkdir -p "${DB_DIR}"
    acted "Directory ${DB_DIR}" "created"
fi
ensure_owner "${DB_DIR}" "zabbix:zabbix"
ensure_mode  "${DB_DIR}" "750"

if [[ -f "${DB_DIR}/zabbix_proxy.sqlite" ]]; then
    ensure_owner "${DB_DIR}/zabbix_proxy.sqlite" "zabbix:zabbix"
    ensure_mode  "${DB_DIR}/zabbix_proxy.sqlite" "640"
else
    info "Proxy DB file not present yet, it is created by the proxy on first start"
fi

# ===========================================================================
# 3. TaruTek agent configuration
# ===========================================================================
section "3. TaruTek agent configuration"

CONF="/etc/zabbix/zabbix_agent2.conf"
AGENT_D_DIR="/etc/zabbix/zabbix_agent2.d"
TARUTEK_CONF="${AGENT_D_DIR}/tarutek.conf"
MQTT_CONF="/etc/zabbix/zabbix_agent2.d/plugins.d/mqtt.conf"
MQTT_LINE="Plugins.MQTT.Sessions.TaruTek.Url=tcp://localhost"

mkdir -p "${AGENT_D_DIR}" "$(dirname "${MQTT_CONF}")"
AGENT_SUM_BEFORE="$(fsum "${CONF}" "${TARUTEK_CONF}" "${MQTT_CONF}" "${PSK_FILE}")"
AGENT_RESTART=0

# 64-character hex PSK (256-bit). An existing valid key is kept so that
# re-running this script does not break an already registered agent/proxy.
# Created here, before the agent is configured, because the agent's
# TLSPSKFile must exist when the agent service starts.
if [[ -s "${PSK_FILE}" ]] && grep -qE '^[0-9a-fA-F]{64}$' "${PSK_FILE}"; then
    exists "PSK key in ${PSK_FILE}"
else
    ( umask 077; openssl rand -hex 32 > "${PSK_FILE}" )
    acted "PSK key in ${PSK_FILE}" "generated new 256-bit key"
fi
ensure_owner "${PSK_FILE}" "zabbix:zabbix"
ensure_mode  "${PSK_FILE}" "600"

ensure_kv "${CONF}" "Server"        "127.0.0.1,ciq.tarutek.com"
ensure_kv "${CONF}" "ServerActive"  "127.0.0.1,ciq.tarutek.com"
ensure_kv "${CONF}" "HostnameItem"  "system.hostname"
ensure_hostname_commented "${CONF}"
ensure_line "${CONF}" "AllowKey=system.run[*]" "AllowKey=system.run[*]"

# PSK encryption (same configuration and same PSK file as the proxy)
ensure_kv "${CONF}" "TLSConnect"     "psk"
ensure_kv_commented "${CONF}" "TLSAccept" "psk"   # hashed (commented out) on the agent
ensure_kv "${CONF}" "TLSPSKIdentity" "${PROXY_HOSTNAME}"
ensure_kv "${CONF}" "TLSPSKFile"     "${PSK_FILE}"

# ---- Custom user parameters (Raspberry Pi metrics) ------------------------
section "4. TaruTek custom user parameters (${TARUTEK_CONF})"

if [[ -f "${TARUTEK_CONF}" ]]; then
    exists "File ${TARUTEK_CONF}"
else
    touch "${TARUTEK_CONF}"
    acted "File ${TARUTEK_CONF}" "created"
fi

# Quoted heredocs: nothing is expanded by the shell (keeps $2, \1 intact).
LINE_TEMP="$(cat << 'TARUTEK_EOF'
UserParameter=system.cpu.temp,vcgencmd measure_temp | sed -n 's/temp=\([0-9]*\.[0-9]*\)[^0-9]*$/\1/p'
TARUTEK_EOF
)"
LINE_THROTTLED="$(cat << 'TARUTEK_EOF'
UserParameter=system.pi.throttled,vcgencmd get_throttled | awk -F'=' '{print $2}'
TARUTEK_EOF
)"
LINE_SERIAL="$(cat << 'TARUTEK_EOF'
UserParameter=rpi.serial,cat /proc/device-tree/serial-number | tr -d '\0'
TARUTEK_EOF
)"

ensure_userparam "${TARUTEK_CONF}" "system.cpu.temp"    "${LINE_TEMP}"      "# CPU Temperature (°C)"
ensure_userparam "${TARUTEK_CONF}" "system.pi.throttled" "${LINE_THROTTLED}" "# Under-voltage / Throttling status bitmask"
ensure_userparam "${TARUTEK_CONF}" "rpi.serial"          "${LINE_SERIAL}"    "# Device Serial number check"

ensure_mode "${TARUTEK_CONF}" "644"

# ---- MQTT plugin session ---------------------------------------------------
section "5. TaruTek MQTT plugin session (${MQTT_CONF})"

if [[ -f "${MQTT_CONF}" ]]; then
    exists "File ${MQTT_CONF}"
else
    touch "${MQTT_CONF}"
    acted "File ${MQTT_CONF}" "created"
fi

MQTT_URL_COUNT="$(grep -cE '^Plugins\.MQTT\.Sessions\.[^=]*\.Url=' "${MQTT_CONF}" || true)"

if grep -qxF "${MQTT_LINE}" "${MQTT_CONF}" && [[ "${MQTT_URL_COUNT}" -eq 1 ]]; then
    exists "MQTT session (${MQTT_LINE})"
elif [[ "${MQTT_URL_COUNT}" -ge 1 ]]; then
    backup_once "${MQTT_CONF}"
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
    acted "MQTT session" "existing Url replaced with ${MQTT_LINE}"
else
    echo "${MQTT_LINE}" >> "${MQTT_CONF}"
    acted "MQTT session" "added ${MQTT_LINE}"
fi

AGENT_SUM_AFTER="$(fsum "${CONF}" "${TARUTEK_CONF}" "${MQTT_CONF}" "${PSK_FILE}")"
[[ "${AGENT_SUM_BEFORE}" != "${AGENT_SUM_AFTER}" ]] && AGENT_RESTART=1

# ===========================================================================
# 6. Mosquitto broker
# ===========================================================================
section "6. Mosquitto MQTT broker"

MOSQ_CONF="/etc/mosquitto/mosquitto.conf"
MOSQ_SUM_BEFORE="$(fsum "${MOSQ_CONF}")"
touch "${MOSQ_CONF}"

L_CNT="$(grep -cE '^[[:space:]]*listener[[:space:]]+1883([[:space:]]|$)' "${MOSQ_CONF}" || true)"
A_CNT="$(grep -cE '^[[:space:]]*allow_anonymous[[:space:]]' "${MOSQ_CONF}" || true)"
L_LINE="$(grep -nxF 'listener 1883 127.0.0.1' "${MOSQ_CONF}" | cut -d: -f1 | head -n1 || true)"
A_LINE="$(grep -nxF 'allow_anonymous true' "${MOSQ_CONF}" | cut -d: -f1 | head -n1 || true)"

if [[ "${L_CNT}" -eq 1 && "${A_CNT}" -eq 1 && -n "${L_LINE}" && -n "${A_LINE}" && "${L_LINE}" -lt "${A_LINE}" ]]; then
    exists "Mosquitto listener 1883 (127.0.0.1) with allow_anonymous true"
else
    backup_once "${MOSQ_CONF}"
    # Remove any active copies, then append in the right order
    # ("allow_anonymous" must come after "listener" to apply to that listener).
    sed -i -E '/^[[:space:]]*allow_anonymous[[:space:]]/d' "${MOSQ_CONF}"
    sed -i -E '/^[[:space:]]*listener[[:space:]]+1883([[:space:]]|$)/d' "${MOSQ_CONF}"
    {
        echo "listener 1883 127.0.0.1"
        echo "allow_anonymous true"
    } >> "${MOSQ_CONF}"
    acted "Mosquitto listener / allow_anonymous settings" "written to ${MOSQ_CONF}"
fi

MOSQ_SUM_AFTER="$(fsum "${MOSQ_CONF}")"
MOSQ_RESTART=0
[[ "${MOSQ_SUM_BEFORE}" != "${MOSQ_SUM_AFTER}" ]] && MOSQ_RESTART=1
ensure_service "mosquitto" "Mosquitto" "${MOSQ_RESTART}"

# ===========================================================================
# 7. User groups and agent service
# ===========================================================================
section "7. Agent user groups and service"

for grp in video render; do
    if ! getent group "${grp}" > /dev/null; then
        warn "Group '${grp}' does not exist on this system, skipping"
    elif id -nG zabbix | tr ' ' '\n' | grep -qx "${grp}"; then
        exists "User zabbix is in group ${grp}"
    else
        usermod -aG "${grp}" zabbix
        AGENT_RESTART=1
        acted "User zabbix in group ${grp}" "added"
    fi
done

ensure_service "zabbix-agent2" "TaruTek agent" "${AGENT_RESTART}"

# ===========================================================================
# 8. TaruTek proxy configuration
# ===========================================================================
section "8. TaruTek proxy configuration"

PROXY_CONF="/etc/zabbix/zabbix_proxy.conf"
PROXY_SUM_BEFORE="$(fsum "${PROXY_CONF}" "${PSK_FILE}")"

ensure_kv "${PROXY_CONF}" "Server" "ciq.tarutek.com"
ensure_hostname_commented "${PROXY_CONF}"
ensure_kv "${PROXY_CONF}" "HostnameItem"       "system.hostname"
ensure_kv "${PROXY_CONF}" "DBName"             "${DB_DIR}/zabbix_proxy.sqlite"
ensure_kv "${PROXY_CONF}" "ProxyOfflineBuffer" "48"

# PSK encryption (identity = this system's hostname)
ensure_kv "${PROXY_CONF}" "TLSConnect"     "psk"
ensure_kv "${PROXY_CONF}" "TLSAccept"      "psk"
ensure_kv "${PROXY_CONF}" "TLSPSKIdentity" "${PROXY_HOSTNAME}"
ensure_kv "${PROXY_CONF}" "TLSPSKFile"     "${PSK_FILE}"

ensure_mode "${PROXY_CONF}" "755"

# The PSK file itself is created in section 3 (shared with the agent).

ensure_kv "${PROXY_CONF}" "EnableRemoteCommands" "1"

PROXY_SUM_AFTER="$(fsum "${PROXY_CONF}" "${PSK_FILE}")"
PROXY_RESTART=0
[[ "${PROXY_SUM_BEFORE}" != "${PROXY_SUM_AFTER}" ]] && PROXY_RESTART=1
ensure_service "zabbix-proxy" "TaruTek proxy" "${PROXY_RESTART}"

# ===========================================================================
# Summary and PSK details
# ===========================================================================
PSK_VALUE="$(tr -d '[:space:]' < "${PSK_FILE}")"

echo
echo "=============================================================="
echo " Summary: ${N_EXIST} already existed (no action), ${N_ACTION} actions taken"
echo "=============================================================="
echo
echo "=============================================================="
echo " TaruTek Proxy and Agent - PSK details (shared key, use to configure the server side)"
echo "=============================================================="
echo " PSK Identity : ${BOLD}${PROXY_HOSTNAME}${RESET}"
echo " PSK Key      : ${BOLD}${PSK_VALUE}${RESET}"
echo " HOST Name    : ${BOLD}$(hostname)${RESET}"
echo "=============================================================="
echo

echo "TaruTek install complete."
