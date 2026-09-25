#!/bin/sh
#
# check-opnsense-quirks.sh -- verify the local deviations on this OPNsense box.
#
# Run after every firmware update. Some of what is checked here lives in
# OPNsense core files and is silently reverted by opnsense-update; the rest
# lives in config.xml and survives, but is easy to undo from the GUI by
# accident.
#
#   FAIL  something is broken or a patch was reverted -- act on it
#   WARN  approaching a limit, or a known-fragile thing needs a nudge
#   INFO  context, no action implied
#
# Exits non-zero if there is at least one FAIL.
#
# Companion scripts:
#   /root/netflow-ramfix-patch.py    re-apply the netflow/flowd source patches
#   /root/netflow-ramfix-vacuum.py   trim + vacuum netflow dbs (needs UFS room)

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

CFG=${CFG:-/conf/config.xml}
NF=${NF:-/usr/local/opnsense/scripts/netflow}
fails=0
warns=0

# --- output helpers ---------------------------------------------------------
if [ -t 1 ]; then
    R=$(printf '\033[31m'); Y=$(printf '\033[33m')
    G=$(printf '\033[32m'); B=$(printf '\033[1m'); Z=$(printf '\033[0m')
else
    R=''; Y=''; G=''; B=''; Z=''
fi

section() { printf '\n%s== %s%s\n' "$B" "$1" "$Z"; }
pass()    { printf '  %sPASS%s  %s\n' "$G" "$Z" "$1"; }
warn()    { printf '  %sWARN%s  %s\n' "$Y" "$Z" "$1"; warns=$((warns + 1)); }
fail()    { printf '  %sFAIL%s  %s\n' "$R" "$Z" "$1"; fails=$((fails + 1)); }
info()    { printf '  INFO  %s\n' "$1"; }

# cfg_is <tag> <expected> <label>
cfg_is() {
    _got=$(sed -n "s|.*<$1>\([^<]*\)</$1>.*|\1|p" "$CFG" | head -1)
    if [ "$_got" = "$2" ]; then
        pass "$3 ($1=$_got)"
    elif [ -z "$_got" ]; then
        fail "$3: <$1> is empty or absent, expected $2"
    else
        fail "$3: <$1>=$_got, expected $2"
    fi
}

# file_has <path> <fixed-string> <label>
file_has() {
    if [ ! -f "$1" ]; then
        fail "$3: $1 missing"
    elif grep -qF "$2" "$1"; then
        pass "$3"
    else
        fail "$3: '$2' not found in $1 -- reverted by an update?"
    fi
}

# file_lacks <path> <fixed-string> <label>
file_lacks() {
    if [ ! -f "$1" ]; then
        fail "$3: $1 missing"
    elif grep -qF "$2" "$1"; then
        fail "$3: stock value '$2' is back in $1 -- re-run netflow-ramfix-patch.py"
    else
        pass "$3"
    fi
}

is_exec() {
    if [ -x "$1" ]; then pass "$2"; else fail "$2: $1 missing or not executable"; fi
}

# ===========================================================================
section "Memory and swap"

memline=$(top -b -d1 2>/dev/null | grep '^Mem')
info "$memline"
free_mb=$(echo "$memline" | sed -n 's/.*[^0-9]\([0-9]*\)M Free.*/\1/p')
laundry_mb=$(echo "$memline" | sed -n 's/.*[^0-9]\([0-9]*\)M Laundry.*/\1/p')
[ -z "$laundry_mb" ] && laundry_mb=0

if [ -n "$free_mb" ] && [ "$free_mb" -lt 150 ]; then
    fail "only ${free_mb}M free -- OOM kills are likely"
elif [ -n "$free_mb" ] && [ "$free_mb" -lt 300 ]; then
    warn "only ${free_mb}M free"
else
    pass "free memory ${free_mb}M"
fi

