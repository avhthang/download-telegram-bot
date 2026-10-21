import asyncio
from contextlib import suppress
import logging
import os
import re
import shutil
import sqlite3
import subprocess
import tempfile
import time
from pathlib import Path

from dotenv import load_dotenv
from telegram import Update
from telegram.constants import ChatAction
from telegram.error import TelegramError
from telegram.ext import Application, CommandHandler, ContextTypes, MessageHandler, filters
from yt_dlp import YoutubeDL
from yt_dlp.utils import DownloadError


load_dotenv()

TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
DOWNLOAD_ROOT = Path(os.getenv("DOWNLOAD_DIR", "downloads")).resolve()
MAX_FILE_SIZE_MB = int(os.getenv("MAX_FILE_SIZE_MB", "49"))
MAX_FILE_SIZE_BYTES = MAX_FILE_SIZE_MB * 1024 * 1024
MAX_CONCURRENT_DOWNLOADS = int(os.getenv("MAX_CONCURRENT_DOWNLOADS", "2"))
VIDEO_ASPECT_MODE = os.getenv("VIDEO_ASPECT_MODE", "16:9").strip().lower()
DELETE_ORIGINAL_AFTER_SECONDS = int(os.getenv("DELETE_ORIGINAL_AFTER_SECONDS", "86400"))
COOKIES_FROM_BROWSER = os.getenv("YTDLP_COOKIES_FROM_BROWSER", "").strip()
COOKIEFILE = os.getenv("YTDLP_COOKIEFILE", "").strip()
STORAGE_CHAT_ID = os.getenv("STORAGE_CHAT_ID", "").strip()
STORAGE_CACHE_DB = Path(os.getenv("STORAGE_CACHE_DB", "storage-cache.sqlite3")).resolve()
TELEGRAM_API_BASE_URL = os.getenv("TELEGRAM_API_BASE_URL", "").strip()
TELEGRAM_API_BASE_FILE_URL = os.getenv("TELEGRAM_API_BASE_FILE_URL", "").strip()
ALLOWED_CHAT_IDS = {
    int(chat_id.strip())
    for chat_id in os.getenv("ALLOWED_CHAT_IDS", "").split(",")
    if chat_id.strip()
}

URL_RE = re.compile(r"https?://[^\s<>()\"']+", re.IGNORECASE)
DOWNLOAD_SEMAPHORE = asyncio.Semaphore(MAX_CONCURRENT_DOWNLOADS)
VIDEO_CACHE_PROFILE = f"aspect-{VIDEO_ASPECT_MODE}-v1"

logging.basicConfig(
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    level=logging.INFO,
)
logger = logging.getLogger("telegram-video-bot")


def extract_urls(text: str) -> list[str]:
    urls = [url.rstrip(".,);]}>") for url in URL_RE.findall(text or "")]
    return list(dict.fromkeys(urls))


def is_allowed_chat(chat_id: int) -> bool:
    return not ALLOWED_CHAT_IDS or chat_id in ALLOWED_CHAT_IDS


def human_size(size: int) -> str:
    units = ["B", "KB", "MB", "GB"]
    value = float(size)
    for unit in units:
        if value < 1024 or unit == units[-1]:
            return f"{value:.1f} {unit}"
        value /= 1024
    return f"{size} B"


def find_downloaded_files(folder: Path) -> list[Path]:
    files = [path for path in folder.rglob("*") if path.is_file()]
    return sorted(files, key=lambda path: path.stat().st_size, reverse=True)


def initialize_storage_cache() -> None:
    STORAGE_CACHE_DB.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(STORAGE_CACHE_DB) as connection:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS stored_videos (
                source_url TEXT NOT NULL,
                storage_chat_id TEXT NOT NULL,
                message_id INTEGER NOT NULL,
                processing_profile TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (source_url, storage_chat_id)
            )
            """
        )
        columns = {
            row[1] for row in connection.execute("PRAGMA table_info(stored_videos)").fetchall()
        }
        if "processing_profile" not in columns:
            connection.execute(
                "ALTER TABLE stored_videos ADD COLUMN processing_profile TEXT NOT NULL DEFAULT 'legacy'"
            )
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS pending_message_deletions (
                chat_id INTEGER NOT NULL,
                message_id INTEGER NOT NULL,
                delete_after INTEGER NOT NULL,
                PRIMARY KEY (chat_id, message_id)
            )
            """
        )


