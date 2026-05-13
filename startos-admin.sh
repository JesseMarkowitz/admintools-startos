#!/usr/bin/env bash
# startos-admin.sh — Interactive admin menu for StartOS servers
# Usage: chmod +x startos-admin.sh && ./startos-admin.sh
#
# Features:
#   1. Create StartOS notification      — fire a one-time notification via start-cli
#   2. Disk usage                       — per-service disk breakdown
#   3. Memory usage                     — per-service memory breakdown
#   4. Manage cron jobs                 — view, delete, and add persistent cron entries
#   5. Schedule backups                 — cron-based automated backup with notification
#   6. Schedule stay-alive curl         — periodic curl to keep an external monitor alive
#   7. Manage notification forwarders   — poll start-cli notifications, forward via webhook
#   8. System database viewer           — browse start-cli db dump by category

VERSION="56"   # integer — increment on each release

set -euo pipefail

# ─────────────────────────────────────────────
# Colors & Styles
# ─────────────────────────────────────────────
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
BOLD="\e[1m"
DIM="\e[2m"
NC="\e[0m"

# ─────────────────────────────────────────────
# Path Constants
# ─────────────────────────────────────────────
_POLLER_BIN_PREFIX="/usr/local/bin/startos-notif-poller-"
_STARTOS_DATA_DIR="/usr/local/share/startos-admin"
_POLLER_STATE_PREFIX="${_STARTOS_DATA_DIR}/startos-admin-poller-state-"
_POLLER_LOG_PREFIX="${_STARTOS_DATA_DIR}/startos-notif-poller-"
# Full path to start-cli — resolved once so cron jobs and generated scripts
# embed the absolute path and don't depend on cron's minimal PATH.
_START_CLI=$(command -v start-cli 2>/dev/null || echo "start-cli")
_CONFIG_BACKUP_FILE="/tmp/startos-config-backup.enc"

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
    clear
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

