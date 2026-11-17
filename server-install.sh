#!/usr/bin/env bash
# =============================================================================
#  VPN Installer — server side
#  Installs 3x-ui + Xray + VLESS XHTTP Reality (+ optional Hysteria2)
#
#  Supported: Ubuntu 20.04/22.04/24.04, Debian 11/12, x86_64/aarch64
#  Does NOT reboot, does NOT touch Docker/Amnezia, does NOT change sshd_config.
#  This script is normally piped over SSH by installer.ps1.
# =============================================================================

set -Eeuo pipefail

# --- config injected by installer.ps1 ---------------------------------------
VPN_PUBLIC_HOST='@@PUBLIC_HOST@@'
VPN_SSH_PORT='@@SSH_PORT@@'
VPN_PANEL_PORT='@@PANEL_PORT@@'
VPN_PANEL_PATH='@@PANEL_PATH@@'
VPN_PANEL_USER='@@PANEL_USER@@'
VPN_PANEL_PASS_B64='@@PANEL_PASS_B64@@'
VPN_CLIENT_NAMES='@@CLIENT_NAMES@@'
VPN_ENABLE_HY2='@@ENABLE_HY2@@'
VPN_SPLIT_TUNNEL='@@SPLIT_TUNNEL@@'
VPN_CHECK_ONLY='@@CHECK_ONLY@@'
VPN_RESUME='@@RESUME@@'
VPN_XUI_VERSION='@@XUI_VERSION@@'
VPN_XUI_INSTALLER_SHA256='@@XUI_INSTALLER_SHA256@@'
VPN_SNI='@@SNI@@'
VPN_ENABLE_AWG='@@ENABLE_AWG@@'
VPN_AWG_PORT='@@AWG_PORT@@'
VPN_PANEL_PUBLIC='@@PANEL_PUBLIC@@'
VPN_HARDEN='@@HARDEN@@'
# --- end config --------------------------------------------------------------

umask 077
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="/root/vpn-install-${STAMP}.log"
RESULT_DIR="/root/vpn-result-${STAMP}"
CERT_DIR="/etc/x-ui/certs"
SNI="${VPN_SNI:-www.otto.de}"
BASE=""
API_AUTH=()
COOKIE_FILE=""
CSRF_TOKEN=""
INBOUND_ID=""
HY2_INBOUND_ID=""
HY2_ENABLED=0
HAS_DOCKER=0
UFW_ACTIVE=0
RESUME_MODE=0
DETECTED_SSH_PORT="$VPN_SSH_PORT"
ORIG_POLICY="ACCEPT"
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
SHORT_ID=""
XHTTP_PATH=""
CLIENTS_JSON="[]"
HY2_CLIENTS_JSON="[]"
CLIENT_NAMES=()
CLIENT_UUIDS=()
CLIENT_LINKS=()
HY2_LINKS=()
HY2_AUTHS=()
AWG_ENABLED=0
AWG_SKIP=0
AWG_PORT="${VPN_AWG_PORT:-auto}"
AWG_SUBNET="10.66.66"
AWG_SERVER_PUBLIC=""
AWG_CLIENTS_JSON="[]"

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '  [OK] %s\n' "$*"; }
info() { printf '  [..] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*"; }
die()  { printf '  [FAIL] %s\n' "$*" >&2; exit 1; }

on_error() {
  local code=$?
  printf '\n  [FAIL] Установка прервана (строка %s, код %s).\n' "${1:-?}" "$code" >&2
  printf '  Лог на сервере: %s\n' "$LOG" >&2
  printf '  Сервер не перезагружался. Проверьте сообщение выше.\n' >&2
  exit "$code"
}
trap 'on_error $LINENO' ERR

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true
}

exec > >(tee -a "$LOG") 2>&1

# =============================================================================
#  PREFLIGHT
# =============================================================================
step "Проверка сервера"

[[ "$(id -u)" -eq 0 ]] || die "Скрипт нужно запускать от root."

# --- config sanity -----------------------------------------------------------
[[ "$VPN_PUBLIC_HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
  || die "Некорректный адрес сервера: $VPN_PUBLIC_HOST"
[[ "$VPN_SSH_PORT" =~ ^[0-9]+$ ]] && (( VPN_SSH_PORT >= 1 && VPN_SSH_PORT <= 65535 )) \
  || die "Некорректный SSH-порт: $VPN_SSH_PORT"
[[ "$SNI" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] \
  || die "Некорректный SNI (домен для маскировки): $SNI"

case "$VPN_ENABLE_HY2" in 0|1) ;; *) die "ENABLE_HY2 должен быть 0 или 1." ;; esac
case "$VPN_SPLIT_TUNNEL" in 0|1) ;; *) die "SPLIT_TUNNEL должен быть 0 или 1." ;; esac
case "$VPN_CHECK_ONLY" in 0|1) ;; *) die "CHECK_ONLY должен быть 0 или 1." ;; esac
case "$VPN_RESUME" in 0|1) ;; *) die "RESUME должен быть 0 или 1." ;; esac
case "$VPN_ENABLE_AWG" in 0|1) ;; *) die "ENABLE_AWG должен быть 0 или 1." ;; esac
case "${VPN_PANEL_PUBLIC:-0}" in 0|1) ;; *) die "PANEL_PUBLIC должен быть 0 или 1." ;; esac
case "${VPN_HARDEN:-0}" in 0|1) ;; *) die "HARDEN должен быть 0 или 1." ;; esac
if [[ "$VPN_AWG_PORT" != "auto" ]]; then
  [[ "$VPN_AWG_PORT" =~ ^[0-9]+$ ]] && (( VPN_AWG_PORT >= 1024 && VPN_AWG_PORT <= 65535 )) \
    || die "Порт AmneziaWG должен быть auto или числом 1024-65535."
