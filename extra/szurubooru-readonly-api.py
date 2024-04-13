import time
import random
import multiprocessing
import os
import shlex
import asyncio
import datetime
import re
import logging
import mimetypes
import uvloop
import textwrap
import io
from pathlib import Path
from typing import Optional, List, Dict, Tuple, Any
from dataclasses import dataclass
from expiringdict import ExpiringDict
from hypercorn.asyncio import serve, Config

import magic
import eyed3
import aiosqlite
from quart import Quart, request, send_file as quart_send_file, redirect, make_response
from quart.ctx import copy_current_app_context
from PIL import Image, ImageDraw, ImageFont, UnidentifiedImageError


log = logging.getLogger(__name__)
app = Quart(__name__)

THUMBNAIL_FOLDER = Path("/tmp") / "awtfdb-szurubooru-thumbnails"


async def send_file(path: str, *, mimetype: Optional[str] = None):
    """Helper function to send files while also supporting Ranged Requests."""
    response = await quart_send_file(path, mimetype=mimetype, conditional=True)

    filebody = response.response
    response.headers["content-length"] = filebody.end - filebody.begin
    response.headers["content-disposition"] = "inline"
    response.headers["content-security-policy"] = "sandbox; frame-src 'None'"

    return response


BASE32_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def base32_parse(string):
    lst = []
    for input_character in string:
        for index, alphabet_character in enumerate(BASE32_ALPHABET):
            if input_character == alphabet_character:
                lst.append(index)
    return lst


def get_ulid_timestamp(ulid_string: str) -> int:
    if len(ulid_string) != 26:
        raise AssertionError(f"given string {ulid_string!r} is not 26 characters")
    encoded_timestamp = ulid_string[0:10]
    decoded_timestamp = base32_parse(encoded_timestamp)
    # turn into u50
    result = 0
    for index, value in enumerate(decoded_timestamp):
        shift = 5 * (len(decoded_timestamp) - 1 - index)
        result |= value << shift
    return result / 1000


def get_ulid_datetime(ulid_string):
    return datetime.datetime.fromtimestamp(get_ulid_timestamp(ulid_string))


def test_ulid():
    ts = get_ulid_timestamp("01FW07HVW1PCGKCDPPFBFC37WA")
    assert ts is not None
    dt = datetime.datetime.fromtimestamp(ts)
    assert dt.year == 2022
    assert dt.month == 2
    assert dt.day == 16


@dataclass
class FileCache:
    canvas_size: Dict[int, Tuple[int, int]]
    file_type: Dict[int, str]
    mime_type: Dict[int, str]
    local_path: Dict[int, str]


@dataclass
class TagEntry:
    name: str
    usages: int


@app.before_serving
async def app_before_serving():
    THUMBNAIL_FOLDER.mkdir(exist_ok=True)
    app.loop = asyncio.get_running_loop()
    indexpath = Path(os.getenv("HOME")) / "awtf.db"
    app.db = await aiosqlite.connect(str(indexpath))
    app.db_query_pool = [
        await aiosqlite.connect(str(indexpath))
        for _ in range(multiprocessing.cpu_count())
    ]
    app.thumbnailing_tasks = {}
    app.expensive_thumbnail_semaphore = asyncio.Semaphore(1)
    app.image_thumbnail_semaphore = asyncio.Semaphore(7)
    app.file_cache = FileCache(
        canvas_size=ExpiringDict(max_len=10000, max_age_seconds=1200),
        file_type=ExpiringDict(max_len=10000, max_age_seconds=1200),
        mime_type=ExpiringDict(max_len=1000, max_age_seconds=300),
        local_path=ExpiringDict(max_len=1000, max_age_seconds=3600),
    )
    app.tag_cache = ExpiringDict(max_len=80000, max_age_seconds=259200)
    app.tag_usage_semaphore = asyncio.Semaphore(2)

    @copy_current_app_context
    async def thumbnail_cleaner_run():
        await thumbnail_cleaner()

    app.loop.create_task(thumbnail_cleaner())


async def thumbnail_cleaner_tick():
    log.info("cleaning thumbnails..")
    WEEK = 60 * 60 * 24 * 7
    count = 0
    for thumbnail_path in THUMBNAIL_FOLDER.glob("*"):
        stat = thumbnail_path.stat()
        delta = time.time() - stat.st_atime
        if delta > WEEK:
            thumbnail_path.unlink(missing_ok=True)
            count += 1
    if count > 0:
        log.info(f"removed {count} thumbnails")


async def thumbnail_cleaner():
    try:
        while True:
            await thumbnail_cleaner_tick()
            await asyncio.sleep(3600)
    except:
        log.exception("thumbnail cleaner task error")


@app.after_serving
async def app_after_serving():
    log.info("possibly optimizing database")
    await app.db.execute("PRAGMA analysis_limit=1000")
    await app.db.execute("PRAGMA optimize")
    log.info("close db pool")
    for conn in app.db_query_pool:
        await conn.close()
    log.info("close db main")
    await app.db.close()


