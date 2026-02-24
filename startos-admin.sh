#!/usr/bin/env bash
# startos-admin.sh — Interactive admin menu for StartOS servers
# Usage: chmod +x startos-admin.sh && ./startos-admin.sh

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
# Helper Functions
# ─────────────────────────────────────────────

print_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║         StartOS Admin Menu               ║"
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
    read -rp "$(echo -e "${DIM}  Press Enter to continue...${NC}")"
}

# Returns 0 for yes, 1 for no
confirm() {
    local prompt="${1:-Are you sure?}"
    while true; do
        read -rp "$(echo -e "${YELLOW}${BOLD}[?]${NC} ${prompt} [y/N]: ")" yn
        case "${yn,,}" in
            y|yes) return 0 ;;
            n|no|"") return 1 ;;
            *) print_warn "Please enter y or n." ;;
        esac
    done
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

    # Duplicate check
    if crontab -u root -l 2>/dev/null | grep -qF "$cron_line"; then
        print_warn "An identical cron job already exists. Skipping install."
        return 0
    fi

    # Restart warning — shown before the point of no return
    echo ""
    echo -e "  ${RED}${BOLD}┌─────────────────────────────────────────────────┐${NC}"
    echo -e "  ${RED}${BOLD}│  WARNING: SERVER WILL AUTOMATICALLY RESTART     │${NC}"
    echo -e "  ${RED}${BOLD}│  after the cron job is installed.               │${NC}"
    echo -e "  ${RED}${BOLD}│  Save any work and close open connections.      │${NC}"
    echo -e "  ${RED}${BOLD}└─────────────────────────────────────────────────┘${NC}"
    echo ""

    if ! confirm "Proceed? (server will restart automatically)"; then
        print_info "Cancelled."
        return 1
    fi

    # Write merged crontab to a temp file.
    # /tmp is accessible from within the chroot environment.
    local tmp_crontab
    tmp_crontab=$(mktemp /tmp/startos-crontab-XXXXXX)
    ( crontab -u root -l 2>/dev/null; echo "$cron_line" ) > "$tmp_crontab"

    print_success "Cron job staged. Entering persistence mode now."
    print_warn "Your SSH session will disconnect when the server restarts."
    print_warn "Reconnect after startup completes to verify with: crontab -l"
    echo ""

    # Feed commands into chroot-and-upgrade via heredoc.
    # $tmp_crontab is expanded here (in the outer shell) so the chroot shell
    # receives the literal path, e.g. /tmp/startos-crontab-aB3xYz.
    # The temp file is deleted inside the chroot after crontab reads it.
    # NOTE: Nothing after this heredoc will execute — the server restarts.
    sudo /usr/lib/startos/scripts/chroot-and-upgrade << EOF
crontab $tmp_crontab
rm -f $tmp_crontab
exit
EOF
}

# ─────────────────────────────────────────────
# Feature 1: Create StartOS Notification
# ─────────────────────────────────────────────

