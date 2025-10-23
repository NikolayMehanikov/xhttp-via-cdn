#!/usr/bin/env bash
set -euo pipefail

# ========== Красота ==========
if [[ -t 1 ]]; then
  RED=$(printf '\033[31m'); GRN=$(printf '\033[32m'); YLW=$(printf '\033[33m')
  BLU=$(printf '\033[34m'); CYA=$(printf '\033[36m'); BLD=$(printf '\033[1m')
  RST=$(printf '\033[0m')
else
  RED=""; GRN=""; YLW=""; BLU=""; CYA=""; BLD=""; RST=""
fi
step() { echo; echo "${BLD}${CYA}[STEP]${RST} $*"; }
ok()   { echo "${GRN}✔${RST} $*"; }
warn() { echo "${YLW}!${RST} $*"; }
err()  { echo "${RED}✘${RST} $*" >&2; }

echo "${BLD}${BLU}=== Remnawave VLESS XHTTP через CDN — автонастройка Nginx + сайт ===${RST}"

# ========== Ввод ==========
read -rp "CDN-домен (публичный), напр. 22zbjwrrqb.a.trbcdn.net: " CDN_DOMAIN
read -rp "Внутренний домен ноды (сертификаты уже/будут на нём), напр. zeronode.gonocta.space: " INTERNAL_DOMAIN
read -rp "Путь XHTTP (по умолчанию /cdn/video/hls/): " XHTTP_PATH
XHTTP_PATH="${XHTTP_PATH:-/cdn/video/hls/}"

echo
read -rp "Если сертификатов нет — попытаться выпустить Let's Encrypt для ВНУТРЕННЕГО домена? [Y/n]: " WANT_ISSUE_INT
WANT_ISSUE_INT="${WANT_ISSUE_INT:-Y}"

read -rp "Если DNS CDN-домена указывает на этот сервер — попытаться выпустить и для CDN-домена? [y/N]: " WANT_ISSUE_CDN
WANT_ISSUE_CDN="${WANT_ISSUE_CDN:-N}"

LE_EMAIL_DEFAULT="admin@${INTERNAL_DOMAIN}"
read -rp "E-mail для Let's Encrypt (уведомления) [по умолчанию: ${LE_EMAIL_DEFAULT}]: " LE_EMAIL
LE_EMAIL="${LE_EMAIL:-$LE_EMAIL_DEFAULT}"

read -rp "Удалять конфликтующий nginx-конфиг с этим именем (если есть)? [Y/n]: " RM_CONFLICT
RM_CONFLICT="${RM_CONFLICT:-Y}"

read -rp "Перезагрузить nginx после настройки? [Y/n]: " RELOAD_NGINX
RELOAD_NGINX="${RELOAD_NGINX:-Y}"

if [[ -z "${CDN_DOMAIN}" || -z "${INTERNAL_DOMAIN}" ]]; then
  err "CDN_DOMAIN и INTERNAL_DOMAIN обязательны."
  exit 1
fi

SITE_NAME="${INTERNAL_DOMAIN}"
SITE_FILE="/etc/nginx/sites-available/${SITE_NAME}.conf"
SITE_LINK="/etc/nginx/sites-enabled/${SITE_NAME}.conf"

CERT_DIR_INT="/etc/letsencrypt/live/${INTERNAL_DOMAIN}"
FULLCHAIN_INT="${CERT_DIR_INT}/fullchain.pem"
PRIVKEY_INT="${CERT_DIR_INT}/privkey.pem"

CERT_DIR_CDN="/etc/letsencrypt/live/${CDN_DOMAIN}"
FULLCHAIN_CDN="${CERT_DIR_CDN}/fullchain.pem"
PRIVKEY_CDN="${CERT_DIR_CDN}/privkey.pem"

WEB_ROOT="/var/www/zeronode"
HTML_ROOT="${WEB_ROOT}/html"
HLS_ROOT="${WEB_ROOT}/cdn/video/hls"
ACME_ROOT="/var/www/letsencrypt"