def get_cached_message_id(url: str) -> int | None:
    if not STORAGE_CHAT_ID:
        return None

    with sqlite3.connect(STORAGE_CACHE_DB) as connection:
        row = connection.execute(
            """
            SELECT message_id FROM stored_videos
            WHERE source_url = ? AND storage_chat_id = ? AND processing_profile = ?
            """,
            (url, STORAGE_CHAT_ID, VIDEO_CACHE_PROFILE),
        ).fetchone()
    return int(row[0]) if row else None


def cache_stored_message(url: str, message_id: int) -> None:
    if not STORAGE_CHAT_ID:
        return

    with sqlite3.connect(STORAGE_CACHE_DB) as connection:
        connection.execute(
            """
            INSERT INTO stored_videos (source_url, storage_chat_id, message_id, processing_profile)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(source_url, storage_chat_id) DO UPDATE SET
                message_id = excluded.message_id,
                processing_profile = excluded.processing_profile,
                created_at = CURRENT_TIMESTAMP
            """,
            (url, STORAGE_CHAT_ID, message_id, VIDEO_CACHE_PROFILE),
        )


def remove_cached_message(url: str) -> None:
    if not STORAGE_CHAT_ID:
        return

    with sqlite3.connect(STORAGE_CACHE_DB) as connection:
        connection.execute(
            "DELETE FROM stored_videos WHERE source_url = ? AND storage_chat_id = ?",
            (url, STORAGE_CHAT_ID),
        )


def schedule_message_deletion(chat_id: int, message_id: int) -> None:
    if DELETE_ORIGINAL_AFTER_SECONDS <= 0:
        return

    delete_after = int(time.time()) + DELETE_ORIGINAL_AFTER_SECONDS
    with sqlite3.connect(STORAGE_CACHE_DB) as connection:
        connection.execute(
            """
            INSERT INTO pending_message_deletions (chat_id, message_id, delete_after)
            VALUES (?, ?, ?)
            ON CONFLICT(chat_id, message_id) DO UPDATE SET delete_after = excluded.delete_after
            """,
            (chat_id, message_id, delete_after),
        )


def get_due_message_deletions() -> list[tuple[int, int]]:
    with sqlite3.connect(STORAGE_CACHE_DB) as connection:
        return connection.execute(
            "SELECT chat_id, message_id FROM pending_message_deletions WHERE delete_after <= ?",
            (int(time.time()),),
        ).fetchall()


def remove_scheduled_deletion(chat_id: int, message_id: int) -> None:
    with sqlite3.connect(STORAGE_CACHE_DB) as connection:
        connection.execute(
            "DELETE FROM pending_message_deletions WHERE chat_id = ? AND message_id = ?",
            (chat_id, message_id),
        )


def retry_scheduled_deletion(chat_id: int, message_id: int) -> None:
    with sqlite3.connect(STORAGE_CACHE_DB) as connection:
        connection.execute(
            """
            UPDATE pending_message_deletions
            SET delete_after = ?
            WHERE chat_id = ? AND message_id = ?
            """,
            (int(time.time()) + 3600, chat_id, message_id),
        )


def build_ydl_options(output_template: str) -> dict:
    options = {
        "format": "bv*+ba/b",
        "merge_output_format": "mp4",
        "outtmpl": output_template,
        "noplaylist": True,
        "quiet": True,
        "no_warnings": True,
        "retries": 5,
        "fragment_retries": 5,
        "continuedl": True,
        "concurrent_fragment_downloads": 4,
        "windowsfilenames": True,
    }

    if COOKIES_FROM_BROWSER:
        options["cookiesfrombrowser"] = (COOKIES_FROM_BROWSER,)
    if COOKIEFILE:
        options["cookiefile"] = COOKIEFILE

    return options


def download_video(url: str, folder: Path) -> tuple[Path, str]:
    output_template = str(folder / "%(title).180B [%(id)s].%(ext)s")
    options = build_ydl_options(output_template)

    with YoutubeDL(options) as ydl:
        info = ydl.extract_info(url, download=True)

    files = find_downloaded_files(folder)
    if not files:
        raise RuntimeError("yt-dlp finished but no downloaded file was found.")

    title = info.get("title") if isinstance(info, dict) else None
    return files[0], title or files[0].stem