# Laundry is dirty pages the pager wants to evict. With no swap it cannot,
# and a large figure is the leading indicator of the OOM cascade.
if [ "$laundry_mb" -gt 600 ]; then
    fail "Laundry ${laundry_mb}M -- pages cannot be reclaimed (no swap); OOM imminent"
elif [ "$laundry_mb" -gt 250 ]; then
    warn "Laundry ${laundry_mb}M -- watch this, it precedes OOM kills"
else
    pass "Laundry ${laundry_mb}M"
fi

if swapinfo -h 2>/dev/null | grep -q '^/'; then
    pass "swap configured: $(swapinfo -h | tail -1)"
else
    info "no swap -- intentional on this box, but it means tmpfs growth is fatal, not slow"
fi

oom=$(grep -ac 'failed to reclaim memory' /var/log/system/latest.log 2>/dev/null)
[ -z "$oom" ] && oom=0
if [ "$oom" -gt 0 ]; then
    fail "$oom OOM kills in today's system log -- something is consuming RAM again"
else
    pass "no OOM kills in today's system log"
fi

# ===========================================================================
section "RAM disks (tmpfs) -- these ARE your RAM"

# Sizes come from max_mfs_var / max_mfs_tmp as a PERCENT of physmem, applied
# only at mount time, i.e. at boot. Changing them needs a reboot, so a mismatch
# between config.xml and the live mount usually means "edited, not rebooted".
phys=$(sysctl -n hw.physmem)
pct_var=$(sed -n 's|.*<max_mfs_var>\([0-9]*\)</max_mfs_var>.*|\1|p' "$CFG" | head -1)
pct_tmp=$(sed -n 's|.*<max_mfs_tmp>\([0-9]*\)</max_mfs_tmp>.*|\1|p' "$CFG" | head -1)
# Absent means OPNsense's built-in default of 50%.
[ -n "$pct_var" ] || { pct_var=50; warn "max_mfs_var unset -- defaulting to 50% of RAM"; }
[ -n "$pct_tmp" ] || { pct_tmp=50; warn "max_mfs_tmp unset -- defaulting to 50% of RAM"; }

check_mount_size() {
    _mp=$1; _pct=$2
    _want=$(( phys / 100 * _pct / 1048576 ))
    _got=$(df -m "$_mp" 2>/dev/null | awk 'NR==2 {print $2}')
    if [ -z "$_got" ]; then
        fail "$_mp is not a separate mount"
    elif [ "$_got" -ge $((_want - 8)) ] && [ "$_got" -le $((_want + 8)) ]; then
        pass "$_mp sized ${_got}M (${_pct}% of physmem)"
    else
        warn "$_mp is ${_got}M but config says ${_pct}% = ~${_want}M -- reboot to apply"
    fi
}

check_mount_size /var/log "$pct_var"
check_mount_size /tmp "$pct_tmp"
check_mount_size /var/lib/php/tmp "$pct_tmp"

# Worst case matters: max_mfs_tmp caps /tmp AND /var/lib/php/tmp, so the three
# mounts together can exceed RAM even though each is individually reasonable.
worst=$(( phys / 100 * pct_var / 1048576 + 2 * (phys / 100 * pct_tmp / 1048576) ))
physmb=$(( phys / 1048576 ))
if [ "$worst" -ge $(( physmb * 3 / 4 )) ]; then
    warn "if all three tmp/log mounts filled: ${worst}M of ${physmb}M RAM -- consider lowering"
else
    info "worst case for the three capped mounts: ${worst}M of ${physmb}M RAM"
fi

