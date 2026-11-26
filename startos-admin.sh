#!/usr/bin/env bash
# shellcheck disable=SC2154  # menu-choice variables are assigned via _read's nameref
# startos-admin.sh — Interactive admin menu for StartOS servers
# Usage: chmod +x startos-admin.sh && ./startos-admin.sh
#
# Menu:
#   Display:  1. Disk used by services    2. System data    3. Memory used by services
#   Create:   4. StartOS notification     5. Backup schedule    6. Stay-alive curl
#   Manage:   7. Cron jobs   8. Notification forwarders   9. Staged changes   10. Alerts
#   Other:    11. Save / Load configuration   12. Documentation   13. Debug mode
# CLI:        --version --help --update [--yes] --no-update-check | status server-info
#             network services service domains interfaces disk memory cron forwarders
#             alerts staged debug notify  (startos-admin --help)

VERSION="74"   # integer — increment on each release

# Generated alert scripts carry MONITOR_FORMAT. Bump a type's format whenever
# its generated script changes in a way installed alerts must pick up; at
# launch the menu offers to rebuild every alert below its type's format
# (settings kept).
#   2 = v72: password-free backup staleness check, "check failing" notices.
#   3 = v73 (backup-age only): StartOS 0.4.3 backup targets (registered ids,
#       availability).
_MONITOR_FORMAT=2
_monitor_format() {
    case "$1" in
        backup-age) echo 3 ;;
        *)          echo "$_MONITOR_FORMAT" ;;
    esac
}

set -euo pipefail

# ─────────────────────────────────────────────
# Colors & Styles
# ─────────────────────────────────────────────
# Real ESC bytes ($'...'), not the literal "\e[..m" two-character form. Only
# `echo -e` expands a literal \e; awk and printf emit it verbatim — which is how
# the package-stats table ended up printing "\e[1m" on screen, since it passes
# these to awk via -v (mawk, Debian's awk, has no \e escape at all).
GREEN=$'\e[32m'
RED=$'\e[31m'
YELLOW=$'\e[33m'
BLUE=$'\e[34m'
CYAN=$'\e[36m'
BOLD=$'\e[1m'
DIM=$'\e[2m'
NC=$'\e[0m'

# ─────────────────────────────────────────────
# Path Constants
# ─────────────────────────────────────────────
_POLLER_BIN_PREFIX="/usr/local/bin/startos-notif-poller-"
_STARTOS_DATA_DIR="/usr/local/share/startos-admin"
_POLLER_STATE_PREFIX="${_STARTOS_DATA_DIR}/startos-admin-poller-state-"
_POLLER_LOG_PREFIX="${_STARTOS_DATA_DIR}/startos-notif-poller-"
# Alert monitors (disk / backup-age / backup-ok / backup-failed / health /
# drive) — named instances.
_MONITOR_BIN_PREFIX="/usr/local/bin/startos-monitor-"
_MONITOR_DATA_PREFIX="${_STARTOS_DATA_DIR}/startos-monitor-"
_MONITOR_VOLUMES_PATH="/media/startos/data/package-data/volumes/"
# Full path to start-cli — resolved once so cron jobs and generated scripts
# embed the absolute path and don't depend on cron's minimal PATH.
_START_CLI=$(command -v start-cli 2>/dev/null || echo "start-cli")
_CONFIG_BACKUP_FILE="/tmp/startos-config-backup.enc"
# Root-only directory for secrets (backup passwords). Created mode 700 inside
# chroot-and-upgrade so it persists across reboots; files inside are mode 600.
_SECRET_DIR="/root/.startos-admin"
# Staged-changes queue: blocks of chroot commands waiting to be applied in one
# restart. Root-only (blocks can contain backup-password base64). Survives
# script exit; lost on reboot (applying always reboots anyway).
_STAGED_FILE="${_SECRET_DIR}/staged-changes"
# Ends every chroot session: delete backup-password files that no cron line
# (active or commented out) refers to any more, so removing or retargeting a
# backup schedule doesn't leave the password behind on disk.
_SECRET_SWEEP_CMDS="for __f in ${_SECRET_DIR}/backup-pass-*; do if [ -f \"\$__f\" ] && ! crontab -l 2>/dev/null | grep -qF \"\$__f\"; then rm -f \"\$__f\"; fi; done; true"
# Single source of truth for the published script location.
_REPO_RAW_URL="https://raw.githubusercontent.com/JesseMarkowitz/admintools-startos/refs/heads/main/startos-admin.sh"
# Release signing key. A downloaded script is installed only if its GPG
# signature (startos-admin.sh.asc) was made by this key; see RELEASING.md.
# Releases before v74 were checked against an older P-256 key and its
# startos-admin.sh.sig. v74 and v75 carry both signatures so copies of v73
# and older can still update.
_UPDATE_GPG_FPR="84FF9BB7F3E85F913CCF438E1A64936712ACCC07"
_UPDATE_GPG_KEY="-----BEGIN PGP PUBLIC KEY BLOCK-----

mDMEawdjXBYJKwYBBAHaRw8BAQdAmYzCSU9H9eQoxT5c1psSvh/byyRuqpH72HaE
7D2kKCC0OEplc3NlIE1hcmtvd2l0eiAocmVsZWFzZSBzaWduaW5nKSA8c3RhcnRv
c0BtYXJrb3dpdHoubWU+iJAEExYKADgWIQSE/5u38+hfkTzPQ44aZJNnEqzMBwUC
awdjXAIbAwULCQgHAgYVCgkICwIEFgIDAQIeAQIXgAAKCRAaZJNnEqzMB7UjAQCs
I2lBnM3HHv5YgJMmIHzLiiPDqGWVvlGvtu/x1aaLXAD9FArHyIja892hlJGNe/J/
5yH87YoZtogmHqXxxlsMLwI=
=lEhq
-----END PGP PUBLIC KEY BLOCK-----"

# ─────────────────────────────────────────────
# Navigation — "exit" / "back" support
# ─────────────────────────────────────────────

_BACK=0

# ─────────────────────────────────────────────
# Debug Mode
# ─────────────────────────────────────────────

_DEBUG=0
_DEBUG_FLAG_FILE="${_STARTOS_DATA_DIR}/debug"
[[ -f "$_DEBUG_FLAG_FILE" ]] && _DEBUG=1

# _read VARNAME "prompt" — wrapper around read -rp.
# Typing "exit" at any prompt exits the script immediately.
# Typing "back" at any prompt sets _BACK=1 and returns 1.
# Callers propagate with:  _read VAR "prompt" || return 1
_read() {
    local -n _out="$1"; shift
    read -rp "$@" _out
    if [[ "${_out,,}" == "exit" ]]; then exit 0; fi
    if [[ "${_out,,}" == "back" ]]; then _BACK=1; return 1; fi
    return 0
}

# Like _read but silent (for passwords). Supports 'back' and 'exit'.
_read_silent() {
    local -n _sout="$1"; shift
    read -rsp "$@" _sout
    echo ""
    if [[ "${_sout,,}" == "exit" ]]; then exit 0; fi
    if [[ "${_sout,,}" == "back" ]]; then _BACK=1; return 1; fi
    return 0
}

# Print the standard navigation hint at the start of a wizard.
_nav_tip() {
    echo -e "  ${DIM}(type 'back' to return to main menu, or 'exit' to quit)${NC}"
    echo ""
}

# Print a debug message when _DEBUG=1. No-op otherwise.
debug_log() {
    [[ $_DEBUG -eq 1 ]] || return 0
    echo -e "  ${DIM}[debug] $*${NC}"
}

# ─────────────────────────────────────────────
# Helper Functions
# ─────────────────────────────────────────────

print_header() {
    # clear fails without a usable TERM (e.g. TERM=dumb, or none); under set -e
    # that would end the script silently, so it is cosmetic only.
    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════╗"
    printf "  ║      StartOS Admin Menu  v%-15s║\n" "${VERSION}"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_success() {
    echo -e "${GREEN}${BOLD}[✓]${NC} ${GREEN}${1}${NC}"
}

print_error() {
    echo -e "${RED}${BOLD}[✗]${NC} ${RED}${1}${NC}"
}

print_info() {
    echo -e "${CYAN}${BOLD}[i]${NC} ${1}"
}

print_warn() {
    echo -e "${YELLOW}${BOLD}[!]${NC} ${YELLOW}${1}${NC}"
}

print_section() {
    echo -e "\n${BOLD}${BLUE}── ${1} ${NC}${DIM}$(printf '─%.0s' {1..40})${NC}"
}

# The server's API state: Running | Initializing | Error (or Unknown if
# unreachable). `state` is the one method served by every context and it needs
# no auth, so it still answers when db/package calls cannot. Bounded by
# timeout: the call that has to answer when the server is sick must not be the
# one that hangs.
_startos_state() {
    timeout 10 start-cli state 2>/dev/null || echo "Unknown"
}

# Guard for calls that need a fully-running server. While StartOS is
# initializing it serves a reduced API with no db.* methods, so 'db dump'
# comes back "Method not found" rather than anything about startup — check
# first and say what is actually happening. Returns 1 unless state is Running.
_require_running() {
    local st
    st=$(_startos_state)
    debug_log "start-cli state: ${st}"
    case "$st" in
        Running) return 0 ;;
        Initializing)
            print_error "StartOS is still starting up."
            echo -e "  ${DIM}System data is unavailable until initialization completes.${NC}"
            echo -e "  ${DIM}Watch progress with${NC} ${CYAN}start-cli init subscribe${NC}" ;;
        Error)
            print_error "StartOS is in diagnostic mode — the server failed to start."
            echo -e "  ${DIM}Open the web interface for the diagnostic report.${NC}" ;;
        *)
            print_error "Could not reach StartOS ('start-cli state' failed)."
            echo -e "  ${DIM}Confirm the server is powered on and startd is running.${NC}" ;;
    esac
    return 1
}

# StartOS version ("0.4.3"), from the file every 0.4.x image ships; empty if
# unreadable.
_os_version() {
    local v
    v=$(head -c 64 /usr/lib/startos/VERSION.txt 2>/dev/null | tr -d '[:space:]') || v=""
    printf '%s' "$v"
}

# True if StartOS is at least version $1 (pre-release suffixes ignored).
# Unknown version → false.
_os_at_least() {
    local v
    v=$(_os_version)
    v="${v%%[-:+~]*}"
    [[ -n "$v" ]] || return 1
    [[ "$(printf '%s\n%s\n' "$1" "$v" | sort -V | head -1)" == "$1" ]]
}

# StartOS 0.4.3 replaced backup targets: they are registered in System →
# Backups, disk targets get a permanent id (32-character GUID, the drive kept
# as /dev/disk/by-uuid/<UUID>), unregistered drives are not listed, and the
# old "disk-/dev/sdX" ids are rejected. Backup results go to History instead
# of notifications.
_backup_targets_registered() { _os_at_least 0.4.3; }

# Bytes → "1.2T" / "6.1G" / "512M" (one decimal above M).
_human_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        split("K M G T P", u, " "); v = b / 1024; i = 1
        while (v >= 1024 && i < 5) { v /= 1024; i++ }
        if (i == 1) printf "%dK", v; else if (i == 2) printf "%dM", v; else printf "%.1f%s", v, u[i]
    }'
}

# Seconds → "3d 4h" / "4h 12m" / "12m".
_human_duration() {
    local s="${1:-0}"
    (( s < 0 )) && s=0
    local d=$(( s / 86400 )) h=$(( s % 86400 / 3600 )) m=$(( s % 3600 / 60 ))
    if (( d > 0 )); then echo "${d}d ${h}h"
    elif (( h > 0 )); then echo "${h}h ${m}m"
    else echo "${m}m"; fi
}

# Status lines for the main menu, like the facts the SSH login banner prints
# (/usr/lib/startos/motd): hostname, StartOS version, uptime, NTP, services,
# data drive, memory, last backup. One state call + one db dump, cached for
# 30 s so redrawing the menu after a typo doesn't re-query the server.
_SB_CACHE=""
_SB_TIME=-100
_status_block() {
    if (( SECONDS - _SB_TIME < 30 )) && [[ -n "$_SB_CACHE" ]]; then
        printf '%s\n' "$_SB_CACHE"
        return 0
    fi
    local out="" st db
    st=$(_startos_state)
    if [[ "$st" != "Running" ]]; then
        case "$st" in
            Initializing) out="  ${YELLOW}StartOS is still starting up${NC} ${DIM}— server details appear once it is running.${NC}" ;;
            Error)        out="  ${RED}StartOS is in diagnostic mode${NC} ${DIM}— open the web interface for the report.${NC}" ;;
            *)            out="  ${RED}Could not reach StartOS${NC} ${DIM}('start-cli state' failed).${NC}" ;;
        esac
        _SB_CACHE="$out"; _SB_TIME=$SECONDS
        printf '%s\n' "$out"
        return 0
    fi
    db=$(timeout 15 start-cli db dump 2>/dev/null) || db=""

    local host="?" ver="?" ntp="" run=0 total=0 last_bk=""
    if [[ -n "$db" ]]; then
        IFS=$'\t' read -r host ver ntp run total last_bk < <(printf '%s' "$db" | jq -r '
            [ (.value.serverInfo.hostname // "?"),
              (.value.serverInfo.version // "?"),
              (.value.serverInfo.ntpSynced | if . == null then "-" else tostring end),
              ([.value.packageData[] | select(.statusInfo.started != null)] | length),
              (.value.packageData | length),
              (.value.serverInfo.lastBackup // "-") ] | @tsv' 2>/dev/null) || true
        # "-" stands in for empty: tabs are IFS whitespace, so read would
        # collapse an empty field and shift the ones after it.
        [[ "$last_bk" == "-" ]] && last_bk=""
    fi

    local up_s up
    up_s=$(cut -d. -f1 /proc/uptime 2>/dev/null) || up_s=0
    up=$(_human_duration "${up_s:-0}")

    local ntp_txt=""
    case "$ntp" in
        true)  ntp_txt=" ${DIM}·${NC} ${GREEN}NTP synced${NC}" ;;
        false) ntp_txt=" ${DIM}·${NC} ${RED}NTP not synced${NC}" ;;
    esac
    out="  ${BOLD}${host}${NC} ${DIM}·${NC} StartOS ${ver} ${DIM}·${NC} up ${up}${ntp_txt}"

    local svc_col="$GREEN"
    (( run < total )) && svc_col="$YELLOW"
    (( total > 0 && run == 0 )) && svc_col="$RED"
    local svc_txt="Services ${svc_col}${run}/${total} running${NC}"
    [[ -z "$db" ]] && svc_txt="Services ${DIM}?${NC}"

    local data_txt="" dsz dus
    if read -r dsz dus < <(df -B1 --output=size,used "$_MONITOR_VOLUMES_PATH" 2>/dev/null | tail -1); then
        [[ "$dsz" =~ ^[0-9]+$ ]] && data_txt=" ${DIM}·${NC} Data $(_human_bytes "$dus")/$(_human_bytes "$dsz")"
    fi
    local mem_txt="" mtot mused
    if read -r mtot mused < <(free -b 2>/dev/null | awk 'NR==2{print $2, $3}'); then
        [[ "$mtot" =~ ^[0-9]+$ ]] && mem_txt=" ${DIM}·${NC} Memory $(_human_bytes "$mused")/$(_human_bytes "$mtot")"
    fi
    out+=$'\n'"  ${svc_txt}${data_txt}${mem_txt}"

    local bk_txt="${YELLOW}never${NC}"
    if [[ -n "$last_bk" ]]; then
        local bk_epoch
        if bk_epoch=$(date -d "$last_bk" +%s 2>/dev/null); then
            bk_txt="$(date -d "@$bk_epoch" '+%Y-%m-%d %H:%M %Z') ${DIM}($(_human_duration $(( $(date +%s) - bk_epoch ))) ago)${NC}"
        else
            bk_txt="$last_bk"
        fi
    fi
    [[ -z "$db" ]] && bk_txt="${DIM}?${NC}"
    out+=$'\n'"  Last backup ${bk_txt}"

    _SB_CACHE="$out"; _SB_TIME=$SECONDS
    printf '%s\n' "$out"
}

pause() {
    echo ""
    local _p_reply
    read -rp "$(echo -e "${DIM}  Press Enter to return (or type 'exit' to quit)...${NC}")" _p_reply
    if [[ "${_p_reply,,}" == "exit" ]]; then exit 0; fi
}

# Returns 0 for yes, 1 for no/back. Sets _BACK=1 and returns 1 on "back". Exits on "exit".
confirm() {
    local prompt="${1:-Are you sure?}"
    while true; do
        local reply
        read -rp "$(echo -e "${YELLOW}${BOLD}[?]${NC} ${prompt} [y/N]: ")" reply
        case "${reply,,}" in
            exit) exit 0 ;;
            back) _BACK=1; return 1 ;;
            y|yes) return 0 ;;
            n|no|"") return 1 ;;
            *) print_warn "Please enter y or n (or 'back'/'exit')." ;;
        esac
    done
}

# Print the standard server-restart warning box.
# $1 = operation text for the variable line (e.g. "after the cron job is installed.")
_warn_restart() {
    local msg
    printf -v msg "%-47s" "$1"
    echo ""
    echo -e "  ${RED}${BOLD}┌─────────────────────────────────────────────────┐${NC}"
    echo -e "  ${RED}${BOLD}│  WARNING: SERVER WILL AUTOMATICALLY RESTART     │${NC}"
    echo -e "  ${RED}${BOLD}│  ${msg}│${NC}"
    echo -e "  ${RED}${BOLD}│  Save any work and close open connections.      │${NC}"
    echo -e "  ${RED}${BOLD}└─────────────────────────────────────────────────┘${NC}"
    echo ""
}

# Extract package IDs from start-cli package list JSON output.
parse_package_ids() {
    echo "$1" | jq -r '.[].id'
}

# Extract backup targets from start-cli backup target list JSON output.
# Outputs one line per target: "id  (description)"
# The ID is always the first whitespace-delimited field on each line.
# Two shapes: StartOS 0.4.3+ lists registered targets as {name, source:{kind,
# …}, availability, available, error}; older StartOS lists every partition and
# CIFS share as {type, …}.
parse_backup_targets() {
    echo "$1" | jq -r '
        def human: if . == null then null
            elif . >= 1e12 then "\(. / 1e11 | floor / 10)T"
            elif . >= 1e9 then "\(. / 1e8 | floor / 10)G"
            else "\(. / 1e6 | floor)M" end;
        to_entries[] |
        if (.value.source | type) == "object" then
            .value as $t | $t.source as $s |
            (if $s.kind == "cifs" then "network share"
             elif $s.kind == "local" then "folder on this server"
             elif $s.kind == "disk" then
                ([$s.drive.vendor, $s.drive.model] | map(select(. != null and . != "")) | join(" ")
                 | if . == "" then "drive" else "drive: \(.)" end)
             else ($s.kind // "unknown") end) as $kind |
            (if $t.availability == "unavailable" then ", UNAVAILABLE\(if $t.error then ": \($t.error)" else "" end)"
             elif ($t.available | human) then ", \($t.available | human) free"
             else "" end) as $state |
            "\(.key)  (\($t.name // "unnamed") — \($kind)\($state))"
        elif .value.type == "disk" then
            "\(.key)  (\([.value.vendor, .value.model] | map(select(. != null)) | join(" ") | if . == "" then "disk" else . end), \((.value.capacity // 0) / 1e9 * 10 | floor / 10) GB\(if .value.label then ", label \(.value.label)" else "" end))"
        else
            "\(.key)  (\(.value.hostname // .value.type // "unknown")\(.value.path // ""))"
        end
    '
}

# Disk backup targets are listed by their current kernel device name
# (disk-/dev/sdb1). That name is not stable: after a reboot or replug the same
# id can name a DIFFERENT drive, and a backup would silently go there. So
# schedules and alerts store a stable target key instead:
#   disk → "uuid-<filesystem UUID>"   (resolved to disk-/dev/sdXN at run time)
#   cifs → the target id unchanged    ("cifs-0")
# The key is the charset-safe name used in password file names, cron comments
# and generated scripts.
_BACKUP_UUID_DIR="/dev/disk/by-uuid"

# Print the stable key for a target id from `backup target list`.
# Returns 1 if a disk target has no filesystem UUID.
_backup_target_key() {
    local id="$1" dev link
    case "$id" in
        disk-/*)
            dev="${id#disk-}"
            for link in "$_BACKUP_UUID_DIR"/*; do
                [[ -e "$link" ]] || continue
                if [[ "$(readlink -f "$link")" == "$dev" ]]; then
                    printf 'uuid-%s\n' "${link##*/}"
                    return 0
                fi
            done
            return 1
            ;;
        *) printf '%s\n' "$id" ;;
    esac
}

# Print the target argument for a `backup create` cron line. A disk key
# resolves the drive by UUID when cron runs; if the drive is not connected the
# target becomes a path that does not exist, so start-cli fails instead of
# backing up to whichever drive now holds the old device name.
_backup_target_cron_arg() {
    case "$1" in
        uuid-*)
            local u="${1#uuid-}"
            # shellcheck disable=SC2016  # $( ) is meant for cron's shell, not this one
            printf '"disk-$(readlink -e %s/%s || echo %s/%s-not-connected)"' \
                "$_BACKUP_UUID_DIR" "$u" "$_BACKUP_UUID_DIR" "$u"
            ;;
        *) printf '%s' "$1" ;;
    esac
}

# Print the package IDs of an installed `backup create` cron line as one
# comma-separated list (empty = all packages). Reads both forms: one
# --package-ids flag per package, and the comma-joined value pre-v70 wrote.
_backup_pkg_ids_from_cron_line() {
    printf '%s\n' "$1" | grep -oE -- "--package-ids [^ ]+" | awk '{print $2}' | paste -sd, - || true
}

# True if a `backup create` cron line carries a comma-joined --package-ids
# value. Versions before v70 wrote that form; start-cli rejects it, so the job
# exits without backing anything up (issue #1).
_backup_cron_line_has_joined_ids() {
    printf '%s\n' "$1" | grep -qE -- "--package-ids [^ ]*,"
}

# Print the target key of an installed `backup create` cron line.
_backup_key_from_cron_line() {
    local re='backup create "disk-\$\(readlink -e /dev/disk/by-uuid/([A-Za-z0-9._-]+) '
    if [[ "$1" =~ $re ]]; then
        printf 'uuid-%s\n' "${BASH_REMATCH[1]}"
    else
        printf '%s\n' "$1" | grep -oE "backup create [^ ]+" | awk '{print $3}'
    fi
}

# Resolve a listed target id to its stable key, printing why if it can't.
# $1 = id from the menu, $2 = nameref for the key. Returns 1 on failure.
_backup_pick_key() {
    local id="$1"
    local -n _bpk_key="$2"
    if ! _bpk_key=$(_backup_target_key "$id"); then
        print_error "Drive '${id}' has no filesystem UUID, so it cannot be told apart from"
        print_error "other drives after a reboot or replug. Aborting."
        return 1
    fi
    if [[ "$_bpk_key" == uuid-* ]]; then
        print_info "Disk target saved as '${_bpk_key}' (its filesystem UUID), so it follows"
        print_info "this drive even if its device name (now ${id#disk-}) changes."
    fi
}

# StartOS 0.4.3+: print the registered target id for an old "uuid-<UUID>" key,
# i.e. the drive added in System → Backups whose partition has that filesystem
# UUID, at its root (where pre-0.4.3 backups were written).
# $1 = uuid key, $2 = `backup target list` JSON. Returns 1 if none.
_backup_uuid_to_registered() {
    local u="${1#uuid-}" id
    id=$(printf '%s' "$2" | jq -r --arg p "${_BACKUP_UUID_DIR}/${u}" '
        to_entries[]
        | select(.value.source.kind? == "disk"
                 and .value.source.logicalname == $p
                 and ((.value.source.path // "") == ""))
        | .key' 2>/dev/null | head -1) || id=""
    [[ -n "$id" && "$id" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    printf '%s\n' "$id"
}

# Rewrite one installed `backup create` cron line that targets a drive by
# "uuid-<UUID>" (pre-0.4.3 form) to the drive's registered id, password file
# included. $1 = cron line, $2 = target list JSON, $3/$4 = namerefs for the
# new line and "old-key new-key". Returns 1 if the line is not in that form,
# 2 if the drive is not registered.
_backup_line_to_registered() {
    local line="$1" tlist="$2"
    local -n _bltr_line="$3" _bltr_keys="$4"
    local key gid
    key=$(_backup_key_from_cron_line "$line")
    [[ "$key" == uuid-* ]] || return 1
    gid=$(_backup_uuid_to_registered "$key" "$tlist") || return 2
    local u="${key#uuid-}"
    local old_arg="\"disk-\$(readlink -e ${_BACKUP_UUID_DIR}/${u} || echo ${_BACKUP_UUID_DIR}/${u}-not-connected)\""
    [[ "$line" == *"$old_arg"* ]] || return 1
    _bltr_line="${line/"$old_arg"/$gid}"
    _bltr_line="${_bltr_line//"${_SECRET_DIR}/backup-pass-${key}"/${_SECRET_DIR}/backup-pass-${gid}}"
    _bltr_keys="${key} ${gid}"
}

# Quote a string for safe single-quoted embedding in a shell command line.
# Replaces each ' with '\'' and wraps the result in single quotes.
_sq() {
    local q="'\\''"
    printf "'%s'" "${1//\'/$q}"
}

# Validate a URL for safe embedding in generated cron lines and scripts.
# Rejects quotes, spaces, $, backticks, backslashes, and % (cron treats
# unescaped % as a newline). Returns 0 if valid, 1 with message if not.
_validate_url() {
    local url="$1"
    if ! [[ "$url" =~ ^https?://[A-Za-z0-9:/?\&=._~#@+,-]+$ ]]; then
        print_warn "URL must start with http:// or https:// and contain only letters, digits, and : / ? & = . _ ~ # @ + , -"
        print_warn "Quotes, spaces, \$, %, and backslashes are not supported."
        return 1
    fi
    return 0
}

# Validate a keyword filter for safe embedding in a generated poller script.
# Letters, digits, spaces, . _ , - only. Empty is allowed (= no filter).
_validate_keyword() {
    local kw="$1"
    if ! [[ "$kw" =~ ^[A-Za-z0-9\ ._,-]*$ ]]; then
        print_warn "Keyword may only contain letters, digits, spaces, and . _ , -"
        return 1
    fi
    return 0
}

# Reject text containing an unescaped % — cron treats % as a newline and
# everything after it becomes stdin to the command, breaking it silently.
# Returns 0 if safe, 1 with message if not.
_check_cron_percent() {
    local _pct_re='(^|[^\])%'
    if [[ "$1" =~ $_pct_re ]]; then
        print_warn "Unescaped % is not supported — cron treats % as a newline."
        print_warn "If you really need a literal %, escape it as \\% yourself."
        return 1
    fi
    return 0
}

# Download the published script + its signature and verify before use.
# $1 = nameref — set to the path of the verified script file on success.
#      The caller must remove the containing temp dir when done:
#      rm -rf "$(dirname "$path")"
# Returns: 0 = verified, 1 = download/network failure, 2 = BAD SIGNATURE.
_fetch_verified_script() {
    local -n _fvs_path="$1"
    local tmpdir curl_rc=0
    tmpdir=$(mktemp -d) || return 1
    if ! curl -fsSL --max-time 10 "$_REPO_RAW_URL" -o "${tmpdir}/startos-admin.sh" 2>/dev/null; then
        rm -rf "$tmpdir"
        return 1
    fi
    curl -fsSL --max-time 10 "${_REPO_RAW_URL}.asc" -o "${tmpdir}/startos-admin.sh.asc" 2>/dev/null || curl_rc=$?
    if [[ $curl_rc -ne 0 ]]; then
        rm -rf "$tmpdir"
        # 22 = the server answered with an error: the script is published
        # without a signature. Anything else is a network problem.
        [[ $curl_rc -eq 22 ]] && return 2
        return 1
    fi
    if ! _gpg_verify_release "${tmpdir}/startos-admin.sh" "${tmpdir}/startos-admin.sh.asc" "$tmpdir"; then
        rm -rf "$tmpdir"
        return 2
    fi
    _fvs_path="${tmpdir}/startos-admin.sh"
}

# _gpg_verify_release <file> <signature.asc> <workdir>
# True only if <signature.asc> is a good signature of <file> by the
# primary key _UPDATE_GPG_FPR. Uses gpgv with a keyring holding only that
# key, so nothing in root's own GnuPG keyring is trusted or touched.
_gpg_verify_release() {
    local file="$1" sig="$2" work="$3"
    if ! command -v gpgv >/dev/null 2>&1; then
        echo "gpgv is not installed, so the release signature can't be checked." >&2
        return 1
    fi
    # Dearmor: drop the armor lines, any header lines, blank lines and the
    # "=XXXX" checksum line, then decode the base64 body.
    printf '%s\n' "$_UPDATE_GPG_KEY" \
        | sed -e '/^-----/d' -e '/: /d' -e '/^[[:space:]]*$/d' -e '/^=/d' \
        | base64 -d > "${work}/release-key.gpg" 2>/dev/null || return 1
    local status
    status=$(gpgv --homedir "$work" --status-fd 1 --keyring "${work}/release-key.gpg" \
                  "$sig" "$file" 2>/dev/null) || return 1
    # VALIDSIG <signing-key fpr> ... <primary-key fpr> (last field)
    echo "$status" | awk -v fpr="$_UPDATE_GPG_FPR" \
        '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && $NF == fpr { ok = 1 } END { exit !ok }'
}

# Compute the HMAC-SHA256 of a config-backup ciphertext (hex output).
# The MAC key is derived one-way from the passphrase via stdin so the
# passphrase itself never appears on a command line.
# Usage: _backup_hmac "passphrase" "ciphertext-b64"
_backup_hmac() {
    local hmac_key
    hmac_key=$(printf '%s' "$1" | openssl dgst -sha256 -hmac "startos-admin-backup-v2" -r | awk '{print $1}')
    printf '%s' "$2" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${hmac_key}" -r | awk '{print $1}'
}

# ─────────────────────────────────────────────
# Staged Changes (batch apply with one restart)
# ─────────────────────────────────────────────
# Each staged change is a block of fully-expanded shell commands — the exact
# text the chroot-and-upgrade shell should execute — preceded by a marker line
# "### STAGE: <label> | <timestamp>".

# Number of staged change blocks in the queue.
_staged_count() {
    local c
    c=$(sudo grep -c '^### STAGE: ' "$_STAGED_FILE" 2>/dev/null) || true
    echo "${c:-0}"
}

# Print staged changes, one per line: "<n>. <label> | <timestamp>"
_staged_labels() {
    sudo grep '^### STAGE: ' "$_STAGED_FILE" 2>/dev/null | sed 's/^### STAGE: //' | nl -w2 -s'. '
}

# Append a change block to the queue.
_stage_change() {
    local label="$1" commands="$2"
    local ts
    ts=$(date '+%Y.%m.%d %H:%M:%S %Z')
    sudo mkdir -p "$_SECRET_DIR"
    sudo chmod 700 "$_SECRET_DIR"
    { printf '### STAGE: %s | %s\n' "$label" "$ts"; printf '%s\n' "$commands"; } \
        | sudo tee -a "$_STAGED_FILE" >/dev/null
    sudo chmod 600 "$_STAGED_FILE"
}

_staged_clear() {
    sudo rm -f "$_STAGED_FILE"
}

# Remove staged blocks by 1-based indices (comma-separated, pre-validated).
_staged_delete() {
    local indices="$1" tmp
    tmp=$(mktemp)
    # shellcheck disable=SC2024  # redirect target is our own mktemp file; sudo is only needed to READ the root-owned queue
    sudo awk -v del="$indices" '
        BEGIN { n=split(del,a,","); for(i=1;i<=n;i++) skip[a[i]]=1; blk=0 }
        /^### STAGE: / { blk++ }
        !(blk in skip) { print }
    ' "$_STAGED_FILE" > "$tmp"
    if [[ -s "$tmp" ]]; then
        sudo cp "$tmp" "$_STAGED_FILE"
        sudo chmod 600 "$_STAGED_FILE"
    else
        _staged_clear
    fi
    rm -f "$tmp"
}

# Run all staged blocks (+optional extra block) in ONE chroot session.
# Blocks are stored fully expanded, so they are piped to the chroot shell
# verbatim — never through an unquoted heredoc (no double expansion).
# Clears the queue on success. Returns the chroot exit code.
_staged_run_chroot() {
    local extra="${1:-}"
    local all
    all=$(sudo cat "$_STAGED_FILE" 2>/dev/null) || true
    if [[ -n "$extra" ]]; then
        [[ -n "$all" ]] && all+=$'\n'
        all+="$extra"
    fi
    all+=$'\n'"$_SECRET_SWEEP_CMDS"
    local chroot_exit=0
    printf '%s\nexit\n' "$all" | sudo /usr/lib/startos/scripts/chroot-and-upgrade || chroot_exit=$?
    debug_log "chroot-and-upgrade exit: $chroot_exit"
    if [[ $chroot_exit -eq 0 ]]; then
        _staged_clear
    fi
    return $chroot_exit
}

# Chooser shown at the end of every mutating flow.
# $1 = human-readable label, $2 = fully-expanded command block.
# Returns 0 if applied or staged; 1 on cancel/back (callers: || return 1).
_apply_or_stage() {
    local label="$1" cmds="$2"
    local pending
    pending=$(_staged_count)

    echo ""
    echo -e "  ${BOLD}How do you want to apply this change?${NC}"
    if [[ $pending -gt 0 ]]; then
        echo -e "    ${BOLD}1)${NC} Apply now — includes your ${pending} staged change(s)  ${DIM}(server restarts)${NC}"
    else
        echo -e "    ${BOLD}1)${NC} Apply now  ${DIM}(server restarts)${NC}"
    fi
    echo -e "    ${BOLD}2)${NC} Stage for later  ${DIM}(apply several changes with one restart)${NC}"
    echo ""
    echo -e "    ${DIM}0) Cancel${NC}"
    echo ""

    local aos_choice
    while true; do
        _read aos_choice "  Choice [1/2/0]: " || return 1
        case "$aos_choice" in
            1)
                _warn_restart "after the change(s) are applied."
                if ! confirm "Proceed? (server will restart automatically)"; then
                    [[ $_BACK -eq 1 ]] && return 1
                    print_info "Cancelled."
                    return 1
                fi
                print_success "Applying. Entering persistence mode now."
                echo ""
                local chroot_exit=0
                _staged_run_chroot "$cmds" || chroot_exit=$?
                if [[ $chroot_exit -eq 0 ]]; then
                    print_success "Applied: ${label}"
                    [[ $pending -gt 0 ]] && print_success "Also applied ${pending} previously staged change(s)."
                    print_warn "The server will restart shortly — your SSH session will disconnect."
                    return 0
                fi
                print_error "chroot-and-upgrade failed (exit $chroot_exit). Nothing was applied."
                [[ $pending -gt 0 ]] && print_info "Previously staged change(s) remain queued; this change was not staged."
                pause
                return 1
                ;;
            2)
                _stage_change "$label" "$cmds"
                local n
                n=$(_staged_count)
                print_success "Staged: ${label}"
                print_info "${n} change(s) pending — apply from main menu → 9) Staged changes."
                print_warn "Staged changes are NOT active until applied, and are lost if the server reboots first."
                pause
                return 0
                ;;
            0)
                print_info "Cancelled."
                return 1
                ;;
            *) print_warn "Enter 1, 2, or 0." ;;
        esac
    done
}

# Staged-changes management submenu: view, apply all, delete selected.
menu_staged_changes() {
    while true; do
        print_header
        print_section "Staged Changes"
        echo ""
        local n
        n=$(_staged_count)
        if [[ $n -eq 0 ]]; then
            print_info "No staged changes."
            echo -e "  ${DIM}When finishing a change wizard, choose 'Stage for later' to queue it here.${NC}"
            pause; return
        fi

        echo -e "  ${DIM}Staged changes are NOT active until applied. Applying restarts the server once.${NC}"
        echo -e "  ${DIM}The queue survives exiting this script but is lost if the server reboots first.${NC}"
        echo ""
        _staged_labels | while IFS= read -r line; do
            echo -e "  ${CYAN}${line}${NC}"
        done
        echo ""
        echo -e "    ${BOLD}1)${NC} Apply all staged changes  ${DIM}(server restarts)${NC}"
        echo -e "    ${BOLD}2)${NC} Delete staged change(s)"
        echo ""
        echo -e "    ${DIM}0) Back${NC}"
        echo ""

        local sc_choice
        _read sc_choice "  $(echo -e "${BOLD}Choice:${NC} ")" || return 1
        case "$sc_choice" in
            1)
                _warn_restart "after the staged changes are applied."
                if ! confirm "Apply ${n} staged change(s)? (server will restart automatically)"; then
                    [[ $_BACK -eq 1 ]] && return 1
                    print_info "Cancelled."
                    sleep 1; continue
                fi
                print_success "Applying staged changes. Entering persistence mode now."
                echo ""
                local chroot_exit=0
                _staged_run_chroot "" || chroot_exit=$?
                if [[ $chroot_exit -eq 0 ]]; then
                    print_success "Applied ${n} staged change(s)."
                    print_warn "The server will restart shortly — your SSH session will disconnect."
                else
                    print_error "chroot-and-upgrade failed (exit $chroot_exit). Staged changes remain queued."
                fi
                pause; return
                ;;
            2)
                local del_sel
                _read del_sel "  Delete which? [numbers comma-separated, or 'all']: " || return 1
                if [[ "$del_sel" == "all" ]]; then
                    if confirm "Delete ALL ${n} staged change(s)?"; then
                        _staged_clear
                        print_success "All staged changes deleted. (Nothing was applied.)"
                    else
                        [[ $_BACK -eq 1 ]] && return 1
                    fi
                    sleep 1; continue
                fi
                local valid=true sel_clean=()
                IFS=',' read -ra parts <<< "$del_sel"
                local part
                for part in "${parts[@]}"; do
                    part="${part// /}"
                    if [[ "$part" =~ ^[0-9]+$ ]] && (( part >= 1 && part <= n )); then
                        sel_clean+=("$part")
                    else
                        valid=false; break
                    fi
                done
                if ! $valid || [[ ${#sel_clean[@]} -eq 0 ]]; then
                    print_warn "Enter numbers 1-${n} comma-separated, or 'all'."
                    sleep 1; continue
                fi
                local del_csv
                del_csv=$(printf '%s\n' "${sel_clean[@]}" | sort -nu | paste -sd,)
                if confirm "Delete staged change(s) ${del_csv}? (They will never be applied.)"; then
                    _staged_delete "$del_csv"
                    print_success "Deleted."
                else
                    [[ $_BACK -eq 1 ]] && return 1
                fi
                sleep 1
                ;;
            0) return ;;
            *) print_warn "Enter 0-2." ; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Cron Installation (Persistence via chroot-and-upgrade)
# ─────────────────────────────────────────────

# Install a cron job persistently via _apply_or_stage (apply now or stage).
# Builds the merged-crontab command block; values are base64-embedded so the
# block is safe to store and to feed to the chroot shell verbatim.
# Optional $3/$4: path + content of a root-only secret file (e.g. backup
# password) written mode 600 in the same chroot session as the cron line.
install_cron_job() {
    local cron_line="$1"
    local action_label="${2:-startos-admin}"
    local secret_path="${3:-}"
    local secret_value="${4:-}"

    # Duplicate check — active crontab AND the staged queue
    if sudo crontab -u root -l 2>/dev/null | grep -qF "$cron_line"; then
        print_warn "An identical cron job already exists. Skipping install."
        return 0
    fi
    if sudo grep -qF "$cron_line" "$_STAGED_FILE" 2>/dev/null; then
        print_warn "An identical cron job is already staged. Skipping."
        return 0
    fi

    # Build comment line, then base64-encode both comment and cron line so they
    # can be safely embedded in the command block (no quoting issues).
    local install_ts
    install_ts=$(date '+%Y.%m.%d %H:%M:%S %Z')
    local comment_line="# startos-admin v${VERSION} | Added: ${install_ts} | Action: ${action_label}"
    local encoded_comment encoded_line
    encoded_comment=$(printf '%s' "$comment_line" | base64 -w 0)
    encoded_line=$(printf '%s' "$cron_line" | base64 -w 0)

    # Optional secret file — written root-only in the same chroot session.
    local secret_cmds=""
    if [[ -n "$secret_path" ]]; then
        local encoded_secret
        encoded_secret=$(printf '%s' "$secret_value" | base64 -w 0)
        secret_cmds="mkdir -p ${_SECRET_DIR}
chmod 700 ${_SECRET_DIR}
printf '%s' \"${encoded_secret}\" | base64 -d > ${secret_path}
chmod 600 ${secret_path}
"
    fi

    debug_log "Cron entry: $cron_line"
    local cmds="${secret_cmds}{ crontab -l 2>/dev/null; printf '%s' \"${encoded_comment}\" | base64 -d; echo; printf '%s' \"${encoded_line}\" | base64 -d; echo; } | crontab -"
    _apply_or_stage "${action_label}: ${cron_line:0:60}" "$cmds" || return 1
}

# ─────────────────────────────────────────────
# Create StartOS Notification
# ─────────────────────────────────────────────

# Wizard: compose and send a one-time StartOS notification via start-cli.
menu_create_notification() {
    print_header
    print_section "Create StartOS Notification"
    echo ""
    _nav_tip

    # ── Step 1: Select service ───────────────────────────────────────────────
    print_info "Fetching installed services..."
    local pkg_list
    if ! pkg_list=$(start-cli package list 2>&1); then
        print_error "Failed to list packages. Is start-cli authenticated?"
        echo -e "${RED}${pkg_list}${NC}"
        pause; return
    fi

    mapfile -t packages <<< "$(parse_package_ids "$pkg_list")"

    echo ""
    echo -e "  ${BOLD}Select service for notification:${NC}"
    local i=1
    for pkg in "${packages[@]}"; do
        echo -e "    ${BOLD}${i})${NC} ${pkg}"
        (( i++ ))
    done
    echo -e "    ${BOLD}${i})${NC} ${DIM}(blank — no service)${NC}"
    echo ""

    local notif_service=""
    while true; do
        _read svc_choice "  Choice [1-${i}]: " || return 1
        if [[ "$svc_choice" =~ ^[0-9]+$ ]]; then
            if [[ "$svc_choice" -ge 1 && "$svc_choice" -lt "$i" ]]; then
                notif_service="${packages[$((svc_choice - 1))]}"
                break
            elif [[ "$svc_choice" -eq "$i" ]]; then
                notif_service="blank"
                break
            fi
        fi
        print_warn "Enter a number between 1 and ${i}."
    done

    # ── Step 2: Select severity ──────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Select severity level:${NC}"
    echo -e "    ${BOLD}1)${NC} ${CYAN}info${NC}    — informational"
    echo -e "    ${BOLD}2)${NC} ${GREEN}success${NC} — completed successfully"
    echo -e "    ${BOLD}3)${NC} ${YELLOW}warning${NC} — requires attention"
    echo -e "    ${BOLD}4)${NC} ${RED}error${NC}   — something went wrong"
    echo ""
    local notif_level="info"
    while true; do
        _read level_choice "  Choice [1-4, default 1]: " || return 1
        case "${level_choice:-1}" in
            1) notif_level="info";    break ;;
            2) notif_level="success"; break ;;
            3) notif_level="warning"; break ;;
            4) notif_level="error";   break ;;
            *) print_warn "Enter 1, 2, 3, or 4." ;;
        esac
    done

    # ── Step 3: Title & message ──────────────────────────────────────────────
    echo ""
    local notif_title=""
    while [[ -z "$notif_title" ]]; do
        _read notif_title "  Notification title: " || return 1
        [[ -z "$notif_title" ]] && print_warn "Title cannot be empty."
    done

    local notif_body=""
    while [[ -z "$notif_body" ]]; do
        _read notif_body "  Notification message: " || return 1
        [[ -z "$notif_body" ]] && print_warn "Message cannot be empty."
    done

    # ── Execute ──────────────────────────────────────────────────────────────
    echo ""
    local svc_display="${notif_service:-"(blank)"}"
    print_info "Creating [$notif_level] notification for ${svc_display}: \"$notif_title\""
    echo ""

    debug_log "Calling: start-cli notification create '${notif_service}' '$notif_level' '$notif_title' '...'"
    local exit_code=0
    local _pkg_args=()
    [[ -n "$notif_service" && "$notif_service" != "blank" ]] && _pkg_args=(--package "$notif_service")
    start-cli notification create "${_pkg_args[@]}" "$notif_level" "$notif_title" "$notif_body" 2>&1 \
        || exit_code=$?
    debug_log "start-cli exit: $exit_code"

    if [[ $exit_code -eq 0 ]]; then
        print_success "Notification created."
    else
        print_error "Command failed (exit $exit_code)."
    fi

    pause
}

# ─────────────────────────────────────────────
# Display Disk Used by Service
# ─────────────────────────────────────────────

# Display total disk stats and per-service disk usage breakdown.
menu_disk_usage() {
    print_header
    print_section "Disk Usage"
    echo ""

    # ── Disk summary ─────────────────────────────────────────────────────────
    print_info "Fetching disk summary..."
    local df_output df_exit=0
    df_output=$(df -h /media/startos/data/package-data/volumes/ 2>&1) || df_exit=$?

    if [[ $df_exit -eq 0 ]]; then
        local df_size df_used df_avail df_pct
        df_size=$(echo  "$df_output" | awk 'NR==2 {print $2}')
        df_used=$(echo  "$df_output" | awk 'NR==2 {print $3}')
        df_avail=$(echo "$df_output" | awk 'NR==2 {print $4}')
        df_pct=$(echo   "$df_output" | awk 'NR==2 {print $5}' | tr -d '%')

        local pct_color="$GREEN"
        [[ "$df_pct" -ge 60 ]] 2>/dev/null && pct_color="$YELLOW"
        [[ "$df_pct" -ge 80 ]] 2>/dev/null && pct_color="$RED"

        echo -e "  ${BOLD}Total:${NC}     ${df_size}"
        echo -e "  ${BOLD}Used:${NC}      ${pct_color}${df_used} (${df_pct}%)${NC}"
        echo -e "  ${BOLD}Available:${NC} ${df_avail}"
        echo ""
    fi

    # ── Per-service breakdown ─────────────────────────────────────────────────
    print_section "Usage by Service"
    echo ""

    # du exits non-zero if a file vanishes mid-scan (e.g. btcpayserver's Postgres
    # temp relation files churn constantly), yet still prints correct totals for
    # every volume. Discard the transient stderr and judge success by output
    # presence, not exit code — matching _cli_disk below.
    local raw_output
    raw_output=$(sudo du -hd 1 /media/startos/data/package-data/volumes/ 2>/dev/null)
    if [[ -z "$raw_output" ]]; then
        print_error "Failed to read disk usage."
        pause; return
    fi

    # Sort largest first (sort -rh handles K/M/G/T), then color-code the output
    while IFS= read -r line; do
        local size_field
        size_field=$(echo "$line" | awk '{print $1}')
        # Extract numeric value and unit
        local num unit
        num=$(echo "$size_field" | sed 's/[A-Za-z]//g')
        unit=$(echo "$size_field" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')

        if [[ "$unit" == "G" ]] || [[ "$unit" == "T" ]]; then
            echo -e "  ${RED}${BOLD}${line}${NC}"
        elif [[ "$unit" == "M" && "${num%%.*}" =~ ^[0-9]+$ ]] && (( ${num%%.*} >= 100 )); then
            echo -e "  ${YELLOW}${line}${NC}"
        else
            echo -e "  ${line}"
        fi
    done <<< "$(echo "$raw_output" | sort -rh)"

    echo ""
    echo -e "  ${DIM}(Red = ≥ 1G, Yellow = ≥ 100M)${NC}"
    pause
}

# ─────────────────────────────────────────────
# Display Memory Used by Service
# ─────────────────────────────────────────────

# Format `start-cli package stats` output: strip table borders, drop the
# Container ID column, sort by usage % descending.
# $1 = raw stats output; $2-$5 = red, yellow, nc, bold (empty = plain output).
_format_pkg_stats() {
    echo "$1" | awk -v red="${2:-}" -v yellow="${3:-}" -v nc="${4:-}" -v bold="${5:-}" '
    BEGIN { FS="|"; rc=0 }
    /^\+/ { next }
    /^\|/ {
        n = $2; gsub(/^[ \t]+|[ \t]+$/, "", n)
        u = $4; gsub(/^[ \t]+|[ \t]+$/, "", u)
        l = $5; gsub(/^[ \t]+|[ \t]+$/, "", l)
        p = $6; gsub(/^[ \t]+|[ \t]+$/, "", p)
        if (n == "Name") {
            printf "%s  %-22s %-12s %-14s %s%s\n", bold, n, u, l, p, nc
            printf "  %-22s %-12s %-14s %s\n", "──────────────────────", "──────────", "────────────", "────────"
        } else if (n != "") {
            rc++; ns[rc]=n; us[rc]=u; ls[rc]=l; ps[rc]=p; pn[rc]=p+0
        }
    }
    END {
        for (i=1; i<=rc; i++) for (j=i+1; j<=rc; j++) if (pn[j]>pn[i]) {
            tmp=ns[i]; ns[i]=ns[j]; ns[j]=tmp
            tmp=us[i]; us[i]=us[j]; us[j]=tmp
            tmp=ls[i]; ls[i]=ls[j]; ls[j]=tmp
            tmp=ps[i]; ps[i]=ps[j]; ps[j]=tmp
            tmp=pn[i]; pn[i]=pn[j]; pn[j]=tmp
        }
        for (i=1; i<=rc; i++) {
            if (pn[i]>=80)      color=bold red
            else if (pn[i]>=60) color=yellow
            else                color=nc
            printf "%s  %-22s %-12s %-14s %s%s\n", color, ns[i], us[i], ls[i], ps[i], nc
        }
    }'
}

# Display per-service memory usage and percentage of total RAM via start-cli package stats.
menu_memory_usage() {
    print_header
    print_section "Memory Used by Service"
    echo ""
    print_info "Running: start-cli package stats"
    debug_log "Running: start-cli package stats"
    echo ""

    local stats_output exit_code=0
    stats_output=$(start-cli package stats 2>&1) || exit_code=$?
    debug_log "start-cli package stats exit: $exit_code"

    if [[ $exit_code -ne 0 ]]; then
        print_error "Command failed (exit $exit_code)."
        echo -e "${RED}${stats_output}${NC}"
        pause; return
    fi

    _format_pkg_stats "$stats_output" "$RED" "$YELLOW" "$NC" "$BOLD"
    echo ""
    pause
}

# ─────────────────────────────────────────────
# Manage Cron Jobs
# ─────────────────────────────────────────────

# Interactive submenu: view/delete existing cron entries or add a new one.
_cron_manage_flow() {
    while true; do
        print_header
        print_section "View / Edit Cron Jobs"
        echo ""
        local _cm_pending
        _cm_pending=$(_staged_count)
        if [[ $_cm_pending -gt 0 ]]; then
            print_warn "${_cm_pending} staged change(s) pending — not reflected below until applied."
            echo ""
        fi

        local cron_output exit_code=0
        cron_output=$(sudo crontab -u root -l 2>&1) || exit_code=$?

        if [[ $exit_code -ne 0 ]]; then
            if echo "$cron_output" | grep -qi "no crontab for"; then
                print_info "No cron jobs are currently scheduled."
            else
                print_error "Failed to read root crontab (exit $exit_code)."
                echo -e "${RED}${cron_output}${NC}"
            fi
            pause; return
        fi

        if [[ -z "$cron_output" ]]; then
            print_info "No cron jobs are currently scheduled."
            pause; return
        fi

        # Display crontab — comments dimmed; active entries numbered cyan; disabled entries numbered yellow
        # Disabled cron lines: start with # followed immediately by a cron char (*, /, digit)
        local -a cron_lines=()
        local -a cron_line_nums=()
        local -a cron_active=()
        local linenum=0
        while IFS= read -r line; do
            linenum=$(( linenum + 1 ))
            if [[ "$line" =~ ^#[*/0-9] ]]; then
                # Disabled cron entry — strip leading # for display
                cron_lines+=("${line#\#}")
                cron_line_nums+=("$linenum")
                cron_active+=(0)
                echo -e "  ${YELLOW}${BOLD}${#cron_lines[@]})${NC} ${DIM}[disabled] ${line#\#}${NC}"
            elif [[ "$line" =~ ^# ]]; then
                # Metadata comment — show dimmed, not numbered
                echo -e "  ${DIM}${line}${NC}"
            elif [[ -n "$line" ]]; then
                # Active cron entry
                cron_lines+=("$line")
                cron_line_nums+=("$linenum")
                cron_active+=(1)
                echo -e "  ${CYAN}${BOLD}${#cron_lines[@]})${NC} ${CYAN}${line}${NC}"
            fi
        done <<< "$cron_output"

        echo ""

        if [[ ${#cron_lines[@]} -eq 0 ]]; then
            pause; return
        fi

        echo -e "  ${DIM}Enter number(s) (comma-separated or 'all'), or 0 to go back.${NC}"
        echo ""
        _read sel_choice "  Select: " || return 1

        if [[ "$sel_choice" == "0" ]]; then
            return
        fi

        # Parse selection into array of 0-based indices into cron_lines
        local -a selected_indices=()
        if [[ "$sel_choice" == "all" ]]; then
            local j
            for (( j=0; j<${#cron_lines[@]}; j++ )); do
                selected_indices+=("$j")
            done
        else
            local valid=true
            IFS=',' read -ra parts <<< "$sel_choice"
            for part in "${parts[@]}"; do
                part="${part// /}"
                if [[ "$part" =~ ^[0-9]+$ ]] && \
                   [[ "$part" -ge 1 ]] && [[ "$part" -le "${#cron_lines[@]}" ]]; then
                    selected_indices+=("$((part - 1))")
                else
                    valid=false; break
                fi
            done
            if ! $valid || [[ "${#selected_indices[@]}" -eq 0 ]]; then
                print_warn "Enter valid number(s) between 1 and ${#cron_lines[@]}, comma-separated, 'all', or 0 to go back."
                sleep 1
                continue
            fi
        fi

        # Action prompt
        echo ""
        echo -e "  ${DIM}Action:  [d]elete  [c]omment out  [e]nable${NC}"
        echo ""
        local action_key
        while true; do
            _read action_key "  Action [d/c/e]: " || return 1
            case "${action_key,,}" in
                d|delete)  action_key="d"; break ;;
                c|comment) action_key="c"; break ;;
                e|enable)  action_key="e"; break ;;
                *) print_warn "Enter d (delete), c (comment out), or e (enable)." ;;
            esac
        done

        # Validate action against entry state
        local bad=false
        for idx in "${selected_indices[@]}"; do
            if [[ "$action_key" == "c" && "${cron_active[$idx]}" -eq 0 ]]; then
                print_warn "Entry $((idx+1)) is already disabled — cannot comment out."
                bad=true; break
            fi
            if [[ "$action_key" == "e" && "${cron_active[$idx]}" -eq 1 ]]; then
                print_warn "Entry $((idx+1)) is already active — cannot enable."
                bad=true; break
            fi
        done
        $bad && { sleep 1; continue; }

        # Build content-based command blocks (exact-line matching) so cron
        # edits compose correctly when staged alongside other changes —
        # line numbers would shift, exact text does not.
        # cron_lines[] holds stripped text for disabled entries; the actual
        # crontab line for those is "#" + text.
        local cmds=""
        echo ""
        local action_verb
        case "$action_key" in
            d) action_verb="delete" ;;
            c) action_verb="comment out" ;;
            e) action_verb="enable" ;;
        esac
        print_warn "This will ${action_verb}:"
        for idx in "${selected_indices[@]}"; do
            local target_linenum="${cron_line_nums[$idx]}"
            local target_line="${cron_lines[$idx]}"
            local actual_line="$target_line"
            [[ "${cron_active[$idx]}" -eq 0 ]] && actual_line="#${target_line}"
            local b64_actual b64_target
            b64_actual=$(printf '%s' "$actual_line" | base64 -w 0)
            b64_target=$(printf '%s' "$target_line" | base64 -w 0)

            case "$action_key" in
                d)
                    # Also remove the preceding metadata comment, if any
                    # (but never a disabled cron entry sitting above).
                    local prev_linenum=$(( target_linenum - 1 ))
                    local prev_line=""
                    [[ $prev_linenum -gt 0 ]] && prev_line=$(echo "$cron_output" | sed -n "${prev_linenum}p")
                    if [[ "$prev_line" =~ ^# && ! "$prev_line" =~ ^#[*/0-9] ]]; then
                        local b64_prev
                        b64_prev=$(printf '%s' "$prev_line" | base64 -w 0)
                        cmds+="__t=\$(printf '%s' \"${b64_prev}\" | base64 -d); crontab -l 2>/dev/null | grep -vxF \"\$__t\" | crontab -
"
                        echo -e "  ${DIM}${prev_line}${NC}"
                    fi
                    cmds+="__t=\$(printf '%s' \"${b64_actual}\" | base64 -d); crontab -l 2>/dev/null | grep -vxF \"\$__t\" | crontab -
"
                    ;;
                c)
                    cmds+="__t=\$(printf '%s' \"${b64_actual}\" | base64 -d); crontab -l 2>/dev/null | while IFS= read -r __l; do if [ \"\$__l\" = \"\$__t\" ]; then printf '#%s\n' \"\$__l\"; else printf '%s\n' \"\$__l\"; fi; done | crontab -
"
                    ;;
                e)
                    cmds+="__t=\$(printf '%s' \"${b64_target}\" | base64 -d); crontab -l 2>/dev/null | while IFS= read -r __l; do if [ \"\$__l\" = \"#\$__t\" ]; then printf '%s\n' \"\$__t\"; else printf '%s\n' \"\$__l\"; fi; done | crontab -
"
                    ;;
            esac
            echo -e "  ${CYAN}${target_line}${NC}"
        done
        echo ""

        local confirm_msg label_verb
        case "$action_key" in
            d) confirm_msg="Delete the selected cron job(s)?";              label_verb="Delete" ;;
            c) confirm_msg="Comment out (disable) the selected cron job(s)?"; label_verb="Disable" ;;
            e) confirm_msg="Enable (uncomment) the selected cron job(s)?";   label_verb="Enable" ;;
        esac

        if ! confirm "$confirm_msg"; then
            [[ $_BACK -eq 1 ]] && return 1
            print_info "Cancelled."
            sleep 1
            continue
        fi

        local aos_label
        if [[ ${#selected_indices[@]} -eq 1 ]]; then
            aos_label="${label_verb} cron entry: ${cron_lines[${selected_indices[0]}]:0:50}"
        else
            aos_label="${label_verb} ${#selected_indices[@]} cron entries"
        fi
        _apply_or_stage "$aos_label" "$cmds" || return 1
        return
    done
}

# Cron runs on the server's clock, which on StartOS is UTC, not the user's
# local time: "45 21 * * *" fires at 21:45 UTC (5:45 PM in New York in
# summer). Say so wherever a schedule is picked, with the current server time
# to convert from.
_cron_clock_note() {
    echo -e "  ${YELLOW}Times are server time (${NC}${BOLD}$(date '+%Z')${NC}${YELLOW}), not your local time. The server's clock reads ${NC}${BOLD}$(date '+%H:%M %Z')${NC}${YELLOW} now.${NC}"
}

# Validate a 5-field cron expression. Returns 0 if valid, 1 with message if not.
_validate_cron_expr() {
    local expr="$1"
    local -a fields
    read -ra fields <<< "$expr"

    if [[ "${#fields[@]}" -ne 5 ]]; then
        print_warn "Cron expression must have exactly 5 fields: minute hour day-of-month month day-of-week"
        return 1
    fi

    local -a names=("minute(0-59)" "hour(0-23)" "day-of-month(1-31)" "month(1-12)" "day-of-week(0-7)")
    local -a mins=(0 0 1 1 0)
    local -a maxs=(59 23 31 12 7)

    local f
    for f in 0 1 2 3 4; do
        local field="${fields[$f]}"
        if ! [[ "$field" =~ ^[0-9*,/\-]+$ ]]; then
            print_warn "Field $((f+1)) (${names[$f]}): invalid characters in '${field}'. Allowed: digits * / - ,"
            return 1
        fi
        if [[ "$field" =~ ^[0-9]+$ ]]; then
            if [[ "$field" -lt "${mins[$f]}" ]] || [[ "$field" -gt "${maxs[$f]}" ]]; then
                print_warn "Field $((f+1)) (${names[$f]}): $field is out of range (${mins[$f]}–${maxs[$f]})."
                return 1
            fi
        fi
    done
    return 0
}

# Interactive flow to add a custom cron job (schedule + command + optional post-actions).
_cron_add_flow() {
    print_header
    print_section "Add a Cron Job"
    echo ""
    _nav_tip

    # ── Step 1: Schedule ─────────────────────────────────────────────────────
    echo -e "  ${BOLD}Step 1 of 3 — Schedule${NC}"
    echo -e "  ${DIM}Fields: minute(0-59)  hour(0-23)  day-of-month(1-31)  month(1-12)  day-of-week(0-7)${NC}"
    echo -e "  ${DIM}Use * for 'every', / for step (e.g. */5), - for range, , for list.${NC}"
    echo -e "  ${DIM}Example: 0 3 * * *   (daily at 03:00 server time)${NC}"
    _cron_clock_note
    echo -e "  ${DIM}Use ${CYAN}https://crontab.guru/${NC}${DIM} to build or verify your expression.${NC}"
    echo ""
    local cron_schedule=""
    while true; do
        _read cron_schedule "  Schedule: " || return 1
        [[ -z "$cron_schedule" ]] && { print_warn "Schedule cannot be empty."; continue; }
        _validate_cron_expr "$cron_schedule" && break
    done

    # ── Step 2: Command ──────────────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Step 2 of 3 — Command${NC}"
    echo ""
    local cron_cmd=""
    while true; do
        _read cron_cmd "  Command: " || return 1
        [[ -z "$cron_cmd" ]] && { print_warn "Command cannot be empty."; continue; }
        _check_cron_percent "$cron_cmd" || continue
        local syntax_err
        if ! syntax_err=$(bash -nc "$cron_cmd" 2>&1); then
            print_warn "Possible syntax error: $syntax_err"
            if confirm "Use this command anyway?"; then
                [[ $_BACK -eq 1 ]] && return 1
                break
            else
                [[ $_BACK -eq 1 ]] && return 1
                continue
            fi
        fi
        break
    done

    # ── Step 3: Post-command actions ─────────────────────────────────────────
    local notif_cmd=""
    _pick_post_action "Step 3 of 3 — Post-command actions:" notif_cmd || return 1

    local full_line="$cron_schedule $cron_cmd"
    [[ -n "$notif_cmd" ]] && full_line+=" && $notif_cmd"

    # ── Preview + confirm ────────────────────────────────────────────────────
    echo ""
    print_section "Review Cron Job"
    echo ""
    echo -e "  ${BOLD}Schedule:${NC}  $cron_schedule"
    echo -e "  ${BOLD}Command:${NC}   $cron_cmd"
    [[ -n "$notif_cmd" ]] && echo -e "  ${BOLD}Notify:${NC}    $notif_cmd"
    echo ""
    echo -e "  ${DIM}Cron line to install:${NC}"
    echo -e "  ${DIM}${full_line}${NC}"
    echo ""

    if confirm "Run this command once now to test it?"; then
        [[ $_BACK -eq 1 ]] && return 1
        echo ""
        print_info "Running: $cron_cmd"
        echo ""
        local run_exit=0
        bash -c "$cron_cmd" || run_exit=$?
        echo ""
        if [[ $run_exit -eq 0 ]]; then
            print_success "Command exited 0."
        else
            print_warn "Command exited $run_exit."
        fi
        echo ""
    fi

    if ! confirm "Install this cron job?"; then
        [[ $_BACK -eq 1 ]] && return 1
        print_info "Cancelled."
        pause; return
    fi

    install_cron_job "$full_line" "Add Cron Job" || return 1
    # NOTE: server restarts after this — nothing below executes
}

# Top-level submenu for cron job management
menu_manage_crontab() {
    while true; do
        print_header
        print_section "Manage Cron Jobs"
        echo ""
        echo -e "    ${CYAN}${BOLD}1)${NC} View / edit cron jobs"
        echo -e "    ${CYAN}${BOLD}2)${NC} Add a cron job"
        echo ""
        echo -e "    ${DIM}0) Back${NC}"
        echo ""
        _read sub_choice "  $(echo -e "${BOLD}Choice:${NC} ")" || return 1
        case "$sub_choice" in
            1) _cron_manage_flow || return 1 ;;
            2) _cron_add_flow    || return 1 ;;
            0) return ;;
            *) print_warn "Enter 0-2." ; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Schedule Backups
# ─────────────────────────────────────────────

# Returns a cron schedule string, sets global CRON_SCHEDULE
# Optional first arg: current schedule string. If provided, adds a "5) Keep current" option.
_pick_backup_schedule() {
    local _pbs_def="${1:-}"
    echo ""
    echo -e "  ${BOLD}Select backup schedule:${NC}"
    _cron_clock_note
    local _pbs_tz; _pbs_tz=$(date '+%Z')
    echo -e "    ${BOLD}1)${NC} Daily at 00:00 ${_pbs_tz}       ${DIM}(0 0 * * *)${NC}"
    echo -e "    ${BOLD}2)${NC} Daily at 03:00 ${_pbs_tz}       ${DIM}(0 3 * * *)${NC}"
    echo -e "    ${BOLD}3)${NC} Weekly (Sun 00:00 ${_pbs_tz})   ${DIM}(0 0 * * 0)${NC}"
    echo -e "    ${BOLD}4)${NC} Custom cron expression"
    [[ -n "$_pbs_def" ]] && echo -e "    ${BOLD}5)${NC} Keep current          ${DIM}(${_pbs_def})${NC}"
    echo ""

    while true; do
        _read sched_choice "  Choice [1-4${_pbs_def:+/5}]: " || return 1
        case "$sched_choice" in
            1) CRON_SCHEDULE="0 0 * * *";  return 0 ;;
            2) CRON_SCHEDULE="0 3 * * *";  return 0 ;;
            3) CRON_SCHEDULE="0 0 * * 0";  return 0 ;;
            4)
                _read CRON_SCHEDULE "  Enter cron expression (e.g. 0 2 * * 1-5): " || return 1
                if [[ -z "$CRON_SCHEDULE" ]]; then
                    print_warn "Cron expression cannot be empty."
                elif _validate_cron_expr "$CRON_SCHEDULE"; then
                    return 0
                fi
                ;;
            5) [[ -n "$_pbs_def" ]] && { CRON_SCHEDULE="$_pbs_def"; return 0; } ;;&
            *) print_warn "Enter 1-4${_pbs_def:+, or 5 to keep current}." ;;
        esac
    done
}

# Run the backup setup wizard (steps 1–5, preview). Populates namerefs
# full_line_ref, password_ref, and secret_path_ref (root-only file the cron
# line reads the password from). Does NOT install or confirm restart.
# Optional defaults (pass from edit flow): $4=target $5=schedule $6=pkg_ids $7=notif_cmd
#   pkg_ids: empty string = all packages; non-empty = comma-separated IDs.
#   Pass sentinel "__NONE__" for $6 to indicate no package default.
_backup_wizard() {
    local -n _bwfl="$1"
    local -n _bwpw="$2"
    local -n _bwsp="$3"
    local _bw_def_target="${4:-}"
    local _bw_def_sched="${5:-}"
    local _bw_def_pkg="${6-__NONE__}"   # no-colon: distinguish unset from empty ("")
    local _bw_def_notif="${7:-}"
    _nav_tip

    # ── Step 1: Select backup target ────────────────────────────────────────
    print_header
    print_section "Schedule Backups"
    echo ""
    print_info "Fetching backup targets..."
    local raw_targets
    if ! raw_targets=$(start-cli backup target list 2>&1); then
        # Right after a restart StartOS answers "Method not found" until it
        # finishes initializing; _require_running says so instead.
        if _require_running; then
            print_error "Failed to list backup targets."
            echo -e "${RED}${raw_targets}${NC}"
        fi
        pause; return 1
    fi

    mapfile -t targets <<< "$(parse_backup_targets "$raw_targets")"

    [[ -z "${targets[0]:-}" ]] && targets=()
    local _bw_registered=0
    _backup_targets_registered && _bw_registered=1
    if [[ ${#targets[@]} -eq 0 ]]; then
        if [[ $_bw_registered -eq 1 ]]; then
            print_warn "No backup targets found. Add one in the StartOS web interface first (System → Backups)."
        else
            print_warn "No backup targets found. Add a target in the StartOS UI first."
        fi
        pause; return 1
    fi

    echo ""
    echo -e "  ${BOLD}Select backup target:${NC}"
    local i=1
    for tgt in "${targets[@]}"; do
        echo -e "    ${BOLD}${i})${NC} ${tgt}"
        (( i++ ))
    done
    if [[ $_bw_registered -eq 1 ]]; then
        echo -e "  ${DIM}Only targets added in System → Backups are listed. To back up to a drive,${NC}"
        echo -e "  ${DIM}add it there first — a drive that already holds backups keeps them.${NC}"
    fi
    [[ -n "$_bw_def_target" ]] && echo -e "  ${DIM}Current: ${_bw_def_target} — press Enter to keep${NC}"
    echo ""

    local backup_target=""
    while true; do
        _read tgt_choice "  Choice [1-$((i-1))]${_bw_def_target:+, Enter to keep}: " || return 1
        if [[ -z "$tgt_choice" && -n "$_bw_def_target" ]]; then
            backup_target="$_bw_def_target"; break
        fi
        if [[ "$tgt_choice" =~ ^[0-9]+$ ]] && \
           [[ "$tgt_choice" -ge 1 ]] && [[ "$tgt_choice" -lt "$i" ]]; then
            local picked_id
            picked_id=$(echo "${targets[$((tgt_choice - 1))]}" | awk '{print $1}')
            _backup_pick_key "$picked_id" backup_target || { pause; return 1; }
            break
        fi
        print_warn "Enter a number between 1 and $((i-1))${_bw_def_target:+, or Enter to keep current}."
    done

    # A kept pre-0.4.3 drive key ("uuid-<UUID>") no longer works on 0.4.3:
    # switch to the drive's registered id.
    if [[ $_bw_registered -eq 1 && "$backup_target" == uuid-* ]]; then
        local _bw_gid
        if _bw_gid=$(_backup_uuid_to_registered "$backup_target" "$raw_targets"); then
            print_info "This drive is now registered in StartOS as '${_bw_gid}'; the schedule will use that id."
            backup_target="$_bw_gid"
        else
            print_error "StartOS 0.4.3 backs up only to drives added in System → Backups, and this"
            print_error "drive (filesystem UUID ${backup_target#uuid-}) has not been added. Add it there"
            print_error "(its existing backups are kept), then edit this schedule again."
            pause; return 1
        fi
    fi

    # Target key becomes part of a root-owned file path and a cron line —
    # restrict to a safe charset before going any further.
    if ! [[ "$backup_target" =~ ^[A-Za-z0-9._-]+$ ]]; then
        print_error "Backup target '${backup_target}' contains unexpected characters. Aborting."
        pause; return 1
    fi

    # ── Step 2: Password ─────────────────────────────────────────────────────
    echo ""
    print_warn "Enter your StartOS primary password (used for backup encryption)."
    local backup_password=""
    while true; do
        _read_silent backup_password "  Password: " || return 1
        [[ -z "$backup_password" ]] && { print_warn "Password cannot be empty."; continue; }
        break
    done

    # ── Step 3: Select packages ──────────────────────────────────────────────
    echo ""
    print_info "Fetching installed services..."
    local pkg_list
    if ! pkg_list=$(start-cli package list 2>&1); then
        print_error "Failed to list packages."
        echo -e "${RED}${pkg_list}${NC}"
        pause; return 1
    fi

    mapfile -t packages <<< "$(parse_package_ids "$pkg_list")"

    if [[ ${#packages[@]} -eq 0 ]]; then
        print_warn "No packages found."
        pause; return 1
    fi

    echo ""
    echo -e "  ${BOLD}Select packages to back up:${NC}"
    i=1
    for pkg in "${packages[@]}"; do
        echo -e "    ${BOLD}${i})${NC} ${pkg}"
        (( i++ ))
    done
    echo ""
    print_info "Enter numbers separated by commas (e.g. 1,3,4), or 'all' for all packages"
    local _bw_has_pkg_def=0
    if [[ "$_bw_def_pkg" != "__NONE__" ]]; then
        _bw_has_pkg_def=1
        local _bw_pkg_display; [[ -z "$_bw_def_pkg" ]] && _bw_pkg_display="ALL" || _bw_pkg_display="$_bw_def_pkg"
        echo -e "  ${DIM}Current: ${_bw_pkg_display} — press Enter to keep${NC}"
    fi
    echo ""

    local selected_packages=()
    local pkg_ids_arg=""
    while true; do
        _read pkg_selection "  Selection (e.g. 1,3 or 'all'${_bw_has_pkg_def:+, Enter to keep}): " || return 1
        if [[ -z "$pkg_selection" && "$_bw_has_pkg_def" -eq 1 ]]; then
            pkg_ids_arg="$_bw_def_pkg"; break
        fi
        if [[ "$pkg_selection" == "all" ]]; then
            pkg_ids_arg=""
            break
        elif [[ "$pkg_selection" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
            local valid=true
            IFS=',' read -ra indices <<< "$pkg_selection"
            for idx in "${indices[@]}"; do
                if [[ "$idx" -lt 1 ]] || [[ "$idx" -gt "${#packages[@]}" ]]; then
                    print_warn "Index $idx is out of range."
                    valid=false; break
                fi
                selected_packages+=("${packages[$((idx - 1))]}")
            done
            if [[ "$valid" == true ]]; then
                pkg_ids_arg=$(IFS=','; echo "${selected_packages[*]}")
                break
            fi
            selected_packages=()
        else
            print_warn "Enter numbers like 1,3 or 'all'${_bw_has_pkg_def:+, or Enter to keep current}."
        fi
    done

    local packages_display
    [[ -z "$pkg_ids_arg" ]] && packages_display="ALL" || packages_display="$pkg_ids_arg"

    # ── Step 4: Schedule ─────────────────────────────────────────────────────
    local CRON_SCHEDULE
    _pick_backup_schedule "$_bw_def_sched" || return 1

    # ── Step 5: Post-backup notification ────────────────────────────────────
    local notif_cmd=""
    _pick_post_action "Post-backup notification:" notif_cmd "$_bw_def_notif" || return 1

    # ── Build cron line ──────────────────────────────────────────────────────
    # The password is NOT embedded in the cron line. It is written to a
    # root-only file (mode 600) at install time and read at backup time, so it
    # never appears in the crontab, crontab listings, or config exports.
    local pass_path="${_SECRET_DIR}/backup-pass-${backup_target}"
    local backup_cmd
    backup_cmd="${_START_CLI} backup create $(_backup_target_cron_arg "$backup_target") \"\$(cat ${pass_path})\""
    # start-cli takes one --package-ids flag per package; a comma-joined value
    # is rejected as an invalid ID and the backup never runs (issue #1).
    if [[ -n "$pkg_ids_arg" ]]; then
        local _bw_ids _bw_id
        IFS=',' read -ra _bw_ids <<< "$pkg_ids_arg"
        for _bw_id in "${_bw_ids[@]}"; do
            backup_cmd+=" --package-ids ${_bw_id}"
        done
    fi
    _bwfl="$CRON_SCHEDULE $backup_cmd"
    [[ -n "$notif_cmd" ]] && _bwfl+=" && $notif_cmd"
    _bwpw="$backup_password"
    _bwsp="$pass_path"

    # ── Preview ──────────────────────────────────────────────────────────────
    echo ""
    print_section "Review Backup Schedule"
    echo ""
    echo -e "  ${BOLD}Target:${NC}    $backup_target"
    echo -e "  ${BOLD}Packages:${NC}  $packages_display"
    echo -e "  ${BOLD}Schedule:${NC}  $CRON_SCHEDULE  ${DIM}(server time, $(date '+%Z'))${NC}"
    [[ -n "$notif_cmd" ]] && echo -e "  ${BOLD}Notify:${NC}    $notif_cmd"
    echo -e "  ${BOLD}Password:${NC}  stored root-only at ${pass_path} (not in the crontab)"
    echo ""
    echo -e "  ${DIM}Cron line:${NC}"
    echo -e "  ${DIM}${_bwfl}${NC}"
    echo ""
}

_backup_install_flow() {
    print_header
    print_section "Schedule Backups"
    echo ""
    local bw_full_line bw_password bw_secret_path
    _backup_wizard bw_full_line bw_password bw_secret_path || return 1

    if ! confirm "Install this backup schedule?"; then
        [[ $_BACK -eq 1 ]] && return 1
        print_info "Cancelled."
        pause; return
    fi

    install_cron_job "$bw_full_line" "Schedule Backups" "$bw_secret_path" "$bw_password" || return 1
    # NOTE: server restarts after this — nothing below executes
}

_backup_edit_flow() {
    # ── Find existing backup entries ─────────────────────────────────────────
    local cron_output
    cron_output=$(sudo crontab -u root -l 2>/dev/null)
    local -a old_comments=() old_cron_lines=() all_lines
    mapfile -t all_lines <<< "$cron_output"
    local total=${#all_lines[@]} eidx
    for (( eidx=0; eidx<total; eidx++ )); do
        if [[ "${all_lines[$eidx]}" == *"| Action: Schedule Backups"* ]]; then
            old_comments+=("${all_lines[$eidx]}")
            local enext=""
            [[ $((eidx+1)) -lt $total ]] && enext="${all_lines[$((eidx+1))]}"
            old_cron_lines+=("$enext")
        fi
    done

    if [[ ${#old_comments[@]} -eq 0 ]]; then
        print_info "No backup schedules installed."
        pause; return
    fi

    # ── List and pick ────────────────────────────────────────────────────────
    print_header
    print_section "Edit Backup Schedule"
    echo ""
    local ei
    for (( ei=0; ei<${#old_comments[@]}; ei++ )); do
        local e_sched e_target
        e_sched=$(echo "${old_cron_lines[$ei]}" | awk '{print $1,$2,$3,$4,$5}')
        e_target=$(_backup_key_from_cron_line "${old_cron_lines[$ei]}")
        echo -e "  ${BOLD}$((ei+1)))${NC} ${e_sched}  →  ${e_target:-unknown}"
        echo -e "     ${DIM}${old_comments[$ei]}${NC}"
        if _backup_cron_line_has_joined_ids "${old_cron_lines[$ei]}"; then
            echo -e "     ${YELLOW}⚠ This schedule never runs: its package list is comma-joined, which start-cli rejects.${NC}"
            echo -e "     ${YELLOW}  Pick it and save it again to fix it.${NC}"
        fi
        echo ""
    done

    local e_choice
    if [[ ${#old_comments[@]} -eq 1 ]]; then
        e_choice=1
        print_info "Only one backup schedule found — selecting it automatically."
        echo ""
    else
        while true; do
            _read e_choice "  Pick entry to replace [1-${#old_comments[@]}, default 1]: " || return 1
            [[ -z "$e_choice" ]] && e_choice=1
            if [[ "$e_choice" =~ ^[0-9]+$ ]] && \
               [[ "$e_choice" -ge 1 ]] && [[ "$e_choice" -le ${#old_comments[@]} ]]; then
                break
            fi
            print_warn "Enter a number between 1 and ${#old_comments[@]}."
        done
    fi

    local old_comment="${old_comments[$((e_choice-1))]}"
    local old_cron_line="${old_cron_lines[$((e_choice-1))]}"

    # ── Parse defaults from existing entry ───────────────────────────────────
    local def_target def_sched def_pkg def_notif=""
    def_target=$(_backup_key_from_cron_line "$old_cron_line")
    def_sched=$(echo "$old_cron_line" | awk '{print $1,$2,$3,$4,$5}')
    # Collect every --package-ids value into one comma-separated list; none =
    # empty string = all packages. A pre-v70 line holds one comma-joined value,
    # which reads back the same way, so re-saving it repairs it.
    def_pkg=$(_backup_pkg_ids_from_cron_line "$old_cron_line")
    # Extract post-action command (everything after first ' && ')
    if echo "$old_cron_line" | grep -qF ' && '; then
        def_notif=$(echo "$old_cron_line" | awk -F' && ' '{for(i=2;i<=NF;i++) printf "%s%s",$i,(i<NF?" && ":""); print ""}')
    fi

    # ── Run wizard for replacement ───────────────────────────────────────────
    print_header
    print_section "Edit Backup Schedule"
    echo ""
    local bw_full_line bw_password bw_secret_path
    _backup_wizard bw_full_line bw_password bw_secret_path "$def_target" "$def_sched" "$def_pkg" "$def_notif" || return 1

    if ! confirm "Replace existing schedule with this?"; then
        [[ $_BACK -eq 1 ]] && return 1
        print_info "Cancelled."
        pause; return
    fi

    local install_ts
    install_ts=$(date '+%Y.%m.%d %H:%M:%S %Z')
    local new_comment="# startos-admin v${VERSION} | Added: ${install_ts} | Action: Schedule Backups"
    local enc_old_c enc_old_l enc_new_c enc_new_l enc_secret
    enc_old_c=$(printf '%s' "$old_comment"   | base64 -w 0)
    enc_old_l=$(printf '%s' "$old_cron_line" | base64 -w 0)
    enc_new_c=$(printf '%s' "$new_comment"   | base64 -w 0)
    enc_new_l=$(printf '%s' "$bw_full_line"  | base64 -w 0)
    enc_secret=$(printf '%s' "$bw_password"  | base64 -w 0)

    debug_log "Replacing backup schedule. Old comment: $old_comment"
    # old_c/old_l are expanded by the chroot shell at apply time (escaped \$);
    # the encoded values are embedded now.
    local cmds="mkdir -p ${_SECRET_DIR}
chmod 700 ${_SECRET_DIR}
printf '%s' \"${enc_secret}\" | base64 -d > ${bw_secret_path}
chmod 600 ${bw_secret_path}
old_c=\$(printf '%s' \"${enc_old_c}\" | base64 -d)
old_l=\$(printf '%s' \"${enc_old_l}\" | base64 -d)
{ crontab -l 2>/dev/null | grep -vxF \"\$old_c\" | grep -vxF \"\$old_l\"; printf '%s' \"${enc_new_c}\" | base64 -d; echo; printf '%s' \"${enc_new_l}\" | base64 -d; echo; } | crontab -"

    _apply_or_stage "Edit backup schedule: ${bw_full_line:0:60}" "$cmds" || return 1
}

menu_schedule_backup() {
    while true; do
        print_header
        print_section "Schedule Backups"
        echo ""
        echo -e "    ${CYAN}${BOLD}1)${NC} Add a new backup schedule"
        echo -e "    ${CYAN}${BOLD}2)${NC} Edit an existing backup schedule"
        echo ""
        echo -e "    ${DIM}0) Back${NC}"
        echo ""
        _read sub_choice "  $(echo -e "${BOLD}Choice:${NC} ")" || return 1
        case "$sub_choice" in
            1) _backup_install_flow || return 1 ;;
            2) _backup_edit_flow    || return 1 ;;
            0) return ;;
            *) print_warn "Enter 0-2." ; sleep 1 ;;
        esac
    done
}

# Helper: prompt for StartOS notification fields, storing into named variables
_pick_notif_startos() {
    local -n _svc="$1" _lvl="$2" _title="$3" _body="$4"

    # Service selection
    echo ""
    print_info "Fetching installed services for notification..."
    debug_log "Running: start-cli package list"
    local _pkg_list
    if ! _pkg_list=$(start-cli package list 2>&1); then
        print_error "Failed to list packages. Is start-cli authenticated?"
        echo -e "${RED}${_pkg_list}${NC}"
        pause; return 1
    fi
    mapfile -t _pkgs <<< "$(parse_package_ids "$_pkg_list")"
    debug_log "Fetched ${#_pkgs[@]} packages"

    echo ""
    echo -e "  ${BOLD}Notification service:${NC}"
    local _i=1
    for _p in "${_pkgs[@]}"; do
        echo -e "    ${BOLD}${_i})${NC} ${_p}"
        (( _i++ ))
    done
    echo -e "    ${BOLD}${_i})${NC} ${DIM}(blank)${NC}"
    echo ""

    while true; do
        _read _sc "  Choice [1-${_i}]: " || return 1
        if [[ "$_sc" =~ ^[0-9]+$ ]]; then
            if [[ "$_sc" -ge 1 && "$_sc" -lt "$_i" ]]; then
                _svc="${_pkgs[$((  _sc - 1))]}"
                break
            elif [[ "$_sc" -eq "$_i" ]]; then
                _svc="blank"
                break
            fi
        fi
        print_warn "Enter a number between 1 and ${_i}."
    done

    # Level
    echo ""
    echo -e "  ${BOLD}Notification level:${NC}"
    echo -e "    ${BOLD}1)${NC} ${CYAN}info${NC}  ${BOLD}2)${NC} ${GREEN}success${NC}  ${BOLD}3)${NC} ${YELLOW}warning${NC}  ${BOLD}4)${NC} ${RED}error${NC}"
    echo ""
    while true; do
        _read _lc "  Choice [1-4, default 1]: " || return 1
        case "${_lc:-1}" in
            1) _lvl="info";    break ;;
            2) _lvl="success"; break ;;
            3) _lvl="warning"; break ;;
            4) _lvl="error";   break ;;
            *) print_warn "Enter 1, 2, 3, or 4." ;;
        esac
    done

    # Title/body end up inside a cron command line — reject unescaped %.
    echo ""
    while true; do
        _read _title "  Notification title: " || return 1
        _check_cron_percent "$_title" && break
    done
    while true; do
        _read _body "  Notification message: " || return 1
        _check_cron_percent "$_body" && break
    done
}

# Prompt for a post-action shell command (with example, % check, and an
# optional test run). Sets the nameref to the entered command.
# Returns 1 on 'back'/'exit' so callers can propagate with || return 1.
_ppa_read_shell_cmd() {
    local -n _prc_cmd="$1"
    echo -e "  ${DIM}Enter the full command to run. Example:${NC}"
    echo -e "  ${DIM}curl -d \"Backup started\" https://ntfy.sh/Your-Topic${NC}"
    echo -e "  ${DIM}Hint: no need for >/dev/null; avoid bare & (use && to chain commands).${NC}"
    while true; do
        _read _prc_cmd "  Shell command: " || return 1
        [[ -z "$_prc_cmd" ]] && { print_warn "Command cannot be empty."; continue; }
        _check_cron_percent "$_prc_cmd" && break
    done
    echo ""
    local _prc_test
    _read _prc_test "  Test this command now? [y/N]: " || return 1
    if [[ "${_prc_test,,}" == "y" ]]; then
        echo ""
        print_info "Running: $_prc_cmd"
        local _prc_exit=0
        bash -c "$_prc_cmd" || _prc_exit=$?
        echo ""
        if [[ $_prc_exit -eq 0 ]]; then
            print_success "Command exited 0 (success)."
        else
            print_warn "Command exited $_prc_exit. Check the output above before continuing."
        fi
    fi
    return 0
}

# Post-action picker: curl / StartOS notification / both / none.
# $1 = section header text (displayed as bold label)
# $2 = nameref variable to receive the built notif_cmd string (empty = none)
# On return, caller can append notif_cmd to their cron line.
_pick_post_action() {
    local _ppa_header="$1"
    local -n _ppa_notif_cmd="$2"
    local _ppa_def_cmd="${3:-}"

    local _ppa_preview=""
    if [[ -n "$_ppa_def_cmd" ]]; then
        _ppa_preview="${_ppa_def_cmd:0:60}"
        [[ ${#_ppa_def_cmd} -gt 60 ]] && _ppa_preview+="..."
    fi

    echo ""
    echo -e "  ${BOLD}${_ppa_header}${NC}"
    echo -e "    ${BOLD}1)${NC} Shell command"
    echo -e "    ${BOLD}2)${NC} StartOS notification"
    echo -e "    ${BOLD}3)${NC} Both"
    echo -e "    ${BOLD}4)${NC} None"
    [[ -n "$_ppa_def_cmd" ]] && echo -e "    ${BOLD}5)${NC} Keep current  ${DIM}(${_ppa_preview})${NC}"
    echo ""

    local _ppa_mode="" _ppa_cmd=""
    local _ppa_svc="" _ppa_level="" _ppa_title="" _ppa_body=""
    while true; do
        _read _ppa_choice "  Choice [1-4${_ppa_def_cmd:+/5}]: " || return 1
        case "$_ppa_choice" in
            5) [[ -n "$_ppa_def_cmd" ]] && { _ppa_notif_cmd="$_ppa_def_cmd"; return 0; } ;;&
            1)
                _ppa_read_shell_cmd _ppa_cmd || return 1
                _ppa_mode="1"; break ;;
            2)
                _pick_notif_startos _ppa_svc _ppa_level _ppa_title _ppa_body || return 1
                _ppa_mode="2"; break ;;
            3)
                _ppa_read_shell_cmd _ppa_cmd || return 1
                _pick_notif_startos _ppa_svc _ppa_level _ppa_title _ppa_body || return 1
                _ppa_mode="3"; break ;;
            4) _ppa_mode="4"; break ;;
            *) print_warn "Enter 1, 2, 3, or 4${_ppa_def_cmd:+, or 5 to keep current}." ;;
        esac
    done

    # Title/body are single-quote escaped (_sq) so quotes, $, and backticks in
    # user text cannot break out of the generated cron command.
    local _ppa_pkg_flag=""
    [[ -n "$_ppa_svc" && "$_ppa_svc" != "blank" ]] && _ppa_pkg_flag="--package ${_ppa_svc} "
    case "$_ppa_mode" in
        1) _ppa_notif_cmd="${_ppa_cmd}" ;;
        2) _ppa_notif_cmd="${_START_CLI} notification create ${_ppa_pkg_flag}${_ppa_level} $(_sq "$_ppa_title") $(_sq "$_ppa_body")" ;;
        3) _ppa_notif_cmd="${_ppa_cmd} && ${_START_CLI} notification create ${_ppa_pkg_flag}${_ppa_level} $(_sq "$_ppa_title") $(_sq "$_ppa_body")" ;;
        4) _ppa_notif_cmd="" ;;
    esac
}

# ─────────────────────────────────────────────
# Schedule Stay-Alive Curl
# ─────────────────────────────────────────────

menu_schedule_stay_alive() {
    print_header
    print_section "Schedule Stay-Alive Curl"
    echo ""
    echo -e "  Schedule a recurring curl to keep a URL reachable — useful for Tor hidden"
    echo -e "  services, clearnet addresses, or any endpoint that needs periodic pinging."
    echo ""
    _nav_tip
    print_header
    print_section "Schedule Stay-Alive Curl"
    echo ""
    local stay_url=""
    while true; do
        _read stay_url "  URL to curl: " || return 1
        [[ -z "$stay_url" ]] && { print_warn "URL cannot be empty."; continue; }
        _validate_url "$stay_url" && break
    done

    local CRON_SCHEDULE
    _pick_poll_frequency || return 1

    local cron_line="$CRON_SCHEDULE curl -fsS --max-time 10 \"$stay_url\" > /dev/null 2>&1"

    echo ""
    print_section "Review Stay-Alive Job"
    echo ""
    echo -e "  ${BOLD}URL:${NC}      $stay_url"
    echo -e "  ${BOLD}Schedule:${NC} $CRON_SCHEDULE"
    echo ""
    echo -e "  ${DIM}Cron line: ${cron_line}${NC}"
    echo ""

    if confirm "Send a test GET to verify the URL responds?"; then
        [[ $_BACK -eq 1 ]] && return 1
        _test_url_get "$stay_url"
    fi

    if confirm "Run the exact cron command once now to verify it exits 0?"; then
        [[ $_BACK -eq 1 ]] && return 1
        echo ""
        print_info "Running: curl -fsS --max-time 10 \"$stay_url\""
        echo ""
        local test_exit=0
        curl -fsS --max-time 10 "$stay_url" > /dev/null 2>&1 || test_exit=$?
        echo ""
        if   [[ $test_exit -eq 0 ]];  then print_success "curl exited 0 — command will work in cron."
        elif [[ $test_exit -eq 28 ]]; then print_warn "curl timed out after 10s (exit 28)."
        else                               print_warn "curl exited $test_exit — URL may not be reachable."
        fi
        echo ""
    fi

    if ! confirm "Install this cron job?"; then
        [[ $_BACK -eq 1 ]] && return 1
        print_info "Cancelled."
        pause; return
    fi

    install_cron_job "$cron_line" "Schedule Stay-Alive Curl" || return 1
    # NOTE: server restarts after this — nothing below executes
}

# ─────────────────────────────────────────────
# Manage Notification Forwarders
# ─────────────────────────────────────────────

# Prompt for polling frequency, sets $CRON_SCHEDULE
_pick_poll_frequency() {
    echo ""
    echo -e "  ${BOLD}Select check frequency:${NC}"
    _cron_clock_note
    echo -e "    ${BOLD}1)${NC} Every 5 minutes    ${DIM}(*/5 * * * *)${NC}"
    echo -e "    ${BOLD}2)${NC} Every 15 minutes   ${DIM}(*/15 * * * *)${NC}"
    echo -e "    ${BOLD}3)${NC} Every 30 minutes   ${DIM}(*/30 * * * *)${NC}"
    echo -e "    ${BOLD}4)${NC} Hourly             ${DIM}(0 * * * *)${NC}"
    echo -e "    ${BOLD}5)${NC} Custom cron expression"
    echo ""
    while true; do
        _read freq "  Choice [1-5]: " || return 1
        case "$freq" in
            1) CRON_SCHEDULE="*/5 * * * *";  return 0 ;;
            2) CRON_SCHEDULE="*/15 * * * *"; return 0 ;;
            3) CRON_SCHEDULE="*/30 * * * *"; return 0 ;;
            4) CRON_SCHEDULE="0 * * * *";    return 0 ;;
            5)
                _read CRON_SCHEDULE "  Enter cron expression (e.g. 0 2 * * 1-5): " || return 1
                if [[ -z "$CRON_SCHEDULE" ]]; then
                    print_warn "Expression cannot be empty."
                elif _validate_cron_expr "$CRON_SCHEDULE"; then
                    return 0
                fi
                ;;
            *) print_warn "Enter 1 through 5." ;;
        esac
    done
}

# Send a sample message to a webhook URL and display the result. Non-blocking.
# Usage: _test_webhook forwarder-name url
_test_webhook() {
    local pname="$1" url="$2"
    echo ""
    echo -e "  ${DIM}Sending test message to webhook...${NC}"
    local ts_test
    ts_test=$(date '+%Y.%m.%d %H:%M:%S %Z')
    local test_msg="${ts_test}  [${pname}]  [Info]  #0  test  |  Test — This is a test from startos-admin.sh"
    debug_log "curl POST → $url"
    local out exit_code http body
    out=$(curl -s -w "\nHTTP_STATUS:%{http_code}" --max-time 10 -d "$test_msg" "$url" 2>&1)
    exit_code=$?
    http=$(echo "$out" | grep 'HTTP_STATUS:' | cut -d: -f2)
    body=$(echo "$out" | grep -v 'HTTP_STATUS:')
    debug_log "curl exit=$exit_code  http=$http"
    if   [[ $exit_code -eq 28 ]]; then print_warn "Timed out after 10s"
    elif [[ $exit_code -ne 0 ]];  then print_warn "curl failed — exit $exit_code"
    elif [[ "$http" =~ ^2 ]];     then print_success "OK — HTTP $http"
    else                               print_warn "HTTP $http (expected 2xx)"
    fi
    [[ -n "$body" ]] && echo -e "  ${DIM}Response: ${body}${NC}"
    echo ""
}

# Send a GET request to a URL and display the HTTP status + response. Non-blocking.
# Usage: _test_url_get url
_test_url_get() {
    local url="$1"
    echo ""
    echo -e "  ${DIM}Sending GET request...${NC}"
    debug_log "curl GET → $url"
    local out exit_code http body
    out=$(curl -s -w "\nHTTP_STATUS:%{http_code}" --max-time 10 "$url" 2>&1)
    exit_code=$?
    http=$(echo "$out" | grep 'HTTP_STATUS:' | cut -d: -f2)
    body=$(echo "$out" | grep -v 'HTTP_STATUS:')
    debug_log "curl exit=$exit_code  http=$http"
    if   [[ $exit_code -eq 28 ]]; then print_warn "Timed out after 10s"
    elif [[ $exit_code -ne 0 ]];  then print_warn "curl failed — exit $exit_code"
    elif [[ "$http" =~ ^2 ]];     then print_success "OK — HTTP $http"
    else                               print_warn "HTTP $http (expected 2xx)"
    fi
    [[ -n "$body" ]] && echo -e "  ${DIM}Response: ${body}${NC}"
    echo ""
}

# Fill an array variable with names of installed forwarders (suffix after prefix).
# Returns 1 (with message + pause) if none are installed.
# Usage: _poller_get_names myarray || return 1
_poller_get_names() {
    local -n _pgn_arr="$1"
    local all_scripts=("${_POLLER_BIN_PREFIX}"*)
    if [[ ! -e "${all_scripts[0]}" ]]; then
        print_info "No notification forwarders installed."
        pause; return 1
    fi
    _pgn_arr=()
    local s
    for s in "${all_scripts[@]}"; do
        _pgn_arr+=("${s##${_POLLER_BIN_PREFIX}}")
    done
}

# Read config vars from an installed poller script.
# Usage: _poller_read_config script_path url_ref levels_ref keyword_ref
_poller_read_config() {
    local _prc_path="$1"
    local -n _prc_url="$2" _prc_levels="$3" _prc_keyword="$4"
    _prc_url=$(grep     '^WEBHOOK_URL=' "$_prc_path" 2>/dev/null | cut -d'"' -f2)
    _prc_levels=$(grep  '^LEVELS='      "$_prc_path" 2>/dev/null | cut -d'"' -f2)
    _prc_keyword=$(grep '^KEYWORD='     "$_prc_path" 2>/dev/null | cut -d'"' -f2)
}

# Display installed pollers with their embedded config.
# Returns 1 (with message) if none are installed.
_poller_list_display() {
    local all_scripts=("${_POLLER_BIN_PREFIX}"*)
    if [[ ! -e "${all_scripts[0]}" ]]; then
        print_info "No notification forwarders installed."
        return 1
    fi

    local i=1
    for script in "${all_scripts[@]}"; do
        local pname="${script##${_POLLER_BIN_PREFIX}}"
        local url levels keyword schedule
        _poller_read_config "$script" url levels keyword
        schedule=$(sudo crontab -u root -l 2>/dev/null \
            | grep "^[^#]*${_POLLER_BIN_PREFIX}${pname}" 2>/dev/null \
            | awk '{print $1,$2,$3,$4,$5}')

        local state_file="${_POLLER_STATE_PREFIX}${pname}"
        local state_val
        if [[ -f "$state_file" ]]; then
            state_val=$(cat "$state_file" 2>/dev/null | tr -d '[:space:]')
            state_val="${state_val:-(empty)}"
        else
            state_val="(file not found)"
        fi

        local log_file="${_POLLER_LOG_PREFIX}${pname}.log"
        local log_info
        if [[ -f "$log_file" ]]; then
            local log_lines
            log_lines=$(wc -l < "$log_file" 2>/dev/null || echo "?")
            log_info="${log_file}  (${log_lines} lines)"
        else
            log_info="${log_file}  (not found)"
        fi

        echo -e "  ${CYAN}${BOLD}${i}) ${pname}${NC}"
        echo -e "     ${DIM}URL:        ${NC}${url}"
        echo -e "     ${DIM}Levels:     ${NC}${levels}"
        echo -e "     ${DIM}Keyword:    ${NC}${keyword:-(none)}"
        echo -e "     ${DIM}Schedule:   ${NC}${schedule:-(not found in crontab)}"
        echo -e "     ${DIM}State file: ${NC}${state_file}"
        echo -e "     ${DIM}Last ID:    ${NC}${state_val}"
        echo -e "     ${DIM}Log:        ${NC}${log_info}"
        echo ""
        (( i++ ))
    done
    return 0
}

# Wizard for installing or updating a named poller
_poller_install_flow() {
    print_header
    print_section "Install / Update Notification Forwarder"
    echo ""
    _nav_tip

    # Step 0: Poller name
    local poller_name=""
    while true; do
        _read poller_name "  Forwarder name (e.g. backup-errors): " || return 1
        if [[ -z "$poller_name" ]]; then
            print_warn "Name cannot be empty."
        elif ! [[ "$poller_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
            print_warn "Use only letters, numbers, and hyphens."
        else
            break
        fi
    done

    if [[ -f "${_POLLER_BIN_PREFIX}${poller_name}" ]]; then
        print_warn "A forwarder named '${poller_name}' already exists — this will update it."
        if ! confirm "Continue and overwrite?"; then
            [[ $_BACK -eq 1 ]] && return 1
            print_info "Cancelled."
            pause; return
        fi
    fi

    # Step 1: Webhook URL
    echo ""
    local webhook_url=""
    while true; do
        _read webhook_url "  Webhook URL: " || return 1
        [[ -z "$webhook_url" ]] && { print_warn "URL cannot be empty."; continue; }
        _validate_url "$webhook_url" && break
    done

    # Step 2: Level filter
    echo ""
    echo -e "  ${BOLD}Filter by notification level:${NC}"
    echo -e "    ${BOLD}1)${NC} All levels"
    echo -e "    ${BOLD}2)${NC} Warning and above  ${DIM}(warning, error)${NC}"
    echo -e "    ${BOLD}3)${NC} Error only"
    echo -e "    ${BOLD}4)${NC} Custom selection"
    echo ""

    local levels="all"
    while true; do
        _read lvl_choice "  Choice [1-4]: " || return 1
        case "$lvl_choice" in
            1) levels="all";           break ;;
            2) levels="warning,error"; break ;;
            3) levels="error";         break ;;
            4)
                local custom_levels=()
                echo ""
                for lvl_name in info success warning error; do
                    local yn_input
                    _read yn_input "  Include ${lvl_name}? [y/N]: " || return 1
                    [[ "${yn_input,,}" =~ ^y ]] && custom_levels+=("$lvl_name")
                done
                if [[ ${#custom_levels[@]} -eq 0 ]]; then
                    print_warn "No levels selected — defaulting to all."
                    levels="all"
                else
                    levels=$(IFS=','; echo "${custom_levels[*]}")
                fi
                break
                ;;
            *) print_warn "Enter 1, 2, 3, or 4." ;;
        esac
    done

    # Step 3: Keyword filter (optional)
    echo ""
    echo -e "  ${DIM}Case-insensitive. Searches both the notification title and message body.${NC}"
    local keyword=""
    while true; do
        _read keyword "  Keyword filter — forward only if title/message contains (blank = none): " || return 1
        _validate_keyword "$keyword" && break
    done

    # Step 4: Frequency
    local CRON_SCHEDULE
    _pick_poll_frequency || return 1

    # Step 5: Preview
    echo ""
    print_section "Review Notification Forwarder"
    echo ""
    echo -e "  ${BOLD}Name:${NC}     ${poller_name}"
    echo -e "  ${BOLD}URL:${NC}      ${webhook_url}"
    echo -e "  ${BOLD}Levels:${NC}   ${levels}"
    echo -e "  ${BOLD}Keyword:${NC}  ${keyword:-(none)}"
    echo -e "  ${BOLD}Schedule:${NC} ${CRON_SCHEDULE}"
    echo ""
    echo -e "  ${DIM}Script:  ${_POLLER_BIN_PREFIX}${poller_name}${NC}"
    echo -e "  ${DIM}State:   ${_POLLER_STATE_PREFIX}${poller_name}${NC}"
    echo -e "  ${DIM}Log:     ${_POLLER_LOG_PREFIX}${poller_name}.log${NC}"
    echo ""
    echo -e "  ${YELLOW}First-run note:${NC} On first run and after every server reboot, the forwarder"
    echo -e "  silently catches up to the current notification state — nothing is forwarded."
    echo -e "  Only notifications that arrive after the first post-boot cron tick will be sent."
    echo -e "  ${DIM}Notifications during downtime or reboots are not forwarded (known limitation).${NC}"
    echo ""

    local _tw_yn
    _read _tw_yn "  Test this webhook now? [y/N]: " || return 1
    [[ "${_tw_yn,,}" == "y" ]] && _test_webhook "$poller_name" "$webhook_url"

    if ! confirm "Install this forwarder?"; then
        [[ $_BACK -eq 1 ]] && return 1
        print_info "Cancelled."
        pause; return
    fi

    install_notif_poller "$poller_name" "$webhook_url" "$levels" "$keyword" "$CRON_SCHEDULE" || return 1
    # NOTE: server restarts after this — nothing below executes
}

_poller_edit_flow() {
    print_header
    print_section "Edit Notification Forwarder"
    echo ""
    _nav_tip

    local script_names=()
    _poller_get_names script_names || return

    local i=1
    for pname in "${script_names[@]}"; do
        echo -e "    ${BOLD}${i})${NC} ${pname}"
        (( i++ ))
    done
    echo ""

    echo -e "    ${DIM}0) Back${NC}"
    echo ""
    local choice
    while true; do
        _read choice "  Choice [1-$((i-1)), or 0 to go back]: " || return 1
        [[ "$choice" == "0" ]] && return 0
        [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )) && break
        print_warn "Enter a number between 1 and $((i-1)), or 0 to go back."
    done
    local poller_name="${script_names[$((choice-1))]}"
    local script_path="${_POLLER_BIN_PREFIX}${poller_name}"

    # Read current config from installed script
    local cur_url cur_levels cur_keyword cur_schedule
    _poller_read_config "$script_path" cur_url cur_levels cur_keyword
    cur_schedule=$(sudo crontab -u root -l 2>/dev/null \
        | grep "^[^#]*${_POLLER_BIN_PREFIX}${poller_name}" \
        | awk '{print $1,$2,$3,$4,$5}')

    echo ""
    print_section "Editing: ${poller_name}"
    echo -e "  ${DIM}Press Enter to keep current value.${NC}"
    echo ""

    # Step 1: URL
    echo -e "  ${DIM}Current URL: ${cur_url}${NC}"
    local webhook_url
    while true; do
        _read webhook_url "  New URL [Enter to keep]: " || return 1
        webhook_url="${webhook_url:-$cur_url}"
        [[ -z "$webhook_url" ]] && { print_warn "URL cannot be empty."; continue; }
        _validate_url "$webhook_url" && break
        cur_url=""   # current value failed validation — force a new entry
    done

    # Step 2: Levels
    echo ""
    echo -e "  ${BOLD}Filter by notification level:${NC}"
    echo -e "    ${BOLD}0)${NC} Keep current  ${DIM}(${cur_levels})${NC}"
    echo -e "    ${BOLD}1)${NC} All levels"
    echo -e "    ${BOLD}2)${NC} Warning and above  ${DIM}(warning, error)${NC}"
    echo -e "    ${BOLD}3)${NC} Error only"
    echo -e "    ${BOLD}4)${NC} Custom selection"
    echo ""
    local levels="$cur_levels"
    while true; do
        _read lvl_choice "  Choice [0-4, default 0]: " || return 1
        case "${lvl_choice:-0}" in
            0) break ;;
            1) levels="all";           break ;;
            2) levels="warning,error"; break ;;
            3) levels="error";         break ;;
            4)
                local custom_levels=()
                echo ""
                for lvl_name in info success warning error; do
                    local yn_input
                    _read yn_input "  Include ${lvl_name}? [y/N]: " || return 1
                    [[ "${yn_input,,}" =~ ^y ]] && custom_levels+=("$lvl_name")
                done
                if [[ ${#custom_levels[@]} -eq 0 ]]; then
                    print_warn "No levels selected — keeping current."
                else
                    levels=$(IFS=','; echo "${custom_levels[*]}")
                fi
                break ;;
            *) print_warn "Enter 0, 1, 2, 3, or 4." ;;
        esac
    done

    # Step 3: Keyword
    echo ""
    echo -e "  ${DIM}Current keyword: ${cur_keyword:-(none)}${NC}"
    echo -e "  ${DIM}Case-insensitive. Searches title and message.${NC}"
    local keyword="$cur_keyword"
    if [[ -n "$cur_keyword" ]]; then
        local kw_clear
        _read kw_clear "  Clear keyword filter? [y/N]: " || return 1
        if [[ "${kw_clear,,}" == "y" ]]; then
            keyword=""
        else
            while true; do
                _read keyword "  New keyword [Enter to keep '${cur_keyword}']: " || return 1
                keyword="${keyword:-$cur_keyword}"
                _validate_keyword "$keyword" && break
                cur_keyword=""   # current value failed validation — force a new entry
            done
        fi
    else
        while true; do
            _read keyword "  Keyword filter — forward only if title/message contains (blank = none): " || return 1
            _validate_keyword "$keyword" && break
        done
    fi

    # Step 4: Schedule
    echo ""
    echo -e "  ${DIM}Current schedule: ${cur_schedule:-(not found)}${NC}"
    local sched_keep
    _read sched_keep "  Keep current schedule? [Y/n]: " || return 1
    local CRON_SCHEDULE
    if [[ "${sched_keep,,}" == "n" ]]; then
        _pick_poll_frequency || return 1
    else
        CRON_SCHEDULE="${cur_schedule}"
        [[ -z "$CRON_SCHEDULE" ]] && { print_warn "No current schedule found. Must select new."; _pick_poll_frequency || return 1; }
    fi

    # Step 5: Review + optional test
    echo ""
    print_section "Review Changes: ${poller_name}"
    echo ""
    echo -e "  ${BOLD}URL:${NC}      ${webhook_url}"
    echo -e "  ${BOLD}Levels:${NC}   ${levels}"
    echo -e "  ${BOLD}Keyword:${NC}  ${keyword:-(none)}"
    echo -e "  ${BOLD}Schedule:${NC} ${CRON_SCHEDULE}"
    echo ""

    local _tw_yn
    _read _tw_yn "  Test this webhook now? [y/N]: " || return 1
    [[ "${_tw_yn,,}" == "y" ]] && _test_webhook "$poller_name" "$webhook_url"

    if ! confirm "Apply changes? (server will restart automatically)"; then
        [[ $_BACK -eq 1 ]] && return 1
        print_info "Cancelled."
        pause; return
    fi

    install_notif_poller "$poller_name" "$webhook_url" "$levels" "$keyword" "$CRON_SCHEDULE" || return 1
    # NOTE: server restarts after this — nothing below executes
}

# Install a named poller script + tagged crontab entry via chroot-and-upgrade.
# Re-running with the same name removes the old crontab entry before adding the new one.
install_notif_poller() {
    local name="$1" url="$2" levels="$3" keyword="$4" schedule="$5"

    # Config block — values are expanded NOW (at install time) and embedded in the script.
    # Single-quoted heredoc for the body keeps all runtime $VARs and $() calls literal.
    local config_block
    config_block="#!/bin/bash
# StartOS Notification Forwarder — generated by startos-admin.sh
# Poller: ${name}
# Re-run startos-admin (main menu → 8, Notification forwarders) to update this configuration.
POLLER_NAME=\"${name}\"
WEBHOOK_URL=\"${url}\"
LEVELS=\"${levels}\"
KEYWORD=\"${keyword}\"
STATE_FILE=\"${_POLLER_STATE_PREFIX}${name}\"
LOG_FILE=\"${_POLLER_LOG_PREFIX}${name}.log\"
START_CLI=\"${_START_CLI}\"
LOG_MAX_LINES=25000
DEBUG=0
[ -f ${_STARTOS_DATA_DIR}/debug ] && DEBUG=1
"

    local body_template
    body_template=$(cat << 'POLLER_BODY_END'
# Cron runs with a minimal PATH — ensure standard locations are included
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

_ts() { date '+%Y.%m.%d %H:%M:%S %Z'; }

# ── Log self-truncation ───────────────────────────────────────────────────
_SELF_LOG="$LOG_FILE"
if [ -f "$_SELF_LOG" ]; then
    _LC=$(wc -l < "$_SELF_LOG" 2>/dev/null || echo 0)
    if [ "$_LC" -gt "$LOG_MAX_LINES" ]; then
        _TMP=$(mktemp)
        tail -n "$LOG_MAX_LINES" "$_SELF_LOG" > "$_TMP" && cat "$_TMP" > "$_SELF_LOG"
        rm -f "$_TMP"
        echo "$(_ts): NOTICE log truncated to last $LOG_MAX_LINES lines (was $_LC)"
    fi
fi

# ── State file ────────────────────────────────────────────────────────────
FIRST_RUN=0
LAST_ID=0
if [ -f "$STATE_FILE" ]; then
    RAW_STATE=$(cat "$STATE_FILE")
    LAST_ID=$(printf '%s' "$RAW_STATE" | tr -d '[:space:]')
    [ "$DEBUG" -eq 1 ] && echo "$(_ts): DEBUG state file exists — raw=[$RAW_STATE] stripped=[$LAST_ID]"
    if ! [[ "$LAST_ID" =~ ^[0-9]+$ ]]; then
        echo "$(_ts): WARN LAST_ID='$LAST_ID' is not a plain integer — resetting to 0"
        LAST_ID=0
    fi
else
    [ "$DEBUG" -eq 1 ] && echo "$(_ts): DEBUG state file not found ($STATE_FILE) — first run mode"
    FIRST_RUN=1
fi

echo "$(_ts): run start — LAST_ID=$LAST_ID  levels=$LEVELS  keyword='$KEYWORD'"

if [ ! -x "$START_CLI" ]; then
    echo "$(_ts): ERROR — start-cli not found or not executable: $START_CLI"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "$(_ts): ERROR — jq not found in PATH: $PATH"
    exit 1
fi

# ── Fetch notifications ───────────────────────────────────────────────────
NOTIFS=$("$START_CLI" notification list 2>&1)
NOTIFS_EXIT=$?
if [ $NOTIFS_EXIT -ne 0 ]; then
    echo "$(_ts): ERROR — $START_CLI notification list failed (exit $NOTIFS_EXIT): $NOTIFS"
    exit 0
fi
if [ -z "$NOTIFS" ]; then
    echo "$(_ts): no notifications returned — exiting"
    exit 0
fi

# ── First run: seed state to skip existing notifications ──────────────────
# On first run (no state file), set LAST_ID to the current maximum so that
# no historical notifications are forwarded. Only notifications that arrive
# after this run will be forwarded. This also applies after a reboot since
# the state file is recreated on the first post-boot cron tick.
if [ "$FIRST_RUN" -eq 1 ]; then
    MAX_RAW=$(echo "$NOTIFS" | jq '[.[].id | tonumber] | max // 0' 2>/dev/null || echo "0")
    LAST_ID=$MAX_RAW
    echo "$(_ts): INFO first run — no state file found. Skipping $MAX_RAW existing notification(s). Only new notifications will be forwarded."
fi

# ── Inspect raw API response ──────────────────────────────────────────────
if [ "$DEBUG" -eq 1 ]; then
    TOTAL=$(echo "$NOTIFS" | jq 'length' 2>/dev/null || echo "?")
    echo "$(_ts): DEBUG API returned $TOTAL notification(s)"
    ID_DUMP=$(echo "$NOTIFS" | jq -r '.[] | "  id=\(.id) type=\(.id|type)"' 2>/dev/null || echo "  (jq failed)")
    echo "$(_ts): DEBUG all notification IDs from API:"
    echo "$ID_DUMP"
    NEW_IDS=$(echo "$NOTIFS" | jq -r --argjson last "$LAST_ID" \
        '[.[] | select((.id | tonumber) > $last) | .id] | @json' 2>/dev/null || echo "?")
    NEW=$(echo "$NOTIFS" | jq --argjson last "$LAST_ID" \
        '[.[] | select((.id | tonumber) > $last)] | length' 2>/dev/null || echo "?")
    echo "$(_ts): DEBUG $TOTAL total, $NEW new (id > $LAST_ID) — new IDs: $NEW_IDS"
fi

# ── Process new notifications ─────────────────────────────────────────────
MAX_ID=$LAST_ID

while IFS= read -r notif; do
    [ "$DEBUG" -eq 1 ] && echo "$(_ts): DEBUG raw notif JSON: $notif"

    # Normalize id to a plain integer string regardless of JSON type
    id=$(echo "$notif" | jq -r '.id | tonumber | tostring')
    if [ "$DEBUG" -eq 1 ]; then
        raw_id=$(echo "$notif" | jq -r '.id')
        echo "$(_ts): DEBUG raw_id=[$raw_id] normalized id=[$id] current MAX_ID=[$MAX_ID]"
    fi

    level=$(echo "$notif" | jq -r '.level')
    title=$(echo "$notif" | jq -r '.title')
    msg=$(echo "$notif"   | jq -r '.message')
    pkg=$(echo "$notif"   | jq -r '.packageId // "null"')
    ts=$(echo "$notif"    | jq -r '.createdAt')

    # Advance MAX_ID for ALL seen notifications, not just forwarded ones
    if [ "$id" -gt "$MAX_ID" ]; then
        [ "$DEBUG" -eq 1 ] && echo "$(_ts): DEBUG advancing MAX_ID: $MAX_ID → $id"
        MAX_ID=$id
    fi

    if [ "$LEVELS" != "all" ] && ! echo ",$LEVELS," | grep -q ",$level,"; then
        echo "$(_ts): skip id=$id level=$level — not in filter '$LEVELS'"
        continue
    fi

    if [ -n "$KEYWORD" ] && ! echo "$title $msg" | grep -Fqi "$KEYWORD"; then
        echo "$(_ts): skip id=$id level=$level — keyword '$KEYWORD' not found in: $title"
        continue
    fi

    ts_fmt=$(date -d "$ts" '+%Y.%m.%d %H:%M:%S %Z' 2>/dev/null || printf '%s UTC' "$(echo "$ts" | sed 's/T/ /; s/\..*//' | tr '-' '.')")
    level_cap=$(echo "$level" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
    echo "$(_ts): forward id=$id level=$level pkg=$pkg title=$title"
    CURL_OUT=$(curl -s -w "\nHTTP_STATUS:%{http_code}" --max-time 10 \
        -d "${ts_fmt}  [${POLLER_NAME}]  [${level_cap}]  #${id}  ${pkg}  |  ${title} — ${msg}" \
        "$WEBHOOK_URL" 2>&1)
    CURL_EXIT=$?
    HTTP_STATUS=$(echo "$CURL_OUT" | grep 'HTTP_STATUS:' | cut -d: -f2)
    CURL_BODY=$(echo "$CURL_OUT" | grep -v 'HTTP_STATUS:')
    [ "$DEBUG" -eq 1 ] && echo "$(_ts): DEBUG curl exit=$CURL_EXIT http=$HTTP_STATUS response=[$CURL_BODY]"

done < <(echo "$NOTIFS" | jq -c --argjson last "$LAST_ID" '[.[] | select((.id | tonumber) > $last)] | sort_by(.id | tonumber) | .[]')

# ── Persist state ─────────────────────────────────────────────────────────
echo "$(_ts): run complete — MAX_ID=$MAX_ID (was LAST_ID=$LAST_ID)"
[ "$DEBUG" -eq 1 ] && [ "$MAX_ID" = "$LAST_ID" ] && echo "$(_ts): DEBUG no new notifications processed — state file unchanged"
[ "$DEBUG" -eq 1 ] && [ "$MAX_ID" != "$LAST_ID" ] && echo "$(_ts): DEBUG writing new MAX_ID=$MAX_ID to $STATE_FILE"
mkdir -p "$(dirname "$STATE_FILE")"
if ! echo "$MAX_ID" > "$STATE_FILE"; then
    echo "$(_ts): ERROR — could not write state file: $STATE_FILE (check permissions)"
elif [ "$DEBUG" -eq 1 ]; then
    VERIFY=$(cat "$STATE_FILE" | tr -d '[:space:]')
    echo "$(_ts): DEBUG state file write confirmed — read-back=[$VERIFY]"
fi
POLLER_BODY_END
)

    local script_content="${config_block}${body_template}"
    local encoded_script encoded_comment encoded_cron
    encoded_script=$(printf '%s' "$script_content" | base64 -w 0)

    local install_ts
    install_ts=$(date '+%Y.%m.%d %H:%M:%S %Z')
    local cron_comment="# startos-admin v${VERSION} | Added: ${install_ts} | Action: Manage Notification Forwarders | Poller: ${name} | Webhook: ${url} | Levels: ${levels} | Keyword: ${keyword:-none}"
    local cron_line="${schedule} ${_POLLER_BIN_PREFIX}${name} >> ${_POLLER_LOG_PREFIX}${name}.log 2>&1"
    encoded_comment=$(printf '%s' "$cron_comment" | base64 -w 0)
    encoded_cron=$(printf '%s' "$cron_line" | base64 -w 0)

    debug_log "Installing poller '$name' → ${_POLLER_BIN_PREFIX}${name}"

    # Remove any existing entry for this poller name, then write the new script
    # and add the tagged comment + cron line — all in one block.
    # mkdir -p here ensures the data dir exists so cron runs can write state/log
    # files. NOTE: files written there at runtime live in the volatile overlay
    # and are LOST on reboot — the forwarder re-seeds on its first post-boot run.
    # \$0 in the block → literal $0 for awk in the chroot shell.
    local cmds="mkdir -p ${_STARTOS_DATA_DIR}
{ crontab -l 2>/dev/null || true; } | awk -v t1=\"| Poller: ${name} |\" -v t2=\"# startos-notif-poller-${name}\" 'index(\$0,t1)||index(\$0,t2)==1{skip=1;next} skip{skip=0;next} {print}' | crontab -
printf '%s' \"${encoded_script}\" | base64 -d > ${_POLLER_BIN_PREFIX}${name}
chmod +x ${_POLLER_BIN_PREFIX}${name}
{ crontab -l 2>/dev/null; printf '%s' \"${encoded_comment}\" | base64 -d; echo; printf '%s' \"${encoded_cron}\" | base64 -d; echo; } | crontab -"

    _apply_or_stage "Install/update forwarder: ${name}" "$cmds" || return 1
}

# Wizard for removing a named poller
_poller_remove_flow() {
    print_header
    print_section "Remove Notification Forwarder"
    echo ""

    local script_names=()
    _poller_get_names script_names || return

    echo -e "  ${BOLD}Select forwarder(s) to remove:${NC}"
    local i=1
    for pname in "${script_names[@]}"; do
        echo -e "    ${BOLD}${i})${NC} ${pname}"
        (( i++ ))
    done
    echo ""
    echo -e "    ${DIM}0) Back${NC}"
    echo ""

    local names_to_remove=()
    while true; do
        _read rchoice "  Choice(s) [1-$((i-1)), comma-separated, 'all', or 0 to go back]: " || return 1
        if [[ "$rchoice" == "0" ]]; then
            return
        fi
        if [[ "$rchoice" == "all" ]]; then
            names_to_remove=("${script_names[@]}")
            break
        fi
        local valid=true
        local selections=()
        IFS=',' read -ra parts <<< "$rchoice"
        for part in "${parts[@]}"; do
            part="${part// /}"
            if [[ "$part" =~ ^[0-9]+$ ]] && [[ "$part" -ge 1 ]] && [[ "$part" -lt "$i" ]]; then
                selections+=("${script_names[$((part - 1))]}")
            else
                valid=false; break
            fi
        done
        if $valid && [[ "${#selections[@]}" -gt 0 ]]; then
            names_to_remove=("${selections[@]}")
            break
        fi
        print_warn "Enter valid number(s) between 1 and $((i-1)), comma-separated, or 'all'."
    done

    echo ""
    local names_display
    names_display=$(printf "'%s' " "${names_to_remove[@]}")
    print_warn "This will permanently remove forwarders: ${names_display}"
    if ! confirm "Remove the selected forwarder(s)?"; then
        [[ $_BACK -eq 1 ]] && return 1
        print_info "Cancelled."
        pause; return
    fi

    # Remove state files now — they are volatile runtime files, wiped by the
    # apply-reboot regardless, so removing early is harmless even when staging.
    for rname in "${names_to_remove[@]}"; do
        local state_file="${_POLLER_STATE_PREFIX}${rname}"
        if [[ -f "$state_file" ]]; then
            print_info "Removing state file: $state_file"
            sudo rm -f "$state_file"
        fi
    done

    # Build the command block with names already substituted.
    local cmds=""
    for rname in "${names_to_remove[@]}"; do
        cmds+="crontab -l 2>/dev/null | grep -v 'startos-notif-poller-${rname}' | grep -Fv '| Poller: ${rname} |' | crontab -
rm -f ${_POLLER_BIN_PREFIX}${rname}
"
    done

    _apply_or_stage "Remove forwarder(s): ${names_display}" "$cmds" || return 1
}

# Display the last 50 lines of a poller's log file.
_poller_view_log() {
    print_header
    print_section "View Forwarder Log"
    echo ""

    local script_names=()
    _poller_get_names script_names || return

    local i=1
    for pname in "${script_names[@]}"; do
        echo -e "    ${BOLD}${i})${NC} ${pname}"
        (( i++ ))
    done
    echo ""

    echo -e "    ${DIM}0) Back${NC}"
    echo ""
    local log_choice
    while true; do
        _read log_choice "  Choice [1-$((i-1)), or 0 to go back]: " || return 1
        [[ "$log_choice" == "0" ]] && return 0
        if [[ "$log_choice" =~ ^[0-9]+$ ]] && \
           [[ "$log_choice" -ge 1 ]] && [[ "$log_choice" -lt "$i" ]]; then
            break
        fi
        print_warn "Enter a number between 1 and $((i-1)), or 0 to go back."
    done

    local log_name="${script_names[$((log_choice - 1))]}"
    local log_file="${_POLLER_LOG_PREFIX}${log_name}.log"

    print_header
    print_section "Forwarder Log: ${log_name}"
    echo ""

    if [[ ! -f "$log_file" ]]; then
        print_info "Log file not found: $log_file"
        print_info "The forwarder may not have run yet."
    else
        echo -e "  ${DIM}(last 50 lines of $log_file)${NC}"
        echo ""
        tail -50 "$log_file"
    fi

    echo ""
    pause
}

_poller_state_flow() {
    print_header
    print_section "Manage Forwarder State"
    echo ""

    local script_names=()
    _poller_get_names script_names || return

    local i=1
    for pname in "${script_names[@]}"; do
        local sv="(not found)"
        [[ -f "${_POLLER_STATE_PREFIX}${pname}" ]] && \
            sv=$(cat "${_POLLER_STATE_PREFIX}${pname}" 2>/dev/null | tr -d '[:space:]') && \
            sv="${sv:-(empty)}"
        echo -e "    ${BOLD}${i})${NC} ${pname}  ${DIM}(last ID: ${sv})${NC}"
        (( i++ ))
    done
    echo ""

    echo -e "    ${DIM}0) Back${NC}"
    echo ""
    local choice
    while true; do
        _read choice "  Choice [1-$((i-1)), or 0 to go back]: " || return 1
        [[ "$choice" == "0" ]] && return 0
        [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )) && break
        print_warn "Enter a number between 1 and $((i-1)), or 0 to go back."
    done
    local pname="${script_names[$((choice-1))]}"
    local state_file="${_POLLER_STATE_PREFIX}${pname}"

    local sv="(file not found)"
    [[ -f "$state_file" ]] && sv=$(cat "$state_file" 2>/dev/null | tr -d '[:space:]') && sv="${sv:-(empty)}"

    echo ""
    echo -e "  ${BOLD}Forwarder:${NC}         ${pname}"
    echo -e "  ${BOLD}State file:${NC}        ${state_file}"
    echo -e "  ${BOLD}Last forwarded ID:${NC} ${sv}"
    echo ""
    echo -e "    ${BOLD}1)${NC} Delete state file  ${DIM}(next run silently catches up — no notifications forwarded)${NC}"
    echo -e "    ${BOLD}2)${NC} Set to current max  ${DIM}(skip all existing, forward only future)${NC}"
    echo -e "    ${BOLD}3)${NC} Set to specific ID"
    echo -e "    ${DIM}0) Back${NC}"
    echo ""

    local action
    while true; do
        _read action "  Choice [0-3]: " || return 1
        case "$action" in 0|1|2|3) break ;; *) print_warn "Enter 0, 1, 2, or 3." ;; esac
    done

    case "$action" in
        0) return ;;
        1)
            if confirm "Delete state file for '${pname}'?"; then
                if sudo rm -f "$state_file" && [[ ! -e "$state_file" ]]; then
                    print_success "State file deleted. Next run silently re-seeds — only notifications after that run are forwarded."
                else
                    print_error "Failed to delete state file."
                fi
            else
                print_info "Cancelled."
            fi ;;
        2)
            echo ""
            print_info "Querying current max notification ID..."
            local cur_max
            cur_max=$(start-cli notification list 2>/dev/null \
                | jq '[.[].id | tonumber] | max // 0' 2>/dev/null || echo "0")
            echo -e "  Current max ID: ${cur_max}"
            if confirm "Set last-forwarded ID to ${cur_max}?"; then
                echo "$cur_max" | sudo tee "$state_file" >/dev/null
                print_success "State set to ${cur_max}. Only notifications newer than this will be forwarded."
            else
                print_info "Cancelled."
            fi ;;
        3)
            local new_id
            while true; do
                _read new_id "  Enter new last-forwarded ID: " || return 1
                [[ "$new_id" =~ ^[0-9]+$ ]] && break
                print_warn "Must be a non-negative integer."
            done
            if confirm "Set last-forwarded ID to ${new_id}?"; then
                echo "$new_id" | sudo tee "$state_file" >/dev/null
                print_success "State set to ${new_id}."
            else
                print_info "Cancelled."
            fi ;;
    esac
    echo ""
    pause
}

# Top-level submenu for notification forwarder management
menu_manage_notif_pollers() {
    while true; do
        print_header
        print_section "Manage Notification Forwarders"
        echo ""
        echo -e "    ${CYAN}${BOLD}1)${NC} Install a new notification forwarder"
        echo -e "    ${CYAN}${BOLD}2)${NC} Edit an existing forwarder"
        echo -e "    ${CYAN}${BOLD}3)${NC} List installed forwarders"
        echo -e "    ${CYAN}${BOLD}4)${NC} Remove a forwarder"
        echo -e "    ${CYAN}${BOLD}5)${NC} View forwarder log"
        echo -e "    ${CYAN}${BOLD}6)${NC} Manage forwarder state"
        echo ""
        echo -e "    ${DIM}0) Back${NC}"
        echo ""
        _read sub_choice "  $(echo -e "${BOLD}Choice:${NC} ")" || return 1
        case "$sub_choice" in
            1) _poller_install_flow || return 1 ;;
            2) _poller_edit_flow    || return 1 ;;
            3)
                print_header
                print_section "Installed Notification Forwarders"
                echo ""
                _poller_list_display || true
                pause
                ;;
            4) _poller_remove_flow  || return 1 ;;
            5) _poller_view_log     || return 1 ;;
            6) _poller_state_flow   || return 1 ;;
            0) return ;;
            *) print_warn "Enter 0-6." ; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Alerts (disk usage / backup staleness / service health / drive health)
# ─────────────────────────────────────────────
# Each alert is a NAMED instance — a generated script
# /usr/local/bin/startos-monitor-<type>-<name> run by a tagged cron entry.
# Multiple instances per type are independent (e.g. disk warn50 at 50% info +
# disk crit85 at 85% error). Re-alert policy: alert on first detection, on
# offender-list change, and at most one reminder per 24h while the condition
# persists. No recovery messages. State is volatile (one repeat after reboot).
# Legacy v60/v61 singletons (no name suffix) are recognized and migrate to a
# named instance when edited.

# Enumerate installed alert instances, one per line: "type<TAB>name<TAB>path".
# Legacy singletons are reported with an empty name field.
_monitor_installed() {
    local f suffix type
    for f in "${_MONITOR_BIN_PREFIX}"*; do
        [[ -f "$f" ]] || continue
        suffix="${f##"${_MONITOR_BIN_PREFIX}"}"
        # Match the hyphenated types first (a bare-type prefix would swallow them).
        for type in backup-age backup-ok backup-failed disk drive health; do
            if [[ "$suffix" == "$type" ]]; then
                printf '%s\t%s\t%s\n' "$type" "" "$f"
                continue 2
            elif [[ "$suffix" == "$type"-* ]]; then
                printf '%s\t%s\t%s\n' "$type" "${suffix#"$type"-}" "$f"
                continue 2
            fi
        done
    done
}

# Human-readable instance display: "Disk usage alert [warn50]"
_monitor_display() {
    local type="$1" name="$2"
    printf '%s [%s]' "$(_monitor_label "$type")" "${name:-unnamed}"
}

_monitor_label() {
    case "$1" in
        disk)       echo "Disk usage alert" ;;
        backup-age) echo "Backup staleness alert" ;;
        backup-ok)  echo "Backup succeeded alert" ;;
        backup-failed) echo "Backup failed alert" ;;
        health)     echo "Service health watchdog" ;;
        drive)      echo "Drive health alert" ;;
    esac
}

_monitor_title() {
    case "$1" in
        disk)       echo "Disk Usage Alert" ;;
        backup-age) echo "Backup Staleness Alert" ;;
        backup-ok)  echo "Backup Succeeded Alert" ;;
        backup-failed) echo "Backup Failed Alert" ;;
        health)     echo "Service Health Alert" ;;
        drive)      echo "Drive Health Alert" ;;
    esac
}

# Read config vars from an installed monitor script.
# Usage: _monitor_read_config path threshold_ref shellcmd_ref startos_ref level_ref excludes_ref [target_ref]
_monitor_read_config() {
    local _mrc_path="$1"
    local -n _mrc_thr="$2" _mrc_cmd="$3" _mrc_sos="$4" _mrc_lvl="$5" _mrc_exc="$6"
    _mrc_thr=$(grep '^THRESHOLD='        "$_mrc_path" 2>/dev/null | cut -d'"' -f2)
    local _mrc_b64
    _mrc_b64=$(grep '^NOTIFY_SHELL_B64=' "$_mrc_path" 2>/dev/null | cut -d'"' -f2)
    _mrc_cmd=""
    [[ -n "$_mrc_b64" ]] && _mrc_cmd=$(printf '%s' "$_mrc_b64" | base64 -d 2>/dev/null)
    _mrc_sos=$(grep '^NOTIFY_STARTOS='   "$_mrc_path" 2>/dev/null | cut -d'"' -f2)
    _mrc_lvl=$(grep '^NOTIF_LEVEL='      "$_mrc_path" 2>/dev/null | cut -d'"' -f2)
    _mrc_exc=$(grep '^EXCLUDES='         "$_mrc_path" 2>/dev/null | cut -d'"' -f2)
    if [[ $# -ge 7 ]]; then
        local -n _mrc_tgt="$7"
        _mrc_tgt=$(grep '^TARGET_ID='    "$_mrc_path" 2>/dev/null | cut -d'"' -f2)
    fi
}

# Current cron schedule for an installed monitor instance (empty if not
# found). $1 = instance suffix (type or type-name). The trailing space keeps
# "disk" from matching "disk-warn50" cron lines.
_monitor_read_schedule() {
    sudo crontab -u root -l 2>/dev/null \
        | grep "^[^#]*${_MONITOR_BIN_PREFIX}${1} " \
        | awk '{print $1,$2,$3,$4,$5}'
}

# Generic schedule preset picker.
# $1 = nameref out; remaining args = alternating "label" "cron-expr" pairs.
_pick_monitor_schedule() {
    local -n _pms_out="$1"; shift
    local -a labels=() exprs=()
    while [[ $# -ge 2 ]]; do
        labels+=("$1"); exprs+=("$2"); shift 2
    done
    local n=${#labels[@]}
    echo ""
    echo -e "  ${BOLD}Select check schedule:${NC}"
    _cron_clock_note
    local i
    for i in "${!labels[@]}"; do
        echo -e "    ${BOLD}$((i+1)))${NC} ${labels[$i]}  ${DIM}(${exprs[$i]})${NC}"
    done
    echo -e "    ${BOLD}$((n+1)))${NC} Custom cron expression"
    echo ""
    local c
    while true; do
        _read c "  Choice [1-$((n+1))]: " || return 1
        if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= n )); then
            _pms_out="${exprs[$((c-1))]}"
            return 0
        elif [[ "$c" == "$((n+1))" ]]; then
            _read _pms_out "  Enter cron expression (e.g. 0 */6 * * *): " || return 1
            if [[ -z "$_pms_out" ]]; then
                print_warn "Expression cannot be empty."
            elif _validate_cron_expr "$_pms_out"; then
                return 0
            fi
        else
            print_warn "Enter 1-$((n+1))."
        fi
    done
}

# Notification method picker for monitors: shell command / StartOS / both.
# The alert text is dynamic, so the shell command receives it as $MSG.
# Sets namerefs: shell_cmd (raw, empty = none), startos (0/1), level.
# Optional $4/$5/$6 = current values for prefill (edit flow); $7 = the level
# offered as the default for a new choice (info/warning/error, default warning).
_pick_monitor_notify() {
    local -n _pmn_cmd="$1" _pmn_sos="$2" _pmn_lvl="$3"
    local _pmn_def_cmd="${4:-}" _pmn_def_sos="${5:-}" _pmn_def_lvl="${6:-}"
    local _pmn_new_lvl="${7:-warning}" _pmn_dn=2
    case "$_pmn_new_lvl" in info) _pmn_dn=1 ;; error) _pmn_dn=3 ;; esac
    _pmn_cmd=""; _pmn_sos=0; _pmn_lvl="warning"

    echo ""
    echo -e "  ${BOLD}How should this alert notify you?${NC}"
    echo -e "    ${BOLD}1)${NC} Shell command  ${DIM}(e.g. webhook)${NC}"
    echo -e "    ${BOLD}2)${NC} StartOS notification"
    echo -e "    ${BOLD}3)${NC} Both"
    local _pmn_has_def=0
    if [[ -n "$_pmn_def_cmd" || "$_pmn_def_sos" == "1" ]]; then
        _pmn_has_def=1
        local _pmn_desc=""
        [[ -n "$_pmn_def_cmd" ]] && _pmn_desc="shell: ${_pmn_def_cmd:0:40}"
        [[ "$_pmn_def_sos" == "1" ]] && _pmn_desc="${_pmn_desc}${_pmn_desc:+ + }StartOS ${_pmn_def_lvl}"
        echo -e "    ${BOLD}4)${NC} Keep current  ${DIM}(${_pmn_desc})${NC}"
    fi
    echo ""

    local _pmn_mode=""
    while true; do
        _read _pmn_mode "  Choice [1-3${_pmn_has_def:+/4}]: " || return 1
        case "$_pmn_mode" in
            1|2|3) break ;;
            4) if [[ $_pmn_has_def -eq 1 ]]; then
                   _pmn_cmd="$_pmn_def_cmd"
                   _pmn_sos="${_pmn_def_sos:-0}"
                   _pmn_lvl="${_pmn_def_lvl:-warning}"
                   return 0
               fi
               print_warn "Enter 1, 2, or 3." ;;
            *) print_warn "Enter 1, 2, or 3${_pmn_has_def:+, or 4 to keep current}." ;;
        esac
    done

    if [[ "$_pmn_mode" == "1" || "$_pmn_mode" == "3" ]]; then
        echo ""
        echo -e "  ${DIM}The alert text is provided in the \$MSG environment variable.${NC}"
        echo -e "  ${DIM}Example:  curl -d \"\$MSG\" https://ntfy.sh/Your-Topic${NC}"
        while true; do
            _read _pmn_cmd "  Shell command: " || return 1
            [[ -n "$_pmn_cmd" ]] && break
            print_warn "Command cannot be empty."
        done
        local _pmn_test
        _read _pmn_test "  Test this command now with a sample message? [y/N]: " || return 1
        if [[ "${_pmn_test,,}" == "y" ]]; then
            echo ""
            print_info "Running with MSG=\"TEST: sample alert from startos-admin\""
            local _pmn_test_exit=0
            MSG="TEST: sample alert from startos-admin" bash -c "$_pmn_cmd" || _pmn_test_exit=$?
            echo ""
            if [[ $_pmn_test_exit -eq 0 ]]; then
                print_success "Command exited 0 (success)."
            else
                print_warn "Command exited $_pmn_test_exit. Check the output above."
            fi
        fi
    fi

    if [[ "$_pmn_mode" == "2" || "$_pmn_mode" == "3" ]]; then
        _pmn_sos=1
        echo ""
        echo -e "  ${BOLD}StartOS notification level:${NC}"
        echo -e "    ${BOLD}1)${NC} ${CYAN}info${NC}  ${BOLD}2)${NC} ${YELLOW}warning${NC}  ${BOLD}3)${NC} ${RED}error${NC}"
        echo ""
        local _pmn_lc
        while true; do
            _read _pmn_lc "  Choice [1-3, default ${_pmn_dn}]: " || return 1
            case "${_pmn_lc:-$_pmn_dn}" in
                1) _pmn_lvl="info";    break ;;
                2) _pmn_lvl="warning"; break ;;
                3) _pmn_lvl="error";   break ;;
                *) print_warn "Enter 1, 2, or 3." ;;
            esac
        done
    fi
    return 0
}

# Stdlib-only python that reads the NVMe SMART / Health log page (log ID 2)
# via the admin ioctl on /dev/nvmeN and prints key=value lines. Embedded
# base64 into generated drive monitors and run directly (via sudo) for the
# wizard's live preview. No smartctl/nvme-cli needed — StartOS doesn't ship
# them and host packages don't survive OS updates. Single-quoted literal:
# must contain no single quotes.
_NVME_SMART_PY='import sys, fcntl, ctypes

class AdminCmd(ctypes.Structure):
    _fields_ = [
        ("opcode", ctypes.c_uint8), ("flags", ctypes.c_uint8),
        ("rsvd1", ctypes.c_uint16), ("nsid", ctypes.c_uint32),
        ("cdw2", ctypes.c_uint32), ("cdw3", ctypes.c_uint32),
        ("metadata", ctypes.c_uint64), ("addr", ctypes.c_uint64),
        ("metadata_len", ctypes.c_uint32), ("data_len", ctypes.c_uint32),
        ("cdw10", ctypes.c_uint32), ("cdw11", ctypes.c_uint32),
        ("cdw12", ctypes.c_uint32), ("cdw13", ctypes.c_uint32),
        ("cdw14", ctypes.c_uint32), ("cdw15", ctypes.c_uint32),
        ("timeout_ms", ctypes.c_uint32), ("result", ctypes.c_uint32),
    ]

NVME_IOCTL_ADMIN_CMD = 0xC0484E41  # _IOWR(N, 0x41, 72-byte AdminCmd)
buf = ctypes.create_string_buffer(512)
cmd = AdminCmd()
cmd.opcode = 0x02            # Get Log Page
cmd.nsid = 0xFFFFFFFF        # controller-wide
cmd.addr = ctypes.addressof(buf)
cmd.data_len = 512
cmd.cdw10 = 0x02 | ((512 // 4 - 1) << 16)  # LID 2 = SMART / Health, NUMDL
with open(sys.argv[1], "rb") as f:
    rc = fcntl.ioctl(f.fileno(), NVME_IOCTL_ADMIN_CMD, cmd)
if rc != 0:
    sys.stderr.write("NVMe error status 0x%x\n" % rc)
    sys.exit(1)
d = bytes(buf)

def le(lo, hi):
    return int.from_bytes(d[lo:hi], "little")

print("critical_warning=%d" % d[0])
print("temperature_c=%d" % (le(1, 3) - 273))
print("available_spare=%d" % d[3])
print("spare_threshold=%d" % d[4])
print("percentage_used=%d" % d[5])
print("power_on_hours=%d" % le(112, 128))
print("unsafe_shutdowns=%d" % le(144, 160))
print("media_errors=%d" % le(160, 176))
print("num_err_log_entries=%d" % le(176, 192))'

# Build the full generated-script content for a monitor instance.
# $1=type $2=threshold $3=excludes-csv $4=shell_cmd(raw) $5=startos(0/1)
# $6=level $7=backup-target-id (backup-age only) $8=instance name
_monitor_script_content() {
    local type="$1" threshold="$2" excludes="$3" shell_cmd="$4" startos="$5" level="$6" target_id="${7:-}" name="${8:-}"
    local inst="${type}${name:+-${name}}"
    local shell_b64=""
    [[ -n "$shell_cmd" ]] && shell_b64=$(printf '%s' "$shell_cmd" | base64 -w 0)
    local title
    title=$(_monitor_title "$type")

    # Config block — values are expanded NOW and embedded. All values are
    # validated/derived (digits, csv of package ids, base64, fixed sets,
    # name regex), so double-quoted embedding is safe.
    printf '%s\n' "#!/bin/bash
# StartOS Alert Monitor — generated by startos-admin.sh
# Monitor: ${inst}
# Re-run startos-admin (main menu → 10, Alerts) to update this configuration.
MONITOR_FORMAT=\"$(_monitor_format "$type")\"
MONITOR_TYPE=\"${type}\"
MONITOR_NAME=\"${name}\"
THRESHOLD=\"${threshold}\"
EXCLUDES=\"${excludes}\"
TARGET_ID=\"${target_id}\"
NOTIFY_SHELL_B64=\"${shell_b64}\"
NOTIFY_STARTOS=\"${startos}\"
NOTIF_LEVEL=\"${level}\"
NOTIF_TITLE=\"${title}\"
VOLUMES_PATH=\"${_MONITOR_VOLUMES_PATH}\"
STATE_FILE=\"${_MONITOR_DATA_PREFIX}${inst}.state\"
LOG_FILE=\"${_MONITOR_DATA_PREFIX}${inst}.log\"
START_CLI=\"${_START_CLI}\"
REMIND_SECS=86400
FAIL_LIMIT=3
LOG_MAX_LINES=2000
DEBUG=0
[ -f ${_STARTOS_DATA_DIR}/debug ] && DEBUG=1"

    # Drive monitors carry the python SMART helper (base64 is safe to embed
    # double-quoted, same as NOTIFY_SHELL_B64).
    [[ "$type" == "drive" ]] && \
        printf 'SMART_PY_B64="%s"\n' "$(printf '%s' "$_NVME_SMART_PY" | base64 -w 0)"

    # Common preamble — PATH, timestamp, log self-truncation
    cat << 'MON_PRE_END'
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
_ts() { date '+%Y.%m.%d %H:%M:%S %Z'; }
if [ -f "$LOG_FILE" ]; then
    _LC=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$_LC" -gt "$LOG_MAX_LINES" ]; then
        _TMP=$(mktemp)
        tail -n "$LOG_MAX_LINES" "$LOG_FILE" > "$_TMP" && cat "$_TMP" > "$LOG_FILE"
        rm -f "$_TMP"
        echo "$(_ts): NOTICE log truncated to last $LOG_MAX_LINES lines (was $_LC)"
    fi
fi
# Send $2 (message) with title $1 through every configured channel.
_notify() {
    if [ -n "$NOTIFY_SHELL_B64" ]; then
        _CMD=$(printf '%s' "$NOTIFY_SHELL_B64" | base64 -d)
        [ "$DEBUG" -eq 1 ] && echo "$(_ts): DEBUG shell command: $_CMD"
        MSG="$2" bash -c "$_CMD"
        echo "$(_ts): shell command exit $?"
    fi
    if [ "$NOTIFY_STARTOS" = "1" ]; then
        if "$START_CLI" notification create "$NOTIF_LEVEL" "$1" "$2"; then
            echo "$(_ts): StartOS notification created"
        else
            echo "$(_ts): StartOS notification FAILED"
        fi
    fi
}
# A check that cannot run can't alert, so failures are counted: after
# FAIL_LIMIT runs in a row, say so once. A successful run resets the count.
# The count lives beside STATE_FILE (volatile: a reboot restarts it).
FAIL_FILE="${STATE_FILE}.fails"
_check_failed() {
    echo "$(_ts): ERROR — $1"
    _FN=0; _FSENT=0
    if [ -f "$FAIL_FILE" ]; then
        _FN=$(sed -n '1p' "$FAIL_FILE"); _FSENT=$(sed -n '2p' "$FAIL_FILE")
    fi
    case "$_FN" in ''|*[!0-9]*) _FN=0 ;; esac
    _FN=$((_FN + 1))
    if [ "$_FN" -ge "$FAIL_LIMIT" ] && [ "$_FSENT" != "1" ]; then
        _LABEL="$NOTIF_TITLE${MONITOR_NAME:+ [$MONITOR_NAME]}"
        echo "$(_ts): check failed ${_FN} times in a row — notifying"
        _notify "${NOTIF_TITLE}: check failing" "${_LABEL}: the check has failed ${_FN} times in a row, so this alert may miss problems until it is fixed. Last error: $1"
        _FSENT=1
    fi
    mkdir -p "$(dirname "$FAIL_FILE")"
    { printf '%s\n' "$_FN"; printf '%s\n' "$_FSENT"; } > "$FAIL_FILE"
}
# Fatal: the check produced no result at all.
_fail() { _check_failed "$1"; exit 0; }
_check_ok() {
    if [ -f "$FAIL_FILE" ]; then
        rm -f "$FAIL_FILE"
        echo "$(_ts): check ran again after earlier failures — failure count reset"
    fi
}
CHECK_ERR=""
# While StartOS initializes it serves a reduced API with no db.* methods, so
# 'db dump' fails with "Method not found" — normal after a restart, so skip
# without counting it. Diagnostic mode or an unreachable server does count.
_need_running() {
    STATE=$(timeout 10 "$START_CLI" state 2>/dev/null) || STATE="Unknown"
    case "$STATE" in
        Running) return 0 ;;
        Initializing) echo "$(_ts): skipped — StartOS is still starting up"; exit 0 ;;
        *) _fail "StartOS is not running (state: ${STATE})" ;;
    esac
}
MON_PRE_END

    # Type-specific check — must set CONDITION (0/1), MSG, FPRINT
    case "$type" in
        disk)
            cat << 'MON_DISK_END'
# ── Check: disk usage ───────────────────────────────────────────────────────
PCT=$(df --output=pcent "$VOLUMES_PATH" 2>/dev/null | tail -1 | tr -d ' %')
if ! [[ "$PCT" =~ ^[0-9]+$ ]]; then
    _fail "could not read disk usage for $VOLUMES_PATH"
fi
CONDITION=0; MSG=""; FPRINT=""
if [ "$PCT" -ge "$THRESHOLD" ]; then
    set -- $(df -h --output=size,used,avail "$VOLUMES_PATH" 2>/dev/null | tail -1)
    SIZE="${1:-?}"; USED="${2:-?}"; AVAIL="${3:-?}"
    CONDITION=1
    FPRINT="over-${THRESHOLD}"
    MSG="Disk usage ${PCT}% has reached your ${THRESHOLD}% alert threshold (used ${USED} of ${SIZE}, ${AVAIL} available)"
fi
echo "$(_ts): usage ${PCT}% / threshold ${THRESHOLD}%"
MON_DISK_END
            ;;
        backup-age)
            cat << 'MON_BAGE_END'
# ── Check: backup staleness ──────────────────────────────────────────────────
# Two sources, neither needing the backup password:
#  * per service — packageData.<id>.lastBackup: when that service last backed
#    up successfully, to any target. StartOS writes it from 0.4.0.3 on.
#  * per target (optional, TARGET_ID) — `backup target list` reports, for each
#    target, when this server's last backup run on it finished.
_need_running
DB=$(timeout 60 "$START_CLI" db dump 2>&1)
if [ $? -ne 0 ] || [ -z "$DB" ]; then
    _fail "start-cli db dump failed: ${DB:0:200}"
fi
SERVER_ID=$(printf '%s' "$DB" | jq -r '.value.serverInfo.id // empty' 2>/dev/null)
OS_VER=$(printf '%s' "$DB" | jq -r '.value.serverInfo.version // empty' 2>/dev/null)
if [ -z "$SERVER_ID" ]; then
    _fail "could not read the server id from the database"
fi
# Before 0.4.0.3 lastBackup was never written, so every service would read
# as "never backed up".
_OLDEST=$(printf '%s\n%s\n' "0.4.0.3" "${OS_VER%%[-:]*}" | sort -V | head -1)
if [ "$_OLDEST" != "0.4.0.3" ]; then
    _fail "StartOS ${OS_VER} does not record per-service backup times; this alert needs StartOS 0.4.0.3 or newer"
fi
NOW=$(date +%s)
# Offenders = installed services (minus excludes) whose last successful backup
# is older than THRESHOLD days, or which have never been backed up.
OFFENDERS=$(printf '%s' "$DB" | jq -r --argjson now "$NOW" --argjson days "$THRESHOLD" --arg excl ",${EXCLUDES}," '
  .value.packageData | to_entries[]
  | .key as $k | .value.lastBackup as $ts
  | select(($excl | contains("," + $k + ",")) | not)
  | if $ts == null then "\($k)\tnever"
    else (
      (try ($ts | sub("\\.[0-9]+"; "") | fromdateiso8601) catch null) as $t
      | if $t == null then "\($k)\tbackup date unreadable"
        else ((($now - $t) / 86400 | floor) as $age
          | if $age > $days then "\($k)\t\($age) days" else empty end)
        end)
    end')
if [ $? -ne 0 ]; then
    _fail "could not read service backup times from the database"
fi
TARGET_STALE=""
if [ -n "$TARGET_ID" ]; then
    TLIST=$(timeout 120 "$START_CLI" backup target list 2>&1)
    _TRC=$?
    TLIST_OK=1
    if [ "$_TRC" -ne 0 ] || ! printf '%s' "$TLIST" | jq -e 'type == "object"' >/dev/null 2>&1; then
        TLIST_OK=0
    fi
    # StartOS 0.4.3+ lists only targets registered in System → Backups, each
    # with a "source"; older StartOS lists every partition and CIFS share.
    REGISTERED=0
    _OLDEST=$(printf '%s\n%s\n' "0.4.3" "${OS_VER%%[-:]*}" | sort -V | head -1)
    [ "$_OLDEST" = "0.4.3" ] && REGISTERED=1
    # A pre-0.4.3 disk target is stored by filesystem UUID ("uuid-<UUID>")
    # because its device name changes on replug. Before 0.4.3, find the
    # drive's current device name; from 0.4.3, find the registered target
    # that holds that partition.
    TARGET_ARG="$TARGET_ID"
    case "$TARGET_ID" in
        uuid-*)
            if [ "$REGISTERED" = 1 ]; then
                TARGET_ARG=$(printf '%s' "$TLIST" | jq -r --arg p "/dev/disk/by-uuid/${TARGET_ID#uuid-}" '
                    to_entries[] | select(.value.source.kind? == "disk" and .value.source.logicalname == $p
                                          and ((.value.source.path // "") == "")) | .key' 2>/dev/null | head -1)
            else
                _DEV=$(readlink -e "/dev/disk/by-uuid/${TARGET_ID#uuid-}") || _DEV=""
                TARGET_ARG="${_DEV:+disk-${_DEV}}"
            fi
            ;;
    esac
    if [ "$TLIST_OK" != 1 ]; then
        CHECK_ERR="could not list backup targets: ${TLIST:0:200}"
    elif [ -z "$TARGET_ARG" ] && [ "$REGISTERED" = 1 ]; then
        CHECK_ERR="backup target ${TARGET_ID} has not been added in System → Backups"
    elif [ -z "$TARGET_ARG" ] || ! printf '%s' "$TLIST" | jq -e --arg t "$TARGET_ARG" 'has($t)' >/dev/null 2>&1; then
        if [ "$REGISTERED" = 1 ]; then
            CHECK_ERR="backup target ${TARGET_ID} is no longer listed in System → Backups"
        else
            CHECK_ERR="backup target ${TARGET_ID} is not connected"
        fi
    elif [ "$(printf '%s' "$TLIST" | jq -r --arg t "$TARGET_ARG" '(.[$t].mountable == false) or (.[$t].availability == "unavailable")')" = "true" ]; then
        _TERR=$(printf '%s' "$TLIST" | jq -r --arg t "$TARGET_ARG" '.[$t].error // empty' | cut -c1-200)
        CHECK_ERR="backup target ${TARGET_ID} could not be reached${_TERR:+: ${_TERR}}"
    else
        # Name the target in messages: a registered id is 32 opaque letters.
        _TNAME=$(printf '%s' "$TLIST" | jq -r --arg t "$TARGET_ARG" '.[$t].name // empty' | cut -c1-80)
        TLABEL="${TARGET_ID}${_TNAME:+ (${_TNAME})}"
        TTS=$(printf '%s' "$TLIST" | jq -r --arg t "$TARGET_ARG" --arg s "$SERVER_ID" '.[$t].startOs[$s].timestamp // empty')
        if [ -z "$TTS" ]; then
            TARGET_STALE="backup target ${TLABEL} has no backup from this server"
        else
            TT=$(date -d "$TTS" +%s 2>/dev/null) || TT=""
            if [ -z "$TT" ]; then
                CHECK_ERR="unreadable backup date on target ${TARGET_ID}: ${TTS}"
            else
                TAGE=$(( (NOW - TT) / 86400 ))
                [ "$TAGE" -gt "$THRESHOLD" ] && TARGET_STALE="backup target ${TLABEL} last received a backup ${TAGE} days ago"
                echo "$(_ts): target ${TLABEL}: last backup ${TTS} (${TAGE} days)"
            fi
        fi
    fi
fi
CONDITION=0; MSG=""; FPRINT=""
if [ -n "$OFFENDERS" ]; then
    CONDITION=1
    COUNT=$(printf '%s\n' "$OFFENDERS" | wc -l)
    LIST=$(printf '%s\n' "$OFFENDERS" | awk -F'\t' '{printf "%s%s (%s)", (NR>1?", ":""), $1, $2}')
    FPRINT=$(printf '%s\n' "$OFFENDERS" | awk -F'\t' '{print $1}' | sort | paste -sd, -)
    MSG="Backup staleness: ${COUNT} service(s) exceed ${THRESHOLD} day(s): ${LIST}"
fi
if [ -n "$TARGET_STALE" ]; then
    CONDITION=1
    FPRINT="${FPRINT}${FPRINT:+,}target:${TARGET_ID}"
    if [ -n "$MSG" ]; then MSG="${MSG}; ${TARGET_STALE}"; else MSG="Backup staleness: ${TARGET_STALE} (threshold ${THRESHOLD} day(s))"; fi
fi
echo "$(_ts): stale: ${FPRINT:-none}"
MON_BAGE_END
            ;;
        backup-ok|backup-failed)
            cat << 'MON_BRES_END'
# ── Check: backup results ────────────────────────────────────────────────────
# StartOS 0.4.3 and newer record each finished backup run in History instead
# of sending a notification. Report each run this alert has not seen yet that
# succeeded (backup-ok) or failed (backup-failed). Seen run ids live beside
# STATE_FILE, which is volatile: with no seen list (after a restart, or right
# after install, which restarts), runs that finished more than 30 minutes
# before the restart, or more than 2 hours ago, count as already reported.
_need_running
HIST=$(timeout 60 "$START_CLI" backup history list --limit 25 --format json 2>&1)
_HRC=$?
if [ "$_HRC" -ne 0 ] || ! printf '%s' "$HIST" | jq -e '.runs | type == "array"' >/dev/null 2>&1; then
    _fail "could not read backup history (needs StartOS 0.4.3 or newer): ${HIST:0:200}"
fi
SEEN_FILE="${STATE_FILE}.seen"
NOW=$(date +%s)
CUTOFF=0
if [ ! -f "$SEEN_FILE" ]; then
    _UP=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    case "$_UP" in ''|*[!0-9]*) _UP=0 ;; esac
    CUTOFF=$(( NOW - _UP - 1800 ))
    [ "$CUTOFF" -lt $(( NOW - 7200 )) ] && CUTOFF=$(( NOW - 7200 ))
fi
# One line per run, oldest first: id, started, completed (epoch), outcome
# (ok / failed = the backup stopped / partial = some items reported errors),
# target name, summary. @tsv escapes tabs and newlines inside error text.
RUNS=$(printf '%s' "$HIST" | jq -r '
  def epoch: (try (sub("\\.[0-9]+"; "") | fromdateiso8601) catch 0);
  .runs | reverse[]
  | .report as $r
  | ($r.server.error) as $se
  | [($r.packages // {}) | to_entries[] | select(.value.error != null) | "\(.key): \(.value.error)"] as $pe
  | [($r.sharedVolumes // {}) | to_entries[] | select(.value.error != null) | "volume \(.value.name // .key): \(.value.error)"] as $ve
  | (($r.packages // {}) | length) as $np
  | (($r.sharedVolumes // {}) | length) as $nv
  | (if $se != null then "failed" elif ($pe | length) > 0 or ($ve | length) > 0 then "partial" else "ok" end) as $out
  | [ .id, (.startedAt | epoch), (.completedAt | epoch), $out,
      ((.targetName // .targetId // "") | if . == "" then "?" else . end),
      (if $out != "ok"
       then ((if $se != null then ["\($se)"] else [] end) + $pe + $ve) | join("; ")
       else "\($np) service(s)\(if $nv > 0 then " and \($nv) shared volume(s)" else "" end) backed up" end) ]
  | @tsv' 2>&1)
if [ $? -ne 0 ]; then
    _fail "could not read the backup history entries: ${RUNS:0:200}"
fi
WANT="ok"; [ "$MONITOR_TYPE" = "backup-failed" ] && WANT="failed"
mkdir -p "$(dirname "$SEEN_FILE")"
touch "$SEEN_FILE"
_fmt_time() { date -d "@$1" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo "?"; }
_fmt_dur() {
    _S=$1; [ "$_S" -lt 0 ] 2>/dev/null && _S=0
    if [ "$_S" -ge 3600 ]; then echo "$((_S / 3600))h $((_S % 3600 / 60))m"
    elif [ "$_S" -ge 60 ]; then echo "$((_S / 60))m"
    else echo "${_S}s"; fi
}
NEW=0
while IFS=$'\t' read -r RID RSTART REND ROUT RTGT RSUM; do
    [ -n "$RID" ] || continue
    grep -qxF "$RID" "$SEEN_FILE" && continue
    printf '%s\n' "$RID" >> "$SEEN_FILE"
    NEW=$((NEW + 1))
    if [ "$REND" -lt "$CUTOFF" ] 2>/dev/null; then
        echo "$(_ts): run ${RID} (${ROUT}, ${RTGT}) finished before this alert started — not reported"
        continue
    fi
    _RCLASS="$ROUT"; [ "$ROUT" = "partial" ] && _RCLASS="failed"
    if [ "$_RCLASS" != "$WANT" ]; then
        echo "$(_ts): run ${RID} ${ROUT} (${RTGT}) — not this alert's outcome"
        continue
    fi
    if [ "$ROUT" = "ok" ]; then
        TITLE="Backup succeeded"
        BODY="Backup to ${RTGT} finished $(_fmt_time "$REND") after $(_fmt_dur $((REND - RSTART))): ${RSUM}."
    elif [ "$ROUT" = "partial" ]; then
        TITLE="Backup failed"
        BODY="Backup to ${RTGT} finished $(_fmt_time "$REND") with errors: $(printf '%s' "$RSUM" | cut -c1-600)"
    else
        TITLE="Backup failed"
        BODY="Backup to ${RTGT} (started $(_fmt_time "$RSTART")) failed: $(printf '%s' "$RSUM" | cut -c1-600)"
    fi
    echo "$(_ts): run ${RID} ${ROUT} (${RTGT}) — notifying"
    _notify "$TITLE" "$BODY"
done <<< "$RUNS"
# Keep the seen list short; history returns at most 25 runs per check.
if [ "$(wc -l < "$SEEN_FILE")" -gt 200 ]; then
    _TMP=$(mktemp) && tail -n 100 "$SEEN_FILE" > "$_TMP" && cat "$_TMP" > "$SEEN_FILE"
    rm -f "$_TMP"
fi
echo "$(_ts): ${NEW} new backup run(s)"
# Each run is reported once above; the condition state machine below has
# nothing more to do.
CONDITION=0; MSG=""; FPRINT=""
MON_BRES_END
            ;;
        health)
            cat << 'MON_HEALTH_END'
# ── Check: service health ────────────────────────────────────────────────────
_need_running
DB=$(timeout 60 "$START_CLI" db dump 2>&1)
if [ $? -ne 0 ] || [ -z "$DB" ]; then
    _fail "start-cli db dump failed: ${DB:0:200}"
fi
BAD_LINES=$(echo "$DB" | jq -r '
  .value.packageData | to_entries[]
  | .key as $id
  | .value.statusInfo as $st
  | (($st.desired // {}) | to_entries[0].value // "unknown") as $desired
  | select($desired == "running")
  | ([$st.health // {} | to_entries[] | select(.value.result == "failure" or .value.result == "error") | .value.name]) as $fails
  | ((if $st.started == null then ["not running"] else [] end)
     + (if ($fails | length) > 0 then ["health checks failing: " + ($fails | join(", "))] else [] end)) as $probs
  | select(($probs | length) > 0)
  | "\($id)\t\($probs | join("; "))"')
BAD_NOW=$(printf '%s\n' "$BAD_LINES" | awk -F'\t' 'NF{print $1}' | sort)
LASTBAD_FILE="${STATE_FILE}.lastbad"
OLD_BAD=""
[ -f "$LASTBAD_FILE" ] && OLD_BAD=$(cat "$LASTBAD_FILE")
# Debounce: only services bad on two consecutive runs are alertable
CONFIRMED=""
for s in $BAD_NOW; do
    if printf '%s\n' "$OLD_BAD" | grep -qx "$s"; then
        CONFIRMED="${CONFIRMED}${CONFIRMED:+ }$s"
    fi
done
mkdir -p "$(dirname "$LASTBAD_FILE")"
if [ -n "$BAD_NOW" ]; then
    printf '%s\n' "$BAD_NOW" > "$LASTBAD_FILE"
else
    rm -f "$LASTBAD_FILE"
fi
CONDITION=0; MSG=""; FPRINT=""
if [ -n "$CONFIRMED" ]; then
    CONDITION=1
    FPRINT=$(printf '%s\n' $CONFIRMED | sort | paste -sd, -)
    LIST=""
    for s in $CONFIRMED; do
        d=$(printf '%s\n' "$BAD_LINES" | awk -F'\t' -v id="$s" '$1==id{print $2; exit}')
        LIST="${LIST}${LIST:+, }${s} (${d})"
    done
    MSG="Service health: ${LIST}"
fi
echo "$(_ts): bad now: $(printf '%s' "$BAD_NOW" | tr '\n' ' ')| confirmed: ${CONFIRMED:-none}"
MON_HEALTH_END
            ;;
        drive)
            cat << 'MON_DRIVE_END'
# ── Check: NVMe drive health (SMART) ─────────────────────────────────────────
# Reads each controller's SMART / Health log via the embedded python helper.
# Alerts on: any critical-warning bit, spare capacity below the drive's own
# threshold, wear (percentage used) >= THRESHOLD, and media errors appearing
# or increasing (tracked per drive in a .media-<ctrl> state file).
CONDITION=0; MSG=""; FPRINT=""
FOUND=0; READ_OK=0
for CTRL in /sys/class/nvme/nvme*; do
    [ -d "$CTRL" ] || continue
    CNAME="${CTRL##*/}"
    DEV="/dev/${CNAME}"
    [ -e "$DEV" ] || continue
    FOUND=1
    MODEL=$(sed 's/[[:space:]]*$//' "$CTRL/model" 2>/dev/null)
    [ -n "$MODEL" ] || MODEL="$DEV"
    OUT=$(printf '%s' "$SMART_PY_B64" | base64 -d | python3 - "$DEV" 2>&1)
    if [ $? -ne 0 ] || [ -z "$OUT" ]; then
        echo "$(_ts): SMART read failed for $DEV: $OUT"
        CHECK_ERR="${CHECK_ERR}${CHECK_ERR:+; }SMART read failed for $DEV: $(printf '%s\n' "$OUT" | tail -1 | cut -c1-200)"
        continue
    fi
    READ_OK=$((READ_OK + 1))
    CW=$(printf '%s\n' "$OUT" | awk -F= '$1=="critical_warning"{print $2}')
    TEMP=$(printf '%s\n' "$OUT" | awk -F= '$1=="temperature_c"{print $2}')
    SPARE=$(printf '%s\n' "$OUT" | awk -F= '$1=="available_spare"{print $2}')
    SPARE_TH=$(printf '%s\n' "$OUT" | awk -F= '$1=="spare_threshold"{print $2}')
    USED=$(printf '%s\n' "$OUT" | awk -F= '$1=="percentage_used"{print $2}')
    MEDIA=$(printf '%s\n' "$OUT" | awk -F= '$1=="media_errors"{print $2}')
    PROBS=""
    if [ "${CW:-0}" -ne 0 ] 2>/dev/null; then
        BITS=""
        [ $((CW & 1)) -ne 0 ]  && BITS="${BITS}${BITS:+, }spare capacity below threshold"
        [ $((CW & 2)) -ne 0 ]  && BITS="${BITS}${BITS:+, }temperature out of safe range (${TEMP}C)"
        [ $((CW & 4)) -ne 0 ]  && BITS="${BITS}${BITS:+, }media reliability degraded"
        [ $((CW & 8)) -ne 0 ]  && BITS="${BITS}${BITS:+, }drive is in READ-ONLY mode"
        [ $((CW & 16)) -ne 0 ] && BITS="${BITS}${BITS:+, }volatile memory backup failed"
        PROBS="CRITICAL WARNING: ${BITS:-code ${CW}}"
    fi
    if [ "${SPARE:-100}" -lt "${SPARE_TH:-0}" ] 2>/dev/null; then
        PROBS="${PROBS}${PROBS:+; }spare capacity ${SPARE}% below drive threshold ${SPARE_TH}%"
    fi
    if [ "${USED:-0}" -ge "$THRESHOLD" ] 2>/dev/null; then
        PROBS="${PROBS}${PROBS:+; }${USED}% of rated endurance used (alert threshold ${THRESHOLD}%)"
    fi
    MEDIA_FILE="${STATE_FILE}.media-${CNAME}"
    LAST_MEDIA=""
    [ -f "$MEDIA_FILE" ] && LAST_MEDIA=$(cat "$MEDIA_FILE")
    case "$LAST_MEDIA" in *[!0-9]*) LAST_MEDIA="" ;; esac
    if [ -n "$LAST_MEDIA" ] && [ "${MEDIA:-0}" -gt "$LAST_MEDIA" ] 2>/dev/null; then
        PROBS="${PROBS}${PROBS:+; }media errors increased from ${LAST_MEDIA} to ${MEDIA}"
    elif [ -z "$LAST_MEDIA" ] && [ "${MEDIA:-0}" -gt 0 ] 2>/dev/null; then
        PROBS="${PROBS}${PROBS:+; }drive reports ${MEDIA} media error(s)"
    fi
    mkdir -p "$(dirname "$MEDIA_FILE")"
    printf '%s\n' "${MEDIA:-0}" > "$MEDIA_FILE"
    if [ -n "$PROBS" ]; then
        CONDITION=1
        FPRINT="${FPRINT}${FPRINT:+,}${CNAME}:cw${CW}:sp${SPARE}:wear${USED}:me${MEDIA}"
        MSG="${MSG}${MSG:+ | }${MODEL} (${DEV}): ${PROBS}"
    fi
    echo "$(_ts): ${DEV} ${MODEL}: temp ${TEMP}C, spare ${SPARE}%, wear ${USED}%, media errors ${MEDIA}, critical warning ${CW}"
done
if [ "$FOUND" -eq 0 ]; then
    _fail "no NVMe drives found (this alert supports NVMe drives only)"
fi
# Every drive failed to answer: there is no result to judge, so don't let the
# empty CONDITION below read as "all clear".
[ "$READ_OK" -eq 0 ] && _fail "$CHECK_ERR"
[ -n "$MSG" ] && MSG="Drive health: ${MSG}"
MON_DRIVE_END
            ;;
    esac

    # Shared alert state machine + notification dispatch
    cat << 'MON_TAIL_END'
# ── Check-failure bookkeeping ────────────────────────────────────────────────
# Reaching here means the check produced a result. CHECK_ERR holds any part
# of it that could not run (e.g. one drive of two unreadable).
if [ -n "$CHECK_ERR" ]; then _check_failed "$CHECK_ERR"; else _check_ok; fi
# ── Alert state machine ──────────────────────────────────────────────────────
_now=$(date +%s)
if [ "$CONDITION" -eq 0 ]; then
    if [ -f "$STATE_FILE" ]; then
        rm -f "$STATE_FILE"
        echo "$(_ts): condition cleared — alert state reset (no recovery message by design)"
    else
        echo "$(_ts): OK"
    fi
    exit 0
fi
OLD_FP=""; OLD_TS=0
if [ -f "$STATE_FILE" ]; then
    OLD_FP=$(sed -n '1p' "$STATE_FILE")
    OLD_TS=$(sed -n '2p' "$STATE_FILE")
    case "$OLD_TS" in ''|*[!0-9]*) OLD_TS=0 ;; esac
fi
AGE=$(( _now - OLD_TS ))
if [ "$FPRINT" = "$OLD_FP" ] && [ "$AGE" -lt "$REMIND_SECS" ]; then
    echo "$(_ts): condition persists (last alert $((AGE/60)) min ago) — repeat suppressed"
    exit 0
fi
echo "$(_ts): ALERT — $MSG"
mkdir -p "$(dirname "$STATE_FILE")"
{ printf '%s\n' "$FPRINT"; printf '%s\n' "$_now"; } > "$STATE_FILE"
_notify "$NOTIF_TITLE" "$MSG"
MON_TAIL_END
}

# Build the chroot commands that install or update one monitor instance
# (script + tagged cron entry). Sets nameref $1 to the commands.
# $2=type $3=threshold $4=excludes $5=shell_cmd $6=startos $7=level
# $8=schedule $9=backup-target-id $10=instance name $11=cleanup-legacy (1 =
# also remove the unnamed v60/v61 singleton script + cron entry for this type
# in the same session)
_monitor_install_cmds() {
    local -n _mic_out="$1"; shift
    local type="$1" threshold="$2" excludes="$3" shell_cmd="$4" startos="$5" level="$6" schedule="$7"
    local target_id="${8:-}" name="${9:-}" cleanup_legacy="${10:-0}"

    # Defense-in-depth: type and name become root-owned file paths and cron
    # lines. Every caller already validates, but guard here too so a bad value
    # can never be written as a path (this is how v62 produced orphaned
    # "<type>-/usr/local/bin/startos-monitor-<type>" cron entries).
    case "$type" in
        disk|backup-age|backup-ok|backup-failed|health|drive) ;;
        *) print_error "Invalid monitor type '${type}'."; return 1 ;;
    esac
    if [[ -n "$name" ]] && ! [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
        print_error "Invalid monitor name '${name}' (letters, digits, hyphens only)."
        return 1
    fi
    if [[ -n "$target_id" ]] && ! [[ "$target_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
        print_error "Invalid backup target id '${target_id}'."
        return 1
    fi
    local inst="${type}${name:+-${name}}"

    local script_content encoded_script
    script_content=$(_monitor_script_content "$type" "$threshold" "$excludes" "$shell_cmd" "$startos" "$level" "$target_id" "$name")
    encoded_script=$(printf '%s' "$script_content" | base64 -w 0)

    local install_ts notify_desc=""
    install_ts=$(date '+%Y.%m.%d %H:%M:%S %Z')
    [[ -n "$shell_cmd" ]] && notify_desc="shell"
    [[ "$startos" == "1" ]] && notify_desc="${notify_desc}${notify_desc:+ + }startos/${level}"
    local cron_comment="# startos-admin v${VERSION} | Added: ${install_ts} | Action: Alerts | Monitor: ${inst} | Threshold: ${threshold}${target_id:+ | Target: ${target_id}} | Notify: ${notify_desc}"
    local cron_line="${schedule} ${_MONITOR_BIN_PREFIX}${inst} >> ${_MONITOR_DATA_PREFIX}${inst}.log 2>&1"
    local encoded_comment encoded_cron
    encoded_comment=$(printf '%s' "$cron_comment" | base64 -w 0)
    encoded_cron=$(printf '%s' "$cron_line" | base64 -w 0)

    debug_log "Building install commands for monitor '$inst' → ${_MONITOR_BIN_PREFIX}${inst}"

    # Migrating a legacy unnamed singleton: remove its script + cron entry in
    # the same session. The trailing space in the grep pattern keeps the bare
    # type from matching named instances (".../startos-monitor-disk " vs
    # ".../startos-monitor-disk-warn50 ").
    local legacy_cmds=""
    if [[ "$cleanup_legacy" == "1" ]]; then
        legacy_cmds="crontab -l 2>/dev/null | grep -v 'startos-monitor-${type} ' | grep -Fv '| Monitor: ${type} |' | crontab -
rm -f ${_MONITOR_BIN_PREFIX}${type}
"
    fi

    # Remove any existing cron entry for this instance, write the script,
    # then add the tagged comment + cron line.
    _mic_out="${legacy_cmds}mkdir -p ${_STARTOS_DATA_DIR}
{ crontab -l 2>/dev/null || true; } | awk -v t1=\"| Monitor: ${inst} |\" -v t2=\"# startos-monitor-${inst}\" 'index(\$0,t1)||index(\$0,t2)==1{skip=1;next} skip{skip=0;next} {print}' | crontab -
printf '%s' \"${encoded_script}\" | base64 -d > ${_MONITOR_BIN_PREFIX}${inst}
chmod +x ${_MONITOR_BIN_PREFIX}${inst}
{ crontab -l 2>/dev/null; printf '%s' \"${encoded_comment}\" | base64 -d; echo; printf '%s' \"${encoded_cron}\" | base64 -d; echo; } | crontab -"
}

# Install or update one monitor instance via _apply_or_stage.
# Arguments as _monitor_install_cmds, without the nameref.
install_monitor() {
    local cmds=""
    _monitor_install_cmds cmds "$@" || return 1
    _apply_or_stage "$(_monitor_display "$1" "${9:-}"): threshold ${2}, ${7}" "$cmds" || return 1
}

# Alerts generated before their type's _monitor_format need rebuilding: v71
# and older backup staleness alerts fail on StartOS 0.4.1+ (the password-
# argument change) and don't report a check that keeps failing; v72 ones
# can't follow StartOS 0.4.3's registered backup targets. Prints
# "type<TAB>name<TAB>path<TAB>format" for each.
_monitor_outdated() {
    local type name path fmt
    while IFS=$'\t' read -r type name path; do
        [[ -n "$path" ]] || continue
        fmt=$(grep -m1 '^MONITOR_FORMAT=' "$path" 2>/dev/null | cut -d'"' -f2) || fmt=""
        [[ "$fmt" =~ ^[0-9]+$ ]] || fmt=1
        (( fmt < $(_monitor_format "$type") )) && printf '%s\t%s\t%s\t%s\n' "$type" "$name" "$path" "$fmt"
    done < <(_monitor_installed)
    return 0
}

# Rebuild one saved alert script (from a Save file) if it predates
# _MONITOR_FORMAT. $1=instance suffix (type or type-name) $2=script base64
# $3=nameref out (new base64). Returns 1 if no rebuild was needed or possible.
_monitor_rebuild_saved() {
    local inst="$1" b64="$2"
    local -n _mrs_out="$3"
    [[ "$inst" =~ ^(disk|backup-age|backup-ok|backup-failed|health|drive)(-([a-zA-Z0-9][a-zA-Z0-9-]*))?$ ]] || return 1
    local type="${BASH_REMATCH[1]}" name="${BASH_REMATCH[3]}"
    local tmp
    tmp=$(mktemp) || return 1
    printf '%s' "$b64" | base64 -d > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    local fmt
    fmt=$(grep -m1 '^MONITOR_FORMAT=' "$tmp" | cut -d'"' -f2) || fmt=""
    [[ "$fmt" =~ ^[0-9]+$ ]] || fmt=1
    if (( fmt >= $(_monitor_format "$type") )); then rm -f "$tmp"; return 1; fi
    local thr="" cmd="" sos="" lvl="" exc="" tgt=""
    _monitor_read_config "$tmp" thr cmd sos lvl exc tgt
    rm -f "$tmp"
    [[ -n "$tgt" ]] && ! [[ "$tgt" =~ ^[A-Za-z0-9._-]+$ ]] && return 1
    _mrs_out=$(_monitor_script_content "$type" "$thr" "$exc" "$cmd" "${sos:-0}" "${lvl:-warning}" "$tgt" "$name" | base64 -w 0)
    print_info "Alert '${inst}' was saved by an older startos-admin — it will be rebuilt with its saved settings."
    return 0
}

# At launch: offer to rebuild outdated alerts with their current settings, all
# in one restart. Skipped when that rebuild is already staged. Declining is
# fine; the offer comes back next launch.
_REBUILD_LABEL="Rebuild alerts for startos-admin v${VERSION}"

# Plan the rebuild of every outdated alert, keeping each one's settings and
# schedule. Sets the namerefs: $1 = command block, $2 = how many can be
# rebuilt, $3 = one display line per outdated alert (newline-separated), $4 =
# 1 if any predates v72, $5 = 1 if any backup staleness alert predates v73.
# An alert with no cron line is listed but not rebuilt.
_monitor_rebuild_plan() {
    local -n _mrp_cmds="$1" _mrp_n="$2" _mrp_list="$3" _mrp_v72="$4" _mrp_v73="$5"
    _mrp_cmds=""; _mrp_n=0; _mrp_list=""; _mrp_v72=0; _mrp_v73=0
    local lines
    lines=$(_monitor_outdated)
    [[ -n "$lines" ]] || return 0
    local type name path fmt
    while IFS=$'\t' read -r type name path fmt; do
        local suffix="${path##"${_MONITOR_BIN_PREFIX}"}"
        local thr="" cmd="" sos="" lvl="" exc="" tgt="" sched
        _monitor_read_config "$path" thr cmd sos lvl exc tgt
        sched=$(_monitor_read_schedule "$suffix")
        local note=""
        (( fmt < 2 )) && _mrp_v72=1
        [[ "$type" == "backup-age" ]] && (( fmt < 3 )) && _mrp_v73=1
        if [[ "$type" == "backup-age" ]] && (( fmt < 2 )); then
            note=" ${YELLOW}— not working on StartOS 0.4.1 and newer${NC}"
        elif [[ "$type" == "backup-age" && -n "$tgt" ]] && _backup_targets_registered; then
            note=" ${YELLOW}— its target check needs this update on StartOS 0.4.3${NC}"
        fi
        if [[ -z "$sched" ]]; then
            _mrp_list+="    ${DIM}•${NC} $(_monitor_display "$type" "$name")${note} ${RED}(no cron schedule found — remove and re-add it under Alerts)${NC}"$'\n'
            continue
        fi
        local c=""
        _monitor_install_cmds c "$type" "$thr" "$exc" "$cmd" "${sos:-0}" "${lvl:-warning}" "$sched" "$tgt" "$name" || continue
        _mrp_list+="    ${DIM}•${NC} $(_monitor_display "$type" "$name")${note}"$'\n'
        _mrp_cmds+="${_mrp_cmds:+$'\n'}${c}"
        _mrp_n=$(( _mrp_n + 1 ))
    done <<< "$lines"
    return 0
}

# What a rebuild brings in, for the lists above. $1/$2 = the v72/v73 flags.
_monitor_rebuild_reasons() {
    echo -e "  Rebuilding keeps each alert's settings and schedule, and brings in:"
    if [[ "$1" -eq 1 ]]; then
        echo -e "    ${DIM}•${NC} Backup staleness alerts no longer use your backup password."
        echo -e "    ${DIM}•${NC} Every alert notifies you if its check fails ${BOLD}3 times in a row${NC}."
    fi
    [[ "$2" -eq 1 ]] && \
        echo -e "    ${DIM}•${NC} Backup staleness alerts understand StartOS 0.4.3's backup targets."
    return 0
}

# At launch: offer to rebuild outdated alerts with their current settings, all
# in one restart. Skipped when that rebuild is already staged. Declining is
# fine; the offer comes back next launch.
_offer_monitor_rebuild() {
    [[ -n "$(_monitor_outdated)" ]] || return 0
    if _staged_labels 2>/dev/null | grep -qF "$_REBUILD_LABEL"; then
        return 0
    fi
    local all_cmds="" n=0 list="" any_v72=0 any_v73=0
    _monitor_rebuild_plan all_cmds n list any_v72 any_v73

    print_header
    print_section "Alerts need updating"
    echo ""
    echo -e "  These alerts were installed by an older startos-admin:"
    echo ""
    printf '%s' "$list" | while IFS= read -r l; do echo -e "$l"; done
    echo ""
    [[ $n -gt 0 ]] || { pause; return 0; }
    _monitor_rebuild_reasons "$any_v72" "$any_v73"
    if ! confirm "Rebuild ${n} alert(s) now?"; then
        _BACK=0
        print_info "Not rebuilt. You'll be asked again next time you start startos-admin."
        pause
        return 0
    fi
    _apply_or_stage "$_REBUILD_LABEL (${n})" "$all_cmds" || { _BACK=0; return 0; }
}

# At launch on StartOS 0.4.3+: backup schedules saved for a drive by
# "uuid-<UUID>" stop working, because 0.4.3 rejects "disk-/dev/sdX" ids and
# backs up only to registered targets. Offer to switch each one to its drive's
# registered id (password file renamed with it), all in one restart, and name
# the drives that still have to be added in System → Backups.
_UUIDFIX_LABEL="Update drive backup schedules for StartOS 0.4.3"
_offer_backup_target_upgrade() {
    _backup_targets_registered || return 0
    local cron_output
    cron_output=$(sudo crontab -u root -l 2>/dev/null) || return 0
    printf '%s\n' "$cron_output" | grep -q 'backup create "disk-\$(readlink -e /dev/disk/by-uuid/' || return 0
    if _staged_labels 2>/dev/null | grep -qF "$_UUIDFIX_LABEL"; then
        return 0
    fi
    [[ "$(_startos_state)" == "Running" ]] || return 0
    local tlist
    tlist=$(timeout 120 start-cli backup target list 2>/dev/null) || return 0

    local -a fixed=() missing=()
    local cmds="" line new keys
    while IFS= read -r line; do
        [[ "$line" == *'backup create "disk-$(readlink -e /dev/disk/by-uuid/'* ]] || continue
        local rc=0
        _backup_line_to_registered "$line" "$tlist" new keys || rc=$?
        if [[ $rc -eq 0 ]]; then
            local old_key="${keys% *}" new_key="${keys#* }"
            fixed+=("${old_key} → ${new_key}  ${DIM}($(echo "$line" | awk '{print $1,$2,$3,$4,$5}'))${NC}")
            local b64_old b64_new
            b64_old=$(printf '%s' "$line" | base64 -w 0)
            b64_new=$(printf '%s' "$new" | base64 -w 0)
            cmds+="if [ -f ${_SECRET_DIR}/backup-pass-${old_key} ]; then cp -p ${_SECRET_DIR}/backup-pass-${old_key} ${_SECRET_DIR}/backup-pass-${new_key}; fi
__o=\$(printf '%s' \"${b64_old}\" | base64 -d); __n=\$(printf '%s' \"${b64_new}\" | base64 -d)
crontab -l 2>/dev/null | while IFS= read -r __l; do if [ \"\$__l\" = \"\$__o\" ]; then printf '%s\n' \"\$__n\"; else printf '%s\n' \"\$__l\"; fi; done | crontab -
"
        elif [[ $rc -eq 2 ]]; then
            missing+=("$(_backup_key_from_cron_line "$line")  ${DIM}($(echo "$line" | awk '{print $1,$2,$3,$4,$5}'))${NC}")
        fi
    done <<< "$cron_output"
    [[ ${#fixed[@]} -gt 0 || ${#missing[@]} -gt 0 ]] || return 0

    print_header
    print_section "Drive backup schedules need updating"
    echo ""
    echo -e "  StartOS 0.4.3 backs up only to targets added in System → Backups and no longer"
    echo -e "  accepts the drive names these schedules use, so they would fail."
    echo ""
    local f
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "  ${YELLOW}Not added in System → Backups yet:${NC}"
        for f in "${missing[@]}"; do echo -e "    ${DIM}•${NC} ${f}"; done
        echo -e "  ${DIM}Add each drive there (its existing backups are kept), then restart${NC}"
        echo -e "  ${DIM}startos-admin to update these schedules.${NC}"
        echo ""
    fi
    if [[ ${#fixed[@]} -eq 0 ]]; then
        pause; return 0
    fi
    echo -e "  ${BOLD}Can be switched to the drive's StartOS id now:${NC}"
    for f in "${fixed[@]}"; do echo -e "    ${DIM}•${NC} ${f}"; done
    echo ""
    if ! confirm "Update ${#fixed[@]} schedule(s) now?"; then
        _BACK=0
        print_info "Not updated. You'll be asked again next time you start startos-admin."
        pause
        return 0
    fi
    _apply_or_stage "$_UUIDFIX_LABEL (${#fixed[@]})" "$cmds" || { _BACK=0; return 0; }
}

# Wizard: install or update one monitor instance (prefilled if installed).
# $1=type $2=instance name $3=legacy (1 = prefill from + migrate the unnamed
# v60/v61 singleton of this type)
# Ask for a new alert's name, offering one built from its settings. Names
# only tell alerts of the same type apart, so the suggestion is the setting
# that differs between them (threshold), or the type itself. An existing
# name is allowed only after confirming it should be replaced.
_pick_monitor_name() {
    local -n _pmn_out="$1"
    local type="$2" thr="$3" base sugg n=2
    case "$type" in
        disk)          base="${thr}pct" ;;
        backup-age)    base="${thr}d" ;;
        drive)         base="wear${thr}" ;;
        health)        base="watchdog" ;;
        backup-ok)     base="succeeded" ;;
        backup-failed) base="failed" ;;
        *)             base="default" ;;
    esac
    sugg="$base"
    while [[ -f "${_MONITOR_BIN_PREFIX}${type}-${sugg}" ]]; do
        sugg="${base}-${n}"; (( n++ ))
    done
    echo ""
    echo -e "  ${BOLD}Name this alert:${NC}"
    echo -e "  ${DIM}The name tells it apart from other alerts of this type in menus, logs and${NC}"
    echo -e "  ${DIM}notifications. Press Enter to use the suggestion.${NC}"
    local nm
    while true; do
        _read nm "  Alert name [${sugg}]: " || return 1
        [[ -z "$nm" ]] && nm="$sugg"
        if ! [[ "$nm" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
            print_warn "Use only letters, numbers, and hyphens."
            continue
        fi
        if [[ -f "${_MONITOR_BIN_PREFIX}${type}-${nm}" ]]; then
            print_warn "A '${nm}' alert of this type already exists."
            confirm "Replace it with these settings?" || { [[ $_BACK -eq 1 ]] && return 1; continue; }
        fi
        break
    done
    _pmn_out="$nm"
}

_monitor_install_flow() {
    local type="$1" name="$2" legacy="${3:-0}"
    # An empty name means a new alert: it is named after the other settings.
    local new_alert=0
    [[ -z "$name" ]] && new_alert=1
    local inst="${type}-${name}"
    local label
    if (( new_alert )); then
        label="New $(_monitor_label "$type")"
    else
        label=$(_monitor_display "$type" "$name")
    fi

    print_header
    print_section "$label"
    echo ""
    _nav_tip

    # Prefill from an existing install (the named instance, or the legacy
    # unnamed singleton when migrating)
    local prefill_path="${_MONITOR_BIN_PREFIX}${inst}"
    [[ "$legacy" == "1" ]] && prefill_path="${_MONITOR_BIN_PREFIX}${type}"
    local cur_thr="" cur_cmd="" cur_sos="" cur_lvl="" cur_exc="" cur_sched="" cur_tgt=""
    if (( ! new_alert )) && [[ -f "$prefill_path" ]]; then
        _monitor_read_config "$prefill_path" cur_thr cur_cmd cur_sos cur_lvl cur_exc cur_tgt
        if [[ "$legacy" == "1" ]]; then
            cur_sched=$(_monitor_read_schedule "$type")
            print_info "Migrating the unnamed alert to '${name}' — current values shown as defaults."
        else
            cur_sched=$(_monitor_read_schedule "$inst")
            print_info "Already installed — current values shown as defaults; this will update it."
        fi
        echo ""
    fi

    # ── backup-age: optionally also watch one backup target ─────────────────
    local mon_target=""
    if [[ "$type" == "backup-age" ]]; then
        echo -e "  ${DIM}StartOS records when each service was last backed up successfully (to any${NC}"
        echo -e "  ${DIM}target). This alert reads those times — no backup password needed.${NC}"
        echo ""
        echo -e "  ${DIM}Optionally it can also watch one backup target, and alert when that target${NC}"
        echo -e "  ${DIM}hasn't received a backup within the threshold — useful when you back up to${NC}"
        echo -e "  ${DIM}more than one place and want to know if one of them stops.${NC}"
        echo ""
        print_info "Fetching backup targets..."
        local raw_targets
        if ! raw_targets=$(start-cli backup target list 2>&1); then
            # Right after a restart StartOS answers "Method not found" until it
            # finishes initializing; _require_running says so instead.
            if _require_running; then
                print_error "Failed to list backup targets."
                echo -e "${RED}${raw_targets}${NC}"
            fi
            pause; return 1
        fi
        local -a targets=()
        mapfile -t targets <<< "$(parse_backup_targets "$raw_targets")"
        [[ -z "${targets[0]:-}" ]] && targets=()
        echo ""
        echo -e "  ${BOLD}Also watch a backup target?${NC}"
        echo -e "    ${BOLD}0)${NC} No — services only"
        local i=1 tgt
        for tgt in "${targets[@]}"; do
            echo -e "    ${BOLD}${i})${NC} ${tgt}"
            (( i++ ))
        done
        _backup_targets_registered && \
            echo -e "  ${DIM}Only targets added in System → Backups are listed.${NC}"
        [[ -n "$cur_tgt" ]] && echo -e "  ${DIM}Current: ${cur_tgt} — press Enter to keep${NC}"
        echo ""
        local tgt_choice
        while true; do
            _read tgt_choice "  Choice [0-$((i-1))${cur_tgt:+, Enter to keep}]: " || return 1
            if [[ -z "$tgt_choice" && -n "$cur_tgt" ]]; then
                mon_target="$cur_tgt"; break
            fi
            if [[ "$tgt_choice" == "0" ]]; then
                mon_target=""; break
            fi
            if [[ "$tgt_choice" =~ ^[0-9]+$ ]] && (( tgt_choice >= 1 && tgt_choice < i )); then
                local picked_id
                picked_id=$(echo "${targets[$((tgt_choice-1))]}" | awk '{print $1}')
                _backup_pick_key "$picked_id" mon_target || { pause; return 1; }
                break
            fi
            print_warn "Enter a number between 0 and $((i-1))${cur_tgt:+, or Enter to keep current}."
        done
        if [[ "$mon_target" == uuid-* ]] && _backup_targets_registered; then
            local mon_gid
            if mon_gid=$(_backup_uuid_to_registered "$mon_target" "$raw_targets"); then
                print_info "This drive is now registered in StartOS as '${mon_gid}'; the alert will use that id."
                mon_target="$mon_gid"
            else
                print_warn "This drive hasn't been added in System → Backups, so StartOS 0.4.3 won't back"
                print_warn "up to it and this alert will report it as not added until you add it."
            fi
        fi
        if [[ -n "$mon_target" ]] && ! [[ "$mon_target" =~ ^[A-Za-z0-9._-]+$ ]]; then
            print_error "Unexpected characters in target id '${mon_target}'. Aborting."
            pause; return 1
        fi
        echo ""
    fi

    # ── backup-ok / backup-failed: needs StartOS 0.4.3's backup history ─────
    if [[ "$type" == "backup-ok" || "$type" == "backup-failed" ]]; then
        local bh_out
        if ! bh_out=$(timeout 60 start-cli backup history list --limit 1 --format json 2>&1) \
           || ! printf '%s' "$bh_out" | jq -e '.runs | type == "array"' >/dev/null 2>&1; then
            if _require_running; then
                if _backup_targets_registered; then
                    print_error "Could not read the backup history:"
                    echo -e "${RED}${bh_out:0:300}${NC}"
                else
                    print_warn "This alert needs StartOS 0.4.3 or newer, which keeps a history of backup"
                    print_warn "runs. This server runs StartOS $(_os_version), which notifies you itself"
                    print_warn "when a backup completes or fails."
                fi
            fi
            pause; return 1
        fi
        if [[ "$type" == "backup-ok" ]]; then
            echo -e "  ${DIM}Sends one notification for each backup that finishes without errors:${NC}"
            echo -e "  ${DIM}the target, when it finished, how long it took and how many services.${NC}"
        else
            echo -e "  ${DIM}Sends one notification for each backup that fails, or finishes with any${NC}"
            echo -e "  ${DIM}service or volume reporting an error, with the error messages.${NC}"
        fi
        echo -e "  ${DIM}StartOS 0.4.3 records each finished backup in System → Backups → History but${NC}"
        echo -e "  ${DIM}no longer sends a notification; this alert reads that history.${NC}"
        echo -e "  ${DIM}A backup that never finishes is not reported here — a Backup staleness${NC}"
        echo -e "  ${DIM}alert catches that.${NC}"
        echo ""
    fi

    # ── drive: verify NVMe + python3, and show current SMART readings ───────
    if [[ "$type" == "drive" ]]; then
        if ! command -v python3 >/dev/null 2>&1; then
            print_error "python3 not found on this system — the drive health alert requires it."
            pause; return 1
        fi
        local -a drv_ctrls=()
        local drv_c
        for drv_c in /sys/class/nvme/nvme*; do
            [[ -d "$drv_c" ]] && drv_ctrls+=("$drv_c")
        done
        if [[ ${#drv_ctrls[@]} -eq 0 ]]; then
            print_warn "No NVMe drives found — this alert supports NVMe drives only."
            pause; return 1
        fi
        echo -e "  ${DIM}Reads each NVMe drive's SMART health log directly from the kernel —${NC}"
        echo -e "  ${DIM}no extra packages needed. Current readings:${NC}"
        echo ""
        local drv_ok=0
        for drv_c in "${drv_ctrls[@]}"; do
            local drv_dev="/dev/${drv_c##*/}" drv_model drv_out
            drv_model=$(sed 's/[[:space:]]*$//' "${drv_c}/model" 2>/dev/null)
            [[ -n "$drv_model" ]] || drv_model="$drv_dev"
            if drv_out=$(printf '%s' "$_NVME_SMART_PY" | sudo python3 - "$drv_dev" 2>&1); then
                local drv_temp drv_spare drv_used drv_media drv_cw
                drv_temp=$(awk -F= '$1=="temperature_c"{print $2}' <<< "$drv_out")
                drv_spare=$(awk -F= '$1=="available_spare"{print $2}' <<< "$drv_out")
                drv_used=$(awk -F= '$1=="percentage_used"{print $2}' <<< "$drv_out")
                drv_media=$(awk -F= '$1=="media_errors"{print $2}' <<< "$drv_out")
                drv_cw=$(awk -F= '$1=="critical_warning"{print $2}' <<< "$drv_out")
                echo -e "    ${BOLD}${drv_model}${NC} ${DIM}(${drv_dev})${NC}: temp ${drv_temp}°C, spare ${drv_spare}%, wear ${drv_used}%, media errors ${drv_media}, critical warning ${drv_cw}"
                (( drv_ok++ ))
            else
                print_warn "SMART read failed for ${drv_dev}: ${drv_out}"
            fi
        done
        echo ""
        if [[ $drv_ok -eq 0 ]]; then
            print_error "No drive answered the SMART query — cannot install this alert."
            pause; return 1
        fi
    fi

    # ── Step 1: Threshold ────────────────────────────────────────────────────
    local threshold=""
    case "$type" in
        disk)
            echo -e "  ${BOLD}Alert when disk usage reaches what percent?${NC}"
            [[ -n "$cur_thr" ]] && echo -e "  ${DIM}Current: ${cur_thr}% — press Enter to keep${NC}"
            while true; do
                _read threshold "  Threshold % [1-99${cur_thr:+, Enter to keep}]: " || return 1
                [[ -z "$threshold" && -n "$cur_thr" ]] && { threshold="$cur_thr"; break; }
                [[ "$threshold" =~ ^[0-9]+$ ]] && (( threshold >= 1 && threshold <= 99 )) && break
                print_warn "Enter a whole number between 1 and 99."
            done
            ;;
        backup-age)
            echo -e "  ${BOLD}Alert when a service has not been backed up for how many days?${NC}"
            echo -e "  ${DIM}Services that have NEVER been backed up always count as stale.${NC}"
            [[ -n "$cur_thr" ]] && echo -e "  ${DIM}Current: ${cur_thr} day(s) — press Enter to keep${NC}"
            while true; do
                _read threshold "  Days [1-365${cur_thr:+, Enter to keep}]: " || return 1
                [[ -z "$threshold" && -n "$cur_thr" ]] && { threshold="$cur_thr"; break; }
                [[ "$threshold" =~ ^[0-9]+$ ]] && (( threshold >= 1 && threshold <= 365 )) && break
                print_warn "Enter a whole number between 1 and 365."
            done
            ;;
        backup-ok|backup-failed)
            threshold="0"
            ;;
        health)
            threshold="0"
            echo -e "  Alerts when a service that should be running has failing health checks"
            echo -e "  or is not running — only after the problem persists across ${BOLD}two${NC}"
            echo -e "  consecutive checks (avoids noise from restarts and updates)."
            echo ""
            ;;
        drive)
            echo -e "  ${BOLD}Alert when SSD wear reaches what percent of rated endurance?${NC}"
            echo -e "  ${DIM}90 is a sensible default. Critical warnings, low spare capacity, and${NC}"
            echo -e "  ${DIM}new media errors always alert, regardless of this threshold.${NC}"
            [[ -n "$cur_thr" ]] && echo -e "  ${DIM}Current: ${cur_thr}% — press Enter to keep${NC}"
            while true; do
                _read threshold "  Wear threshold % [1-100${cur_thr:+, Enter to keep}]: " || return 1
                [[ -z "$threshold" && -n "$cur_thr" ]] && { threshold="$cur_thr"; break; }
                [[ "$threshold" =~ ^[0-9]+$ ]] && (( threshold >= 1 && threshold <= 100 )) && break
                print_warn "Enter a whole number between 1 and 100."
            done
            ;;
    esac

    # ── Step 2 (backup-age only): exclude services ───────────────────────────
    local excludes=""
    if [[ "$type" == "backup-age" ]]; then
        echo ""
        print_info "Fetching installed services..."
        local pkg_list
        if pkg_list=$(start-cli package list 2>/dev/null); then
            local -a packages=()
            mapfile -t packages <<< "$(parse_package_ids "$pkg_list")"
            echo ""
            echo -e "  ${BOLD}Exclude services from this check?${NC} ${DIM}(e.g. intentionally not backed up)${NC}"
            local i=1
            local pkg
            for pkg in "${packages[@]}"; do
                echo -e "    ${BOLD}${i})${NC} ${pkg}"
                (( i++ ))
            done
            [[ -n "$cur_exc" ]] && echo -e "  ${DIM}Current excludes: ${cur_exc} — press Enter to keep, or '-' for none${NC}"
            echo ""
            while true; do
                local exc_sel
                _read exc_sel "  Exclude (numbers comma-separated, blank = ${cur_exc:+keep current}${cur_exc:-none}, '-' = none): " || return 1
                if [[ -z "$exc_sel" ]]; then
                    excludes="$cur_exc"; break
                elif [[ "$exc_sel" == "-" ]]; then
                    excludes=""; break
                elif [[ "$exc_sel" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
                    local valid=true sel=()
                    IFS=',' read -ra parts <<< "$exc_sel"
                    local part
                    for part in "${parts[@]}"; do
                        if (( part >= 1 && part <= ${#packages[@]} )); then
                            sel+=("${packages[$((part-1))]}")
                        else
                            valid=false; break
                        fi
                    done
                    if $valid; then
                        excludes=$(IFS=','; echo "${sel[*]}")
                        break
                    fi
                    print_warn "Numbers must be between 1 and ${#packages[@]}."
                else
                    print_warn "Enter numbers like 1,3 or blank or '-'."
                fi
            done
        else
            print_warn "Could not list services — no excludes configured."
        fi
    fi

    # ── Step 3: Schedule ─────────────────────────────────────────────────────
    [[ -n "$cur_sched" ]] && echo -e "\n  ${DIM}Current schedule: ${cur_sched}${NC}"
    local CRON_SCHEDULE
    case "$type" in
        disk)
            _pick_monitor_schedule CRON_SCHEDULE \
                "Hourly" "0 * * * *" \
                "Every 6 hours" "0 */6 * * *" \
                "Daily at 9 AM" "0 9 * * *" || return 1 ;;
        backup-age)
            _pick_monitor_schedule CRON_SCHEDULE \
                "Daily at 9 AM" "0 9 * * *" \
                "Weekly (Mon 9 AM)" "0 9 * * 1" || return 1 ;;
        backup-ok|backup-failed)
            echo -e "\n  ${DIM}How soon after a backup finishes you hear about it.${NC}"
            _pick_monitor_schedule CRON_SCHEDULE \
                "Every 5 minutes" "*/5 * * * *" \
                "Every 15 minutes" "*/15 * * * *" \
                "Every 30 minutes" "*/30 * * * *" || return 1 ;;
        health)
            _pick_monitor_schedule CRON_SCHEDULE \
                "Every 5 minutes" "*/5 * * * *" \
                "Every 15 minutes" "*/15 * * * *" \
                "Every 30 minutes" "*/30 * * * *" || return 1 ;;
        drive)
            _pick_monitor_schedule CRON_SCHEDULE \
                "Daily at 9 AM" "0 9 * * *" \
                "Every 6 hours" "0 */6 * * *" \
                "Weekly (Mon 9 AM)" "0 9 * * 1" || return 1 ;;
    esac

    # ── Step 4: Notification method ──────────────────────────────────────────
    local notify_cmd notify_sos notify_lvl
    local new_lvl="warning"
    case "$type" in backup-ok) new_lvl="info" ;; backup-failed) new_lvl="error" ;; esac
    _pick_monitor_notify notify_cmd notify_sos notify_lvl "$cur_cmd" "$cur_sos" "$cur_lvl" "$new_lvl" || return 1

    # ── Step 5 (new alerts): Name ────────────────────────────────────────────
    if (( new_alert )); then
        _pick_monitor_name name "$type" "$threshold" || return 1
        inst="${type}-${name}"
        label=$(_monitor_display "$type" "$name")
    fi

    # ── Review ───────────────────────────────────────────────────────────────
    echo ""
    print_section "Review: ${label}"
    echo ""
    echo -e "  ${BOLD}Name:${NC}      ${name}"
    case "$type" in
        disk)       echo -e "  ${BOLD}Threshold:${NC} ${threshold}% disk usage" ;;
        backup-age) echo -e "  ${BOLD}Threshold:${NC} ${threshold} day(s) since last backup"
                    echo -e "  ${BOLD}Target:${NC}    ${mon_target:-(services only)}"
                    echo -e "  ${BOLD}Excludes:${NC}  ${excludes:-(none)}" ;;
        backup-ok)  echo -e "  ${BOLD}Trigger:${NC}   each backup that finishes without errors" ;;
        backup-failed) echo -e "  ${BOLD}Trigger:${NC}   each backup that fails or reports an error" ;;
        health)     echo -e "  ${BOLD}Trigger:${NC}   failing health checks / not running (2 consecutive checks)" ;;
        drive)      echo -e "  ${BOLD}Threshold:${NC} ${threshold}% wear ${DIM}(critical warnings, spare, media errors always alert)${NC}" ;;
    esac
    echo -e "  ${BOLD}Schedule:${NC}  ${CRON_SCHEDULE}"
    [[ -n "$notify_cmd" ]] && echo -e "  ${BOLD}Shell:${NC}     ${notify_cmd}"
    [[ "$notify_sos" == "1" ]] && echo -e "  ${BOLD}StartOS:${NC}   ${notify_lvl} notification"
    echo ""
    if [[ "$type" == "backup-ok" || "$type" == "backup-failed" ]]; then
        echo -e "  ${DIM}One notification per backup run. A server restart within 30 minutes of a${NC}"
        echo -e "  ${DIM}backup finishing can repeat its notification once.${NC}"
    else
        echo -e "  ${DIM}Re-alert policy: first detection, when the offender list changes, and at${NC}"
        echo -e "  ${DIM}most one reminder per 24h while the condition persists. No recovery message.${NC}"
    fi
    echo -e "  ${DIM}If the check itself fails 3 times in a row, you are told once.${NC}"
    echo ""

    if ! confirm "Install this alert?"; then
        [[ $_BACK -eq 1 ]] && return 1
        print_info "Cancelled."
        pause; return
    fi

    install_monitor "$type" "$threshold" "$excludes" "$notify_cmd" "$notify_sos" "$notify_lvl" "$CRON_SCHEDULE" "$mon_target" "$name" "$legacy" || return 1
}

# Show installed monitor instances with their config.
_monitor_list_display() {
    local lines
    lines=$(_monitor_installed)
    if [[ -z "$lines" ]]; then
        print_info "No alerts installed."
        return 1
    fi
    local type name script
    while IFS=$'\t' read -r type name script; do
        local suffix="${script##"${_MONITOR_BIN_PREFIX}"}"
        local thr="" cmd="" sos="" lvl="" exc="" sched="" tgt=""
        _monitor_read_config "$script" thr cmd sos lvl exc tgt
        sched=$(_monitor_read_schedule "$suffix")
        local state_file="${_MONITOR_DATA_PREFIX}${suffix}.state"
        local state_val="(no active alert)"
        [[ -f "$state_file" ]] && state_val="ALERTING since $(date -d "@$(sed -n '2p' "$state_file" 2>/dev/null)" '+%Y.%m.%d %H:%M' 2>/dev/null || echo '?')"
        echo -e "  ${CYAN}${BOLD}$(_monitor_display "$type" "$name")${NC}"
        case "$type" in
            disk)       echo -e "     ${DIM}Threshold:${NC} ${thr}%" ;;
            backup-age) echo -e "     ${DIM}Threshold:${NC} ${thr} day(s)   ${DIM}Target:${NC} ${tgt:-(services only)}   ${DIM}Excludes:${NC} ${exc:-(none)}" ;;
            backup-ok)  echo -e "     ${DIM}Trigger:${NC}   each backup that finishes without errors" ;;
            backup-failed) echo -e "     ${DIM}Trigger:${NC}   each backup that fails or reports an error" ;;
            health)     echo -e "     ${DIM}Trigger:${NC}   unhealthy across 2 consecutive checks" ;;
            drive)      echo -e "     ${DIM}Threshold:${NC} ${thr}% wear   ${DIM}(critical warnings, spare, media errors always alert)${NC}" ;;
        esac
        echo -e "     ${DIM}Schedule:${NC}  ${sched:-(not found in crontab)}"
        echo -e "     ${DIM}Notify:${NC}    ${cmd:+shell}${cmd:+${sos:+ + }}$([[ "$sos" == "1" ]] && echo "StartOS ${lvl}")"
        echo -e "     ${DIM}State:${NC}     ${state_val}"
        local fails_n
        fails_n=$(sed -n '1p' "${state_file}.fails" 2>/dev/null) || fails_n=""
        [[ "$fails_n" =~ ^[0-9]+$ ]] && \
            echo -e "     ${DIM}Check:${NC}     ${RED}failing (${fails_n} run(s) in a row) — see the log${NC}"
        if [[ " $(_monitor_outdated | cut -f3 | tr '\n' ' ') " == *" ${script} "* ]]; then
            echo -e "     ${YELLOW}Built by an older startos-admin — restart startos-admin to rebuild it.${NC}"
        fi
        echo -e "     ${DIM}Id:${NC}        ${suffix}  ${DIM}(startos-admin alerts log ${suffix})${NC}"
        echo -e "     ${DIM}Log:${NC}       ${_MONITOR_DATA_PREFIX}${suffix}.log"
        echo ""
    done <<< "$lines"
    return 0
}

# Add flow: pick a type, run the wizard (which asks for the name last).
_monitor_add_flow() {
    print_header
    print_section "Add an Alert"
    echo ""
    _nav_tip
    echo -e "  ${BOLD}Alert type:${NC}"
    echo -e "    ${BOLD}1)${NC} Disk usage alert"
    echo -e "    ${BOLD}2)${NC} Backup staleness alert"
    echo -e "    ${BOLD}3)${NC} Service health watchdog"
    echo -e "    ${BOLD}4)${NC} Drive health alert ${DIM}(NVMe SMART)${NC}"
    echo -e "    ${BOLD}5)${NC} Backup succeeded alert ${DIM}(StartOS 0.4.3+)${NC}"
    echo -e "    ${BOLD}6)${NC} Backup failed alert ${DIM}(StartOS 0.4.3+)${NC}"
    echo ""
    local t_choice type
    while true; do
        _read t_choice "  Choice [1-6]: " || return 1
        case "$t_choice" in
            1) type="disk";       break ;;
            2) type="backup-age"; break ;;
            3) type="health";     break ;;
            4) type="drive";      break ;;
            5) type="backup-ok";  break ;;
            6) type="backup-failed"; break ;;
            *) print_warn "Enter 1-6." ;;
        esac
    done
    # The name is asked last, in _monitor_install_flow, once the settings it
    # can describe are known.
    _monitor_install_flow "$type" "" 0 || return 1
}

# Edit flow: pick an installed instance; legacy unnamed instances get a name
# (migration) as part of the update.
_monitor_edit_flow() {
    print_header
    print_section "Edit an Alert"
    echo ""

    local lines
    lines=$(_monitor_installed)
    if [[ -z "$lines" ]]; then
        print_info "No alerts installed."
        pause; return
    fi

    local -a e_types=() e_names=()
    local t n p i=1
    while IFS=$'\t' read -r t n p; do
        e_types+=("$t"); e_names+=("$n")
        echo -e "    ${BOLD}${i})${NC} $(_monitor_display "$t" "$n")"
        (( i++ ))
    done <<< "$lines"
    echo ""

    echo -e "    ${DIM}0) Back${NC}"
    echo ""
    local choice
    while true; do
        _read choice "  Choice [1-$((i-1)), or 0 to go back]: " || return 1
        [[ "$choice" == "0" ]] && return 0
        [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )) && break
        print_warn "Enter a number between 1 and $((i-1)), or 0 to go back."
    done
    local type="${e_types[$((choice-1))]}"
    local name="${e_names[$((choice-1))]}"
    local legacy=0

    if [[ -z "$name" ]]; then
        legacy=1
        echo ""
        print_info "This alert predates named alerts — it gets a name as part of this update."
        while true; do
            _read name "  Alert name [default]: " || return 1
            [[ -z "$name" ]] && name="default"
            if [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
                break
            fi
            print_warn "Use only letters, numbers, and hyphens."
        done
    fi

    _monitor_install_flow "$type" "$name" "$legacy" || return 1
}

_monitor_remove_flow() {
    print_header
    print_section "Remove Alert(s)"
    echo ""

    local lines
    lines=$(_monitor_installed)
    if [[ -z "$lines" ]]; then
        print_info "No alerts installed."
        pause; return
    fi

    local -a r_types=() r_names=() r_suffixes=()
    local t n p i=1
    while IFS=$'\t' read -r t n p; do
        r_types+=("$t"); r_names+=("$n"); r_suffixes+=("${p##"${_MONITOR_BIN_PREFIX}"}")
        echo -e "    ${BOLD}${i})${NC} $(_monitor_display "$t" "$n")"
        (( i++ ))
    done <<< "$lines"
    echo ""
    echo -e "    ${DIM}0) Back${NC}"
    echo ""

    local -a rm_idx=()
    local rchoice
    while true; do
        _read rchoice "  Choice(s) [1-$((i-1)), comma-separated, 'all', or 0 to go back]: " || return 1
        if [[ "$rchoice" == "0" ]]; then return; fi
        if [[ "$rchoice" == "all" ]]; then
            local j
            for (( j=0; j<${#r_suffixes[@]}; j++ )); do rm_idx+=("$j"); done
            break
        fi
        local valid=true sel=()
        IFS=',' read -ra parts <<< "$rchoice"
        local part
        for part in "${parts[@]}"; do
            part="${part// /}"
            if [[ "$part" =~ ^[0-9]+$ ]] && (( part >= 1 && part < i )); then
                sel+=("$((part-1))")
            else
                valid=false; break
            fi
        done
        if $valid && [[ ${#sel[@]} -gt 0 ]]; then
            rm_idx=("${sel[@]}")
            break
        fi
        print_warn "Enter valid number(s) between 1 and $((i-1)), comma-separated, or 'all'."
    done

    echo ""
    local names_display="" idx
    for idx in "${rm_idx[@]}"; do
        names_display+="${names_display:+, }$(_monitor_display "${r_types[$idx]}" "${r_names[$idx]}")"
    done
    if ! confirm "Remove: ${names_display}?"; then
        [[ $_BACK -eq 1 ]] && return 1
        print_info "Cancelled."
        pause; return
    fi

    # State/log files are volatile runtime files — remove now (harmless when
    # staging). The trailing space in the cron grep keeps a bare type from
    # matching named instances.
    local cmds="" suffix
    for idx in "${rm_idx[@]}"; do
        suffix="${r_suffixes[$idx]}"
        # .state plus its derivatives (.state.lastbad, .state.media-*); the
        # glob must expand as root, hence sh -c.
        sudo sh -c "rm -f '${_MONITOR_DATA_PREFIX}${suffix}.state' '${_MONITOR_DATA_PREFIX}${suffix}.state.'*"
        cmds+="crontab -l 2>/dev/null | grep -v 'startos-monitor-${suffix} ' | grep -Fv '| Monitor: ${suffix} |' | crontab -
rm -f ${_MONITOR_BIN_PREFIX}${suffix}
"
    done

    _apply_or_stage "Remove alert(s): ${names_display}" "$cmds" || return 1
}

_monitor_view_log() {
    print_header
    print_section "View Alert Log"
    echo ""

    local lines
    lines=$(_monitor_installed)
    if [[ -z "$lines" ]]; then
        print_info "No alerts installed."
        pause; return
    fi

    local -a l_types=() l_names=() l_suffixes=()
    local t n p i=1
    while IFS=$'\t' read -r t n p; do
        l_types+=("$t"); l_names+=("$n"); l_suffixes+=("${p##"${_MONITOR_BIN_PREFIX}"}")
        echo -e "    ${BOLD}${i})${NC} $(_monitor_display "$t" "$n")"
        (( i++ ))
    done <<< "$lines"
    echo ""
    echo -e "    ${DIM}0) Back${NC}"
    echo ""
    local log_choice
    while true; do
        _read log_choice "  Choice [1-$((i-1)), or 0 to go back]: " || return 1
        [[ "$log_choice" == "0" ]] && return 0
        [[ "$log_choice" =~ ^[0-9]+$ ]] && (( log_choice >= 1 && log_choice < i )) && break
        print_warn "Enter a number between 1 and $((i-1)), or 0 to go back."
    done
    local log_idx=$((log_choice-1))
    local log_file="${_MONITOR_DATA_PREFIX}${l_suffixes[$log_idx]}.log"

    print_header
    print_section "Alert Log: $(_monitor_display "${l_types[$log_idx]}" "${l_names[$log_idx]}")"
    echo ""
    if [[ ! -f "$log_file" ]]; then
        print_info "Log file not found: $log_file"
        print_info "The monitor may not have run yet (or the server rebooted — logs are volatile)."
    else
        echo -e "  ${DIM}(last 50 lines of $log_file)${NC}"
        echo ""
        tail -50 "$log_file"
    fi
    echo ""
    pause
}

# Alerts manager submenu (instances, like the forwarder manager).
menu_alerts() {
    while true; do
        print_header
        print_section "Alerts"
        echo ""
        local inst_lines
        inst_lines=$(_monitor_installed)
        echo -e "  ${BOLD}Installed on this server now:${NC}"
        if [[ -n "$inst_lines" ]]; then
            local t n p
            while IFS=$'\t' read -r t n p; do
                local thr="" cmd="" sos="" lvl="" exc="" tgt="" desc=""
                _monitor_read_config "$p" thr cmd sos lvl exc tgt
                case "$t" in
                    disk)       desc="${thr}%" ;;
                    backup-age) desc="${thr}d, ${tgt:-?}" ;;
                    backup-ok|backup-failed) desc="each backup run" ;;
                    health)     desc="2-check debounce" ;;
                    drive)      desc="${thr}% wear" ;;
                esac
                echo -e "    ${CYAN}•${NC} $(_monitor_display "$t" "$n")  ${DIM}(${desc})${NC}"
            done <<< "$inst_lines"
        else
            echo -e "    ${DIM}(none)${NC}"
        fi
        echo ""
        echo -e "  ${BOLD}What would you like to do?${NC}"
        echo -e "    ${CYAN}${BOLD}1)${NC} Add an alert"
        echo -e "    ${CYAN}${BOLD}2)${NC} Edit an alert"
        echo -e "    ${CYAN}${BOLD}3)${NC} List installed alerts ${DIM}(details)${NC}"
        echo -e "    ${CYAN}${BOLD}4)${NC} Remove alert(s)"
        echo -e "    ${CYAN}${BOLD}5)${NC} View alert log"
        echo ""
        echo -e "    ${DIM}0) Back${NC}"
        echo ""
        local al_choice
        _read al_choice "  $(echo -e "${BOLD}Choice:${NC} ")" || return 1
        case "$al_choice" in
            1) _monitor_add_flow    || return 1 ;;
            2) _monitor_edit_flow   || return 1 ;;
            3)
                print_header
                print_section "Installed Alerts"
                echo ""
                _monitor_list_display || true
                pause
                ;;
            4) _monitor_remove_flow || return 1 ;;
            5) _monitor_view_log    || return 1 ;;
            0) return ;;
            *) print_warn "Enter 0-5." ; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────────
# System Database Viewer
# ─────────────────────────────────────────────

# Display hostname, OS version, architecture, and last backup timestamp from DB.
_db_server_info() {
    print_header
    _show_server_info "$1"
    pause
}

# Body of Server Info, shared by the menu and `startos-admin server-info`.
_show_server_info() {
    local db="$1"
    print_section "Server Info"
    echo ""

    local hostname version arch platform last_backup dev_info
    hostname=$(echo "$db"    | jq -r '.value.serverInfo.hostname    // "unknown"')
    version=$(echo "$db"     | jq -r '.value.serverInfo.version     // "unknown"')
    last_backup=$(echo "$db" | jq -r '.value.serverInfo.lastBackup  // "never"')

    # StartOS 0.4.0.1 dropped arch/platform from serverInfo; they now come from
    # 'server device-info' (.hardware.arch / .os.platform).
    dev_info=$(start-cli server device-info --format json 2>/dev/null) || dev_info=""
    arch=$(echo "$dev_info"     | jq -r '.hardware.arch // "unknown"' 2>/dev/null || echo "unknown")
    platform=$(echo "$dev_info" | jq -r '.os.platform  // "unknown"' 2>/dev/null || echo "unknown")
    [[ -z "$arch"     ]] && arch="unknown"
    [[ -z "$platform" ]] && platform="unknown"

    if [[ "$last_backup" != "never" ]]; then
        last_backup=$(date -d "$last_backup" '+%Y.%m.%d %H:%M:%S %Z' 2>/dev/null || echo "$last_backup")
    fi

    echo -e "  ${BOLD}Hostname:${NC}      $hostname"
    echo -e "  ${BOLD}StartOS:${NC}       $version"
    echo -e "  ${BOLD}Architecture:${NC}  $arch"
    echo -e "  ${BOLD}Platform:${NC}      $platform"
    echo -e "  ${BOLD}Last Backup:${NC}   $last_backup"
    echo ""
}

# Display server addresses, WiFi, gateways and DNS servers from DB.
_db_network() {
    print_header
    _show_network "$1"
    pause
}

# Body of Network, shared by the menu and `startos-admin network`.
_show_network() {
    local db="$1"
    print_section "Network"
    echo ""

    # ── Addresses (mirrors the GUI Addresses table) ──────────────────────────
    print_section "Addresses"
    echo ""
    # 0.4.0.1 replaced serverInfo.network.hostnameInfo with a per-binding address
    # list under network.host.bindings[<internal port>].addresses.available[].
    # IP entries carry metadata.gateway (string), mDNS entries metadata.gateways
    # (array). The default port for the scheme is left off the URL.
    echo "$db" | jq -r '
        [.value.serverInfo.network.host.bindings // {} | to_entries[] |
            .value.addresses.available[]? |
            (if .ssl then "https" else "http" end) as $scheme |
            (.metadata.kind // "unknown") as $kind |
            (if $kind == "ipv6"
                then "[" + .hostname +
                     (if (.metadata.scopeId and (.hostname | startswith("fe80")))
                        then "%" + (.metadata.scopeId|tostring) else "" end) + "]"
                else .hostname end) as $host |
            (if (.ssl and .port == 443) or ((.ssl|not) and .port == 80)
                then "" else ":" + (.port|tostring) end) as $portsuffix |
            {
                type:    $kind,
                access:  (if .public then "public" else "private" end),
                gateway: (.metadata.gateway // ((.metadata.gateways // []) | join(",")) | if . == "" then "unknown" else . end),
                url:     ($scheme + "://" + $host + $portsuffix)
            }
        ] | unique_by(.url) | .[] |
        "\(.type)\t\(.access)\t\(.gateway)\t\(.url)"
    ' 2>/dev/null | while IFS=$'\t' read -r type access gateway url; do
        printf "  %-10s  %-8s  %-24s  %s\n" "$type" "$access" "$gateway" "$url"
    done
    echo ""

    # Tor addresses are no longer reported here: as of 0.4.0 Tor is a service the
    # user installs and enables per interface, so serverInfo.network.onions is
    # gone and there is no server-wide onion list to show.

    # ── WiFi ─────────────────────────────────────────────────────────────────
    print_section "WiFi"
    echo ""
    local wifi_enabled wifi_ssid
    # `// "unknown"` would swallow a legitimate `false` here, since jq's
    # alternative operator treats false as empty — test for null explicitly.
    wifi_enabled=$(echo "$db" | jq -r '.value.serverInfo.network.wifi.enabled | if . == null then "unknown" else tostring end')
    wifi_ssid=$(echo "$db"    | jq -r '.value.serverInfo.network.wifi.selected // "none"')
    echo -e "  ${BOLD}Enabled:${NC}  $wifi_enabled"
    echo -e "  ${BOLD}Network:${NC}  $wifi_ssid"
    echo ""

    # ── Gateways ─────────────────────────────────────────────────────────────
    print_section "Gateways"
    echo ""
    printf "  %-26s  %-22s  %-18s  %s\n" "Name" "Type" "LAN IP" "WAN IP"
    printf "  %-26s  %-22s  %-18s  %s\n" "──────────────────────────" "──────────────────────" "──────────────────" "───────────────"
    echo "$db" | jq -r '
        .value.serverInfo.network.gateways // {} | to_entries[] |
        select(.value.ipInfo.deviceType != "loopback") |
        (.value.ipInfo.subnets // [] | map(select(test("^[0-9]"))) | first // "?" | split("/")[0]) as $lanip |
        (if ($lanip | test("^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)")) then "private" else "public" end) as $access |
        "\(.value.ipInfo.name // .key)\t\(.value.ipInfo.deviceType // "unknown") (\($access))\t\($lanip)\t\(.value.ipInfo.wanIp // "n/a")"
    ' 2>/dev/null | while IFS=$'\t' read -r name dtype lanip wan; do
        printf "  %-26s  %-22s  %-18s  %s\n" "$name" "$dtype" "$lanip" "$wan"
    done
    echo ""

    # ── DNS ──────────────────────────────────────────────────────────────────
    print_section "DNS Servers"
    echo ""
    local dns_strategy
    # 0.4.0.1 moved dns under serverInfo.network.
    dns_strategy=$(echo "$db" | jq -r '
        if (.value.serverInfo.network.dns.staticServers | (. != null and length > 0)) then "Static"
        else "DHCP" end
    ' 2>/dev/null)
    echo -e "  ${BOLD}Strategy:${NC}  $dns_strategy"
    echo ""
    echo "$db" | jq -r '
        [(.value.serverInfo.network.dns.staticServers // [])[], (.value.serverInfo.network.dns.dhcpServers // [])[]] |
        unique[]
    ' 2>/dev/null | while read -r dns; do
        echo -e "  ${CYAN}•${NC} $dns"
    done
    echo ""
}

# List all installed services with running state and health-check status from DB.
_db_svc_status() {
    print_header
    _show_svc_status "$1"
    pause
}

# Body of Service Status, shared by the menu and `startos-admin services`.
_show_svc_status() {
    local db="$1"
    print_section "Service Status"
    echo ""

    local svc_list
    svc_list=$(echo "$db" | jq -r '.value.packageData | keys[]')

    while IFS= read -r svc; do
        local desired
        desired=$(echo "$db" | jq -r \
            ".value.packageData[\"$svc\"].statusInfo.desired | to_entries[0].value // \"unknown\"")

        local state_color="$RED"
        [[ "$desired" == "running" ]] && state_color="$GREEN"

        echo -e "  ${BOLD}${svc}${NC}  ${state_color}${desired}${NC}"

        echo "$db" | jq -r ".value.packageData[\"$svc\"].statusInfo.health // {} | to_entries[] |
            \"\(.value.name): \(.value.result) — \(.value.message // \"\")\"" 2>/dev/null \
        | while IFS= read -r hline; do
            local hcolor="$DIM"
            echo "$hline" | grep -q ": success" && hcolor="$GREEN"
            echo "$hline" | grep -q ": loading" && hcolor="$YELLOW"
            echo "$hline" | grep -qE ": failure|: error" && hcolor="$RED"
            echo -e "    ${hcolor}${hline}${NC}"
        done

        echo ""
    done <<< "$svc_list"
}

# Display full DB record for a single service selected by the user.
_db_svc_detail() {
    local db="$1"
    print_header
    print_section "Service Detail"
    echo ""
    _nav_tip

    local svc_list
    mapfile -t svc_list < <(echo "$db" | jq -r '.value.packageData | keys[]')

    local i=1
    for svc in "${svc_list[@]}"; do
        echo -e "    ${CYAN}${BOLD}${i})${NC} ${svc}"
        (( i++ )) || true
    done
    echo ""

    local svc_choice
    _read svc_choice "  $(echo -e "${BOLD}Choice:${NC} ")" || return 1

    if ! [[ "$svc_choice" =~ ^[0-9]+$ ]] || \
       [[ "$svc_choice" -lt 1 ]] || [[ "$svc_choice" -gt "${#svc_list[@]}" ]]; then
        print_warn "Invalid choice."; sleep 1; return 0
    fi

    print_header
    _show_svc_detail "$db" "${svc_list[$((svc_choice - 1))]}"
    pause
}

# Body of Service Detail for one service, shared by the menu and
# `startos-admin service <id>`.
_show_svc_detail() {
    local db="$1" pkg="$2"
    print_section "Service: $pkg"
    echo ""

    local desired started last_bk registry
    desired=$(echo "$db"  | jq -r ".value.packageData[\"$pkg\"].statusInfo.desired | to_entries[0].value // \"unknown\"")
    started=$(echo "$db"  | jq -r ".value.packageData[\"$pkg\"].statusInfo.started // \"unknown\"")
    # Last successful backup of this service, to any target. Written by
    # StartOS 0.4.0.3 and newer; earlier versions leave it empty.
    last_bk=$(echo "$db"  | jq -r ".value.packageData[\"$pkg\"].lastBackup          // \"never\"")
    registry=$(echo "$db" | jq -r ".value.packageData[\"$pkg\"].registry             // \"unknown\"")

    [[ "$started" != "unknown" ]] && started=$(date -d "$started" '+%Y.%m.%d %H:%M:%S %Z' 2>/dev/null || echo "$started")
    [[ "$last_bk" != "never"   ]] && last_bk=$(date -d "$last_bk" '+%Y.%m.%d %H:%M:%S %Z' 2>/dev/null || echo "$last_bk")

    local state_color="$RED"
    [[ "$desired" == "running" ]] && state_color="$GREEN"

    echo -e "  ${BOLD}Status:${NC}       ${state_color}${desired}${NC}"
    echo -e "  ${BOLD}Started:${NC}      $started"
    echo -e "  ${BOLD}Last Backup:${NC}  $last_bk"
    echo -e "  ${BOLD}Registry:${NC}     $registry"
    echo ""

    print_section "Health Checks"
    echo ""
    echo "$db" | jq -r ".value.packageData[\"$pkg\"].statusInfo.health // {} | to_entries[] |
        \"\(.value.name)\n  result:  \(.value.result)\n  detail:  \(.value.message // \"\")\"" 2>/dev/null \
    | while IFS= read -r line; do
        echo -e "  $line"
    done
    echo ""

    print_section "Dependencies"
    echo ""
    local deps
    deps=$(echo "$db" | jq -r ".value.packageData[\"$pkg\"].currentDependencies | keys[]?" 2>/dev/null)
    if [[ -z "$deps" ]]; then
        echo -e "  ${DIM}None${NC}"
    else
        while IFS= read -r dep; do
            echo -e "  ${CYAN}•${NC} $dep"
        done <<< "$deps"
    fi
    echo ""
}

# jq helpers shared by _interfaces_tsv and _domains_tsv, prepended to their
# programs. $a = one entry of a binding's addresses.available, $iface = one of
# the binding's interfaces, $addrs = the binding's addresses object,
# $gws = serverInfo.network.gateways.
_JQ_ADDR_DEFS='
  # mdns / private-domain carry metadata.gateways[], everything else gateway
  def sa_gw($a): ($a.metadata.gateway // ($a.metadata.gateways // [])[0]);
  # IPv6 in brackets
  def sa_host($a): if $a.metadata.kind == "ipv6" then "[" + $a.hostname + "]" else $a.hostname end;
  # URL from the ssl flag and the interface scheme; the scheme default port is
  # left off, and query parameters (embedded certs/macaroons) are stripped.
  def sa_url($a; $iface):
    (if ($a.ssl and $iface.addressInfo.sslScheme != null) then $iface.addressInfo.sslScheme
     elif ($a.ssl | not) and ($iface.addressInfo.scheme != null) then $iface.addressInfo.scheme
     elif $a.ssl then "ssl"
     else "tcp" end) as $proto |
    (if ($proto == "https" and $a.port == 443) or ($proto == "http" and $a.port == 80)
     then "" else ":" + ($a.port|tostring) end) as $portPart |
    $proto + "://" + sa_host($a) + $portPart + (($iface.addressInfo.suffix // "") | split("?")[0]);
  # Active = what the UI shows as switched on. A public IP:port is off unless
  # listed in addresses.enabled; everything else (private IPs and domains) is
  # on unless listed in addresses.disabled.
  def sa_active($a; $addrs):
    if ($a.public == true) and ($a.metadata.kind == "ipv4" or $a.metadata.kind == "ipv6") then
      ($a.port == null) or
      ((($addrs.enabled // []) | index(sa_host($a) + ":" + ($a.port|tostring))) != null)
    else
      (($addrs.disabled // []) | any(.[0] == $a.hostname and .[1] == ($a.port // 0))) | not
    end;
  # Gateway display name ("Wired connection 1", "StartTunnel", …), trimmed.
  def sa_gwname($gws; $id):
    if $id == null then "local"
    else (($gws[$id].name // $gws[$id].ipInfo.name // $id) | gsub("^\\s+|\\s+$"; "")) end;
'

# Extract service interface URLs from a DB dump as TSV:
# service<TAB>iface-name<TAB>type<TAB>network<TAB>url<TAB>active|inactive<TAB>kind
# kind is the address kind: ipv4, ipv6, mdns, public-domain or private-domain.
# $1 = db dump JSON, $2 = JSON array of service ids to include.
#
# As of StartOS 0.4.0 there is no packageData.<pkg>.serviceInterfaces map;
# interfaces live inside the binding they belong to, at
#   packageData.<pkg>.hosts.<hostId>.bindings.<internalPort>.interfaces.<ifaceId>
# so the addresses for an interface are the enclosing binding's
# addresses.available — no hostId lookup needed.
_interfaces_tsv() {
    echo "$1" | jq -r --argjson svcs "$2" "${_JQ_ADDR_DEFS}"'
      (.value.serverInfo.network.gateways // {}) as $gws |
      .value.packageData | to_entries[] |
      select(.key as $k | $svcs | index($k)) |
      .key as $svc |
      (.value.hosts // {}) | to_entries[] |
      (.value.bindings // {}) | to_entries[] |
      .value as $binding |
      select($binding.enabled != false) |
      ($binding.addresses // {}) as $addrs |
      ($binding.interfaces // {}) | to_entries[] |
      .value as $iface |
      ($addrs.available // [])[] as $a |
      sa_gw($a) as $gwId |
      # Skip loopback, the internal bridge and link-local IPv6
      select($gwId | . != "lo" and . != "lxcbr0") |
      select(($a.metadata.kind == "ipv6" and ($a.hostname | startswith("fe80::"))) | not) |
      "\($svc)\t\($iface.name)\t\($iface.type)\t\(sa_gwname($gws; $gwId))\t\(sa_url($a; $iface))\t\(if sa_active($a; $addrs) then "active" else "inactive" end)\t\($a.metadata.kind // "unknown")"
    ' 2>/dev/null
}

# Every domain on the server — public and private, the StartOS web interface's
# own included — as TSV, one row per domain and interface URL, sorted by domain:
#   domain service interface url access gateway cert state resolver expected
# access = public|private; cert = the certificate as the web UI names it
# (Let's Encrypt, Root CA, Self signed, -); state = active|inactive (an address
# switched off in the UI, or a domain whose bindings have no interface);
# resolver = "public" (ask public DNS) or the gateway IPv4 the server's own DNS
# answers on (private domains); expected = the IP(s) the name should resolve to.
# The service column says "startos" for the web interface's domains.
# $1 = db dump JSON, $2 = JSON array of service ids to include, $3 = 1 to
# include the StartOS web interface.
_domains_tsv() {
    echo "$1" | jq -r --argjson svcs "$2" --argjson withos "${3:-1}" "${_JQ_ADDR_DEFS}"'
      def ipv4s($gw): [($gw.ipInfo.subnets // [])[] | select(test("^[0-9]+\\.")) | split("/")[0]];
      def certname($a; $b; $host):
        if ($a.ssl | not) then "-"
        elif ($b.options.addSsl == null) then (if $b.options.secure.ssl == true then "Self signed" else "-" end)
        elif $a.metadata.kind != "public-domain" then "Root CA"
        else ($host.publicDomains[$a.hostname].acme // null) as $u |
          if $u == null then "Root CA"
          elif $u == "https://acme-v02.api.letsencrypt.org/directory" then "Let'"'"'s Encrypt"
          elif $u == "https://acme-staging-v02.api.letsencrypt.org/directory" then "Let'"'"'s Encrypt (Staging)"
          else $u end
        end;
      (.value.serverInfo.network.gateways // {}) as $gws |
      ( (if $withos == 1 then [{svc: "startos", host: (.value.serverInfo.network.host // {})}] else [] end)
        + [ .value.packageData | to_entries[] | select(.key as $k | $svcs | index($k)) |
            .key as $s | (.value.hosts // {}) | to_entries[] | {svc: $s, host: .value} ] )
      | [ .[] | .svc as $svc | .host as $host |
          ( [ ($host.publicDomains // {}) | to_entries[] |
                {d: .key, access: "public", gws: [.value.gateway]} ]
            + [ ($host.privateDomains // {}) | to_entries[] | select(.key | endswith(".local") | not) |
                {d: .key, access: "private", gws: (.value | if type == "array" then . else [] end)} ] )[] as $dom |
          ($dom.gws | map(sa_gwname($gws; .)) | join(",")) as $gwnames |
          (if $dom.access == "public"
             then {resolver: "public", expected: ([$dom.gws[] | $gws[.].ipInfo.wanIp // empty] | unique | join(","))}
             else (ipv4s($gws[$dom.gws[0] // ""] // {})) as $ips |
                  {resolver: ($ips[0] // "-"), expected: ($ips | join(","))}
           end) as $dns |
          [ ($host.bindings // {}) | to_entries[] | .value as $b |
            select($b.enabled != false) |
            ($b.addresses // {}) as $addrs |
            ($addrs.available // [])[] as $a |
            select($a.hostname == $dom.d and ($a.metadata.kind == "public-domain" or $a.metadata.kind == "private-domain")) |
            ($b.interfaces // {}) | to_entries[] | .value as $iface |
            {iface: $iface.name, url: sa_url($a; $iface), cert: certname($a; $b; $host),
             state: (if sa_active($a; $addrs) then "active" else "inactive" end)} ] as $rows |
          (if ($rows | length) == 0 then [{iface: "-", url: "-", cert: "-", state: "inactive"}] else $rows end)[] |
          [$dom.d, $svc, .iface, .url, $dom.access, (if $gwnames == "" then "-" else $gwnames end),
           .cert, .state, $dns.resolver, (if $dns.expected == "" then "-" else $dns.expected end)] ]
      | unique | sort_by(.[0], .[1], .[2], .[3]) | .[] | @tsv
    ' 2>/dev/null
}

# A records for $1, comma-separated (empty if none), then a tab and the
# resolver that answered. $2 = "public" to ask public DNS (1.1.1.1, then
# 9.9.9.9, then this server's own resolver), or an IP to ask that server.
# Returns 1 if no resolver answered or dig is missing.
_dns_lookup_a() {
    local name="$1" via="$2" out="" srv
    command -v dig >/dev/null 2>&1 || return 1
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    local -a servers=()
    if [[ "$via" == "public" ]]; then servers=(1.1.1.1 9.9.9.9 system)
    else servers=("$via"); fi
    for srv in "${servers[@]}"; do
        if [[ "$srv" == "system" ]]; then
            out=$(dig +short +time=3 +tries=1 A "$name" 2>/dev/null) || continue
        else
            out=$(dig +short +time=3 +tries=1 A "$name" "@${srv}" 2>/dev/null) || continue
        fi
        printf '%s\t%s\n' "$(grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' <<< "$out" | sort -u | paste -sd, -)" "$srv"
        return 0
    done
    return 1
}

# _domains_tsv plus a DNS check of every domain, as TSV:
#   domain service interface url access gateway cert state dns resolved expected resolver
# dns = ok (resolves to an expected IP) | elsewhere (resolves, but not to one)
#     | missing (no A record) | unchecked (no expected IP known, or no
#     resolver answered); resolved = the A records found ("-" if none);
# resolver = who answered (1.1.1.1, 9.9.9.9, system, or the gateway IP).
# Lookups run in parallel, one per distinct domain and resolver.
_domains_report() {
    local rows
    rows=$(_domains_tsv "$@") || rows=""
    [[ -n "$rows" ]] || return 0
    local tmp
    tmp=$(mktemp -d) || return 1
    local -A job=()
    local d svc ifc url acc gw cert st via exp key n=0
    while IFS=$'\t' read -r d svc ifc url acc gw cert st via exp; do
        key="${d}|${via}"
        [[ -n "${job[$key]:-}" ]] && continue
        n=$(( n + 1 )); job[$key]=$n
        [[ "$via" == "-" ]] && continue
        ( _dns_lookup_a "$d" "$via" > "${tmp}/${n}" 2>/dev/null || true ) &
    done <<< "$rows"
    wait
    while IFS=$'\t' read -r d svc ifc url acc gw cert st via exp; do
        local res="" ans="" by="-" dns="unchecked"
        res=$(cat "${tmp}/${job[${d}|${via}]}" 2>/dev/null) || res=""
        if [[ -n "$res" ]]; then
            ans="${res%%$'\t'*}"; by="${res#*$'\t'}"
            if [[ -z "$ans" ]]; then
                dns="missing"
            elif [[ "$exp" != "-" ]]; then
                dns="elsewhere"
                local ip
                for ip in ${ans//,/ }; do
                    [[ ",${exp}," == *",${ip},"* ]] && { dns="ok"; break; }
                done
            fi
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$d" "$svc" "$ifc" "$url" "$acc" "$gw" "$cert" "$st" "$dns" "${ans:--}" "$exp" "$by"
    done <<< "$rows"
    rm -rf "$tmp"
}

# Print the domain report grouped by domain (menu and `startos-admin domains`
# on a terminal). $1 = output of _domains_report.
_show_domains() {
    local report="$1"
    print_section "Domains"
    echo ""
    if [[ -z "$report" ]]; then
        print_info "No domains are set up on this server."
        echo -e "  ${DIM}Domains are added to a service's interface in the StartOS web UI.${NC}"
        echo ""
        return 0
    fi
    echo -e "  ${DIM}Public domains are looked up in public DNS (1.1.1.1) and should point at their${NC}"
    echo -e "  ${DIM}gateway's public IP. Private domains are answered by this server's own DNS, for${NC}"
    echo -e "  ${DIM}devices that use this server as their DNS server.${NC}"
    echo ""
    local prev="" n_dom=0 n_ok=0 n_bad=0 n_unk=0
    local d svc ifc url acc gw cert st dns ans exp by
    while IFS=$'\t' read -r d svc ifc url acc gw cert st dns ans exp by; do
        if [[ "$d" != "$prev" ]]; then
            [[ -n "$prev" ]] && echo ""
            prev="$d"; n_dom=$(( n_dom + 1 ))
            echo -e "  ${BOLD}${d}${NC}  ${DIM}${acc} · ${gw}${NC}"
            local via_note=""
            [[ "$acc" == "public" && "$by" != "1.1.1.1" && "$by" != "-" ]] && via_note=" ${DIM}(answered by ${by})${NC}"
            case "$dns" in
                ok)
                    n_ok=$(( n_ok + 1 ))
                    if [[ "$acc" == "public" ]]; then
                        echo -e "    ${GREEN}DNS ✓${NC} points to ${ans}${via_note}"
                    else
                        echo -e "    ${GREEN}DNS ✓${NC} this server answers ${ans} on ${gw}"
                    fi ;;
                elsewhere)
                    n_bad=$(( n_bad + 1 ))
                    echo -e "    ${YELLOW}DNS ✗ points to ${ans}, not ${exp}${NC}${via_note}"
                    [[ "$acc" == "public" ]] && \
                        echo -e "      ${DIM}${exp} is the public IP of ${gw}. A proxy or CDN in front of the domain also shows here.${NC}" ;;
                missing)
                    n_bad=$(( n_bad + 1 ))
                    if [[ "$acc" == "public" && "$exp" == "-" ]]; then
                        echo -e "    ${RED}DNS ✗ no A record${NC}${via_note} ${DIM}— and StartOS doesn't know ${gw}'s public IP${NC}"
                    elif [[ "$acc" == "public" ]]; then
                        echo -e "    ${RED}DNS ✗ no A record${NC}${via_note} ${DIM}— add one pointing to ${exp}${NC}"
                    else
                        echo -e "    ${RED}DNS ✗ this server's DNS on ${gw} does not answer for it${NC}"
                    fi ;;
                *)
                    n_unk=$(( n_unk + 1 ))
                    if [[ "$exp" == "-" ]]; then
                        echo -e "    ${DIM}DNS not checked — StartOS doesn't know ${gw}'s public IP${NC}"
                    else
                        echo -e "    ${DIM}DNS not checked — no DNS server answered${NC}"
                    fi ;;
            esac
        fi
        if [[ "$url" == "-" ]]; then
            echo -e "    ${DIM}${svc}  (no interface uses this domain)${NC}"
        elif [[ "$st" == "active" ]]; then
            printf "    %-16s %-20s %-44s ${DIM}%s${NC}\n" "$svc" "$ifc" "$url" "$cert"
        else
            printf "    ${DIM}%-16s %-20s %-44s %s  (off)${NC}\n" "$svc" "$ifc" "$url" "$cert"
        fi
    done <<< "$report"
    echo ""
    local summary="${n_dom} domain(s) · ${GREEN}${n_ok} DNS ok${NC}"
    (( n_bad > 0 )) && summary+=" · ${YELLOW}${n_bad} need attention${NC}"
    (( n_unk > 0 )) && summary+=" · ${DIM}${n_unk} not checked${NC}"
    echo -e "  ${summary}"
    echo ""
}

# System Data → Domains: every domain on the server, with a DNS check.
_db_domains() {
    local db="$1"
    print_header
    print_info "Checking DNS for every domain..."
    local report
    report=$(_domains_report "$db" "$(echo "$db" | jq -c '.value.packageData | keys')" 1)
    print_header
    _show_domains "$report"
    pause
}

# Display service interfaces (URLs) extracted from DB for selected services.
_db_interfaces() {
    local db="$1"
    print_header
    print_section "Service Interfaces"
    echo ""
    _nav_tip

    # Build service list
    local svc_list
    mapfile -t svc_list < <(echo "$db" | jq -r '.value.packageData | keys[]')

    local i=1
    for svc in "${svc_list[@]}"; do
        echo -e "    ${CYAN}${BOLD}${i})${NC} ${svc}"
        (( i++ )) || true
    done
    echo ""
    echo -e "    ${CYAN}${BOLD}a)${NC} All services"
    echo ""

    local svc_input
    _read svc_input "  $(echo -e "${BOLD}Select services (comma-separated) or 'a' for all:${NC} ")" || return 1

    # Parse selection into a jq-friendly filter array
    local selected=()
    if [[ "${svc_input,,}" == "a" || "${svc_input,,}" == "all" ]]; then
        selected=("${svc_list[@]}")
    else
        IFS=',' read -ra picks <<< "$svc_input"
        for p in "${picks[@]}"; do
            p=$(echo "$p" | tr -d '[:space:]')
            if ! [[ "$p" =~ ^[0-9]+$ ]] || [[ "$p" -lt 1 ]] || [[ "$p" -gt "${#svc_list[@]}" ]]; then
                print_warn "Invalid selection: $p"; sleep 1; return 0
            fi
            selected+=("${svc_list[$((p - 1))]}")
        done
    fi
    [[ ${#selected[@]} -eq 0 ]] && { print_warn "No services selected."; sleep 1; return 0; }

    # Build jq filter string: ["svc1","svc2",...]
    local jq_filter
    jq_filter=$(printf '%s\n' "${selected[@]}" | jq -R . | jq -sc .)

    print_header
    print_section "Service Interfaces"
    echo ""

    # Extract and display interfaces
    local output
    output=$(_interfaces_tsv "$db" "$jq_filter")

    if [[ -z "$output" ]]; then
        print_info "No interfaces found for selected services."
    else
        local prev_svc=""
        while IFS=$'\t' read -r svc iname itype net url active _kind; do
            if [[ "$svc" != "$prev_svc" ]]; then
                [[ -n "$prev_svc" ]] && echo ""
                echo -e "  ${BOLD}${svc}${NC}"
                prev_svc="$svc"
            fi
            local type_color="$GREEN"
            [[ "$itype" == "api" ]] && type_color="$YELLOW"
            [[ "$itype" == "p2p" ]] && type_color="$BLUE"
            # Inactive addresses are switched off in the UI: shown, but dimmed.
            if [[ "$active" == "active" ]]; then
                printf "    ${type_color}%-4s${NC}  %-20s  %-20s  %s\n" "$itype" "$iname" "$net" "$url"
            else
                printf "    ${DIM}%-4s  %-20s  %-20s  %s  (off)${NC}\n" "$itype" "$iname" "$net" "$url"
            fi
        done <<< "$output"
    fi
    echo ""

    pause
}

menu_db_dump() {
    print_header
    print_section "System Data"
    echo ""
    _require_running || { pause; return; }

    print_info "Fetching database dump..."
    debug_log "Running: start-cli db dump"
    local db_json db_err
    db_json=$(start-cli db dump 2>/tmp/_sadmin_dberr) || {
        db_err=$(cat /tmp/_sadmin_dberr 2>/dev/null); rm -f /tmp/_sadmin_dberr
        print_error "Failed to run 'start-cli db dump'."
        [[ -n "$db_err" ]] && echo -e "${RED}${db_err}${NC}"
        pause; return
    }
    rm -f /tmp/_sadmin_dberr
    [[ -z "$db_json" ]] && { print_error "Empty response."; pause; return; }
    debug_log "DB dump: ${#db_json} bytes"

    while true; do
        print_header
        print_section "System Data"
        echo ""
        echo -e "    ${CYAN}${BOLD}1)${NC} Server Info"
        echo -e "    ${CYAN}${BOLD}2)${NC} Network"
        echo -e "    ${CYAN}${BOLD}3)${NC} Service Status"
        echo -e "    ${CYAN}${BOLD}4)${NC} Service Detail"
        echo -e "    ${CYAN}${BOLD}5)${NC} Service Interfaces"
        echo -e "    ${CYAN}${BOLD}6)${NC} Domains  ${DIM}(with a DNS check)${NC}"
        echo ""
        echo -e "    ${DIM}0) Back${NC}"
        echo ""
        _read db_choice "  $(echo -e "${BOLD}Choice:${NC} ")" || return 1
        case "$db_choice" in
            1) _db_server_info  "$db_json" ;;
            2) _db_network      "$db_json" ;;
            3) _db_svc_status   "$db_json" ;;
            4) _db_svc_detail   "$db_json" || return 1 ;;
            5) _db_interfaces   "$db_json" || return 1 ;;
            6) _db_domains      "$db_json" ;;
            0) return ;;
            *) print_warn "Enter 0-6." ; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Documentation
# ─────────────────────────────────────────────

menu_documentation() {
    while true; do
        print_header
        print_section "Documentation"
        echo ""
        echo -e "    ${CYAN}${BOLD}1)${NC} Disk used by services"
        echo -e "    ${CYAN}${BOLD}2)${NC} System data"
        echo -e "    ${CYAN}${BOLD}3)${NC} Memory used by services"
        echo -e "    ${CYAN}${BOLD}4)${NC} StartOS notification"
        echo -e "    ${CYAN}${BOLD}5)${NC} Backup schedule"
        echo -e "    ${CYAN}${BOLD}6)${NC} Stay-alive curl"
        echo -e "    ${CYAN}${BOLD}7)${NC} Cron jobs"
        echo -e "    ${CYAN}${BOLD}8)${NC} Notification forwarders"
        echo -e "    ${CYAN}${BOLD}9)${NC} Staged changes"
        echo -e "    ${CYAN}${BOLD}10)${NC} Alerts"
        echo -e "    ${CYAN}${BOLD}11)${NC} Save / Load configuration"
        echo -e "    ${CYAN}${BOLD}12)${NC} Command line"
        echo -e "    ${CYAN}${BOLD}13)${NC} Troubleshooting"
        echo ""
        echo -e "    ${DIM}0) Back${NC}"
        echo ""
        _read doc_choice "  $(echo -e "${BOLD}Choice:${NC} ")" || return 1
        case "$doc_choice" in
            4)
                print_header
                print_section "Create a StartOS Notification"
                echo ""
                echo -e "  This allows you to create a one-time notification with whatever information"
                echo -e "  you would like to provide. The notification will show up just like any other"
                echo -e "  notification in the notification section of the StartOS user interface."
                echo ""
                echo -e "  ${BOLD}You can specify:${NC}"
                echo ""
                echo -e "    ${CYAN}•${NC} What service it comes from  ${DIM}(or leave blank)${NC}"
                echo -e "    ${CYAN}•${NC} The message priority  ${DIM}(info, success, warning, error)${NC}"
                echo -e "    ${CYAN}•${NC} Message title"
                echo -e "    ${CYAN}•${NC} Message body"
                echo ""
                pause ;;
            1)
                print_header
                print_section "Display Disk Used by Services"
                echo ""
                echo -e "  This will show you the total, used, and available disk space on your server,"
                echo -e "  followed by a breakdown of how much disk space is used by each of the"
                echo -e "  different services installed on your StartOS server."
                echo ""
                pause ;;
            3)
                print_header
                print_section "Display Memory Used by Services"
                echo ""
                echo -e "  This will show the current memory usage, as well as the percentage of total"
                echo -e "  memory used by each of your services."
                echo ""
                pause ;;
            7)
                print_header
                print_section "Manage Cron Jobs"
                echo ""
                echo -e "  ${BOLD}View / delete:${NC} Shows all cron jobs currently scheduled on your server."
                echo -e "  Comments are dimmed; executable lines are numbered for deletion."
                echo -e "  Use ${CYAN}https://crontab.guru/${NC} to translate expressions into plain language."
                echo ""
                echo -e "  ${YELLOW}You should only keep jobs you are actively using.${NC}"
                echo ""
                echo -e "  ${BOLD}Add a cron job:${NC} Schedule any command to run on a recurring schedule."
                echo ""
                echo -e "  ${BOLD}You can specify:${NC}"
                echo ""
                echo -e "    ${CYAN}•${NC} ${BOLD}Schedule${NC} — a 5-field cron expression (minute hour day-of-month month"
                echo -e "      day-of-week). Validated for field count, allowed characters, and value"
                echo -e "      ranges before install. Use ${CYAN}https://crontab.guru/${NC} to build expressions."
                echo ""
                echo -e "    ${CYAN}•${NC} ${BOLD}Command${NC} — the shell command to run. A basic syntax check is performed;"
                echo -e "      you can proceed anyway if the check flags a false positive."
                echo ""
                echo -e "    ${CYAN}•${NC} ${BOLD}Post-command actions${NC} — optionally curl to a URL and/or create a"
                echo -e "      StartOS notification after the command completes."
                echo ""
                pause ;;
            5)
                print_header
                print_section "Schedule Backups"
                echo ""
                echo -e "  This allows you to add a cron entry that will automatically kick off backups."
                echo ""
                echo -e "  ${BOLD}You can specify:${NC}"
                echo ""
                echo -e "    ${CYAN}•${NC} ${BOLD}Backup target${NC} — where to send the backup. You must have already"
                echo -e "      created the target in the StartOS UI and manually tested it first"
                echo -e "      (on StartOS 0.4.3 and newer: System → Backups, drives included)."
                echo ""
                echo -e "    ${CYAN}•${NC} ${BOLD}Services to back up${NC} — select specific services or all of them."
                echo ""
                echo -e "    ${CYAN}•${NC} ${BOLD}Schedule${NC} — how frequently and at what time backups run, using cron"
                echo -e "      syntax. Use ${CYAN}https://crontab.guru/${NC} to verify your expression."
                echo ""
                echo -e "    ${CYAN}•${NC} ${BOLD}Post-backup action${NC} — optionally run a shell command and/or create a"
                echo -e "      StartOS notification. Enter the full command, e.g.:"
                echo -e "      ${DIM}curl -d \"Backup started\" https://ntfy.sh/Your-Topic${NC}"
                echo -e "      StartOS 0.4.2 and older notify you when a backup completes. StartOS 0.4.3"
                echo -e "      and newer don't — add a ${BOLD}Backup succeeded${NC} and a ${BOLD}Backup failed${NC} alert"
                echo -e "      (main menu → 10, Alerts) to be told how each backup went."
                echo ""
                echo -e "  ${BOLD}Password storage:${NC} your StartOS primary password is saved to a root-only"
                echo -e "  file (${DIM}${_SECRET_DIR}/backup-pass-<target>${NC}, mode 600) — it does NOT appear"
                echo -e "  in the crontab. It is briefly visible in the process list while a backup runs."
                echo ""
                echo -e "  ${BOLD}Physical drives:${NC} on StartOS 0.4.3 and newer, a drive added in System →"
                echo -e "  Backups gets a permanent id, and schedules use it. Before 0.4.3 they are saved"
                echo -e "  by filesystem UUID (${DIM}uuid-<UUID>${NC}), not by device name (${DIM}disk-/dev/sdb1${NC}),"
                echo -e "  which can change on replug or reboot; the backup finds the drive by UUID each"
                echo -e "  time, and fails if it is not connected. After updating to 0.4.3, add each such"
                echo -e "  drive in System → Backups; startos-admin then offers to switch its schedules."
                echo ""
                echo -e "  When you remove or retarget a schedule, its password file is deleted once no"
                echo -e "  cron entry uses it."
                echo ""
                pause ;;
            6)
                print_header
                print_section "Schedule Stay-Alive Curl"
                echo ""
                echo -e "  This causes your StartOS server to browse to a URL on a regular schedule —"
                echo -e "  for example, a monitoring service like ${CYAN}https://healthchecks.io/${NC}."
                echo ""
                echo -e "  That service can be configured to alert you if it stops receiving the"
                echo -e "  request within a defined time window. Hence the name: ${BOLD}Stay Alive${NC}."
                echo ""
                echo -e "  ${YELLOW}Why this matters:${NC} If your StartOS server goes offline — whether because"
                echo -e "  your internet connection fails or the server itself fails — nothing on your"
                echo -e "  server can notify you that it has failed. You need an external service to"
                echo -e "  detect the silence and send that alert."
                echo ""
                pause ;;
            8)
                print_header
                print_section "Manage Notification Forwarders"
                echo ""
                echo -e "  Creates persistent forwarders that forward StartOS notifications to"
                echo -e "  external systems via HTTP. Each forwarder periodically runs"
                echo -e "  ${CYAN}start-cli notification list${NC}, filters by level and/or keyword,"
                echo -e "  and POSTs matching notifications as plain text to a webhook URL."
                echo ""
                echo -e "  Multiple forwarders can run simultaneously — e.g., one for all"
                echo -e "  warnings, one scoped to backup errors only."
                echo ""
                echo -e "  ${BOLD}Configuration options:${NC}"
                echo ""
                echo -e "    ${CYAN}•${NC} ${BOLD}Name${NC} — identifier used in the forwarded message, log filename,"
                echo -e "      and state file (e.g. ${DIM}backup-errors${NC})"
                echo ""
                echo -e "    ${CYAN}•${NC} ${BOLD}URL${NC} — webhook endpoint to POST to (NTFY, Slack, Discord,"
                echo -e "      healthchecks.io, or any HTTP endpoint)"
                echo ""
                echo -e "    ${CYAN}•${NC} ${BOLD}Level filter${NC} — all / warning+error / error only / custom selection"
                echo ""
                echo -e "    ${CYAN}•${NC} ${BOLD}Keyword filter${NC} — optional text string; case-insensitive, searches"
                echo -e "      both the notification title and message body (blank = no filter)"
                echo ""
                echo -e "    ${CYAN}•${NC} ${BOLD}Schedule${NC} — how often to poll (every 5/15/30 min, hourly,"
                echo -e "      or a custom cron expression)"
                echo ""
                echo -e "  ${BOLD}Message format${NC} (plain text POST body):"
                echo ""
                echo -e "  ${DIM}2026.03.01 10:15:00 UTC  [backup-errors]  [Warning]  #42  btcpayserver  |  Backup Failed — Disk full${NC}"
                echo ""
                echo -e "  Fields: timestamp  [forwarder-name]  [Level]  #id  package  |  title — message"
                echo ""
                echo -e "  ${BOLD}First run behavior:${NC}"
                echo -e "  On the first poll after install (and after every reboot), the forwarder"
                echo -e "  silently seeds its state to the current newest notification — nothing is"
                echo -e "  forwarded. Subsequent runs forward only notifications newer than the"
                echo -e "  last one seen."
                echo ""
                echo -e "  ${BOLD}Files created per forwarder:${NC}"
                echo ""
                echo -e "    ${DIM}Script:  /usr/local/bin/startos-notif-poller-<name>${NC}"
                echo -e "    ${DIM}State:   ${_POLLER_STATE_PREFIX}<name>${NC}"
                echo -e "    ${DIM}Log:     ${_POLLER_LOG_PREFIX}<name>.log${NC}"
                echo ""
                pause ;;
            2)
                print_header
                print_section "System Data"
                echo ""
                echo -e "  This fetches a full dump of the StartOS system database and lets you"
                echo -e "  browse it by category."
                echo ""
                echo -e "  ${BOLD}Available views:${NC}"
                echo ""
                echo -e "    ${CYAN}•${NC} ${BOLD}Server Info${NC}    — hostname, OS version, architecture, last backup"
                echo -e "    ${CYAN}•${NC} ${BOLD}Network${NC}        — LAN/WAN addresses, WiFi, gateway IPs, DNS servers"
                echo -e "    ${CYAN}•${NC} ${BOLD}Service Status${NC} — all services with running/stopped state and health checks"
                echo -e "    ${CYAN}•${NC} ${BOLD}Service Detail${NC} — full detail for a single service"
                echo -e "    ${CYAN}•${NC} ${BOLD}Service Interfaces${NC} — every address of every interface, for chosen services"
                echo -e "    ${CYAN}•${NC} ${BOLD}Domains${NC}        — every domain on the server (the web UI's own included),"
                echo -e "      the interfaces that use it, its gateway and certificate, and a DNS check:"
                echo -e "      public domains are looked up in public DNS (1.1.1.1, then 9.9.9.9) and should"
                echo -e "      point at their gateway's public IP; private domains should be answered by"
                echo -e "      this server's own DNS on their gateway."
                echo ""
                pause ;;
            13)
                print_header
                print_section "Troubleshooting"
                echo ""
                echo -e "  ${BOLD}Cron jobs not running${NC}"
                echo -e "  Check that the cron daemon is active: ${CYAN}systemctl status cron${NC}"
                echo -e "  Verify entries exist: ${CYAN}sudo crontab -u root -l${NC}"
                echo -e "  Entries installed by this tool are prefixed with ${DIM}# startos-admin v${NC}"
                echo ""
                echo -e "  ${BOLD}Webhook not receiving messages${NC}"
                echo -e "  Use the test option in the forwarder install wizard to confirm the"
                echo -e "  URL is reachable. Check the poller log (volatile — lost on reboot):"
                echo -e "  ${DIM}/usr/local/share/startos-admin/startos-notif-poller-<name>.log${NC}"
                echo -e "  Look for ${DIM}curl${NC} errors or non-2xx HTTP responses."
                echo ""
                echo -e "  ${BOLD}Forwarder state file${NC}"
                echo -e "  State files are volatile and lost on reboot. On the first post-boot"
                echo -e "  cron run, the forwarder silently catches up — no notifications are"
                echo -e "  forwarded. Notifications that occurred during downtime are not sent."
                echo -e "  To force a re-seed manually, delete the state file:"
                echo -e "  ${DIM}/usr/local/share/startos-admin/startos-admin-poller-state-<name>${NC}"
                echo ""
                echo -e "  ${BOLD}start-cli authentication errors${NC}"
                echo -e "  Some features require ${CYAN}start-cli${NC} to be authenticated."
                echo -e "  If you see 'Failed to list packages', reconnect your SSH session"
                echo -e "  and confirm ${CYAN}start-cli db dump >/dev/null${NC} succeeds."
                echo -e "  To check the server is up at all, run ${CYAN}start-cli state${NC}"
                echo -e "  — it reports Running, Initializing, or Error and needs no auth."
                echo ""
                echo -e "  ${BOLD}Changes lost after reboot${NC}"
                echo -e "  StartOS does not persist changes by default. All changes made by"
                echo -e "  this tool go through ${CYAN}chroot-and-upgrade${NC}, which triggers a server"
                echo -e "  restart and makes the change permanent. If a change was not made"
                echo -e "  via this tool, it will be lost on next reboot."
                echo ""
                pause ;;
            9)
                print_header
                print_section "Staged Changes"
                echo ""
                echo -e "  Every change this tool makes (cron jobs, backup schedules, forwarders)"
                echo -e "  requires a server restart to become persistent. Staging lets you queue"
                echo -e "  several changes and apply them all with ${BOLD}one${NC} restart."
                echo ""
                echo -e "  At the end of each change wizard you choose:"
                echo ""
                echo -e "    ${CYAN}•${NC} ${BOLD}Apply now${NC} — restart immediately (any staged changes are included)"
                echo -e "    ${CYAN}•${NC} ${BOLD}Stage for later${NC} — add to the queue, no restart yet"
                echo ""
                echo -e "  ${BOLD}From the Staged changes menu you can:${NC}"
                echo ""
                echo -e "    ${CYAN}•${NC} View the queue (label + when it was staged)"
                echo -e "    ${CYAN}•${NC} Apply all staged changes  ${DIM}(one restart)${NC}"
                echo -e "    ${CYAN}•${NC} Delete staged change(s)   ${DIM}(safe — they were never applied)${NC}"
                echo ""
                echo -e "  ${YELLOW}Important:${NC} staged changes are NOT active until applied. The queue"
                echo -e "  survives exiting this script, but is ${BOLD}lost if the server reboots${NC}"
                echo -e "  before you apply. Views (cron list, forwarder list) show only what is"
                echo -e "  currently active — staged changes appear after they are applied."
                echo ""
                echo -e "  ${DIM}Queue file: ${_STAGED_FILE} (root-only)${NC}"
                echo ""
                pause ;;
            12)
                print_header
                print_section "Command Line"
                echo ""
                echo -e "  startos-admin can be used non-interactively for scripting and monitoring:"
                echo ""
                echo -e "    ${CYAN}startos-admin --version${NC}            print version and exit"
                echo -e "    ${CYAN}startos-admin --help${NC}               usage summary"
                echo -e "    ${CYAN}startos-admin --no-update-check${NC}    skip the startup update check this launch"
                echo -e "    ${CYAN}startos-admin --update${NC}             check for a signed update (does NOT install)"
                echo -e "    ${CYAN}startos-admin --update --yes${NC}       install a verified update ${RED}(SERVER RESTARTS)${NC}"
                echo ""
                echo -e "  ${BOLD}Show${NC} (read-only; plain output when piped):"
                echo ""
                echo -e "    ${CYAN}startos-admin status${NC}               the server status from the menu header"
                echo -e "    ${CYAN}startos-admin server-info${NC}          System data → Server Info"
                echo -e "    ${CYAN}startos-admin network${NC}              System data → Network"
                echo -e "    ${CYAN}startos-admin services${NC}             System data → Service Status"
                echo -e "    ${CYAN}startos-admin service nextcloud${NC}    System data → Service Detail"
                echo -e "    ${CYAN}startos-admin domains${NC}              every domain + DNS check (tab-separated)"
                echo -e "    ${CYAN}startos-admin domains --names${NC}      just the domain names"
                echo -e "    ${CYAN}startos-admin interfaces [svc]${NC}     interface URLs (tab-separated)"
                echo -e "    ${CYAN}startos-admin disk${NC} / ${CYAN}memory${NC}        usage by service"
                echo -e "    ${CYAN}startos-admin cron list${NC}            the root crontab"
                echo -e "    ${CYAN}startos-admin forwarders list${NC}      / ${CYAN}forwarders log <name>${NC}"
                echo -e "    ${CYAN}startos-admin alerts list${NC}          / ${CYAN}alerts log <id>${NC}"
                echo -e "    ${CYAN}startos-admin staged list${NC}          staged changes, numbered"
                echo ""
                echo -e "  ${BOLD}Change:${NC}"
                echo ""
                echo -e "    ${CYAN}startos-admin notify info \"Title\" \"Message\"${NC}   send a StartOS notification"
                echo -e "    ${CYAN}startos-admin debug on|off${NC}         debug mode (until the next restart)"
                echo -e "    ${CYAN}startos-admin staged drop 2${NC}        / ${CYAN}staged clear${NC}"
                echo -e "    ${CYAN}startos-admin alerts rebuild${NC}       stage the rebuild of outdated alerts"
                echo -e "    ${CYAN}startos-admin staged apply --yes${NC}   apply staged changes ${RED}(SERVER RESTARTS)${NC}"
                echo ""
                echo -e "  ${CYAN}startos-admin --help${NC} lists every option and the exit codes."
                echo ""
                echo -e "  Updates installed via ${CYAN}--update --yes${NC} are signature-verified first, and"
                echo -e "  include any staged changes in the same restart."
                echo ""
                pause ;;
            10)
                print_header
                print_section "Alerts"
                echo ""
                echo -e "  Monitors that watch your server on a cron schedule and alert you via a"
                echo -e "  shell command (e.g. webhook), a StartOS notification, or both:"
                echo ""
                echo -e "    ${CYAN}•${NC} ${BOLD}Disk usage alert${NC} — fires when usage reaches your % threshold"
                echo -e "    ${CYAN}•${NC} ${BOLD}Backup staleness alert${NC} — fires when any service has not been backed"
                echo -e "      up within your day threshold (never-backed-up counts as stale; you can"
                echo -e "      exclude services). One message lists ALL stale services."
                echo -e "      ${DIM}Reads each service's last successful backup time from StartOS (0.4.0.3+;${NC}"
                echo -e "      ${DIM}no password needed). Can also watch one backup target and alert when${NC}"
                echo -e "      ${DIM}it hasn't received a backup within the threshold.${NC}"
                echo -e "    ${CYAN}•${NC} ${BOLD}Service health watchdog${NC} — fires when a service that should be"
                echo -e "      running has failing health checks or is not running, persisting across"
                echo -e "      two consecutive checks (avoids noise from restarts/updates)."
                echo -e "    ${CYAN}•${NC} ${BOLD}Drive health alert${NC} — fires when an NVMe drive's SMART log shows"
                echo -e "      a critical warning, low spare capacity, wear past your % threshold, or"
                echo -e "      new media errors — the dying-drive warning the StartOS UI lacks."
                echo -e "      ${DIM}Reads SMART directly from the kernel (no packages installed).${NC}"
                echo -e "      ${DIM}NVMe drives only; SATA/USB drives are not monitored.${NC}"
                echo -e "    ${CYAN}•${NC} ${BOLD}Backup succeeded / Backup failed alerts${NC} — one notification per"
                echo -e "      finished backup that succeeded, or that failed or reported an error,"
                echo -e "      with the target, time and errors. ${DIM}StartOS 0.4.3+, which keeps these${NC}"
                echo -e "      ${DIM}results in System → Backups → History instead of notifying you. A backup${NC}"
                echo -e "      ${DIM}that never finishes is caught by the staleness alert, not these.${NC}"
                echo ""
                echo -e "  ${BOLD}Shell command contract:${NC} the alert text is provided in the ${CYAN}\$MSG${NC}"
                echo -e "  environment variable. Example:  ${DIM}curl -d \"\$MSG\" https://ntfy.sh/Your-Topic${NC}"
                echo -e "  Commands run as root via cron — same trust level as your cron jobs."
                echo ""
                echo -e "  ${BOLD}Re-alert policy:${NC} alert on first detection, immediately when the list of"
                echo -e "  affected services changes, and at most one reminder per 24h while the"
                echo -e "  condition persists. ${YELLOW}No recovery (all-clear) message is sent.${NC}"
                echo -e "  (The backup succeeded/failed alerts instead report each backup run once.)"
                echo ""
                echo -e "  Alert state is volatile — after a reboot, an ongoing condition re-alerts"
                echo -e "  once."
                echo ""
                echo -e "  ${BOLD}When a check can't run:${NC} if an alert fails to run its check ${BOLD}3 times in${NC}"
                echo -e "  ${BOLD}a row${NC} (StartOS unreachable, drive unreadable, backup target not connected),"
                echo -e "  it tells you once through the same route, then stays quiet until a check"
                echo -e "  succeeds. A server that is still starting up doesn't count."
                echo ""
                echo -e "  ${BOLD}Named instances:${NC} you can install several alerts of the same type, each"
                echo -e "  with its own name, threshold, notification route, and schedule — e.g."
                echo -e "  ${DIM}disk [warn50] → ntfy info at 50%  +  disk [crit85] → StartOS error at 85%${NC}"
                echo -e "  Instances are fully independent: with disk at 87%, BOTH of those are in"
                echo -e "  alert state (each with its own daily reminder). Two backup staleness"
                echo -e "  alerts can watch different backup targets."
                echo ""
                echo -e "    ${DIM}Scripts: ${_MONITOR_BIN_PREFIX}<type>-<name>${NC}"
                echo -e "    ${DIM}State:   ${_MONITOR_DATA_PREFIX}<type>-<name>.state${NC}"
                echo -e "    ${DIM}Logs:    ${_MONITOR_DATA_PREFIX}<type>-<name>.log${NC}"
                echo ""
                pause ;;
            11)
                print_header
                print_section "Save / Load Configuration"
                echo ""
                echo -e "  Saves your installed cron jobs and notification forwarders as a"
                echo -e "  single AES-256 encrypted configuration file, and can load them back"
                echo -e "  after an OS upgrade or reflash."
                echo ""
                echo -e "  ${BOLD}Save${NC} stores:"
                echo ""
                echo -e "    ${CYAN}•${NC} All root cron entries"
                echo -e "    ${CYAN}•${NC} All notification forwarder scripts  ${DIM}(including embedded webhook URLs)${NC}"
                echo -e "    ${CYAN}•${NC} All scheduled-backup password files  ${DIM}(root-only secrets)${NC}"
                echo ""
                echo -e "  ${BOLD}Load${NC} reinstalls everything in a single reboot — including the"
                echo -e "  ${CYAN}startos-admin${NC} script itself at ${DIM}/usr/local/bin/startos-admin${NC}."
                echo ""
                echo -e "  The configuration file is encrypted with AES-256-CBC using a passphrase"
                echo -e "  you provide, plus an HMAC-SHA256 integrity check that detects tampering"
                echo -e "  or corruption before loading. ${YELLOW}The passphrase cannot be recovered.${NC}"
                echo -e "  A forgotten passphrase makes the file permanently unreadable."
                echo ""
                echo -e "  The encrypted file is saved to ${DIM}${_CONFIG_BACKUP_FILE}${NC}."
                echo -e "  An ${CYAN}scp${NC} command is shown after saving to transfer it off the server."
                echo -e "  The same command (reversed) is shown at the start of the load flow."
                echo ""
                pause ;;
            0) return ;;
            *) print_warn "Enter 0-13." ; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Save / Load Configuration
# ─────────────────────────────────────────────

_config_export_flow() {
    print_header
    print_section "Save Configuration"
    echo ""
    _nav_tip

    # ── Preflight ─────────────────────────────────────────────────────────────
    if ! command -v openssl &>/dev/null; then
        print_error "openssl not found. Cannot create encrypted configuration file."
        pause; return
    fi

    local crontab_out
    crontab_out=$(sudo crontab -u root -l 2>/dev/null || true)
    local poller_scripts=("${_POLLER_BIN_PREFIX}"*)
    local has_pollers=0
    [[ -e "${poller_scripts[0]}" ]] && has_pollers=1

    if [[ -z "$crontab_out" && $has_pollers -eq 0 ]]; then
        print_warn "Nothing to save: no cron jobs and no forwarders are installed."
        pause; return
    fi

    # ── Encryption warning ────────────────────────────────────────────────────
    echo ""
    echo -e "  ${RED}${BOLD}┌─────────────────────────────────────────────────┐${NC}"
    echo -e "  ${RED}${BOLD}│  WARNING: ENCRYPTION PASSPHRASE CANNOT          │${NC}"
    echo -e "  ${RED}${BOLD}│  BE RECOVERED.                                  │${NC}"
    echo -e "  ${RED}${BOLD}│                                                 │${NC}"
    echo -e "  ${RED}${BOLD}│  If you forget the passphrase, this saved       │${NC}"
    echo -e "  ${RED}${BOLD}│  file will be permanently unreadable.           │${NC}"
    echo -e "  ${RED}${BOLD}│  There is no reset or recovery option.          │${NC}"
    echo -e "  ${RED}${BOLD}└─────────────────────────────────────────────────┘${NC}"
    echo ""

    # ── Collect and confirm passphrase ────────────────────────────────────────
    local passphrase passphrase2
    while true; do
        _read_silent passphrase "  Enter backup passphrase: " || return 1
        if [[ -z "$passphrase" ]]; then
            print_warn "Passphrase cannot be empty."
            continue
        fi
        _read_silent passphrase2 "  Confirm passphrase: " || { unset passphrase; return 1; }
        if [[ "$passphrase" == "$passphrase2" ]]; then
            unset passphrase2
            break
        fi
        print_warn "Passphrases do not match. Try again."
    done

    # ── Assemble plaintext bundle ─────────────────────────────────────────────
    local bundle
    bundle="STARTOS_ADMIN_BACKUP_V1"$'\n'
    bundle+="BACKUP_DATE=$(date '+%Y.%m.%d %H:%M:%S %Z')"$'\n'
    bundle+="CRONTAB_B64=$(printf '%s' "$crontab_out" | base64 -w 0)"$'\n'

    local pcount=0
    if [[ $has_pollers -eq 1 ]]; then
        local s
        for s in "${poller_scripts[@]}"; do
            [[ -f "$s" ]] || continue
            local pname="${s##${_POLLER_BIN_PREFIX}}"
            bundle+="POLLER_${pcount}_NAME=${pname}"$'\n'
            bundle+="POLLER_${pcount}_SCRIPT_B64=$(base64 -w 0 < "$s")"$'\n'
            (( pcount++ ))
        done
    fi
    bundle+="POLLER_COUNT=${pcount}"$'\n'

    # Alert monitor scripts (named instances; legacy unnamed also captured)
    local mcount=0
    local ms
    for ms in "${_MONITOR_BIN_PREFIX}"*; do
        [[ -f "$ms" ]] || continue
        bundle+="MONITOR_${mcount}_NAME=${ms##"${_MONITOR_BIN_PREFIX}"}"$'\n'
        bundle+="MONITOR_${mcount}_SCRIPT_B64=$(base64 -w 0 < "$ms")"$'\n'
        (( mcount++ ))
    done
    bundle+="MONITOR_COUNT=${mcount}"$'\n'

    # Backup-password secret files (root-only) — carried inside the encrypted
    # bundle so scheduled backups work again after a restore.
    local scount=0
    local -a secret_files=()
    mapfile -t secret_files < <(sudo find "$_SECRET_DIR" -maxdepth 1 -name 'backup-pass-*' -type f 2>/dev/null)
    local sf
    for sf in "${secret_files[@]}"; do
        [[ -n "$sf" ]] || continue
        bundle+="SECRET_${scount}_NAME=$(basename "$sf")"$'\n'
        bundle+="SECRET_${scount}_B64=$(sudo base64 -w 0 "$sf")"$'\n'
        (( scount++ ))
    done
    bundle+="SECRET_COUNT=${scount}"$'\n'

    # ── Encrypt (V2: ciphertext + HMAC-SHA256 integrity check) ───────────────
    local pass_file
    pass_file=$(mktemp)
    chmod 600 "$pass_file"
    printf '%s\n' "$passphrase" > "$pass_file"

    local ct enc_exit=0
    ct=$(printf '%s' "$bundle" \
        | openssl enc -aes-256-cbc -pbkdf2 -salt -a \
            -pass "file:${pass_file}") \
        || enc_exit=$?
    rm -f "$pass_file"

    if [[ $enc_exit -ne 0 || -z "$ct" ]]; then
        unset passphrase
        print_error "Encryption failed (openssl exit ${enc_exit}). Backup not written."
        pause; return
    fi

    local hmac
    hmac=$(_backup_hmac "$passphrase" "$ct")
    unset passphrase

    {
        echo "STARTOS_ADMIN_BACKUP_V2"
        printf '%s\n' "$ct"
        echo "HMAC:${hmac}"
    } > "$_CONFIG_BACKUP_FILE"

    # ── Display results ───────────────────────────────────────────────────────
    local cron_count=0
    [[ -n "$crontab_out" ]] && \
        cron_count=$(echo "$crontab_out" | grep -c '^# startos-admin v' 2>/dev/null || true)

    ${_START_CLI} notification create info "StartOS Admin" "StartOS Admin Configuration Saved" 2>/dev/null || true

    echo ""
    print_success "Configuration saved to: ${_CONFIG_BACKUP_FILE}"
    echo ""
    print_section "Save Summary"
    echo ""
    echo -e "  ${BOLD}Cron entries:${NC} ${cron_count} startos-admin managed entries"
    echo -e "  ${BOLD}Forwarders:${NC}   ${pcount}"
    echo -e "  ${BOLD}Alerts:${NC}       ${mcount}"
    echo -e "  ${BOLD}Backup passwords:${NC} ${scount} (root-only secret files)"
    echo ""
    print_section "Encrypted configuration file contents"
    echo ""
    cat "$_CONFIG_BACKUP_FILE"
    echo ""

    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')
    print_section "Copy this file off the server"
    echo ""
    echo -e "  Run this command from your ${BOLD}local machine${NC}:"
    echo ""
    echo -e "  ${CYAN}scp start9@${server_ip}:${_CONFIG_BACKUP_FILE} ./${NC}"
    echo ""

    pause
}

_config_restore_flow() {
    print_header
    print_section "Load Configuration"
    echo ""
    _nav_tip

    # ── scp instructions ──────────────────────────────────────────────────────
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')
    print_section "Copy the saved configuration file to this server first"
    echo ""
    echo -e "  Run this command from your ${BOLD}local machine${NC} before continuing:"
    echo ""
    echo -e "  ${CYAN}scp ./startos-config-backup.enc start9@${server_ip}:${_CONFIG_BACKUP_FILE}${NC}"
    echo ""

    local _rp_reply
    read -rp "$(echo -e "${DIM}  Press Enter once the file is on the server (or type 'exit' to quit)...${NC}")" _rp_reply
    [[ "${_rp_reply,,}" == "exit" ]] && exit 0

    # ── File path ─────────────────────────────────────────────────────────────
    echo ""
    local backup_path
    _read backup_path "  Path to configuration file [${_CONFIG_BACKUP_FILE}]: " || return 1
    [[ -z "$backup_path" ]] && backup_path="$_CONFIG_BACKUP_FILE"

    if [[ ! -f "$backup_path" ]]; then
        print_error "File not found: ${backup_path}"
        pause; return
    fi

    # ── Preflight ─────────────────────────────────────────────────────────────
    if ! command -v openssl &>/dev/null; then
        print_error "openssl not found. Cannot decrypt configuration file."
        pause; return
    fi

    # ── Collect passphrase and decrypt ────────────────────────────────────────
    echo ""
    local passphrase
    _read_silent passphrase "  Enter backup passphrase: " || return 1

    # V2 format: marker line, base64 ciphertext, trailing HMAC line.
    # Verify the HMAC before feeding anything to openssl. V1 files (raw
    # openssl base64) are still accepted, with a warning.
    local file_format ct=""
    file_format=$(head -1 "$backup_path")
    if [[ "$file_format" == "STARTOS_ADMIN_BACKUP_V2" ]]; then
        ct=$(sed -n '2,$p' "$backup_path" | grep -v '^HMAC:')
        local stored_hmac computed_hmac
        stored_hmac=$(grep '^HMAC:' "$backup_path" | head -1 | cut -d: -f2 | tr -d '[:space:]')
        computed_hmac=$(_backup_hmac "$passphrase" "$ct")
        if [[ -z "$stored_hmac" || "$computed_hmac" != "$stored_hmac" ]]; then
            unset passphrase
            print_error "Integrity check FAILED — wrong passphrase, or the file was corrupted or tampered with."
            print_warn "Load aborted. Nothing was changed."
            pause; return
        fi
        print_success "Integrity check passed."
    else
        print_warn "Legacy (v1) file format — no integrity protection. Proceeding."
    fi

    local pass_file
    pass_file=$(mktemp)
    chmod 600 "$pass_file"
    printf '%s\n' "$passphrase" > "$pass_file"
    unset passphrase

    local bundle dec_exit=0
    if [[ -n "$ct" ]]; then
        bundle=$(printf '%s\n' "$ct" | openssl enc -d -aes-256-cbc -pbkdf2 -a \
            -pass "file:${pass_file}") || dec_exit=$?
    else
        bundle=$(openssl enc -d -aes-256-cbc -pbkdf2 -a \
            -pass "file:${pass_file}" -in "$backup_path") || dec_exit=$?
    fi
    rm -f "$pass_file"

    if [[ $dec_exit -ne 0 || -z "$bundle" ]]; then
        print_error "Decryption failed. Wrong passphrase or corrupt file."
        pause; return
    fi

    # ── Validate and parse bundle ─────────────────────────────────────────────
    local header
    header=$(printf '%s' "$bundle" | head -1)
    if [[ "$header" != "STARTOS_ADMIN_BACKUP_V1" ]]; then
        print_error "Unrecognized file format. Cannot load."
        pause; return
    fi

    local crontab_b64 pcount backup_date
    backup_date=$(printf '%s' "$bundle" | grep '^BACKUP_DATE='  | head -1 | cut -d= -f2-)
    crontab_b64=$(printf '%s' "$bundle" | grep '^CRONTAB_B64='  | head -1 | cut -d= -f2-)
    pcount=$(printf '%s'      "$bundle" | grep '^POLLER_COUNT=' | head -1 | cut -d= -f2-)
    pcount="${pcount//[^0-9]/}"
    [[ -z "$pcount" ]] && pcount=0

    local -a pnames=() pscripts=()
    local pi
    for (( pi=0; pi<pcount; pi++ )); do
        pnames+=("$(printf '%s'  "$bundle" | grep "^POLLER_${pi}_NAME="        | head -1 | cut -d= -f2-)")
        pscripts+=("$(printf '%s' "$bundle" | grep "^POLLER_${pi}_SCRIPT_B64=" | head -1 | cut -d= -f2-)")
    done

    local mcount
    mcount=$(printf '%s' "$bundle" | grep '^MONITOR_COUNT=' | head -1 | cut -d= -f2-)
    mcount="${mcount//[^0-9]/}"
    [[ -z "$mcount" ]] && mcount=0

    local -a mnames=() mscripts=()
    local mi
    for (( mi=0; mi<mcount; mi++ )); do
        mnames+=("$(printf '%s'   "$bundle" | grep "^MONITOR_${mi}_NAME="       | head -1 | cut -d= -f2-)")
        mscripts+=("$(printf '%s' "$bundle" | grep "^MONITOR_${mi}_SCRIPT_B64=" | head -1 | cut -d= -f2-)")
    done

    local scount
    scount=$(printf '%s' "$bundle" | grep '^SECRET_COUNT=' | head -1 | cut -d= -f2-)
    scount="${scount//[^0-9]/}"
    [[ -z "$scount" ]] && scount=0

    local -a snames=() svals=()
    local si
    for (( si=0; si<scount; si++ )); do
        snames+=("$(printf '%s' "$bundle" | grep "^SECRET_${si}_NAME=" | head -1 | cut -d= -f2-)")
        svals+=("$(printf '%s'  "$bundle" | grep "^SECRET_${si}_B64="  | head -1 | cut -d= -f2-)")
    done

    # ── Validate every parsed field before it touches a root-owned path ──────
    # Names become file paths written as root inside the chroot — restrict to
    # the same charsets enforced at creation time (blocks path traversal in a
    # hand-crafted or corrupted bundle).
    if [[ -n "$crontab_b64" ]] && ! printf '%s' "$crontab_b64" | base64 -d >/dev/null 2>&1; then
        print_error "Saved crontab is not valid base64. Load aborted."
        pause; return
    fi
    for pi in "${!pnames[@]}"; do
        if ! [[ "${pnames[$pi]}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
            print_error "Saved file contains an invalid forwarder name: '${pnames[$pi]}'. Load aborted."
            pause; return
        fi
        if ! printf '%s' "${pscripts[$pi]}" | base64 -d >/dev/null 2>&1; then
            print_error "Forwarder script '${pnames[$pi]}' is not valid base64. Load aborted."
            pause; return
        fi
    done
    for si in "${!snames[@]}"; do
        if ! [[ "${snames[$si]}" =~ ^backup-pass-[A-Za-z0-9._-]+$ ]]; then
            print_error "Saved file contains an invalid secret file name: '${snames[$si]}'. Load aborted."
            pause; return
        fi
        if ! printf '%s' "${svals[$si]}" | base64 -d >/dev/null 2>&1; then
            print_error "Secret '${snames[$si]}' is not valid base64. Load aborted."
            pause; return
        fi
    done
    for mi in "${!mnames[@]}"; do
        if ! [[ "${mnames[$mi]}" =~ ^(disk|backup-age|backup-ok|backup-failed|health|drive)(-[a-zA-Z0-9][a-zA-Z0-9-]*)?$ ]]; then
            print_error "Saved file contains an invalid alert monitor name: '${mnames[$mi]}'. Load aborted."
            pause; return
        fi
        if ! printf '%s' "${mscripts[$mi]}" | base64 -d >/dev/null 2>&1; then
            print_error "Alert monitor '${mnames[$mi]}' is not valid base64. Load aborted."
            pause; return
        fi
    done

    # ── StartOS 0.4.3+: drive schedules saved by filesystem UUID ──────────────
    # 0.4.3 rejects the "disk-/dev/sdX" ids those schedules pass. Switch each
    # to its drive's registered id now (password file renamed to match), so
    # the loaded schedule works without a second restart. A drive not yet
    # added in System → Backups keeps its line; startos-admin reminds at launch.
    local -A lc_secret_rename=()
    local lc_uuid_fixed=0 lc_uuid_missing=0
    if [[ -n "$crontab_b64" ]] && _backup_targets_registered; then
        local lc_cron lc_tlist
        lc_cron=$(printf '%s' "$crontab_b64" | base64 -d)
        if [[ "$lc_cron" == *'backup create "disk-$(readlink -e /dev/disk/by-uuid/'* ]] \
           && lc_tlist=$(timeout 120 start-cli backup target list 2>/dev/null); then
            local lc_out="" lc_line lc_new lc_keys lc_rc
            while IFS= read -r lc_line; do
                lc_rc=0
                _backup_line_to_registered "$lc_line" "$lc_tlist" lc_new lc_keys || lc_rc=$?
                if [[ $lc_rc -eq 0 ]]; then
                    lc_out+="${lc_new}"$'\n'
                    lc_secret_rename["backup-pass-${lc_keys% *}"]="backup-pass-${lc_keys#* }"
                    (( lc_uuid_fixed++ )) || true
                else
                    [[ $lc_rc -eq 2 ]] && { (( lc_uuid_missing++ )) || true; }
                    lc_out+="${lc_line}"$'\n'
                fi
            done <<< "$lc_cron"
            crontab_b64=$(printf '%s' "${lc_out%$'\n'}" | base64 -w 0)
        fi
    fi

    # ── Show restore summary ──────────────────────────────────────────────────
    print_header
    print_section "Load Summary"
    echo ""
    echo -e "  ${BOLD}Saved on:${NC}     ${backup_date}"
    echo ""

    local cron_count=0
    [[ -n "$crontab_b64" ]] && \
        cron_count=$(printf '%s' "$crontab_b64" | base64 -d 2>/dev/null \
            | grep -c '^# startos-admin v' || true)
    echo -e "  ${BOLD}Cron entries:${NC} ${cron_count} startos-admin managed entries"
    (( lc_uuid_fixed > 0 )) && \
        echo -e "    ${DIM}• ${lc_uuid_fixed} drive backup schedule(s) switched to the drive's StartOS 0.4.3 id${NC}"
    (( lc_uuid_missing > 0 )) && \
        echo -e "    ${YELLOW}• ${lc_uuid_missing} drive backup schedule(s) need their drive added in System → Backups${NC}"

    echo -e "  ${BOLD}Forwarders:${NC}   ${pcount}"
    for pi in "${!pnames[@]}"; do
        echo -e "    ${DIM}• ${pnames[$pi]}${NC}"
    done
    echo -e "  ${BOLD}Alerts:${NC}       ${mcount}"
    for mi in "${!mnames[@]}"; do
        echo -e "    ${DIM}• ${mnames[$mi]}${NC}"
    done
    echo -e "  ${BOLD}Backup passwords:${NC} ${scount} (loaded root-only to ${_SECRET_DIR})"
    echo ""
    print_warn "Your current crontab will be REPLACED with the saved version."
    [[ $pcount -gt 0 ]] && \
        print_warn "Forwarder scripts with matching names will be overwritten."
    print_info "The latest startos-admin script will also be downloaded, signature-verified, and installed persistently."
    local _lc_pending
    _lc_pending=$(_staged_count)
    if [[ $_lc_pending -gt 0 ]]; then
        echo ""
        print_warn "You have ${_lc_pending} staged change(s) pending. They will be LOST when the server"
        print_warn "restarts for this load. Apply or delete them first (main menu → 9) if you need them."
    fi
    echo ""

    # ── Confirmations ─────────────────────────────────────────────────────────
    if ! confirm "Load this configuration?"; then
        [[ $_BACK -eq 1 ]] && return 1
        print_info "Cancelled."
        pause; return
    fi

    _warn_restart "after the configuration is loaded."
    if ! confirm "Proceed? (server will restart automatically)"; then
        [[ $_BACK -eq 1 ]] && return 1
        print_info "Cancelled."
        return
    fi

    ${_START_CLI} notification create info "StartOS Admin" "StartOS Admin Configuration Loaded" 2>/dev/null || true

    # ── Download + verify the latest script BEFORE entering the chroot ───────
    # If the download fails or the signature does not verify, the restore
    # proceeds without reinstalling startos-admin (nothing unverified is run).
    local verified_path="" fetch_rc=0 script_b64=""
    _fetch_verified_script verified_path || fetch_rc=$?
    if [[ $fetch_rc -eq 0 ]]; then
        script_b64=$(base64 -w 0 < "$verified_path")
        rm -rf "$(dirname "$verified_path")"
    elif [[ $fetch_rc -eq 2 ]]; then
        print_error "Downloaded script FAILED signature verification — startos-admin will NOT be reinstalled."
        print_warn "This may indicate a compromised repository. The rest of the load will proceed."
    else
        # Offline: install the copy that is running now (what the README's
        # install command just downloaded), unless it is already the
        # installed one.
        local _self
        _self=$(realpath "$0" 2>/dev/null || echo "$0")
        if [[ "$_self" != "/usr/local/bin/startos-admin" && -f "$_self" ]]; then
            print_warn "Could not download the latest script — installing this copy (v${VERSION}) instead."
            script_b64=$(base64 -w 0 < "$_self")
        else
            print_warn "Could not download the latest script — startos-admin will NOT be reinstalled."
            print_warn "Re-run the install command from the README after the load completes."
        fi
    fi

    # ── Build and run chroot session ──────────────────────────────────────────
    local chroot_body
    chroot_body="mkdir -p ${_STARTOS_DATA_DIR}
"
    if [[ -n "$script_b64" ]]; then
        chroot_body+="printf '%s' '${script_b64}' | base64 -d > /usr/local/bin/startos-admin
chmod +x /usr/local/bin/startos-admin
"
    fi
    if [[ -n "$crontab_b64" ]]; then
        chroot_body+="{ printf '%s' '${crontab_b64}' | base64 -d; echo; } | crontab -
"
    fi

    for pi in "${!pnames[@]}"; do
        local pn="${pnames[$pi]}"
        local ps="${pscripts[$pi]}"
        chroot_body+="printf '%s' '${ps}' | base64 -d > ${_POLLER_BIN_PREFIX}${pn}
chmod +x ${_POLLER_BIN_PREFIX}${pn}
"
    done

    for mi in "${!mnames[@]}"; do
        local mn="${mnames[$mi]}"
        local msb="${mscripts[$mi]}"
        # A saved alert script from an older startos-admin is rebuilt from its
        # settings with this version's generator, so a Load doesn't bring back
        # a check that no longer works (v71 staleness alerts on 0.4.1+). The
        # saved crontab already carries its schedule.
        local rebuilt=""
        _monitor_rebuild_saved "$mn" "$msb" rebuilt && msb="$rebuilt"
        chroot_body+="printf '%s' '${msb}' | base64 -d > ${_MONITOR_BIN_PREFIX}${mn}
chmod +x ${_MONITOR_BIN_PREFIX}${mn}
"
    done

    if [[ $scount -gt 0 ]]; then
        chroot_body+="mkdir -p ${_SECRET_DIR}
chmod 700 ${_SECRET_DIR}
"
        for si in "${!snames[@]}"; do
            local sn="${snames[$si]}"
            local sv="${svals[$si]}"
            [[ -n "${lc_secret_rename[$sn]:-}" ]] && sn="${lc_secret_rename[$sn]}"
            chroot_body+="printf '%s' '${sv}' | base64 -d > ${_SECRET_DIR}/${sn}
chmod 600 ${_SECRET_DIR}/${sn}
"
        done
    fi

    print_success "Load staged. Entering persistence mode now."
    echo ""
    debug_log "Loading: crontab=${cron_count} entries, pollers=${pcount}"

    local chroot_exit=0
    chroot_body+="${_SECRET_SWEEP_CMDS}
"
    sudo /usr/lib/startos/scripts/chroot-and-upgrade << EOF || chroot_exit=$?
${chroot_body}exit
EOF

    if [[ $chroot_exit -eq 0 ]]; then
        print_success "Configuration loaded."
        print_warn "The server will restart shortly — your SSH session will disconnect."
        print_warn "After reconnecting, run: startos-admin"
    else
        print_error "chroot-and-upgrade failed (exit ${chroot_exit}). Configuration may not have been fully loaded."
        pause
    fi
}

menu_config_backup_restore() {
    while true; do
        print_header
        print_section "Save / Load Configuration"
        echo ""
        echo -e "    ${CYAN}${BOLD}1)${NC} Save configuration  ${DIM}(encrypted file)${NC}"
        echo -e "    ${CYAN}${BOLD}2)${NC} Load configuration  ${DIM}(from a saved file)${NC}"
        echo ""
        echo -e "    ${DIM}0) Back${NC}"
        echo ""
        _read sub_choice "  $(echo -e "${BOLD}Choice:${NC} ")" || return 1
        case "$sub_choice" in
            1) _config_export_flow  || { _BACK=0; continue; } ;;
            2) _config_restore_flow || { _BACK=0; continue; } ;;
            0) return ;;
            *) print_warn "Enter 0-2." ; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Auto-Update Check
# ─────────────────────────────────────────────
# Two-phase flow:
#   Phase 1 — Persistent install check: if the script is not running from
#     /usr/local/bin/startos-admin, offer to install it there and return.
#     Version comparison is skipped in this case.
#   Phase 2 — Version check: fetch the remote script + signature from GitHub,
#     verify the signature against the embedded public key, extract VERSION,
#     and offer an upgrade if the remote version is newer. A script that fails
#     signature verification is never installed.
#     Runs only when already installed persistently.
# Both phases are silent on network failure.

check_for_update() {
    local remote_version

    # --no-update-check: skip the startup check entirely this launch
    if [[ "${_SKIP_UPDATE_CHECK:-0}" -eq 1 ]]; then
        debug_log "Update check skipped (--no-update-check)"
        return 0
    fi

    # ── First-run: not yet installed persistently ────────────────────────────
    local _script_path
    _script_path=$(realpath "$0" 2>/dev/null || echo "$0")
    if [[ "$_script_path" != "/usr/local/bin/startos-admin" ]]; then
        echo ""
        print_info "This script is not installed on this server yet."
        echo -e "  ${DIM}Installing puts it at /usr/local/bin/startos-admin, so 'startos-admin' runs from anywhere.${NC}"
        echo ""
        echo -e "    ${CYAN}${BOLD}1)${NC} Install it  ${DIM}(server restarts)${NC}"
        echo -e "    ${CYAN}${BOLD}2)${NC} Load a saved configuration  ${DIM}(installs it too, in the same restart)${NC}"
        echo -e "    ${CYAN}${BOLD}3)${NC} Not now  ${DIM}(go to the menu without installing)${NC}"
        echo ""
        local _fr_choice=""
        while true; do
            _read _fr_choice "  Choice [1-3]: " || { _BACK=0; _fr_choice=3; }
            case "$_fr_choice" in
                1|2|3) break ;;
                *) print_warn "Enter 1, 2 or 3." ;;
            esac
        done
        if [[ "$_fr_choice" == "2" ]]; then
            _config_restore_flow || true
            _BACK=0
            return 0
        fi
        if [[ "$_fr_choice" == "1" ]]; then
            _warn_restart "after the script is installed."
            if ! confirm "Proceed? (server will restart automatically)"; then
                [[ $_BACK -eq 1 ]] && { _BACK=0; }
                return 0
            fi
            echo ""
            local _pending
            _pending=$(_staged_count)
            [[ $_pending -gt 0 ]] && print_info "Including ${_pending} staged change(s) in the same restart."
            local _encoded
            _encoded=$(base64 -w 0 < "$_script_path")
            local chroot_exit=0
            _staged_run_chroot "printf '%s' \"${_encoded}\" | base64 -d > /usr/local/bin/startos-admin
chmod +x /usr/local/bin/startos-admin" || chroot_exit=$?
            if [[ $chroot_exit -eq 0 ]]; then
                print_success "Installed. Server restarting — reconnect and run: startos-admin"
            else
                print_error "Installation failed (exit $chroot_exit)."
                pause
            fi
        fi
        [[ $_BACK -eq 1 ]] && { _BACK=0; }
        return 0  # skip version check when not running from persistent install
    fi

    # ── Normal update check (only runs when already persistent) ─────────────
    # Fetch script + signature; fail silently if offline, loudly if the
    # signature does not verify.
    debug_log "Fetching remote script + signature from: $_REPO_RAW_URL"
    local verified_path="" fetch_rc=0
    _fetch_verified_script verified_path || fetch_rc=$?
    if [[ $fetch_rc -eq 1 ]]; then
        debug_log "Remote fetch failed or timed out — skipping update check"
        return 0
    elif [[ $fetch_rc -eq 2 ]]; then
        echo ""
        print_error "Update check: the published script FAILED signature verification."
        print_warn "Refusing to update. This may indicate a compromised repository."
        print_warn "Your installed version is unaffected."
        pause
        return 0
    fi

    remote_version=$(grep '^VERSION=' "$verified_path" | head -1 | tr -d '"' | cut -d= -f2 | awk '{print $1}') || true
    if [[ -z "$remote_version" ]]; then
        rm -rf "$(dirname "$verified_path")"
        return 0
    fi
    debug_log "Remote version: $remote_version  Local: $VERSION"

    # Compare as integers; skip if already current
    if [[ "$remote_version" -le "$VERSION" ]] 2>/dev/null; then
        rm -rf "$(dirname "$verified_path")"
        return 0
    fi

    echo ""
    print_info "A newer version is available: v${remote_version}  (you have v${VERSION})"
    print_info "Signature verified."
    echo ""
    if ! confirm "Download and install v${remote_version} persistently to /usr/local/bin/startos-admin?"; then
        [[ $_BACK -eq 1 ]] && _BACK=0
        rm -rf "$(dirname "$verified_path")"
        return 0
    fi

    _warn_restart "after the update is installed."
    if ! confirm "Proceed? (server will restart automatically)"; then
        [[ $_BACK -eq 1 ]] && _BACK=0
        rm -rf "$(dirname "$verified_path")"
        return 0
    fi
    echo ""

    local _pending
    _pending=$(_staged_count)
    [[ $_pending -gt 0 ]] && print_info "Including ${_pending} staged change(s) in the same restart."

    local encoded
    encoded=$(base64 -w 0 < "$verified_path")
    rm -rf "$(dirname "$verified_path")"

    local chroot_exit=0
    _staged_run_chroot "printf '%s' \"${encoded}\" | base64 -d > /usr/local/bin/startos-admin
chmod +x /usr/local/bin/startos-admin" || chroot_exit=$?

    if [[ $chroot_exit -eq 0 ]]; then
        print_success "Updated to v${remote_version}. Server restarting — reconnect and run: startos-admin"
    else
        print_error "Update failed (exit $chroot_exit)."
        pause
    fi
}

# ─────────────────────────────────────────────
# Debug Mode Toggle
# ─────────────────────────────────────────────

# Toggle debug mode on/off. Writes or removes the flag file; updates _DEBUG for this session.
menu_toggle_debug() {
    print_header
    print_section "Debug Mode"
    echo ""
    if [[ $_DEBUG -eq 1 ]]; then
        echo -e "  Debug mode is currently ${GREEN}${BOLD}ON${NC}."
        echo -e "  ${DIM}Shows extra output during operations and enables verbose poller logging.${NC}"
        echo ""
        if confirm "Disable debug mode?"; then
            if sudo rm -f "$_DEBUG_FLAG_FILE"; then
                _DEBUG=0
                print_success "Debug mode disabled."
            else
                print_error "Failed to remove flag file. Debug mode unchanged."
            fi
        else
            [[ $_BACK -eq 1 ]] && return 1
            print_info "No change."
        fi
    else
        echo -e "  Debug mode is currently ${DIM}OFF${NC}."
        echo -e "  ${DIM}Enabling shows extra output during operations and enables verbose poller logging.${NC}"
        echo ""
        if confirm "Enable debug mode?"; then
            sudo mkdir -p "$(dirname "$_DEBUG_FLAG_FILE")"
            if sudo touch "$_DEBUG_FLAG_FILE"; then
                _DEBUG=1
                print_success "Debug mode enabled."
            else
                print_error "Failed to create flag file. Debug mode unchanged."
            fi
        else
            [[ $_BACK -eq 1 ]] && return 1
            print_info "No change."
        fi
    fi
    echo ""
    pause
}

# ─────────────────────────────────────────────
# Main Menu
# ─────────────────────────────────────────────

main_menu() {
    check_for_update
    _offer_monitor_rebuild
    _offer_backup_target_upgrade
    while true; do
        print_header
        _status_block
        echo ""
        _nav_tip
        # Counts and labels for display
        local _cron_n _fwd_arr _fwd_n _stg_n _alrt_arr _alrt_n _dbg_label
        _cron_n=$(sudo crontab -u root -l 2>/dev/null | grep -c '^# startos-admin v' || true)
        _fwd_arr=("${_POLLER_BIN_PREFIX}"*)
        [[ -e "${_fwd_arr[0]}" ]] && _fwd_n=${#_fwd_arr[@]} || _fwd_n=0
        _alrt_arr=("${_MONITOR_BIN_PREFIX}"*)
        [[ -e "${_alrt_arr[0]}" ]] && _alrt_n=${#_alrt_arr[@]} || _alrt_n=0
        _stg_n=$(_staged_count)
        local _stg_label="${DIM}(${_stg_n})${NC}"
        [[ $_stg_n -gt 0 ]] && _stg_label="${YELLOW}(${_stg_n} pending)${NC}"
        [[ $_DEBUG -eq 1 ]] && _dbg_label="${GREEN}ON${NC}" || _dbg_label="${DIM}OFF${NC}"

        echo -e "  ${BOLD}Select an action:${NC}"
        echo ""
        echo -e "  ${DIM}Display${NC}"
        echo -e "    ${CYAN}${BOLD}1)${NC} Disk used by services"
        echo -e "    ${CYAN}${BOLD}2)${NC} System data"
        echo -e "    ${CYAN}${BOLD}3)${NC} Memory used by services"
        echo -e "  ${DIM}Create${NC}"
        echo -e "    ${CYAN}${BOLD}4)${NC} StartOS notification"
        echo -e "    ${CYAN}${BOLD}5)${NC} Backup schedule"
        echo -e "    ${CYAN}${BOLD}6)${NC} Stay-alive curl"
        echo -e "  ${DIM}Manage${NC}"
        echo -e "    ${CYAN}${BOLD}7)${NC} Cron jobs  ${DIM}(${_cron_n})${NC}"
        echo -e "    ${CYAN}${BOLD}8)${NC} Notification forwarders  ${DIM}(${_fwd_n})${NC}"
        echo -e "    ${CYAN}${BOLD}9)${NC} Staged changes  ${_stg_label}"
        echo -e "    ${CYAN}${BOLD}10)${NC} Alerts  ${DIM}(${_alrt_n})${NC}"
        echo -e "  ${DIM}Other${NC}"
        echo -e "    ${CYAN}${BOLD}11)${NC} Save / Load configuration"
        echo -e "    ${CYAN}${BOLD}12)${NC} Documentation"
        echo -e "    ${CYAN}${BOLD}13)${NC} Debug mode  ${DIM}(${NC}${_dbg_label}${DIM})${NC}"
        echo ""
        echo -e "    ${DIM}0) Exit${NC}"
        echo ""

        _read choice "  $(echo -e "${BOLD}Choice:${NC} ")" || { _BACK=0; continue; }

        case "$choice" in
            1) menu_disk_usage             || { _BACK=0; continue; } ;;
            2) menu_db_dump                || { _BACK=0; continue; } ;;
            3) menu_memory_usage           || { _BACK=0; continue; } ;;
            4) menu_create_notification    || { _BACK=0; continue; } ;;
            5) menu_schedule_backup        || { _BACK=0; continue; } ;;
            6) menu_schedule_stay_alive    || { _BACK=0; continue; } ;;
            7) menu_manage_crontab         || { _BACK=0; continue; } ;;
            8) menu_manage_notif_pollers   || { _BACK=0; continue; } ;;
            9) menu_staged_changes         || { _BACK=0; continue; } ;;
            10) menu_alerts                || { _BACK=0; continue; } ;;
            11) menu_config_backup_restore || { _BACK=0; continue; } ;;
            12) menu_documentation         || { _BACK=0; continue; } ;;
            13) menu_toggle_debug          || { _BACK=0; continue; } ;;
            0)
                echo ""
                if [[ $(_staged_count) -gt 0 ]]; then
                    print_warn "$(_staged_count) staged change(s) are still pending. They survive exiting"
                    print_warn "this script but are LOST if the server reboots before you apply them."
                fi
                print_info "Goodbye."
                echo ""
                exit 0
                ;;
            *)
                print_warn "Invalid choice. Enter 0-13."
                sleep 1
                ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Non-Interactive CLI
# ─────────────────────────────────────────────

_usage() {
    cat << EOF
startos-admin v${VERSION} — StartOS server administration

Usage:
  startos-admin                     Interactive menu
  startos-admin --version           Print version and exit
  startos-admin --help              This help
  startos-admin --no-update-check   Skip the startup update check this launch
  startos-admin --update            Check for a signed update (does NOT install)
  startos-admin --update --yes      Install a verified update (SERVER RESTARTS)

Show (read-only):
  startos-admin status              Server status (the menu's header lines)
  startos-admin server-info         Hostname, version, architecture, last backup
  startos-admin network             Addresses, WiFi, gateways, DNS servers
  startos-admin services            Every service's state and health checks
  startos-admin service <id>        One service: status, backup, health, dependencies
  startos-admin domains [svc]       Every domain, with a DNS check (tab-separated:
                                    domain, service, interface, url, access,
                                    gateway, cert, state, dns, resolved,
                                    expected, resolver). 'startos' = the web UI
  startos-admin domains --names     Just the domain names, one per line
  startos-admin interfaces [svc]    Service interface URLs (tab-separated:
                                    service, interface, type, network, url,
                                    state, kind)
  startos-admin disk                Disk usage by service
  startos-admin memory              Memory usage by service
  startos-admin cron list           The root crontab
  startos-admin forwarders list     Installed notification forwarders
  startos-admin forwarders log <name> [lines]
  startos-admin alerts list         Installed alerts (with their ids)
  startos-admin alerts log <id> [lines]
  startos-admin staged list         Staged changes, numbered
  startos-admin debug               Debug mode: on or off

Change:
  startos-admin notify [--service <id>] <info|success|warning|error> <title> <message>
                                    Send a StartOS notification now
  startos-admin debug on|off        Debug mode (until the next restart)
  startos-admin staged drop <n>[,<n>...]   Remove staged change(s)
  startos-admin staged clear        Remove all staged changes
  startos-admin alerts rebuild      Stage the rebuild of alerts made by an older
                                    startos-admin (settings kept)
  startos-admin alerts rebuild --apply --yes   ...and apply it now (SERVER RESTARTS)
  startos-admin staged apply --yes  Apply all staged changes (SERVER RESTARTS)

Exit codes: 0 = done    1 = failed    2 = usage error
  --update:          10 = update available (not installed)
                     1 = network/download failure    3 = signature verification failure
  staged apply:      10 = not applied (no --yes); the changes are listed
EOF
}

# Check for (and with --yes, install) a signed update. Never installs
# anything that fails signature verification. Exits; never returns.
_cli_update() {
    local do_install="${1:-}"
    local verified_path="" rc=0
    _fetch_verified_script verified_path || rc=$?
    if [[ $rc -eq 1 ]]; then
        echo "ERROR: could not download the published script (network failure)." >&2
        exit 1
    elif [[ $rc -eq 2 ]]; then
        echo "ERROR: published script FAILED signature verification — refusing to update." >&2
        echo "This may indicate a compromised repository." >&2
        exit 3
    fi

    local remote_version
    remote_version=$(grep '^VERSION=' "$verified_path" | head -1 | tr -d '"' | cut -d= -f2 | awk '{print $1}') || true
    if [[ -z "$remote_version" ]] || [[ "$remote_version" -le "$VERSION" ]] 2>/dev/null; then
        rm -rf "$(dirname "$verified_path")"
        echo "Up to date (v${VERSION})."
        exit 0
    fi

    echo "Update available: v${remote_version} (you have v${VERSION}). Signature verified."
    if [[ "$do_install" != "--yes" ]]; then
        rm -rf "$(dirname "$verified_path")"
        echo "Run 'startos-admin --update --yes' to install (server will restart)."
        exit 10
    fi

    local encoded
    encoded=$(base64 -w 0 < "$verified_path")
    rm -rf "$(dirname "$verified_path")"
    local pending
    pending=$(_staged_count)
    [[ $pending -gt 0 ]] && echo "Including ${pending} staged change(s) in the same restart."
    local chroot_exit=0
    _staged_run_chroot "printf '%s' \"${encoded}\" | base64 -d > /usr/local/bin/startos-admin
chmod +x /usr/local/bin/startos-admin" || chroot_exit=$?
    if [[ $chroot_exit -eq 0 ]]; then
        echo "Updated to v${remote_version}. Server restarting."
        exit 0
    fi
    echo "ERROR: install failed (chroot-and-upgrade exit ${chroot_exit})." >&2
    exit 1
}

_cli_disk() {
    local vol="/media/startos/data/package-data/volumes/"
    df -h "$vol" 2>/dev/null || true
    echo ""
    sudo du -hd 1 "$vol" 2>/dev/null | sort -rh || true
    exit 0
}

_cli_memory() {
    local stats
    if ! stats=$(start-cli package stats 2>&1); then
        echo "ERROR: 'start-cli package stats' failed: ${stats}" >&2
        exit 1
    fi
    _format_pkg_stats "$stats" "" "" "" ""
    exit 0
}

# CLI output goes to scripts and files as often as to a terminal: no color
# codes unless stdout is a terminal.
_cli_plain_if_piped() {
    [[ -t 1 ]] && return 0
    GREEN=""; RED=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; DIM=""; NC=""
}

# Usage error: message, then the usage summary, both on stderr; exit 2.
_cli_usage_error() {
    echo "ERROR: $1" >&2
    echo "Run 'startos-admin --help' for usage." >&2
    exit 2
}

# Database dump for a CLI command into nameref $1, or exit 1 saying why.
_cli_db() {
    local -n _cd_out="$1"
    if ! _cd_out=$(start-cli db dump 2>&1); then
        local st
        st=$(_startos_state)
        if [[ "$st" != "Running" ]]; then
            echo "ERROR: StartOS is not running (state: ${st}); its database is unavailable." >&2
        else
            echo "ERROR: 'start-cli db dump' failed: ${_cd_out}" >&2
        fi
        exit 1
    fi
}

# Exit 1 unless service $2 is installed (db dump in $1).
_cli_need_service() {
    if ! echo "$1" | jq -e --arg s "$2" '.value.packageData | has($s)' >/dev/null 2>&1; then
        echo "ERROR: no installed service with id '${2}'." >&2
        echo "Installed: $(echo "$1" | jq -r '.value.packageData | keys | join(" ")')" >&2
        exit 1
    fi
}

_cli_status() {
    _status_block
    exit 0
}

# server-info | network | services — the System Data views.
_cli_db_view() {
    local db
    _cli_db db
    case "$1" in
        server-info) _show_server_info "$db" ;;
        network)     _show_network     "$db" ;;
        services)    _show_svc_status  "$db" ;;
    esac
    exit 0
}

_cli_service() {
    local svc="${1:-}"
    [[ -n "$svc" ]] || _cli_usage_error "'service' needs a service id, e.g. startos-admin service nextcloud"
    local db
    _cli_db db
    _cli_need_service "$db" "$svc"
    _show_svc_detail "$db" "$svc"
    exit 0
}

_cli_interfaces() {
    local svc="${1:-}"
    local db
    _cli_db db
    local jq_filter
    if [[ -n "$svc" ]]; then
        jq_filter=$(printf '%s' "$svc" | jq -R . | jq -sc .)
    else
        jq_filter=$(echo "$db" | jq -c '.value.packageData | keys')
    fi
    local out
    out=$(_interfaces_tsv "$db" "$jq_filter") || true
    if [[ -z "$out" ]]; then
        if [[ -n "$svc" ]]; then
            echo "ERROR: no interfaces found for service '${svc}'." >&2
            exit 1
        fi
        exit 0
    fi
    printf '%s\n' "$out"
    exit 0
}

# domains [--names] [svc] — every domain with its DNS check, tab-separated
# (see _domains_report), or with --names just the names, one per line.
# "startos" as the service selects the web interface's own domains.
_cli_domains() {
    local want_names=0 svc="" a
    for a in "$@"; do
        case "$a" in
            --names) want_names=1 ;;
            -*)      _cli_usage_error "unknown option for 'domains': $a" ;;
            *)       [[ -z "$svc" ]] || _cli_usage_error "'domains' takes at most one service id"
                     svc="$a" ;;
        esac
    done
    local db
    _cli_db db
    local svcs withos=1
    if [[ -z "$svc" ]]; then
        svcs=$(echo "$db" | jq -c '.value.packageData | keys')
    elif [[ "$svc" == "startos" ]]; then
        svcs='[]'
    else
        _cli_need_service "$db" "$svc"
        svcs=$(printf '%s' "$svc" | jq -R . | jq -sc .); withos=0
    fi
    if (( want_names )); then
        _domains_tsv "$db" "$svcs" "$withos" | cut -f1 | sort -u
    else
        _domains_report "$db" "$svcs" "$withos"
    fi
    exit 0
}

# cron list — the root crontab as installed (comments included).
_cli_cron() {
    [[ "${1:-}" == "list" ]] || _cli_usage_error "usage: startos-admin cron list"
    local out rc=0
    out=$(sudo crontab -u root -l 2>&1) || rc=$?
    if (( rc != 0 )); then
        grep -qi "no crontab for" <<< "$out" && exit 0
        echo "ERROR: could not read the root crontab: ${out}" >&2
        exit 1
    fi
    local pending
    pending=$(_staged_count)
    (( pending > 0 )) && echo "Note: ${pending} staged change(s) pending — not in this list until applied." >&2
    printf '%s\n' "$out"
    exit 0
}

# Validate a log line count ($1, default 50) into nameref $2.
_cli_lines_arg() {
    local -n _cla_out="$2"
    _cla_out="${1:-50}"
    [[ "$_cla_out" =~ ^[0-9]+$ ]] && (( _cla_out >= 1 && _cla_out <= 100000 )) \
        || _cli_usage_error "line count must be a number from 1 to 100000"
}

# forwarders list | log <name> [lines]
_cli_forwarders() {
    case "${1:-}" in
        list)
            _poller_list_display || true
            exit 0 ;;
        log)
            local name="${2:-}" lines
            [[ -n "$name" ]] || _cli_usage_error "usage: startos-admin forwarders log <name> [lines]"
            _cli_lines_arg "${3:-}" lines
            if ! [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] || [[ ! -f "${_POLLER_BIN_PREFIX}${name}" ]]; then
                echo "ERROR: no forwarder named '${name}'. See: startos-admin forwarders list" >&2
                exit 1
            fi
            local log_file="${_POLLER_LOG_PREFIX}${name}.log"
            if [[ ! -f "$log_file" ]]; then
                echo "No log yet: ${log_file} (the forwarder may not have run since the last restart)." >&2
                exit 0
            fi
            tail -n "$lines" "$log_file"
            exit 0 ;;
        *) _cli_usage_error "usage: startos-admin forwarders list | log <name> [lines]" ;;
    esac
}

# alerts list | log <id> [lines] | rebuild [--apply --yes]
_cli_alerts() {
    case "${1:-}" in
        list)
            _monitor_list_display || true
            exit 0 ;;
        log)
            local id="${2:-}" lines
            [[ -n "$id" ]] || _cli_usage_error "usage: startos-admin alerts log <id> [lines]   (ids: startos-admin alerts list)"
            _cli_lines_arg "${3:-}" lines
            if ! _monitor_installed | cut -f3 | grep -qxF "${_MONITOR_BIN_PREFIX}${id}"; then
                echo "ERROR: no alert with id '${id}'. See the Id lines in: startos-admin alerts list" >&2
                exit 1
            fi
            local log_file="${_MONITOR_DATA_PREFIX}${id}.log"
            if [[ ! -f "$log_file" ]]; then
                echo "No log yet: ${log_file} (the alert may not have run since the last restart)." >&2
                exit 0
            fi
            tail -n "$lines" "$log_file"
            exit 0 ;;
        rebuild)
            shift
            local apply=0 yes=0 a
            for a in "$@"; do
                case "$a" in
                    --apply) apply=1 ;;
                    --yes)   yes=1 ;;
                    *) _cli_usage_error "unknown option for 'alerts rebuild': $a" ;;
                esac
            done
            (( apply && ! yes )) && _cli_usage_error "--apply restarts the server; add --yes to confirm"
            if [[ -z "$(_monitor_outdated)" ]]; then
                echo "All installed alerts are up to date."
                exit 0
            fi
            if _staged_labels 2>/dev/null | grep -qF "$_REBUILD_LABEL"; then
                echo "The rebuild is already staged. Apply it with: startos-admin staged apply --yes"
                exit 0
            fi
            local cmds="" n=0 list="" v72=0 v73=0
            _monitor_rebuild_plan cmds n list v72 v73
            echo "Built by an older startos-admin:"
            printf '%s' "$list" | while IFS= read -r l; do echo -e "$l"; done
            if (( n == 0 )); then
                echo "Nothing can be rebuilt (see above)." >&2
                exit 1
            fi
            _monitor_rebuild_reasons "$v72" "$v73"
            if (( apply )); then
                local pending chroot_exit=0
                pending=$(_staged_count)
                (( pending > 0 )) && echo "Including ${pending} staged change(s) in the same restart."
                _staged_run_chroot "$cmds" || chroot_exit=$?
                if (( chroot_exit == 0 )); then
                    echo "Rebuilt ${n} alert(s). Server restarting."
                    exit 0
                fi
                echo "ERROR: chroot-and-upgrade failed (exit ${chroot_exit}). Nothing was applied." >&2
                exit 1
            fi
            _stage_change "$_REBUILD_LABEL (${n})" "$cmds"
            echo "Staged the rebuild of ${n} alert(s). Apply with: startos-admin staged apply --yes (server restarts)"
            exit 0 ;;
        *) _cli_usage_error "usage: startos-admin alerts list | log <id> [lines] | rebuild [--apply --yes]" ;;
    esac
}

# debug [on|off] — show or set debug mode (this boot only, as in the menu).
_cli_debug() {
    case "${1:-}" in
        "")  [[ -f "$_DEBUG_FLAG_FILE" ]] && echo "on" || echo "off"; exit 0 ;;
        on)  sudo mkdir -p "$(dirname "$_DEBUG_FLAG_FILE")" && sudo touch "$_DEBUG_FLAG_FILE" \
                 || { echo "ERROR: could not create ${_DEBUG_FLAG_FILE}." >&2; exit 1; }
             echo "Debug mode on."; exit 0 ;;
        off) sudo rm -f "$_DEBUG_FLAG_FILE" \
                 || { echo "ERROR: could not remove ${_DEBUG_FLAG_FILE}." >&2; exit 1; }
             echo "Debug mode off."; exit 0 ;;
        *)   _cli_usage_error "usage: startos-admin debug [on|off]" ;;
    esac
}

# staged list | apply [--yes] | drop <n>[,<n>…] | clear
_cli_staged() {
    local n
    n=$(_staged_count)
    case "${1:-}" in
        list)
            (( n > 0 )) && _staged_labels
            exit 0 ;;
        apply)
            if (( n == 0 )); then echo "No staged changes."; exit 0; fi
            if [[ "${2:-}" != "--yes" ]]; then
                _staged_labels
                echo "Run 'startos-admin staged apply --yes' to apply ${n} change(s) (SERVER RESTARTS)."
                exit 10
            fi
            local chroot_exit=0
            _staged_run_chroot "" || chroot_exit=$?
            if (( chroot_exit == 0 )); then
                echo "Applied ${n} staged change(s). Server restarting."
                exit 0
            fi
            echo "ERROR: chroot-and-upgrade failed (exit ${chroot_exit}). Staged changes remain queued." >&2
            exit 1 ;;
        drop)
            local drop_sel="${2:-}" part
            [[ -n "$drop_sel" ]] || _cli_usage_error "usage: startos-admin staged drop <n>[,<n>...]   (numbers from: staged list)"
            local -a nums=() parts=()
            IFS=',' read -ra parts <<< "$drop_sel"
            for part in "${parts[@]}"; do
                part="${part// /}"
                [[ "$part" =~ ^[0-9]+$ ]] && (( part >= 1 && part <= n )) \
                    || { echo "ERROR: '${part}' is not a staged change number (1-${n})." >&2; exit 1; }
                nums+=("$part")
            done
            local csv
            csv=$(printf '%s\n' "${nums[@]}" | sort -nu | paste -sd, -)
            _staged_delete "$csv"
            echo "Dropped staged change(s) ${csv}. Nothing was applied."
            exit 0 ;;
        clear)
            _staged_clear
            echo "Cleared ${n} staged change(s). Nothing was applied."
            exit 0 ;;
        *) _cli_usage_error "usage: startos-admin staged list | apply [--yes] | drop <n>[,<n>...] | clear" ;;
    esac
}

# notify [--service <id>] <info|success|warning|error> <title> <message>
_cli_notify() {
    local svc=""
    if [[ "${1:-}" == "--service" ]]; then
        svc="${2:-}"
        [[ -n "$svc" ]] || _cli_usage_error "--service needs a service id"
        shift 2
    fi
    [[ $# -eq 3 ]] || _cli_usage_error "usage: startos-admin notify [--service <id>] <info|success|warning|error> <title> <message>"
    local level="$1" title="$2" body="$3"
    case "$level" in
        info|success|warning|error) ;;
        *) _cli_usage_error "level must be info, success, warning or error" ;;
    esac
    [[ -n "$title" && -n "$body" ]] || _cli_usage_error "title and message must not be empty"
    local -a pkg_args=()
    if [[ -n "$svc" ]]; then
        # start-cli accepts any package id here, so a typo would post a
        # notification for a service that doesn't exist.
        local db
        _cli_db db
        _cli_need_service "$db" "$svc"
        pkg_args=(--package "$svc")
    fi
    local out
    if ! out=$(start-cli notification create "${pkg_args[@]}" "$level" "$title" "$body" 2>&1); then
        echo "ERROR: 'start-cli notification create' failed: ${out}" >&2
        exit 1
    fi
    echo "Notification created."
    exit 0
}

# ─────────────────────────────────────────────
# Entry Point
# ─────────────────────────────────────────────

# All required commands are preinstalled on StartOS; this guards against
# running the script somewhere it doesn't belong.
_missing=()
for _dep in jq curl openssl; do
    command -v "$_dep" >/dev/null 2>&1 || _missing+=("$_dep")
done
if [[ ${#_missing[@]} -gt 0 ]]; then
    print_error "Missing required command(s): ${_missing[*]}"
    print_info "This script is intended to run on a StartOS server."
    exit 1
fi

_SKIP_UPDATE_CHECK=0
case "${1:-}" in
    "") : ;;
    --version|-v)      echo "startos-admin v${VERSION}"; exit 0 ;;
    --help|-h)         _usage; exit 0 ;;
    --no-update-check) _SKIP_UPDATE_CHECK=1 ;;
    --update)          _cli_update "${2:-}" ;;
    disk)              _cli_disk ;;
    memory)            _cli_memory ;;
    interfaces)        _cli_plain_if_piped; _cli_interfaces "${2:-}" ;;
    status)            _cli_plain_if_piped; _cli_status ;;
    server-info|network|services)
                       _cli_plain_if_piped; _cli_db_view "$1" ;;
    service)           _cli_plain_if_piped; _cli_service "${2:-}" ;;
    domains)           _cli_plain_if_piped; shift; _cli_domains "$@" ;;
    cron)              _cli_plain_if_piped; _cli_cron "${2:-}" ;;
    forwarders)        _cli_plain_if_piped; shift; _cli_forwarders "$@" ;;
    alerts)            _cli_plain_if_piped; shift; _cli_alerts "$@" ;;
    staged)            _cli_plain_if_piped; shift; _cli_staged "$@" ;;
    debug)             _cli_plain_if_piped; _cli_debug "${2:-}" ;;
    notify)            _cli_plain_if_piped; shift; _cli_notify "$@" ;;
    *)
        echo "Unknown option: $1" >&2
        echo "" >&2
        _usage >&2
        exit 2
        ;;
esac

main_menu