pause() {
    echo ""
    local _p_reply
    read -rp "$(echo -e "${DIM}  Press Enter to continue (or type 'exit' to quit)...${NC}")" _p_reply
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

# Run a command, show colored output, return its exit code
run_cmd() {
    local output exit_code=0
    output=$("$@" 2>&1) || exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        echo "$output"
    else
        print_error "Command failed (exit $exit_code)"
        echo -e "${RED}${output}${NC}"
    fi
    return $exit_code
}

# Extract package IDs from start-cli package list JSON output.
# Uses jq if available, falls back to grep+sed.
parse_package_ids() {
    local json="$1"
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r '.[].id'
    else
        echo "$json" | grep '"id":' | sed 's/.*"id": *"\([^"]*\)".*/\1/'
    fi
}

# Extract backup targets from start-cli backup target list JSON output.
# Outputs one line per target: "id  (hostname/path)"
# The ID is always the first whitespace-delimited field on each line.
parse_backup_targets() {
    local json="$1"
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r '
            to_entries[] |
            "\(.key)  (\(.value.hostname // .value.type // "unknown")\(.value.path // ""))"
        '
    else
        # Top-level keys sit at exactly 2-space indent: '  "cifs-0": {'
        echo "$json" | grep -E '^  "[^"]+": \{' | sed 's/  "\([^"]*\)": {.*/\1/'
    fi
}

# ─────────────────────────────────────────────
# Cron Installation (Persistence via chroot-and-upgrade)
# ─────────────────────────────────────────────

# Install a cron job persistently using StartOS's chroot-and-upgrade mechanism.
# Warns the user that the server will automatically restart, then:
#   1. Writes the merged crontab (existing + new line) to a temp file in /tmp
#   2. Enters chroot-and-upgrade and installs the crontab from that file
#   3. Exits the chroot session (which triggers the automatic server restart)
install_cron_job() {
    local cron_line="$1"
    local action_label="${2:-startos-admin}"

    # Duplicate check
    if crontab -u root -l 2>/dev/null | grep -qF "$cron_line"; then
        print_warn "An identical cron job already exists. Skipping install."
        return 0
    fi

    # Restart warning — shown before the point of no return
    _warn_restart "after the cron job is installed."

    if ! confirm "Proceed? (server will restart automatically)"; then
        [[ $_BACK -eq 1 ]] && return 1
        print_info "Cancelled."
        return 1
    fi

    # Build comment line, then base64-encode both comment and cron line so they
    # can be safely embedded in the heredoc (no quoting issues with special chars).
    local install_ts
    install_ts=$(date '+%Y.%m.%d %H:%M:%S %Z')
    local comment_line="# startos-admin v${VERSION} | Added: ${install_ts} | Action: ${action_label}"
    local encoded_comment encoded_line
    encoded_comment=$(printf '%s' "$comment_line" | base64 -w 0)
    encoded_line=$(printf '%s' "$cron_line" | base64 -w 0)

    print_success "Cron job staged. Entering persistence mode now."
    echo ""
    debug_log "Installing cron entry: $cron_line"

    # Feed commands into chroot-and-upgrade via heredoc.
    # Encoded values are alphanumeric-only — safe in any shell context.
    # The trailing `echo` after each base64 -d adds the required newline.
    local chroot_exit=0
    sudo /usr/lib/startos/scripts/chroot-and-upgrade << EOF || chroot_exit=$?
{ crontab -l 2>/dev/null; printf '%s' "$encoded_comment" | base64 -d; echo; printf '%s' "$encoded_line" | base64 -d; echo; } | crontab -
exit
EOF
    debug_log "chroot-and-upgrade exit: $chroot_exit"

    if [[ $chroot_exit -eq 0 ]]; then
        print_success "Cron job installed persistently."
        print_warn "The server will restart shortly — your SSH session will disconnect."
        print_warn "After reconnecting, verify with: crontab -l"
    else
        print_error "chroot-and-upgrade failed (exit $chroot_exit). Cron job was not installed."
        print_warn "Verify current crontab with: crontab -l"
        pause
    fi
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

    local raw_output
    if ! raw_output=$(sudo du -hd 1 /media/startos/data/package-data/volumes/ 2>&1); then
        print_error "Failed to read disk usage."
        echo -e "${RED}${raw_output}${NC}"
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
        elif [[ "$unit" == "M" ]] && (( $(echo "$num >= 100" | bc -l 2>/dev/null || echo 0) )); then
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

    # Reformat: strip table borders, drop Container ID column, sort by usage % desc, colorize
    echo "$stats_output" | awk -v red="$RED" -v yellow="$YELLOW" -v nc="$NC" -v bold="$BOLD" '
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

        # Collect affected line numbers (including preceding comment tag for delete)
        # For comment/uncomment, only the cron line itself is modified — tag line is untouched.
        local -a affected_linenums=()
        local -a target_linenums=()
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
            local prev_linenum=$(( target_linenum - 1 ))
            local prev_line=""
            [[ $prev_linenum -gt 0 ]] && prev_line=$(echo "$cron_output" | sed -n "${prev_linenum}p")
            if [[ "$action_key" == "d" && "$prev_line" =~ ^# ]]; then
                affected_linenums+=("$prev_linenum")
                echo -e "  ${DIM}${prev_line}${NC}"
            fi
            affected_linenums+=("$target_linenum")
            target_linenums+=("$target_linenum")
            echo -e "  ${CYAN}${target_line}${NC}"
        done
        echo ""

        local confirm_msg
        case "$action_key" in
            d) confirm_msg="Delete the selected cron job(s)?" ;;
            c) confirm_msg="Comment out (disable) the selected cron job(s)?" ;;
            e) confirm_msg="Enable (uncomment) the selected cron job(s)?" ;;
        esac

        if ! confirm "$confirm_msg"; then
            [[ $_BACK -eq 1 ]] && return 1
            print_info "Cancelled."
            sleep 1
            continue
        fi

        local restart_verb
        case "$action_key" in
            d) restart_verb="the cron job(s) are deleted." ;;
            c) restart_verb="the cron job(s) are disabled." ;;
            e) restart_verb="the cron job(s) are enabled." ;;
        esac
        _warn_restart "after ${restart_verb}"

        if ! confirm "Proceed? (server will restart automatically)"; then
            [[ $_BACK -eq 1 ]] && return 1
            print_info "Cancelled."
            sleep 1
            continue
        fi

        # Build sorted comma-separated line number strings for awk
        local affected_lines target_lines
        affected_lines=$(printf '%s\n' "${affected_linenums[@]}" | sort -nu | paste -sd,)
        target_lines=$(printf '%s\n' "${target_linenums[@]}"   | sort -nu | paste -sd,)

        local action_label chroot_exit=0
        case "$action_key" in
            d)
                print_success "Deletion staged. Entering persistence mode now."
                echo ""
                debug_log "cron delete: line numbers=$affected_lines"
                sudo /usr/lib/startos/scripts/chroot-and-upgrade << EOF || chroot_exit=$?
{ crontab -l 2>/dev/null || true; } | awk -v lines="$affected_lines" 'BEGIN{n=split(lines,a,",");for(i=1;i<=n;i++)skip[a[i]]=1} !(NR in skip){print}' | crontab -
exit
EOF
                debug_log "chroot-and-upgrade exit: $chroot_exit"
                action_label="deleted" ;;
            c)
                print_success "Disable staged. Entering persistence mode now."
                echo ""
                debug_log "cron disable: line numbers=$target_lines"
                sudo /usr/lib/startos/scripts/chroot-and-upgrade << EOF || chroot_exit=$?
{ crontab -l 2>/dev/null || true; } | awk -v lines="$target_lines" 'BEGIN{n=split(lines,a,",");for(i=1;i<=n;i++)tog[a[i]]=1} NR in tog{print "#" $0;next} {print}' | crontab -
exit
EOF
                debug_log "chroot-and-upgrade exit: $chroot_exit"
                action_label="disabled" ;;
            e)
                print_success "Enable staged. Entering persistence mode now."
                echo ""
                debug_log "cron enable: line numbers=$target_lines"
                sudo /usr/lib/startos/scripts/chroot-and-upgrade << EOF || chroot_exit=$?
{ crontab -l 2>/dev/null || true; } | awk -v lines="$target_lines" 'BEGIN{n=split(lines,a,",");for(i=1;i<=n;i++)tog[a[i]]=1} NR in tog{sub(/^#/,"");print;next} {print}' | crontab -
exit
EOF
                debug_log "chroot-and-upgrade exit: $chroot_exit"
                action_label="enabled" ;;
        esac

        if [[ $chroot_exit -eq 0 ]]; then
            print_success "Cron job(s) ${action_label}."
            print_warn "The server will restart shortly — your SSH session will disconnect."
        else
            print_error "chroot-and-upgrade failed (exit $chroot_exit). Cron job(s) were not ${action_label}."
            if [[ $_DEBUG -eq 1 ]]; then
                local _c_path="/usr/lib/startos/scripts/chroot-and-upgrade"
                if [[ -x "$_c_path" ]]; then
                    debug_log "chroot-and-upgrade binary found and executable: $_c_path"
                else
                    debug_log "chroot-and-upgrade NOT found or not executable at: $_c_path"
                fi
            else
                print_info "Enable debug mode (main menu → 10) and retry for more detail."
            fi
            pause
        fi
        return
    done
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
    echo -e "  ${DIM}Example: 0 3 * * *   (daily at 3 AM)${NC}"
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
        bash -c "$cron_cmd"
        local run_exit=$?
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
    echo -e "    ${BOLD}1)${NC} Daily at midnight     ${DIM}(0 0 * * *)${NC}"
    echo -e "    ${BOLD}2)${NC} Daily at 3 AM         ${DIM}(0 3 * * *)${NC}"
    echo -e "    ${BOLD}3)${NC} Weekly (Sun midnight) ${DIM}(0 0 * * 0)${NC}"
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
                else
                    return 0
                fi
                ;;
            5) [[ -n "$_pbs_def" ]] && { CRON_SCHEDULE="$_pbs_def"; return 0; } ;;&
            *) print_warn "Enter 1-4${_pbs_def:+, or 5 to keep current}." ;;
        esac
    done
}

