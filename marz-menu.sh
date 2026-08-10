#!/bin/bash
# Quick-access menu for a Marzban install done via install.sh: update,
# restart, change domain, backup/restore for server migration, manage the
# admin account, and full uninstall -- all in one place.
#
# Installed by install.sh as the `marz-menu` command (run it from anywhere).

set -uo pipefail

CONF_FILE="/etc/marzban/marz-menu.conf"

if [ "$(id -u)" -ne 0 ]; then
  echo "Нужны права root. Запусти: sudo marz-menu" >&2
  exit 1
fi

if [ ! -f "$CONF_FILE" ]; then
  echo "Не найден $CONF_FILE -- похоже, панель установлена не через install.sh." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$CONF_FILE"

if [ -z "${PROJECT_DIR:-}" ] || [ ! -f "$PROJECT_DIR/docker-compose.yml" ]; then
  echo "PROJECT_DIR ($PROJECT_DIR) не похож на папку установки Marzban." >&2
  exit 1
fi

cd "$PROJECT_DIR"

DIM='\033[2;36m'
BOLD_CYAN='\033[1;36m'
RESET='\033[0m'
RULE="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

banner() {
  printf "${DIM}%s${RESET}\n" "$RULE"
  printf "${BOLD_CYAN}            𝑨 𝑹 𝑺 𝑰             ${RESET}\n"
  printf "${DIM}         Marz Menu               ${RESET}\n"
  printf "${DIM}%s${RESET}\n" "$RULE"
}

get_env() {
  local key="$1"
  grep -E "^${key}[[:space:]]*=" .env 2>/dev/null | head -n1 | sed -E "s/^${key}[[:space:]]*=[[:space:]]*\"?([^\"]*)\"?[[:space:]]*\$/\1/"
}

set_env() {
  local key="$1" value="$2"
  if grep -q "^${key}[[:space:]]*=" .env; then
    sed -i "s|^${key}[[:space:]]*=.*|${key} = \"${value}\"|" .env
  elif grep -q "^# ${key}[[:space:]]*=" .env; then
    sed -i "s|^# ${key}[[:space:]]*=.*|${key} = \"${value}\"|" .env
  else
    echo "${key} = \"${value}\"" >> .env
  fi
}

pause() {
  echo
  read -r -p "Enter -- вернуться в меню... " _
}

