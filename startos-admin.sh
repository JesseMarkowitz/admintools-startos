#!/usr/bin/env bash
# startos-admin.sh — Interactive admin menu for StartOS servers
# Usage: chmod +x startos-admin.sh && ./startos-admin.sh

VERSION="33"   # integer — increment on each release

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
_POLLER_STATE_PREFIX="/var/lib/startos-admin/startos-admin-poller-state-"
_POLLER_LOG_PREFIX="/var/log/startos-notif-poller-"

# ─────────────────────────────────────────────
# Navigation — "exit" / "back" support
# ─────────────────────────────────────────────

_BACK=0

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

# Print the standard navigation hint at the start of a wizard.
_nav_tip() {
    echo -e "  ${DIM}(type 'back' to return to main menu, or 'exit' to quit)${NC}"
    echo ""
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

    # Feed commands into chroot-and-upgrade via heredoc.
    # Encoded values are alphanumeric-only — safe in any shell context.
    # The trailing `echo` after each base64 -d adds the required newline.
    local chroot_exit=0
    sudo /usr/lib/startos/scripts/chroot-and-upgrade << EOF || chroot_exit=$?
{ crontab -l 2>/dev/null; printf '%s' "$encoded_comment" | base64 -d; echo; printf '%s' "$encoded_line" | base64 -d; echo; } | crontab -
exit
EOF

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
# Feature 1: Create StartOS Notification
# ─────────────────────────────────────────────

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
    _read notif_title "  Notification title: " || return 1
    if [[ -z "$notif_title" ]]; then
        print_error "Title cannot be empty."
        pause; return
    fi

    _read notif_body "  Notification message: " || return 1
    if [[ -z "$notif_body" ]]; then
        print_error "Message cannot be empty."
        pause; return
    fi

    # ── Execute ──────────────────────────────────────────────────────────────
    echo ""
    local svc_display="${notif_service:-"(blank)"}"
    print_info "Creating [$notif_level] notification for ${svc_display}: \"$notif_title\""
    echo ""

    local exit_code=0
    start-cli notification create "$notif_service" "$notif_level" "$notif_title" "$notif_body" 2>&1 \
        || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        print_success "Notification created."
    else
        print_error "Command failed (exit $exit_code)."
    fi

    pause
}

# ─────────────────────────────────────────────
# Feature 2: Display Disk Used by Service
# ─────────────────────────────────────────────

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

    # Color-code the output: highlight lines >= 1G in red, >= 100M in yellow
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
    done <<< "$raw_output"

    echo ""
    echo -e "  ${DIM}(Red = ≥ 1G, Yellow = ≥ 100M)${NC}"
    pause
}

# ─────────────────────────────────────────────
# Feature 3: Display Memory Used by Service
# ─────────────────────────────────────────────