# Run the backup setup wizard (steps 1–5, preview). Populates namerefs
# full_line_ref and password_ref. Does NOT install or confirm restart.
# Optional defaults (pass from edit flow): $3=target $4=schedule $5=pkg_ids $6=notif_cmd
#   pkg_ids: empty string = all packages; non-empty = comma-separated IDs.
#   Pass sentinel "__NONE__" for $5 to indicate no package default.
_backup_wizard() {
    local -n _bwfl="$1"
    local -n _bwpw="$2"
    local _bw_def_target="${3:-}"
    local _bw_def_sched="${4:-}"
    local _bw_def_pkg="${5-__NONE__}"   # no-colon: distinguish unset from empty ("")
    local _bw_def_notif="${6:-}"
    _nav_tip

    # ── Step 1: Select backup target ────────────────────────────────────────
    print_header
    print_section "Schedule Backups"
    echo ""
    print_info "Fetching backup targets..."
    local raw_targets
    if ! raw_targets=$(start-cli backup target list 2>&1); then
        print_error "Failed to list backup targets."
        echo -e "${RED}${raw_targets}${NC}"
        pause; return 1
    fi

    mapfile -t targets <<< "$(parse_backup_targets "$raw_targets")"

    if [[ ${#targets[@]} -eq 0 ]]; then
        print_warn "No backup targets found. Add a target in the StartOS UI first."
        pause; return 1
    fi

    echo ""
    echo -e "  ${BOLD}Select backup target:${NC}"
    local i=1
    for tgt in "${targets[@]}"; do
        echo -e "    ${BOLD}${i})${NC} ${tgt}"
        (( i++ ))
    done
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
            backup_target="${targets[$((tgt_choice - 1))]}"
            backup_target=$(echo "$backup_target" | awk '{print $1}')
            break
        fi
        print_warn "Enter a number between 1 and $((i-1))${_bw_def_target:+, or Enter to keep current}."
    done

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
    local backup_cmd="${_START_CLI} backup create ${backup_target} '${backup_password}'"
    [[ -n "$pkg_ids_arg" ]] && backup_cmd+=" --package-ids ${pkg_ids_arg}"
    _bwfl="$CRON_SCHEDULE $backup_cmd"
    [[ -n "$notif_cmd" ]] && _bwfl+=" && $notif_cmd"
    _bwpw="$backup_password"

    # ── Preview ──────────────────────────────────────────────────────────────
    echo ""
    print_section "Review Backup Schedule"
    echo ""
    echo -e "  ${BOLD}Target:${NC}    $backup_target"
    echo -e "  ${BOLD}Packages:${NC}  $packages_display"
    echo -e "  ${BOLD}Schedule:${NC}  $CRON_SCHEDULE"
    [[ -n "$notif_cmd" ]] && echo -e "  ${BOLD}Notify:${NC}    $notif_cmd"
    echo ""
    echo -e "  ${DIM}Cron line:${NC}"
    local preview_line="${_bwfl//${backup_password}/********}"
    echo -e "  ${DIM}${preview_line}${NC}"
    echo ""
}

_backup_install_flow() {
    print_header
    print_section "Schedule Backups"
    echo ""
    local bw_full_line bw_password
    _backup_wizard bw_full_line bw_password || return 1

    if ! confirm "Install this backup schedule?"; then
        [[ $_BACK -eq 1 ]] && return 1
        print_info "Cancelled."
        pause; return
    fi

    install_cron_job "$bw_full_line" "Schedule Backups" || return 1
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
        e_target=$(echo "${old_cron_lines[$ei]}" | grep -oE "backup create [^ ]+" | awk '{print $3}')
        echo -e "  ${BOLD}$((ei+1)))${NC} ${e_sched}  →  ${e_target:-unknown}"
        echo -e "     ${DIM}${old_comments[$ei]}${NC}"
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
    def_target=$(echo "$old_cron_line" | grep -oE "backup create [^ ]+" | awk '{print $3}')
    def_sched=$(echo "$old_cron_line" | awk '{print $1,$2,$3,$4,$5}')
    # If --package-ids present, extract value; otherwise empty string = all packages
    def_pkg=$(echo "$old_cron_line" | grep -oE "\-\-package-ids [^ ]+" | awk '{print $2}')
    # Extract post-action command (everything after first ' && ')
    if echo "$old_cron_line" | grep -qF ' && '; then
        def_notif=$(echo "$old_cron_line" | awk -F' && ' '{for(i=2;i<=NF;i++) printf "%s%s",$i,(i<NF?" && ":""); print ""}')
    fi

    # ── Run wizard for replacement ───────────────────────────────────────────
    print_header
    print_section "Edit Backup Schedule"
    echo ""
    local bw_full_line bw_password
    _backup_wizard bw_full_line bw_password "$def_target" "$def_sched" "$def_pkg" "$def_notif" || return 1

    if ! confirm "Replace existing schedule with this?"; then
        [[ $_BACK -eq 1 ]] && return 1
        print_info "Cancelled."
        pause; return
    fi

    local install_ts
    install_ts=$(date '+%Y.%m.%d %H:%M:%S %Z')
    local new_comment="# startos-admin v${VERSION} | Added: ${install_ts} | Action: Schedule Backups"
    local enc_old_c enc_old_l enc_new_c enc_new_l
    enc_old_c=$(printf '%s' "$old_comment"   | base64 -w 0)
    enc_old_l=$(printf '%s' "$old_cron_line" | base64 -w 0)
    enc_new_c=$(printf '%s' "$new_comment"   | base64 -w 0)
    enc_new_l=$(printf '%s' "$bw_full_line"  | base64 -w 0)

    _warn_restart "after the backup schedule is updated."
    if ! confirm "Proceed? (server will restart automatically)"; then
        [[ $_BACK -eq 1 ]] && return 1
        print_info "Cancelled."
        return
    fi

    print_success "Replacement staged. Entering persistence mode now."
    echo ""
    debug_log "Replacing backup schedule. Old comment: $old_comment"
    local chroot_exit=0
    sudo /usr/lib/startos/scripts/chroot-and-upgrade << EOF || chroot_exit=$?
old_c=\$(printf '%s' "$enc_old_c" | base64 -d)
old_l=\$(printf '%s' "$enc_old_l" | base64 -d)
{ crontab -l 2>/dev/null | grep -vxF "\$old_c" | grep -vxF "\$old_l"; printf '%s' "$enc_new_c" | base64 -d; echo; printf '%s' "$enc_new_l" | base64 -d; echo; } | crontab -
exit
EOF

    if [[ $chroot_exit -eq 0 ]]; then
        print_success "Backup schedule updated persistently."
        print_warn "The server will restart shortly — your SSH session will disconnect."
        print_warn "After reconnecting, verify with: crontab -l"
    else
        print_error "chroot-and-upgrade failed (exit $chroot_exit). Schedule may not have been updated."
        pause
    fi
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

    echo ""
    _read _title "  Notification title: " || return 1
    _read _body "  Notification message: " || return 1
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
                echo -e "  ${DIM}Enter the full command to run. Example:${NC}"
                echo -e "  ${DIM}curl -d \"Backup started\" https://ntfy.sh/Your-Topic${NC}"
                echo -e "  ${DIM}Hint: no need for >/dev/null; avoid bare & (use && to chain commands).${NC}"
                _read _ppa_cmd "  Shell command: " || return 1
                [[ -z "$_ppa_cmd" ]] && { print_warn "Command cannot be empty."; continue; }
                echo ""
                _read _ppa_test "  Test this command now? [y/N]: " || return 1
                if [[ "${_ppa_test,,}" == "y" ]]; then
                    echo ""
                    print_info "Running: $_ppa_cmd"
                    local _ppa_test_exit=0
                    bash -c "$_ppa_cmd"; _ppa_test_exit=$?
                    echo ""
                    if [[ $_ppa_test_exit -eq 0 ]]; then
                        print_success "Command exited 0 (success)."
                    else
                        print_warn "Command exited $_ppa_test_exit. Check the output above before continuing."
                    fi
                fi
                _ppa_mode="1"; break ;;
            2)
                _pick_notif_startos _ppa_svc _ppa_level _ppa_title _ppa_body || return 1
                _ppa_mode="2"; break ;;
            3)
                echo -e "  ${DIM}Enter the full command to run. Example:${NC}"
                echo -e "  ${DIM}curl -d \"Backup started\" https://ntfy.sh/Your-Topic${NC}"
                echo -e "  ${DIM}Hint: no need for >/dev/null; avoid bare & (use && to chain commands).${NC}"
                _read _ppa_cmd "  Shell command: " || return 1
                [[ -z "$_ppa_cmd" ]] && { print_warn "Command cannot be empty."; continue; }
                echo ""
                _read _ppa_test "  Test this command now? [y/N]: " || return 1
                if [[ "${_ppa_test,,}" == "y" ]]; then
                    echo ""
                    print_info "Running: $_ppa_cmd"
                    local _ppa_test_exit=0
                    bash -c "$_ppa_cmd"; _ppa_test_exit=$?
                    echo ""
                    if [[ $_ppa_test_exit -eq 0 ]]; then
                        print_success "Command exited 0 (success)."
                    else
                        print_warn "Command exited $_ppa_test_exit. Check the output above before continuing."
                    fi
                fi
                _pick_notif_startos _ppa_svc _ppa_level _ppa_title _ppa_body || return 1
                _ppa_mode="3"; break ;;
            4) _ppa_mode="4"; break ;;
            *) print_warn "Enter 1, 2, 3, or 4${_ppa_def_cmd:+, or 5 to keep current}." ;;
        esac
    done

    local _ppa_pkg_flag=""
    [[ -n "$_ppa_svc" && "$_ppa_svc" != "blank" ]] && _ppa_pkg_flag="--package ${_ppa_svc} "
    case "$_ppa_mode" in
        1) _ppa_notif_cmd="${_ppa_cmd}" ;;
        2) _ppa_notif_cmd="${_START_CLI} notification create ${_ppa_pkg_flag}${_ppa_level} \"${_ppa_title}\" \"${_ppa_body}\"" ;;
        3) _ppa_notif_cmd="${_ppa_cmd} && ${_START_CLI} notification create ${_ppa_pkg_flag}${_ppa_level} \"${_ppa_title}\" \"${_ppa_body}\"" ;;
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
    _read stay_url "  URL to curl: " || return 1
    if [[ -z "$stay_url" ]]; then
        print_error "URL cannot be empty."
        pause; return
    fi

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
                [[ -n "$CRON_SCHEDULE" ]] && return 0
                print_warn "Expression cannot be empty."
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
        [[ -n "$webhook_url" ]] && break
        print_warn "URL cannot be empty."
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
    _read keyword "  Keyword filter — forward only if title/message contains (blank = none): " || return 1

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
    _read _tw_yn "  Test this webhook now? [y/N]: "
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

    local choice
    while true; do
        _read choice "  Choice [1-$((i-1))]: " || return 1
        [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )) && break
        print_warn "Enter a number between 1 and $((i-1))."
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
    _read webhook_url "  New URL [Enter to keep]: " || return 1
    webhook_url="${webhook_url:-$cur_url}"
    [[ -z "$webhook_url" ]] && { print_warn "URL cannot be empty."; pause; return; }

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
            _read keyword "  New keyword [Enter to keep '${cur_keyword}']: " || return 1
            keyword="${keyword:-$cur_keyword}"
        fi
    else
        _read keyword "  Keyword filter — forward only if title/message contains (blank = none): " || return 1
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
    _read _tw_yn "  Test this webhook now? [y/N]: "
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
# Re-run startos-admin.sh option 7 to update this configuration.
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

    if [ -n "$KEYWORD" ] && ! echo "$title $msg" | grep -qi "$KEYWORD"; then
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

    _warn_restart "after the forwarder is installed."

    if ! confirm "Proceed? (server will restart automatically)"; then
        [[ $_BACK -eq 1 ]] && return 1
        print_info "Cancelled."
        return 1
    fi

    print_success "Forwarder staged. Entering persistence mode now."
    echo ""
    debug_log "Installing poller '$name' → ${_POLLER_BIN_PREFIX}${name}"

    # Remove any existing entry for this poller name, then write the new script
    # and add the tagged comment + cron line. All in one chroot session.
    # mkdir -p here creates the data dir in the persistent root-fs overlay so that
    # cron jobs writing state/log files there survive across reboots.
    # \$0 in the heredoc → $0 for awk (the outer bash escapes \$ → $).
    local chroot_exit=0
    sudo /usr/lib/startos/scripts/chroot-and-upgrade << EOF || chroot_exit=$?