fi
[[ "$VPN_XUI_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "Некорректная версия 3x-ui: $VPN_XUI_VERSION"
[[ "$VPN_XUI_INSTALLER_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] \
  || die "Некорректный SHA-256 установщика 3x-ui."
[[ -n "$VPN_CLIENT_NAMES" ]] || die "Не задано ни одного клиента."

# Resume mode: finish an interrupted install on a server where this installer
# already installed 3x-ui. Requires the explicit -Resume switch.
if [[ "$VPN_RESUME" == "1" ]]; then
  [[ -x /usr/local/x-ui/x-ui ]] \
    || die "Режим -Resume: 3x-ui не установлен. Запустите обычную установку."
  [[ -f /etc/x-ui/install-result.env ]] \
    || die "Режим -Resume: не найден /etc/x-ui/install-result.env. Это не незавершённая установка."
  # shellcheck disable=SC1091
  . /etc/x-ui/install-result.env
  VPN_PANEL_PORT="${XUI_PANEL_PORT:-$VPN_PANEL_PORT}"
  VPN_PANEL_PATH="${XUI_WEB_BASE_PATH:-$VPN_PANEL_PATH}"
  VPN_PANEL_USER="${XUI_USERNAME:-$VPN_PANEL_USER}"
  VPN_PANEL_PASS="${XUI_PASSWORD:-}"
  RESUME_MODE=1
  info "Режим -Resume: используем существующую панель 3x-ui."
fi

if [[ "$VPN_PANEL_PORT" != "auto" ]]; then
  [[ "$VPN_PANEL_PORT" =~ ^[0-9]+$ ]] \
    || die "Некорректный порт панели: $VPN_PANEL_PORT"
  (( VPN_PANEL_PORT >= 1024 && VPN_PANEL_PORT <= 65535 )) \
    || die "Порт панели должен быть от 1024 до 65535."
  [[ "$VPN_PANEL_PORT" != "443" ]] \
    || die "Порт 443 занят VLESS. Выберите другой порт панели."
fi

if [[ "$VPN_PANEL_PATH" == "auto" ]]; then
  VPN_PANEL_PATH="$(head -c 16 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-20)"
fi
VPN_PANEL_PATH="${VPN_PANEL_PATH#/}"
VPN_PANEL_PATH="${VPN_PANEL_PATH%/}"
[[ "$VPN_PANEL_PATH" =~ ^[A-Za-z0-9_-]{8,64}$ ]] \
  || die "Путь панели: 8-64 символа, только A-Z a-z 0-9 _ - (без слэшей)."

if [[ "$VPN_PANEL_USER" == "auto" ]]; then
  VPN_PANEL_USER="$(head -c 16 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-20)"
fi
[[ "$VPN_PANEL_USER" =~ ^[A-Za-z0-9._-]{8,64}$ ]] \
  || die "Логин панели: 8-64 символа, только A-Z a-z 0-9 . _ -."

if [[ "$RESUME_MODE" == "1" ]]; then
  : # password came from /etc/x-ui/install-result.env
elif [[ "$VPN_PANEL_PASS_B64" == "auto" ]]; then
  VPN_PANEL_PASS="$(head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-32)"
else
  VPN_PANEL_PASS="$(printf '%s' "$VPN_PANEL_PASS_B64" | base64 -d 2>/dev/null || true)"
fi
unset VPN_PANEL_PASS_B64
(( ${#VPN_PANEL_PASS} >= 12 )) \
  || die "Пароль панели не декодировался или слишком короткий."

[[ -f /etc/os-release ]] || die "Не найден /etc/os-release."
# shellcheck disable=SC1091
. /etc/os-release

case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "Поддерживаются только Ubuntu и Debian. Найдено: ${PRETTY_NAME:-${ID:-unknown}}." ;;
esac

if [[ "${ID}" == "ubuntu" ]]; then
  awk -v v="${VERSION_ID:-0}" 'BEGIN{exit !(v+0 >= 20.04)}' || die "Нужна Ubuntu 20.04 или новее."
elif [[ "${ID}" == "debian" ]]; then
  awk -v v="${VERSION_ID:-0}" 'BEGIN{exit !(v+0 >= 11)}' || die "Нужен Debian 11 или новее."
fi

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|aarch64) ;;
  *) die "Архитектура $ARCH не поддерживается." ;;
esac

command -v systemctl >/dev/null 2>&1 || die "Нужен systemd."
command -v apt-get >/dev/null 2>&1 || die "Нужен apt."

info "ОС: ${PRETTY_NAME:-$ID $VERSION_ID}"
info "Архитектура: $ARCH"

mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
if (( mem_kb < 400000 )); then
  warn "Мало RAM (${mem_kb} KB). 3x-ui сможет работать, но лучше 512 MB+."
fi

avail_kb="$(df -Pk / | awk 'NR==2{print $4}')"
if (( avail_kb < 1500000 )); then
  die "Мало свободного места: нужно минимум 1.5 GB."
fi

if [[ -d /usr/local/x-ui || -f /etc/systemd/system/x-ui.service ]]; then
  if [[ "$RESUME_MODE" == "1" ]]; then
    info "3x-ui уже установлен — продолжаем настройку."
  else
    die "3x-ui уже установлен. Установщик рассчитан на чистый сервер. Ничего не изменено."
  fi
fi

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  HAS_DOCKER=1
  warn "Обнаружен Docker. Установщик не будет его трогать; firewall не будет блокировать другие порты."
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  UFW_ACTIVE=1
  warn "Обнаружен активный ufw. Правила будут добавлены через ufw, без сброса."
fi

# Never touch an existing Amnezia installation. If Amnezia/AmneziaWG is already
# present, the optional AmneziaWG step is skipped completely.
if [[ "$VPN_ENABLE_AWG" == "1" ]]; then
  if [[ -d /opt/amnezia ]] \
    || [[ -f /etc/amnezia/amneziawg/awg0.conf ]] \
    || { command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qi '^amnezia'; } \
    || { command -v awg >/dev/null 2>&1 && awg show interfaces 2>/dev/null | grep -qw 'awg0'; }; then
    AWG_SKIP=1
    warn "На сервере уже есть Amnezia/AmneziaWG. Установщик её не трогает; дополнительный AmneziaWG пропущен."
  fi
fi

if [[ -n "${SSH_CONNECTION:-}" ]]; then
  detected="$(awk '{print $4}' <<< "$SSH_CONNECTION")"
  if [[ "$detected" =~ ^[0-9]+$ ]] && (( detected > 0 && detected <= 65535 )); then
    DETECTED_SSH_PORT="$detected"
  fi
fi
info "SSH-порт текущего подключения: $DETECTED_SSH_PORT (разрешим также $VPN_SSH_PORT)"

tcp_busy() {
  ss -H -ltn 2>/dev/null | awk -v p=":$1" '$4 ~ p"$" {found=1} END{exit !found}'
}
udp_busy() {
  ss -H -lun 2>/dev/null | awk -v p=":$1" '$4 ~ p"$" {found=1} END{exit !found}'
}

# Install the tools needed for the port check if they are missing.
if ! command -v ss >/dev/null 2>&1; then
  apt-get update -y -o Acquire::Retries=3 >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends iproute2 >/dev/null 2>&1 || true
fi

if [[ "$VPN_PANEL_PORT" == "auto" ]]; then
  for _ in $(seq 1 60); do
    candidate="$(shuf -i 20000-60000 -n 1)"
    if ! tcp_busy "$candidate"; then
      VPN_PANEL_PORT="$candidate"
      break
    fi
  done
  [[ "$VPN_PANEL_PORT" != "auto" ]] || die "Не удалось выбрать свободный порт панели."
  info "Порт панели выбран автоматически: $VPN_PANEL_PORT"
fi

if tcp_busy 443; then
  if [[ "$RESUME_MODE" == "1" ]]; then
    info "TCP 443 уже занят — проверю, наш ли это inbound."
  else
    die "TCP 443 уже занят. Освободите порт или возьмите другой сервер."
  fi
fi
if [[ "$RESUME_MODE" == "0" ]] && tcp_busy "$VPN_PANEL_PORT"; then
  die "Порт панели $VPN_PANEL_PORT уже занят."
fi
if [[ "$VPN_ENABLE_HY2" == "1" ]] && udp_busy 443; then
  die "UDP 443 уже занят. Отключите Hysteria2 или освободите порт."
fi

if [[ "$VPN_ENABLE_AWG" == "1" && "$AWG_SKIP" == "0" ]]; then
  if [[ "$AWG_PORT" == "auto" ]]; then
    if ! udp_busy 51820; then
      AWG_PORT=51820
    else
      for _ in $(seq 1 60); do
        candidate="$(shuf -i 20000-60000 -n 1)"
        if ! udp_busy "$candidate"; then
          AWG_PORT="$candidate"
          break
        fi
      done
      [[ "$AWG_PORT" != "auto" ]] || die "Не удалось выбрать свободный UDP-порт для AmneziaWG."
    fi
    info "Порт AmneziaWG выбран: UDP ${AWG_PORT}"
  elif udp_busy "$AWG_PORT"; then
    die "UDP ${AWG_PORT} уже занят. Выберите другой порт AmneziaWG."
  fi
fi

if [[ "$VPN_CHECK_ONLY" == "1" ]]; then
  ok "Сервер подходит для установки."
  printf '\n=== VPN_CHECK_OK ===\n'
  exit 0
fi

mkdir -p "$RESULT_DIR"
chmod 700 "$RESULT_DIR"

# =============================================================================
#  PACKAGES
# =============================================================================
step "Установка пакетов"
apt-get update -y -o Acquire::Retries=3
apt-get install -y --no-install-recommends \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  curl wget jq qrencode ca-certificates openssl tar gzip unzip socat iproute2 iptables cron sqlite3
ok "Пакеты установлены."

# =============================================================================
#  3X-UI
# =============================================================================
if [[ "$RESUME_MODE" == "0" ]]; then
  step "Установка 3x-ui ${VPN_XUI_VERSION}"
  INSTALLER="/tmp/3xui-install-${VPN_XUI_VERSION}.sh"
  curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 15 --max-time 120 \
    "https://raw.githubusercontent.com/MHSanaei/3x-ui/${VPN_XUI_VERSION}/install.sh" \
    -o "$INSTALLER"
  echo "${VPN_XUI_INSTALLER_SHA256}  ${INSTALLER}" | sha256sum -c - >/dev/null \
    || die "SHA-256 установщика 3x-ui не совпал. Скачивание повреждено или подменено."
  info "Официальный установщик скачан и проверен."

  XUI_NONINTERACTIVE=1 \
  XUI_USERNAME="$VPN_PANEL_USER" \
  XUI_PASSWORD="$VPN_PANEL_PASS" \
  XUI_PANEL_PORT="$VPN_PANEL_PORT" \
  XUI_WEB_BASE_PATH="$VPN_PANEL_PATH" \
  XUI_DB_TYPE=sqlite \
  XUI_SSL_MODE=none \
  XUI_SERVER_IP="$VPN_PUBLIC_HOST" \
  XUI_ENABLE_FAIL2BAN=false \
  bash "$INSTALLER" "$VPN_XUI_VERSION"
else
  step "Продолжение настройки"
  info "3x-ui уже установлен — используем существующую панель."
  systemctl start x-ui >/dev/null 2>&1 || true
fi

for _ in $(seq 1 30); do
  if systemctl is-active --quiet x-ui; then
    break
  fi
  sleep 1
done
systemctl is-active --quiet x-ui || die "Служба x-ui не запустилась."
ok "3x-ui готов."

[[ -f /etc/x-ui/install-result.env ]] || die "3x-ui не записал /etc/x-ui/install-result.env."
# shellcheck disable=SC1091
. /etc/x-ui/install-result.env
VPN_PANEL_PORT="${XUI_PANEL_PORT:-$VPN_PANEL_PORT}"
VPN_PANEL_PATH="${XUI_WEB_BASE_PATH:-$VPN_PANEL_PATH}"
VPN_PANEL_USER="${XUI_USERNAME:-$VPN_PANEL_USER}"
VPN_PANEL_PASS="${XUI_PASSWORD:-$VPN_PANEL_PASS}"
VPN_PANEL_PATH="${VPN_PANEL_PATH#/}"
VPN_PANEL_PATH="${VPN_PANEL_PATH%/}"
BASE="http://127.0.0.1:${VPN_PANEL_PORT}/${VPN_PANEL_PATH}"

# Panel access mode. 0 = loopback only (SSH tunnel), 1 = HTTPS on all interfaces.
PANEL_PUBLIC="${VPN_PANEL_PUBLIC:-0}"
PANEL_EFFECTIVE_PUBLIC=0
if [[ "$PANEL_PUBLIC" == "1" ]]; then
  PANEL_SCHEME="https"
  PANEL_URL="https://${VPN_PUBLIC_HOST}:${VPN_PANEL_PORT}/${VPN_PANEL_PATH}/"
else
  PANEL_SCHEME="http"
  PANEL_URL="http://127.0.0.1:${VPN_PANEL_PORT}/${VPN_PANEL_PATH}/"
fi

# A previous run may have switched the panel to HTTPS. Plain HTTP on the same
# port then stops answering, so detect the certificate and use https://.
PANEL_IS_HTTPS=0
if command -v sqlite3 >/dev/null 2>&1 && [[ -f /etc/x-ui/x-ui.db ]]; then
  if [[ -n "$(sqlite3 /etc/x-ui/x-ui.db "select value from settings where key='webCertFile';" 2>/dev/null || true)" ]]; then
    PANEL_IS_HTTPS=1
    BASE="https://127.0.0.1:${VPN_PANEL_PORT}/${VPN_PANEL_PATH}"
  fi
fi
# Keep the reported URL consistent with an already-secured panel (resume run).
if [[ "$PANEL_IS_HTTPS" == "1" && "$PANEL_PUBLIC" != "1" ]]; then
  PANEL_SCHEME="https"
  PANEL_URL="https://127.0.0.1:${VPN_PANEL_PORT}/${VPN_PANEL_PATH}/"
fi

# 3x-ui enables its subscription server by default on TCP 2096. If the panel
# itself uses 2096, the sub server cannot bind and x-ui exits. This installer
# does not need subscription links, so disable the sub server in that case.
fix_panel_port_conflict() {
  local db="/etc/x-ui/x-ui.db" web_port sub_port sub_enable backup
  [[ -f "$db" ]] || return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0

  web_port="$(sqlite3 "$db" "select value from settings where key='webPort' limit 1;" 2>/dev/null || true)"
  [[ -n "$web_port" ]] || web_port="$VPN_PANEL_PORT"
  sub_port="$(sqlite3 "$db" "select value from settings where key='subPort' limit 1;" 2>/dev/null || true)"
  [[ -n "$sub_port" ]] || sub_port="2096"
  sub_enable="$(sqlite3 "$db" "select value from settings where key='subEnable' limit 1;" 2>/dev/null || true)"
  [[ -n "$sub_enable" ]] || sub_enable="true"
  sub_enable="$(printf '%s' "$sub_enable" | tr '[:upper:]' '[:lower:]')"
  case "$sub_enable" in 1|t|true|yes|on) sub_enable=true ;; *) sub_enable=false ;; esac

  if [[ "$sub_enable" != "true" ]]; then
    return 0
  fi

  if [[ "$sub_port" == "$web_port" ]]; then
    warn "Порт панели ${web_port} совпадает с портом подписок 3x-ui. Отключаю подписки, иначе x-ui не запустится."
  else
    warn "Отключаю подписки 3x-ui: они не нужны, а порт ${sub_port} зря слушает наружу."
  fi
  systemctl stop x-ui >/dev/null 2>&1 || true
  sleep 1
  backup="${db}.bak-$(date +%Y%m%d-%H%M%S)"
  if ! sqlite3 "$db" ".backup '${backup}'" >/dev/null 2>&1; then
    cp -a "$db" "$backup" 2>/dev/null || true
    [[ -f "${db}-wal" ]] && cp -a "${db}-wal" "${backup}-wal" 2>/dev/null || true
    [[ -f "${db}-shm" ]] && cp -a "${db}-shm" "${backup}-shm" 2>/dev/null || true
  fi
  if [[ "$(sqlite3 "$db" "select count(*) from settings where key='subEnable';" 2>/dev/null || echo 0)" == "0" ]]; then
    sqlite3 "$db" "insert into settings(key,value) values('subEnable','false');" >/dev/null 2>&1 || true
  else
    sqlite3 "$db" "update settings set value='false' where key='subEnable';" >/dev/null 2>&1 || true
  fi
  warn "Подписки отключены. Резервная копия базы: ${backup}"
  return 0
}

# 3x-ui restarts itself at the end of its installer. Restart once more so we
# never talk to an old process that is about to be replaced. Bind the panel to
# loopback: the SSH tunnel is the only intended way in.
restart_panel() {
  local old_pid new_pid _
  fix_panel_port_conflict
  # Clear a failed/rate-limited unit: otherwise systemd refuses to start it
  # again after several quick restarts ("Start request repeated too quickly").
  systemctl reset-failed x-ui >/dev/null 2>&1 || true
  old_pid="$(systemctl show -p MainPID --value x-ui 2>/dev/null || echo 0)"
  systemctl restart x-ui >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    new_pid="$(systemctl show -p MainPID --value x-ui 2>/dev/null || echo 0)"
    if [[ "$new_pid" =~ ^[0-9]+$ && "$new_pid" != "0" && "$new_pid" != "$old_pid" ]] \
      && systemctl is-active --quiet x-ui \
      && curl -ksS -o /dev/null --max-time 2 "${BASE}/" 2>/dev/null; then
      # Two answers one second apart: the old process is really gone.
      sleep 1
      if curl -ksS -o /dev/null --max-time 2 "${BASE}/" 2>/dev/null; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

panel_diagnostics() {
  local state
  state="$(systemctl is-active x-ui 2>/dev/null | head -n1 || true)"
  warn "Служба x-ui: ${state:-unknown}"
  if ! ss -H -ltn 2>/dev/null | grep -q ":${VPN_PANEL_PORT} "; then
    warn "Порт панели ${VPN_PANEL_PORT} не слушается."
  fi
  if journalctl -u x-ui -n 50 --no-pager 2>/dev/null | grep -q 'address already in use'; then
    warn "Порт панели занят. Частая причина — подписки 3x-ui на 2096 при порте панели 2096."
  fi
  warn "Последние строки журнала x-ui:"
  journalctl -u x-ui -n 20 --no-pager 2>/dev/null | tail -n 20 || true
}

/usr/local/x-ui/x-ui setting -listenIP "127.0.0.1" >/dev/null 2>&1 || true
if ! restart_panel; then
  panel_diagnostics
  die "Панель 3x-ui не отвечает на ${BASE}/. Проверьте: systemctl status x-ui"
fi

api_error_text() {
  jq -r 'if ((.obj.issues? // []) | length) > 0
         then (.obj.issues | map(.message) | join("; "))
         else (.msg // .) end' <<< "$1" 2>/dev/null || printf '%s' "$1"
}

api_get() {
  local path="$1" attempt resp restarted=0
  for attempt in 1 2 3 4 5; do
    if resp="$(curl -kfsS --max-time 10 "${API_AUTH[@]}" "${BASE}${path}" 2>/dev/null)"; then
      printf '%s' "$resp"
      return 0
    fi
    # A restart during the first seconds is normal; later failures are not.
    if (( attempt >= 3 && restarted == 0 )); then
      restart_panel || true
      restarted=1
    fi
    sleep 1
  done
  return 1
}

login_panel() {
  local csrf login_body
  COOKIE_FILE="$(mktemp)"
  csrf="$(curl -kfsS --max-time 15 -c "$COOKIE_FILE" "${BASE}/csrf-token" 2>/dev/null \
    | jq -r '.obj // empty' 2>/dev/null || true)"
  if [[ -n "$csrf" ]]; then
    login_body="$(mktemp)"
    if curl -kfsS --max-time 15 -c "$COOKIE_FILE" -b "$COOKIE_FILE" -X POST \
        -H "X-CSRF-Token: ${csrf}" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "username=${VPN_PANEL_USER}" \
        --data-urlencode "password=${VPN_PANEL_PASS}" \
        "${BASE}/login" -o "$login_body" 2>/dev/null \
      && jq -e '.success == true' >/dev/null 2>&1 < "$login_body"; then
      rm -f "$login_body" 2>/dev/null || true
      API_AUTH=(-b "$COOKIE_FILE" -H "X-CSRF-Token: ${csrf}")
      info "API панели: сессия входа."
      return 0
    fi
    rm -f "$login_body" 2>/dev/null || true
  fi
  rm -f "$COOKIE_FILE" 2>/dev/null || true
  COOKIE_FILE=""
  if [[ -n "${XUI_API_TOKEN:-}" ]]; then
    API_AUTH=(-H "Authorization: Bearer ${XUI_API_TOKEN}")
    warn "Вход по логину не удался — использую API-токен из окружения."
    return 0
  fi
  return 1
}

if ! login_panel; then
  die "Не удалось войти в панель 3x-ui. Проверьте логин/пароль и что панель запущена."
fi

if ! LIST_JSON="$(api_get "/panel/api/inbounds/list")"; then
  panel_diagnostics
  die "API панели не отвечает. Проверьте: systemctl status x-ui"
fi
if ! jq -e '.success == true' >/dev/null 2>&1 <<< "$LIST_JSON"; then
  die "API панели вернул ошибку: $(api_error_text "$LIST_JSON")"
fi

# =============================================================================
#  REALITY KEYS + CLIENTS
# =============================================================================
step "Генерация ключей Reality"
case "$(uname -m)" in
  x86_64) XRAY_ARCH=amd64 ;;
  aarch64) XRAY_ARCH=arm64 ;;
  *) die "Неподдерживаемая архитектура: $(uname -m)" ;;
esac
XRAY_BIN="/usr/local/x-ui/bin/xray-linux-${XRAY_ARCH}"
[[ -x "$XRAY_BIN" ]] || die "Не найден Xray: $XRAY_BIN"

KEYS="$("$XRAY_BIN" x25519 2>/dev/null || true)"
REALITY_PRIVATE_KEY="$(sed -n -e 's/^PrivateKey: //p' -e 's/^Private key: //p' <<< "$KEYS" | head -n1)"
REALITY_PUBLIC_KEY="$(sed -n -e 's/^Password (PublicKey): //p' -e 's/^Public key: //p' <<< "$KEYS" | head -n1)"
if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
  die "Не удалось разобрать вывод xray x25519: $KEYS"
fi
SHORT_ID="$(openssl rand -hex 8)"
XHTTP_PATH="/$(openssl rand -hex 8)"
ok "Reality: pbk=${REALITY_PUBLIC_KEY:0:12}..., sid=${SHORT_ID}"

step "Создание клиентов"
IFS=',' read -r -a RAW_NAMES <<< "$VPN_CLIENT_NAMES"
if (( ${#RAW_NAMES[@]} == 0 )); then
  RAW_NAMES=("client-1")
fi

for i in "${!RAW_NAMES[@]}"; do
  raw="${RAW_NAMES[$i]}"
  name="$(printf '%s' "$raw" | tr -cs 'A-Za-z0-9_-' '-' | sed 's/^-*//;s/-*$//' | cut -c1-24)"
  [[ -n "$name" ]] || name="client-$((i+1))"
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  subid="$(openssl rand -hex 8)"
  email="client-$((i+1))-${name}"

  CLIENT_NAMES+=("$name")
  CLIENT_UUIDS+=("$uuid")

  client_json="$(jq -n \
    --arg id "$uuid" \
    --arg email "$email" \
    --arg subId "$subid" \
    '{id:$id, flow:"", email:$email, limitIp:0, totalGB:0, expiryTime:0, enable:true, tgId:0, subId:$subId, reset:0}')"
  CLIENTS_JSON="$(jq -c --argjson c "$client_json" '. + [$c]' <<< "$CLIENTS_JSON")"
  info "Клиент: $name"
done

SETTINGS_JSON="$(jq -n --argjson clients "$CLIENTS_JSON" \
  '{clients:$clients, decryption:"none", encryption:"none"}')"

STREAM_JSON="$(jq -n \
  --arg target "${SNI}:443" \
  --arg sni "$SNI" \
  --arg privateKey "$REALITY_PRIVATE_KEY" \
  --arg publicKey "$REALITY_PUBLIC_KEY" \
  --arg shortId "$SHORT_ID" \
  --arg path "$XHTTP_PATH" \
  '{
    network:"xhttp",
    security:"reality",
    xhttpSettings:{path:$path, host:"", mode:"auto"},
    realitySettings:{
      show:false, xver:0, target:$target, serverNames:[$sni],
      privateKey:$privateKey, minClientVer:"", maxClientVer:"", maxTimediff:0,
      shortIds:[$shortId], mldsa65Seed:"",
      settings:{publicKey:$publicKey, fingerprint:"chrome", serverName:"", spiderX:"/", mldsa65Verify:""}
    }
  }')"

SNIFFING_JSON='{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'

INBOUND_JSON="$(jq -n \
  --arg remark "VLESS-XHTTP-Reality-443" \
  --arg tag "inbound-vless-xhttp-reality-443" \
  --argjson settings "$SETTINGS_JSON" \
  --argjson streamSettings "$STREAM_JSON" \
  --argjson sniffing "$SNIFFING_JSON" \
  '{
    up:0, down:0, total:0, remark:$remark, tag:$tag,
    subSortIndex:1, excludeFromSub:false, enable:true, expiryTime:0,
    trafficReset:"never", trafficResetDay:1,
    listen:"", port:443, protocol:"vless",
    settings:$settings, streamSettings:$streamSettings, sniffing:$sniffing,
    shareAddrStrategy:"node", shareAddr:""
  }')"

step "Создание VLESS inbound"
INBOUND_TAG="inbound-vless-xhttp-reality-443"

find_inbound_id() {
  local list
  list="$(api_get "/panel/api/inbounds/list")" || return 1
  jq -r --arg tag "$INBOUND_TAG" '.obj[]? | select(.tag==$tag) | .id' \
    <<< "$list" 2>/dev/null | head -n1 || true
}

print_inbounds() {
  local list
  list="$(api_get "/panel/api/inbounds/list" || true)"
  if [[ -z "$list" ]]; then
    warn "Не удалось получить список inbound."
    return
  fi
  info "Существующие inbound:"
  jq -r '.obj[]? | "  id=\(.id) tag=\(.tag) port=\(.port) protocol=\(.protocol) enable=\(.enable)"' \
    <<< "$list" 2>/dev/null || true
}

if ! INBOUNDS_JSON="$(api_get "/panel/api/inbounds/list")"; then
  panel_diagnostics
  die "Не удалось получить список inbound от панели."
fi

INBOUND_ID="$(jq -r --arg tag "$INBOUND_TAG" '.obj[]? | select(.tag==$tag) | .id' \
  <<< "$INBOUNDS_JSON" 2>/dev/null | head -n1 || true)"

# Fail fast if another inbound already owns TCP 443. Keep its JSON so nothing
# is lost if the user decides to remove it.
if [[ -z "$INBOUND_ID" ]]; then
  TCP_443_FILTER='select(.port == 443 and .tag != $tag and (.protocol == "vless" or .protocol == "vmess" or .protocol == "trojan" or .protocol == "mtproto" or .protocol == "shadowsocks" or .protocol == "tunnel" or .protocol == "masque"))'
  OTHER_443="$(jq -r --arg tag "$INBOUND_TAG" \
    ".obj[]? | ${TCP_443_FILTER} | \"\\(.tag) (id=\\(.id), protocol=\\(.protocol))\"" \
    <<< "$INBOUNDS_JSON" 2>/dev/null | head -n1 || true)"
  if [[ -n "$OTHER_443" ]]; then
    jq --arg tag "$INBOUND_TAG" \
      ".obj[]? | ${TCP_443_FILTER}" \
      <<< "$INBOUNDS_JSON" > "${RESULT_DIR}/conflict-443-inbound.json" 2>/dev/null || true
    warn "Порт 443/TCP уже занят inbound: ${OTHER_443}"
    warn "Его настройки сохранены: ${RESULT_DIR}/conflict-443-inbound.json"
    die "Освободите порт 443 в панели (удалите или смените порт этого inbound) и запустите установку снова."
  fi
fi

if [[ -n "$INBOUND_ID" ]]; then
  # Resume: keep the existing inbound as-is. The panel's update endpoint
  # intentionally preserves stored clients, so reusing them keeps links valid.
  EXISTING="$(jq -c --arg tag "$INBOUND_TAG" '.obj[]? | select(.tag==$tag)' \
    <<< "$INBOUNDS_JSON" 2>/dev/null | head -n1 || true)"
  [[ -n "$EXISTING" ]] || die "Не удалось прочитать существующий inbound (id=$INBOUND_ID)."

  EX_PORT="$(jq -r '.port // 443' <<< "$EXISTING")"
  EX_PBK="$(jq -r '.streamSettings.realitySettings.settings.publicKey // .streamSettings.realitySettings.publicKey // empty' <<< "$EXISTING")"
  EX_SID="$(jq -r '.streamSettings.realitySettings.shortIds[0] // empty' <<< "$EXISTING")"
  EX_PATH="$(jq -r '.streamSettings.xhttpSettings.path // empty' <<< "$EXISTING")"
  EX_MODE="$(jq -r '.streamSettings.xhttpSettings.mode // empty' <<< "$EXISTING")"
  EX_SNI="$(jq -r '.streamSettings.realitySettings.serverNames[0] // empty' <<< "$EXISTING")"
  EX_ENABLE="$(jq -r '.enable // false' <<< "$EXISTING")"
  EX_CLIENTS="$(jq -c '.settings.clients // []' <<< "$EXISTING")"

  [[ "$EX_PORT" == "443" ]] \
    || die "Существующий inbound использует порт ${EX_PORT}, а установщик ожидает 443. Удалите его в панели и запустите снова."
  [[ -n "$EX_PBK" && -n "$EX_SID" && -n "$EX_PATH" ]] \
    || die "В существующем inbound не хватает Reality/XHTTP настроек. Удалите его в панели и запустите снова."
  [[ "$(jq 'length' <<< "$EX_CLIENTS")" != "0" ]] \
    || die "Inbound уже есть (id=$INBOUND_ID), но без клиентов. Удалите его в панели и запустите снова."

  REALITY_PUBLIC_KEY="$EX_PBK"
  SHORT_ID="$EX_SID"
  XHTTP_PATH="$EX_PATH"
  LINK_MODE="${EX_MODE:-auto}"
  [[ -n "$EX_SNI" ]] && SNI="$EX_SNI"
  CLIENT_NAMES=()
  CLIENT_UUIDS=()
  while IFS=$'\t' read -r cid cemail; do
    [[ -n "$cid" ]] || continue
    cname="$(sed -E 's/^client-[0-9]+-//' <<< "$cemail")"
    cname="$(printf '%s' "$cname" | tr -cs 'A-Za-z0-9_-' '-' | sed 's/^-*//;s/-*$//' | cut -c1-24)"
    [[ -n "$cname" ]] || cname="client-$(( ${#CLIENT_NAMES[@]} + 1 ))"
    CLIENT_NAMES+=("$cname")
    CLIENT_UUIDS+=("$cid")
  done < <(jq -r '.[] | [.id, (.email // "")] | @tsv' <<< "$EX_CLIENTS")
  [[ ${#CLIENT_UUIDS[@]} -gt 0 ]] \
    || die "В существующем inbound нет клиентов с корректным id. Удалите его в панели и запустите снова."

  if [[ "$EX_ENABLE" != "true" ]]; then
    EN_BODY="$(mktemp)"
    EN_CODE="$(curl -ksS --max-time 15 -o "$EN_BODY" -w '%{http_code}' -X POST "${API_AUTH[@]}" \
      -H "Content-Type: application/json" \
      --data-binary '{"enable":true}' \
      "${BASE}/panel/api/inbounds/setEnable/${INBOUND_ID}" 2>/dev/null)" || EN_CODE="000"
    EN_RESP="$(cat "$EN_BODY" 2>/dev/null || true)"
    rm -f "$EN_BODY"
    if [[ "$EN_CODE" != "200" ]] || ! jq -e '.success == true' >/dev/null 2>&1 <<< "$EN_RESP"; then
      die "Не удалось включить существующий inbound (HTTP ${EN_CODE}): $(api_error_text "$EN_RESP")"
    fi
    ok "Существующий inbound включён."
  fi
  ok "Использую существующий VLESS inbound (id=$INBOUND_ID) без изменений."
else
  ADDED=0
  RESP=''
  ADD_CODE=''
  print_inbounds
  for attempt in $(seq 1 10); do
    ADD_BODY="$(mktemp)"
    ADD_CODE="$(curl -ksS --max-time 15 -o "$ADD_BODY" -w '%{http_code}' -X POST "${API_AUTH[@]}" \
        -H "Content-Type: application/json" \
        --data-binary "$INBOUND_JSON" \
        "${BASE}/panel/api/inbounds/add" 2>/dev/null)" || ADD_CODE="000"
    RESP="$(cat "$ADD_BODY" 2>/dev/null || true)"
    rm -f "$ADD_BODY"
    if [[ "$ADD_CODE" == "200" ]] && jq -e '.success == true' >/dev/null 2>&1 <<< "$RESP"; then
      ADDED=1
      break
    fi

    # A restricted API token can read the list but not create inbounds.
    # Fall back to a normal login session and retry.
    if [[ ( "$ADD_CODE" == "401" || "$ADD_CODE" == "403" ) && -z "${COOKIE_FILE:-}" ]]; then
      COOKIE_FILE="$(mktemp)"
      CSRF_TOKEN="$(curl -kfsS -c "$COOKIE_FILE" "${BASE}/csrf-token" 2>/dev/null | jq -r '.obj // empty' 2>/dev/null || true)"
      if [[ -n "$CSRF_TOKEN" ]] && curl -kfsS -c "$COOKIE_FILE" -b "$COOKIE_FILE" -X POST \
        -H "X-CSRF-Token: ${CSRF_TOKEN}" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "username=${VPN_PANEL_USER}" \
        --data-urlencode "password=${VPN_PANEL_PASS}" \
        "${BASE}/login" >/dev/null 2>&1; then
        API_AUTH=(-b "$COOKIE_FILE" -H "X-CSRF-Token: ${CSRF_TOKEN}")
        warn "API-токен не имеет прав на изменение — переключаюсь на вход по логину/паролю."
        continue
      fi
      rm -f "$COOKIE_FILE"
      COOKIE_FILE=''
    fi

    # The add may have succeeded even if the response was lost.
    if INBOUND_ID="$(find_inbound_id)"; then
      if [[ -n "$INBOUND_ID" ]]; then
        ADDED=1
        break
      fi
    fi

    ERR_TEXT="$(api_error_text "$RESP")"
    warn "Панель не приняла inbound (попытка ${attempt}/10): HTTP ${ADD_CODE}: ${ERR_TEXT:0:800}"

    if [[ "$ERR_TEXT" == *"Duplicate email"* || "$ERR_TEXT" == *"UNIQUE constraint failed"* || "$ERR_TEXT" == *"duplicate key"* ]]; then
      DEDUP_SUFFIX="$(openssl rand -hex 3)"
      CLIENTS_JSON="$(jq -c --arg s "$DEDUP_SUFFIX" \
        'map(.email = (.email + "-" + $s))' <<< "$CLIENTS_JSON")"
      SETTINGS_JSON="$(jq -n --argjson clients "$CLIENTS_JSON" \
        '{clients:$clients, decryption:"none", encryption:"none"}')"
      INBOUND_JSON="$(jq --argjson settings "$SETTINGS_JSON" \
        '.settings = $settings' <<< "$INBOUND_JSON")"
      warn "Email уже занят в панели — повторяю с новыми email (${DEDUP_SUFFIX})."
    fi

    if [[ "$ERR_TEXT" == *"port 443"* && "$ERR_TEXT" == *"already used by inbound"* ]]; then
      CONFLICT_TAG="$(sed -n "s/.*already used by inbound '\([^']*\)'.*/\1/p" <<< "$ERR_TEXT" | head -n1)"
      if [[ -n "$CONFLICT_TAG" && "$CONFLICT_TAG" != "$INBOUND_TAG" ]]; then
        api_get "/panel/api/inbounds/list" 2>/dev/null \
          | jq --arg tag "$CONFLICT_TAG" '.obj[]? | select(.tag==$tag)' \
          > "${RESULT_DIR}/conflict-443-inbound.json" 2>/dev/null || true
        warn "Порт 443 уже занят inbound '${CONFLICT_TAG}'."
        warn "Его настройки сохранены: ${RESULT_DIR}/conflict-443-inbound.json"
        warn "Удалите или переключите этот inbound в панели и запустите установку снова."
        break
      fi
    fi

    if ! curl -ksS -o /dev/null --max-time 2 "${BASE}/" 2>/dev/null; then
      restart_panel || true
    fi
    sleep 3
  done
  if [[ "$ADDED" != "1" ]]; then
    warn "Последние строки журнала x-ui:"
    if [[ -f /var/log/x-ui/x-ui.log ]]; then
      tail -n 30 /var/log/x-ui/x-ui.log 2>/dev/null || true
    fi
    journalctl -u x-ui -n 30 --no-pager 2>/dev/null | tail -n 30 || true
    die "Панель не приняла VLESS inbound после 10 попыток. Причина указана выше."
  fi

  if [[ -z "${INBOUND_ID:-}" ]]; then
    INBOUND_ID="$(jq -r '.obj.id // empty' <<< "$RESP" 2>/dev/null || true)"
  fi
  if [[ -z "${INBOUND_ID:-}" ]]; then
    INBOUND_ID="$(find_inbound_id)" || die "Панель не отвечает при поиске inbound."
  fi
  [[ -n "$INBOUND_ID" ]] || die "Панель не вернула id inbound."
  ok "VLESS inbound создан (id=$INBOUND_ID)."
fi

# If Xray did not pick up the inbound, restart the panel once and wait again.
XRAY_LISTENING=0
for attempt in 1 2; do
  for _ in $(seq 1 20); do
    if ss -H -ltnp 2>/dev/null | grep -q ':443 .*xray'; then
      XRAY_LISTENING=1
      break
    fi
    sleep 1
  done
  [[ "$XRAY_LISTENING" == "1" ]] && break
  if [[ "$attempt" == "1" ]]; then
    warn "Xray пока не слушает 443 — перезапускаю x-ui."
    restart_panel || true
    sleep 3
  fi
done
if [[ "$XRAY_LISTENING" != "1" ]]; then
  warn "Кто слушает TCP 443:"
  ss -H -ltnp 2>/dev/null | grep ':443 ' || warn "  никто"
  warn "Последние строки журнала x-ui:"
  if [[ -f /var/log/x-ui/x-ui.log ]]; then
    tail -n 30 /var/log/x-ui/x-ui.log 2>/dev/null || true
  fi
  journalctl -u x-ui -n 30 --no-pager 2>/dev/null | tail -n 30 || true
  die "Xray не слушает TCP 443. Проверьте: systemctl status x-ui и /var/log/x-ui/x-ui.log"
fi

# Build share links (compat format: works in v2rayNG, NekoBox, Hiddify, v2rayN).
PATH_ENC="$(jq -rn --arg v "$XHTTP_PATH" '$v|@uri')"
for i in "${!CLIENT_NAMES[@]}"; do
  name="${CLIENT_NAMES[$i]}"
  uuid="${CLIENT_UUIDS[$i]}"
  name_enc="$(jq -rn --arg v "$name" '$v|@uri')"
  link="vless://${uuid}@${VPN_PUBLIC_HOST}:443?encryption=none&fp=chrome&host=&mode=${LINK_MODE:-auto}&path=${PATH_ENC}&pbk=${REALITY_PUBLIC_KEY}&security=reality&sid=${SHORT_ID}&sni=${SNI}&type=xhttp#${name_enc}"
  CLIENT_LINKS+=("$link")
  if ! qrencode -o "${RESULT_DIR}/qr-${name}.png" -s 8 -m 2 "$link" 2>/dev/null; then
    warn "Не удалось сделать QR для клиента $name."
  fi
done
ok "Ссылки и QR готовы."

# =============================================================================
#  HYSTERIA2 (OPTIONAL)
# =============================================================================
if [[ "$VPN_ENABLE_HY2" == "1" ]]; then
  step "Настройка Hysteria2 (UDP 443)"
  mkdir -p "$CERT_DIR"
  chmod 700 "$CERT_DIR"
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${CERT_DIR}/hysteria2-key.pem" \
    -out "${CERT_DIR}/hysteria2-cert.pem" \
    -days 3650 -subj "/CN=${SNI}" \
    -addext "subjectAltName=DNS:${SNI}" >/dev/null 2>&1 \
    || die "Не удалось создать сертификат Hysteria2."
  chmod 600 "${CERT_DIR}/hysteria2-key.pem"
  cp -f "${CERT_DIR}/hysteria2-cert.pem" "${RESULT_DIR}/hysteria2-cert.pem"
  cp -f "${CERT_DIR}/hysteria2-key.pem" "${RESULT_DIR}/hysteria2-key.pem"

  PIN_B64="$(openssl x509 -in "${CERT_DIR}/hysteria2-cert.pem" -outform DER \
    | openssl dgst -sha256 -binary | base64 -w0)"
  PIN_HEX="$(openssl x509 -in "${CERT_DIR}/hysteria2-cert.pem" -outform DER \
    | openssl dgst -sha256 | awk '{print $2}')"

  for i in "${!CLIENT_NAMES[@]}"; do
    name="${CLIENT_NAMES[$i]}"
    auth="$(openssl rand -hex 16)"
    subid="$(openssl rand -hex 8)"
    email="hy2-$((i+1))-${name}"
    HY2_AUTHS+=("$auth")
    client_json="$(jq -n \
      --arg auth "$auth" \
      --arg email "$email" \
      --arg subId "$subid" \
      '{auth:$auth, email:$email, limitIp:0, totalGB:0, expiryTime:0, enable:true, tgId:0, subId:$subId}')"
    HY2_CLIENTS_JSON="$(jq -c --argjson c "$client_json" '. + [$c]' <<< "$HY2_CLIENTS_JSON")"
  done

  HY2_SETTINGS="$(jq -n --argjson clients "$HY2_CLIENTS_JSON" \
    '{clients:$clients, version:2}')"

  HY2_STREAM="$(jq -n \
    --arg sni "$SNI" \
    --arg cert "${CERT_DIR}/hysteria2-cert.pem" \
    --arg key "${CERT_DIR}/hysteria2-key.pem" \
    --arg pin "$PIN_B64" \
    '{
      network:"hysteria",
      security:"tls",
      hysteriaSettings:{version:2, udpIdleTimeout:60},
      tlsSettings:{
        serverName:$sni, minVersion:"1.3", maxVersion:"1.3", cipherSuites:"",
        rejectUnknownSni:false, disableSystemRoot:false, enableSessionResumption:false,
        certificates:[{certificateFile:$cert, keyFile:$key, oneTimeLoading:false, usage:"encipherment", buildChain:false}],
        alpn:["h3"], echServerKeys:"",
        settings:{fingerprint:"", echConfigList:"", pinnedPeerCertSha256:[$pin], verifyPeerCertByName:""}
      }
    }')"

  HY2_INBOUND="$(jq -n \
    --arg remark "Hysteria2-UDP-443" \
    --arg tag "inbound-hysteria2-udp-443" \
    --argjson settings "$HY2_SETTINGS" \
    --argjson streamSettings "$HY2_STREAM" \
    '{
      up:0, down:0, total:0, remark:$remark, tag:$tag,
      subSortIndex:2, excludeFromSub:false, enable:true, expiryTime:0,
      trafficReset:"never", trafficResetDay:1,
      listen:"", port:443, protocol:"hysteria",
      settings:$settings, streamSettings:$streamSettings, sniffing:{enabled:false},
      shareAddrStrategy:"node", shareAddr:""
    }')"

  HY2_BODY="$(mktemp)"
  HY2_CODE="$(curl -ksS --max-time 15 -o "$HY2_BODY" -w '%{http_code}' -X POST "${API_AUTH[@]}" \
      -H "Content-Type: application/json" \
      --data-binary "$HY2_INBOUND" \
      "${BASE}/panel/api/inbounds/add" 2>/dev/null)" || HY2_CODE="000"
  HY2_RESP="$(cat "$HY2_BODY" 2>/dev/null || true)"
  rm -f "$HY2_BODY"
  if [[ "$HY2_CODE" == "200" ]] && jq -e '.success == true' >/dev/null 2>&1 <<< "$HY2_RESP"; then
    HY2_INBOUND_ID="$(jq -r '.obj.id // empty' <<< "$HY2_RESP")"
    HY2_ENABLED=1
    ok "Hysteria2 inbound создан (id=$HY2_INBOUND_ID)."
    for i in "${!CLIENT_NAMES[@]}"; do
      name="${CLIENT_NAMES[$i]}"
      name_enc="$(jq -rn --arg v "$name" '$v|@uri')"
      link="hysteria2://${HY2_AUTHS[$i]}@${VPN_PUBLIC_HOST}:443/?alpn=h3&insecure=1&pinSHA256=${PIN_HEX}&security=tls&sni=${SNI}#${name_enc}-hy2"
      HY2_LINKS+=("$link")
      qrencode -o "${RESULT_DIR}/qr-${name}-hy2.png" -s 8 -m 2 "$link" 2>/dev/null || true
    done
  else
    HY2_ENABLED=0
    warn "Hysteria2 не создался (HTTP ${HY2_CODE}): $(api_error_text "$HY2_RESP")."
    warn "VLESS продолжит работать. Hysteria2 можно добавить позже в панели."
  fi
else
  info "Hysteria2 отключён (по выбору)."
fi

# =============================================================================
#  AMNEZIAWG (OPTIONAL, NO DOCKER)
# =============================================================================
install_amneziawg() {
  step "AmneziaWG (UDP ${AWG_PORT})"
  if [[ "$AWG_SKIP" == "1" ]]; then
    warn "Amnezia/AmneziaWG уже есть на сервере — установщик её не трогает."
    return 0
  fi

  info "Ставлю официальный AmneziaWG из репозитория Amnezia (без Docker)."
  # Separate transactions: if headers for the running kernel are no longer in
  # the archive, an all-in-one apt call fails and dkms would not install either.
  apt-get install -y --no-install-recommends \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    software-properties-common python3-launchpadlib gnupg2 dkms linux-headers-generic \
    >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends "linux-headers-$(uname -r)" >/dev/null 2>&1 || true

  running_kernel="$(uname -r)"
  newest_kernel="$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -n1 || true)"
  kernel_stale=0
  if [[ -n "$newest_kernel" && "$newest_kernel" != "$running_kernel" ]]; then
    kernel_stale=1
    warn "Ядро устарело: работает ${running_kernel}, установлено ${newest_kernel}."
    warn "AmneziaWG собирается под работающее ядро — вероятно, понадобится перезагрузка."
  fi

  if [[ "${ID}" == "ubuntu" ]]; then
    if ! add-apt-repository -y ppa:amnezia/ppa >/dev/null 2>&1; then
      warn "Не удалось подключить официальный PPA Amnezia. AmneziaWG пропущен."
      return 0
    fi
  else
    # Official Amnezia instructions use the Ubuntu focal repository on Debian.
    install -d -m 0755 /etc/apt/keyrings
    if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 60 \
      "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x75C9DD72C799870E310542E24166F2C257290828" \
      | gpg --dearmor --yes -o /etc/apt/keyrings/amneziawg.gpg 2>/dev/null; then
      warn "Не удалось получить официальный ключ Amnezia. AmneziaWG пропущен."
      return 0
    fi
    echo "deb [signed-by=/etc/apt/keyrings/amneziawg.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main" \
      > /etc/apt/sources.list.d/amneziawg.list
  fi

  apt-get update -y -o Acquire::Retries=3 >/dev/null 2>&1 || true
  awg_apt_log="$(mktemp)"
  awg_apt_ok=1
  if ! apt-get install -y --no-install-recommends \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" amneziawg >"$awg_apt_log" 2>&1; then
    # Usually DKMS fails to build on an older kernel. The sources are patched
    # below and the module is built by hand, so do not give up here.
    awg_apt_ok=0
    warn "Пакет AmneziaWG установился не полностью (обычно сборка модуля на старом ядре)."
    tail -n 8 "$awg_apt_log" 2>/dev/null | sed 's/^/      /' || true
  fi
  rm -f "$awg_apt_log" 2>/dev/null || true

  if ! command -v awg >/dev/null 2>&1 || ! command -v awg-quick >/dev/null 2>&1; then
    warn "Не найдены awg/awg-quick. AmneziaWG пропущен."
    return 0
  fi
  # AmneziaWG sources call timer_delete(), which appeared in Linux 6.2.
  # On older kernels (Ubuntu 22.04, 5.15) the module fails to build with
  # "implicit declaration of function 'timer_delete'". Patch the DKMS
  # sources once and use del_timer_sync() instead.
  if [[ -d "/lib/modules/$(uname -r)/build" ]] && \
     ! grep -qs 'timer_delete' "/lib/modules/$(uname -r)/build/include/linux/timer.h"; then
    for awg_src in /usr/src/amneziawg-*/; do
      [[ -d "$awg_src" ]] || continue
      if grep -qs 'timer_delete(' "$awg_src"*.c 2>/dev/null; then
        sed -i 's/timer_delete(/del_timer_sync(/g' "$awg_src"*.c 2>/dev/null || true
        info "AmneziaWG: исходник адаптирован под старое ядро (timer_delete -> del_timer_sync)."
      fi
    done
  fi
  if (( awg_apt_ok == 0 )) && command -v dkms >/dev/null 2>&1; then
    # Sources are patched now: force a rebuild for the running kernel, then
    # finish the interrupted package configuration.
    awg_ver="$(dkms status 2>/dev/null | sed -n 's|^amneziawg/\([^,]*\),.*|\1|p' | head -n1)"
    if [[ -n "$awg_ver" ]]; then
      dkms build -m amneziawg -v "$awg_ver" -k "$(uname -r)" --force >/dev/null 2>&1 || true
      dkms install -m amneziawg -v "$awg_ver" -k "$(uname -r)" --force >/dev/null 2>&1 || true
    fi
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a >/dev/null 2>&1 || true
  fi
  if ! modprobe amneziawg >/dev/null 2>&1; then
    # Module may be present but not registered yet: try building it once.
    dkms autoinstall >/dev/null 2>&1 || true
    modprobe amneziawg >/dev/null 2>&1 || true
  fi
  if ! lsmod 2>/dev/null | grep -q '^amneziawg'; then
    warn "Модуль ядра amneziawg не загрузился. Нужны kernel headers и DKMS."
    if (( kernel_stale == 1 )); then
      warn "Причина: работает старое ядро ${running_kernel}, установлено ${newest_kernel}."
      warn "Перезагрузите сервер и запустите «Продолжить установку VPN» — AmneziaWG поставится."
    fi
    warn "AmneziaWG пропущен; VLESS продолжит работать."
    return 0
  fi

  for candidate in 10.66.66 10.67.67 10.68.68 10.69.69; do
    if ! ip route 2>/dev/null | grep -q "^${candidate}\\."; then
      AWG_SUBNET="$candidate"
      break
    fi
  done

  AWG_JC="$(shuf -i 4-12 -n 1)"
  AWG_JMIN="$(shuf -i 8-80 -n 1)"
  AWG_JMAX="$(shuf -i $((AWG_JMIN + 20))-1280 -n 1)"
  AWG_S1="$(shuf -i 15-150 -n 1)"
  AWG_S2="$(shuf -i 15-150 -n 1)"
  while (( AWG_S1 + 56 == AWG_S2 )); do
    AWG_S2="$(shuf -i 15-150 -n 1)"
  done
  mapfile -t AWG_H < <(shuf -i 5-2147483647 -n 4)
  if (( ${#AWG_H[@]} != 4 )); then
    warn "Не удалось сгенерировать параметры AmneziaWG. Пропуск."
    return 0
  fi

  AWG_SERVER_PRIVATE="$(awg genkey 2>/dev/null || true)"
  AWG_SERVER_PUBLIC="$(printf '%s' "$AWG_SERVER_PRIVATE" | awg pubkey 2>/dev/null || true)"
  if [[ -z "$AWG_SERVER_PRIVATE" || -z "$AWG_SERVER_PUBLIC" ]]; then
    warn "Не удалось сгенерировать ключи AmneziaWG. Пропуск."
    return 0
  fi

  AWG_WAN_IF="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
  [[ -n "$AWG_WAN_IF" ]] || AWG_WAN_IF="eth0"

  AWG_CONF="/etc/amnezia/amneziawg/awg0.conf"
  if [[ -f "$AWG_CONF" ]]; then
    warn "AmneziaWG уже настроен (${AWG_CONF}) — конфиг не перезаписываю."
    AWG_PORT="$(awk -F' = ' '/^ListenPort/{print $2; exit}' "$AWG_CONF" 2>/dev/null || true)"
    [[ -n "$AWG_PORT" && "$AWG_PORT" != "auto" ]] || AWG_PORT="51820"
    AWG_SUBNET="$(awk -F' = ' '/^Address/{split($2,a,"/"); split(a[1],b,"."); print b[1]"."b[2]"."b[3]; exit}' "$AWG_CONF" 2>/dev/null || true)"
    [[ -n "$AWG_SUBNET" ]] || AWG_SUBNET="10.66.66"
    systemctl enable awg-quick@awg0 >/dev/null 2>&1 || true
    if ! systemctl is-active --quiet awg-quick@awg0; then
      systemctl reset-failed awg-quick@awg0 >/dev/null 2>&1 || true
      systemctl start awg-quick@awg0 >/dev/null 2>&1 || true
    fi
    if ! awg show awg0 >/dev/null 2>&1; then
      warn "AmneziaWG настроен, но интерфейс awg0 не поднялся. Проверьте: systemctl status awg-quick@awg0"
      return 0
    fi
    AWG_SERVER_PUBLIC="$(awg show awg0 public-key 2>/dev/null || true)"
    AWG_ENABLED=1
    # Reuse client configs from the previous run so the QR codes still work.
    prev_dir="$(ls -1d /root/vpn-result-* 2>/dev/null | sort | tail -n2 | head -n1 || true)"
    if [[ -n "$prev_dir" && "$prev_dir" != "$RESULT_DIR" ]]; then
      cp -f "${prev_dir}"/amnezia-*.conf "$RESULT_DIR"/ 2>/dev/null || true
      cp -f "${prev_dir}"/qr-*-awg.png "$RESULT_DIR"/ 2>/dev/null || true
    fi
    for i in "${!CLIENT_NAMES[@]}"; do
      name="${CLIENT_NAMES[$i]}"
      conf_file="${RESULT_DIR}/amnezia-${name}.conf"
      [[ -f "$conf_file" ]] || continue
      qr_b64=""
      if [[ -f "${RESULT_DIR}/qr-${name}-awg.png" ]]; then
        qr_b64="$(base64 -w0 "${RESULT_DIR}/qr-${name}-awg.png")"
      fi
      item="$(jq -n \
        --arg name "$name" \
        --arg ip "${AWG_SUBNET}.$((i + 2))" \
        --arg config "$(cat "$conf_file")" \
        --arg qr "$qr_b64" \
        '{name:$name, ip:$ip, config:$config, qr_png_base64:$qr}')"
      AWG_CLIENTS_JSON="$(jq -c --argjson item "$item" '. + [$item]' <<< "$AWG_CLIENTS_JSON")"
    done
    ok "AmneziaWG уже работает: UDP ${AWG_PORT}, интерфейс awg0."
    return 0
  fi
  mkdir -p /etc/amnezia/amneziawg
  chmod 700 /etc/amnezia/amneziawg

  cat > "$AWG_CONF" <<AWG_EOF
[Interface]
Address = ${AWG_SUBNET}.1/24
ListenPort = ${AWG_PORT}
PrivateKey = ${AWG_SERVER_PRIVATE}
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
H1 = ${AWG_H[0]}
H2 = ${AWG_H[1]}
H3 = ${AWG_H[2]}
H4 = ${AWG_H[3]}
MTU = 1280
PostUp = iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i awg0 -j ACCEPT; iptables -C FORWARD -o awg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o awg0 -j ACCEPT; iptables -t nat -C POSTROUTING -s ${AWG_SUBNET}.0/24 -o ${AWG_WAN_IF} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${AWG_SUBNET}.0/24 -o ${AWG_WAN_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i awg0 -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -o awg0 -j ACCEPT 2>/dev/null || true; iptables -t nat -D POSTROUTING -s ${AWG_SUBNET}.0/24 -o ${AWG_WAN_IF} -j MASQUERADE 2>/dev/null || true
AWG_EOF

  for i in "${!CLIENT_NAMES[@]}"; do
    name="${CLIENT_NAMES[$i]}"
    awg_priv="$(awg genkey 2>/dev/null || true)"
    awg_pub="$(printf '%s' "$awg_priv" | awg pubkey 2>/dev/null || true)"
    awg_psk="$(awg genpsk 2>/dev/null || true)"
    if [[ -z "$awg_priv" || -z "$awg_pub" || -z "$awg_psk" ]]; then
      warn "Не удалось создать ключи AmneziaWG для ${name}. Пропуск клиента."
      continue
    fi
    awg_ip="${AWG_SUBNET}.$((i + 2))"
    cat > "${RESULT_DIR}/amnezia-${name}.conf" <<CLIENT_EOF
[Interface]
PrivateKey = ${awg_priv}
Address = ${awg_ip}/32
DNS = 1.1.1.1, 8.8.8.8
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
H1 = ${AWG_H[0]}
H2 = ${AWG_H[1]}
H3 = ${AWG_H[2]}
H4 = ${AWG_H[3]}
MTU = 1280

[Peer]
PublicKey = ${AWG_SERVER_PUBLIC}
PresharedKey = ${awg_psk}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${VPN_PUBLIC_HOST}:${AWG_PORT}
PersistentKeepalive = 25
CLIENT_EOF
    chmod 600 "${RESULT_DIR}/amnezia-${name}.conf"
    qrencode -o "${RESULT_DIR}/qr-${name}-awg.png" -s 8 -m 2 \
      < "${RESULT_DIR}/amnezia-${name}.conf" 2>/dev/null || true
    cat >> "$AWG_CONF" <<PEER_EOF

# client: ${name}
[Peer]
PublicKey = ${awg_pub}
PresharedKey = ${awg_psk}
AllowedIPs = ${awg_ip}/32
PEER_EOF
  done

  chmod 600 "$AWG_CONF"
  # Forwarding must survive a reboot, otherwise clients connect but have no internet.
  printf 'net.ipv4.ip_forward = 1\n' > /etc/sysctl.d/99-awg-forward.conf
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  systemctl enable awg-quick@awg0 >/dev/null 2>&1 || true
  # A leftover interface (re-run / resume) makes "restart" fail with
  # "awg0 already exists", so clear it first.
  systemctl stop awg-quick@awg0 >/dev/null 2>&1 || true
  ip link del awg0 >/dev/null 2>&1 || true
  systemctl reset-failed awg-quick@awg0 >/dev/null 2>&1 || true
  if ! systemctl start awg-quick@awg0 >/dev/null 2>&1; then
    warn "AmneziaWG не запустился. Конфиг удалён, VLESS продолжит работать."
    systemctl disable awg-quick@awg0 >/dev/null 2>&1 || true
    rm -f "$AWG_CONF" "${RESULT_DIR}"/amnezia-*.conf "${RESULT_DIR}"/qr-*-awg.png
    return 0
  fi
  sleep 1
  if ! awg show awg0 >/dev/null 2>&1; then
    warn "Интерфейс awg0 не поднялся. AmneziaWG пропущен; VLESS работает."
    systemctl disable awg-quick@awg0 >/dev/null 2>&1 || true
    rm -f "$AWG_CONF" "${RESULT_DIR}"/amnezia-*.conf "${RESULT_DIR}"/qr-*-awg.png
    return 0
  fi

  AWG_ENABLED=1
  for i in "${!CLIENT_NAMES[@]}"; do
    name="${CLIENT_NAMES[$i]}"
    conf_file="${RESULT_DIR}/amnezia-${name}.conf"
    [[ -f "$conf_file" ]] || continue
    config_text="$(cat "$conf_file")"
    qr_b64=""
    if [[ -f "${RESULT_DIR}/qr-${name}-awg.png" ]]; then
      qr_b64="$(base64 -w0 "${RESULT_DIR}/qr-${name}-awg.png")"
    fi
    item="$(jq -n \
      --arg name "$name" \
      --arg ip "${AWG_SUBNET}.$((i + 2))" \
      --arg config "$config_text" \
      --arg qr "$qr_b64" \
      '{name:$name, ip:$ip, config:$config, qr_png_base64:$qr}')"
    AWG_CLIENTS_JSON="$(jq -c --argjson item "$item" '. + [$item]' <<< "$AWG_CLIENTS_JSON")"
  done
  ok "AmneziaWG запущен: UDP ${AWG_PORT}, интерфейс awg0."
}

if [[ "$VPN_ENABLE_AWG" == "1" ]]; then
  install_amneziawg || warn "AmneziaWG не установился. VLESS продолжит работать."
else
  info "AmneziaWG отключён (по выбору)."
fi

# =============================================================================
#  SYSCTL / BBR
# =============================================================================
step "Сетевая оптимизация (BBR + TCP)"
cat > /etc/sysctl.d/99-vpn-tuning.conf <<'SYSCTL_EOF'
# VPN tuning: BBR, fq, larger TCP buffers, no slow start after idle.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 1024 65535
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432
# A browser with QUIC opens hundreds of flows: the default 8192 conntrack
# entries overflow and new connections get dropped (slow pages, broken video).
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 300
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
SYSCTL_EOF

if [[ "$AWG_ENABLED" == "1" ]]; then
  printf 'net.ipv4.ip_forward = 1\n' > /etc/sysctl.d/99-vpn-awg.conf
  ok "IP forwarding включён для AmneziaWG."
fi

modprobe tcp_bbr 2>/dev/null || true
echo "tcp_bbr" > /etc/modules-load.d/vpn-bbr.conf
sysctl --system >/dev/null 2>&1 || warn "sysctl применился не полностью."
CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
if [[ "$CC" == "bbr" ]]; then
  ok "BBR включён, qdisc=fq, буферы 32 MB."
else
  warn "BBR не включился (сейчас: $CC). VPN продолжит работать."
fi

# =============================================================================
#  FIREWALL
# =============================================================================
step "Настройка firewall"

SSH_PORTS="$VPN_SSH_PORT"
if [[ "$DETECTED_SSH_PORT" != "$VPN_SSH_PORT" ]]; then
  SSH_PORTS="$SSH_PORTS $DETECTED_SSH_PORT"
fi
ORIG_POLICY="$(iptables -S INPUT 2>/dev/null | awk '/^-P INPUT /{print $3; exit}')"
[[ -n "$ORIG_POLICY" ]] || ORIG_POLICY="ACCEPT"

cat > /usr/local/sbin/vpn-firewall.sh <<'FIREWALL_EOF'
#!/bin/bash
# VPN firewall. Only touches its own VPN-FW chain; never flushes INPUT.
set -e

SSH_PORTS="__SSH_PORTS__"
PANEL_PORT="__PANEL_PORT__"
PANEL_PUBLIC="__PANEL_PUBLIC__"
ENABLE_HY2="__ENABLE_HY2__"
ENABLE_AWG="__ENABLE_AWG__"
AWG_PORT="__AWG_PORT__"
HAS_DOCKER="__HAS_DOCKER__"
HARDEN="__HARDEN__"

# If ufw is already active, add rules through ufw instead of raw iptables.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  for p in $SSH_PORTS; do ufw allow "$p"/tcp >/dev/null 2>&1 || true; done
  ufw allow 443/tcp >/dev/null 2>&1 || true
  if [ "$ENABLE_HY2" = "1" ]; then
    ufw allow 443/udp >/dev/null 2>&1 || true
  fi
  if [ "$ENABLE_AWG" = "1" ]; then
    ufw allow "$AWG_PORT"/udp >/dev/null 2>&1 || true
  fi
  if [ "$PANEL_PUBLIC" = "1" ]; then
    ufw allow "$PANEL_PORT"/tcp >/dev/null 2>&1 || true
  fi
  # 3x-ui always keeps its subscription server on 2096; we do not use it.
  if [ "$PANEL_PORT" != "2096" ]; then
    ufw deny 2096/tcp >/dev/null 2>&1 || true
  fi
  # Otherwise the panel listens on 127.0.0.1 only, so no extra ufw deny is needed.
  exit 0
fi

iptables -N VPN-FW 2>/dev/null || true
iptables -F VPN-FW
iptables -A VPN-FW -i lo -j ACCEPT
if [ "$HARDEN" = "1" ]; then
  # Drop malformed packets and TCP frames that cannot start a connection.
  iptables -A VPN-FW -m conntrack --ctstate INVALID -j DROP
  iptables -A VPN-FW -p tcp ! --syn -m conntrack --ctstate NEW -j DROP
fi
iptables -A VPN-FW -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A VPN-FW -p icmp -j ACCEPT
for p in $SSH_PORTS; do
  iptables -A VPN-FW -p tcp --dport "$p" -j ACCEPT
done
iptables -A VPN-FW -p tcp --dport 443 -j ACCEPT
if [ "$ENABLE_HY2" = "1" ]; then
  iptables -A VPN-FW -p udp --dport 443 -j ACCEPT
fi
if [ "$ENABLE_AWG" = "1" ]; then
  iptables -A VPN-FW -p udp --dport "$AWG_PORT" -j ACCEPT
fi
if [ "$PANEL_PUBLIC" = "1" ]; then
  iptables -A VPN-FW -p tcp --dport "$PANEL_PORT" -j ACCEPT
else
  iptables -A VPN-FW -p tcp --dport "$PANEL_PORT" -j DROP
fi
# 3x-ui always keeps its subscription server on 2096; it cannot be disabled in
# the DB, so keep that port closed unless the panel itself uses it.
if [ "$PANEL_PORT" != "2096" ]; then
  iptables -A VPN-FW -p tcp --dport 2096 -j DROP
fi

if [ "$HAS_DOCKER" = "1" ]; then
  # Do not change the host policy when Docker is present; only our ports are managed.
  iptables -A VPN-FW -j RETURN
else
  iptables -A VPN-FW -j DROP
fi

iptables -C INPUT -j VPN-FW 2>/dev/null || iptables -I INPUT 1 -j VPN-FW
if [ "$HAS_DOCKER" = "0" ]; then
  iptables -P INPUT DROP
fi

# Clients on mobile networks often have a smaller MTU: without clamping, big
# packets stall and pages load halfway. Append-only, safe with Docker.
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
  iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
FIREWALL_EOF

sed -i \
  -e "s/__SSH_PORTS__/${SSH_PORTS}/g" \
  -e "s/__PANEL_PORT__/${VPN_PANEL_PORT}/g" \
  -e "s/__PANEL_PUBLIC__/${PANEL_PUBLIC}/g" \
  -e "s/__ENABLE_HY2__/${VPN_ENABLE_HY2}/g" \
  -e "s/__ENABLE_AWG__/${AWG_ENABLED}/g" \
  -e "s/__AWG_PORT__/${AWG_PORT:-0}/g" \
  -e "s/__HAS_DOCKER__/${HAS_DOCKER}/g" \
  -e "s/__HARDEN__/${VPN_HARDEN}/g" \
  /usr/local/sbin/vpn-firewall.sh
chmod 755 /usr/local/sbin/vpn-firewall.sh

cat > /usr/local/sbin/vpn-firewall-rollback.sh <<ROLLBACK_EOF
#!/bin/bash
# Safety rollback: runs 15 minutes after install. If the install did not finish,
# remove the VPN-FW jump and restore the original INPUT policy.
if [ -f /root/.vpn-install-success ]; then
  rm -f /root/.vpn-install-success
  exit 0
fi
iptables -D INPUT -j VPN-FW 2>/dev/null || true
iptables -F VPN-FW 2>/dev/null || true
iptables -X VPN-FW 2>/dev/null || true
if [ "${ORIG_POLICY}" = "ACCEPT" ]; then
  iptables -P INPUT ACCEPT 2>/dev/null || true
fi
ROLLBACK_EOF
chmod 755 /usr/local/sbin/vpn-firewall-rollback.sh

# Schedule the safety rollback before applying anything.
if ! systemd-run --on-active=15min --unit=vpn-firewall-rollback \
  --description="VPN firewall rollback" /usr/local/sbin/vpn-firewall-rollback.sh >/dev/null 2>&1; then
  nohup bash -c 'sleep 900; /usr/local/sbin/vpn-firewall-rollback.sh' >/dev/null 2>&1 &
fi

/usr/local/sbin/vpn-firewall.sh
sleep 2
ok "Firewall применён: SSH ${SSH_PORTS}, TCP 443$([[ "$VPN_ENABLE_HY2" == "1" ]] && echo ', UDP 443')$([[ "$AWG_ENABLED" == "1" ]] && echo ", UDP ${AWG_PORT} (AmneziaWG)"), панель $([[ "$PANEL_PUBLIC" == "1" ]] && echo "TCP ${VPN_PANEL_PORT} (HTTPS)" || echo 'только через туннель')."

cat > /etc/systemd/system/vpn-firewall.service <<'SERVICE_EOF'
[Unit]
Description=VPN firewall rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpn-firewall.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable vpn-firewall.service >/dev/null 2>&1 || true
ok "Правила firewall сохранены для автозапуска."

# =============================================================================
#  PANEL: HTTPS + ACCESS FROM THE INTERNET (optional)
# =============================================================================
if [[ "$PANEL_PUBLIC" == "1" ]]; then
  step "Панель: HTTPS и доступ из интернета"
  install -d -m 0700 /etc/x-ui
  panel_https_ok=0
  if openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout /etc/x-ui/panel.key -out /etc/x-ui/panel.crt \
      -subj "/CN=${VPN_PUBLIC_HOST}" \
      -addext "subjectAltName=IP:${VPN_PUBLIC_HOST}" >/dev/null 2>&1; then
    chmod 600 /etc/x-ui/panel.key
    chmod 644 /etc/x-ui/panel.crt
    if /usr/local/x-ui/x-ui setting -webCert /etc/x-ui/panel.crt -webCertKey /etc/x-ui/panel.key >/dev/null 2>&1; then
      systemctl reset-failed x-ui >/dev/null 2>&1 || true
      systemctl restart x-ui >/dev/null 2>&1 || true
      for _ in $(seq 1 40); do
        if curl -sk -o /dev/null --max-time 3 "https://127.0.0.1:${VPN_PANEL_PORT}/${VPN_PANEL_PATH}/" 2>/dev/null; then
          panel_https_ok=1
          break
        fi
        sleep 1
      done
    else
      warn "Панель не приняла сертификат (флаг -webCertKey)."
    fi
  else
    warn "Не удалось создать самоподписанный сертификат."
  fi

  if (( panel_https_ok == 1 )); then
    /usr/local/x-ui/x-ui setting -listenIP "0.0.0.0" >/dev/null 2>&1 || true
    systemctl restart x-ui >/dev/null 2>&1 || true
    panel_public_ok=0
    for _ in $(seq 1 40); do
      if curl -sk -o /dev/null --max-time 3 "https://127.0.0.1:${VPN_PANEL_PORT}/${VPN_PANEL_PATH}/" 2>/dev/null; then
        panel_public_ok=1
        break
      fi
      sleep 1
    done
    if (( panel_public_ok == 1 )); then
      PANEL_EFFECTIVE_PUBLIC=1
      ok "Панель: ${PANEL_URL}"
      ok "Сертификат самоподписанный — браузер один раз предупредит."
    else
      warn "Панель не поднялась на 0.0.0.0 — оставляю HTTPS только через туннель."
      /usr/local/x-ui/x-ui setting -listenIP "127.0.0.1" >/dev/null 2>&1 || true
      systemctl restart x-ui >/dev/null 2>&1 || true
      # Keep the certificate: the tunnel works fine with HTTPS on loopback.
      PANEL_SCHEME="https"
      PANEL_URL="https://127.0.0.1:${VPN_PANEL_PORT}/${VPN_PANEL_PATH}/"
    fi
  fi

  if (( panel_https_ok == 0 )); then
    # Roll back to plain HTTP on loopback so the panel stays reachable.
    /usr/local/x-ui/x-ui setting -webCert "" -webCertKey "" >/dev/null 2>&1 || true
    /usr/local/x-ui/x-ui setting -listenIP "127.0.0.1" >/dev/null 2>&1 || true
    systemctl restart x-ui >/dev/null 2>&1 || true
    PANEL_SCHEME="http"
    PANEL_URL="http://127.0.0.1:${VPN_PANEL_PORT}/${VPN_PANEL_PATH}/"
    warn "Панель оставлена на 127.0.0.1 (HTTP). Вход — через «Открыть панель» в меню."
  fi
fi

# =============================================================================
#  HEALTHCHECK + FAIL2BAN
# =============================================================================
step "Защита и самовосстановление"

cat > /usr/local/sbin/vpn-healthcheck.sh <<'HEALTH_EOF'
#!/bin/bash
# Restart x-ui if it is inactive or if its Xray child process disappeared.
set -u
if ! systemctl is-active --quiet x-ui; then
  logger -t vpn-healthcheck "x-ui inactive; restarting"
  systemctl restart x-ui
  exit 0
fi
if ! pgrep -f 'xray-linux' >/dev/null 2>&1; then
  sleep 10
  if ! pgrep -f 'xray-linux' >/dev/null 2>&1; then
    logger -t vpn-healthcheck "xray process missing; restarting x-ui"
    systemctl restart x-ui
  fi
fi
HEALTH_EOF
chmod 755 /usr/local/sbin/vpn-healthcheck.sh

cat > /etc/systemd/system/vpn-healthcheck.service <<'HS_EOF'
[Unit]
Description=VPN health check
After=x-ui.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpn-healthcheck.sh
HS_EOF

cat > /etc/systemd/system/vpn-healthcheck.timer <<'HT_EOF'
[Unit]
Description=Run VPN health check every 2 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=2min
AccuracySec=30s

[Install]
WantedBy=timers.target
HT_EOF

systemctl daemon-reload
if systemctl enable --now vpn-healthcheck.timer >/dev/null 2>&1; then
  ok "Автопроверка x-ui каждые 2 минуты включена."
else
  warn "Не удалось включить автопроверку x-ui. VPN это не ломает."
fi

# fail2ban protects SSH from password guessing. Best effort: never fatal.
f2b_log="$(mktemp)"
if apt-get install -y --no-install-recommends fail2ban python3-systemd >"$f2b_log" 2>&1; then
  rm -f "$f2b_log" 2>/dev/null || true
  F2B_PORTS="$(echo "$SSH_PORTS" | tr ' ' ',')"
  cat > /etc/fail2ban/jail.d/vpn-sshd.local <<F2B_EOF
[sshd]
enabled = true
port = ${F2B_PORTS}
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
F2B_EOF
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban >/dev/null 2>&1 || true
  if systemctl is-active --quiet fail2ban; then
    ok "fail2ban защищает SSH: 5 ошибок → бан на 1 час."
  else
    warn "fail2ban установлен, но не запустился. VPN это не ломает."
  fi
else
  tail -n 8 "$f2b_log" 2>/dev/null | sed 's/^/      /' || true
  rm -f "$f2b_log" 2>/dev/null || true
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a >/dev/null 2>&1 || true
  warn "fail2ban не установился. VPN это не ломает."
fi

# =============================================================================
#  HARDENING (optional)
# =============================================================================
if [[ "$VPN_HARDEN" == "1" ]]; then
  step "Защита сервера"

  cat > /etc/sysctl.d/99-vpn-hardening.conf <<'SYSCTL_EOF'
# Basic network hardening. VPN tunnels and Docker keep working.
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
SYSCTL_EOF
  sysctl --system >/dev/null 2>&1 || true
  if [[ "$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null || echo 0)" == "1" ]]; then
    ok "Сетевые настройки защищены: SYN-cookies, без redirects и source route."
  else
    warn "Не удалось применить часть сетевых настроек. VPN это не ломает."
  fi

  # Automatic security updates only; no automatic reboot.
  upg_log="$(mktemp)"
  if apt-get install -y --no-install-recommends unattended-upgrades >"$upg_log" 2>&1; then
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'UPG_EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
UPG_EOF
    cat > /etc/apt/apt.conf.d/51-vpn-unattended <<'UPG2_EOF'
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}-security";
        "${distro_id}ESMApps:${distro_codename}-apps-security";
        "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
UPG2_EOF
    systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
    if systemctl is-enabled --quiet unattended-upgrades 2>/dev/null; then
      ok "Автообновления безопасности включены (без перезагрузки)."
    else
      warn "Автообновления настроены, но служба не включилась."
    fi
  else
    tail -n 5 "$upg_log" 2>/dev/null | sed 's/^/      /' || true
    warn "unattended-upgrades не установился. VPN это не ломает."
  fi
  rm -f "$upg_log" 2>/dev/null || true

  # Repeat offenders get banned for a week.
  if command -v fail2ban-client >/dev/null 2>&1; then
    cat > /etc/fail2ban/jail.d/vpn-recidive.local <<'REC_EOF'
[recidive]
enabled = true
logpath = /var/log/fail2ban.log
banaction = iptables-allports
bantime = 1w
findtime = 1d
maxretry = 3
REC_EOF
    if fail2ban-client -t >/dev/null 2>&1; then
      systemctl restart fail2ban >/dev/null 2>&1 || true
      if systemctl is-active --quiet fail2ban; then
        ok "Повторные подборы пароля банятся на неделю."
      else
        warn "Правило для повторных нарушителей не применилось."
      fi
    else
      rm -f /etc/fail2ban/jail.d/vpn-recidive.local
      warn "Правило для повторных нарушителей не подошло — оставил базовую защиту."
    fi
  fi
else
  info "Защита сервера не включалась (по выбору)."
fi

# =============================================================================
#  SELF-CHECK
# =============================================================================
step "Проверка установленного"

VERIFY_JSON='[]'
VERIFY_TOTAL=0
VERIFY_PASSED=0

check() {
  local name="$1" state="$2" detail="${3:-}"
  VERIFY_TOTAL=$((VERIFY_TOTAL + 1))
  if [[ "$state" == "1" ]]; then
    VERIFY_PASSED=$((VERIFY_PASSED + 1))
    printf '  [OK] %s\n' "$name"
  else
    printf '  [!!] %s%s\n' "$name" "${detail:+ — $detail}"
  fi
  local okjson="false"
  if [[ "$state" == "1" ]]; then okjson="true"; fi
  VERIFY_JSON="$(jq -c \
    --arg n "$name" \
    --argjson o "$okjson" \
    --arg d "$detail" \
    '. + [{name:$n, ok:$o, detail:$d}]' <<< "$VERIFY_JSON")"
}

if systemctl is-active --quiet x-ui; then
  check "Служба 3x-ui запущена" 1
else
  check "Служба 3x-ui запущена" 0 "systemctl status x-ui"
fi

if pgrep -f 'xray-linux' >/dev/null 2>&1; then
  check "Процесс Xray работает" 1
else
  check "Процесс Xray работает" 0 "перезапустите x-ui"
fi

if ss -H -ltn 2>/dev/null | grep -q ':443 '; then
  check "TCP 443 слушается" 1
else
  check "TCP 443 слушается" 0
fi

panel_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 6 "${PANEL_URL}" 2>/dev/null || true)"
if [[ "$panel_code" =~ ^[23] ]]; then
  check "Панель отвечает" 1 "HTTP ${panel_code}"
else
  check "Панель отвечает" 0 "код ${panel_code:-нет ответа}"
fi

if iptables -S INPUT 2>/dev/null | grep -q -- '-j VPN-FW' \
  || iptables -S INPUT 2>/dev/null | grep -q -- '-P INPUT DROP' \
  || { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; }; then
  check "Firewall включён" 1
else
  check "Firewall включён" 0 "нет цепочки VPN-FW"
fi

if systemctl is-active --quiet fail2ban; then
  check "Защита SSH (fail2ban)" 1
else
  check "Защита SSH (fail2ban)" 0 "не запущен"
fi

if getent hosts "$SNI" >/dev/null 2>&1; then
  check "Домен маскировки резолвится" 1 "$SNI"
else
  check "Домен маскировки резолвится" 0 "$SNI"
fi

if timeout 8 openssl s_client -connect 127.0.0.1:443 -servername "$SNI" -brief </dev/null >/dev/null 2>&1; then
  check "Reality отвечает по TLS" 1 "$SNI"
else
  check "Reality отвечает по TLS" 0
fi

egress="$(curl -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"
if [[ "$VPN_PUBLIC_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  if [[ "$egress" == "$VPN_PUBLIC_HOST" ]]; then
    check "Выход в интернет с нужного IP" 1 "$egress"
  else
    check "Выход в интернет с нужного IP" 0 "сервер видит ${egress:-неизвестно}"
  fi
else
  if [[ -n "$egress" ]]; then
    check "Выход в интернет" 1 "$egress"
  else
    check "Выход в интернет" 0
  fi
fi

if [[ "$HY2_ENABLED" == "1" ]]; then
  if ss -H -lun 2>/dev/null | grep -q ':443 '; then
    check "Hysteria2 слушает UDP 443" 1
  else
    check "Hysteria2 слушает UDP 443" 0
  fi
fi

if [[ "$AWG_ENABLED" == "1" ]]; then
  if awg show awg0 >/dev/null 2>&1; then
    check "AmneziaWG поднят (awg0)" 1 "UDP ${AWG_PORT}"
  else
    check "AmneziaWG поднят (awg0)" 0 "systemctl status awg-quick@awg0"
  fi
fi

if (( VERIFY_TOTAL > 0 )); then
  VERIFY_SCORE=$(( VERIFY_PASSED * 100 / VERIFY_TOTAL ))
else
  VERIFY_SCORE=0
fi
if (( VERIFY_SCORE >= 90 )); then
  VERIFY_GRADE="отлично"
elif (( VERIFY_SCORE >= 75 )); then
  VERIFY_GRADE="хорошо"
elif (( VERIFY_SCORE >= 50 )); then
  VERIFY_GRADE="средне"
else
  VERIFY_GRADE="плохо"
fi
ok "Самопроверка: ${VERIFY_PASSED}/${VERIFY_TOTAL} (${VERIFY_SCORE}% — ${VERIFY_GRADE})."

# =============================================================================
#  RESULT FILES
# =============================================================================
step "Сохранение результата"

# links.txt
{
  echo "VPN ${VPN_PUBLIC_HOST} — ссылки"
  echo "Дата: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo
  echo "=== VLESS + XHTTP + Reality (TCP 443) ==="
  echo
  for i in "${!CLIENT_NAMES[@]}"; do
    echo "[${CLIENT_NAMES[$i]}]"
    echo "${CLIENT_LINKS[$i]}"
    echo
  done
  if [[ "$HY2_ENABLED" == "1" ]]; then
    echo "=== Hysteria2 (UDP 443) ==="
    echo "Внимание: UDP может блокироваться провайдером. Если не работает — используйте VLESS."
    echo
    for i in "${!CLIENT_NAMES[@]}"; do
      echo "[${CLIENT_NAMES[$i]}]"
      echo "${HY2_LINKS[$i]}"
      echo
    done
  fi
  if [[ "$AWG_ENABLED" == "1" ]]; then
    echo "=== AmneziaWG (UDP ${AWG_PORT}) ==="
    echo "Готовые файлы: amnezia-<имя>.conf в папке результата."
    echo "Импорт: AmneziaVPN → + → Файл настроек → выбрать .conf."
    echo "Endpoint: ${VPN_PUBLIC_HOST}:${AWG_PORT}"
    echo
    while IFS=$'\t' read -r awg_name awg_ip; do
      echo "[${awg_name}] ${awg_ip} → amnezia-${awg_name}.conf"
    done < <(jq -r '.[] | [.name, .ip] | @tsv' <<< "$AWG_CLIENTS_JSON")
    echo
  fi
} > "${RESULT_DIR}/links.txt"

if [[ "$VPN_SPLIT_TUNNEL" == "1" ]]; then
  cat > "${RESULT_DIR}/split-tunnel.txt" <<'SPLIT_EOF'
БЕЛЫЕ СПИСКИ / РАЗДЕЛЬНОЕ ТУННЕЛИРОВАНИЕ
=========================================

Это настройка КЛИЕНТА, а не сервера. Сервер одинаково принимает весь трафик.
Нужно один раз добавить правила в приложение, через которое подключаетесь.

Вариант A. Российские сайты — напрямую, остальное — через VPN (рекомендуется)
------------------------------------------------------------------------------
v2rayNG / v2rayN:
  Настройки → Маршрутизация → Правила:
    1) geosite:category-ru   → direct (напрямую)
    2) geoip:ru              → direct
    3) geosite:private       → direct
    4) остальное             → proxy (через VPN)

NekoBox:
  Настройки → Маршрутизация → выберите профиль «Bypass Russia»
  (или добавьте те же правила вручную).

Hiddify:
  Настройки → Маршрутизация → «Russia direct» / «Bypass Russia».
  Если профиля нет — добавьте geosite:category-ru и geoip:ru в direct.

Вариант B. Только выбранные сайты — через VPN, остальное — напрямую
--------------------------------------------------------------------
v2rayNG / v2rayN:
  Правила:
    1) geosite:youtube, geosite:google, geosite:telegram → proxy
    2) остальное → direct
  Вместо списка можно указать свои домены:
    domain:example.com → proxy
    domain:another.org → proxy

