import time
import os
import shlex
import asyncio
import datetime
import re
import logging
import mimetypes
import uvloop
import textwrap
from pathlib import Path
from typing import Optional, List, Dict, Tuple
from dataclasses import dataclass
from expiringdict import ExpiringDict
from hypercorn.asyncio import serve, Config

import magic
import aiosqlite
from quart import Quart, request, send_file as quart_send_file
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
    app.thumbnailing_tasks = {}
    app.expensive_thumbnail_semaphore = asyncio.Semaphore(3)
    app.image_thumbnail_semaphore = asyncio.Semaphore(10)
    app.file_cache = FileCache(
        canvas_size=ExpiringDict(max_len=10000, max_age_seconds=1200),
        file_type=ExpiringDict(max_len=10000, max_age_seconds=1200),
        mime_type=ExpiringDict(max_len=1000, max_age_seconds=300),
        local_path=ExpiringDict(max_len=1000, max_age_seconds=3600),
    )
    app.tag_cache = ExpiringDict(max_len=4000, max_age_seconds=1800)

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
    log.info("close db")
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
                "posts:favorite": "regular",
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
    print(request.args)
    query = request.args["query"]
    query = query.replace("\\:", ":")
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
        tags = await fetch_tag(tag[0])
        for tag in tags:
            rows.append(
                {
                    "version": 1,
                    "names": tag["names"],
                    "category": "default",
                    "implications": [],
                    "suggestions": [],
                    "creationTime": "1900-01-01T00:00:00Z",
                    "lastEditTime": "1900-01-01T00:00:00Z",
                    "usages": tag["usages"],
                    "description": "awooga",
                }
            )

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
    tag_regex = re.compile("[a-zA-Z-_0-9:;&\\*\(\)]+")
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

    final_query = ["select file_hash from tag_files where"]

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
                final_query.append(" core_hash = ?")
                if captured_regex_index == 4:
                    full_match = full_match[1:-1]
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


@app.get("/_awtfdb_content/<int:file_id>")
async def content(file_id: int):
    file_local_path = await fetch_file_local_path(file_id)
    if not file_local_path:
        return "", 404

    mimetype = fetch_mimetype(file_local_path)
    return await send_file(file_local_path, mimetype=mimetype)


def blocking_thumbnail_image(path, thumbnail_path, size):
    try:
        with Image.open(path) as file_as_image:
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


def blocking_thumbnail_any_text(file_path, thumbnail_path, size, text):
    thumbnail_image = Image.new("RGB", (500, 500), (255, 255, 255))

    # draw file_path's name
    draw = ImageDraw.Draw(thumbnail_image)

    offset_y = 10
    for line in textwrap.wrap(text, width=25):
        draw.text((15, offset_y), line, fill=(0, 0, 0), font=font)
        bbox = font.getbbox(line)
        offset_y = offset_y + (bbox[3] - bbox[1]) + 2

    thumbnail_image.save(thumbnail_path)


def blocking_thumbnail_filepath(file_path, thumbnail_path, size):
    blocking_thumbnail_any_text(file_path, thumbnail_path, size, Path(file_path).name)


def blocking_thumbnail_file_contents(file_path, thumbnail_path, size):
    file_path = Path(file_path)
    with file_path.open(mode="r") as fd:
        first_256_bytes = fd.read(256)

    blocking_thumbnail_any_text(file_path, thumbnail_path, size, first_256_bytes)


async def thumbnail_given_path_only_filename(
    path: Path, thumbnail_path: Path, size=(350, 350)
):
    """Fallback for mime types that only want to spit out their filename
    as a thumbnail"""
    return await app.loop.run_in_executor(
        None, blocking_thumbnail_filepath, path, thumbnail_path, size
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
    "video/x-m4v": ".m4v",
    "video/3gpp": ".3gpp",
    "application/vnd.oasis.opendocument.text": ".odt",
    "application/epub+zip": ".epub",
}


