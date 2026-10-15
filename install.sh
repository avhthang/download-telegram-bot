#!/usr/bin/env bash
# Cài đặt tự động Telegram Video Downloader Bot + Local Bot API Server trên Ubuntu.
#
# Cách dùng (trên VPS):
#   git clone https://github.com/avhthang/download-telegram-bot.git
#   cd download-telegram-bot
#   sudo bash install.sh
#
# Chạy lại script bất cứ lúc nào để cập nhật code/cấu hình; các giá trị cũ được giữ làm mặc định.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/avhthang/download-telegram-bot.git}"
APP_DIR="/opt/download-telegram-bot"
API_DIR="/opt/telegram-bot-api"
APP_USER="tgbot"
SERVICE="telegram-video-bot"
API_PORT=8081
LOGOUT_MARKER="$API_DIR/.cloud-logged-out"

c_info=$'\e[36m'; c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_off=$'\e[0m'
info() { echo "${c_info}==>${c_off} $*"; }
ok()   { echo "${c_ok}✔${c_off} $*"; }
warn() { echo "${c_warn}!${c_off} $*"; }
die()  { echo "${c_err}✘ $*${c_off}" >&2; exit 1; }

# Đọc từ /dev/tty để vẫn nhập được khi chạy qua `curl ... | bash`.
ask() { # ask VAR "Câu hỏi" "mặc định" [secret]
  local var="$1" prompt="$2" default="${3:-}" secret="${4:-}" shown answer
  shown="$default"
  [[ -n "$secret" && -n "$default" ]] && shown="giữ nguyên"
  if [[ -n "$shown" ]]; then prompt="$prompt [$shown]"; fi
  if [[ -n "$secret" ]]; then
    read -r -s -p "$prompt: " answer </dev/tty; echo
  else
    read -r -p "$prompt: " answer </dev/tty
  fi
  printf -v "$var" '%s' "${answer:-$default}"
}

confirm() { # confirm "Câu hỏi" Y|N
  local answer default="${2:-Y}" hint="[Y/n]"
  [[ "$default" == N ]] && hint="[y/N]"
  read -r -p "$1 $hint: " answer </dev/tty
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[YyCc] ]]
}

env_get() { # env_get FILE KEY -> giá trị trong file .env (nếu có)
  [[ -f "$1" ]] || return 0
  grep -E "^$2=" "$1" | tail -n1 | cut -d= -f2- || true
}

tg_call() { # tg_call BASE_URL TOKEN METHOD -> JSON
  curl -s --max-time 30 "$1/bot$2/$3" || true
}

# ---------------------------------------------------------------- kiểm tra
[[ $EUID -eq 0 ]] || die "Hãy chạy bằng quyền root: sudo bash install.sh"
[[ -r /etc/os-release ]] && . /etc/os-release
[[ "${ID:-}" == ubuntu ]] || warn "Script được viết cho Ubuntu; hệ điều hành hiện tại: ${PRETTY_NAME:-không rõ}"
[[ -e /dev/tty ]] || die "Cần terminal tương tác để nhập thông tin."

info "Cài gói cơ bản (curl, git)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl git >/dev/null

# Nguồn code: thư mục chứa script, hoặc clone từ GitHub khi chạy qua curl.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /nonexistent)"
if [[ -f "$SCRIPT_DIR/bot.py" ]]; then
  SRC_DIR="$SCRIPT_DIR"
else
  SRC_DIR="$(mktemp -d)"
  info "Tải code từ $REPO_URL..."
  git clone -q --depth 1 "$REPO_URL" "$SRC_DIR"
fi

# Dừng bot cũ (nếu có) để không chạy song song trong lúc cài.
systemctl stop "$SERVICE" 2>/dev/null || true

# ---------------------------------------------------------------- nhập thông tin
OLD_ENV="$APP_DIR/.env"
OLD_API_ENV="$API_DIR/.env"

echo
echo "================ THÔNG TIN CẤU HÌNH ================"
echo "Nhấn Enter để dùng giá trị trong [ngoặc vuông]."
echo

