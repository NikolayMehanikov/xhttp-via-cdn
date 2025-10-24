#!/usr/bin/env bash
set -euo pipefail

# ========= оформление =========
if [[ -t 1 ]]; then
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'
  BLU=$'\033[34m'; CYA=$'\033[36m'; BLD=$'\033[1m'
  RST=$'\033[0m'
else  RED=""; GRN=""; YLW=""; BLU=""; CYA=""; BLD=""; RST=""; fi
step(){ echo; echo "${BLD}${CYA}[STEP]${RST} $*"; }
ok(){   echo "${GRN}✔${RST} $*"; }
warn(){ echo "${YLW}!${RST} $*"; }
err(){  echo "${RED}✘${RST} $*" >&2; }
die(){  err "$*"; exit 1; }

echo "${BLD}${BLU}=== Remnawave VLESS xHTTP через CDN — автонастройка Nginx + сайт ===${RST}"

# ========= выбор режима =========
echo "Режимы:"
echo "  [1] Чистая установка ноды (база + первый CDN)"
echo "  [2] Добавить ещё один CDN (не трогая существующее)"
read -rp "Выбери режим [1/2]: " MODE
MODE="${MODE:-1}"

# ========= общие переменные =========
WEB_ROOT="/var/www/zeronode"
HTML_ROOT="${WEB_ROOT}/html"
ACME_ROOT="/var/www/letsencrypt"

need_packages(){
  step "Устанавливаем/обновляем пакеты..."
  export DEBIAN_FRONTEND=noninteractive
  apt update -y
  apt install -y nginx certbot curl ca-certificates
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
  fi
  ok "Пакеты готовы"
}

ensure_dirs(){
  step "Готовим каталоги"
  mkdir -p "${HTML_ROOT}" "${WEB_ROOT}/cdn" "${ACME_ROOT}"
  ok "Каталоги готовы"
}