menu_create_notification() {
    print_header
    print_section "Create StartOS Notification"
    echo ""

    # ── Step 1: Select service ───────────────────────────────────────────────
    print_info "Fetching installed services..."
    local pkg_list
    if ! pkg_list=$(start-cli package list 2>&1); then
        print_error "Failed to list packages. Is start-cli authenticated?"
        echo -e "${RED}${pkg_list}${NC}"
        pause; return
    fi

    mapfile -t packages <<< "$(echo "$pkg_list" | grep -v '^$')"

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
        read -rp "  Choice [1-${i}]: " svc_choice
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
    echo -e "    ${BOLD}2)${NC} ${YELLOW}warning${NC} — requires attention"
    echo -e "    ${BOLD}3)${NC} ${RED}error${NC}   — something went wrong"
    echo ""
    local notif_level="info"
    while true; do
        read -rp "  Choice [1-3, default 1]: " level_choice
        case "${level_choice:-1}" in
            1) notif_level="info";    break ;;
            2) notif_level="warning"; break ;;
            3) notif_level="error";   break ;;
            *) print_warn "Enter 1, 2, or 3." ;;
        esac
    done

    # ── Step 3: Title & message ──────────────────────────────────────────────
    echo ""
    read -rp "  Notification title: " notif_title
    if [[ -z "$notif_title" ]]; then
        print_error "Title cannot be empty."
        pause; return
    fi

    read -rp "  Notification message: " notif_body
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
    print_section "Disk Usage by Service"
    echo ""
    print_info "Running: sudo du -hd 1 /media/startos/data/package-data/volumes/"
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
    print_info "Fetching installed services..."
    echo ""

    local pkg_list
    if ! pkg_list=$(start-cli package list 2>&1); then
        print_error "Failed to list packages. Is start-cli authenticated?"
        echo -e "${RED}${pkg_list}${NC}"
        pause; return
    fi

    mapfile -t packages <<< "$(echo "$pkg_list" | grep -v '^$')"

    if [[ ${#packages[@]} -eq 0 ]]; then
        print_warn "No packages found."
        pause; return
    fi

    echo -e "  ${BOLD}Installed services:${NC}"
    local i=1
    for pkg in "${packages[@]}"; do
        echo -e "    ${BOLD}${i})${NC} ${pkg}"
        (( i++ ))
    done
    echo -e "    ${BOLD}0)${NC} All services"
    echo ""

    local choice
    while true; do
        read -rp "  Select service [0-$((${#packages[@]}))]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -le "${#packages[@]}" ]]; then
            break
        fi
        print_warn "Enter a number between 0 and ${#packages[@]}."
    done

    echo ""

    if [[ "$choice" -eq 0 ]]; then
        # All services
        for pkg in "${packages[@]}"; do
            print_section "Stats: $pkg"
            start-cli package stats "$pkg" 2>&1 || print_error "Failed to get stats for $pkg"
            echo ""
        done
    else
        local selected_pkg="${packages[$((choice - 1))]}"
        print_section "Stats: $selected_pkg"
        start-cli package stats "$selected_pkg" 2>&1 || print_error "Failed to get stats for $selected_pkg"
    fi

    pause
}

# ─────────────────────────────────────────────
# Feature 4: Schedule Backups
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
        read -rp "  Choice [1-4]: " sched_choice
        case "$sched_choice" in
            1) CRON_SCHEDULE="0 0 * * *";  return 0 ;;
            2) CRON_SCHEDULE="0 3 * * *";  return 0 ;;
            3) CRON_SCHEDULE="0 0 * * 0";  return 0 ;;
            4)
                read -rp "  Enter cron expression (e.g. 0 2 * * 1-5): " CRON_SCHEDULE
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

    # ── Step 1: Select backup target ────────────────────────────────────────
    print_info "Fetching backup targets..."
    local raw_targets
    if ! raw_targets=$(start-cli backup target list 2>&1); then
        print_error "Failed to list backup targets."
        echo -e "${RED}${raw_targets}${NC}"
        pause; return
    fi

    mapfile -t targets <<< "$(echo "$raw_targets" | grep -v '^$')"

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
        read -rp "  Choice [1-$((i-1))]: " tgt_choice
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
    local backup_password=""
    while true; do
        read -rsp "  Password: " backup_password
        echo ""
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

    mapfile -t packages <<< "$(echo "$pkg_list" | grep -v '^$')"

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
    echo -e "    ${BOLD}0)${NC} All packages"
    echo ""
    print_info "For multiple packages enter numbers separated by commas (e.g. 1,3,4)"
    echo ""

    local selected_packages=()
    local pkg_ids_arg=""
    while true; do
        read -rp "  Selection (e.g. 1,3 or 0 for all): " pkg_selection
        if [[ "$pkg_selection" == "0" ]]; then
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
            print_warn "Enter numbers like 1,3 or 0 for all."
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
    pick_cron_schedule

    # ── Step 5: Post-backup notification ────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Post-backup notification:${NC}"
    echo -e "    ${BOLD}1)${NC} curl to a URL"
    echo -e "    ${BOLD}2)${NC} StartOS notification"
    echo -e "    ${BOLD}3)${NC} Both"
    echo -e "    ${BOLD}4)${NC} None"
    echo ""

    local notif_mode="" curl_url="" notif_svc="" notif_level="" notif_title="" notif_body=""
    while true; do
        read -rp "  Choice [1-4]: " notif_choice
        case "$notif_choice" in
            1)
                read -rp "  Notification URL: " curl_url
                [[ -z "$curl_url" ]] && { print_warn "URL cannot be empty."; continue; }
                notif_mode="1"; break
                ;;
            2)
                _pick_notif_startos notif_svc notif_level notif_title notif_body
                notif_mode="2"; break
                ;;
            3)
                read -rp "  Notification URL: " curl_url
                [[ -z "$curl_url" ]] && { print_warn "URL cannot be empty."; continue; }
                _pick_notif_startos notif_svc notif_level notif_title notif_body
                notif_mode="3"; break
                ;;
            4) notif_mode="4"; break ;;
            *) print_warn "Enter 1, 2, 3, or 4." ;;
        esac
    done

    # ── Build backup and notification commands ───────────────────────────────
    local backup_cmd="start-cli backup create ${backup_target} '${backup_password}'"
    [[ -n "$pkg_ids_arg" ]] && backup_cmd+=" --package-ids ${pkg_ids_arg}"

    local notif_cmd=""
    case "$notif_mode" in
        1) notif_cmd="curl -fsS --max-time 10 \"${curl_url}\" >/dev/null 2>&1" ;;
        2) notif_cmd="start-cli notification create ${notif_svc} ${notif_level} \"${notif_title}\" \"${notif_body}\"" ;;
        3) notif_cmd="curl -fsS --max-time 10 \"${curl_url}\" >/dev/null 2>&1 && start-cli notification create ${notif_svc} ${notif_level} \"${notif_title}\" \"${notif_body}\"" ;;
    esac

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
        print_info "Cancelled."
        pause; return
    fi

    install_cron_job "$full_line"
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
    mapfile -t _pkgs <<< "$(echo "$_pkg_list" | grep -v '^$')"

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
        read -rp "  Choice [1-${_i}]: " _sc
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
    echo -e "    ${BOLD}1)${NC} ${CYAN}info${NC}  ${BOLD}2)${NC} ${YELLOW}warning${NC}  ${BOLD}3)${NC} ${RED}error${NC}"
    echo ""
    while true; do
        read -rp "  Choice [1-3, default 1]: " _lc
        case "${_lc:-1}" in
            1) _lvl="info";    break ;;
            2) _lvl="warning"; break ;;
            3) _lvl="error";   break ;;
            *) print_warn "Enter 1, 2, or 3." ;;
        esac
    done

    echo ""
    read -rp "  Notification title: " _title
    read -rp "  Notification message: " _body
}