@app.route("/info")
async def info():
    post_count = (await app.db.execute_fetchall("select count(*) from files"))[0][0]

    return {
        "postCount": post_count,
        "diskUsage": 0,
        "featuredPost": None,
        "featuringTime": None,
        "featuringUser": None,
        "serverTime": datetime.datetime.utcnow().isoformat() + "Z",
        "config": {
            "userNameRegex": "^[a-zA-Z0-9_-]{1,32}$",
            "passwordRegex": "^.{5,}$",
            "tagNameRegex": "^\\S+$",
            "tagCategoryNameRegex": "^[^\\s%+#/]+$",
            "defaultUserRank": "administrator",
            "enableSafety": True,
            "contactEmail": None,
            "canSendMails": False,
            "privileges": {
                "users:create:self": "anonymous",
                "users:create:any": "administrator",
                "users:list": "regular",
                "users:view": "regular",
                "users:edit:any:name": "moderator",
                "users:edit:any:pass": "moderator",
                "users:edit:any:email": "moderator",
                "users:edit:any:avatar": "moderator",
                "users:edit:any:rank": "moderator",
                "users:edit:self:name": "regular",
                "users:edit:self:pass": "regular",
                "users:edit:self:email": "regular",
                "users:edit:self:avatar": "regular",
                "users:edit:self:rank": "moderator",
                "users:delete:any": "administrator",
                "users:delete:self": "regular",
                "userTokens:list:any": "administrator",
                "userTokens:list:self": "regular",
                "userTokens:create:any": "administrator",
                "userTokens:create:self": "regular",
                "userTokens:edit:any": "administrator",
                "userTokens:edit:self": "regular",
                "userTokens:delete:any": "administrator",
                "userTokens:delete:self": "regular",
                "posts:create:anonymous": "regular",
                "posts:create:identified": "regular",
                "posts:list": "anonymous",
                "posts:reverseSearch": "regular",
                "posts:view": "anonymous",
                "posts:view:featured": "anonymous",
                "posts:edit:content": "power",
                "posts:edit:flags": "regular",
                "posts:edit:notes": "regular",
                "posts:edit:relations": "regular",
                "posts:edit:safety": "power",
                "posts:edit:source": "regular",
                "posts:edit:tags": "regular",
                "posts:edit:thumbnail": "power",
                "posts:feature": "moderator",
                "posts:delete": "moderator",
                "posts:score": "regular",
                "posts:merge": "moderator",
                "posts:favorite": "anonymous",
                "posts:bulk-edit:tags": "power",
                "posts:bulk-edit:safety": "power",
                "tags:create": "regular",
                "tags:edit:names": "power",
                "tags:edit:category": "power",
                "tags:edit:description": "power",
                "tags:edit:implications": "power",
                "tags:edit:suggestions": "power",
                "tags:list": "regular",
                "tags:view": "anonymous",
                "tags:merge": "moderator",
                "tags:delete": "moderator",
                "tagCategories:create": "moderator",
                "tagCategories:edit:name": "moderator",
                "tagCategories:edit:color": "moderator",
                "tagCategories:edit:order": "moderator",
                "tagCategories:list": "anonymous",
                "tagCategories:view": "anonymous",
                "tagCategories:delete": "moderator",
                "tagCategories:setDefault": "moderator",
                "pools:create": "regular",
                "pools:edit:names": "power",
                "pools:edit:category": "power",
                "pools:edit:description": "power",
                "pools:edit:posts": "power",
                "pools:list": "anonymous",
                "pools:view": "anonymous",
                "pools:merge": "moderator",
                "pools:delete": "moderator",
                "poolCategories:create": "moderator",
                "poolCategories:edit:name": "moderator",
                "poolCategories:edit:color": "moderator",
                "poolCategories:list": "anonymous",
                "poolCategories:view": "anonymous",
                "poolCategories:delete": "moderator",
                "poolCategories:setDefault": "moderator",
                "comments:create": "regular",
                "comments:delete:any": "moderator",
                "comments:delete:own": "regular",
                "comments:edit:any": "moderator",
                "comments:edit:own": "regular",
                "comments:list": "regular",
                "comments:view": "regular",
                "comments:score": "regular",
                "snapshots:list": "power",
                "uploads:create": "regular",
                "uploads:useDownloader": "power",
            },
        },
    }


@app.errorhandler(400)
def handle_exception(exception):
    log.exception(f"Error in request: {exception!r}")
    return "shit", 400


@app.get("/tags/")
async def tags_fetch():
    # GET /tags/?offset=<initial-pos>&limit=<page-size>&query=<query>
    query = request_query_field()
    offset = request.args.get("offset", 0)
    query = query.replace("*", "")
    query = query.replace(" sort:usages", "")
    if len(query) < 2:
        return {
            "query": query,
            "offset": offset,
            "limit": 10000,
            "total": 0,
            "results": [],
        }
    tag_rows = await app.db.execute(
        """
    select distinct core_hash core_hash, hashes.hash_data
    from tag_names
    join hashes
    on hashes.id = tag_names.core_hash
    where lower(tag_text) LIKE '%' || lower(?) || '%'
    """,
        (query,),
    )
    rows = []
    async for tag in tag_rows:
        start_ts = time.monotonic()
        tag_timestamp = get_ulid_datetime(tag[0])
        tags = await fetch_tag(tag[0])
        for tag in tags:
            rows.append(
                {
                    "version": 1,
                    "names": tag["names"],
                    "category": "default",
                    "implications": [],
                    "suggestions": [],
                    "creationTime": tag_timestamp.isoformat(),
                    "lastEditTime": tag_timestamp.isoformat(),
                    "usages": tag["usages"],
                    "description": "awooga",
                }
            )
        end_ts = time.monotonic()
        log.info("tag process %.2f msec", round((end_ts - start_ts) * 1000, 5))

    rows = sorted(rows, key=lambda r: r["usages"], reverse=True)

    return {
        "query": query,
        "offset": offset,
        "limit": 10000,
        "total": len(rows),
        "results": rows,
    }


@dataclass
class CompiledSearch:
    query: str
    tags: List[str]