mkdir -p ${_STARTOS_DATA_DIR}
{ crontab -l 2>/dev/null || true; } | awk -v t1="| Poller: ${name} |" -v t2="# startos-notif-poller-${name}" 'index(\$0,t1)||index(\$0,t2)==1{skip=1;next} skip{skip=0;next} {print}' | crontab -
printf '%s' "$encoded_script" | base64 -d > ${_POLLER_BIN_PREFIX}${name}
chmod +x ${_POLLER_BIN_PREFIX}${name}
{ crontab -l 2>/dev/null; printf '%s' "$encoded_comment" | base64 -d; echo; printf '%s' "$encoded_cron" | base64 -d; echo; } | crontab -
exit
EOF
    debug_log "chroot-and-upgrade exit: $chroot_exit"

    if [[ $chroot_exit -eq 0 ]]; then
        print_success "Forwarder '${name}' installed persistently."
        print_warn "The server will restart shortly — your SSH session will disconnect."
        print_warn "After reconnecting, test with: ${_POLLER_BIN_PREFIX}${name}"
    else
        print_error "chroot-and-upgrade failed (exit $chroot_exit). Forwarder was not installed."
        pause
    fi
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

    _warn_restart "after the forwarder(s) are removed."

    if ! confirm "Proceed? (server will restart automatically)"; then
        [[ $_BACK -eq 1 ]] && return 1
        print_info "Cancelled."
        return 1
    fi

    # Remove state files AFTER 2nd confirm — root-owned, not accessible inside chroot
    for rname in "${names_to_remove[@]}"; do
        local state_file="${_POLLER_STATE_PREFIX}${rname}"
        if [[ -f "$state_file" ]]; then
            print_info "Removing state file: $state_file"
            sudo rm -f "$state_file"
        fi
    done

    # Build chroot commands with names already substituted (avoids $0 escaping in heredoc)
    local chroot_body=""
    for rname in "${names_to_remove[@]}"; do
        chroot_body+="crontab -l 2>/dev/null | grep -v 'startos-notif-poller-${rname}' | grep -Fv '| Poller: ${rname} |' | crontab -
rm -f ${_POLLER_BIN_PREFIX}${rname}
"
    done

    print_success "Removal staged. Entering persistence mode now."
    echo ""

    local chroot_exit=0
    sudo /usr/lib/startos/scripts/chroot-and-upgrade << EOF || chroot_exit=$?
${chroot_body}exit
EOF

    if [[ $chroot_exit -eq 0 ]]; then
        print_success "Removed: ${names_display}"
        print_warn "The server will restart shortly — your SSH session will disconnect."
    else
        print_error "chroot-and-upgrade failed (exit $chroot_exit). Forwarder(s) may not have been fully removed."
        pause
    fi
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

    local log_choice
    while true; do
        _read log_choice "  Choice [1-$((i-1))]: " || return 1
        if [[ "$log_choice" =~ ^[0-9]+$ ]] && \
           [[ "$log_choice" -ge 1 ]] && [[ "$log_choice" -lt "$i" ]]; then
            break
        fi
        print_warn "Enter a number between 1 and $((i-1))."
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

    local choice
    while true; do
        _read choice "  Choice [1-$((i-1))]: " || return 1
        [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )) && break
        print_warn "Enter a number between 1 and $((i-1))."
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
                    print_success "State file deleted. Next run will forward only the most recent notification."
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
# System Database Viewer
# ─────────────────────────────────────────────