def normalize_video_aspect_ratio(file_path: Path) -> Path:
    if VIDEO_ASPECT_MODE == "source":
        return file_path

    if VIDEO_ASPECT_MODE != "16:9":
        raise ValueError("VIDEO_ASPECT_MODE must be either 'source' or '16:9'.")

    output_path = file_path.with_name(f"{file_path.stem}.16x9.mp4")
    # Pad instead of cropping or stretching, so every pixel of the source survives.
    video_filter = (
        "pad=ceil(max(iw,ih*16/9)/2)*2:ceil(max(ih,iw*9/16)/2)*2:"
        "(ow-iw)/2:(oh-ih)/2:color=black,setsar=1"
    )
    command = [
        "ffmpeg",
        "-y",
        "-i",
        str(file_path),
        "-map",
        "0:v:0",
        "-map",
        "0:a?",
        "-vf",
        video_filter,
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "18",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        "-b:a",
        "192k",
        "-movflags",
        "+faststart",
        str(output_path),
    ]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0 or not output_path.exists():
        raise RuntimeError(f"ffmpeg could not normalize the video: {result.stderr[-800:]}")

    file_path.unlink(missing_ok=True)
    return output_path


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    del context
    if update.effective_message:
        await update.effective_message.reply_text(
            "Gửi link video vào nhóm/chat này, mình sẽ tải chất lượng cao nhất có thể rồi gửi lại. "
            "Các nội dung có DRM hoặc không có quyền truy cập hợp lệ sẽ không tải được."
        )


async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    message = update.effective_message
    chat = update.effective_chat
    if not message or not chat:
        return

    if not is_allowed_chat(chat.id):
        logger.info("Ignoring message from unauthorized chat %s", chat.id)
        return

    urls = extract_urls(message.text or message.caption or "")
    if not urls:
        return

    for url in urls:
        await process_url(message, context, url)


def caption_for(title: str, url: str) -> str:
    return f"{title}\n\nNguồn: {url}"[:1024]


async def upload_file(
    context: ContextTypes.DEFAULT_TYPE,
    chat_id: int | str,
    file_path: Path,
    caption: str,
):
    with file_path.open("rb") as video_file:
        try:
            return await context.bot.send_video(
                chat_id=chat_id,
                video=video_file,
                caption=caption,
                supports_streaming=True,
                read_timeout=600,
                write_timeout=600,
                connect_timeout=60,
                pool_timeout=60,
            )
        except TelegramError:
            logger.warning("send_video failed; retrying as document", exc_info=True)
            video_file.seek(0)
            return await context.bot.send_document(
                chat_id=chat_id,
                document=video_file,
                caption=caption,
                read_timeout=600,
                write_timeout=600,
                connect_timeout=60,
                pool_timeout=60,
            )


async def copy_stored_video(
    context: ContextTypes.DEFAULT_TYPE,
    target_chat_id: int,
    message_id: int,
) -> None:
    await context.bot.copy_message(
        chat_id=target_chat_id,
        from_chat_id=STORAGE_CHAT_ID,
        message_id=message_id,
        read_timeout=60,
        write_timeout=60,
        connect_timeout=30,
        pool_timeout=30,
    )


async def delete_expired_messages(application: Application) -> None:
    while True:
        try:
            deletions = await asyncio.to_thread(get_due_message_deletions)
            for chat_id, message_id in deletions:
                try:
                    await application.bot.delete_message(chat_id=chat_id, message_id=message_id)
                except TelegramError:
                    logger.warning(
                        "Could not delete original message %s in chat %s; retrying in one hour",
                        message_id,
                        chat_id,
                        exc_info=True,
                    )
                    await asyncio.to_thread(retry_scheduled_deletion, chat_id, message_id)
                else:
                    await asyncio.to_thread(remove_scheduled_deletion, chat_id, message_id)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("Message deletion worker failed")

        await asyncio.sleep(60)


async def post_init(application: Application) -> None:
    if DELETE_ORIGINAL_AFTER_SECONDS > 0:
        application.bot_data["deletion_worker"] = application.create_task(
            delete_expired_messages(application),
            name="delete-expired-messages",
        )


async def post_shutdown(application: Application) -> None:
    task = application.bot_data.pop("deletion_worker", None)
    if task:
        task.cancel()
        with suppress(asyncio.CancelledError):
            await task