def compile_query(search_query: str) -> CompiledSearch:
    forced_query = os.environ.get("AWTFDB_FORCED_QUERY")
    if forced_query:
        if not search_query:
            search_query = forced_query
        else:
            search_query = f"{forced_query} {search_query}"
    or_operator = re.compile("( +)?\\|( +)?")
    not_operator = re.compile("( +)?-( +)?")
    and_operator = re.compile(" +")
    tag_regex = re.compile("[a-zA-Z-_0-9:;&\\*\(\)!]+")
    raw_tag_regex = re.compile('".*?"')

    regexes = (
        or_operator,
        not_operator,
        and_operator,
        tag_regex,
        raw_tag_regex,
    )

    if not search_query:
        return CompiledSearch("select distinct file_hash from tag_files", [])

    final_query = ["select distinct file_hash from tag_files where"]

    index = 0
    captured_regex_index = None
    tags = []

    while True:
        compiling_search_query = search_query[index:]
        if not compiling_search_query:
            break

        maybe_capture = None
        for regex_index, regex in enumerate(regexes):
            maybe_capture = regex.search(compiling_search_query)
            if maybe_capture and maybe_capture.start() == 0:
                captured_regex_index = regex_index
                break

        if maybe_capture:
            full_match = maybe_capture[0]
            index += maybe_capture.end()
            assert captured_regex_index is not None
            if captured_regex_index == 0:
                final_query.append(" or")
            if captured_regex_index == 1:
                if not tags:
                    final_query.append(" true")
                final_query.append(" except")
                final_query.append(" select file_hash from tag_files where")
            if captured_regex_index == 2:
                final_query.append(" intersect")
                final_query.append(" select file_hash from tag_files where")
            if captured_regex_index in (3, 4):
                if captured_regex_index == 4:
                    full_match = full_match[1:-1]
                if full_match.startswith("system:low_tags:"):
                    _, _, tag_limit = full_match.split(":")
                    tag_limit = int(tag_limit)
                    final_query.append(
                        f" (select count(*) from tag_files tf2 where tf2.file_hash = tag_files.file_hash) < {tag_limit}"
                    )
                elif full_match.startswith("system:random"):
                    final_query.append(
                        " core_hash = (select core_hash from tag_names order by random() limit 1)"
                    )
                else:
                    final_query.append(" core_hash = ?")
                    tags.append(full_match)

        else:
            raise Exception(f"Invalid search query. Unexpected character at {index}")
    return CompiledSearch("".join(final_query), tags)


def test_compiler():
    assert compile_query("a b c d") is not None
    assert compile_query("a d_(test)") is not None
    result = compile_query('a b | "cd"|e')
    assert (
        result.query
        == "select file_hash from tag_files where core_hash = ? intersect select file_hash from tag_files where core_hash = ? or core_hash = ? or core_hash = ?"
    )
    assert result.tags == ["a", "b", "cd", "e"]


def test_compiler_batch():
    test_data = (
        ("a b c", ("a", "b", "c")),
        ("a bc d", ("a", "bc", "d")),
        ('a "bc" d', ("a", "bc", "d")),
        ('a "b c" d', ("a", "b c", "d")),
        ('a "b c" -d', ("a", "b c", "d")),
        ('-a "b c" d', ("a", "b c", "d")),
        ('-a -"b c" -d', ("a", "b c", "d")),
        ("-d", ("d",)),
    )

    for query, expected_tags_array in test_data:
        result = compile_query(query)
        assert result.tags == list(expected_tags_array)


def test_compiler_errors():
    import pytest

    with pytest.raises(Exception):
        compile_query('a "cd')


async def fetch_file_local_path(file_id: int) -> Optional[str]:
    cached_path = app.file_cache.local_path.get(file_id)
    if cached_path:
        return cached_path

    file_local_path_result = await app.db.execute_fetchall(
        "select local_path from files where file_hash = ?",
        (file_id,),
    )

    if not file_local_path_result:
        return None

    path = file_local_path_result[0][0]
    app.file_cache.local_path[file_id] = path
    return path