df -m | awk '$1 == "tmpfs" {gsub(/%/,"",$5); print $6, $5, $3, $2}' | \
while read -r mp pct used size; do
    if [ "$pct" -ge 90 ]; then
        printf '  %sFAIL%s  %s at %s%% (%sM of %sM) -- SQLite there cannot even DELETE\n' \
            "$R" "$Z" "$mp" "$pct" "$used" "$size"
    elif [ "$pct" -ge 70 ]; then
        printf '  %sWARN%s  %s at %s%% (%sM of %sM)\n' "$Y" "$Z" "$mp" "$pct" "$used" "$size"
    else
        printf '  %sPASS%s  %s at %s%% (%sM of %sM)\n' "$G" "$Z" "$mp" "$pct" "$used" "$size"
    fi
done
# The subshell above cannot update our counters; re-derive the worst case.
if df -m | awk '$1 == "tmpfs" {gsub(/%/,"",$5); if ($5 >= 90) found=1} END {exit !found}'; then
    fails=$((fails + 1))
fi

# ===========================================================================
section "Log retention (config.xml -- survives updates)"

# maxfilesize is a rotation TRIGGER evaluated hourly by the cron job
# "configctl -d syslog archive", not a hard cap. A log growing 9MB/hour will
# still produce ~9MB files with maxfilesize=8.
cfg_is maxfilesize 8 "syslog rotate trigger"
# maxpreserve is a FILE COUNT per log subject, not days. Slow subjects rotate
# daily so 3 means 3 days; the filter log rotates hourly so 3 means ~3 hours.
cfg_is maxpreserve 3 "syslog files kept per subject"

if grep -q 'configctl -d syslog archive' /var/cron/tabs/root 2>/dev/null; then
    pass "hourly log_archive cron entry present"
else
    fail "log_archive cron entry missing from /var/cron/tabs/root"
fi