# ─────────────────────────────────────────────
# Feature 5: Schedule Stay-Alive Curl
# ─────────────────────────────────────────────

menu_schedule_stay_alive() {
    print_header
    print_section "Schedule Stay-Alive Curl"
    echo ""

    read -rp "  URL to curl: " stay_url
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
        read -rp "  Choice [1-5]: " freq_choice
        case "$freq_choice" in
            1) CRON_SCHEDULE="*/5 * * * *";  break ;;
            2) CRON_SCHEDULE="*/15 * * * *"; break ;;
            3) CRON_SCHEDULE="*/30 * * * *"; break ;;
            4) CRON_SCHEDULE="0 * * * *";    break ;;
            5)
                read -rp "  Enter cron expression: " CRON_SCHEDULE
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
        print_info "Cancelled."
        pause; return
    fi

    install_cron_job "$cron_line"
    # NOTE: server restarts after this — nothing below executes
}

# ─────────────────────────────────────────────
# Main Menu
# ─────────────────────────────────────────────

main_menu() {
    while true; do
        print_header
        echo -e "  ${BOLD}Select an action:${NC}"
        echo ""
        echo -e "    ${CYAN}${BOLD}1)${NC} Create a StartOS notification"
        echo -e "    ${CYAN}${BOLD}2)${NC} Display disk used by service"
        echo -e "    ${CYAN}${BOLD}3)${NC} Display memory used by service"
        echo -e "    ${CYAN}${BOLD}4)${NC} Schedule backups"
        echo -e "    ${CYAN}${BOLD}5)${NC} Schedule stay-alive curl"
        echo ""
        echo -e "    ${DIM}0) Exit${NC}"
        echo ""

        read -rp "  $(echo -e "${BOLD}Choice:${NC} ")" choice

        case "$choice" in
            1) menu_create_notification ;;
            2) menu_disk_usage ;;
            3) menu_memory_usage ;;
            4) menu_schedule_backup ;;
            5) menu_schedule_stay_alive ;;
            0)
                echo ""
                print_info "Goodbye."
                echo ""
                exit 0
                ;;
            *)
                print_warn "Invalid choice. Enter 0-5."
                sleep 1
                ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Entry Point
# ─────────────────────────────────────────────

main_menu
