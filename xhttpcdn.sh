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
    * {
      box-sizing: border-box;
    }
    
    body {
      margin: 0;
      font-family: "Segoe UI", "Roboto", "Arial", sans-serif;
      background: linear-gradient(180deg, #0a0a1a 0%, #1a1a2e 100%);
      color: #f2f2f2;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
    }
    
    header {
      background: #830000;
      padding: 15px 20px;
      text-align: center;
      letter-spacing: 0.5px;
      box-shadow: 0 2px 5px rgba(0,0,0,0.4);
      position: relative;
    }
    
    .header-container {
      max-width: 1200px;
      margin: 0 auto;
    }
    
    header h1 {
      margin: 0;
      font-size: 28px;
      font-weight: 700;
      color: #fff;
      line-height: 1.2;
    }
    
    header p {
      font-size: 15px;
      color: #f5cccc;
      margin: 3px 0 0;
    }
    
    .logo {
      position: absolute;
      left: 20px;
      top: 50%;
      transform: translateY(-50%);
      width: 40px;
      height: 40px;
      background: #fff;
      border-radius: 50%;
      display: flex;
      align-items: center;
      justify-content: center;
      font-weight: bold;
      color: #830000;
      cursor: pointer;
    }
    
    .mobile-menu {
      display: none;
      position: absolute;
      right: 20px;
      top: 50%;
      transform: translateY(-50%);
      color: white;
      font-size: 24px;
      cursor: pointer;
    }

    nav {
      background: #6a0000;
      padding: 10px 0;
      box-shadow: 0 2px 3px rgba(0,0,0,0.2);
    }
    
    .nav-container {
      max-width: 1200px;
      margin: 0 auto;
      display: flex;
      justify-content: center;
      flex-wrap: wrap;
    }
    
    nav a {
      color: #f2f2f2;
      text-decoration: none;
      padding: 8px 15px;
      margin: 0 5px;
      font-size: 14px;
      border-radius: 3px;
      transition: background 0.3s;
      cursor: pointer;
    }
    
    nav a:hover {
      background: rgba(255,255,255,0.1);
    }
    
    nav a.active {
      background: rgba(255,255,255,0.2);
      font-weight: bold;
    }

    main {
      max-width: 1200px;
      margin: 20px auto;
      padding: 0 15px;
      flex: 1;
      width: 100%;
    }
    
    .content-wrapper {
      display: flex;
      gap: 20px;
      margin-top: 20px;
    }
    
    .main-content {
      flex: 1;
    }
    
    .sidebar {
      width: 300px;
      flex-shrink: 0;
    }
    
    .page {
      display: none;
    }
    
    .page.active {
      display: block;
    }

    .video-container {
      background: #000;
      border: 3px solid #930000;
      border-radius: 8px;
      box-shadow: 0 0 20px rgba(255,0,0,0.2);
      overflow: hidden;
      margin-bottom: 20px;
    }

    video {
      width: 100%;
      height: auto;
      background: #000;
    }
    
    .video-info {
      padding: 15px;
      background: #1a1a2e;
      border-top: 1px solid #333;
    }
    
    .video-title {
      font-size: 18px;
      font-weight: bold;
      margin-bottom: 5px;
    }
    
    .video-date {
      color: #aaa;
      font-size: 14px;
    }
    
    .video-description {
      margin-top: 10px;
      color: #ccc;
      font-size: 14px;
      line-height: 1.5;
    }

    .btn-watch {
      display: inline-block;
      margin: 10px 0 20px;
      padding: 14px 28px;
      font-size: 18px;
      font-weight: 600;
      color: #fff;
      background: linear-gradient(90deg, #a40000 0%, #d00000 100%);
      border: none;
      border-radius: 4px;
      text-decoration: none;
      cursor: pointer;
      box-shadow: 0 0 8px rgba(255,0,0,0.3);
      transition: 0.3s;
    }
    
    .btn-watch:hover {
      box-shadow: 0 0 15px rgba(255,0,0,0.6);
      transform: scale(1.03);
    }
    
    .btn-secondary {
      display: inline-block;
      margin: 5px;
      padding: 10px 20px;
      font-size: 14px;
      color: #fff;
      background: #333;
      border: none;
      border-radius: 4px;
      text-decoration: none;
      cursor: pointer;
      transition: 0.3s;
    }
    
    .btn-secondary:hover {
      background: #444;
    }

    section.info {
      margin-top: 30px;
      line-height: 1.6;
      color: #ccc;
      text-align: left;
      background: rgba(30,30,50,0.5);
      padding: 20px;
      border-radius: 8px;
    }
    
    section.info h2 {
      color: #f0d0d0;
      font-size: 22px;
      margin-bottom: 10px;
      border-left: 4px solid #b00000;
      padding-left: 8px;
    }
    
    .episodes {
      margin-top: 30px;
    }
    
    .episode-list {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
      gap: 15px;
      margin-top: 15px;
    }
    
    .episode-item {
      background: rgba(40,40,60,0.7);
      border-radius: 5px;
      overflow: hidden;
      transition: transform 0.3s;
      cursor: pointer;
    }
    
    .episode-item:hover {
      transform: translateY(-5px);
    }
    
    .episode-thumb {
      width: 100%;
      height: 120px;
      background: #222;
      display: flex;
      align-items: center;
      justify-content: center;
      color: #777;
      font-size: 14px;
      position: relative;
    }
    
    .episode-thumb::after {
      content: "▶";
      position: absolute;
      top: 50%;
      left: 50%;
      transform: translate(-50%, -50%);
      font-size: 24px;
      color: #fff;
      opacity: 0;
      transition: opacity 0.3s;
    }
    
    .episode-item:hover .episode-thumb::after {
      opacity: 1;
    }
    
    .episode-info {
      padding: 10px;
    }
    
    .episode-title {
      font-size: 14px;
      font-weight: bold;
      margin-bottom: 5px;
    }
    
    .episode-date {
      font-size: 12px;
      color: #aaa;
    }
    
    .sidebar-widget {
      background: rgba(30,30,50,0.5);
      border-radius: 8px;
      padding: 15px;
      margin-bottom: 20px;
    }
    
    .sidebar-title {
      font-size: 18px;
      color: #f0d0d0;
      margin-bottom: 10px;
      padding-bottom: 5px;
      border-bottom: 1px solid #444;
    }
    
    .news-list {
      list-style: none;
      padding: 0;
      margin: 0;
    }
    
    .news-item {
      padding: 8px 0;
      border-bottom: 1px solid #333;
      cursor: pointer;
    }
    
    .news-item:last-child {
      border-bottom: none;
    }
    
    .news-item a {
      color: #f2f2f2;
      text-decoration: none;
      font-size: 14px;
      transition: color 0.3s;
    }
    
    .news-item:hover a {
      color: #ff6b6b;
    }
    
    .news-date {
      font-size: 12px;
      color: #888;
      display: block;
    }
    
    .episode-detail {
      max-width: 800px;
      margin: 0 auto;
    }
    
    .coming-soon {
      text-align: center;
      padding: 40px 20px;
      background: rgba(30,30,50,0.5);
      border-radius: 8px;
      margin-top: 20px;
    }
    
    .coming-soon-icon {
      font-size: 48px;
      margin-bottom: 20px;
    }
    
    .guests-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
      gap: 20px;
      margin-top: 20px;
    }
    
    .guest-card {
      background: rgba(40,40,60,0.7);
      border-radius: 8px;
      padding: 15px;
      text-align: center;
    }
    
    .guest-photo {
      width: 80px;
      height: 80px;
      border-radius: 50%;
      background: #333;
      margin: 0 auto 10px;
      display: flex;
      align-items: center;
      justify-content: center;
      color: #777;
    }
    
    .guest-name {
      font-weight: bold;
      margin-bottom: 5px;
    }
    
    .guest-role {
      font-size: 12px;
      color: #aaa;
    }

    footer {
      margin-top: 50px;
      background: #111;
      color: #777;
      text-align: center;
      padding: 20px 10px;
      font-size: 13px;
      border-top: 1px solid #333;
    }
    
    .footer-links {
      display: flex;
      justify-content: center;
      flex-wrap: wrap;
      margin-bottom: 10px;
    }
    
    .footer-links a {
      color: #aaa;
      text-decoration: none;
      margin: 0 10px;
      font-size: 13px;
      cursor: pointer;
    }
    
    .footer-links a:hover {
      color: #fff;
    }

    /* Адаптивность */
    @media (max-width: 1024px) {
      .content-wrapper {
        flex-direction: column;
      }
      
      .sidebar {
        width: 100%;
      }
      
      .episode-list {
        grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
      }
    }
    
    @media (max-width: 768px) {
      header h1 {
        font-size: 22px;
      }
      
      .logo {
        display: none;
      }
      
      .mobile-menu {
        display: block;
      }
      
      .nav-container {
        flex-direction: column;
        display: none;
      }
      
      .nav-container.active {
        display: flex;
      }
      
      nav a {
        display: block;
        margin: 5px 0;
        text-align: center;
      }
      
      .btn-watch {
        padding: 12px 24px;
        font-size: 16px;
      }
    }
    
    @media (max-width: 480px) {
      header h1 {
        font-size: 20px;
      }
      
      header p {
        font-size: 13px;
      }
      
      .episode-list {
        grid-template-columns: repeat(2, 1fr);
      }
      
      .video-title {
        font-size: 16px;
      }
    }
  </style>
</head>
<body>
  <header>
    <div class="header-container">
      <div class="logo" onclick="showPage('home')">ВС</div>
      <div class="mobile-menu">☰</div>
      <h1>ВЕЧЕР С ВЛАДИМИРОМ СОЛОВЬЁВЫМ</h1>
      <p>Лучшее из программы. Эфир, дискуссии, события дня.</p>
    </div>
  </header>
  
  <nav>
    <div class="nav-container" id="navMenu">
      <a class="nav-link active" onclick="showPage('home')">Главная</a>
      <a class="nav-link" onclick="showPage('episodes')">Выпуски</a>
      <a class="nav-link" onclick="showPage('archive')">Архив</a>
      <a class="nav-link" onclick="showPage('guests')">Гости</a>
      <a class="nav-link" onclick="showPage('photos')">Фото</a>
      <a class="nav-link" onclick="showPage('about')">О программе</a>
      <a class="nav-link" onclick="showPage('contacts')">Контакты</a>
    </div>
  </nav>

  <main>
    <!-- Главная страница -->
    <div id="home" class="page active">
      <div class="content-wrapper">
        <div class="main-content">
          <a href="#video" class="btn-watch" onclick="playCurrentVideo()">▶ Смотреть эфир</a>

          <div class="video-container" id="video">
            <video id="player" controls></video>
            <div class="video-info">
              <div class="video-title" id="currentVideoTitle">Вечер с Владимиром Соловьёвым - Выпуск от 30 мая</div>
              <div class="video-date">Опубликовано: 30.05.2025</div>
              <div class="video-description">Обсуждение актуальных политических событий, международной ситуации и экономических прогнозов с участием ведущих экспертов.</div>
            </div>
          </div>
          
          <div class="actions">
            <a class="btn-secondary" onclick="playPreviousVideo()">Предыдущий выпуск</a>
            <a class="btn-secondary" onclick="playNextVideo()">Следующий выпуск</a>
            <a class="btn-secondary" onclick="showPage('archive')">Архив выпусков</a>
          </div>

          <section class="info">
            <h2>О программе</h2>
            <p>
              «Вечер с Владимиром Соловьёвым» — общественно-политическое ток-шоу,
              в котором обсуждаются самые острые темы дня. Программа выходит в эфир
              ежедневно и собирает за одним столом политиков, экспертов, журналистов и общественных деятелей.
            </p>

            <h2>Последний выпуск</h2>
            <p>
              Смотрите свежие дебаты и комментарии по актуальным вопросам внешней и внутренней политики.
              Лучшие фрагменты и полные выпуски доступны онлайн в HD-качестве.
            </p>
          </section>
          
          <section class="episodes">
            <h2>Последние выпуски</h2>
            <div class="episode-list">
              <div class="episode-item" onclick="playEpisode(0)">
                <div class="episode-thumb">Эфир от 29.05</div>
                <div class="episode-info">
                  <div class="episode-title">Обсуждение новых санкций</div>
                  <div class="episode-date">29.05.2025</div>
                </div>
              </div>
              <div class="episode-item" onclick="playEpisode(1)">
                <div class="episode-thumb">Эфир от 28.05</div>
                <div class="episode-info">
                  <div class="episode-title">Интервью с министром</div>
                  <div class="episode-date">28.05.2025</div>
                </div>
              </div>
              <div class="episode-item" onclick="playEpisode(2)">
                <div class="episode-thumb">Эфир от 27.05</div>
                <div class="episode-info">
                  <div class="episode-title">Экономические прогнозы</div>
                  <div class="episode-date">27.05.2025</div>
                </div>
              </div>
              <div class="episode-item" onclick="playEpisode(3)">
                <div class="episode-thumb">Эфир от 26.05</div>
                <div class="episode-info">
                  <div class="episode-title">Международная ситуация</div>
                  <div class="episode-date">26.05.2025</div>
                </div>
              </div>
            </div>
          </section>
        </div>
        
        <div class="sidebar">
          <div class="sidebar-widget">
            <div class="sidebar-title">Новости программы</div>
            <ul class="news-list">
              <li class="news-item" onclick="showNews(0)">
                <a>Специальный выпуск с участием иностранных экспертов</a>
                <span class="news-date">28.05.2025</span>
              </li>
              <li class="news-item" onclick="showNews(1)">
                <a>Изменение времени эфира на следующей неделе</a>
                <span class="news-date">27.05.2025</span>
              </li>
              <li class="news-item" onclick="showNews(2)">
                <a>Рейтинг программы вырос на 15%</a>
                <span class="news-date">25.05.2025</span>
              </li>
              <li class="news-item" onclick="showNews(3)">
                <a>Новые гости в студии Соловьёва</a>
                <span class="news-date">24.05.2025</span>
              </li>
            </ul>
          </div>
          
          <div class="sidebar-widget">
            <div class="sidebar-title">Популярные выпуски</div>
            <ul class="news-list">
              <li class="news-item" onclick="playPopular(0)">
                <a>Дебаты о будущем экономики</a>
                <span class="news-date">15.05.2025</span>
              </li>
              <li class="news-item" onclick="playPopular(1)">
                <a>Интервью с Сергеем Шойгу</a>
                <span class="news-date">10.05.2025</span>
              </li>
              <li class="news-item" onclick="playPopular(2)">
                <a>Спецвыпуск к 9 мая</a>
                <span class="news-date">09.05.2025</span>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </div>

    <!-- Страница выпусков -->
    <div id="episodes" class="page">
      <div class="content-wrapper">
        <div class="main-content">
          <h1>Все выпуски</h1>
          <div class="episode-list">
            <div class="episode-item" onclick="playEpisode(0)">
              <div class="episode-thumb">Эфир от 29.05</div>
              <div class="episode-info">
                <div class="episode-title">Обсуждение новых санкций</div>
                <div class="episode-date">29.05.2025</div>
              </div>
            </div>
            <div class="episode-item" onclick="playEpisode(1)">
              <div class="episode-thumb">Эфир от 28.05</div>
              <div class="episode-info">
                <div class="episode-title">Интервью с министром</div>
                <div class="episode-date">28.05.2025</div>
              </div>
            </div>
            <div class="episode-item" onclick="playEpisode(2)">
              <div class="episode-thumb">Эфир от 27.05</div>
              <div class="episode-info">
                <div class="episode-title">Экономические прогнозы</div>
                <div class="episode-date">27.05.2025</div>
              </div>
            </div>
            <div class="episode-item" onclick="playEpisode(3)">
              <div class="episode-thumb">Эфир от 26.05</div>
              <div class="episode-info">
                <div class="episode-title">Международная ситуация</div>
                <div class="episode-date">26.05.2025</div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- Страница архива -->
    <div id="archive" class="page">
      <div class="content-wrapper">
        <div class="main-content">
          <h1>Архив выпусков</h1>
          <div class="coming-soon">
            <div class="coming-soon-icon">📁</div>
            <h2>Архив находится в процессе наполнения</h2>
            <p>В ближайшее время здесь будут доступны все выпуски программы за предыдущие периоды.</p>
          </div>
        </div>
      </div>
    </div>

    <!-- Страница гостей -->
    <div id="guests" class="page">
      <div class="content-wrapper">
        <div class="main-content">
          <h1>Постоянные гости программы</h1>
          <div class="guests-grid">
            <div class="guest-card">
              <div class="guest-photo">МП</div>
              <div class="guest-name">Маргарита Симоньян</div>
              <div class="guest-role">Главный редактор RT</div>
            </div>
            <div class="guest-card">
              <div class="guest-photo">ВЖ</div>
              <div class="guest-name">Владимир Жириновский</div>
              <div class="guest-role">Политик</div>
            </div>
            <div class="guest-card">
              <div class="guest-photo">АХ</div>
              <div class="guest-name">Анатолий Вассерман</div>
              <div class="guest-role">Публицист</div>
            </div>
            <div class="guest-card">
              <div class="guest-photo">ОС</div>
              <div class="guest-name">Ольга Скабеева</div>
              <div class="guest-role">Телеведущая</div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- Остальные страницы -->
    <div id="photos" class="page">
      <div class="content-wrapper">
        <div class="main-content">
          <h1>Фотогалерея</h1>
          <div class="coming-soon">
            <div class="coming-soon-icon">📷</div>
            <h2>Фотогалерея скоро будет доступна</h2>
            <p>Мы работаем над добавлением фотографий со съёмок программы.</p>
          </div>
        </div>
      </div>
    </div>

    <div id="about" class="page">
      <div class="content-wrapper">
        <div class="main-content">
          <h1>О программе</h1>
          <section class="info">
            <h2>Вечер с Владимиром Соловьёвым</h2>
            <p>Общественно-политическое ток-шоу, выходящее в эфир с 2012 года. В программе обсуждаются актуальные вопросы политики, экономики и общественной жизни.</p>
            
            <h2>Ведущий</h2>
            <p>Владимир Соловьёв — российский журналист, теле- и радиоведущий, писатель, актёр и общественный деятель.</p>
            
            <h2>Формат</h2>
            <p>Ежедневные выпуски с участием экспертов, политиков и общественных деятелей. Прямые эфиры, горячие дискуссии и эксклюзивные интервью.</p>
          </section>
        </div>
      </div>
    </div>

    <div id="contacts" class="page">
      <div class="content-wrapper">
        <div class="main-content">
          <h1>Контакты</h1>
          <section class="info">
            <h2>Связь с программой</h2>
            <p>Email: solovyov@tv.ru</p>
            <p>Телефон: +7 (495) 123-45-67</p>
            <p>Адрес: Москва, ул. Академика Королёва, 12</p>
            
            <h2>Социальные сети</h2>
            <p>Телеграм: t.me/solovyov_live</p>
            <p>ВКонтакте: vk.com/solovyov</p>
          </section>
        </div>
      </div>
    </div>
  </main>

  <footer>
    <div class="footer-links">
      <a onclick="showPage('about')">О канале</a>
      <a href="#">Реклама</a>
      <a href="#">Для прессы</a>
      <a onclick="showPage('contacts')">Контакты</a>
      <a href="#">Политика конфиденциальности</a>
    </div>
    © 2025 Российское телевидение. Все права защищены.
  </footer>

  <script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
  <script>
    // Данные для видео и выпусков
    const episodes = [
      {
        title: "Вечер с Владимиром Соловьёвым - Выпуск от 30 мая",
        date: "30.05.2025",
        description: "Обсуждение актуальных политических событий, международной ситуации и экономических прогнозов с участием ведущих экспертов.",
        thumb: "Эфир от 30.05"
      },
      {
        title: "Обсуждение новых санкций - 29 мая",
        date: "29.05.2025", 
        description: "Анализ последних международных санкций и их влияния на экономику России.",
        thumb: "Эфир от 29.05"
      },
      {
        title: "Интервью с министром - 28 мая",
        date: "28.05.2025",
        description: "Эксклюзивное интервью с министром иностранных дел о текущей внешней политике.",
        thumb: "Эфир от 28.05"
      },
      {
        title: "Экономические прогнозы - 27 мая", 
        date: "27.05.2025",
        description: "Обсуждение экономической ситуации в стране и прогнозы на ближайшее будущее.",
        thumb: "Эфир от 27.05"
      }
    ];

    let currentEpisodeIndex = 0;

    // Инициализация при загрузке
    document.addEventListener('DOMContentLoaded', function() {
      updateVideoPlayer();
    });

    // Функции навигации по страницам
    function showPage(pageId) {
      // Скрыть все страницы
      document.querySelectorAll('.page').forEach(page => {
        page.classList.remove('active');
      });
      
      // Показать выбранную страницу
      document.getElementById(pageId).classList.add('active');
      
      // Обновить активную ссылку в навигации
      document.querySelectorAll('.nav-link').forEach(link => {
        link.classList.remove('active');
      });
      event.target.classList.add('active');
      
      // Закрыть мобильное меню если открыто
      document.getElementById('navMenu').classList.remove('active');
    }

    // Функции для работы с видео
    function playEpisode(index) {
      currentEpisodeIndex = index;
      showPage('home');
      updateVideoPlayer();
      
      // Прокрутить к видео
      document.getElementById('video').scrollIntoView({ behavior: 'smooth' });
    }

    function playCurrentVideo() {
      updateVideoPlayer();
      document.getElementById('video').scrollIntoView({ behavior: 'smooth' });
    }

    function playPreviousVideo() {
      if (currentEpisodeIndex > 0) {
        currentEpisodeIndex--;
        updateVideoPlayer();
      } else {
        alert('Это самый ранний выпуск в доступном архиве');
      }
    }

    function playNextVideo() {
      if (currentEpisodeIndex < episodes.length - 1) {
        currentEpisodeIndex++;
        updateVideoPlayer();
      } else {
        alert('Это самый свежий выпуск. Следующий эфир будет доступен после выхода в эфир');
      }
    }

    function playPopular(index) {
      const popularEpisodes = [2, 1, 0]; // Индексы популярных выпусков
      playEpisode(popularEpisodes[index]);
    }

    function updateVideoPlayer() {
      const episode = episodes[currentEpisodeIndex];
      document.getElementById('currentVideoTitle').textContent = episode.title;
      
      // В реальном приложении здесь бы загружалось соответствующее видео
      const video = document.getElementById('player');
      video.innerHTML = '<source src="/cdn/video/hls/Vecher.s.Solovyovim.' + 
                       episode.date.replace('.', '').replace('.', '') + 
                       '/master.m3u8" type="application/x-mpegURL">';
      
      // Сообщение о том, что видео загружается
      const videoContainer = document.querySelector('.video-container');
      videoContainer.style.position = 'relative';
      
      if (!videoContainer.querySelector('.video-loading')) {
        const loadingMsg = document.createElement('div');
        loadingMsg.className = 'video-loading';
        // >>> единственная правка ниже — строка cssText обёрнута в строковый литерал
        loadingMsg.style.cssText = `
          position: absolute;
          top: 50%;
          left: 50%;
          transform: translate(-50%, -50%);
          background: rgba(0,0,0,0.8);
          color: white;
          padding: 20px;
          border-radius: 5px;
          text-align: center;
          z-index: 10;
        `;
        loadingMsg.innerHTML = '<div>Видео загружается...</div><div style="font-size:12px; margin-top:10px;">Пожалуйста, подождите</div>';
        videoContainer.appendChild(loadingMsg);
      }
      
      // Имитация загрузки видео
      setTimeout(() => {
        const loadingMsg = videoContainer.querySelector('.video-loading');
        if (loadingMsg) {
          loadingMsg.style.display = 'none';
        }
      }, 2000);
    }

    function showNews(index) {
      const newsTitles = [
        "Специальный выпуск с участием иностранных экспертов",
        "Изменение времени эфира на следующей неделе", 
        "Рейтинг программы вырос на 15%",
        "Новые гости в студии Соловьёва"
      ];
      
      alert('Новость: ' + newsTitles[index] + '\n\nПолный текст новости будет доступен в ближайшее время.');
    }

    // Мобильное меню
    document.querySelector('.mobile-menu').addEventListener('click', function() {
      document.getElementById('navMenu').classList.toggle('active');
    });

    // Инициализация видеоплеера (заглушка)
    const video = document.getElementById('player');
    video.controls = true;
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