Проверка
--------
1. Включите VPN.
2. Откройте https://ifconfig.me — должен показать адрес VPN-сервера.
3. Откройте российский сайт (например, https://ya.ru) — он должен работать
   напрямую и не расходовать VPN-трафик.
4. Если сайт не открывается — проверьте, что правило стоит в списке выше
   правила «остальное → proxy».

Важно
-----
- Правила действуют только в том приложении, где вы их добавили.
- На телефоне и на ПК настройки нужно сделать отдельно.
- Если не уверены — начните с варианта A.
SPLIT_EOF
fi

# Result JSON for the Windows installer.
CLIENTS_RESULT='[]'
for i in "${!CLIENT_NAMES[@]}"; do
  name="${CLIENT_NAMES[$i]}"
  uuid="${CLIENT_UUIDS[$i]}"
  link="${CLIENT_LINKS[$i]}"
  qr_b64=""
  if [[ -f "${RESULT_DIR}/qr-${name}.png" ]]; then
    qr_b64="$(base64 -w0 "${RESULT_DIR}/qr-${name}.png")"
  fi
  item="$(jq -n \
    --arg name "$name" \
    --arg uuid "$uuid" \
    --arg link "$link" \
    --arg qr "$qr_b64" \
    '{name:$name, uuid:$uuid, link:$link, qr_png_base64:$qr}')"
  CLIENTS_RESULT="$(jq -c --argjson item "$item" '. + [$item]' <<< "$CLIENTS_RESULT")"
done

if [[ "$HY2_ENABLED" == "1" ]]; then
  HY2_RESULT='[]'
  for i in "${!CLIENT_NAMES[@]}"; do
    name="${CLIENT_NAMES[$i]}"
    link="${HY2_LINKS[$i]}"
    qr_b64=""
    if [[ -f "${RESULT_DIR}/qr-${name}-hy2.png" ]]; then
      qr_b64="$(base64 -w0 "${RESULT_DIR}/qr-${name}-hy2.png")"
    fi
    item="$(jq -n \
      --arg name "$name" \
      --arg link "$link" \
      --arg qr "$qr_b64" \
      '{name:$name, link:$link, qr_png_base64:$qr}')"
    HY2_RESULT="$(jq -c --argjson item "$item" '. + [$item]' <<< "$HY2_RESULT")"
  done
  HY2_JSON="$(jq -n --argjson clients "$HY2_RESULT" '{enabled:true, clients:$clients}')"
else
  HY2_JSON='{"enabled":false}'
fi

if [[ "$AWG_ENABLED" == "1" ]]; then
  AWG_JSON="$(jq -n \
    --arg port "$AWG_PORT" \
    --arg subnet "$AWG_SUBNET" \
    --arg serverKey "$AWG_SERVER_PUBLIC" \
    --argjson clients "$AWG_CLIENTS_JSON" \
    '{enabled:true, port:($port|tonumber), subnet:$subnet, server_public_key:$serverKey, clients:$clients}')"
elif [[ "$VPN_ENABLE_AWG" == "1" && "$AWG_SKIP" == "1" ]]; then
  AWG_JSON='{"enabled":false, "skipped":true, "reason":"existing-amnezia"}'
else
  AWG_JSON='{"enabled":false}'
fi

VERIFY_OBJ="$(jq -n \
  --argjson score "$VERIFY_SCORE" \
  --arg grade "$VERIFY_GRADE" \
  --argjson checks "$VERIFY_JSON" \
  '{score:$score, grade:$grade, checks:$checks}')"

jq -n \
  --arg host "$VPN_PUBLIC_HOST" \
  --arg sshPort "$VPN_SSH_PORT" \
  --arg panelPort "$VPN_PANEL_PORT" \
  --arg panelPath "$VPN_PANEL_PATH" \
  --arg panelUser "$VPN_PANEL_USER" \
  --arg panelPass "$VPN_PANEL_PASS" \
  --arg panelUrl "${PANEL_URL}" \
  --arg inboundId "$INBOUND_ID" \
  --arg sni "$SNI" \
  --arg pbk "$REALITY_PUBLIC_KEY" \
  --arg sid "$SHORT_ID" \
  --arg path "$XHTTP_PATH" \
  --arg mode "${LINK_MODE:-auto}" \
  --argjson clients "$CLIENTS_RESULT" \
  --argjson hy2 "$HY2_JSON" \
  --argjson awg "$AWG_JSON" \
  --arg split "$VPN_SPLIT_TUNNEL" \
  --arg splitNotes "$(cat "${RESULT_DIR}/split-tunnel.txt" 2>/dev/null || true)" \
  --argjson verify "$VERIFY_OBJ" \
  --arg createdAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  '{
    ok:true,
    host:$host,
    ssh_port:($sshPort|tonumber),
    panel:{port:($panelPort|tonumber), path:$panelPath, username:$panelUser, password:$panelPass, url:$panelUrl},
    inbound:{id:($inboundId|tonumber), remark:"VLESS-XHTTP-Reality-443", port:443, sni:$sni, pbk:$pbk, sid:$sid, path:$path, mode:$mode},
    clients:$clients,
    hysteria2:$hy2,
    amneziawg:$awg,
    split_tunnel:($split=="1"),
    split_tunnel_notes:$splitNotes,
    verify:$verify,
    created_at:$createdAt
  }' > "${RESULT_DIR}/result.json"