async def transcode_path(file_id, local_path, mimetype):
    extension = get_extension(mimetype.transcode_to)
    transcodes_folder = Path("/tmp") / "awtfdb-transcodes"
    transcodes_folder.mkdir(exist_ok=True)
    target_path = transcodes_folder / f"{file_id}{extension}"

    if not target_path.exists():
        cmdline = f"ffmpeg -y -i {shlex.quote(local_path)} -movflags +empty_moov -movflags +frag_keyframe -c:v copy {shlex.quote(str(target_path))}"
        log.info("transcoding with cmdline %r", cmdline)
        process = await asyncio.create_subprocess_shell(
            cmdline,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        out, err = await process.communicate()
        out, err = out.decode(), err.decode()
        log.info("out: %s, err: %s", out, err)
        if process.returncode != 0:
            log.warn(
                "ffmpeg (thumbnailer) returned non-zero exit code %d",
                process.returncode,
            )
            raise RuntimeError("ffmpeg failed")

    return target_path


@app.get("/_awtfdb_content/<file_id>")
async def content(file_id: str):
    file_local_path = await fetch_file_local_path(file_id)
    if not file_local_path:
        return "", 404

    mimetype = fetch_mimetype(file_local_path)

    if mimetype.transcode_to:
        log.info("requested transcode %r", mimetype)
        request.timeout = None
        target_path = await transcode_path(file_id, file_local_path, mimetype)
        log.info("sending %s", target_path)
        return await send_file(target_path, mimetype=mimetype.target)
    else:
        nginx_host = os.environ.get("NGINX")
        if nginx_host:
            return redirect(f"http://{nginx_host}/{file_local_path}")
        else:
            return await send_file(file_local_path, mimetype=mimetype.target)


def blocking_thumbnail_image(path, thumbnail_path, size):
    try:
        with Image.open(path) as file_as_image:
            file_as_image = file_as_image.convert("RGB")
            file_as_image.thumbnail(size)
            file_as_image.save(thumbnail_path)
    except UnidentifiedImageError:
        log.exception("failed to make thumbnail")
        return False


async def thumbnail_given_path(path: Path, thumbnail_path: Path, size=(350, 350)):
    return await app.loop.run_in_executor(
        None, blocking_thumbnail_image, path, thumbnail_path, size
    )


font = ImageFont.truetype("Arial", size=35)


def draw_text_on_image(
    draw,
    text: str,
    *,
    offset_y: int = 120,
    border_color: Tuple[int, int, int] = (0, 0, 0),
    text_color: Tuple[int] = (255, 255, 255),
):
    for line in textwrap.wrap(text, width=25):
        x, y = 15, offset_y

        draw.text((x - 1, y - 1), line, font=font, fill=border_color)
        draw.text((x + 1, y - 1), line, font=font, fill=border_color)
        draw.text((x - 1, y + 1), line, font=font, fill=border_color)
        draw.text((x + 1, y + 1), line, font=font, fill=border_color)

        draw.text((x, y), line, fill=text_color, font=font)
        bbox = font.getbbox(line)
        offset_y = offset_y + (bbox[3] - bbox[1]) + 2


def blocking_thumbnail_any_text(file_path, thumbnail_path, size, text):
    thumbnail_image = Image.new("RGB", (500, 500), (255, 255, 255))

    # draw file_path's name
    draw = ImageDraw.Draw(thumbnail_image)
    draw_text_on_image(draw, text)

    thumbnail_image.save(thumbnail_path)


def blocking_thumbnail_filepath(file_path, thumbnail_path, size):
    blocking_thumbnail_any_text(file_path, thumbnail_path, size, Path(file_path).name)


def blocking_thumbnail_file_contents(file_path, thumbnail_path, size):
    file_path = Path(file_path)
    with file_path.open(mode="r") as fd:
        first_256_bytes = fd.read(256)

    blocking_thumbnail_any_text(file_path, thumbnail_path, size, first_256_bytes)


def blocking_thumbnail_audio(file_path, thumbnail_path, size):
    audio_file = eyed3.load(file_path)
    thumbnail_image = Image.new("RGB", size, (255, 255, 255))
    draw = ImageDraw.Draw(thumbnail_image)
    text_offset = 50
    if audio_file and audio_file.tag:
        text_offset = 230
        for audio_image_bytes in audio_file.tag.images:
            audio_image = Image.open(io.BytesIO(audio_image_bytes.image_data))
            resized_audio_image = audio_image.resize(size)
            # slap it on top of thumbnail_image
            thumbnail_image.paste(resized_audio_image)
            break
    draw_text_on_image(draw, Path(file_path).name, offset_y=text_offset)
    thumbnail_image.save(thumbnail_path)


async def thumbnail_given_path_only_filename(
    path: Path, thumbnail_path: Path, size=(350, 350)
):
    """Fallback for mime types that only want to spit out their filename
    as a thumbnail"""
    return await app.loop.run_in_executor(
        None, blocking_thumbnail_filepath, path, thumbnail_path, size
    )


async def thumbnail_given_audio(path: Path, thumbnail_path: Path, size=(350, 350)):
    return await app.loop.run_in_executor(
        None, blocking_thumbnail_audio, path, thumbnail_path, size
    )


async def thumbnail_given_path_file_contents(
    path: Path, thumbnail_path: Path, size=(350, 350)
):
    """Fallback for mime types that only want to spit out their filename
    as a thumbnail"""
    return await app.loop.run_in_executor(
        None, blocking_thumbnail_file_contents, path, thumbnail_path, size
    )


MIME_EXTENSION_MAPPING = {
    "video/x-matroska": ".mkv",
    "video/mkv": ".mkv",
    "audio/x-m4a": ".m4a",
    "audio/ogg": ".ogg",
    "video/x-m4v": ".m4v",
    "video/3gpp": ".3gpp",
    "application/vnd.oasis.opendocument.text": ".odt",
    "application/epub+zip": ".epub",
    "image/webp": ".webp",
}


def get_extension(mimetype):
    from_mimetypes = mimetypes.guess_extension(mimetype)
    if from_mimetypes:
        return from_mimetypes

    return MIME_EXTENSION_MAPPING[mimetype]


TRANSCODE = {"video/x-matroska": "video/mp4"}
MIME_OPTIMIZATION = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".mp4": "video/mp4",
    ".gif": "image/gif",
    ".webp": "image/webp",
}


@dataclass
class Mimetype:
    raw: str
    transcode_to: Optional[str] = None

    @property
    def target(self):
        return self.transcode_to or self.raw


def fetch_mimetype(file_path: str):
    mimetype = app.file_cache.mime_type.get(file_path)
    if not mimetype:
        path = Path(file_path)
        if path.suffix in MIME_OPTIMIZATION:
            mimetype = Mimetype(MIME_OPTIMIZATION[path.suffix])
        else:
            mimetype = Mimetype(magic.from_file(file_path, mime=True))

        mimetype.transcode_to = TRANSCODE.get(mimetype.raw)
        app.file_cache.mime_type[file_path] = mimetype
    return mimetype