menu_memory_usage() {
    print_header
    print_section "Memory Used by Service"
    echo ""
    print_info "Running: start-cli package stats"
    echo ""

    local stats_output exit_code=0
    stats_output=$(start-cli package stats 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        print_error "Command failed (exit $exit_code)."
        echo -e "${RED}${stats_output}${NC}"
        pause; return
    fi

    # Reformat: strip table borders, drop Container ID column, colorize by usage %
    echo "$stats_output" | awk '
    BEGIN { FS="|" }
    /^\+/ { next }
    /^\|/ {
        n = $2; gsub(/^[ \t]+|[ \t]+$/, "", n)
        u = $4; gsub(/^[ \t]+|[ \t]+$/, "", u)
        l = $5; gsub(/^[ \t]+|[ \t]+$/, "", l)
        p = $6; gsub(/^[ \t]+|[ \t]+$/, "", p)
        if (n == "Name") {
            printf "\033[1m  %-22s %-12s %-14s %s\033[0m\n", n, u, l, p
            printf "  %-22s %-12s %-14s %s\n", "──────────────────────", "──────────", "────────────", "────────"
        } else {
            pct = p + 0
            if (pct >= 80)      color = "\033[1;31m"
            else if (pct >= 50) color = "\033[33m"
            else                color = "\033[0m"
            printf "%s  %-22s %-12s %-14s %s\033[0m\n", color, n, u, l, p
        }
    }'
    echo ""
    pause
}

# ─────────────────────────────────────────────
# Feature 4: Manage Cron Jobs
# ─────────────────────────────────────────────

_cron_view_delete() {
    while true; do
        print_header
        print_section "View / Delete Cron Jobs"
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

        # Display crontab — comments dimmed, executable lines numbered for deletion
        local -a cron_lines=()
        local -a cron_line_nums=()
        local linenum=0
        while IFS= read -r line; do
            linenum=$(( linenum + 1 ))
            if [[ "$line" =~ ^# ]]; then
                echo -e "  ${DIM}${line}${NC}"
            elif [[ -n "$line" ]]; then
                cron_lines+=("$line")
                cron_line_nums+=("$linenum")
                echo -e "  ${CYAN}${BOLD}${#cron_lines[@]})${NC} ${CYAN}${line}${NC}"
            fi
        done <<< "$cron_output"

        echo ""

        if [[ ${#cron_lines[@]} -eq 0 ]]; then
            pause; return
        fi

        echo -e "  ${DIM}Enter number(s) to delete (comma-separated or 'all'), or 0 to go back.${NC}"
        echo ""
        _read del_choice "  Choice: " || return 1

        if [[ "$del_choice" == "0" ]]; then
            return
        fi

        # Parse selection into array of 0-based indices into cron_lines
        local -a selected_indices=()
        if [[ "$del_choice" == "all" ]]; then
            local j
            for (( j=0; j<${#cron_lines[@]}; j++ )); do
                selected_indices+=("$j")
            done
        else
            local valid=true
            IFS=',' read -ra parts <<< "$del_choice"
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

        # For each selected job, collect its crontab line number (and preceding comment if any)
        local -a remove_linenums=()
        echo ""
        print_warn "This will delete:"
        for idx in "${selected_indices[@]}"; do
            local target_linenum="${cron_line_nums[$idx]}"
            local target_line="${cron_lines[$idx]}"
            local prev_linenum=$(( target_linenum - 1 ))
            local prev_line=""
            [[ $prev_linenum -gt 0 ]] && prev_line=$(echo "$cron_output" | sed -n "${prev_linenum}p")
            if [[ "$prev_line" =~ ^# ]]; then
                remove_linenums+=("$prev_linenum")
                echo -e "  ${DIM}${prev_line}${NC}"
            fi
            remove_linenums+=("$target_linenum")
            echo -e "  ${CYAN}${target_line}${NC}"
        done
        echo ""

        # Sort and deduplicate line numbers, then join with commas for awk
        local remove_lines
        remove_lines=$(printf '%s\n' "${remove_linenums[@]}" | sort -nu | paste -sd,)

        if ! confirm "Delete the selected cron job(s)?"; then
            [[ $_BACK -eq 1 ]] && return 1
            print_info "Cancelled."
            sleep 1
            continue
        fi

        _warn_restart "after the cron job(s) are deleted."

        if ! confirm "Proceed? (server will restart automatically)"; then
            [[ $_BACK -eq 1 ]] && return 1
            print_info "Cancelled."
            sleep 1
            continue
        fi

        print_success "Deletion staged. Entering persistence mode now."
        echo ""

        # $remove_lines is e.g. "5" or "2,3,5,6" — expanded by outer bash, safe in heredoc.
        # The awk program skips all lines whose NR is in the skip set.
        local chroot_exit=0
        sudo /usr/lib/startos/scripts/chroot-and-upgrade << EOF || chroot_exit=$?
{ crontab -l 2>/dev/null || true; } | awk -v lines="$remove_lines" 'BEGIN{n=split(lines,a,","); for(i=1;i<=n;i++) skip[a[i]]=1} !(NR in skip){print}' | crontab -
exit
EOF

        if [[ $chroot_exit -eq 0 ]]; then
            print_success "Cron job(s) deleted."
            print_warn "The server will restart shortly — your SSH session will disconnect."
        else
            print_error "chroot-and-upgrade failed (exit $chroot_exit). Cron job(s) were not deleted."
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
        echo -e "    ${CYAN}${BOLD}1)${NC} View / delete cron jobs"
        echo -e "    ${CYAN}${BOLD}2)${NC} Add a cron job"
        echo ""
        echo -e "    ${DIM}0) Back${NC}"
        echo ""
        _read sub_choice "  $(echo -e "${BOLD}Choice:${NC} ")" || return 1
        case "$sub_choice" in
            1) _cron_view_delete || return 1 ;;
            2) _cron_add_flow    || return 1 ;;
            0) return ;;
            *) print_warn "Enter 0-2." ; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Feature 5: Schedule Backups
# ─────────────────────────────────────────────

# Returns a cron schedule string, sets global CRON_SCHEDULE
pick_cron_schedule() {
    echo ""
    echo -e "  ${BOLD}Select backup schedule:${NC}"
    echo -e "    ${BOLD}1)${NC} Daily at midnight     ${DIM}(0 0 * * *)${NC}"
    echo -e "    ${BOLD}2)${NC} Daily at 3 AM         ${DIM}(0 3 * * *)${NC}"
    echo -e "    ${BOLD}3)${NC} Weekly (Sun midnight) ${DIM}(0 0 * * 0)${NC}"
    echo -e "    ${BOLD}4)${NC} Custom cron expression"
    echo ""

    while true; do
        _read sched_choice "  Choice [1-4]: " || return 1
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
            *) print_warn "Enter 1, 2, 3, or 4." ;;
        esac
    done
}

menu_schedule_backup() {
    print_header
    print_section "Schedule Backups"
    echo ""
    _nav_tip

    # ── Step 1: Select backup target ────────────────────────────────────────
    print_info "Fetching backup targets..."
    local raw_targets
    if ! raw_targets=$(start-cli backup target list 2>&1); then
        print_error "Failed to list backup targets."
        echo -e "${RED}${raw_targets}${NC}"
        pause; return
    fi

    mapfile -t targets <<< "$(parse_backup_targets "$raw_targets")"

    if [[ ${#targets[@]} -eq 0 ]]; then
        print_warn "No backup targets found. Add a target in the StartOS UI first."
        pause; return
    fi

    echo ""
    echo -e "  ${BOLD}Select backup target:${NC}"
    local i=1
    for tgt in "${targets[@]}"; do
        echo -e "    ${BOLD}${i})${NC} ${tgt}"
        (( i++ ))
    done
    echo ""

    local backup_target=""
    while true; do
        _read tgt_choice "  Choice [1-$((i-1))]: " || return 1
        if [[ "$tgt_choice" =~ ^[0-9]+$ ]] && \
           [[ "$tgt_choice" -ge 1 ]] && [[ "$tgt_choice" -lt "$i" ]]; then
            backup_target="${targets[$((tgt_choice - 1))]}"
            # Extract just the target ID if the line contains extra info (e.g. "cifs-6  My NAS")
            backup_target=$(echo "$backup_target" | awk '{print $1}')
            break
        fi
        print_warn "Enter a number between 1 and $((i-1))."
    done

    # ── Step 2: Password ─────────────────────────────────────────────────────
    echo ""
    print_warn "Enter your StartOS primary password (used for backup encryption)."
    echo -e "  ${DIM}(type 'back' + Enter to return to main menu, or 'exit' + Enter to quit)${NC}"
    local backup_password=""
    while true; do
        read -rsp "  Password: " backup_password
        echo ""
        if [[ "${backup_password,,}" == "exit" ]]; then exit 0; fi
        if [[ "${backup_password,,}" == "back" ]]; then _BACK=1; return 1; fi
        if [[ -z "$backup_password" ]]; then
            print_warn "Password cannot be empty."
        else
            break
        fi
    done

    # ── Step 3: Select packages ──────────────────────────────────────────────
    echo ""
    print_info "Fetching installed services..."
    local pkg_list
    if ! pkg_list=$(start-cli package list 2>&1); then
        print_error "Failed to list packages."
        echo -e "${RED}${pkg_list}${NC}"
        pause; return
    fi

    mapfile -t packages <<< "$(parse_package_ids "$pkg_list")"

    if [[ ${#packages[@]} -eq 0 ]]; then
        print_warn "No packages found."
        pause; return
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
    echo ""

    local selected_packages=()
    local pkg_ids_arg=""
    while true; do
        _read pkg_selection "  Selection (e.g. 1,3 or 'all'): " || return 1
        if [[ "$pkg_selection" == "all" ]]; then
            # No --package-ids flag = back up everything
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
                # Join with commas for --package-ids
                pkg_ids_arg=$(IFS=','; echo "${selected_packages[*]}")
                break
            fi
            selected_packages=()
        else
            print_warn "Enter numbers like 1,3 or 'all'."
        fi
    done

    local packages_display
    if [[ -z "$pkg_ids_arg" ]]; then
        packages_display="ALL"
    else
        packages_display="$pkg_ids_arg"
    fi

    # ── Step 4: Schedule ─────────────────────────────────────────────────────
    local CRON_SCHEDULE
    pick_cron_schedule || return 1

    # ── Step 5: Post-backup notification ────────────────────────────────────
    local notif_cmd=""
    _pick_post_action "Post-backup notification:" notif_cmd || return 1

    # ── Build backup command ──────────────────────────────────────────────────
    local backup_cmd="start-cli backup create ${backup_target} '${backup_password}'"
    [[ -n "$pkg_ids_arg" ]] && backup_cmd+=" --package-ids ${pkg_ids_arg}"

    local full_line="$CRON_SCHEDULE $backup_cmd"
    [[ -n "$notif_cmd" ]] && full_line+=" && $notif_cmd"

    # ── Step 6: Preview & confirm ────────────────────────────────────────────
    echo ""
    print_section "Review Backup Schedule"
    echo ""
    echo -e "  ${BOLD}Target:${NC}    $backup_target"
    echo -e "  ${BOLD}Packages:${NC}  $packages_display"
    echo -e "  ${BOLD}Schedule:${NC}  $CRON_SCHEDULE"
    [[ -n "$notif_cmd" ]] && echo -e "  ${BOLD}Notify:${NC}    $notif_cmd"
    echo ""
    echo -e "  ${DIM}Cron line to install:${NC}"
    # Show password masked in preview
    local preview_line="${full_line//${backup_password}/********}"
    echo -e "  ${DIM}${preview_line}${NC}"
    echo ""

    if ! confirm "Install this cron job?"; then
        [[ $_BACK -eq 1 ]] && return 1
        print_info "Cancelled."
        pause; return
    fi

    install_cron_job "$full_line" "Schedule Backups" || return 1
    # NOTE: server restarts after this — nothing below executes
}

# Helper: prompt for StartOS notification fields, storing into named variables
_pick_notif_startos() {
    local -n _svc="$1" _lvl="$2" _title="$3" _body="$4"

    # Service selection
    echo ""
    print_info "Fetching installed services for notification..."
    local _pkg_list
    _pkg_list=$(start-cli package list 2>/dev/null) || true
    mapfile -t _pkgs <<< "$(parse_package_ids "$_pkg_list")"

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

    echo ""
    echo -e "  ${BOLD}${_ppa_header}${NC}"
    echo -e "    ${BOLD}1)${NC} curl to a URL"
    echo -e "    ${BOLD}2)${NC} StartOS notification"
    echo -e "    ${BOLD}3)${NC} Both"
    echo -e "    ${BOLD}4)${NC} None"
    echo ""

    local _ppa_mode="" _ppa_curl_url=""
    local _ppa_svc="" _ppa_level="" _ppa_title="" _ppa_body=""
    while true; do
        _read _ppa_choice "  Choice [1-4]: " || return 1
        case "$_ppa_choice" in
            1)
                _read _ppa_curl_url "  Notification URL: " || return 1
                [[ -z "$_ppa_curl_url" ]] && { print_warn "URL cannot be empty."; continue; }
                _ppa_mode="1"; break ;;
            2)
                _pick_notif_startos _ppa_svc _ppa_level _ppa_title _ppa_body || return 1
                _ppa_mode="2"; break ;;
            3)
                _read _ppa_curl_url "  Notification URL: " || return 1
                [[ -z "$_ppa_curl_url" ]] && { print_warn "URL cannot be empty."; continue; }
                _pick_notif_startos _ppa_svc _ppa_level _ppa_title _ppa_body || return 1
                _ppa_mode="3"; break ;;
            4) _ppa_mode="4"; break ;;
            *) print_warn "Enter 1, 2, 3, or 4." ;;
        esac
    done

    case "$_ppa_mode" in
        1) _ppa_notif_cmd="curl -fsS --max-time 10 \"${_ppa_curl_url}\" >/dev/null 2>&1" ;;
        2) _ppa_notif_cmd="start-cli notification create ${_ppa_svc} ${_ppa_level} \"${_ppa_title}\" \"${_ppa_body}\"" ;;
        3) _ppa_notif_cmd="curl -fsS --max-time 10 \"${_ppa_curl_url}\" >/dev/null 2>&1 && start-cli notification create ${_ppa_svc} ${_ppa_level} \"${_ppa_title}\" \"${_ppa_body}\"" ;;
        4) _ppa_notif_cmd="" ;;
    esac
}

# ─────────────────────────────────────────────
# Feature 5: Schedule Stay-Alive Curl
# ─────────────────────────────────────────────

menu_schedule_stay_alive() {
    print_header
    print_section "Schedule Stay-Alive Curl"
    echo ""
    _nav_tip

    _read stay_url "  URL to curl: " || return 1
    if [[ -z "$stay_url" ]]; then
        print_error "URL cannot be empty."
        pause; return
    fi

    echo ""
    echo -e "  ${BOLD}Select frequency:${NC}"
    echo -e "    ${BOLD}1)${NC} Every 5 minutes    ${DIM}(*/5 * * * *)${NC}"
    echo -e "    ${BOLD}2)${NC} Every 15 minutes   ${DIM}(*/15 * * * *)${NC}"
    echo -e "    ${BOLD}3)${NC} Every 30 minutes   ${DIM}(*/30 * * * *)${NC}"
    echo -e "    ${BOLD}4)${NC} Hourly             ${DIM}(0 * * * *)${NC}"
    echo -e "    ${BOLD}5)${NC} Custom cron expression"
    echo ""

    local CRON_SCHEDULE
    while true; do
        _read freq_choice "  Choice [1-5]: " || return 1
        case "$freq_choice" in
            1) CRON_SCHEDULE="*/5 * * * *";  break ;;
            2) CRON_SCHEDULE="*/15 * * * *"; break ;;
            3) CRON_SCHEDULE="*/30 * * * *"; break ;;
            4) CRON_SCHEDULE="0 * * * *";    break ;;
            5)
                _read CRON_SCHEDULE "  Enter cron expression (e.g. 0 2 * * 1-5): " || return 1
                [[ -n "$CRON_SCHEDULE" ]] && break
                print_warn "Expression cannot be empty."
                ;;
            *) print_warn "Enter 1 through 5." ;;
        esac
    done

    local cron_line="$CRON_SCHEDULE curl -fsS --max-time 10 \"$stay_url\" > /dev/null 2>&1"

    echo ""
    print_section "Review Stay-Alive Job"
    echo ""
    echo -e "  ${BOLD}URL:${NC}      $stay_url"
    echo -e "  ${BOLD}Schedule:${NC} $CRON_SCHEDULE"
    echo ""
    echo -e "  ${DIM}Cron line: ${cron_line}${NC}"
    echo ""

    if ! confirm "Install this cron job?"; then
        [[ $_BACK -eq 1 ]] && return 1
        print_info "Cancelled."
        pause; return
    fi

    install_cron_job "$cron_line" "Schedule Stay-Alive Curl" || return 1
    # NOTE: server restarts after this — nothing below executes
}

