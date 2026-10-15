# Telegram Video Downloader Bot

Bot Telegram nhận link video trong nhóm/chat, tải video bằng `yt-dlp` với chất lượng cao nhất có thể, gửi lại vào nhóm, rồi xóa file tạm trên VPS. Có thể dùng một channel riêng làm kho video: bot upload bản gốc vào channel, ghi nhớ URL và message ID, rồi copy nội bộ từ channel về nhóm.

> Chỉ dùng bot cho nội dung bạn có quyền tải và chia sẻ. Bot không vượt DRM; các website phim/streaming có DRM, chặn bot, hoặc yêu cầu tài khoản có thể không tải được.

## Cài đặt nhanh trên VPS Ubuntu (khuyên dùng)

Script `install.sh` tự cài mọi thứ: swap (nếu RAM ít), Python, ffmpeg, Docker, Local Bot API Server (upload tới 2,000 MB), bot chạy nền bằng systemd. Script sẽ hỏi bot token, `api_id`/`api_hash` (lấy tại [my.telegram.org/apps](https://my.telegram.org/apps)), channel kho và các nhóm được phép.

```bash
git clone https://github.com/avhthang/download-telegram-bot.git
cd download-telegram-bot
sudo bash install.sh
```

Cập nhật sau này: `git pull && sudo bash install.sh` (các giá trị cũ được giữ làm mặc định, chỉ cần nhấn Enter).

Bot được cài vào `/opt/download-telegram-bot`, Local Bot API Server ở `/opt/telegram-bot-api`. Xem log: `journalctl -u telegram-video-bot -f`.

Phần dưới đây là hướng dẫn cài thủ công.

## Yêu cầu

- Python 3.10+
- `ffmpeg`
- Bot token từ [@BotFather](https://t.me/BotFather)

## Cài đặt

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

Trên Windows PowerShell:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
```

Sửa `.env`:

```env
TELEGRAM_BOT_TOKEN=token-cua-ban
MAX_FILE_SIZE_MB=49
```

Nếu chỉ muốn bot hoạt động trong một vài nhóm:

```env
ALLOWED_CHAT_IDS=-1001234567890,-1009876543210
```

Lấy chat id bằng cách thêm bot vào nhóm, gửi một tin nhắn, rồi xem log hoặc dùng các bot lấy ID.

## Dùng channel làm kho video

1. Tạo một channel riêng, nên để private nếu chỉ dùng làm kho.
2. Thêm bot làm admin của channel và cấp quyền đăng bài.
3. Thêm cấu hình sau vào `.env`:

```env
STORAGE_CHAT_ID=-1001234567890
STORAGE_CACHE_DB=/opt/download-telegram-bot/storage-cache.sqlite3
```

`STORAGE_CHAT_ID` có thể là numeric ID của private channel hoặc `@username` của channel có username. Khi bật cấu hình này, bot sẽ:

- Lưu file tải lần đầu trong channel.
- Copy chính message đó về nhóm, nên không upload lần hai.
- Lưu URL và `message_id` vào SQLite. Khi người dùng gửi lại đúng URL, bot chỉ copy từ kho Telegram mà không tải lại video.
- Xóa file tạm khỏi VPS ngay sau khi Telegram nhận file.

Channel là nơi lưu tiện dụng, không phải backup duy nhất: không nên xóa các bài trong channel, và vẫn nên giữ nguồn/backup quan trọng ở nơi khác.

## File lớn hơn 50 MB: Local Bot API Server

Bot API tiêu chuẩn của Telegram hiện chỉ cho bot upload video/document tối đa 50 MB. Channel kho **không** tự tăng giới hạn này. Muốn upload tối đa 2,000 MB, cần chạy [Local Bot API Server của Telegram](https://core.telegram.org/bots/api#using-a-local-bot-api-server) ngay trên VPS; Telegram xác nhận local server cho phép upload tới 2,000 MB.

Sau khi Local Bot API Server đã chạy trên VPS ở port `8081`, cập nhật `.env`:

```env
MAX_FILE_SIZE_MB=1900
TELEGRAM_API_BASE_URL=http://127.0.0.1:8081/bot
TELEGRAM_API_BASE_FILE_URL=http://127.0.0.1:8081/file/bot
```

Local Bot API Server yêu cầu `api_id` và `api_hash` của tài khoản Telegram developer, không phải bot token. Tạo chúng tại [my.telegram.org](https://my.telegram.org/apps), rồi cài và chạy server theo [hướng dẫn chính thức](https://github.com/tdlib/telegram-bot-api). Không mở port `8081` ra Internet; chỉ để bot trên cùng VPS truy cập qua `127.0.0.1`.

## Chạy bot

```bash
python bot.py
```

Thêm bot vào nhóm, cấp quyền gửi tin nhắn/file, rồi gửi link video.

## Hỗ trợ nền tảng

Bot dùng `yt-dlp`, nên hỗ trợ rất nhiều nền tảng phổ biến như YouTube, TikTok, Facebook, Instagram, X/Twitter, Reddit, Vimeo và nhiều website video khác. Danh sách hỗ trợ phụ thuộc vào phiên bản `yt-dlp`; hãy cập nhật thường xuyên:

```bash
pip install -U yt-dlp
```

Một số website cần đăng nhập. Có thể cấu hình:

```env
YTDLP_COOKIES_FROM_BROWSER=chrome
```

hoặc:

```env
YTDLP_COOKIEFILE=/absolute/path/to/cookies.txt
```

## Chạy bằng systemd trên VPS Linux

Tạo file `/etc/systemd/system/telegram-video-bot.service`:

```ini
[Unit]
Description=Telegram Video Downloader Bot
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/telegram-video-bot
EnvironmentFile=/opt/telegram-video-bot/.env
ExecStart=/opt/telegram-video-bot/.venv/bin/python /opt/telegram-video-bot/bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Sau đó:

```bash
sudo systemctl daemon-reload
sudo systemctl enable telegram-video-bot
sudo systemctl start telegram-video-bot
sudo journalctl -u telegram-video-bot -f
```

## Ghi chú vận hành

- File tải về được lưu trong thư mục tạm dưới `DOWNLOAD_DIR` và luôn được xóa trong bước `finally`.
- Dùng Bot API tiêu chuẩn: đặt `MAX_FILE_SIZE_MB=49`. Dùng Local Bot API Server: đặt tối đa `1900` để chừa biên an toàn dưới 2 GB.
- Muốn tải chất lượng cao nhất ổn định cần cài `ffmpeg`, vì nhiều nền tảng tách video và audio thành hai luồng.