async def process_url(message, context: ContextTypes.DEFAULT_TYPE, url: str) -> None:
    async with DOWNLOAD_SEMAPHORE:
        status_message = await message.reply_text(f"Đang tải video:\n{url}")
        temp_dir: Path | None = None

        try:
            if STORAGE_CHAT_ID:
                cached_message_id = await asyncio.to_thread(get_cached_message_id, url)
                if cached_message_id:
                    await status_message.edit_text("Video đã có trong kho. Đang gửi lại từ Telegram...")
                    try:
                        await copy_stored_video(context, message.chat_id, cached_message_id)
                    except TelegramError:
                        logger.warning("Stored message is unavailable; downloading again", exc_info=True)
                        await asyncio.to_thread(remove_cached_message, url)
                    else:
                        await asyncio.to_thread(
                            schedule_message_deletion,
                            message.chat_id,
                            message.message_id,
                        )
                        await status_message.delete()
                        return

            DOWNLOAD_ROOT.mkdir(parents=True, exist_ok=True)
            temp_dir = Path(tempfile.mkdtemp(prefix="video-", dir=DOWNLOAD_ROOT))
            await context.bot.send_chat_action(message.chat_id, ChatAction.UPLOAD_VIDEO)
            file_path, title = await asyncio.to_thread(download_video, url, temp_dir)
            await status_message.edit_text("Đã tải xong. Đang chuẩn hóa video...")
            file_path = await asyncio.to_thread(normalize_video_aspect_ratio, file_path)
            file_size = file_path.stat().st_size

            if file_size > MAX_FILE_SIZE_BYTES:
                await status_message.edit_text(
                    "Video đã tải xong nhưng quá lớn để gửi qua cấu hình hiện tại "
                    f"({human_size(file_size)} > {MAX_FILE_SIZE_MB} MB)."
                )
                return

            await status_message.edit_text(
                f"Đã tải xong: {title}\nĐang lưu lên Telegram ({human_size(file_size)})..."
            )

            caption = caption_for(title, url)
            if STORAGE_CHAT_ID:
                stored_message = await upload_file(context, STORAGE_CHAT_ID, file_path, caption)
                await asyncio.to_thread(cache_stored_message, url, stored_message.message_id)
                await status_message.edit_text("Đã lưu vào kho Telegram. Đang gửi lại nhóm...")
                await copy_stored_video(context, message.chat_id, stored_message.message_id)
            else:
                await upload_file(context, message.chat_id, file_path, caption)

            await asyncio.to_thread(
                schedule_message_deletion,
                message.chat_id,
                message.message_id,
            )
            await status_message.delete()

        except DownloadError as exc:
            logger.exception("Download failed for %s", url)
            await safe_edit(
                status_message,
                "Không tải được link này. Có thể website cần đăng nhập, chặn bot, DRM, "
                f"hoặc link không được yt-dlp hỗ trợ.\n\nChi tiết: {str(exc)[:800]}",
            )
        except TelegramError as exc:
            logger.exception("Telegram upload failed for %s", url)
            await safe_edit(
                status_message,
                "Đã tải được video nhưng Telegram từ chối upload. Thường do file quá lớn "
                f"hoặc kết nối upload bị ngắt.\n\nChi tiết: {str(exc)[:800]}",
            )
        except Exception as exc:
            logger.exception("Unexpected failure for %s", url)
            await safe_edit(status_message, f"Lỗi ngoài dự kiến: {str(exc)[:800]}")
        finally:
            if temp_dir:
                shutil.rmtree(temp_dir, ignore_errors=True)


async def safe_edit(message, text: str) -> None:
    try:
        await message.edit_text(text)
    except TelegramError:
        logger.warning("Could not edit status message", exc_info=True)


def validate_environment() -> None:
    if not TOKEN:
        raise SystemExit("Missing TELEGRAM_BOT_TOKEN. Copy .env.example to .env and fill it in.")
    if shutil.which("ffmpeg") is None:
        raise SystemExit("ffmpeg was not found in PATH. Install ffmpeg before starting the bot.")
    if VIDEO_ASPECT_MODE not in {"source", "16:9"}:
        raise SystemExit("VIDEO_ASPECT_MODE must be either 'source' or '16:9'.")
    if DELETE_ORIGINAL_AFTER_SECONDS < 0:
        raise SystemExit("DELETE_ORIGINAL_AFTER_SECONDS cannot be negative.")
    if MAX_FILE_SIZE_MB > 50 and not TELEGRAM_API_BASE_URL:
        logger.warning(
            "MAX_FILE_SIZE_MB is above 50 but TELEGRAM_API_BASE_URL is not configured. "
            "The hosted Telegram Bot API will reject uploads above 50 MB."
        )


def main() -> None:
    validate_environment()
    initialize_storage_cache()
    try:
        asyncio.get_event_loop()
    except RuntimeError:
        asyncio.set_event_loop(asyncio.new_event_loop())

    builder = Application.builder().token(TOKEN)
    if TELEGRAM_API_BASE_URL:
        builder = builder.base_url(TELEGRAM_API_BASE_URL)
    if TELEGRAM_API_BASE_FILE_URL:
        builder = builder.base_file_url(TELEGRAM_API_BASE_FILE_URL)

    application = builder.post_init(post_init).post_shutdown(post_shutdown).build()
    application.add_handler(CommandHandler("start", start))
    application.add_handler(MessageHandler(filters.ALL, handle_message))
    logger.info("Bot is running")
    application.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == "__main__":
    main()