while true; do
  ask BOT_TOKEN "Bot token (lấy từ @BotFather)" "$(env_get "$OLD_ENV" TELEGRAM_BOT_TOKEN)" secret
  [[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] || { warn "Token không đúng định dạng, nhập lại."; continue; }
  BOT_ID="${BOT_TOKEN%%:*}"
  if [[ -f "$LOGOUT_MARKER" && "$(cat "$LOGOUT_MARKER")" == "$BOT_ID" ]]; then
    # Bot đã chuyển sang server local; gọi API gốc lúc này sẽ đăng nhập lại cloud nên bỏ qua.
    ok "Bot $BOT_ID đã dùng Local Bot API Server từ lần cài trước."
    break
  fi
  resp="$(tg_call https://api.telegram.org "$BOT_TOKEN" getMe)"
  if [[ "$resp" == *'"ok":true'* ]]; then
    ok "Token hợp lệ: @$(sed -n 's/.*"username":"\([^"]*\)".*/\1/p' <<<"$resp")"
    break
  fi
  warn "Telegram từ chối token: ${resp:-không kết nối được}"
  confirm "Vẫn dùng token này?" N && break
done

echo
echo "Local Bot API Server cho phép gửi file tới 2000 MB (mặc định chỉ 50 MB)."
echo "Cần api_id và api_hash lấy tại https://my.telegram.org/apps"
USE_LOCAL_API=N
default_local=Y
[[ -f "$OLD_ENV" && -z "$(env_get "$OLD_ENV" TELEGRAM_API_BASE_URL)" ]] && default_local=N
if confirm "Cài Local Bot API Server?" "$default_local"; then
  USE_LOCAL_API=Y
  while true; do
    ask API_ID "api_id" "$(env_get "$OLD_API_ENV" TELEGRAM_API_ID)"
    [[ "$API_ID" =~ ^[0-9]+$ ]] && break
    warn "api_id phải là số."
  done
  while true; do
    ask API_HASH "api_hash" "$(env_get "$OLD_API_ENV" TELEGRAM_API_HASH)" secret
    [[ "$API_HASH" =~ ^[0-9a-fA-F]{32}$ ]] && break
    warn "api_hash phải gồm 32 ký tự hex."
  done
fi

echo
echo "Channel kho: bot upload video vào channel này rồi copy về nhóm."
echo "Bot phải là admin của channel. Để trống nếu không dùng."
ask STORAGE_CHAT_ID "ID channel kho (vd -1001234567890 hoặc @tenchannel)" "$(env_get "$OLD_ENV" STORAGE_CHAT_ID)"

echo
echo "Giới hạn nhóm được dùng bot (cách nhau bởi dấu phẩy). Để trống = mọi nhóm."
ask ALLOWED_CHAT_IDS "ID các nhóm được phép" "$(env_get "$OLD_ENV" ALLOWED_CHAT_IDS)"

default_conc="$(env_get "$OLD_ENV" MAX_CONCURRENT_DOWNLOADS)"
while true; do
  ask MAX_CONCURRENT "Số video tải đồng thời (1 an toàn cho ổ 30 GB)" "${default_conc:-1}"
  [[ "$MAX_CONCURRENT" =~ ^[1-9][0-9]*$ ]] && break
  warn "Hãy nhập số nguyên dương."
done

if [[ "$USE_LOCAL_API" == Y ]]; then MAX_SIZE=1900; else MAX_SIZE=49; fi

port_in_use() { ss -ltnH "sport = :$1" 2>/dev/null | grep -q .; }

if [[ "$USE_LOCAL_API" == Y ]]; then
  # Giải phóng port của container cũ do chính script này tạo, để không bị tính là xung đột.
  if command -v docker >/dev/null; then
    docker rm -f telegram-bot-api >/dev/null 2>&1 || true
  fi
  old_url="$(env_get "$OLD_ENV" TELEGRAM_API_BASE_URL)"
  old_port="$(sed -n 's#.*127\.0\.0\.1:\([0-9]*\)/.*#\1#p' <<<"$old_url")"
  API_PORT="${old_port:-$API_PORT}"
  if port_in_use "$API_PORT"; then
    echo
    warn "Port $API_PORT đã bị chương trình khác dùng:"
    ss -ltnpH "sport = :$API_PORT" | sed 's/^/    /'
    if ss -ltnpH "sport = :$API_PORT" | grep -qi 'telegram'; then
      warn "Có vẻ đã có một Telegram Bot API Server khác đang chạy (cài tay trước đó?)."
      warn "Hai server cùng dùng một bot sẽ xung đột; nên tắt server cũ sau khi cài xong."
    fi
    free_port="$API_PORT"
    while port_in_use "$free_port"; do free_port=$((free_port + 1)); done
    while true; do
      ask API_PORT "Port cho Local Bot API Server" "$free_port"
      if [[ ! "$API_PORT" =~ ^[0-9]+$ ]] || (( API_PORT < 1024 || API_PORT > 65535 )); then
        warn "Port phải là số từ 1024 đến 65535."
      elif port_in_use "$API_PORT"; then
        warn "Port $API_PORT cũng đang bị dùng."
      else
        break
      fi
    done
  fi
fi

echo
echo "====================================================="
echo " Bot token        : ${BOT_TOKEN%%:*}:***"
echo " Local Bot API    : $USE_LOCAL_API"
if [[ "$USE_LOCAL_API" == Y ]]; then echo " Port Bot API     : 127.0.0.1:$API_PORT"; fi
echo " Giới hạn file    : $MAX_SIZE MB"
echo " Channel kho      : ${STORAGE_CHAT_ID:-(không dùng)}"
echo " Nhóm được phép   : ${ALLOWED_CHAT_IDS:-(tất cả)}"
echo " Tải đồng thời    : $MAX_CONCURRENT"
echo "====================================================="
confirm "Bắt đầu cài đặt?" Y || die "Đã huỷ."

# ---------------------------------------------------------------- swap
mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
swap_mb=$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)
if (( mem_mb < 4000 && swap_mb < 1000 )); then
  info "RAM ${mem_mb} MB, chưa có swap -> tạo swap 2 GB..."
  if [[ ! -f /swapfile ]]; then
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile 2>/dev/null || true
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
  ok "Đã bật swap."
fi

# ---------------------------------------------------------------- gói hệ thống
info "Cài Python, ffmpeg..."
apt-get install -y -qq python3 python3-venv python3-pip ffmpeg >/dev/null
python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' \
  || die "Bot cần Python 3.10+. Hãy dùng Ubuntu 22.04 hoặc mới hơn."

if [[ "$USE_LOCAL_API" == Y ]] && ! { command -v docker >/dev/null && docker compose version >/dev/null 2>&1; }; then
  info "Cài Docker..."
  if ! apt-get install -y -qq docker.io docker-compose-v2 >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
  fi
  systemctl enable --now docker >/dev/null
  ok "Docker đã sẵn sàng."
fi

# ---------------------------------------------------------------- code bot
info "Cài code bot vào $APP_DIR..."
id "$APP_USER" >/dev/null 2>&1 || useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
mkdir -p "$APP_DIR"
if [[ "$(realpath "$SRC_DIR")" != "$(realpath "$APP_DIR")" ]]; then
  tar -C "$SRC_DIR" \
    --exclude=.git --exclude=.venv --exclude=venv --exclude=.env --exclude=downloads \
    --exclude=data --exclude=__pycache__ --exclude='*.sqlite3*' \
    -cf - . | tar -C "$APP_DIR" -xf -
fi
mkdir -p "$APP_DIR/downloads" "$APP_DIR/data"
# Chuyển cache cũ (cài thủ công theo README) vào thư mục data.
if [[ -f "$APP_DIR/storage-cache.sqlite3" && ! -f "$APP_DIR/data/storage-cache.sqlite3" ]]; then
  mv "$APP_DIR"/storage-cache.sqlite3* "$APP_DIR/data/"
fi
chown -R "$APP_USER:$APP_USER" "$APP_DIR/downloads" "$APP_DIR/data"

info "Tạo virtualenv và cài thư viện Python..."
[[ -x "$APP_DIR/.venv/bin/python" ]] || python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/pip" install -q --upgrade pip
"$APP_DIR/.venv/bin/pip" install -q --upgrade -r "$APP_DIR/requirements.txt"
ok "Đã cài thư viện."

info "Ghi cấu hình $APP_DIR/.env..."
{
  echo "TELEGRAM_BOT_TOKEN=$BOT_TOKEN"
  echo "DOWNLOAD_DIR=$APP_DIR/downloads"
  echo "MAX_FILE_SIZE_MB=$MAX_SIZE"
  echo "MAX_CONCURRENT_DOWNLOADS=$MAX_CONCURRENT"
  echo "STORAGE_CACHE_DB=$APP_DIR/data/storage-cache.sqlite3"
  if [[ -n "$STORAGE_CHAT_ID" ]]; then echo "STORAGE_CHAT_ID=$STORAGE_CHAT_ID"; fi
  if [[ -n "$ALLOWED_CHAT_IDS" ]]; then echo "ALLOWED_CHAT_IDS=$ALLOWED_CHAT_IDS"; fi
  if [[ "$USE_LOCAL_API" == Y ]]; then
    echo "TELEGRAM_API_BASE_URL=http://127.0.0.1:$API_PORT/bot"
    echo "TELEGRAM_API_BASE_FILE_URL=http://127.0.0.1:$API_PORT/file/bot"
  fi
  # Giữ các tuỳ chọn yt-dlp nếu đã cấu hình tay.
  for key in YTDLP_COOKIEFILE YTDLP_COOKIES_FROM_BROWSER; do
    val="$(env_get "$OLD_ENV" "$key")"
    if [[ -n "$val" ]]; then echo "$key=$val"; fi
  done
} >"$APP_DIR/.env.new"
mv "$APP_DIR/.env.new" "$APP_DIR/.env"
chown "root:$APP_USER" "$APP_DIR/.env"
chmod 640 "$APP_DIR/.env"

# ---------------------------------------------------------------- Local Bot API Server
if [[ "$USE_LOCAL_API" == Y ]]; then
  info "Cấu hình Local Bot API Server trong $API_DIR..."
  mkdir -p "$API_DIR"
  umask 077
  printf 'TELEGRAM_API_ID=%s\nTELEGRAM_API_HASH=%s\n' "$API_ID" "$API_HASH" >"$API_DIR/.env"
  umask 022
  cat >"$API_DIR/docker-compose.yml" <<EOF
services:
  telegram-bot-api:
    image: aiogram/telegram-bot-api:latest
    container_name: telegram-bot-api
    restart: unless-stopped
    env_file: .env
    ports:
      # Chỉ mở cho localhost. Đừng đổi thành "$API_PORT:8081" vì Docker sẽ vượt qua firewall.
      - "127.0.0.1:$API_PORT:8081"
    volumes:
      - tg-bot-api-data:/var/lib/telegram-bot-api
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
volumes:
  tg-bot-api-data:
EOF
  (cd "$API_DIR" && docker compose pull -q && docker compose up -d --remove-orphans)

  info "Đợi Local Bot API Server khởi động..."
  for _ in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$API_PORT/" || true)"
    [[ "$code" != 000 ]] && break
    sleep 1
  done
  [[ "$code" != 000 ]] || die "Server không phản hồi. Xem log: docker logs telegram-bot-api"

  if [[ ! -f "$LOGOUT_MARKER" || "$(cat "$LOGOUT_MARKER")" != "$BOT_ID" ]]; then
    info "Đăng xuất bot khỏi Bot API gốc của Telegram (bắt buộc khi chuyển sang server local)..."
    resp="$(tg_call https://api.telegram.org "$BOT_TOKEN" logOut)"
    if [[ "$resp" == *'"ok":true'* ]]; then
      echo "$BOT_ID" >"$LOGOUT_MARKER"
      ok "Đã logOut khỏi cloud. (Trong 10 phút tới không thể quay lại API gốc.)"
    else
      warn "logOut trả về: ${resp:-không kết nối được}. Tiếp tục với server local."
    fi
  fi

  resp="$(tg_call "http://127.0.0.1:$API_PORT" "$BOT_TOKEN" getMe)"
  if [[ "$resp" == *'"ok":true'* ]]; then
    ok "Local Bot API Server hoạt động: @$(sed -n 's/.*"username":"\([^"]*\)".*/\1/p' <<<"$resp")"
  else
    die "Server local từ chối bot: $resp (kiểm tra api_id/api_hash, xem: docker logs telegram-bot-api)"
  fi
fi

# ---------------------------------------------------------------- systemd
info "Tạo service $SERVICE..."
after="network-online.target"
[[ "$USE_LOCAL_API" == Y ]] && after="$after docker.service"
cat >"/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=Telegram video downloader bot
After=$after
Wants=network-online.target

[Service]
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/.venv/bin/python $APP_DIR/bot.py
Restart=always
RestartSec=10
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1
systemctl restart "$SERVICE"
sleep 5
if systemctl is-active --quiet "$SERVICE"; then
  ok "Bot đang chạy."
else
  journalctl -u "$SERVICE" -n 30 --no-pager
  die "Bot không khởi động được, xem log ở trên."
fi

cat <<EOF

${c_ok}================ CÀI ĐẶT HOÀN TẤT ================${c_off}
Thêm bot vào nhóm (và làm admin channel kho nếu dùng), rồi gửi link video.

Lệnh hữu ích:
  Xem log bot         : journalctl -u $SERVICE -f
  Khởi động lại bot   : systemctl restart $SERVICE
  Sửa cấu hình        : nano $APP_DIR/.env  (sau đó restart bot)
  Cập nhật yt-dlp     : $APP_DIR/.venv/bin/pip install -U yt-dlp && systemctl restart $SERVICE
  Cập nhật toàn bộ    : git pull && sudo bash install.sh
EOF
if [[ "$USE_LOCAL_API" == Y ]]; then
  cat <<EOF
  Log Bot API Server  : docker logs -f telegram-bot-api
  Cập nhật server API : cd $API_DIR && docker compose pull && docker compose up -d
EOF
fi
