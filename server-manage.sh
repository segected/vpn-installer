#!/usr/bin/env bash
# =============================================================================
#  VPN Manager — server side
#  Adds/lists/removes VLESS clients and AmneziaWG peers.
#  This script is uploaded over SSH by manage.ps1.
# =============================================================================

set -Eeuo pipefail

# --- config injected by manage.ps1 ------------------------------------------
PANEL_PORT='@@PANEL_PORT@@'
PANEL_PATH='@@PANEL_PATH@@'
PANEL_USER='@@PANEL_USER@@'
PANEL_PASS_B64='@@PANEL_PASS_B64@@'
INBOUND_ID='@@INBOUND_ID@@'
PUBLIC_HOST='@@PUBLIC_HOST@@'
SNI='@@SNI@@'
PBK='@@PBK@@'
SID='@@SID@@'
XHTTP_PATH='@@XHTTP_PATH@@'
XHTTP_MODE='@@XHTTP_MODE@@'
AWG_PORT='@@AWG_PORT@@'
# --- end config --------------------------------------------------------------

umask 077
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

BASE="http://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}"
COOKIE="$(mktemp)"
AWG_CONF="/etc/amnezia/amneziawg/awg0.conf"
BACKUP_DIR="/root/vpn-backups"

cleanup() { rm -f "$COOKIE" 2>/dev/null || true; }
trap cleanup EXIT

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '  [OK] %s\n' "$*"; }
info() { printf '  [..] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*"; }
die()  { printf '  [FAIL] %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "На сервере нет $1."
}

[[ "$PANEL_PORT" =~ ^[0-9]+$ ]] || die "Некорректный порт панели."
[[ "$INBOUND_ID" =~ ^[0-9]+$ ]] || die "Некорректный inbound id."
[[ -n "$PANEL_PATH" && -n "$PANEL_USER" ]] || die "Не хватает данных панели."

human_bytes() {
  local b="${1:-0}"
  if (( b >= 1073741824 )); then
    awk -v b="$b" 'BEGIN{printf "%.2f GB", b/1073741824}'
  elif (( b >= 1048576 )); then
    awk -v b="$b" 'BEGIN{printf "%.1f MB", b/1048576}'
  elif (( b >= 1024 )); then
    awk -v b="$b" 'BEGIN{printf "%.1f KB", b/1024}'
  else
    printf '%s B' "$b"
  fi
}

# =============================================================================
#  3X-UI API
# =============================================================================
PANEL_PASS="$(printf '%s' "$PANEL_PASS_B64" | base64 -d 2>/dev/null || true)"
[[ -n "$PANEL_PASS" ]] || die "Не удалось прочитать пароль панели."
CSRF_TOKEN=""

api_login() {
  local login_body
  CSRF_TOKEN="$(curl -fsS --max-time 15 -c "$COOKIE" "${BASE}/csrf-token" 2>/dev/null | jq -r '.obj // empty' 2>/dev/null || true)"
  [[ -n "$CSRF_TOKEN" ]] || die "Панель не выдала CSRF-токен. Проверьте, что x-ui запущен."
  login_body="$(mktemp)"
  if ! curl -fsS --max-time 15 -c "$COOKIE" -b "$COOKIE" -X POST \
      -H "X-CSRF-Token: ${CSRF_TOKEN}" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-urlencode "username=${PANEL_USER}" \
      --data-urlencode "password=${PANEL_PASS}" \
      "${BASE}/login" -o "$login_body" 2>/dev/null \
    || ! jq -e '.success == true' >/dev/null 2>&1 < "$login_body"; then
    rm -f "$login_body" 2>/dev/null || true
    die "Не удалось войти в панель 3x-ui. Проверьте логин/пароль и что панель запущена."
  fi
  rm -f "$login_body" 2>/dev/null || true
}

api() {
  local method="$1" path="$2" body="${3:-}" resp err
  local args=(-sS --max-time 25 -b "$COOKIE" -X "$method" -H "Content-Type: application/json")
  [[ -n "$CSRF_TOKEN" ]] && args+=(-H "X-CSRF-Token: ${CSRF_TOKEN}")
  [[ -n "$body" ]] && args+=(--data "$body")
  resp="$(curl "${args[@]}" "${BASE}${path}" 2>/dev/null || true)"
  [[ -n "$resp" ]] || die "Панель не ответила на ${path}."
  if ! jq -e '.success == true' >/dev/null 2>&1 <<< "$resp"; then
    err="$(jq -r 'if ((.obj.issues? // []) | length) > 0 then (.obj.issues | map(.message) | join("; ")) else (.msg // .) end' <<< "$resp" 2>/dev/null || printf '%s' "$resp")"
    die "Ошибка API: ${err}"
  fi
  printf '%s' "$resp"
}

build_link() {
  local name="$1" uuid="$2" name_enc path_enc
  name_enc="$(jq -rn --arg v "$name" '$v|@uri')"
  path_enc="$(jq -rn --arg v "$XHTTP_PATH" '$v|@uri')"
  printf 'vless://%s@%s:443?encryption=none&fp=chrome&host=&mode=%s&path=%s&pbk=%s&security=reality&sid=%s&sni=%s&type=xhttp#%s' \
    "$uuid" "$PUBLIC_HOST" "${XHTTP_MODE:-auto}" "$path_enc" "$PBK" "$SID" "$SNI" "$name_enc"
}

qr_base64() {
  local text="$1" tmp b64=""
  tmp="$(mktemp --suffix=.png)"
  if qrencode -o "$tmp" -s 8 -m 2 "$text" 2>/dev/null; then
    b64="$(base64 -w0 "$tmp")"
  fi
  rm -f "$tmp"
  printf '%s' "$b64"
}

print_payload() {
  printf '\n=== VPN_CLIENT_JSON_BEGIN ===\n'
  printf '%s' "$1" | base64 -w0
  printf '\n=== VPN_CLIENT_JSON_END ===\n'
}

get_client_by_email() {
  api GET "/panel/api/clients/list" \
    | jq -c --arg e "$1" '.obj[]? | select(.email==$e)' | head -n1
}

# =============================================================================
#  VLESS CLIENTS
# =============================================================================
cmd_list_vless() {
  local list
  list="$(api GET "/panel/api/clients/list")"
  printf '\nVLESS-клиенты (inbound %s):\n\n' "$INBOUND_ID"
  printf 'Имя                    Вкл   Трафик        Срок\n'
  printf -- '---------------------- ----- ------------- ----------\n'
  jq -r --argjson id "$INBOUND_ID" '
    .obj[]?
    | select((.inboundIds // []) | index($id))
    | [.email, (if .enable then "да" else "нет" end),
       (((.traffic.up // 0) + (.traffic.down // 0)) | tostring),
       ((.expiryTime // 0) | tostring)]
    | @tsv' <<< "$list" |
  while IFS=$'\t' read -r email en traffic exp; do
    human="$(human_bytes "$traffic")"
    if [[ "$exp" == "0" ]]; then
      term="бессрочно"
    else
      term="$(date -d "@$((exp / 1000))" '+%Y-%m-%d' 2>/dev/null || printf '%s' "$exp")"
    fi
    printf '%-22s %-6s %-14s %s\n' "$email" "$en" "$human" "$term"
  done
  printf '\nВсего: %s\n' "$(jq -r --argjson id "$INBOUND_ID" '[.obj[]? | select((.inboundIds // []) | index($id))] | length' <<< "$list")"
}

cmd_add_vless() {
  local name="${1:-}" days="${2:-0}" gb="${3:-0}"
  [[ "$name" =~ ^[A-Za-z0-9_-]{1,24}$ ]] || die "Имя: 1-24 символа A-Z a-z 0-9 _ -"
  [[ "$days" =~ ^[0-9]+$ ]] || days=0
  [[ "$gb" =~ ^[0-9]+$ ]] || gb=0

  local list
  list="$(api GET "/panel/api/clients/list")"
  if jq -e --arg e "$name" '.obj[]? | select(.email==$e)' >/dev/null 2>&1 <<< "$list"; then
    die "Клиент '${name}' уже существует. Выберите другое имя."
  fi

  local expiry=0 total=0
  (( days > 0 )) && expiry=$(( $(date +%s%3N) + days * 86400000 ))
  (( gb > 0 )) && total=$(( gb * 1073741824 ))

  local subid body
  subid="$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  body="$(jq -n \
    --arg email "$name" \
    --arg sub "$subid" \
    --argjson exp "$expiry" \
    --argjson total "$total" \
    --argjson id "$INBOUND_ID" \
    '{client:{email:$email, enable:true, totalGB:$total, expiryTime:$exp, limitIp:0, tgId:0, subId:$sub}, inboundIds:[$id]}')"

  info "Создаю клиента ${name}..."
  api POST "/panel/api/clients/add" "$body" >/dev/null

  local client uuid link qr payload
  client="$(get_client_by_email "$name")"
  uuid="$(jq -r '.uuid // empty' <<< "$client")"
  [[ -n "$uuid" && "$uuid" != "null" ]] || die "Клиент создан, но UUID не найден. Откройте панель вручную."
  link="$(build_link "$name" "$uuid")"
  qr="$(qr_base64 "$link")"
  payload="$(jq -n \
    --arg name "$name" \
    --arg uuid "$uuid" \
    --arg link "$link" \
    --arg qr "$qr" \
    --argjson days "$days" \
    --argjson gb "$gb" \
    '{name:$name, uuid:$uuid, link:$link, qr_png_base64:$qr, days:$days, gb:$gb}')"
  ok "Клиент ${name} добавлен."
  print_payload "$payload"
}

cmd_show_vless() {
  local name="${1:-}" client uuid link qr payload
  [[ -n "$name" ]] || die "Укажите имя клиента."
  client="$(get_client_by_email "$name")"
  [[ -n "$client" ]] || die "Клиент '${name}' не найден."
  uuid="$(jq -r '.uuid // empty' <<< "$client")"
  [[ -n "$uuid" && "$uuid" != "null" ]] || die "У клиента нет UUID."
  link="$(build_link "$name" "$uuid")"
  qr="$(qr_base64 "$link")"
  payload="$(jq -n --arg name "$name" --arg uuid "$uuid" --arg link "$link" --arg qr "$qr" \
    '{name:$name, uuid:$uuid, link:$link, qr_png_base64:$qr}')"
  printf '\nКлиент: %s\nUUID: %s\nСсылка:\n%s\n' "$name" "$uuid" "$link"
  print_payload "$payload"
}

cmd_del_vless() {
  local name="${1:-}" enc
  [[ -n "$name" ]] || die "Укажите имя клиента."
  enc="$(jq -rn --arg v "$name" '$v|@uri')"
  mkdir -p "$BACKUP_DIR"
  get_client_by_email "$name" > "${BACKUP_DIR}/deleted-client-${name}-$(date +%Y%m%d-%H%M%S).json" 2>/dev/null || true
  info "Удаляю клиента ${name}..."
  api POST "/panel/api/clients/del/${enc}?keepTraffic=1" >/dev/null
  ok "Клиент ${name} удалён."
}

# =============================================================================
#  AMNEZIAWG
# =============================================================================
awg_require() {
  [[ -f "$AWG_CONF" ]] || die "AmneziaWG не установлен (${AWG_CONF} отсутствует)."
  require_cmd awg
  require_cmd awg-quick
  awg show awg0 >/dev/null 2>&1 || die "Интерфейс awg0 не запущен. Проверьте: systemctl status awg-quick@awg0"
}

awg_if_value() {
  awk -v key="$1" '
    /^\[Interface\]/ { inif=1; next }
    /^\[/ { inif=0 }
    inif && index($0, key " =") == 1 { sub(/^[^=]*= */, ""); print; exit }
  ' "$AWG_CONF"
}

awg_server_pub() {
  local pub
  pub="$(awg show awg0 public-key 2>/dev/null || true)"
  if [[ -z "$pub" ]]; then
    pub="$(printf '%s' "$(awg_if_value PrivateKey)" | awg pubkey 2>/dev/null || true)"
  fi
  printf '%s' "$pub"
}

awg_listen_port() {
  local p
  p="$(awg_if_value ListenPort)"
  printf '%s' "${p:-$AWG_PORT}"
}

awg_next_ip() {
  local base last max=1
  base="$(awg_if_value Address | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3}')"
  [[ -n "$base" ]] || die "Не удалось определить подсеть AmneziaWG."
  while read -r ip; do
    [[ -n "$ip" ]] || continue
    last="${ip##*.}"
    [[ "$last" =~ ^[0-9]+$ ]] || continue
    (( last > max )) && max="$last"
  done < <(grep -oE 'AllowedIPs = [0-9.]+' "$AWG_CONF" | awk '{print $3}' | cut -d/ -f1)
  printf '%s.%d' "$base" "$((max + 1))"
}

awg_apply() {
  local stripped
  stripped="$(mktemp)"
  if ! awg-quick strip awg0 > "$stripped" 2>/dev/null; then
    rm -f "$stripped"
    return 1
  fi
  if ! awg syncconf awg0 "$stripped" >/dev/null 2>&1; then
    awg setconf awg0 "$stripped" >/dev/null 2>&1 || { rm -f "$stripped"; return 1; }
  fi
  rm -f "$stripped"
  return 0
}

cmd_list_awg() {
  awg_require
  printf '\nAmneziaWG: awg0, UDP %s\n\n' "$(awg_listen_port)"
  printf '%-22s %-16s %s\n' 'Имя' 'IP' 'Публичный ключ'
  printf '%-22s %-16s %s\n' '---' '--' '--------------'
  awk '
    $0 == "" { next }
    /^# client: / { name=substr($0, 11); next }
    /^\[Peer\]/ { inpeer=1; pub=""; allowed=""; next }
    inpeer && /^PublicKey = / { sub(/^PublicKey = /, ""); pub=$0 }
    inpeer && /^AllowedIPs = / { sub(/^AllowedIPs = /, ""); allowed=$0; sub(/\/32$/, "", allowed) }
    inpeer && /^$/ { if (name != "") printf "%-22s %-16s %s\n", name, allowed, pub; inpeer=0; name="" }
    END { if (inpeer && name != "") printf "%-22s %-16s %s\n", name, allowed, pub }
  ' "$AWG_CONF"
  printf '\nСостояние:\n'
  awg show awg0 | sed 's/^/  /'
}

cmd_add_awg() {
  local name="${1:-}" priv pub psk ip backup conf qr payload server_pub listen_port
  [[ "$name" =~ ^[A-Za-z0-9_-]{1,24}$ ]] || die "Имя: 1-24 символа A-Z a-z 0-9 _ -"
  awg_require
  if grep -q "^# client: ${name}$" "$AWG_CONF"; then
    die "Клиент AmneziaWG '${name}' уже существует."
  fi

  priv="$(awg genkey 2>/dev/null || true)"
  pub="$(printf '%s' "$priv" | awg pubkey 2>/dev/null || true)"
  psk="$(awg genpsk 2>/dev/null || true)"
  [[ -n "$priv" && -n "$pub" && -n "$psk" ]] || die "Не удалось сгенерировать ключи AmneziaWG."
  ip="$(awg_next_ip)"
  server_pub="$(awg_server_pub)"
  listen_port="$(awg_listen_port)"
  [[ -n "$server_pub" ]] || die "Не удалось получить публичный ключ сервера AmneziaWG."
  for key in Jc Jmin Jmax S1 S2 H1 H2 H3 H4; do
    [[ -n "$(awg_if_value "$key")" ]] || die "В конфиге AmneziaWG нет параметра ${key}."
  done

  mkdir -p "$BACKUP_DIR"
  backup="${AWG_CONF}.bak-$(date +%Y%m%d-%H%M%S)"
  cp -a "$AWG_CONF" "$backup"
  {
    printf '\n# client: %s\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n' \
      "$name" "$pub" "$psk" "$ip"
  } >> "$AWG_CONF"

  if ! awg_apply; then
    cp -a "$backup" "$AWG_CONF"
    awg_apply || true
    die "Не удалось применить конфиг AmneziaWG. Изменения отменены."
  fi

  conf="$(mktemp)"
  cat > "$conf" <<CLIENT_EOF
[Interface]
PrivateKey = ${priv}
Address = ${ip}/32
DNS = 1.1.1.1, 8.8.8.8
Jc = $(awg_if_value Jc)
Jmin = $(awg_if_value Jmin)
Jmax = $(awg_if_value Jmax)
S1 = $(awg_if_value S1)
S2 = $(awg_if_value S2)
H1 = $(awg_if_value H1)
H2 = $(awg_if_value H2)
H3 = $(awg_if_value H3)
H4 = $(awg_if_value H4)
MTU = 1280

[Peer]
PublicKey = ${server_pub}
PresharedKey = ${psk}
AllowedIPs = 0.0.0.0/0
Endpoint = ${PUBLIC_HOST}:${listen_port}
PersistentKeepalive = 25
CLIENT_EOF

  qr="$(qr_base64 "$(cat "$conf")")"
  payload="$(jq -n \
    --arg name "$name" \
    --arg ip "$ip" \
    --arg config "$(cat "$conf")" \
    --arg qr "$qr" \
    '{name:$name, ip:$ip, config:$config, qr_png_base64:$qr}')"
  rm -f "$conf"
  ok "Клиент AmneziaWG ${name} добавлен (${ip})."
  print_payload "$payload"
}

cmd_del_awg() {
  local name="${1:-}" pub backup
  [[ -n "$name" ]] || die "Укажите имя клиента AmneziaWG."
  awg_require
  pub="$(awk -v name="$name" '
    $0 == "# client: " name { found=1; next }
    found && /^PublicKey = / { sub(/^PublicKey = /, ""); print; exit }
  ' "$AWG_CONF")"
  [[ -n "$pub" ]] || die "Клиент AmneziaWG '${name}' не найден."

  mkdir -p "$BACKUP_DIR"
  backup="${AWG_CONF}.bak-$(date +%Y%m%d-%H%M%S)"
  cp -a "$AWG_CONF" "$backup"
  awk -v name="$name" '
    $0 == "# client: " name { skip=1; next }
    skip && /^# client: / { skip=0 }
    skip { next }
    { print }
  ' "$AWG_CONF" > "${AWG_CONF}.new"
  mv "${AWG_CONF}.new" "$AWG_CONF"

  if ! awg_apply; then
    cp -a "$backup" "$AWG_CONF"
    awg_apply || true
    die "Не удалось применить конфиг AmneziaWG. Изменения отменены."
  fi
  ok "Клиент AmneziaWG ${name} удалён."
}

# =============================================================================
#  STATUS / BACKUP
# =============================================================================
cmd_status() {
  local listen_port="0"
  [[ -f "$AWG_CONF" ]] && listen_port="$(awg_listen_port)"

  printf '\n=== Сервер ===\n'
  hostname 2>/dev/null || true
  uptime 2>/dev/null || true
  printf '\n=== Сервисы ===\n'
  printf 'x-ui: %s\n' "$(systemctl is-active x-ui 2>/dev/null || echo unknown)"
  if [[ -f "$AWG_CONF" ]]; then
    printf 'awg-quick@awg0: %s\n' "$(systemctl is-active awg-quick@awg0 2>/dev/null || echo unknown)"
  else
    printf 'AmneziaWG: не установлен\n'
  fi
  printf '\n=== Порты ===\n'
  ss -ltnp 2>/dev/null | grep -E ":(${PANEL_PORT}|443) " || true
  if [[ "$listen_port" != "0" ]]; then
    ss -lunp 2>/dev/null | grep -E ":(${listen_port}) " || true
  fi
  printf '\n=== Xray ===\n'
  pgrep -a xray 2>/dev/null | head -n 3 || true
  if [[ -f "$AWG_CONF" ]]; then
    printf '\n=== AmneziaWG ===\n'
    awg show awg0 2>/dev/null | head -n 14 || true
  fi
  printf '\n=== Диск и память ===\n'
  df -h / 2>/dev/null | tail -n1 || true
  free -h 2>/dev/null | head -n2 || true
}

cmd_backup() {
  local out files=()
  mkdir -p "$BACKUP_DIR"
  [[ -f /etc/x-ui/x-ui.db ]] && files+=(/etc/x-ui/x-ui.db)
  [[ -f "$AWG_CONF" ]] && files+=("$AWG_CONF")
  [[ -f /usr/local/sbin/vpn-firewall.sh ]] && files+=(/usr/local/sbin/vpn-firewall.sh)
  (( ${#files[@]} > 0 )) || die "Нечего сохранять: не найдены файлы панели/VPN."
  out="${BACKUP_DIR}/vpn-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar czf "$out" "${files[@]}"
  chmod 600 "$out"
  ok "Backup создан: ${out}"
  ls -lh "$out" 2>/dev/null || true
}

# =============================================================================
#  MAIN
# =============================================================================
ACTION="${1:-help}"
shift || true

case "$ACTION" in
  list-vless|add-vless|show-vless|del-vless) api_login ;;
esac

case "$ACTION" in
  list-vless) cmd_list_vless ;;
  add-vless)  cmd_add_vless "${1:-}" "${2:-0}" "${3:-0}" ;;
  show-vless) cmd_show_vless "${1:-}" ;;
  del-vless)  cmd_del_vless "${1:-}" ;;
  list-awg)   cmd_list_awg ;;
  add-awg)    cmd_add_awg "${1:-}" ;;
  del-awg)    cmd_del_awg "${1:-}" ;;
  status)     cmd_status ;;
  backup)     cmd_backup ;;
  help|*)
    cat <<'HELP'
VPN Manager (серверная часть)

Действия:
  list-vless              список VLESS-клиентов
  add-vless <имя> [дни] [ГБ]  добавить клиента
  show-vless <имя>        ссылка и QR клиента
  del-vless <имя>         удалить клиента
  list-awg                список AmneziaWG
  add-awg <имя>           добавить AmneziaWG-клиента
  del-awg <имя>           удалить AmneziaWG-клиента
  status                  состояние сервера
  backup                  backup базы панели и конфигов
HELP
    ;;
esac