# log_archive has a trap: if syslog-ng ends up writing into an already-rotated
# filename (<subject>_YYYYMMDD.NNNN.log), the regex that detects a rotatable
# file fails, the script hits "else { continue; }" and NEVER prunes that
# subject again. The tell is a dangling or non-canonical latest.log.
for d in /var/log/*/; do
    subj=$(basename "$d")
    link="$d/latest.log"
    [ -L "$link" ] || continue
    tgt=$(readlink "$link")
    if [ ! -e "$tgt" ]; then
        fail "$subj: latest.log dangles -> $(basename "$tgt"); rotation is stuck, restart syslog-ng"
    elif ! echo "$(basename "$tgt")" | grep -Eq "^${subj}_[0-9]{8}\.log$"; then
        fail "$subj: live log is $(basename "$tgt"), not canonical; pruning is stuck, restart syslog-ng"
    fi
done
pass "checked latest.log targets for rotation-stuck subjects"

# ===========================================================================
section "Netflow / Insight retention (CORE FILES -- reverted by updates)"

file_has "$NF/flowd_aggregate.py" 'MAX_LOGS = 3' \
    "flowd.log kept to 3 rotations (~40MB with MAX_FILE_SIZE_MB=10)"
file_lacks "$NF/flowd_aggregate.py" 'MAX_LOGS = 10' "flowd.log MAX_LOGS not stock"

# src_addr_details aggregates on 6 fields incl. dst_addr and service_port, so
# it costs ~15MB/day here. Stock is 62 days.
file_lacks "$NF/lib/aggregates/source.py" 'seconds_per_day(62)' \
    "src_addr_details retention not stock (62d)"
file_lacks "$NF/lib/aggregates/source.py" 'seconds_per_day(365)' \
    "src_addr daily retention not stock (365d)"
file_lacks "$NF/lib/aggregates/ports.py" 'seconds_per_day(365)' \
    "dst_port daily retention not stock (365d)"

n2=$(grep -c 'seconds_per_day(2)' "$NF/lib/aggregates/source.py" 2>/dev/null)
if [ "$n2" = "2" ]; then
    pass "source.py: both daily aggregates at 2d"
else
    fail "source.py: expected 2 aggregates at 2d, found $n2 -- re-run netflow-ramfix-patch.py"
fi

nfl=$(ls /var/log/flowd.log.* 2>/dev/null | wc -l | tr -d ' ')
if [ "$nfl" -le 3 ]; then
    pass "flowd.log rotations: $nfl"
else
    warn "flowd.log rotations: $nfl (>3) -- is flowd_aggregate running? it does the rotating"
fi

# ===========================================================================
section "Hostwatch"

cfg_is expire4_interval 604800 "IPv4 host entries expire (7d)"
cfg_is expire6_interval 86400  "IPv6 host entries expire (1d)"

hwif=$(sed -n 's/^hostwatch_interfaces="\(.*\)"/\1/p' /etc/rc.conf.d/hostwatch 2>/dev/null)
if [ -z "$hwif" ]; then
    fail "hostwatch binds ALL interfaces -- it will record every internet peer seen on WAN"
else
    pass "hostwatch bound to: $hwif"
    for dev in $(sed -n 's|.*<if>\(.*\)</if>.*|\1|p' "$CFG" | sort -u); do
        case " $hwif " in
            *" $dev "*)
                # Is this device a WAN? Crude but effective: it carries a gateway.
                if grep -q "<if>$dev</if>" "$CFG" && \
                   sed -n "/<if>$dev<\/if>/,/<\/.*>/p" "$CFG" | grep -q 'dhcp\|pppoe'; then
                    warn "hostwatch includes $dev which looks like a WAN device"
                fi
                ;;
        esac
    done
fi

wal=/var/db/hostwatch/hosts.db-wal
if [ -f "$wal" ]; then
    walmb=$(( $(stat -f %z "$wal") / 1048576 ))
    # A WAL this large means checkpointing has stalled; once the 128M mount is
    # full the db gets corrupted and must be recreated.
    if [ "$walmb" -ge 60 ]; then
        fail "hosts.db-wal is ${walmb}M -- checkpointing stalled, mount will fill"
    elif [ "$walmb" -ge 25 ]; then
        warn "hosts.db-wal is ${walmb}M"
    else
        pass "hosts.db-wal is ${walmb}M"
    fi
fi

# ===========================================================================
section "IPv6 RA watchdog (gotcha 10)"

is_exec /usr/local/sbin/ipv6-ra-watchdog "watchdog script present"
is_exec /usr/local/etc/rc.syshook.d/start/99-ipv6-ra-watchdog "boot hook present"

# The watchdog also repairs the gateway monitor that gave up waiting for the
# address (gotcha 23). Both files are hand-installed, so an older copy or a
# restore from backup can silently lose this half.
file_has /usr/local/sbin/ipv6-ra-watchdog 'pluginctl -c monitor' \
    "watchdog re-runs the gateway monitor hook"
file_has /usr/local/etc/rc.syshook.d/start/99-ipv6-ra-watchdog \
    'rm -f /var/run/ipv6-ra-watchdog.monitor-stamp' \
    "boot hook clears the rate-limit stamp (/var/run survives reboots)"

# rc.syshook.d runs EVERY file in the directory regardless of extension, so a
# stray .bak or .orig becomes a second, older copy running at boot. This is not
# hypothetical: a leftover 99-ipv6-ra-watchdog.bak ran concurrently with the
# real hook and raced it.
stray=$(ls /usr/local/etc/rc.syshook.d/*/* 2>/dev/null | \
    grep -E '\.(bak|orig|old|save|dpkg-dist|rpmsave)|~$|\.bak-' || true)
if [ -z "$stray" ]; then
    pass "no leftover backup files in rc.syshook.d (they would be executed)"
else
    for f in $stray; do fail "rc.syshook.d will execute this backup file: $f"; done
fi

act=/usr/local/opnsense/service/conf/actions.d/actions_ipv6watchdog.conf
if [ ! -f "$act" ]; then
    fail "configd action $act missing"
elif ! grep -q '^description:' "$act"; then
    fail "configd action has no description: line -- it will not appear in the cron picker"
else
    pass "configd action present with description:"