# ========== 1. Пакеты ==========
step "Устанавливаем/обновляем пакеты (nginx, certbot, curl, ca-certificates)..."
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y nginx certbot curl ca-certificates
if command -v ufw >/dev/null 2>&1; then
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
fi
ok "Пакеты готовы"

# ========== 2. Каталоги ==========
step "Готовим каталоги сайта/HLS/ACME..."
mkdir -p "${HTML_ROOT}" "${HLS_ROOT}" "${ACME_ROOT}"
ok "Каталоги созданы"

# ========== 3. Временный HTTP для ACME ==========
TEMP80="/etc/nginx/sites-available/_acme_${SITE_NAME}.conf"
step "Готовим временный сервер :80 для HTTP-01 ACME..."
cat > "${TEMP80}" <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name ${INTERNAL_DOMAIN} ${CDN_DOMAIN};
  location /.well-known/acme-challenge/ {
    root ${ACME_ROOT};
    allow all;
  }
  location / { return 301 https://\$host\$request_uri; }
}
EOF
ln -sf "${TEMP80}" "/etc/nginx/sites-enabled/_acme_${SITE_NAME}.conf"
nginx -t && systemctl reload nginx
ok "ACME-сервер на 80 активирован"

# ========== 4. Выпуск сертификатов при необходимости ==========
want_issue_domain() {
  local domain="$1"
  local fullchain="/etc/letsencrypt/live/${domain}/fullchain.pem"
  local privkey="/etc/letsencrypt/live/${domain}/privkey.pem"
  if [[ -s "$fullchain" && -s "$privkey" ]]; then
    warn "Сертификаты для ${domain} уже найдены. Пропускаю выпуск."
    return 0
  fi
  step "Выпускаем сертификат для ${domain} (HTTP-01, webroot=${ACME_ROOT})..."
  if certbot certonly --agree-tos --no-eff-email --email "${LE_EMAIL}" \
      --webroot -w "${ACME_ROOT}" -d "${domain}" --non-interactive; then
    ok "Выпущено: ${domain}"
  else
    err "Не удалось выпустить сертификат для ${domain}. Проверь DNS A-запись (должна указывать на этот сервер) и доступ к :80."
    return 1
  fi
}

# внутренний домен
if [[ "${WANT_ISSUE_INT^^}" != "N" ]]; then
  want_issue_domain "${INTERNAL_DOMAIN}" || true
fi

# CDN-домен (только если реально указывает на этот сервер)
if [[ "${WANT_ISSUE_CDN^^}" == "Y" ]]; then
  # осторожно: это сработает только если CDN-домен A/AAAA → этот сервер
  want_issue_domain "${CDN_DOMAIN}" || true
fi

# Проверим наличие сертификатов для внутреннего домена (обязательно)
if [[ ! -s "${FULLCHAIN_INT}" || ! -s "${PRIVKEY_INT}" ]]; then
  err "Нет валидных сертификатов для внутреннего домена: ${INTERNAL_DOMAIN}"
  echo "Ожидалось: ${FULLCHAIN_INT} и ${PRIVKEY_INT}"
  echo "Выдай сертификат и перезапусти скрипт."
  exit 1
fi
ok "Сертификаты для ${INTERNAL_DOMAIN} готовы"

