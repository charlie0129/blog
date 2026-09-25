#!/usr/local/bin/python3
"""Shrink netflow/Insight + flowd.log footprint on a RAM-constrained OPNsense box.

WHY: /var/netflow is a 256M tmpfs (RAM). Stock retention is 365 days for the
daily rollups and 62 days for src_addr_details. Measured on this box,
src_addr_details costs ~15MB/day, so stock settings guarantee the mount fills,
and once it is full SQLite cannot even run its own DELETE (no room for the
rollback journal) -- flowd_aggregate then dies with "database or disk is full"
and stops rotating /var/log/flowd.log too.

These are OPNsense core files and WILL be reverted by opnsense-update.
Re-run this after every firmware update. Detection: check-opnsense-ramfix.sh

Idempotent and re-appliable: converges to the target value from the stock
value or from any previously-set local value.
"""
import re
import shutil
import sys

DAILY = r'86400: cls\.seconds_per_day\(\d+\)[^\n]*'


def patch_in_class(text, anchor, pattern, replacement):
    """Replace `pattern` only inside the class block containing `anchor`.

    Needed because source.py defines two classes that each have an identical
    `86400: cls.seconds_per_day(N)` line.
    """
    start = text.find(anchor)
    if start == -1:
        return text, 0
    end = text.find('\nclass ', start)
    if end == -1:
        end = len(text)
    block = text[start:end]
    new_block, n = re.subn(pattern, replacement, block, count=1)
    return text[:start] + new_block + text[end:], n


# (path, anchor inside the class, regex to replace, replacement, desired, label)
PATCHES = [
    (
        '/usr/local/opnsense/scripts/netflow/flowd_aggregate.py',
        None,
        r'^MAX_LOGS = \d+[^\n]*$',
        'MAX_LOGS = 3  # local: was 10; caps flowd.log at ~3x10MB',
        'MAX_LOGS = 3',
        'flowd_aggregate.py MAX_LOGS -> 3',
    ),
    (
        # Largest consumer: aggregates on 6 fields including dst_addr and
        # service_port, so rows scale with unique flows (~15MB/day here).
        '/usr/local/opnsense/scripts/netflow/lib/aggregates/source.py',
        "target_filename = 'src_addr_details_%06d.sqlite'",
        DAILY,
        '86400: cls.seconds_per_day(2)  # local: was 62; ~15MB/day on this box',
        'cls.seconds_per_day(2)',
        'source.py src_addr_details daily -> 2d',
    ),
    (
        '/usr/local/opnsense/scripts/netflow/lib/aggregates/source.py',
        "target_filename = 'src_addr_%06d.sqlite'",
        DAILY,
        '86400: cls.seconds_per_day(2)  # local: was 365',
        'cls.seconds_per_day(2)',
        'source.py src_addr daily -> 2d',
    ),
    (
        '/usr/local/opnsense/scripts/netflow/lib/aggregates/ports.py',
        "target_filename = 'dst_port_%06d.sqlite'",
        DAILY,
        '86400: cls.seconds_per_day(2)  # local: was 365',
        'cls.seconds_per_day(2)',
        'ports.py dst_port daily -> 2d',
    ),
]

# interface.py is deliberately NOT patched: interface_*.sqlite is ~5MB total
# and is the data the bandwidth graphs read.

applied, skipped, failed = [], [], []

for path, anchor, pattern, replacement, desired, label in PATCHES:
    with open(path) as fh:
        text = fh.read()

    # Already at the desired value inside the right class block?
    if anchor is None:
        current = text
    else:
        start = text.find(anchor)
        end = text.find('\nclass ', start) if start != -1 else -1
        current = text[start:end if end != -1 else len(text)] if start != -1 else ''
    if desired in current:
        skipped.append(label)
        continue

    if anchor is None:
        new, n = re.subn(pattern, replacement, text, count=1, flags=re.M)
    else:
        new, n = patch_in_class(text, anchor, pattern, replacement)

    if n != 1:
        failed.append(label)
        continue

    try:
        with open(path + '.stock'):
            pass
    except IOError:
        shutil.copy2(path, path + '.stock')

    with open(path, 'w') as fh:
        fh.write(new)
    applied.append(label)

for label in applied:
    print('applied:          %s' % label)
for label in skipped:
    print('already in place: %s' % label)
for label in failed:
    print('FAILED, pattern not found (upstream changed?): %s' % label)

if applied:
    print('\nRestart the aggregator to pick this up:')
    print('  service flowd_aggregate restart')

sys.exit(1 if failed else 0)