fi

# NOTE: model-defined cron jobs render into tabs/nobody (they invoke configctl,
# which is root-side), NOT tabs/root. Looking in the wrong file is misleading.
if grep -q 'ipv6watchdog solicit' /var/cron/tabs/nobody 2>/dev/null; then
    pass "watchdog cron job present in /var/cron/tabs/nobody"
else
    fail "watchdog cron job missing from /var/cron/tabs/nobody"
fi

# ===========================================================================
section "Custom tmpfs mounts (gotchas 14 and 15)"

n=$(grep -c '^tmpfs' /etc/fstab 2>/dev/null)
if [ "$n" = "5" ]; then
    pass "5 custom tmpfs entries in /etc/fstab"
else
    fail "expected 5 custom tmpfs entries in /etc/fstab, found $n"
fi
is_exec /usr/local/etc/rc.syshook.d/early/01-ramdisk-dirs "ownership-restore hook present"

for spec in "/var/db/rrd nobody" "/var/db/hostwatch hostd" "/var/lib/php/sessions wwwonly" \
            "/var/unbound/data unbound"; do
    d=$(echo "$spec" | cut -d' ' -f1); want=$(echo "$spec" | cut -d' ' -f2)
    got=$(stat -f %Su "$d" 2>/dev/null)
    if [ "$got" = "$want" ]; then
        pass "$d owned by $got"
    else
        fail "$d owned by $got, expected $want -- mounting tmpfs resets ownership"
    fi
done

if [ -f /var/unbound/root.key ]; then
    pass "unbound root.key is on disk (outside the tmpfs)"
else
    warn "/var/unbound/root.key missing -- DNSSEC anchor must persist outside tmpfs"
fi

# ===========================================================================
section "Firewall / forwarding settings (gotchas 3 and 8)"

for s in net.pf.share_forward net.pf.share_forward6; do
    v=$(sysctl -n $s 2>/dev/null)
    if [ "$v" = "1" ]; then pass "$s=1"; else warn "$s=$v, expected 1 (measured faster)"; fi
done

if grep -q '^set state-policy if-bound' /tmp/rules.debug 2>/dev/null; then
    pass "pf state-policy is if-bound"
else
    fail "pf state-policy is not if-bound in /tmp/rules.debug"
fi

# ===========================================================================
section "Services and gateways"

down=$(configctl service list 2>/dev/null | \
    /usr/local/bin/python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print("\n".join("%s (%s)" % (s.get("description"), s.get("status")) for s in d
      if "not running" in s.get("status","")))' 2>/dev/null)
if [ -z "$down" ]; then
    pass "all services running"
else
    echo "$down" | while read -r l; do [ -n "$l" ] && printf '  %sFAIL%s  down: %s\n' "$R" "$Z" "$l"; done
    fails=$((fails + 1))
fi

offline=$(configctl interface gateways status 2>/dev/null | \
    /usr/local/bin/python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print(" ".join(k for k,v in d.items() if v.get("status_translated")!="Online"))' 2>/dev/null)
if [ -z "$offline" ]; then
    pass "all gateways Online"
else
    # Known: after a reboot the PPPoE RA arrives *after* gateway monitor setup
    # ran, so the v6 monitor never starts. Re-running the hook fixes it.
    warn "gateway(s) not Online: $offline"
    info "if a v6 gateway on the PPPoE link: run 'pluginctl -c monitor'"
    info "NOTE: 'pluginctl -c dpinger_configure_do' is a silent no-op; the hook is 'monitor'"
fi

# ===========================================================================
printf '\n%s== Summary%s\n' "$B" "$Z"
printf '  %s FAIL, %s WARN\n' "$fails" "$warns"
if [ "$fails" -gt 0 ]; then
    printf '  Re-apply core-file patches with: python3 /root/netflow-ramfix-patch.py\n'
    exit 1
fi
exit 0