# ========== 5. Страница index.html ==========
step "Разворачиваем сайт-плеер (index.html)..."
cat > "${HTML_ROOT}/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <title>Вечер с Владимиром Соловьёвым — Лучшее</title>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="description" content="Лучшее из программы «Вечер с Владимиром Соловьёвым». Новости, эфир, аналитика.">
  <link rel="icon" href="https://upload.wikimedia.org/wikipedia/commons/2/21/Star_icon-72a7cf.svg">
  <style>
    * { box-sizing: border-box; }
    body { margin:0; font-family:"Segoe UI","Roboto","Arial",sans-serif;
      background:linear-gradient(180deg,#0a0a1a 0%,#1a1a2e 100%); color:#f2f2f2; }
    header { background:#830000; padding:15px 20px; text-align:center; box-shadow:0 2px 5px rgba(0,0,0,.4); }
    header h1 { margin:0; font-size:28px; font-weight:700; }
    header p { margin:4px 0 0; color:#f5cccc; }
    main { max-width:1200px; margin:20px auto; padding:0 15px; }
    .btn-watch { display:inline-block; margin:10px 0 20px; padding:14px 28px; font-size:18px;
      color:#fff; background:linear-gradient(90deg,#a40000,#d00000); border-radius:4px; text-decoration:none; }
    .video-container { background:#000; border:3px solid #930000; border-radius:8px; box-shadow:0 0 20px rgba(255,0,0,.2); overflow:hidden; }
    video { width:100%; height:auto; background:#000; }
    .video-info { padding:12px 15px; background:#1a1a2e; border-top:1px solid #333; }
    .video-title { font-weight:700; }
    .overlay { position:absolute; inset:0; display:none; align-items:center; justify-content:center; background:rgba(0,0,0,.5); }
    .overlay.show { display:flex; }
    .wrap { position:relative; }
    footer { margin-top:40px; text-align:center; color:#888; padding:18px 10px; border-top:1px solid #333; background:#111; }
  </style>
</head>
<body>
  <header>
    <h1>ВЕЧЕР С ВЛАДИМИРОМ СОЛОВЬЁВЫМ</h1>
    <p>Лучшее из программы. Эфир, дискуссии, события дня.</p>
  </header>

  <main>
    <a href="#video" class="btn-watch">▶ Смотреть эфир</a>
    <div class="video-container wrap" id="video">
      <video id="player" controls playsinline></video>
      <div id="overlay" class="overlay">
        <a id="playBtn" class="btn-watch">▶ Воспроизвести со звуком</a>
      </div>
      <div class="video-info">
        <div class="video-title">Выпуск (демо)</div>
        <div class="video-date">Опубликовано: 30.05.2025</div>
      </div>
    </div>
  </main>

  <footer>© 2025 Российское телевидение. Все права защищены.</footer>

  <script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
  <script>
    // Автоплей со звуком без клика невозможен по политике браузеров.
    // Делаем "тихий старт" и включаем звук по первому тапу/клику.
    const video = document.getElementById('player');
    const overlay = document.getElementById('overlay');
    const btn = document.getElementById('playBtn');
    const src = '/cdn/video/hls/Vecher.s.Solovyovim.30.05/master.m3u8';

    let inited = false;
    function init() {
      if (inited) return; inited = true;
      if (Hls.isSupported()) { const h = new Hls(); h.loadSource(src); h.attachMedia(video); }
      else if (video.canPlayType('application/vnd.apple.mpegurl')) { video.src = src; }
    }
    (async () => {
      init(); video.muted = true;
      try { await video.play(); overlay.classList.add('show'); }
      catch { overlay.classList.add('show'); }
    })();
    btn.addEventListener('click', async () => {
      init(); video.muted = false; try { await video.play(); } catch {}
      overlay.classList.remove('show');
    });
  </script>
</body>
</html>
HTML
ok "index.html установлен: ${HTML_ROOT}/index.html"

# ========== 6. Nginx сайт с XHTTP/HLS ==========
step "Готовим постоянный nginx-вирт: ${SITE_FILE}"

if [[ -f "${SITE_FILE}" && "${RM_CONFLICT^^}" != "N" ]]; then
  mv -f "${SITE_FILE}" "${SITE_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
  warn "Старый ${SITE_FILE} сохранён как .bak"
fi

cat > "${SITE_FILE}" <<NGINX
server {
    listen 443 ssl http2;
    server_name ${INTERNAL_DOMAIN} ${CDN_DOMAIN};

    # Используем серты внутреннего домена
    ssl_certificate     ${FULLCHAIN_INT};
    ssl_certificate_key ${PRIVKEY_INT};

    http2_max_concurrent_streams 128;

    # Корень: сайт-плеер
    location / {
        root ${HTML_ROOT};
        index index.html;
        charset utf-8;
    }

    # Health-check
    location = /health { return 204; }

    # HLS-файлы -> отдаём с диска (правильные MIME, CORS, кэш)
    location ~* ^${XHTTP_PATH%/}/(.*\\.(m3u8|ts))$ {
        root ${WEB_ROOT};
        types {
            application/vnd.apple.mpegurl m3u8;
            video/mp2t ts;
        }
        # Плейлисты не кэшируем
        if (\$uri ~* "\\.m3u8$") {
            add_header Cache-Control "no-cache, no-store, must-revalidate";
        }
        # Сегменты .ts кэшируем надолго
        if (\$uri ~* "\\.ts$") {
            add_header Cache-Control "public, max-age=31536000, immutable";
        }
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Headers "Range, Origin, Content-Type, Accept" always;
        add_header Access-Control-Expose-Headers "Content-Length, Content-Range" always;
        default_type application/octet-stream;
    }

    # Всё прочее под XHTTP-путём -> в Xray через gRPC (UNIX socket)
    location ${XHTTP_PATH} {
        client_max_body_size 0;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        client_body_timeout 5m;
        grpc_read_timeout   315s;
        grpc_send_timeout   5m;

        grpc_pass unix:/dev/shm/xrxh.socket;
    }
}
NGINX

ln -sf "${SITE_FILE}" "${SITE_LINK}"
# Удалим дефолт, чтобы не мешал
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

# Чистим временный ACME-сайт (нам он больше не нужен)
rm -f "/etc/nginx/sites-enabled/_acme_${SITE_NAME}.conf" "${TEMP80}" 2>/dev/null || true

# Проверка и перезапуск
step "Проверяем конфиги nginx..."
nginx -t
if [[ "${RELOAD_NGINX^^}" != "N" ]]; then
  systemctl reload nginx
  ok "nginx перезагружен"
else
  warn "nginx НЕ перезагружали (по твоему выбору)."
fi

# ========== 7. Самопроверка ==========
step "Самопроверка (через внутренний домен)..."
set +e
HC=$(curl -sS -o /dev/null -w "%{http_code}" --http2 -k "https://${INTERNAL_DOMAIN}/health")
CT=$(curl -sS -I --http2 -k "https://${INTERNAL_DOMAIN}${XHTTP_PATH}master.m3u8" | awk -F': ' 'tolower($1)=="content-type"{print $2}' | tr -d '\r')
set -e
echo "  /health @ ${INTERNAL_DOMAIN}  => HTTP ${HC}"
echo "  MIME(master.m3u8) ожидается application/vnd.apple.mpegurl => ${CT:-<нет файла>}"

echo
echo "${BLD}${GRN}=========================== ГОТОВО ===========================${RST}"
echo "CDN-домен (внешний):      ${CDN_DOMAIN}"
echo "Внутренний домен (TLS):   ${INTERNAL_DOMAIN}"
echo "XHTTP путь:               ${XHTTP_PATH}"
echo
echo "Каталоги:"
echo " - Сайт:  ${HTML_ROOT}"
echo " - HLS:   ${HLS_ROOT}"
echo
echo "Nginx конфиг: ${SITE_FILE}"
echo
echo "Проверка локально (внутренний домен):"
echo "  https://${INTERNAL_DOMAIN}/"
echo "  https://${INTERNAL_DOMAIN}/health   (ожидается HTTP 204)"
echo
echo "Через CDN (после корректной настройки origin/Host на ${INTERNAL_DOMAIN}):"
echo "  https://${CDN_DOMAIN}/"
echo
echo "Напоминание:"
echo " - Плейлисты .m3u8 НЕ кэшируются; сегменты .ts кэшируются надолго (immutable)."
echo " - Всё под ${XHTTP_PATH} НЕ являющееся *.m3u8|*.ts уходит в Xray через unix-сокет /dev/shm/xrxh.socket."
echo " - Remnawave/Xray конфиги скрипт НЕ меняет."
echo "${BLD}${GRN}==============================================================${RST}"