# временный сайт для ACME
enable_temp_acme(){
  local doms="$*"
  local tag="_acme_${RANDOM}"
  local file="/etc/nginx/sites-available/${tag}.conf"
  cat >"$file"<<EOF
server {
  listen 80;
  listen [::]:80;
  server_name ${doms};
  location /.well-known/acme-challenge/ {
    root ${ACME_ROOT};
    allow all;
  }
  location / { return 301 https://\$host\$request_uri; }
}
EOF
  ln -sf "$file" "/etc/nginx/sites-enabled/${tag}.conf"
  nginx -t && systemctl reload nginx
  echo "$file"
}

disable_temp_acme(){
  local file="$1"
  rm -f "$file" "/etc/nginx/sites-enabled/$(basename "$file")" || true
  nginx -t && systemctl reload nginx || true
}

issue_cert(){
  local domain="$1" email="$2"
  local full="/etc/letsencrypt/live/${domain}/fullchain.pem"
  local key="/etc/letsencrypt/live/${domain}/privkey.pem"
  if [[ -s "$full" && -s "$key" ]]; then
    warn "Сертификат уже есть: ${domain}"
    return 0
  fi
  step "Выпуск сертификата для ${domain}"
  certbot certonly --agree-tos --no-eff-email --email "$email" \
    --webroot -w "${ACME_ROOT}" -d "$domain" --non-interactive \
    || die "Не удалось выпустить сертификат для ${domain}"
  ok "Сертификат выпущен: ${domain}"
}

# выбор сокета
detect_socket(){
  local s=""
  for cand in /dev/shm/xrxh.socket /dev/shm/xrxh2.socket; do
    [[ -S "$cand" ]] && s="$cand" && break
  done
  if [[ -z "$s" ]]; then
    warn "UNIX-сокет xHTTP не найден."
    read -rp "Введи путь к сокету (напр. /dev/shm/xrxh.socket): " s
  else
    read -rp "Обнаружен сокет ${s}. Использовать? [Y/n]: " use
    if [[ "${use:-Y}" =~ ^[Nn]$ ]]; then
      read -rp "Введи путь к сокету: " s
    fi
  fi
  [[ -S "$s" ]] || die "Сокет ${s} не существует (или это не сокет)."
  echo "$s"
}

# мини-сайт/плеер
install_site(){
  step "Разворачиваем index.html (если отсутствует)"
  if [[ ! -s "${HTML_ROOT}/index.html" ]]; then
cat > "${HTML_ROOT}/index.html" <<'HTML'
<!DOCTYPE html><html lang="ru"><meta charset="utf-8">
<title>Вечер с Владимиром Соловьёвым — Лучшее</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="icon" href="https://upload.wikimedia.org/wikipedia/commons/2/21/Star_icon-72a7cf.svg">
<style>body{margin:0;font:16px/1.5 -apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Arial,sans-serif;background:#0b0f1a;color:#eee}
header{background:#830000;padding:14px 18px;text-align:center}
main{max-width:1100px;margin:20px auto;padding:0 12px}
.video{border:3px solid #930000;border-radius:8px;overflow:hidden;background:#000}
footer{margin-top:40px;text-align:center;color:#888;padding:16px 8px;border-top:1px solid #333;background:#111}
.btn{display:inline-block;background:#c40000;color:#fff;padding:10px 18px;border-radius:4px;text-decoration:none;margin:10px 0}
.info{background:#141a2a;border-radius:8px;padding:16px;margin-top:18px}
</style>
<header><h1>ВЕЧЕР С ВЛАДИМИРОМ СОЛОВЬЁВЫМ</h1><div>Лучшее из программы. Эфир, дискуссии, события дня.</div></header>
<main>
  <a class="btn" href="#v">▶ Смотреть эфир</a>
  <div id="v" class="video"><video id="player" controls playsinline></video></div>
  <div class="info">Плейлисты .m3u8 не кэшируются, сегменты .ts — кэшируются долго.</div>
</main>
<footer>© 2025 Российское телевидение</footer>
<script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
<script>
const v=document.getElementById('player');const src='/cdn/video/hls/Vecher.s.Solovyovim.30.05/master.m3u8';
if(Hls.isSupported()){const h=new Hls();h.loadSource(src);h.attachMedia(v);}
else if(v.canPlayType('application/vnd.apple.mpegurl')){v.src=src;}
</script></html>
HTML
    ok "Сайт установлен → ${HTML_ROOT}/index.html"
  else
    warn "index.html уже есть — не трогаю"
  fi
}

# генерация nginx-конфига под ОДИН CDN
write_nginx_site(){
  local CDN_DOMAIN="$1" SOCKET="$2" XHTTP_PATH="$3" CERT_DOMAIN="$4"
  local CONF="/etc/nginx/sites-available/${CDN_DOMAIN}.conf"
  local LINK="/etc/nginx/sites-enabled/${CDN_DOMAIN}.conf"
  local FULL="/etc/letsencrypt/live/${CERT_DOMAIN}/fullchain.pem"
  local KEY="/etc/letsencrypt/live/${CERT_DOMAIN}/privkey.pem"

  [[ -s "$FULL" && -s "$KEY" ]] || die "Нет сертификата для ${CERT_DOMAIN}"

  step "Пишем nginx-сайт: ${CONF}"
  cat >"$CONF"<<NGINX
server {
    listen 443 ssl http2;
    server_name ${CDN_DOMAIN};

    ssl_certificate     ${FULL};
    ssl_certificate_key ${KEY};

    http2_max_concurrent_streams 128;

    # Корень: сайт-плеер/страницы
    location / {
        root ${HTML_ROOT};
        index index.html;
        charset utf-8;
    }

    # Health-check
    location = /health { return 204; }

    # HLS-файлы -> отдаём с диска (MIME, CORS, Cache)
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

    # Всё остальное в XHTTP (через UNIX-сокет) — ожидаем 400 + X-Padding
    location ${XHTTP_PATH} {
        client_max_body_size 0;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        client_body_timeout 5m;
        grpc_read_timeout   315s;
        grpc_send_timeout   5m;
        grpc_pass unix:${SOCKET};
    }
}
NGINX
  ln -sf "$CONF" "$LINK"
  nginx -t && systemctl reload nginx
  ok "Сайт активирован: https://${CDN_DOMAIN}/"
}

# диагностика по домену
diagnose_domain(){
  local DOMAIN="$1" XHTTP_PATH="$2"

  echo
  step "Диагностика: ${DOMAIN}"

  local HC=$(curl -sS -o /dev/null -w "%{http_code}" --http2 -k "https://${DOMAIN}/health" || true)
  if [[ "$HC" == "204" ]]; then ok "/health → 204 OK"
  else err "/health → ${HC:-N/A} (ожидается 204)"; fi

  # Проверим MIME, если файл есть
  local HDRS=$(curl -sS -I --http2 -k "https://${DOMAIN}${XHTTP_PATH}master.m3u8" || true)
  local CT=$(sed -n 's/^[cC]ontent-[tT]ype: *//p' <<<"$HDRS" | tr -d '\r')
  local CODE=$(sed -n 's/^HTTP[^ ]* \([0-9][0-9][0-9]\).*/\1/p' <<<"$HDRS" | head -n1)

  if [[ "$CODE" == "200" && "$CT" == application/vnd.apple.mpegurl* ]]; then
    ok "master.m3u8 → 200 (${CT})"
  elif [[ "$CODE" == "404" ]]; then
    warn "master.m3u8 → 404 (файл не найден — это нормально, если HLS ещё не залит)"
  elif [[ -n "$CODE" ]]; then
    warn "master.m3u8 → ${CODE} (${CT:-без Content-Type})"
  else
    warn "master.m3u8 → нет ответа/ошибка запроса"
  fi

  # Проверка xHTTP-ручки (должен отвечать 400 и отдать X-Padding)
  local XCODE=$(curl -sS -o /dev/null -D - --http2 -k "https://${DOMAIN}${XHTTP_PATH}test" | awk 'NR==1{print $2}')
  local XPAD=$(curl -sS -o /dev/null -D - --http2 -k "https://${DOMAIN}${XHTTP_PATH}test" | awk 'BEGIN{IGNORECASE=1}/^X-Padding:/{print $0}')
  if [[ "$XCODE" == "400" && -n "$XPAD" ]]; then
    ok "xHTTP проверка → 400 (прокинуто в Xray, заголовок X-Padding присутствует)"
  elif [[ "$XCODE" == "502" ]]; then
    err "xHTTP проверка → 502 (nginx не может достучаться до UNIX-сокета/инбаунда)"
    echo "  Проверь: существует ли нужный сокет, совпадает ли путь в конфиге, запущен ли remnanode/xray."
  else
    warn "xHTTP проверка → ${XCODE:-N/A} (ожидали 400 c X-Padding)"
  fi
}

# ========= режим 1: чистая установка =========
if [[ "$MODE" == "1" ]]; then
  need_packages
  ensure_dirs
  install_site

  read -rp "CDN-домен (публичный): " CDN_DOMAIN
  read -rp "Домен для TLS-серта (обычно внутренний, можно тот же): " CERT_DOMAIN
  read -rp "E-mail для Let's Encrypt [по умолчанию admin@${CERT_DOMAIN}]: " LE
  LE="${LE:-admin@${CERT_DOMAIN}}"
  read -rp "XHTTP путь [по умолчанию /cdn/video/hls/]: " XHTTP_PATH
  XHTTP_PATH="${XHTTP_PATH:-/cdn/video/hls/}"

  # ACME и сертификат
  ACME_FILE=$(enable_temp_acme "$CDN_DOMAIN $CERT_DOMAIN")
  issue_cert "$CERT_DOMAIN" "$LE"
  disable_temp_acme "$ACME_FILE"

  # сокет
  SOCKET="$(detect_socket)"

  # сайт
  write_nginx_site "$CDN_DOMAIN" "$SOCKET" "$XHTTP_PATH" "$CERT_DOMAIN"

  diagnose_domain "$CDN_DOMAIN" "$XHTTP_PATH"

  echo
  echo "${BLD}${GRN}Готово.${RST} Добавляй новый CDN-ресурс в панели: origin = ${CDN_DOMAIN}, HTTPS, Host = ${CDN_DOMAIN} (или как требуется CDN)."
  exit 0
fi

# ========= режим 2: добавить ещё один CDN =========
if [[ "$MODE" == "2" ]]; then
  need_packages
  ensure_dirs
  install_site

  read -rp "Новый CDN-домен: " CDN_DOMAIN
  read -rp "Какой домен использовать для TLS-серта (обычно тот же CDN-домен): " CERT_DOMAIN
  read -rp "Выпустить/обновить сертификат для ${CERT_DOMAIN}? [Y/n]: " DO_LE
  read -rp "E-mail для Let's Encrypt [по умолчанию admin@${CERT_DOMAIN}]: " LE
  LE="${LE:-admin@${CERT_DOMAIN}}"
  read -rp "XHTTP путь (например /cdn2/video/hls/): " XHTTP_PATH
  XHTTP_PATH="${XHTTP_PATH:-/cdn/video/hls/}"

  # ACME при необходимости
  if [[ "${DO_LE:-Y}" =~ ^[Yy]$ ]]; then
    ACME_FILE=$(enable_temp_acme "$CDN_DOMAIN $CERT_DOMAIN")
    issue_cert "$CERT_DOMAIN" "$LE"
    disable_temp_acme "$ACME_FILE"
  fi

  SOCKET="$(detect_socket)"

  write_nginx_site "$CDN_DOMAIN" "$SOCKET" "$XHTTP_PATH" "$CERT_DOMAIN"
  diagnose_domain "$CDN_DOMAIN" "$XHTTP_PATH"

  echo
  echo "${BLD}${GRN}Готово.${RST} Новый CDN-вирт добавлен: https://${CDN_DOMAIN}/"
  echo "При желании повторяй режим [2] для следующего домена/пути/сокета."
  exit 0
fi

die "Неизвестный режим: ${MODE}"