# Display hostname, OS version, architecture, and last backup timestamp from DB.
_db_server_info() {
    local db="$1"
    print_header
    print_section "Server Info"
    echo ""

    local hostname version arch platform last_backup
    hostname=$(echo "$db"    | jq -r '.value.serverInfo.hostname    // "unknown"')
    version=$(echo "$db"     | jq -r '.value.serverInfo.version     // "unknown"')
    arch=$(echo "$db"        | jq -r '.value.serverInfo.arch        // "unknown"')
    platform=$(echo "$db"    | jq -r '.value.serverInfo.platform    // "unknown"')
    last_backup=$(echo "$db" | jq -r '.value.serverInfo.lastBackup  // "never"')

    if [[ "$last_backup" != "never" ]]; then
        last_backup=$(date -d "$last_backup" '+%Y.%m.%d %H:%M:%S %Z' 2>/dev/null || echo "$last_backup")
    fi

    echo -e "  ${BOLD}Hostname:${NC}      $hostname"
    echo -e "  ${BOLD}StartOS:${NC}       $version"
    echo -e "  ${BOLD}Architecture:${NC}  $arch"
    echo -e "  ${BOLD}Platform:${NC}      $platform"
    echo -e "  ${BOLD}Last Backup:${NC}   $last_backup"
    echo ""
    pause
}

