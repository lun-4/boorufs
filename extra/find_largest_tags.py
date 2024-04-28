#!/usr/bin/env python3


import time
import os
import sys
import sqlite3
from pathlib import Path
from typing import Dict, List, Set


def main():
    try:
        limit = int(sys.argv[1])
    except IndexError:
        limit = 50

    print("limit", limit, file=sys.stderr)

    path = Path.home() / "awtf.db"
    db = sqlite3.connect(f"file:{str(path)}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row

    cur = db.cursor()

    res = cur.execute(
        """
        select file_hash, local_path
        from files
        """
    )
    filemap: Dict[str, List[str]] = {}
    tagmap: Dict[str, Set[str]] = {}

    stat_map: Dict[str, int] = {}
    start_ts = time.monotonic()
    for row in res:
        file_hash, local_path = row["file_hash"], row["local_path"]
        if local_path not in stat_map:
            stat_map[local_path] = Path(local_path).stat().st_size
        # fetch tags
        tcur = db.cursor()
        tcur.execute(
            """
            select hashes.id as core_hash
            from tag_files
            join hashes
            	on tag_files.core_hash = hashes.id
            where tag_files.file_hash = ?
            """,
            (file_hash,),
        )

        for row in tcur:
            if row["core_hash"] not in tagmap:
                tagmap[row["core_hash"]] = {local_path}
            else:
                tagmap[row["core_hash"]].add(local_path)
    end_ts = time.monotonic()
    time_taken = round(end_ts - start_ts, 2)
    print("took", time_taken, "seconds to fetch all files and stats", file=sys.stderr)

    sort_by_count_with_min_gb = os.environ.get("SORT_BY_COUNT_WITH_MIN_GB")

    def _sort_by_total_size(core_hash: str) -> int:
        return sum(stat_map[p] for p in tagmap[core_hash])

    def _sort_by_count(core_hash: str) -> int:
        return len(tagmap[core_hash])

    keys = tagmap.keys()

    if sort_by_count_with_min_gb:
        _sorter = _sort_by_count
        keys = filter(
            lambda k: _sort_by_total_size(k)
            >= int(sort_by_count_with_min_gb) * 1024 * 1024 * 1024,
            keys,
        )
        reverse = False
    else:
        _sorter = _sort_by_total_size
        reverse = True

    sorted_tag_keys = sorted(keys, key=_sorter, reverse=reverse)
    for core_hash in sorted_tag_keys[:limit]:
        ccur = db.cursor()
        ccur.execute("select tag_text from tag_names where core_hash = ?", (core_hash,))
        row = ccur.fetchone()
        tag_text = row["tag_text"]
        used_bytes = _sort_by_total_size(core_hash)
        as_kb = used_bytes / 1024
        as_mb = as_kb / 1024
        as_gb = as_mb / 1024
        count = len(tagmap[core_hash])
        print(f"{core_hash}\t{tag_text}\t{as_gb}\tgb\t{count}\tfiles")

    ender_ts = time.monotonic()
    time_taken = round(ender_ts - end_ts, 2)
    print("took", time_taken, "seconds to sort and shit it all", file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main())