def get_extension(mimetype):
    from_mimetypes = mimetypes.guess_extension(mimetype)
    if from_mimetypes:
        return from_mimetypes

    return MIME_EXTENSION_MAPPING[mimetype]


MIME_REMAPPING = {"video/x-matroska": "video/mkv"}


def fetch_mimetype(file_path: str):
    mimetype = app.file_cache.mime_type.get(file_path)
    if not mimetype:
        mimetype = magic.from_file(file_path, mime=True)
        mimetype = MIME_REMAPPING.get(mimetype, mimetype)
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


async def submit_thumbnail(file_id, mimetype, file_local_path, thumbnail_path):
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
        thumbnailing_function = thumbnail_given_path_only_filename
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


@app.get("/_awtfdb_thumbnails/<int:file_id>")
async def thumbnail(file_id: int):
    file_local_path = await fetch_file_local_path(file_id)
    if not file_local_path:
        return "", 404

    mimetype = fetch_mimetype(file_local_path)
    extension = get_extension(mimetype)
    log.info("thumbnailing mime %s ext %r", mimetype, extension)
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


def request_fields() -> Optional[List[str]]:
    fields = request.args.get("fields")
    if not fields:
        return None
    return fields.split(",")


@app.get("/posts/")
async def posts_fetch():
    query = request.args.get("query", "")
    offset = int(request.args.get("offset", 0))
    limit = int(request.args.get("limit", 15))
    query = query.replace("\\:", ":")
    fields = request_fields()

    if "pool:" in query:
        # switch logic to fetching stuff from pool only in order lol
        _, pool_id = query.split(":")
        pool = await fetch_pool_entity(int(pool_id))
        posts = pool["posts"][offset:]
        return {
            "query": query,
            "offset": offset,
            "limit": limit,
            "total": len(posts),
            "results": posts,
        }

    result = compile_query(query)
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
    tag_rows = await app.db.execute(
        result.query + f" limit {limit} offset {offset}",
        mapped_tag_args,
    )
    total_rows_count = await app.db.execute(
        result.query,
        mapped_tag_args,
    )
    total_files = len(await total_rows_count.fetchall())

    rows_coroutines = []
    async for file_hash_row in tag_rows:
        file_hash = file_hash_row[0]
        rows_coroutines.append(fetch_file_entity(file_hash, fields=fields))
    start_ts = time.monotonic()
    rows = await asyncio.gather(*rows_coroutines)
    end_ts = time.monotonic()
    time_taken = round(end_ts - start_ts, 3)
    log.info("took %.3f seconds to fetch file metadata", time_taken)

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


async def fetch_tag(core_hash) -> list:

    tag_entry = app.tag_cache.get(core_hash)
    if tag_entry is None:
        named_tag_cursor = await app.db.execute(
            """
            select tag_text
            from tag_names
            where tag_names.core_hash = ?
            """,
            (core_hash,),
        )

        start_ts = time.monotonic()
        usages_from_metrics = await app.db.execute_fetchall(
            """
            select relationship_count
            from metrics_tag_usage_values
            where core_hash = ?
            order by timestamp desc
            limit 1
            """,
            (core_hash,),
        )
        if not usages_from_metrics:
            log.info("tag %d has no metrics, calculating manually...", core_hash)
            usages = (
                await app.db.execute_fetchall(
                    "select count(rowid) from tag_files where core_hash = ?",
                    (core_hash,),
                )
            )[0][0]
        else:
            usages = usages_from_metrics[0][0]

        tag_entry = []
        async for named_tag in named_tag_cursor:
            tag_entry.append(TagEntry(named_tag[0], usages))

    assert tag_entry is not None
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
)