# Display Tor addresses, LAN/gateway IPs, WiFi, and DNS servers from DB.
_db_network() {
    local db="$1"
    print_header
    print_section "Network"
    echo ""

    # ── Addresses (mirrors the GUI Addresses table) ──────────────────────────
    print_section "Addresses"
    echo ""
    echo "$db" | jq -r '
        [.value.serverInfo.network.hostnameInfo // {} | to_entries[] | .value[] |
            {
                type:    (.hostname.kind // "unknown"),
                access:  (if .public then "public" else "private" end),
                gateway: (.gateway.name // "unknown"),
                url:     ("https://" + .hostname.value)
            }
        ] | unique_by(.url) | .[] |
        "\(.type)\t\(.access)\t\(.gateway)\t\(.url)"
    ' 2>/dev/null | while IFS=$'\t' read -r type access gateway url; do
        printf "  %-10s  %-8s  %-24s  %s\n" "$type" "$access" "$gateway" "$url"
    done
    echo ""

    # ── Tor Addresses ────────────────────────────────────────────────────────
    local onions
    onions=$(echo "$db" | jq -r '.value.serverInfo.network.onions[]? // empty' 2>/dev/null)
    if [[ -n "$onions" ]]; then
        print_section "Tor Addresses"
        echo ""
        while IFS= read -r onion; do
            echo -e "  ${CYAN}•${NC} $onion"
        done <<< "$onions"
        echo ""
    fi

    # ── WiFi ─────────────────────────────────────────────────────────────────
    print_section "WiFi"
    echo ""
    local wifi_enabled wifi_ssid
    wifi_enabled=$(echo "$db" | jq -r '.value.serverInfo.network.wifi.enabled  // "unknown"')
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
    dns_strategy=$(echo "$db" | jq -r '
        if (.value.serverInfo.dns.staticServers | (. != null and length > 0)) then "Static"
        else "DHCP" end
    ' 2>/dev/null)
    echo -e "  ${BOLD}Strategy:${NC}  $dns_strategy"
    echo ""
    echo "$db" | jq -r '
        [(.value.serverInfo.dns.staticServers // [])[], (.value.serverInfo.dns.dhcpServers // [])[]] |
        unique[]
    ' 2>/dev/null | while read -r dns; do
        echo -e "  ${CYAN}•${NC} $dns"
    done
    echo ""

    pause
}

# List all installed services with running state and health-check status from DB.
_db_svc_status() {
    local db="$1"
    print_header
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

    pause
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

    local pkg="${svc_list[$((svc_choice - 1))]}"

    print_header
    print_section "Service: $pkg"
    echo ""

    local desired started last_bk registry
    desired=$(echo "$db"  | jq -r ".value.packageData[\"$pkg\"].statusInfo.desired | to_entries[0].value // \"unknown\"")
    started=$(echo "$db"  | jq -r ".value.packageData[\"$pkg\"].statusInfo.started // \"unknown\"")
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
    output=$(echo "$db" | jq -r --argjson svcs "$jq_filter" '
      .value.packageData | to_entries[] |
      select(.key as $k | $svcs | index($k)) |
      .key as $svc |
      .value as $pkg |
      $pkg.serviceInterfaces | to_entries[] |
      .value as $iface |
      $iface.addressInfo.hostId as $hostId |
      $iface.addressInfo.suffix as $suffix |
      $iface.addressInfo.scheme as $scheme |
      $iface.addressInfo.sslScheme as $sslScheme |
      # Walk bindings → addresses.available for the matched host
      ($pkg.hosts[$hostId].bindings // {} | to_entries[].value.addresses.available[]?) as $a |
      # Filter: skip loopback, internal bridge, link-local IPv6
      select($a.metadata.gateway | . != "lo" and . != "lxcbr0") |
      select(($a.metadata.kind == "ipv6" and ($a.hostname | startswith("fe80::"))) | not) |
      # Wrap IPv6 in brackets
      (if $a.metadata.kind == "ipv6" then "[" + $a.hostname + "]"
       else $a.hostname end) as $host |
      # Strip query params from suffix (hides embedded certs/macaroons)
      ($suffix | split("?")[0]) as $safeSuffix |
      # Build URL using ssl flag and interface scheme
      (
        if ($a.ssl and $sslScheme != null) then
          $sslScheme + "://" + $host + ":" + ($a.port|tostring) + $safeSuffix
        elif ($a.ssl | not) and ($scheme != null) then
          $scheme + "://" + $host + ":" + ($a.port|tostring) + $safeSuffix
        elif $a.ssl then
          "ssl://" + $host + ":" + ($a.port|tostring) + $safeSuffix
        else
          "tcp://" + $host + ":" + ($a.port|tostring) + $safeSuffix
        end
      ) as $url |
      # Network label
      (if $a.metadata.gateway == "wg1" then "tunnel"
       elif $a.metadata.gateway == null then "local"
       else $a.metadata.gateway
       end) as $net |
      "\($svc)\t\($iface.name)\t\($iface.type)\t\($net)\t\($url)"
    ' 2>/dev/null)

    if [[ -z "$output" ]]; then
        print_info "No interfaces found for selected services."
    else
        local prev_svc=""
        while IFS=$'\t' read -r svc iname itype net url; do
            if [[ "$svc" != "$prev_svc" ]]; then
                [[ -n "$prev_svc" ]] && echo ""
                echo -e "  ${BOLD}${svc}${NC}"
                prev_svc="$svc"
            fi
            local type_color="$GREEN"
            [[ "$itype" == "api" ]] && type_color="$YELLOW"
            [[ "$itype" == "p2p" ]] && type_color="$BLUE"
            printf "    ${type_color}%-4s${NC}  %-20s  %-24s  %s\n" "$itype" "$iname" "$net" "$url"
        done <<< "$output"
    fi
    echo ""

    pause
}

menu_db_dump() {
    print_header
    print_section "System Database"
    echo ""
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
        print_section "System Database"
        echo ""
        echo -e "    ${CYAN}${BOLD}1)${NC} Server Info"
        echo -e "    ${CYAN}${BOLD}2)${NC} Network"
        echo -e "    ${CYAN}${BOLD}3)${NC} Service Status"
        echo -e "    ${CYAN}${BOLD}4)${NC} Service Detail"
        echo -e "    ${CYAN}${BOLD}5)${NC} Service Interfaces"
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
            0) return ;;
            *) print_warn "Enter 0-5." ; sleep 1 ;;
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
        echo -e "    ${CYAN}${BOLD}1)${NC} Create a StartOS notification"
        echo -e "    ${CYAN}${BOLD}2)${NC} Display disk used by services"
        echo -e "    ${CYAN}${BOLD}3)${NC} Display memory used by services"
        echo -e "    ${CYAN}${BOLD}4)${NC} Manage cron jobs"
        echo -e "    ${CYAN}${BOLD}5)${NC} Schedule backups"
        echo -e "    ${CYAN}${BOLD}6)${NC} Schedule stay-alive curl"
        echo -e "    ${CYAN}${BOLD}7)${NC} Manage notification forwarders"
        echo -e "    ${CYAN}${BOLD}8)${NC} System Database"
        echo -e "    ${CYAN}${BOLD}9)${NC} Troubleshooting"
        echo -e "    ${CYAN}${BOLD}10)${NC} Backup / Restore configuration"
        echo ""
        echo -e "    ${DIM}0) Back${NC}"
        echo ""
        _read doc_choice "  $(echo -e "${BOLD}Choice:${NC} ")" || return 1
        case "$doc_choice" in
            1)
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
            2)
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
            4)
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
                echo -e "      created the target in the StartOS UI and manually tested it first."
                echo ""
                echo -e "    ${CYAN}•${NC} ${BOLD}Services to back up${NC} — select specific services or all of them."
                echo ""
                echo -e "    ${CYAN}•${NC} ${BOLD}Schedule${NC} — how frequently and at what time backups run, using cron"
                echo -e "      syntax. Use ${CYAN}https://crontab.guru/${NC} to verify your expression."
                echo ""
                echo -e "    ${CYAN}•${NC} ${BOLD}Post-backup action${NC} — optionally run a shell command and/or create a"
                echo -e "      StartOS notification. Enter the full command, e.g.:"
                echo -e "      ${DIM}curl -d \"Backup started\" https://ntfy.sh/Your-Topic${NC}"
                echo -e "      Since StartOS already notifies you when a backup completes, combining"
                echo -e "      a kickoff notification with the completion one gives you elapsed time."
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
            7)
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
                echo -e "  On the first poll after install, the forwarder forwards only the"
                echo -e "  single most recent notification at that moment. All older notifications"
                echo -e "  are skipped to prevent a historical flood. Subsequent runs forward"
                echo -e "  only notifications newer than the last one seen."
                echo ""
                echo -e "  ${BOLD}Files created per forwarder:${NC}"
                echo ""
                echo -e "    ${DIM}Script:  /usr/local/bin/startos-notif-poller-<name>${NC}"
                echo -e "    ${DIM}State:   /media/startos/data/startos-admin/startos-admin-poller-state-<name>${NC}"
                echo -e "    ${DIM}Log:     /media/startos/data/startos-admin/startos-notif-poller-<name>.log${NC}"
                echo ""
                pause ;;
            8)
                print_header
                print_section "System Database"
                echo ""
                echo -e "  This fetches a full dump of the StartOS system database and lets you"
                echo -e "  browse it by category."
                echo ""
                echo -e "  ${BOLD}Available views:${NC}"
                echo ""
                echo -e "    ${CYAN}•${NC} ${BOLD}Server Info${NC}    — hostname, OS version, architecture, last backup"
                echo -e "    ${CYAN}•${NC} ${BOLD}Network${NC}        — Tor addresses, WiFi, gateway IPs, DNS servers"
                echo -e "    ${CYAN}•${NC} ${BOLD}Service Status${NC} — all services with running/stopped state and health checks"
                echo -e "    ${CYAN}•${NC} ${BOLD}Service Detail${NC} — full detail for a single service"
                echo ""
                pause ;;
            9)
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
                echo -e "  and confirm ${CYAN}start-cli auth status${NC} reports authenticated."
                echo ""
                echo -e "  ${BOLD}Changes lost after reboot${NC}"
                echo -e "  StartOS does not persist changes by default. All changes made by"
                echo -e "  this tool go through ${CYAN}chroot-and-upgrade${NC}, which triggers a server"
                echo -e "  restart and makes the change permanent. If a change was not made"
                echo -e "  via this tool, it will be lost on next reboot."
                echo ""
                pause ;;
            10)
                print_header
                print_section "Backup / Restore Configuration"
                echo ""
                echo -e "  Exports your installed cron jobs and notification forwarders as a"
                echo -e "  single AES-256 encrypted backup file, and can restore them after"
                echo -e "  an OS upgrade or reflash."
                echo ""
                echo -e "  ${BOLD}Export${NC} saves:"
                echo ""
                echo -e "    ${CYAN}•${NC} All root cron entries"
                echo -e "    ${CYAN}•${NC} All notification forwarder scripts  ${DIM}(including embedded webhook URLs)${NC}"
                echo ""
                echo -e "  ${BOLD}Restore${NC} reinstalls everything in a single reboot — including the"
                echo -e "  ${CYAN}startos-admin${NC} script itself at ${DIM}/usr/local/bin/startos-admin${NC}."
                echo ""
                echo -e "  The backup file is encrypted with AES-256-CBC using a passphrase you"
                echo -e "  provide. ${YELLOW}The passphrase cannot be recovered.${NC} A forgotten passphrase"
                echo -e "  makes the backup permanently unreadable."
                echo ""
                echo -e "  The encrypted file is saved to ${DIM}${_CONFIG_BACKUP_FILE}${NC}."
                echo -e "  An ${CYAN}scp${NC} command is shown after export to transfer it off the server."
                echo -e "  The same command (reversed) is shown at the start of the restore flow."
                echo ""
                pause ;;
            0) return ;;
            *) print_warn "Enter 0-10." ; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Configuration Backup / Restore
# ─────────────────────────────────────────────

