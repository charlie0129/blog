#!/usr/local/bin/python3
"""Apply current netflow retention and VACUUM, doing the work on disk.

/var/netflow is a small tmpfs. When it is near-full SQLite cannot run its own
DELETE (needs rollback-journal space) or VACUUM (needs ~the database size
again), so flowd_aggregate dies with "database or disk is full". This moves
each database to UFS, trims and vacuums it there, then moves it back small.

Retention is read from the live aggregate classes, so this stays in sync with
whatever netflow-ramfix-patch.py has set.

Run with flowd_aggregate stopped.
"""
import datetime
import os
import shutil
import sqlite3
import sys

sys.path.insert(0, '/usr/local/opnsense/scripts/netflow')

from lib.aggregates.interface import FlowInterfaceTotals          # noqa: E402
from lib.aggregates.ports import FlowDstPortTotals                # noqa: E402
from lib.aggregates.source import (FlowSourceAddrTotals,          # noqa: E402
                                   FlowSourceAddrDetails)

SRC = '/var/netflow'
WORK = '/var/tmp/netflow-vacuum'
DAY = 86400

# filename -> retention seconds, straight from the (possibly patched) classes
RETENTION = {}
for cls in (FlowInterfaceTotals, FlowDstPortTotals,
            FlowSourceAddrTotals, FlowSourceAddrDetails):
    for resolution, keep in cls.history_per_resolution().items():
        RETENTION[cls.target_filename % resolution] = keep

os.makedirs(WORK, exist_ok=True)

names = sorted(
    (n for n in os.listdir(SRC) if n.endswith('.sqlite')),
    key=lambda n: os.path.getsize(os.path.join(SRC, n)),
    reverse=True,  # biggest first, so the mount frees up soonest
)

total_before = total_after = 0

for name in names:
    src_path = os.path.join(SRC, name)
    before = os.path.getsize(src_path)
    total_before += before

    keep = RETENTION.get(name)
    if keep is None:
        print('%-36s skip (no retention rule)' % name)
        total_after += before
        continue

    work_path = os.path.join(WORK, name)
    stat = os.stat(src_path)
    shutil.move(src_path, work_path)

    try:
        conn = sqlite3.connect(work_path, timeout=60,
                               detect_types=sqlite3.PARSE_DECLTYPES
                               | sqlite3.PARSE_COLNAMES)
        cur = conn.cursor()
        cur.execute("select name from sqlite_master "
                    "where type='table' and name='timeserie'")
        deleted = 0
        if cur.fetchone():
            cur.execute('select max(mtime) as "[timestamp]" from timeserie')
            last = cur.fetchall()[0][0]
            if isinstance(last, datetime.datetime):
                now_utc = datetime.datetime.now(
                    datetime.timezone.utc).replace(tzinfo=None)
                ref = now_utc if last > now_utc else last
                expire = ref - datetime.timedelta(seconds=keep)
                cur.execute('delete from timeserie where mtime < :expire',
                            {'expire': expire})
                deleted = cur.rowcount
                conn.commit()
        cur.execute('vacuum')
        conn.commit()
        conn.close()
    except Exception as exc:
        shutil.move(work_path, src_path)  # never strand a db off its mount
        sys.exit('ERROR processing %s: %s' % (name, exc))

    shutil.move(work_path, src_path)
    os.chown(src_path, stat.st_uid, stat.st_gid)
    os.chmod(src_path, stat.st_mode & 0o7777)

    after = os.path.getsize(src_path)
    total_after += after
    print('%-36s %6.1fM -> %6.1fM  (%7d rows dropped, keep %gd)'
          % (name, before / 1048576.0, after / 1048576.0,
             deleted, keep / float(DAY)))

print('\ntotal %.1fM -> %.1fM' % (total_before / 1048576.0,
                                  total_after / 1048576.0))
os.rmdir(WORK)