# ─────────────────────────────────────────────
# Feature 7: Manage Notification Forwarders
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
    local out exit_code http body
    out=$(curl -s -w "\nHTTP_STATUS:%{http_code}" --max-time 10 -d "$test_msg" "$url" 2>&1)
    exit_code=$?
    http=$(echo "$out" | grep 'HTTP_STATUS:' | cut -d: -f2)
    body=$(echo "$out" | grep -v 'HTTP_STATUS:')
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
        url=$(grep      '^WEBHOOK_URL=' "$script" 2>/dev/null | cut -d'"' -f2)
        levels=$(grep   '^LEVELS='      "$script" 2>/dev/null | cut -d'"' -f2)
        keyword=$(grep  '^KEYWORD='     "$script" 2>/dev/null | cut -d'"' -f2)
        schedule=$(sudo crontab -u root -l 2>/dev/null \
            | grep -A1 "^# startos-notif-poller-${pname}" 2>/dev/null \
            | tail -1 | awk '{print $1,$2,$3,$4,$5}')

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
    echo -e "  ${YELLOW}First-run note:${NC} On the first poll after install, the forwarder will"
    echo -e "  forward only the single most recent notification at that moment."
    echo -e "  All older notifications are skipped to avoid a historical flood."
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
    cur_url=$(grep      '^WEBHOOK_URL='  "$script_path" 2>/dev/null | cut -d'"' -f2)
    cur_levels=$(grep   '^LEVELS='       "$script_path" 2>/dev/null | cut -d'"' -f2)
    cur_keyword=$(grep  '^KEYWORD='      "$script_path" 2>/dev/null | cut -d'"' -f2)
    cur_schedule=$(sudo crontab -u root -l 2>/dev/null \
        | grep -A1 "^# startos-notif-poller-${poller_name}" | tail -1 \
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
LOG_MAX_LINES=25000
DEBUG=0
"

    local body_template
    body_template=$(cat << 'POLLER_BODY_END'
# Cron runs with a minimal PATH — ensure standard locations are included
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

_ts() { date '+%Y.%m.%d %H:%M:%S %Z'; }

# ── Log self-truncation ───────────────────────────────────────────────────
_SELF_LOG="/var/log/startos-notif-poller-${POLLER_NAME}.log"
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

if ! command -v start-cli >/dev/null 2>&1; then
    echo "$(_ts): ERROR — start-cli not found in PATH: $PATH"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "$(_ts): ERROR — jq not found in PATH: $PATH"
    exit 1
fi

# ── Fetch notifications ───────────────────────────────────────────────────
NOTIFS=$(start-cli notification list 2>&1)
NOTIFS_EXIT=$?
if [ $NOTIFS_EXIT -ne 0 ]; then
    echo "$(_ts): ERROR — start-cli notification list failed (exit $NOTIFS_EXIT): $NOTIFS"
    exit 0
fi
if [ -z "$NOTIFS" ]; then
    echo "$(_ts): no notifications returned — exiting"
    exit 0
fi

# ── First run: seed state to prevent historical flood ─────────────────────
# On first run (no state file exists yet), we find the highest existing
# notification ID and set LAST_ID = MAX_ID - 1 so that only the single most
# recent notification is forwarded. This prevents replaying every historical
# notification the first time the forwarder runs. Subsequent runs forward
# only notifications with IDs greater than the last seen ID.
if [ "$FIRST_RUN" -eq 1 ]; then
    MAX_RAW=$(echo "$NOTIFS" | jq '[.[].id | tonumber] | max // 0' 2>/dev/null || echo "0")
    LAST_ID=$(( MAX_RAW - 1 ))
    [ "$LAST_ID" -lt 0 ] && LAST_ID=0
    echo "$(_ts): INFO first run — most recent notification id=$MAX_RAW, setting LAST_ID=$LAST_ID so only that notification is forwarded"
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

done < <(echo "$NOTIFS" | jq -c --argjson last "$LAST_ID" '[.[] | select((.id | tonumber) > $last)] | .[]')

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
    local cron_comment="# startos-notif-poller-${name} | Added: ${install_ts} | v${VERSION} | Action: Manage Notification Forwarders | Webhook: ${url} | Levels: ${levels} | Keyword: ${keyword:-none}"
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

    # Remove any existing entry for this poller name, then write the new script
    # and add the tagged comment + cron line. All in one chroot session.
    # \$0 in the heredoc → $0 for awk (the outer bash escapes \$ → $).
    local chroot_exit=0
    sudo /usr/lib/startos/scripts/chroot-and-upgrade << EOF || chroot_exit=$?
{ crontab -l 2>/dev/null || true; } | awk -v t="# startos-notif-poller-${name}" 'index(\$0,t)==1{skip=1;next} skip{skip=0;next} {print}' | crontab -
printf '%s' "$encoded_script" | base64 -d > ${_POLLER_BIN_PREFIX}${name}
chmod +x ${_POLLER_BIN_PREFIX}${name}
{ crontab -l 2>/dev/null; printf '%s' "$encoded_comment" | base64 -d; echo; printf '%s' "$encoded_cron" | base64 -d; echo; } | crontab -
exit
EOF

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
        chroot_body+="crontab -l 2>/dev/null | grep -v 'startos-notif-poller-${rname}' | crontab -
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
    echo -e "    ${BOLD}1)${NC} Delete state file  ${DIM}(next run seeds from most recent notification)${NC}"
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
                sudo rm -f "$state_file"
                print_success "State file deleted. Next run will forward only the most recent notification."
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

menu_db_dump() {
    print_header
    print_section "System Database"
    echo ""
    print_info "Fetching database dump..."
    local db_json
    db_json=$(start-cli db dump 2>/dev/null) || {
        print_error "Failed to run 'start-cli db dump'."
        pause; return
    }
    [[ -z "$db_json" ]] && { print_error "Empty response."; pause; return; }

    while true; do
        print_header
        print_section "System Database"
        echo ""
        echo -e "    ${CYAN}${BOLD}1)${NC} Server Info"
        echo -e "    ${CYAN}${BOLD}2)${NC} Network"
        echo -e "    ${CYAN}${BOLD}3)${NC} Service Status"
        echo -e "    ${CYAN}${BOLD}4)${NC} Service Detail"
        echo ""
        echo -e "    ${DIM}0) Back${NC}"
        echo ""
        _read db_choice "  $(echo -e "${BOLD}Choice:${NC} ")" || return 1
        case "$db_choice" in
            1) _db_server_info "$db_json" ;;
            2) _db_network     "$db_json" ;;
            3) _db_svc_status  "$db_json" ;;
            4) _db_svc_detail  "$db_json" || return 1 ;;
            0) return ;;
            *) print_warn "Enter 0-4." ; sleep 1 ;;
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
                echo -e "    ${CYAN}•${NC} ${BOLD}Post-backup notification${NC} — optionally browse to a URL (useful for"
                echo -e "      services like NTFY) and/or create a StartOS notification. Since StartOS"
                echo -e "      already notifies you when a backup completes, combining this with the"
                echo -e "      kick-off notification gives you elapsed time for each backup run."
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
                echo -e "    ${DIM}State:   /var/lib/startos-admin/startos-admin-poller-state-<name>${NC}"
                echo -e "    ${DIM}Log:     /var/log/startos-notif-poller-<name>.log${NC}"
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
            0) return ;;
            *) print_warn "Enter 0-8." ; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Auto-Update Check