ok "Результаты сохранены: ${RESULT_DIR}"

# =============================================================================
#  DONE
# =============================================================================
touch /root/.vpn-install-success

printf '\n=== VPN_RESULT_JSON_BEGIN ===\n'
base64 -w0 "${RESULT_DIR}/result.json"
printf '\n=== VPN_RESULT_JSON_END ===\n'

printf '\n'
printf '============================================================\n'
printf '  ГОТОВО! VPN установлен.\n'
printf '============================================================\n'
printf '  Сервер:   %s\n' "$VPN_PUBLIC_HOST"
printf '  Панель:   %s\n' "$PANEL_URL"
printf '  Логин:    %s\n' "$VPN_PANEL_USER"
printf '  Пароль:   %s\n' "$VPN_PANEL_PASS"
printf '  Клиентов: %s\n' "${#CLIENT_NAMES[@]}"
printf '  Hysteria2: %s\n' "$([[ "$HY2_ENABLED" == "1" ]] && echo да || echo нет)"
printf '  AmneziaWG: %s\n' "$([[ "$AWG_ENABLED" == "1" ]] && echo "да (UDP ${AWG_PORT})" || { [[ "$AWG_SKIP" == "1" ]] && echo 'пропущен (Amnezia уже есть)' || echo нет; })"
printf '  Защита:    %s\n' "$([[ "$VPN_HARDEN" == "1" ]] && echo 'включена (sysctl, автообновления, fail2ban)' || echo 'выключена')"
printf '  Проверка:  %s/%s (%s%%, %s)\n' "$VERIFY_PASSED" "$VERIFY_TOTAL" "$VERIFY_SCORE" "$VERIFY_GRADE"
printf '  Результаты: %s\n' "$RESULT_DIR"
printf '============================================================\n'
printf '\n'

log "Установка завершена успешно."

rm -f "${INSTALLER:-}" 2>/dev/null || true
if [[ -f "$0" && "$0" == /tmp/* ]]; then
  ( sleep 2; rm -f "$0" ) >/dev/null 2>&1 &
fi

exit 0
