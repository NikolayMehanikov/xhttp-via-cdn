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

pause() { read -rp "${DIM}..нажми ENTER для продолжения${RST}"; }

# ========== Удаление/очистка ==========
cleanup_domain() {
  local TARGET_DOMAIN="$1"            # что чистим по server_name (cdn / internal)
  local ALSO_CERT="$2"                # Y/N удалять сертификат
  local PURGE_WEB="$3"                # Y/N снести /var/www/zeronode полностью

  local SA="/etc/nginx/sites-available"
  local SE="/etc/nginx/sites-enabled"

  step "Ищу nginx-конфиги, содержащие server_name ${TARGET_DOMAIN} ..."
  # Поиск файлов, где встречается server_name с доменом
  mapfile -t HITS < <(grep -lsR --include="*.conf" -E "server_name[^;]*\b${TARGET_DOMAIN}\b" "${SA}" 2>/dev/null || true)
  if ((${#HITS[@]})); then
    for f in "${HITS[@]}"; do
      echo " - найден: ${f}"
      local base="$(basename "$f")"
      rm -f "${SE}/${base}" 2>/dev/null || true
      rm -f "${f}" || true
    done
    ok "Удалены конфиги из sites-available и ссылки из sites-enabled"
  else
    warn "Конфиги с server_name ${TARGET_DOMAIN} не найдены"
  fi

  # Сносим временные ACME-сайты, созданные скриптом
  step "Чищу временные ACME-конфиги ..."
  rm -f "${SA}"/_acme_*.conf "${SE}"/_acme_*.conf 2>/dev/null || true
  ok "ACME-конфиги убраны"

  # Сертификат
  if [[ "${ALSO_CERT^^}" == "Y" ]]; then
    step "Удаляю сертификат Let's Encrypt для ${TARGET_DOMAIN} (если есть) ..."
    if [[ -d "/etc/letsencrypt/live/${TARGET_DOMAIN}" ]]; then
      certbot delete --cert-name "${TARGET_DOMAIN}" -n || true
      ok "Сертификат удалён (или отсутствовал)"
    else
      warn "Директория /etc/letsencrypt/live/${TARGET_DOMAIN} не найдена — нечего удалять"
    fi
  fi

  # Веб-корень
  if [[ "${PURGE_WEB^^}" == "Y" ]]; then
    step "Удаляю веб-контент, развёрнутый скриптом (/var/www/zeronode) ..."
    rm -rf /var/www/zeronode 2>/dev/null || true
    rm -rf /var/www/letsencrypt 2>/dev/null || true
    ok "Веб-корень и ACME-папка очищены"
  fi

  step "Проверка nginx и перезагрузка ..."
  if nginx -t; then
    systemctl reload nginx || systemctl restart nginx
    ok "nginx перезагружен"
  else
    err "nginx -t вернул ошибку — проверь конфиги вручную"
  fi

  echo
  ok "Очистка по домену ${TARGET_DOMAIN} завершена."
}

# ========== Выбор режима ==========
banner
echo "Выбери режим:
  ${BLD}1${RST} — Установка с нуля (подготовить всё)
  ${BLD}2${RST} — Добавить ещё один CDN-хост
  ${BLD}3${RST} — Полностью удалить/очистить следы CDN по домену"
read -rp "Введи 1/2/3: " MODE

if [[ "${MODE}" == "3" ]]; then
  read -rp "Домен, по которому чистим (например, cdnhello.example.com): " CLEAN_FQDN
  [[ -z "${CLEAN_FQDN}" ]] && { err "Домен обязателен"; exit 1; }
  read -rp "Удалить сертификат Let's Encrypt для ${CLEAN_FQDN}? [Y/n]: " DELCERT
  DELCERT="${DELCERT:-Y}"
  read -rp "Снести весь контент /var/www/zeronode ? [y/N]: " PURGEWEB
  PURGEWEB="${PURGEWEB:-N}"

  cleanup_domain "${CLEAN_FQDN}" "${DELCERT}" "${PURGEWEB}"
  exit 0
fi

# ========== Ввод ==========
FULL_INSTALL="N"
if [[ "${MODE}" == "1" ]]; then
  FULL_INSTALL="Y"
fi

read -rp "CDN-домен (к которому будут приходить пользователи), напр. cdn.example.com: " CDN_DOMAIN
read -rp "Домен TLS/Origin (обычно твой origin у провайдера/CDN, напр. cdnhello.example.com): " INTERNAL_DOMAIN
read -rp "XHTTP путь (по умолчанию /cdn/video/hls/): " XHTTP_PATH
XHTTP_PATH="${XHTTP_PATH:-/cdn/video/hls/}"

LE_EMAIL_DEFAULT="admin@${INTERNAL_DOMAIN}"
read -rp "E-mail для Let's Encrypt [по умолчанию: ${LE_EMAIL_DEFAULT}]: " LE_EMAIL
LE_EMAIL="${LE_EMAIL:-$LE_EMAIL_DEFAULT}"

read -rp "Если cert'а нет — выпустить для ${INTERNAL_DOMAIN}? [Y/n]: " WANT_CERT_INTERNAL
WANT_CERT_INTERNAL="${WANT_CERT_INTERNAL:-Y}"

echo
# ========== Пакеты и базовые директории ==========
if [[ "${FULL_INSTALL}" == "Y" ]]; then
  step "Устанавливаю пакеты (nginx, certbot, curl, ca-certificates)..."
  export DEBIAN_FRONTEND=noninteractive
  apt update -y
  apt install -y nginx certbot curl ca-certificates
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
  fi
  ok "Пакеты готовы"
fi

WEB_ROOT="/var/www/zeronode"
HTML_ROOT="${WEB_ROOT}/html"
HLS_ROOT="${WEB_ROOT}${XHTTP_PATH%/}"
ACME_ROOT="/var/www/letsencrypt"

step "Готовлю директории сайта/ACME..."
mkdir -p "${HTML_ROOT}" "${HLS_ROOT}" "${ACME_ROOT}"
ok "Директории есть"

# ========== index.html (не затирать, если уже есть) ==========
step "Разворачиваю index.html (если отсутствует)"
if [[ -f "${HTML_ROOT}/index.html" ]]; then
  warn "index.html уже есть — не трогаю"
else
  cat > "${HTML_ROOT}/index.html" <<'HTML'
<!doctype html><html lang="ru"><meta charset="utf-8">
<title>Вечер с Владимиром Соловьёвым — Лучшее</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="icon" href="https://upload.wikimedia.org/wikipedia/commons/2/21/Star_icon-72a7cf.svg">
<style>body{margin:0;font:16px/1.5 -apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Arial,sans-serif;background:#0a0a1a;color:#f2f2f2}
header{background:#830000;padding:12px 16px;text-align:center;box-shadow:0 2px 5px rgba(0,0,0,.4)}
main{max-width:1100px;margin:20px auto;padding:0 16px}
.btn{display:inline-block;padding:10px 18px;background:#cc0000;color:#fff;border-radius:4px;text-decoration:none}
.player{border:3px solid #930000;border-radius:8px;overflow:hidden;background:#000}
video{width:100%;height:auto;background:#000}</style>
<header><h1>ВЕЧЕР С ВЛАДИМИРОМ СОЛОВЬЁВЫМ</h1><p>Лучшее из программы</p></header>
<main><a class="btn" href="#video">▶ Смотреть эфир</a><div class="player" id="video"><video id="player" controls playsinline></video></div></main>
<script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
<script>
const video=document.getElementById('player');const src='/cdn/video/hls/Vecher.s.Solovyovim.30.05/master.m3u8';
function init(){if(Hls.isSupported()){const h=new Hls();h.loadSource(src);h.attachMedia(video)}else if(video.canPlayType('application/vnd.apple.mpegurl')){video.src=src}}
(async()=>{init();video.muted=true;try{await video.play();}catch(e){}})();
</script></html>
HTML
  ok "index.html создан"
fi

# ========== Временный :80 для ACME и выпуск сертификата для INTERNAL ==========
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
    ok "Сертификат выпущен: /etc/letsencrypt/live/${INTERNAL_DOMAIN}/fullchain.pem"
  else
    warn "Не удалось выпустить сертификат для ${INTERNAL_DOMAIN}. Продолжаю, если он уже существовал."
  fi
fi

FULLCHAIN_INT="/etc/letsencrypt/live/${INTERNAL_DOMAIN}/fullchain.pem"
PRIVKEY_INT="/etc/letsencrypt/live/${INTERNAL_DOMAIN}/privkey.pem"
if [[ ! -s "${FULLCHAIN_INT}" || ! -s "${PRIVKEY_INT}" ]]; then
  err "Нет валидного сертификата для ${INTERNAL_DOMAIN}. Завершаю."
  exit 1
fi

# ========== Выбор/указание сокета Xray ==========
step "Пробую найти Xray UNIX-сокеты в /dev/shm ..."
mapfile -t SOCKETS < <(ls -1 /dev/shm/*.socket 2>/dev/null || true)
SOCK_PATH=""
if ((${#SOCKETS[@]})); then
  echo "Найдено:"
  i=1; for s in "${SOCKETS[@]}"; do echo "  ${i}) ${s}"; ((i++)); done
  read -rp "Выбери номер сокета (или ENTER для /dev/shm/xrxh.socket): " CH
  if [[ -n "${CH:-}" && "${CH}" =~ ^[0-9]+$ && "${CH}" -ge 1 && "${CH}" -le "${#SOCKETS[@]}" ]]; then
    SOCK_PATH="${SOCKETS[$((CH-1))]}"
  fi
fi
SOCK_PATH="${SOCK_PATH:-/dev/shm/xrxh.socket}"
warn "Использую путь сокета: ${SOCK_PATH}"
if [[ ! -S "${SOCK_PATH}" ]]; then
  warn "Сокет пока не существует — это OK, если ты ещё не поднял inbound xHTTP в Remnawave/Xray на этот путь."
fi

# ========== Основной nginx-вирт ==========
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
# Уберём временный ACME
rm -f "/etc/nginx/sites-enabled/_acme_${INTERNAL_DOMAIN}.conf" "${TEMP80}" 2>/dev/null || true

step "Проверка и перезагрузка nginx ..."
nginx -t
systemctl reload nginx || systemctl restart nginx
ok "nginx перезагружен"

# ========== Диагностика ==========
step "Самопроверка и диагностика"
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
  400)
    echo "   ${GRN}OK${RST}: Туннель XHTTP отвечает (ожидаемый 400 без валидного запроса)."
    ;;
  502)
    echo "   ${RED}FAIL${RST}: 502 Bad Gateway — вероятно, Xray inbound по сокету ${SOCK_PATH} не запущен или путь неверный."
    echo "       Проверь Remnawave/Xray: listen=\"${SOCK_PATH}\" и перезапусти ядро."
    ;;
  000|*)
    echo "   ${YLW}WARN${RST}: код ${CODE_TUNNEL}. Если не 400 — проверь, что inbound xHTTP реально слушает ${SOCK_PATH}."
    ;;
esac

if [[ -n "${MIME_M3U8}" ]]; then
  echo "  master.m3u8 Content-Type → ${MIME_M3U8}"
  if [[ "${MIME_M3U8}" == "application/vnd.apple.mpegurl" ]]; then
    echo "   ${GRN}OK${RST}: MIME корректный для HLS."
  else
    echo "   ${YLW}WARN${RST}: неожиданный MIME — проверь location для m3u8."
  fi
else
  echo "  master.m3u8: ${DIM}плейлист не найден — это не ошибка, если ты ещё не залил HLS.${RST}"
fi

echo
echo "${BLD}${GRN}===================== ГОТОВО =====================${RST}"
echo " CDN-домен (внешний):    ${CDN_DOMAIN}"
echo " Origin/TLS домен:       ${INTERNAL_DOMAIN}"
echo " XHTTP путь:             ${XHTTP_PATH}"
echo " Веб-корень сайта:       ${HTML_ROOT}"
echo " HLS-корень:             ${HLS_ROOT}"
echo " Xray сокет:             ${SOCK_PATH}"
echo
echo "Подсказка:"
echo " - Если используешь Яндекс CDN: для ${CDN_DOMAIN} ставь CNAME на их домен,"
echo "   а в настройках CDN укажи origin=${INTERNAL_DOMAIN} (наш сервер)."
echo " - Если приходишь напрямую без CDN — делай A-запись ${CDN_DOMAIN} → IP VPS."
echo " - Для удаления смотри режим 3 (очистка) — он уберёт nginx-конфиги, сертификат и веб-корень."