# ─────────────────────────────────────────────

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
            local _chroot_exit=0
            sudo /usr/lib/startos/scripts/chroot-and-upgrade << EOF || _chroot_exit=$?
printf '%s' "$_encoded" | base64 -d > /usr/local/bin/startos-admin
chmod +x /usr/local/bin/startos-admin
mkdir -p /var/lib/startos-admin
exit
EOF
            if [[ $_chroot_exit -eq 0 ]]; then
                print_success "Installed. Server restarting — reconnect and run: startos-admin"
            else
                print_error "Installation failed (exit $_chroot_exit)."
                pause
            fi
        fi
        [[ $_BACK -eq 1 ]] && { _BACK=0; }
        return 0  # skip version check when not running from persistent install
    fi

    # ── Normal update check (only runs when already persistent) ─────────────
    # Fetch with short timeout — fail silently if offline or unreachable
    remote_script=$(curl -fsSL --max-time 5 "$raw_url" 2>/dev/null) || return 0

    remote_version=$(echo "$remote_script" | grep '^VERSION=' | head -1 | tr -d '"' | cut -d= -f2 | awk '{print $1}')
    [[ -z "$remote_version" ]] && return 0

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
mkdir -p /var/lib/startos-admin
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
# Main Menu
# ─────────────────────────────────────────────