_config_export_flow() {
    print_header
    print_section "Export Configuration Backup"
    echo ""
    _nav_tip

    # ── Preflight ─────────────────────────────────────────────────────────────
    if ! command -v openssl &>/dev/null; then
        print_error "openssl not found. Cannot create encrypted backup."
        pause; return
    fi

    local crontab_out
    crontab_out=$(sudo crontab -u root -l 2>/dev/null || true)
    local poller_scripts=("${_POLLER_BIN_PREFIX}"*)
    local has_pollers=0
    [[ -e "${poller_scripts[0]}" ]] && has_pollers=1

    if [[ -z "$crontab_out" && $has_pollers -eq 0 ]]; then
        print_warn "Nothing to back up: no cron jobs and no forwarders are installed."
        pause; return
    fi

    # ── Encryption warning ────────────────────────────────────────────────────
    echo ""
    echo -e "  ${RED}${BOLD}┌─────────────────────────────────────────────────┐${NC}"
    echo -e "  ${RED}${BOLD}│  WARNING: ENCRYPTION PASSPHRASE CANNOT          │${NC}"
    echo -e "  ${RED}${BOLD}│  BE RECOVERED.                                  │${NC}"
    echo -e "  ${RED}${BOLD}│                                                 │${NC}"
    echo -e "  ${RED}${BOLD}│  If you forget the passphrase, this backup      │${NC}"
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

    # ── Encrypt to file ───────────────────────────────────────────────────────
    local pass_file
    pass_file=$(mktemp)
    chmod 600 "$pass_file"
    printf '%s\n' "$passphrase" > "$pass_file"
    unset passphrase

    local enc_exit=0
    printf '%s' "$bundle" \
        | openssl enc -aes-256-cbc -pbkdf2 -salt -a \
            -pass "file:${pass_file}" > "$_CONFIG_BACKUP_FILE" \
        || enc_exit=$?
    rm -f "$pass_file"

    if [[ $enc_exit -ne 0 ]]; then
        rm -f "$_CONFIG_BACKUP_FILE"
        print_error "Encryption failed (openssl exit ${enc_exit}). Backup not written."
        pause; return
    fi

    # ── Display results ───────────────────────────────────────────────────────
    local cron_count=0
    [[ -n "$crontab_out" ]] && \
        cron_count=$(echo "$crontab_out" | grep -c '^# startos-admin v' 2>/dev/null || true)

    ${_START_CLI} notification create info "StartOS Admin" "StartOS Admin Configuration Backed Up" 2>/dev/null || true

    echo ""
    print_success "Backup written to: ${_CONFIG_BACKUP_FILE}"
    echo ""
    print_section "Backup Summary"
    echo ""
    echo -e "  ${BOLD}Cron entries:${NC} ${cron_count} startos-admin managed entries"
    echo -e "  ${BOLD}Forwarders:${NC}   ${pcount}"
    echo ""
    print_section "Encrypted backup file contents"
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
    print_section "Restore Configuration Backup"
    echo ""
    _nav_tip

    # ── scp instructions ──────────────────────────────────────────────────────
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')
    print_section "Copy the backup file to this server first"
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
    _read backup_path "  Path to backup file [${_CONFIG_BACKUP_FILE}]: " || return 1
    [[ -z "$backup_path" ]] && backup_path="$_CONFIG_BACKUP_FILE"

    if [[ ! -f "$backup_path" ]]; then
        print_error "File not found: ${backup_path}"
        pause; return
    fi

    # ── Preflight ─────────────────────────────────────────────────────────────
    if ! command -v openssl &>/dev/null; then
        print_error "openssl not found. Cannot decrypt backup."
        pause; return
    fi

    # ── Collect passphrase and decrypt ────────────────────────────────────────
    echo ""
    local passphrase
    _read_silent passphrase "  Enter backup passphrase: " || return 1

    local pass_file
    pass_file=$(mktemp)
    chmod 600 "$pass_file"
    printf '%s\n' "$passphrase" > "$pass_file"
    unset passphrase

    local bundle dec_exit=0
    bundle=$(openssl enc -d -aes-256-cbc -pbkdf2 -a \
        -pass "file:${pass_file}" -in "$backup_path") || dec_exit=$?
    rm -f "$pass_file"

    if [[ $dec_exit -ne 0 || -z "$bundle" ]]; then
        print_error "Decryption failed. Wrong passphrase or corrupt file."
        pause; return
    fi

    # ── Validate and parse bundle ─────────────────────────────────────────────
    local header
    header=$(printf '%s' "$bundle" | head -1)
    if [[ "$header" != "STARTOS_ADMIN_BACKUP_V1" ]]; then
        print_error "Unrecognized backup format. Cannot restore."
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

    # ── Show restore summary ──────────────────────────────────────────────────
    print_header
    print_section "Restore Summary"
    echo ""
    echo -e "  ${BOLD}Backup date:${NC}  ${backup_date}"
    echo ""

    local cron_count=0
    [[ -n "$crontab_b64" ]] && \
        cron_count=$(printf '%s' "$crontab_b64" | base64 -d 2>/dev/null \
            | grep -c '^# startos-admin v' || true)
    echo -e "  ${BOLD}Cron entries:${NC} ${cron_count} startos-admin managed entries"

    echo -e "  ${BOLD}Forwarders:${NC}   ${pcount}"
    for pi in "${!pnames[@]}"; do
        echo -e "    ${DIM}• ${pnames[$pi]}${NC}"
    done
    echo ""
    print_warn "Your current crontab will be REPLACED with the backed-up version."
    [[ $pcount -gt 0 ]] && \
        print_warn "Forwarder scripts with matching names will be overwritten."
    print_info "The latest startos-admin script will also be downloaded and installed persistently."
    echo ""

    # ── Confirmations ─────────────────────────────────────────────────────────
    if ! confirm "Restore this configuration?"; then
        [[ $_BACK -eq 1 ]] && return 1
        print_info "Cancelled."
        pause; return
    fi

    _warn_restart "after the configuration is restored."
    if ! confirm "Proceed? (server will restart automatically)"; then
        [[ $_BACK -eq 1 ]] && return 1
        print_info "Cancelled."
        return
    fi

    ${_START_CLI} notification create info "StartOS Admin" "StartOS Admin Configuration Restored" 2>/dev/null || true

    # ── Build and run chroot session ──────────────────────────────────────────
    local chroot_body
    chroot_body="mkdir -p ${_STARTOS_DATA_DIR}
curl -fsSL https://raw.githubusercontent.com/JesseMarkowitz/admintools-startos/refs/heads/main/startos-admin.sh -o /usr/local/bin/startos-admin
chmod +x /usr/local/bin/startos-admin
"
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

    print_success "Restore staged. Entering persistence mode now."
    echo ""
    debug_log "Restoring: crontab=${cron_count} entries, pollers=${pcount}"

    local chroot_exit=0
    sudo /usr/lib/startos/scripts/chroot-and-upgrade << EOF || chroot_exit=$?
${chroot_body}exit
EOF

    if [[ $chroot_exit -eq 0 ]]; then
        print_success "Configuration restored."
        print_warn "The server will restart shortly — your SSH session will disconnect."
        print_warn "After reconnecting, run: startos-admin"
    else
        print_error "chroot-and-upgrade failed (exit ${chroot_exit}). Configuration may not have been fully restored."
        pause
    fi
}

