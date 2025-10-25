#!/usr/bin/env bash
set -euo pipefail

# ---------- Красота ----------
if [[ -t 1 ]]; then
  RED=$(printf '\033[31m'); GRN=$(printf '\033[32m'); YLW=$(printf '\033[33m')
  BLU=$(printf '\033[34m'); CYA=$(printf '\033[36m'); BLD=$(printf '\033[1m')
  DIM=$(printf '\033[2m'); RST=$(printf '\033[0m')
else RED=""; GRN=""; YLW=""; BLU=""; CYA=""; BLD=""; DIM=""; RST=""; fi
step(){ echo; echo "${BLD}${CYA}[STEP]${RST} $*"; }
ok(){   echo "${GRN}✔${RST} $*"; }
warn(){ echo "${YLW}!${RST} $*"; }
err(){  echo "${RED}✘${RST} $*" >&2; }

banner(){ echo "${BLD}${BLU}=== Remnawave VLESS XHTTP + Nginx (CDN ready) — установщик ===${RST}"; }

explain_domains(){
  local mode="$1"
  echo
  echo "${BLD}Как заполнять домены:${RST}"
  if [[ "$mode" == "1" ]]; then
    cat <<'HLP'
• Режим: через внешний CDN (Яндекс CDN/Cloudfort/etc.)
  - CDN-домен (публичный): твой поддомен, куда идут клиенты.
      Пример: cdn2.yourbeautycostmore.hair
      DNS:    CNAME -> Хост, выданный CDN
              (пример: 4f07146f16015b10.a.yccdn.cloud.yandex.net или htww9x9nsz.cdncf.ru)
  - Origin/TLS-домен: поддомен с A-записью на IP VPS (на нём выпустим сертификат).
      Пример: cdnhello.yourbeautycostmore.hair
      В панели CDN: origin host = cdnhello.yourbeautycostmore.hair, protocol = HTTPS.
HLP
  else
    cat <<'HLP'
• Режим: без внешнего CDN (напрямую)
  - CDN-домен (публичный): твой поддомен с A -> IP VPS.
      Пример: cdnhello.yourbeautycostmore.hair
  - Origin/TLS-домен: обычно тот же домен (или любой с A -> IP VPS), на него выпустим сертификат.
HLP
  fi
  echo
}

