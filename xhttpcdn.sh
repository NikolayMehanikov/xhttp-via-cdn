#!/usr/bin/env bash
set -euo pipefail

# ========== Красота ==========
if [[ -t 1 ]]; then
  RED=$(printf '\033[31m'); GRN=$(printf '\033[32m'); YLW=$(printf '\033[33m')
  BLU=$(printf '\033[34m'); CYA=$(printf '\033[36m'); BLD=$(printf '\033[1m')
  DIM=$(printf '\033[2m'); RST=$(printf '\033[0m')
else
  RED=""; GRN=""; YLW=""; BLU=""; CYA=""; BLD=""; DIM=""; RST=""
fi
step() { echo; echo "${BLD}${CYA}[STEP]${RST} $*"; }
ok()   { echo "${GRN}✔${RST} $*"; }
warn() { echo "${YLW}!${RST} $*"; }
err()  { echo "${RED}✘${RST} $*" >&2; }

banner() {
  echo "${BLD}${BLU}=== Remnawave VLESS XHTTP через CDN — установка/добавление/очистка ===${RST}"
}

# ------ Подсказки про домены ------
explain_domains() {
  local mode="$1" # 1=через CDN, 2=напрямую
  echo
  echo "${BLD}Как заполнять домены:${RST}"
  if [[ "$mode" == "1" ]]; then
    cat <<'HLP'
  • У тебя внешний CDN (Яндекс CDN, Cloudfort и т.п.)
    - CDN-домен (публичный): твой поддомен, на который будут приходить пользователи.
        Пример: cdn2.yourbeautycostmore.hair
        DNS:     CNAME -> выданный CDN-хост
                 (пример: 4f07146f16015b10.a.yccdn.cloud.yandex.net или htww9x9nsz.cdncf.ru)
    - Origin/TLS-домен: поддомен, указывающий на IP этого VPS (A-запись на IP VPS).
        Пример: cdnhello.yourbeautycostmore.hair
        В панели CDN: origin host = cdnhello.yourbeautycostmore.hair, протокол HTTPS.
HLP
  else
    cat <<'HLP'
  • Без внешнего CDN (напрямую)
    - CDN-домен (публичный): твой поддомен, на который приходят клиенты.
        Пример: cdnhello.yourbeautycostmore.hair
        DNS:     A -> IP VPS
    - Origin/TLS-домен: обычно тот же самый домен (или другой, но также A -> IP VPS).
HLP
  fi
  echo
}