async def thumbnail_given_video(file_local_path, thumbnail_path):
    proc = await asyncio.create_subprocess_shell(
        "ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1"
        f" {shlex.quote(file_local_path)}",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    out, err = await proc.communicate()
    out, err = out.strip().decode(), err.decode()
    log.info("out: %r, err: %r", out, err)
    if proc.returncode != 0:
        log.warn(
            "ffmpeg (time calculator) returned non-zero exit code %d", proc.returncode
        )
        return False

    total_seconds = int(float(out))
    total_5percent_seconds = total_seconds // 15

    proc = await asyncio.create_subprocess_shell(
        f"ffmpeg -n -ss {total_5percent_seconds} "
        f"-i {shlex.quote(file_local_path)} "
        f"-frames:v 1 "
        f"{shlex.quote(str(thumbnail_path))}",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    out, err = await proc.communicate()
    out, err = out.decode(), err.decode()
    log.info("out: %r, err: %r", out, err)
    if proc.returncode != 0:
        log.warn("ffmpeg (thumbnailer) returned non-zero exit code %d", proc.returncode)
        return False

    return await thumbnail_given_path(str(thumbnail_path), str(thumbnail_path))


async def thumbnail_given_pdf(file_local_path, thumbnail_path):
    proc = await asyncio.create_subprocess_shell(
        f"convert -cache 20 {shlex.quote(file_local_path)}[0] -density 900 {shlex.quote(str(thumbnail_path))}",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    out, err = await proc.communicate()
    out, err = out.decode(), err.decode()
    log.info("out: %r, err: %r", out, err)
    assert proc.returncode == 0

    return await thumbnail_given_path(
        str(thumbnail_path), str(thumbnail_path), (600, 600)
    )


async def _thumbnail_wrapper(semaphore, function, local_path, thumb_path):
    async with semaphore:
        return await function(local_path, thumb_path)


async def submit_thumbnail(file_id, mimetype_packed, file_local_path, thumbnail_path):
    mimetype = mimetype_packed.target
    if mimetype.startswith("image/"):
        thumbnailing_function = thumbnail_given_path
        semaphore = app.image_thumbnail_semaphore
    elif mimetype == ("application/pdf"):
        thumbnail_path = thumbnail_path.parent / f"{file_id}.png"
        semaphore = app.expensive_thumbnail_semaphore
        thumbnailing_function = thumbnail_given_pdf
    elif mimetype.startswith("video/"):
        thumbnail_path = thumbnail_path.parent / f"{file_id}.png"
        thumbnailing_function = thumbnail_given_video
        semaphore = app.expensive_thumbnail_semaphore
    elif mimetype.startswith("audio/"):
        thumbnail_path = thumbnail_path.parent / f"{file_id}.png"
        thumbnailing_function = thumbnail_given_audio
        semaphore = app.image_thumbnail_semaphore
    elif mimetype.startswith("text/"):
        thumbnail_path = thumbnail_path.parent / f"{file_id}.png"
        thumbnailing_function = thumbnail_given_path_file_contents
        semaphore = app.image_thumbnail_semaphore
    else:
        return None

    if thumbnail_path.exists():
        return thumbnail_path

    task = app.thumbnailing_tasks.get(file_id)
    if not task:
        coro = _thumbnail_wrapper(
            semaphore, thumbnailing_function, file_local_path, thumbnail_path
        )
        task = app.loop.create_task(coro)
        app.thumbnailing_tasks[file_id] = task

    await asyncio.gather(task)
    result = task.result()
    if result is False:
        return None
    try:
        app.thumbnailing_tasks.pop(file_id)
    except KeyError:
        pass
    return thumbnail_path


@app.get("/_awtfdb_thumbnails/<file_id>")
async def thumbnail(file_id: int):
    file_local_path = await fetch_file_local_path(file_id)
    if not file_local_path:
        return "", 404

    mimetype = fetch_mimetype(file_local_path)
    extension = get_extension(mimetype.target)
    log.info("thumbnailing mime %s ext %r", mimetype.target, extension)
    assert extension is not None

    thumbnail_path = THUMBNAIL_FOLDER / f"{file_id}{extension}"
    thumbnail_path = await submit_thumbnail(
        file_id, mimetype, file_local_path, thumbnail_path
    )
    if thumbnail_path:
        return await send_file(thumbnail_path)
    else:
        log.warning("cant thumbnail %s", mimetype)
        return "", 500


def request_wanted_fields() -> Optional[List[str]]:
    fields = request.args.get("fields")
    if not fields:
        return None
    return fields.split(",")


def request_query_field():
    return request.args.get("query", "").strip().replace("\\:", ":").replace("\\!", "!")


class Timer:
    """Context manager to measure how long the indented block takes to run."""

    def __init__(self):
        self.start = None
        self.end = None

    def __enter__(self):
        self.start = time.perf_counter()
        return self

    async def __aenter__(self):
        return self.__enter__()

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.end = time.perf_counter()

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        return self.__exit__(exc_type, exc_val, exc_tb)

    def __str__(self):
        return f"{self.duration:.3f}ms"

    @property
    def duration(self):
        """Duration in ms."""
        return (self.end - self.start) * 1000


async def compile_and_execute_query(
    query: str, *, limit: Optional[int], offset: Optional[int]
):
    with Timer() as querytimer:
        result = compile_query(query)
    log.info("compiled query %r in %s", result, querytimer)
    mapped_tag_args = []
    for tag_name in result.tags:
        tag_name_cursor = await app.db.execute(
            """
        select hashes.id
        from tag_names
        join hashes
        on hashes.id = tag_names.core_hash
        where tag_text = ?
        """,
            (tag_name,),
        )

        tag_name_id = await tag_name_cursor.fetchone()
        if tag_name_id is None:
            raise Exception(f"tag not found {tag_name!r}")

        mapped_tag_args.append(tag_name_id[0])

    log.debug("query: %r", result.query)
    log.debug("tags: %r", result.tags)
    log.debug("mapped: %r", mapped_tag_args)
    with Timer() as main_exectimer:
        if limit is not None and offset is not None:
            limit_and_offset = f"limit {limit} offset {offset}"
        else:
            log.warning("running %r without limit and offset!", result.query)
            limit_and_offset = ""
        tag_rows = await app.db.execute(
            result.query + f" order by file_hash desc {limit_and_offset}",
            mapped_tag_args,
        )

    log.info("exec main query in %s", main_exectimer)
    return result, mapped_tag_args, tag_rows


@app.get("/posts/")
async def posts_fetch():
    query = request_query_field()
    fields = request_wanted_fields()
    offset = int(request.args.get("offset", 0))
    limit = int(request.args.get("limit", 15))

    if query.startswith("pool:"):
        # switch logic to fetching stuff from pool only in order lol
        _, pool_id = query.split(":")
        pool = await fetch_pool_entity(pool_id)
        posts = pool["posts"][offset : offset + limit]
        return {
            "query": query,
            "offset": offset,
            "limit": limit,
            "total": len(pool["posts"]),
            "results": posts,
        }

    result, mapped_tag_args, tag_rows = await compile_and_execute_query(
        query, limit=limit, offset=offset
    )

    with Timer() as main_counttimer:
        total_rows_count = await app.db.execute(
            f"select count(*) from ({result.query})",
            mapped_tag_args,
        )
        row = await total_rows_count.fetchone()
        total_files = row[0]
    log.info("count query in %s", main_counttimer)

    rows_coroutines = []
    async for file_hash_row in tag_rows:
        file_hash = file_hash_row[0]
        log.debug("spawn task for %r", file_hash)
        rows_coroutines.append(
            fetch_file_entity(file_hash, fields=fields, from_file_listing=True)
        )
    log.debug("wait for %d tasks", len(rows_coroutines))
    with Timer() as gather_timer:
        rows = await asyncio.gather(*rows_coroutines)
    log.info("took %s to fetch file metadata", gather_timer)

    return {
        "query": query,
        "offset": offset,
        "limit": limit,
        "total": total_files,
        "results": rows,
    }


def extract_canvas_size(path: Path) -> tuple:
    try:
        with Image.open(path) as im:
            return im.width, im.height
    except UnidentifiedImageError:
        log.exception("failed to extract dimensions")
        return (None, None)


async def calculate_usages_manually(core_hash):
    async with app.tag_usage_semaphore:
        try:
            usages = (
                await app.db.execute_fetchall(
                    "select count(core_hash) from tag_files where core_hash = ?",
                    (core_hash,),
                )
            )[0][0]
            log.info("tag %s has %d posts!", core_hash, usages)

            # replace usages in tag cache
            tag_entries = app.tag_cache[core_hash]
            for entry in tag_entries:
                entry.usages = usages
        except Exception as e:
            log.exception("failed to calculate usages")
            raise e


async def fetch_tag(core_hash) -> list:
    tag_entry = app.tag_cache.get(core_hash)
    if tag_entry is None:
        named_tag_cursor = await query_db().execute(
            """
            select tag_text
            from tag_names
            where tag_names.core_hash = ?
            """,
            (core_hash,),
        )

        start_ts = time.monotonic()
        usages_from_metrics = await query_db().execute_fetchall(
            """
            select relationship_count
            from metrics_tag_usage_values
            where core_hash = ?
            order by timestamp desc
            limit 1
            """,
            (core_hash,),
        )
        end_ts = time.monotonic()
        log.info(
            "took %.2f msec fetching tag usage", round((end_ts - start_ts) * 1000, 3)
        )

        if usages_from_metrics:
            usages = usages_from_metrics[0][0]
        else:
            # we do know its at least 1 lol
            usages = 1

        tag_entry = []
        start_ts = time.monotonic()
        async for named_tag in named_tag_cursor:
            tag_entry.append(TagEntry(named_tag[0], usages))
        end_ts = time.monotonic()
        log.info(
            "took %.2f msec fetching tag names", round((end_ts - start_ts) * 1000, 3)
        )

        app.tag_cache[core_hash] = tag_entry

    tags_result = []

    for named_tag in tag_entry:
        tags_result.append(
            {
                "names": [named_tag.name],
                "category": "default",
                "usages": named_tag.usages,
            }
        )

    return tags_result


MICRO_FILE_FIELDS = ("id", "thumbnailUrl")
ALL_FILE_FIELDS = (
    "id",
    "thumbnailUrl",
    "tags",
    "pools",
    "tagCount",
    "type",
    "canvasHeight",
    "canvasWidth",
    "fileSize",
)


def query_db():
    return random.choice(app.db_query_pool)


async def fetch_file_entity(
    file_id: str,
    *,
    micro=False,
    fields: Optional[List[str]] = None,
    from_file_listing: bool = False,
) -> Optional[dict]:
    fields = fields or ALL_FILE_FIELDS
    if micro:
        fields = MICRO_FILE_FIELDS

    file_timestamp = get_ulid_datetime(file_id)

    returned_file = {
        "version": 1,
        "id": file_id,
        "creationTime": file_timestamp.isoformat(),
        "lastEditTime": file_timestamp.isoformat(),
        "lastFeatureTime": file_timestamp.isoformat(),
        "safety": "safe",
        "source": None,
        "checksum": "test",
        "checksumMD5": "test",
        "contentUrl": f"api/_awtfdb_content/{file_id}",
        "thumbnailUrl": f"api/_awtfdb_thumbnails/{file_id}",
        "flags": ["loop"],
        "relations": [],
        "notes": [],
        "user": {"name": "root", "avatarUrl": None},
        "score": 0,
        "ownScore": 0,
        "ownFavorite": False,
        "favoriteCount": 0,
        "commentCount": 0,
        "noteCount": 0,
        "featureCount": 0,
        "relationCount": 0,
        "favoritedBy": [],
        "hasCustomThumbnail": True,
        "comments": [],
    }

    if "thumbnailUrl" in fields:
        returned_file["thumbnailUrl"] = f"api/_awtfdb_thumbnails/{file_id}"

    if "tags" in fields or "pools" in fields or "tagCount" in fields:
        file_tags = []
        if from_file_listing:
            # usage 1 for everything

            file_tags_cursor = await query_db().execute(
                """
                select tn.tag_text 
                from tag_files
                join tag_names tn 
                on tn.core_hash = tag_files.core_hash 
                where file_hash = ?;
                """,
                (file_id,),
            )

            tags_coroutines = []
            async for row in file_tags_cursor:
                file_tags.append(
                    {
                        "names": [row[0]],
                        "category": "default",
                        "usages": 1,
                    }
                )
        else:
            file_tags_cursor = await query_db().execute(
                "select core_hash from tag_files where file_hash = ?",
                (file_id,),
            )

            tags_coroutines = []
            async for row in file_tags_cursor:
                tags_coroutines.append(fetch_tag(row[0]))
            tags_results = await asyncio.gather(*tags_coroutines)
            for tag_result in tags_results:
                file_tags.extend(tag_result)

        # sort tags by name instead of by hash
        returned_file["tags"] = sorted(file_tags, key=lambda t: t["names"][0])

        favorite_tag = os.environ.get("FAVORITE_TAG")
        if favorite_tag is not None:
            if favorite_tag in [t["names"][0] for t in returned_file["tags"]]:
                returned_file["ownFavorite"] = True
                returned_file["favoriteCount"] = 1

        pool_rows = await query_db().execute_fetchall(
            "select pool_hash from pool_entries where file_hash = ?",
            [file_id],
        )
        pool_coroutines = [fetch_pool_entity(row[0], micro=True) for row in pool_rows]
        pools = await asyncio.gather(*pool_coroutines)

        returned_file["tags"].extend(
            [
                {
                    "category": "default",
                    "names": [f'pool:{pool["id"]}'],
                    "usages": pool["postCount"],
                }
                for pool in pools
            ]
        )

        returned_file["pools"] = pools
        returned_file["tagCount"] = len(file_tags)

    file_local_path = app.file_cache.local_path.get(file_id)
    if file_local_path is None:
        rows = await query_db().execute_fetchall(
            "select local_path from files where file_hash = ?",
            (file_id,),
        )
        if rows:
            file_local_path = rows[0][0]
        else:
            log.warning("failed to fetch file id %r", file_id)
            file_local_path = None
        app.file_cache.local_path[file_id] = file_local_path
    if not file_local_path:
        return None

    file_mime = fetch_mimetype(file_local_path)
    returned_file["mimeType"] = file_mime.target

    if "type" in fields:
        file_type = app.file_cache.file_type.get(file_id)
        if not file_type:
            if file_mime.raw.startswith("image/"):
                file_type = "image"
                if file_mime.raw == "image/gif":
                    file_type = "animation"

            elif file_mime.raw.startswith("video/"):
                file_type = "video"
            elif file_mime.raw.startswith("audio/"):
                file_type = "audio"
            else:
                file_type = "image"
        app.file_cache.file_type[file_id] = file_type
        assert file_type in ("image", "animation", "video", "flash", "audio")
        returned_file["type"] = file_type

    if "canvasHeight" in fields or "canvasWidth" in fields:
        canvas_size = app.file_cache.canvas_size.get(file_id)

        if not canvas_size:
            assert "type" in fields
            if file_type in ("image", "animation"):
                canvas_size = await app.loop.run_in_executor(
                    None, extract_canvas_size, file_local_path
                )
            elif file_type == "video":
                proc = await asyncio.create_subprocess_shell(
                    " ".join(
                        [
                            "ffprobe",
                            "-v",
                            "error",
                            "-select_streams",
                            "v:0",
                            "-show_entries",
                            "stream=width,height",
                            "-of",
                            "csv=s=x:p=0",
                            shlex.quote(file_local_path),
                        ]
                    ),
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                out, err = await proc.communicate()
                assert proc.returncode == 0
                out, err = out.decode().strip(), err.decode()
                log.info("out: %r, err: %r", out, err)
                canvas_size = out.split("x")
                if not out:
                    canvas_size = (None, None)
            elif file_type in ("audio", None):
                canvas_size = (None, None)
        app.file_cache.canvas_size[file_id] = canvas_size
        returned_file["canvasWidth"] = int(canvas_size[0]) if canvas_size[0] else None
        returned_file["canvasHeight"] = int(canvas_size[1]) if canvas_size[1] else None

        log.info("file %s calculate canvas size: %r", file_id, canvas_size)
        assert len(canvas_size) == 2

    if "fileSize" in fields:
        returned_file["fileSize"] = Path(file_local_path).stat().st_size

    log.info("file %s fetch fields %r", file_id, fields)
    return returned_file


@app.get("/post/<file_id>")
async def single_post_fetch(file_id: int):
    # GET /post/<id>
    return await fetch_file_entity(file_id)


async def _fetch_around_file(
    file_id: str, mode="next", exclude: Optional[list] = None
) -> Optional[str]:
    assert mode in ("next", "previous")
    comparator = "<" if mode == "previous" else ">"
    selector = "desc" if mode == "previous" else "asc"

    # optimization: if not exclude, 'limit 1' is wanted
    limit = "limit 1" if not exclude else ""
    cursor = await app.db.execute(
        f"""
        select file_hash
        from files
        where file_hash {comparator} ?
        order by file_hash {selector}
        {limit}
        """,
        (file_id,),
    )
    log.info("exclude %r", exclude)
    if not exclude:
        row = await cursor.fetchone()
        return row[0] if row else None
    else:
        wanted_file_id = None
        async for row in cursor:
            if row[0] not in exclude:
                wanted_file_id = row[0]
                break
        return wanted_file_id


def list_get(lst: List[Any], index: int) -> Optional[Any]:
    if index < 0:
        return None
    return lst[index] if index < len(lst) else None


@app.get("/post/<file_id>/around/")
async def single_post_fetch_around(file_id: str):
    fields = request_wanted_fields()
    query = request_query_field()

    prev_file_id, next_file_id = None, None

    query_posts = None
    query_ids = None

    # fast path for pools

    if query.startswith("pool:"):
        # operate in the context of a pool, as in, next will be next page in
        # the pool, next on the last page will operate as usual, as well as
        # previous

        _, pool_id = query.split(":")
        pool = await fetch_pool_entity(pool_id)
        query_posts = pool["posts"]
        query_ids = [f["id"] for f in posts]

    else:
        # run query normally and find out what next/prev are from the returned rows
        _, _, tag_rows = await compile_and_execute_query(query, limit=None, offset=None)
        query_ids = [row[0] async for row in tag_rows]

    if query_ids:
        try:
            current_file_id_index = query_ids.index(file_id)
        except ValueError:
            current_file_id_index = None

        if current_file_id_index is not None:
            prev_file_id = list_get(query_ids, current_file_id_index - 1)
            next_file_id = list_get(query_ids, current_file_id_index + 1)

    if prev_file_id is None:
        # fallback to normal db order if no prev is fetched (e.g start of a pool)
        # also prevent from entering a black hole where once in a pool
        # you cant ever get out of it if files of it arent orderedd correctly
        # (the whole point of fixing this UX in the first place)
        prev_file_id = await _fetch_around_file(
            file_id, mode="previous", exclude=query_ids
        )

    # same logic for next_file
    if next_file_id is None:
        next_file_id = await _fetch_around_file(file_id, mode="next", exclude=query_ids)

    # fast path for pools (we already have the entire file entity in the returned pool)

    prev_file = await maybe_fast_resolve_file(query_posts, prev_file_id, fields=fields)
    next_file = await maybe_fast_resolve_file(query_posts, next_file_id, fields=fields)

    return {
        "prev": prev_file,
        "next": next_file,
    }


async def maybe_fast_resolve_file(
    posts_mapping: Optional[Dict[str, dict]],
    file_id: Optional[str],
    *,
    fields: List[str],
) -> Optional[dict]:
    if not file_id:
        return None

    if posts_mapping and file_id in posts_mapping:
        return posts_mapping[file_id]

    return await fetch_file_entity(file_id, fields=fields)


async def fetch_pool_entity(pool_hash: str, micro=False):
    pool_timestamp = get_ulid_datetime(pool_hash)
    pool_rows = await query_db().execute_fetchall(
        "select title from pools where pool_hash = ?", [pool_hash]
    )
    if not pool_rows:
        return None
    pool_title = pool_rows[0][0]
    count_rows = await query_db().execute_fetchall(
        "select count(*) from pool_entries where pool_hash = ?", [pool_hash]
    )
    post_count = int(count_rows[0][0])

    if not micro:
        post_rows = await query_db().execute_fetchall(
            "select file_hash from pool_entries where pool_hash = ? order by entry_index asc",
            [pool_hash],
        )
        pool_posts_coroutines = [
            fetch_file_entity(row[0], micro=True) for row in post_rows
        ]
        pool_posts = await asyncio.gather(*pool_posts_coroutines)
    else:
        pool_posts = []

    return {
        "version": 1,
        "id": pool_hash,
        "names": [pool_title],
        "category": "default",
        "posts": pool_posts,
        "creationTime": pool_timestamp.isoformat(),
        "lastEditTime": pool_timestamp.isoformat(),
        "postCount": post_count,
        "description": "",
    }


@app.get("/pools/")
async def pools_fetch():
    # GET /pools/?offset=<initial-pos>&limit=<page-size>&query=<query>
    query = request_query_field().split(" ")[0].replace("*", "%").lower()
    offset = int(request.args.get("offset", 0))
    limit = int(request.args.get("limit", 15))
    query = query.replace("\\:", ":")
    print(query)

    count_rows = await app.db.execute_fetchall(
        """
        select count(pool_hash)
        from pools
        where lower(pools.title) LIKE '%' || ? || '%'
        """,
        [query],
    )
    result_rows = await app.db.execute_fetchall(
        f"""
    select pool_hash
    from pools
    where pools.title LIKE '%' || ? || '%'
    limit {limit}
    offset {offset}
    """,
        [query],
    )

    pools = [await fetch_pool_entity(row[0]) for row in result_rows]
    assert all(p is not None for p in pools)

    return {
        "query": query,
        "offset": offset,
        "limit": limit,
        "total": count_rows[0][0],
        "results": pools,
    }


@app.get("/pool/<pool_id>")
async def single_pool_fetch(pool_id: int):
    return await fetch_pool_entity(pool_id)


@app.route("/tag-categories")
async def tag_categories():
    return {
        "results": [
            {
                "name": "default",
                "version": 1,
                "color": "default",
                "usages": 0,
                "default": True,
                "order": 1,
            }
        ],
    }


@app.route("/pool-categories")
async def pool_categories():
    return {
        "results": [
            {
                "name": "default",
                "version": 1,
                "color": "default",
                "usages": 0,
                "default": True,
            }
        ],
    }


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.DEBUG if os.environ.get("DEBUG") else logging.INFO
    )
    if os.environ.get("EZDEBUG"):
        log.setLevel(logging.DEBUG)
    uvloop.install()
    config = Config()
    config.accesslog = "-"
    config.bind = ["0.0.0.0:6666"]
    asyncio.run(serve(app, config))
