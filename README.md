# Telegram Video Downloader Bot

Bot Telegram nhận link video trong nhóm/chat, tải video bằng `yt-dlp` với chất lượng cao nhất có thể, gửi lại vào nhóm, rồi xóa file tạm trên VPS.

> Chỉ dùng bot cho nội dung bạn có quyền tải và chia sẻ. Bot không vượt DRM; các website phim/streaming có DRM, chặn bot, hoặc yêu cầu tài khoản có thể không tải được.

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
MAX_FILE_SIZE_MB=1900
```

Nếu chỉ muốn bot hoạt động trong một vài nhóm:

```env
ALLOWED_CHAT_IDS=-1001234567890,-1009876543210
```

Lấy chat id bằng cách thêm bot vào nhóm, gửi một tin nhắn, rồi xem log hoặc dùng các bot lấy ID.

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
- `MAX_FILE_SIZE_MB` nên đặt theo giới hạn upload Telegram/Bot API và dung lượng VPS của bạn.
- Muốn tải chất lượng cao nhất ổn định cần cài `ffmpeg`, vì nhiều nền tảng tách video và audio thành hai luồng.
