#!/usr/bin/env python3
#
# find out which files from a folder are not indexed
#
# use: find_unindexed.py path/to/folder

import sys
import os
import sqlite3
import logging
from pathlib import Path


log = logging.getLogger(__name__)


def main():
    logging.basicConfig(level=logging.INFO)
    path = Path.home() / "awtf.db"
    db = sqlite3.connect(f"file:{str(path)}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    total = 0

    for folder_to_check in sys.argv[1:]:
        folder_to_check = Path(folder_to_check).resolve()
        files_in_folder = set(f for f in folder_to_check.glob("**/*") if f.is_file())

        log.info("%d files in folder", len(files_in_folder))

        cur = db.cursor()
        res = cur.execute(
            """
            select local_path
            from files
            where local_path LIKE ? || '%'
            """,
            (str(folder_to_check),),
        )
        indexed_files = set()
        for row in res:
            indexed_files.add(Path(row["local_path"]))

        unindexed_files = files_in_folder - indexed_files
        for path in unindexed_files:
            if os.environ.get("PRINT_0") == "1":
                print(str(path) + "\x00", end="", file=sys.stdout)
            else:
                print(path, file=sys.stdout)

        log.info("%d files in folder", len(files_in_folder))
        log.info("%d files indexed for folder", len(indexed_files))
        log.info("path: %s", folder_to_check)

        log.info("%d unindexed files", len(unindexed_files))
        total += len(unindexed_files)
    log.info("total unindexed files: %d", total)


if __name__ == "__main__":
    sys.exit(main())