# ---------- Очистка ----------
cleanup_domain(){
  local TARGET_DOMAIN="$1" ALSO_CERT="$2" PURGE_WEB="$3"
  local SA="/etc/nginx/sites-available" SE="/etc/nginx/sites-enabled"

  step "Удаляю nginx-конфиги с server_name ${TARGET_DOMAIN} ..."
  mapfile -t HITS < <(grep -lsR --include="*.conf" -E "server_name[^;]*\b${TARGET_DOMAIN}\b" "$SA" 2>/dev/null || true)
  if ((${#HITS[@]})); then
    for f in "${HITS[@]}"; do
      echo " - ${f}"
      local base; base="$(basename "$f")"
      rm -f "${SE}/${base}" 2>/dev/null || true
      rm -f "${f}" || true
    done
    ok "Конфиги и ссылки удалены"
  else
    warn "Совпадений в ${SA} не найдено"
  fi

  step "Удаляю временные ACME-конфиги ..."
  rm -f "${SA}"/_acme_*.conf "${SE}"/_acme_*.conf 2>/dev/null || true
  ok "ACME-конфиги убраны"

  if [[ "${ALSO_CERT^^}" == "Y" ]]; then
    step "Удаляю сертификат Let's Encrypt для ${TARGET_DOMAIN} ..."
    if [[ -d "/etc/letsencrypt/live/${TARGET_DOMAIN}" ]]; then
      certbot delete --cert-name "${TARGET_DOMAIN}" -n || true
      ok "Сертификат удалён"
    else
      warn "Каталог /etc/letsencrypt/live/${TARGET_DOMAIN} отсутствует"
    fi
  fi

  if [[ "${PURGE_WEB^^}" == "Y" ]]; then
    step "Удаляю веб-контент, созданный скриптом ..."
    rm -rf /var/www/zeronode /var/www/letsencrypt 2>/dev/null || true
    ok "Веб-корень и ACME-директория очищены"
  fi

  step "Проверяю nginx и перезагружаю ..."
  if nginx -t; then
    systemctl reload nginx || systemctl restart nginx
    ok "nginx перезагружен"
  else
    err "nginx -t упал — проверь конфиги"
  fi

  ok "Очистка по домену ${TARGET_DOMAIN} завершена."
}

# ---------- Старт ----------
banner
echo "Выбери режим:
  ${BLD}1${RST} — Чистая установка через внешний CDN (CNAME)
  ${BLD}2${RST} — Добавить ещё один CDN на эту ноду
  ${BLD}3${RST} — Очистка/удаление по домену"
read -rp "Введи 1/2/3: " MODE
[[ -z "${MODE:-}" ]] && MODE=1

if [[ "${MODE}" == "3" ]]; then
  read -rp "Домен, по которому чистим: " CLEAN_FQDN
  [[ -z "${CLEAN_FQDN}" ]] && { err "Домен обязателен"; exit 1; }
  read -rp "Удалить сертификат Let's Encrypt для ${CLEAN_FQDN}? [Y/n]: " DELCERT; DELCERT="${DELCERT:-Y}"
  read -rp "Удалить веб-контент /var/www/zeronode ? [y/N]: " PURGEWEB; PURGEWEB="${PURGEWEB:-N}"
  cleanup_domain "${CLEAN_FQDN}" "${DELCERT}" "${PURGEWEB}"
  exit 0
fi

explain_domains "${MODE}"

# ---------- Ввод ----------
if [[ "${MODE}" == "1" ]]; then
  echo "${DIM}Пример: CDN-домен=cdn2.yourbeautycostmore.hair (CNAME -> 4f07...yccdn...), Origin=cdnhello.yourbeautycostmore.hair (A -> IP VPS)${RST}"
else
  echo "${DIM}Пример: CDN-домен=cdnhello.yourbeautycostmore.hair (A -> IP VPS), Origin=тот же${RST}"
fi

read -rp "CDN-домен (публичный, куда идут клиенты): " CDN_DOMAIN
read -rp "Origin/TLS-домен (на нём выпустим SSL; в панели CDN — origin host): " INTERNAL_DOMAIN
read -rp "XHTTP путь (по умолчанию /cdn/video/hls/): " XHTTP_PATH
XHTTP_PATH="${XHTTP_PATH:-/cdn/video/hls/}"

LE_EMAIL_DEFAULT="admin@${INTERNAL_DOMAIN}"
read -rp "E-mail для Let's Encrypt [${LE_EMAIL_DEFAULT}]: " LE_EMAIL
LE_EMAIL="${LE_EMAIL:-$LE_EMAIL_DEFAULT}"

read -rp "Если cert отсутствует — выпустить для ${INTERNAL_DOMAIN}? [Y/n]: " WANT_CERT_INTERNAL
WANT_CERT_INTERNAL="${WANT_CERT_INTERNAL:-Y}"

[[ -z "${CDN_DOMAIN}" || -z "${INTERNAL_DOMAIN}" ]] && { err "CDN-домен и Origin/TLS-домен обязательны"; exit 1; }

echo
echo "${BLD}ИТОГО:${RST}
  CDN-домен (публичный):  ${CYA}${CDN_DOMAIN}${RST}
  Origin/TLS-домен:       ${CYA}${INTERNAL_DOMAIN}${RST}
  XHTTP путь:             ${CYA}${XHTTP_PATH}${RST}
  Cert для Origin:        ${CYA}${WANT_CERT_INTERNAL}${RST}"
echo

# ---------- Пакеты ----------
step "Ставлю пакеты (nginx, certbot, curl, ca-certificates) ..."
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y nginx certbot curl ca-certificates
if command -v ufw >/dev/null 2>&1; then ufw allow 80/tcp || true; ufw allow 443/tcp || true; fi
ok "Пакеты готовы"

WEB_ROOT="/var/www/zeronode"
HTML_ROOT="${WEB_ROOT}/html"
ACME_ROOT="/var/www/letsencrypt"
HLS_ROOT="${WEB_ROOT}${XHTTP_PATH%/}"

step "Готовлю директории сайта/ACME/HLS ..."
mkdir -p "${HTML_ROOT}" "${ACME_ROOT}" "${HLS_ROOT}"
ok "Директории есть"

# ---------- index.html ----------
step "Разворачиваю index.html (если отсутствует)"
if [[ -f "${HTML_ROOT}/index.html" ]]; then
  warn "index.html уже есть — не трогаю"
else
  cat > "${HTML_ROOT}/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Edge node</title>
<body style="margin:0;background:#0f172a;color:#e5e7eb;font:16px/1.5 -apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Arial,sans-serif">
<div style="max-width:860px;margin:10vh auto;padding:24px">
  <h1 style="margin:0 0 8px">Edge node</h1>
  <p>Статический сайт + XHTTP.</p>
</div>
</body>
HTML
  ok "index.html создан"
fi

# ---------- ACME :80 ----------
TEMP80="/etc/nginx/sites-available/_acme_${INTERNAL_DOMAIN}.conf"
if [[ "${WANT_CERT_INTERNAL^^}" != "N" ]]; then
  step "Поднимаю временный HTTP для ACME ..."
  cat > "${TEMP80}" <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name ${INTERNAL_DOMAIN} ${CDN_DOMAIN};
  location /.well-known/acme-challenge/ { root ${ACME_ROOT}; allow all; }
  location / { return 301 https://\$host\$request_uri; }
}
EOF
  ln -sf "${TEMP80}" "/etc/nginx/sites-enabled/_acme_${INTERNAL_DOMAIN}.conf"
  nginx -t && systemctl reload nginx
  ok "ACME-сайт включён"

  step "Выпускаю сертификат для ${INTERNAL_DOMAIN} ..."
  if certbot certonly --agree-tos --no-eff-email --email "${LE_EMAIL}" --webroot -w "${ACME_ROOT}" -d "${INTERNAL_DOMAIN}" -n; then
    ok "Сертификат выпущен"
  else
    warn "Выпустить не удалось — продолжаю, если cert уже есть."
  fi
fi

FULLCHAIN_INT="/etc/letsencrypt/live/${INTERNAL_DOMAIN}/fullchain.pem"
PRIVKEY_INT="/etc/letsencrypt/live/${INTERNAL_DOMAIN}/privkey.pem"
[[ ! -s "${FULLCHAIN_INT}" || ! -s "${PRIVKEY_INT}" ]] && { err "Нет валидного cert для ${INTERNAL_DOMAIN}"; exit 1; }

# ---------- Определяем корректный сокет ----------
step "Ищу доступные UNIX-сокеты Xray в /dev/shm ..."
mapfile -t SOCKETS < <(ls -1 /dev/shm/*.socket 2>/dev/null || true)
SOCK_PATH_DEFAULT="/dev/shm/xrxh.socket"
# эвристика: если путь содержит 'cdn2' — предлагаем xrxh2.socket
if [[ "${XHTTP_PATH}" == *"/cdn2/"* ]] && [[ -S "/dev/shm/xrxh2.socket" ]]; then
  SOCK_PATH_DEFAULT="/dev/shm/xrxh2.socket"
fi

if ((${#SOCKETS[@]})); then
  echo "Найдено сокетов:"
  i=1; for s in "${SOCKETS[@]}"; do echo "  ${i}) ${s}"; ((i++)); done
  read -rp "Выбери номер сокета (ENTER = ${SOCK_PATH_DEFAULT}): " CH
  if [[ -n "${CH:-}" && "${CH}" =~ ^[0-9]+$ && "${CH}" -ge 1 && "${CH}" -le "${#SOCKETS[@]}" ]]; then
    SOCK_PATH="${SOCKETS[$((CH-1))]}"
  else
    SOCK_PATH="${SOCK_PATH_DEFAULT}"
  fi
else
  warn "Сокетов не найдено. По умолчанию укажу ${SOCK_PATH_DEFAULT}."
  SOCK_PATH="${SOCK_PATH_DEFAULT}"
fi
warn "Использую сокет: ${SOCK_PATH}"
[[ ! -S "${SOCK_PATH}" ]] && warn "Сейчас его нет — подними inbound в Remnawave/Xray на этот путь, иначе будет 502."

# ---------- Основной nginx-вирт ----------
SITE_FILE="/etc/nginx/sites-available/${INTERNAL_DOMAIN}.conf"
SITE_LINK="/etc/nginx/sites-enabled/${INTERNAL_DOMAIN}.conf"
step "Пишу nginx-конфиг: ${SITE_FILE}"

cat > "${SITE_FILE}" <<NGINX
server {
    listen 443 ssl http2;
    server_name ${INTERNAL_DOMAIN} ${CDN_DOMAIN};

    ssl_certificate     ${FULLCHAIN_INT};
    ssl_certificate_key ${PRIVKEY_INT};
    http2_max_concurrent_streams 128;

    location / {
        root ${HTML_ROOT};
        index index.html;
        charset utf-8;
    }

    location = /health { return 204; }

    # HLS-файлы с диска
    location ~* ^${XHTTP_PATH%/}/(.*\.(m3u8|ts))$ {
        root ${WEB_ROOT};
        types { application/vnd.apple.mpegurl m3u8; video/mp2t ts; }
        if (\$uri ~* "\.m3u8$") { add_header Cache-Control "no-cache, no-store, must-revalidate"; }
        if (\$uri ~* "\.ts$")   { add_header Cache-Control "public, max-age=31536000, immutable"; }
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Headers "Range, Origin, Content-Type, Accept" always;
        add_header Access-Control-Expose-Headers "Content-Length, Content-Range" always;
        default_type application/octet-stream;
    }

    # Всё остальное под XHTTP-путём — в Xray по gRPC/UNIX
    location ${XHTTP_PATH} {
        client_max_body_size 0;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        client_body_timeout 5m;
        grpc_read_timeout   315s;
        grpc_send_timeout   5m;
        grpc_pass unix:${SOCK_PATH};
    }
}
NGINX

ln -sf "${SITE_FILE}" "${SITE_LINK}"
rm -f "/etc/nginx/sites-enabled/_acme_${INTERNAL_DOMAIN}.conf" "${TEMP80}" 2>/dev/null || true
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

step "Проверяю конфиги nginx и перезагружаю ..."
nginx -t
systemctl reload nginx || systemctl restart nginx
ok "nginx перезагружен"

# ---------- Диагностика ----------
step "Самопроверка"
set +e
CODE_HEALTH=$(curl -sS -o /dev/null -w "%{http_code}" --http2 -k "https://${INTERNAL_DOMAIN}/health")
CODE_TUNNEL=$(curl -sS -o /dev/null -w "%{http_code}" --http2 -k "https://${INTERNAL_DOMAIN}${XHTTP_PATH}test")
MIME_M3U8=$(curl -sS -I --http2 -k "https://${INTERNAL_DOMAIN}${XHTTP_PATH}master.m3u8" | awk -F': ' 'tolower($1)=="content-type"{gsub("\r","");print $2}')
set -e

echo "  /health → ${CODE_HEALTH}"
if [[ "${CODE_HEALTH}" == "204" ]]; then
  echo "   ${GRN}OK${RST}: HTTPS сайт отвечает."
else
  echo "   ${RED}FAIL${RST}: /health не 204 — проверь SSL/сервернеймы/DNS/файрвол."
fi

echo "  ${XHTTP_PATH}test → ${CODE_TUNNEL}"
case "${CODE_TUNNEL}" in
  400) echo "   ${GRN}OK${RST}: XHTTP жив (400 — ожидаемо без полезной нагрузки клиента VLESS)." ;;
  502) echo "   ${RED}FAIL${RST}: 502 — nginx не достучался до Xray. Скорее всего нет сокета ${SOCK_PATH} или неверен путь XHTTP."
       echo "             Проверь: ls -lh ${SOCK_PATH} и inbound Remnawave (listen=${SOCK_PATH}, path=${XHTTP_PATH})." ;;
  499|504) echo "   ${YLW}WARN${RST}: таймаут/обрыв. Проверь нагрузку и доступность Xray." ;;
  *) echo "   ${YLW}WARN${RST}: код ${CODE_TUNNEL}. Для живого XHTTP обычно видим 400; иное — проверь inbound/сокет/путь." ;;
esac

if [[ -n "${MIME_M3U8}" ]]; then
  echo "  master.m3u8 Content-Type → ${MIME_M3U8}"
  [[ "${MIME_M3U8}" == "application/vnd.apple.mpegurl" ]] \
    && echo "   ${GRN}OK${RST}: MIME корректен." \
    || echo "   ${YLW}WARN${RST}: неожиданный MIME — проверь regex location для m3u8."
else
  echo "  master.m3u8: ${DIM}файл не найден — это нормально, если HLS ещё не залит.${RST}"
fi

echo
echo "${BLD}${GRN}===================== ГОТОВО =====================${RST}"
echo " CDN-домен (публичный):  ${CDN_DOMAIN}"
echo " Origin/TLS-домен:       ${INTERNAL_DOMAIN}"
echo " XHTTP путь:             ${XHTTP_PATH}"
echo " Xray сокет:             ${SOCK_PATH}"
echo
if [[ "${MODE}" == "1" ]]; then
  echo "Подсказка для CDN:"
  echo " - В DNS сделай CNAME для ${CDN_DOMAIN} → хост, выданный провайдером CDN."
  echo " - В панели CDN: origin=${INTERNAL_DOMAIN}, protocol=HTTPS, host header=${INTERNAL_DOMAIN}."
else
  echo "Подсказка без CDN:"
  echo " - В DNS сделай A для ${CDN_DOMAIN} → IP VPS. При желании используй его же как origin."
fi
[[ ! -S "${SOCK_PATH}" ]] && echo "${YLW}!${RST} Внимание: сокет ${SOCK_PATH} сейчас отсутствует. Подними inbound в Remnawave/Xray:"
[[ ! -S "${SOCK_PATH}" ]] && echo "    listen=${SOCK_PATH}, path=${XHTTP_PATH}, network=xhttp, mode=auto, decryption=none."