async def fetch_file_entity(
    file_id: int, *, micro=False, fields: Optional[List[str]] = None
) -> dict:
    fields = fields or ALL_FILE_FIELDS
    if micro:
        fields = MICRO_FILE_FIELDS

    returned_file = {
        "version": 1,
        "id": file_id,
        "creationTime": "1900-01-01T00:00:00Z",
        "lastEditTime": "1900-01-01T00:00:00Z",
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
        "lastFeatureTime": "1900-01-01T00:00:00Z",
        "favoritedBy": [],
        "hasCustomThumbnail": True,
        "comments": [],
    }

    if "thumbnailUrl" in fields:
        returned_file["thumbnailUrl"] = f"api/_awtfdb_thumbnails/{file_id}"

    if "tags" in fields or "pools" in fields or "tagCount" in fields:
        file_tags = []
        file_tags_cursor = await app.db.execute(
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

        pool_rows = await app.db.execute_fetchall(
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
        file_local_path = (
            await app.db.execute_fetchall(
                "select local_path from files where file_hash = ?",
                (file_id,),
            )
        )[0][0]
        app.file_cache.local_path[file_id] = file_local_path

    file_mime = fetch_mimetype(file_local_path)
    returned_file["mimeType"] = file_mime

    if "type" in fields:
        file_type = app.file_cache.file_type.get(file_id)
        if not file_type:
            if file_mime.startswith("image/"):
                file_type = "image"
                if file_mime == "image/gif":
                    file_type = "animation"

            elif file_mime.startswith("video/"):
                file_type = "video"
            elif file_mime.startswith("audio/"):
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

        log.info("file %d calculate canvas size: %r", file_id, canvas_size)
        assert len(canvas_size) == 2

    log.info("file %d fetch fields %r", file_id, fields)
    return returned_file


@app.get("/post/<int:file_id>")
async def single_post_fetch(file_id: int):
    # GET /post/<id>
    return await fetch_file_entity(file_id)


@app.get("/post/<int:file_id>/around/")
async def single_post_fetch_around(file_id: int):
    fields = request_fields()
    prev_cursor = await app.db.execute(
        """
        select file_hash
        from files
        where file_hash < ?
        order by file_hash desc
        limit 1
        """,
        (file_id,),
    )
    next_cursor = await app.db.execute(
        """
        select file_hash
        from files
        where file_hash > ?
        order by file_hash asc
        limit 1
        """,
        (file_id,),
    )
    prev_value = await prev_cursor.fetchone()
    prev_id = prev_value[0] if prev_value else None
    next_value = await next_cursor.fetchone()
    next_id = next_value[0] if next_value else None
    return {
        "prev": await fetch_file_entity(prev_id, fields=fields) if prev_id else None,
        "next": await fetch_file_entity(next_id, fields=fields) if next_id else None,
    }


async def fetch_pool_entity(pool_hash: int, micro=False):
    pool_rows = await app.db.execute_fetchall(
        "select title from pools where pool_hash = ?", [pool_hash]
    )
    if not pool_rows:
        return None
    pool_title = pool_rows[0][0]
    count_rows = await app.db.execute_fetchall(
        "select count(*) from pool_entries where pool_hash = ?", [pool_hash]
    )
    post_count = int(count_rows[0][0])

    if not micro:
        post_rows = await app.db.execute_fetchall(
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
        "creationTime": "1900-01-01T00:00:00Z",
        "lastEditTime": "1900-01-01T00:00:00Z",
        "postCount": post_count,
        "description": "",
    }


@app.get("/pools/")
async def pools_fetch():
    # GET /pools/?offset=<initial-pos>&limit=<page-size>&query=<query>
    query = request.args.get("query", "")
    offset = int(request.args.get("offset", 0))
    limit = int(request.args.get("limit", 15))
    query = query.replace("\\:", ":")

    count_rows = await app.db.execute_fetchall(
        """
        select count(pool_hash)
        from pools
        where pools.title LIKE '%' || ? || '%'
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


@app.get("/pool/<int:pool_id>")
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
    uvloop.install()
    config = Config()
    config.bind = ["0.0.0.0:6666"]
    asyncio.run(serve(app, config))