main_menu() {
    check_for_update
    while true; do
        print_header
        # Counts for display
        local _cron_n _fwd_arr _fwd_n
        _cron_n=$(sudo crontab -u root -l 2>/dev/null | grep -c '^# startos-admin v' 2>/dev/null || echo 0)
        _fwd_arr=("${_POLLER_BIN_PREFIX}"*)
        [[ -e "${_fwd_arr[0]}" ]] && _fwd_n=${#_fwd_arr[@]} || _fwd_n=0

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
        echo ""
        echo -e "    ${DIM}0) Exit${NC}"
        echo ""

        _read choice "  $(echo -e "${BOLD}Choice:${NC} ")" || { _BACK=0; continue; }

        case "$choice" in
            1) menu_documentation          || { _BACK=0; continue; } ;;
            2) menu_create_notification    || { _BACK=0; continue; } ;;
            3) menu_disk_usage ;;
            4) menu_memory_usage ;;
            5) menu_manage_crontab         || { _BACK=0; continue; } ;;
            6) menu_schedule_backup        || { _BACK=0; continue; } ;;
            7) menu_schedule_stay_alive    || { _BACK=0; continue; } ;;
            8) menu_manage_notif_pollers   || { _BACK=0; continue; } ;;
            9) menu_db_dump                || { _BACK=0; continue; } ;;
            0)
                echo ""
                print_info "Goodbye."
                echo ""
                exit 0
                ;;
            *)
                print_warn "Invalid choice. Enter 0-9."
                sleep 1
                ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Entry Point
# ─────────────────────────────────────────────

main_menu