action_status() {
  echo
  docker compose ps
  echo
  local internal_port
  internal_port=$(get_env UVICORN_PORT)
  if [ -f /etc/nginx/sites-available/marzban ] && grep -q "server_name" /etc/nginx/sites-available/marzban && ! grep -q "server_name _;" /etc/nginx/sites-available/marzban; then
    local panel_domain
    panel_domain=$(grep -m1 "server_name" /etc/nginx/sites-available/marzban | awk '{print $2}' | tr -d ';')
    echo "Dashboard: https://${panel_domain}/dashboard/"
  else
    local ip
    ip=$(curl -fsS -4 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    local port
    port=$(grep -oP 'listen \K[0-9]+' /etc/nginx/sites-available/marzban 2>/dev/null | head -n1)
    echo "Dashboard: http://${ip}:${port:-$internal_port}/dashboard/"
  fi
  pause
}

action_update() {
  echo
  echo "Обновляю исходники..."
  git pull

  # marz-menu might itself have changed upstream -- keep the installed
  # command in sync with whatever's now in the repo.
  if [ -f "$PROJECT_DIR/marz-menu.sh" ]; then
    cp "$PROJECT_DIR/marz-menu.sh" /usr/local/bin/marz-menu
    chmod +x /usr/local/bin/marz-menu
  fi

  echo "Пересобираю и перезапускаю..."
  docker compose down || true
  docker compose up -d --build
  echo "Готово."
  pause
}

action_restart() {
  echo
  docker compose restart
  echo "Панель перезапущена."
  pause
}

action_logs() {
  echo
  read -r -p "Сколько последних строк показать? [100]: " n
  n=${n:-100}
  docker compose logs --tail="$n" marzban
  pause
}

action_change_domain() {
  echo
  read -r -p "Новый домен для панели (например panel.example.com): " NEW_PANEL_DOMAIN
  read -r -p "Новый домен для подписок (например subs.example.com): " NEW_SUBS_DOMAIN
  if [ -z "$NEW_PANEL_DOMAIN" ] || [ -z "$NEW_SUBS_DOMAIN" ]; then
    echo "Оба домена обязательны, отменяю." >&2
    pause
    return
  fi
  read -r -p "Email для Let's Encrypt [admin@${NEW_PANEL_DOMAIN}]: " CERTBOT_EMAIL
  CERTBOT_EMAIL=${CERTBOT_EMAIL:-admin@${NEW_PANEL_DOMAIN}}

  local internal_port
  internal_port=$(get_env UVICORN_PORT)
  internal_port=${internal_port:-8001}

  if ! command -v certbot >/dev/null 2>&1; then
    echo "Ставлю certbot..."
    apt-get update -qq
    apt-get install -y -qq certbot python3-certbot-nginx
  fi

  cat > /etc/nginx/sites-available/marzban <<EOF
server {
    listen 80;
    server_name ${NEW_PANEL_DOMAIN};
    location / {
        proxy_pass http://127.0.0.1:${internal_port};
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
server {
    listen 80;
    server_name ${NEW_SUBS_DOMAIN};
    location / {
        proxy_pass http://127.0.0.1:${internal_port};
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/marzban /etc/nginx/sites-enabled/marzban
  if ! nginx -t; then
    echo "nginx -t не прошёл, конфиг не применён." >&2
    pause
    return
  fi
  systemctl reload nginx || systemctl restart nginx

  set_env XRAY_SUBSCRIPTION_URL_PREFIX "https://${NEW_SUBS_DOMAIN}"
  docker compose up -d

  echo "Запрашиваю SSL сертификат..."
  if ! certbot --nginx --non-interactive --agree-tos -m "$CERTBOT_EMAIL" \
      -d "$NEW_PANEL_DOMAIN" -d "$NEW_SUBS_DOMAIN"; then
    echo "certbot не смог выпустить сертификат автоматически (проверь, что A-записи уже смотрят на этот сервер)." >&2
    echo "Повторить вручную: certbot --nginx -d ${NEW_PANEL_DOMAIN} -d ${NEW_SUBS_DOMAIN}" >&2
  fi

  echo
  echo "Готово. Новый адрес панели: https://${NEW_PANEL_DOMAIN}/dashboard/"
  pause
}

action_admin() {
  echo
  read -r -p "Имя пользователя админа: " ADMIN_USER
  if [ -z "$ADMIN_USER" ]; then
    echo "Имя не может быть пустым." >&2
    pause
    return
  fi
  read -r -s -p "Новый пароль (пусто -- сгенерировать): " ADMIN_PASS
  echo
  if [ -z "$ADMIN_PASS" ]; then
    ADMIN_PASS=$(openssl rand -hex 12)
    GENERATED_PASS=true
  else
    GENERATED_PASS=false
  fi

  local OUTPUT
  if OUTPUT=$(docker compose exec -T \
    -e ADMIN_USERNAME="$ADMIN_USER" \
    -e ADMIN_PASSWORD="$ADMIN_PASS" \
    marzban python3 -c "
import os
from app.db import GetDB, crud
from app.models.admin import AdminCreate, AdminPartialModify

username = os.environ['ADMIN_USERNAME']
password = os.environ['ADMIN_PASSWORD']

with GetDB() as db:
    existing = crud.get_admin(db, username)
    if existing:
        crud.partial_update_admin(db, existing, AdminPartialModify(
            password=password,
            is_sudo=None,
            telegram_id=None,
            discord_webhook=None,
            users_usage_limit=None,
            max_users_data_limit=None,
            max_users=None,
            expire_date=None,
        ))
        print('Пароль обновлён для существующего админа.')
    else:
        crud.create_admin(db, AdminCreate(username=username, password=password, is_sudo=True))
        print('Новый sudo-админ создан.')
" 2>&1); then
    echo "$OUTPUT"
    echo
    echo "Username: $ADMIN_USER"
    if [ "$GENERATED_PASS" = true ]; then
      echo "Password: $ADMIN_PASS   (сгенерирован, сохрани)"
    else
      echo "Password: (тот, что ввёл)"
    fi
  else
    echo "$OUTPUT" >&2
    echo "Не получилось -- см. ошибку выше." >&2
  fi
  pause
}

action_export() {
  echo
  local ts backup
  ts=$(date +%Y%m%d-%H%M%S)
  backup="/root/marzban-backup-${ts}.tar.gz"
  echo "Собираю бэкап (база данных, конфиг ядра, .env)..."
  tar czf "$backup" \
    -C /var/lib/marzban . \
    -C "$PROJECT_DIR" .env 2>/dev/null || {
      echo "Не получилось собрать бэкап." >&2
      pause
      return
    }
  echo
  echo "Готово: $backup"
  echo
  echo "Дальше на новом сервере:"
  echo "  1) Установи чистую панель тем же установщиком (тот же однострочник)."
  echo "  2) Скопируй файл сюда:"
  echo "     scp $backup root@<IP_НОВОГО_СЕРВЕРА>:/root/"
  echo "  3) На новом сервере: sudo marz-menu -> \"Перенос -- импорт бэкапа\", укажи путь к файлу."
  pause
}

action_import() {
  echo
  echo "ВНИМАНИЕ: это заменит текущую базу данных, конфиг ядра и .env на этом сервере."
  read -r -p "Путь к файлу бэкапа (marzban-backup-*.tar.gz): " backup
  if [ ! -f "$backup" ]; then
    echo "Файл не найден: $backup" >&2
    pause
    return
  fi
  read -r -p "Точно продолжить и перезаписать текущие данные? [y/N]: " confirm
  if ! [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "Отменено."
    pause
    return
  fi

  echo "Останавливаю панель..."
  docker compose down || true

  local tmp
  tmp=$(mktemp -d)
  tar xzf "$backup" -C "$tmp"

  if [ -f "$tmp/db.sqlite3" ]; then
    cp "$tmp/db.sqlite3" /var/lib/marzban/db.sqlite3
  fi
  if [ -f "$tmp/xray_config.json" ]; then
    cp "$tmp/xray_config.json" /var/lib/marzban/xray_config.json
  fi
  if [ -f "$tmp/.env" ]; then
    cp "$tmp/.env" "$PROJECT_DIR/.env"
  fi
  rm -rf "$tmp"

  echo "Запускаю панель с восстановленными данными..."
  docker compose up -d --build

  echo
  echo "Готово. Проверь, что домены/A-записи (если использовались) теперь смотрят на этот сервер,"
  echo "и при необходимости перевыпусти SSL через пункт \"Сменить домен\"."
  pause
}

action_uninstall() {
  echo
  bash "$PROJECT_DIR/uninstall.sh"
  echo
  echo "marz-menu больше не понадобится на этом сервере."
  read -r -p "Enter -- выход... " _
  exit 0
}

while true; do
  clear
  banner
  echo
  echo "1) Статус панели"
  echo "2) Обновить панель"
  echo "3) Перезапустить панель"
  echo "4) Логи панели"
  echo "5) Сменить домен"
  echo "6) Создать / сбросить пароль админа"
  echo "7) Перенос на другой сервер -- экспорт (бэкап)"
  echo "8) Перенос на другой сервер -- импорт бэкапа"
  echo "9) Полностью удалить панель"
  echo "0) Выход"
  echo
  read -r -p "Выбор: " choice
  case "$choice" in
    1) action_status ;;
    2) action_update ;;
    3) action_restart ;;
    4) action_logs ;;
    5) action_change_domain ;;
    6) action_admin ;;
    7) action_export ;;
    8) action_import ;;
    9) action_uninstall ;;
    0) exit 0 ;;
    *) echo "Не понял выбор." ; sleep 1 ;;
  esac
done