menu_config_backup_restore() {
    while true; do
        print_header
        print_section "Backup / Restore Configuration"
        echo ""
        echo -e "    ${CYAN}${BOLD}1)${NC} Export (save configuration backup)"
        echo -e "    ${CYAN}${BOLD}2)${NC} Restore (load configuration backup)"
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
#   Phase 2 — Version check: fetch the remote script from GitHub, extract
#     its VERSION, and offer an upgrade if the remote version is newer.
#     Runs only when already installed persistently.
# Both phases are silent on network failure (curl || return 0).

check_for_update() {
    local raw_url="https://raw.githubusercontent.com/JesseMarkowitz/admintools-startos/refs/heads/main/startos-admin.sh"
    local remote_version remote_script

    # ── First-run: not yet installed persistently ────────────────────────────
    local _script_path
    _script_path=$(realpath "$0" 2>/dev/null || echo "$0")
    if [[ "$_script_path" != "/usr/local/bin/startos-admin" ]]; then
        echo ""
        print_info "This script is not yet installed persistently."
        print_info "Installing to /usr/local/bin/startos-admin lets you run 'startos-admin' from anywhere."
        print_info "Tip: If you plan to restore a saved configuration right now, decline this —"
        print_info "     the Restore option installs the script persistently as part of the same reboot."
        echo ""
        if confirm "Install persistently to /usr/local/bin/startos-admin now?"; then
            _warn_restart "after the script is installed."
            if ! confirm "Proceed? (server will restart automatically)"; then
                [[ $_BACK -eq 1 ]] && { _BACK=0; }
                return 0
            fi
            echo ""
            local _encoded
            _encoded=$(base64 -w 0 < "$_script_path")
            local chroot_exit=0
            sudo /usr/lib/startos/scripts/chroot-and-upgrade << EOF || chroot_exit=$?
printf '%s' "$_encoded" | base64 -d > /usr/local/bin/startos-admin
chmod +x /usr/local/bin/startos-admin
exit
EOF
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
    # Fetch with short timeout — fail silently if offline or unreachable
    debug_log "Fetching remote version from: $raw_url"
    remote_script=$(curl -fsSL --max-time 5 "$raw_url" 2>/dev/null) || {
        debug_log "Remote fetch failed or timed out — skipping update check"
        return 0
    }

    remote_version=$(echo "$remote_script" | grep '^VERSION=' | head -1 | tr -d '"' | cut -d= -f2 | awk '{print $1}')
    [[ -z "$remote_version" ]] && return 0
    debug_log "Remote version: $remote_version  Local: $VERSION"

    # Compare as integers; skip if already current
    if [[ "$remote_version" -le "$VERSION" ]] 2>/dev/null; then
        return 0
    fi

    echo ""
    print_info "A newer version is available: v${remote_version}  (you have v${VERSION})"
    echo ""
    if ! confirm "Download and install v${remote_version} persistently to /usr/local/bin/startos-admin?"; then
        [[ $_BACK -eq 1 ]] && { _BACK=0; return 0; }
        return 0
    fi

    _warn_restart "after the update is installed."
    if ! confirm "Proceed? (server will restart automatically)"; then
        [[ $_BACK -eq 1 ]] && { _BACK=0; return 0; }
        return 0
    fi
    echo ""

    local encoded
    encoded=$(printf '%s' "$remote_script" | base64 -w 0)

    local chroot_exit=0
    sudo /usr/lib/startos/scripts/chroot-and-upgrade << EOF || chroot_exit=$?
printf '%s' "$encoded" | base64 -d > /usr/local/bin/startos-admin
chmod +x /usr/local/bin/startos-admin
exit
EOF

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
    while true; do
        print_header
        _nav_tip
        # Counts and labels for display
        local _cron_n _fwd_arr _fwd_n _dbg_label
        _cron_n=$(sudo crontab -u root -l 2>/dev/null | grep -c '^# startos-admin v' || true)
        _fwd_arr=("${_POLLER_BIN_PREFIX}"*)
        [[ -e "${_fwd_arr[0]}" ]] && _fwd_n=${#_fwd_arr[@]} || _fwd_n=0
        [[ $_DEBUG -eq 1 ]] && _dbg_label="${GREEN}ON${NC}" || _dbg_label="${DIM}OFF${NC}"

        echo -e "  ${BOLD}Select an action:${NC}"
        echo ""
        echo -e "    ${CYAN}${BOLD}1)${NC} Documentation"
        echo -e "    ${CYAN}${BOLD}2)${NC} Create a StartOS notification"
        echo -e "    ${CYAN}${BOLD}3)${NC} Display disk used by services"
        echo -e "    ${CYAN}${BOLD}4)${NC} Display memory used by services"
        echo -e "    ${CYAN}${BOLD}5)${NC} Manage cron jobs  ${DIM}(${_cron_n})${NC}"
        echo -e "    ${CYAN}${BOLD}6)${NC} Schedule backups"
        echo -e "    ${CYAN}${BOLD}7)${NC} Schedule stay-alive curl"
        echo -e "    ${CYAN}${BOLD}8)${NC} Manage notification forwarders  ${DIM}(${_fwd_n})${NC}"
        echo -e "    ${CYAN}${BOLD}9)${NC} System Database"
        echo -e "    ${CYAN}${BOLD}10)${NC} Backup / Restore configuration"
        echo -e "    ${CYAN}${BOLD}11)${NC} Debug mode  ${DIM}(${NC}${_dbg_label}${DIM})${NC}"
        echo ""
        echo -e "    ${DIM}0) Exit${NC}"
        echo ""

        _read choice "  $(echo -e "${BOLD}Choice:${NC} ")" || { _BACK=0; continue; }

        case "$choice" in
            1) menu_documentation          || { _BACK=0; continue; } ;;
            2) menu_create_notification    || { _BACK=0; continue; } ;;
            3) menu_disk_usage             || { _BACK=0; continue; } ;;
            4) menu_memory_usage           || { _BACK=0; continue; } ;;
            5) menu_manage_crontab         || { _BACK=0; continue; } ;;
            6) menu_schedule_backup        || { _BACK=0; continue; } ;;
            7) menu_schedule_stay_alive    || { _BACK=0; continue; } ;;
            8) menu_manage_notif_pollers   || { _BACK=0; continue; } ;;
            9) menu_db_dump                   || { _BACK=0; continue; } ;;
            10) menu_config_backup_restore    || { _BACK=0; continue; } ;;
            11) menu_toggle_debug             || { _BACK=0; continue; } ;;
            0)
                echo ""
                print_info "Goodbye."
                echo ""
                exit 0
                ;;
            *)
                print_warn "Invalid choice. Enter 0-11."
                sleep 1
                ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Entry Point
# ─────────────────────────────────────────────

main_menu