# ========== Очистка ==========
cleanup_domain() {
  local TARGET_DOMAIN="$1"
  local ALSO_CERT="$2"   # Y/N
  local PURGE_WEB="$3"   # Y/N

  local SA="/etc/nginx/sites-available"
  local SE="/etc/nginx/sites-enabled"

  step "Удаляю nginx-конфиги с server_name ${TARGET_DOMAIN} ..."
  mapfile -t HITS < <(grep -lsR --include="*.conf" -E "server_name[^;]*\b${TARGET_DOMAIN}\b" "${SA}" 2>/dev/null || true)
  if ((${#HITS[@]})); then
    for f in "${HITS[@]}"; do
      echo " - ${f}"
      local base="$(basename "$f")"
      rm -f "${SE}/${base}" 2>/dev/null || true
      rm -f "${f}" || true
    done
    ok "Конфиги и ссылки удалены"
  else
    warn "Совпадений в ${SA} не найдено"
  fi

  step "Чищу временные ACME-конфиги ..."
  rm -f "${SA}"/_acme_*.conf "${SE}"/_acme_*.conf 2>/dev/null || true
  ok "ACME-конфиги убраны"

  if [[ "${ALSO_CERT^^}" == "Y" ]]; then
    step "Удаляю сертификат Let's Encrypt для ${TARGET_DOMAIN} (если был) ..."
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

  step "Проверка nginx и перезагрузка ..."
  if nginx -t; then
    systemctl reload nginx || systemctl restart nginx
    ok "nginx перезагружен"
  else
    err "nginx -t упал — проверь конфиги"
  fi

  ok "Очистка по домену ${TARGET_DOMAIN} завершена."
}

# ========== Выбор режима ==========
banner
echo "Режим:
  ${BLD}1${RST} — Установка с нуля (через внешний CDN — CNAME)
  ${BLD}2${RST} — Установка/добавление без CDN (напрямую на VPS)
  ${BLD}3${RST} — Удаление/очистка по домену"
read -rp "Введи 1/2/3: " MODE
[[ -z "${MODE:-}" ]] && MODE=1

if [[ "${MODE}" == "3" ]]; then
  read -rp "Домен, по которому чистим: " CLEAN_FQDN
  [[ -z "${CLEAN_FQDN}" ]] && { err "Домен обязателен"; exit 1; }
  read -rp "Удалить сертификат Let's Encrypt для ${CLEAN_FQDN}? [Y/n]: " DELCERT
  DELCERT="${DELCERT:-Y}"
  read -rp "Удалить веб-контент /var/www/zeronode ? [y/N]: " PURGEWEB
  PURGEWEB="${PURGEWEB:-N}"
  cleanup_domain "${CLEAN_FQDN}" "${DELCERT}" "${PURGEWEB}"
  exit 0
fi

# ========== Ввод с подсказками ==========
explain_domains "${MODE}"

if [[ "${MODE}" == "1" ]]; then
  echo "${DIM}Пример: CDN-домен=cdn2.yourbeautycostmore.hair (CNAME → 4f07...yccdn...), Origin=cdnhello.yourbeautycostmore.hair (A → IP VPS)${RST}"
else
  echo "${DIM}Пример: CDN-домен=cdnhello.yourbeautycostmore.hair (A → IP VPS), Origin=тот же самый${RST}"
fi

read -rp "CDN-домен (публичный, на который пойдут клиенты): " CDN_DOMAIN
read -rp "Origin/TLS-домен (домены для SSL на этом VPS, в CDN-панели — origin host): " INTERNAL_DOMAIN
read -rp "XHTTP путь (по умолчанию /cdn/video/hls/): " XHTTP_PATH
XHTTP_PATH="${XHTTP_PATH:-/cdn/video/hls/}"

LE_EMAIL_DEFAULT="admin@${INTERNAL_DOMAIN}"
read -rp "E-mail для Let's Encrypt [по умолчанию: ${LE_EMAIL_DEFAULT}]: " LE_EMAIL
LE_EMAIL="${LE_EMAIL:-$LE_EMAIL_DEFAULT}"

read -rp "Если cert'а нет — выпустить для ${INTERNAL_DOMAIN}? [Y/n]: " WANT_CERT_INTERNAL
WANT_CERT_INTERNAL="${WANT_CERT_INTERNAL:-Y}"

[[ -z "${CDN_DOMAIN}" || -z "${INTERNAL_DOMAIN}" ]] && { err "CDN-домен и Origin/TLS-домен обязательны"; exit 1; }

echo
echo "${BLD}ИТОГО:${RST}
  CDN-домен (публичный):  ${CYA}${CDN_DOMAIN}${RST}
  Origin/TLS-домен:       ${CYA}${INTERNAL_DOMAIN}${RST}
  Путь XHTTP:             ${CYA}${XHTTP_PATH}${RST}
  Выпуск cert для Origin: ${CYA}${WANT_CERT_INTERNAL}${RST}"
echo

# ========== Пакеты (для «с нуля» и для варианта 2 тоже, если не стоят) ==========
step "Устанавливаю пакеты (nginx, certbot, curl, ca-certificates) ..."
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y nginx certbot curl ca-certificates
if command -v ufw >/dev/null 2>&1; then
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
fi
ok "Пакеты готовы"

WEB_ROOT="/var/www/zeronode"
HTML_ROOT="${WEB_ROOT}/html"
HLS_ROOT="${WEB_ROOT}${XHTTP_PATH%/}"
ACME_ROOT="/var/www/letsencrypt"

step "Готовлю директории сайта/ACME ..."
mkdir -p "${HTML_ROOT}" "${HLS_ROOT}" "${ACME_ROOT}"
ok "Директории есть"

# ===== index.html (не перезаписываем) =====
step "Разворачиваю index.html (если отсутствует)"
if [[ -f "${HTML_ROOT}/index.html" ]]; then
  warn "index.html уже есть — не трогаю"
else
  cat > "${HTML_ROOT}/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Static edge</title>
<body style="margin:0;background:#0f172a;color:#e5e7eb;font:16px/1.5 -apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Arial,sans-serif">
<div style="max-width:860px;margin:10vh auto;padding:24px">
  <h1 style="margin:0 0 8px">Edge node</h1>
  <p>Сервис статического контента и XHTTP-туннеля.</p>
  <p>Путь XHTTP: <code id="p"></code></p>
</div>
<script>document.getElementById('p').textContent=location.origin+'/cdn/video/hls/'.replace('/cdn/video/hls/','/');</script>
</body>
HTML
  ok "index.html создан"
fi

# ===== Временный :80 для ACME и выпуск сертификата =====
TEMP80="/etc/nginx/sites-available/_acme_${INTERNAL_DOMAIN}.conf"
if [[ "${WANT_CERT_INTERNAL^^}" != "N" ]]; then
  step "Поднимаю временный HTTP-сайт для ACME ..."
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
  if certbot certonly --agree-tos --no-eff-email --email "${LE_EMAIL}" \
      --webroot -w "${ACME_ROOT}" -d "${INTERNAL_DOMAIN}" -n; then
    ok "Сертификат выпущен"
  else
    warn "Выпустить не удалось — продолжаем, если cert уже существует."
  fi
fi

FULLCHAIN_INT="/etc/letsencrypt/live/${INTERNAL_DOMAIN}/fullchain.pem"
PRIVKEY_INT="/etc/letsencrypt/live/${INTERNAL_DOMAIN}/privkey.pem"
if [[ ! -s "${FULLCHAIN_INT}" || ! -s "${PRIVKEY_INT}" ]]; then
  err "Нет валидного сертификата для ${INTERNAL_DOMAIN}. Завершаю."
  exit 1
fi

# ===== Выбор сокета Xray =====
step "Пробую найти Xray UNIX-сокеты в /dev/shm ..."
mapfile -t SOCKETS < <(ls -1 /dev/shm/*.socket 2>/dev/null || true)
SOCK_PATH=""
if ((${#SOCKETS[@]})); then
  echo "Найдено:"
  i=1; for s in "${SOCKETS[@]}"; do echo "  ${i}) ${s}"; ((i++)); done
  read -rp "Выбери номер сокета (ENTER = /dev/shm/xrxh.socket): " CH
  if [[ -n "${CH:-}" && "${CH}" =~ ^[0-9]+$ && "${CH}" -ge 1 && "${CH}" -le "${#SOCKETS[@]}" ]]; then
    SOCK_PATH="${SOCKETS[$((CH-1))]}"
  fi
fi
SOCK_PATH="${SOCK_PATH:-/dev/shm/xrxh.socket}"
warn "Использую путь сокета: ${SOCK_PATH}"
if [[ ! -S "${SOCK_PATH}" ]]; then
  warn "Сокет пока не существует — подними inbound xHTTP в Remnawave/Xray на этот путь."
fi

# ===== Основной nginx-вирт =====
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

step "Проверка и перезагрузка nginx ..."
nginx -t
systemctl reload nginx || systemctl restart nginx
ok "nginx перезагружен"

# ===== Диагностика =====
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
  echo "   ${RED}FAIL${RST}: /health не 204 — проверь SSL/сервернеймы/DNS."
fi

echo "  ${XHTTP_PATH}test → ${CODE_TUNNEL}"
case "${CODE_TUNNEL}" in
  400) echo "   ${GRN}OK${RST}: Туннель XHTTP отвечает (ожидаемый 400 без валидного запроса)." ;;
  502) echo "   ${RED}FAIL${RST}: 502 — Xray inbound по сокету ${SOCK_PATH} не запущен или путь неверный." ;;
  *)   echo "   ${YLW}WARN${RST}: код ${CODE_TUNNEL}. Если не 400 — проверь работу inbound/сокета." ;;
esac

if [[ -n "${MIME_M3U8}" ]]; then
  echo "  master.m3u8 Content-Type → ${MIME_M3U8}"
  [[ "${MIME_M3U8}" == "application/vnd.apple.mpegurl" ]] && \
     echo "   ${GRN}OK${RST}: MIME корректен." || \
     echo "   ${YLW}WARN${RST}: неожиданный MIME — проверь location для m3u8."
else
  echo "  master.m3u8: ${DIM}нет файла — это нормально, если HLS ещё не залит.${RST}"
fi

echo
echo "${BLD}${GRN}===================== ГОТОВО =====================${RST}"
echo " CDN-домен (публичный):  ${CDN_DOMAIN}"
echo " Origin/TLS-домен:       ${INTERNAL_DOMAIN}"
echo " XHTTP путь:             ${XHTTP_PATH}"
echo " Xray сокет:             ${SOCK_PATH}"
echo
echo "Подсказка:"
if [[ "${MODE}" == "1" ]]; then
  echo " - В DNS сделай CNAME для ${CDN_DOMAIN} -> хост от провайдера CDN."
  echo " - В панели CDN укажи origin=${INTERNAL_DOMAIN}, protocol=HTTPS, host header=${INTERNAL_DOMAIN}."
else
  echo " - В DNS сделай A для ${CDN_DOMAIN} -> IP VPS. Можно использовать тот же домен для origin."
fi
echo " - Режим 3 («Очистка») удалит конфиги nginx, временные ACME и (опционально) cert и /var/www/zeronode."
