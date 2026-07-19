#!/usr/bin/env bash
set -e

INSTALL_DIR="/opt"
if [ -z "$APP_NAME" ]; then
    APP_NAME="fireban"
fi
ensure_valid_app_name() {
    local candidate="${APP_NAME:-fireban}"
    if ! [[ "$candidate" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
        candidate="fireban"
        echo "Invalid app name detected. Falling back to default: $candidate"
    fi
    APP_NAME="$candidate"
}
ensure_valid_app_name
APP_DIR="$INSTALL_DIR/$APP_NAME"
DATA_DIR="/var/lib/$APP_NAME"
ENV_FILE="$APP_DIR/.env"
LAST_XRAY_CORES=10
CERTS_BASE="/var/lib/$APP_NAME/certs"
FIREBAN_REPO="${FIREBAN_REPO:-firegoood/FireBan}"
FIREBAN_REF="${FIREBAN_REF:-dev}"
FIREBAN_DISTRIBUTION_REPO="${FIREBAN_DISTRIBUTION_REPO:-firegoood/FireBan-Release}"
FIREBAN_DISTRIBUTION_REF="${FIREBAN_DISTRIBUTION_REF:-main}"
FIREBAN_RAW_BASE="${FIREBAN_RAW_BASE:-https://raw.githubusercontent.com/${FIREBAN_DISTRIBUTION_REPO}/${FIREBAN_DISTRIBUTION_REF}}"
FIREBAN_SCRIPT_BASE_URL_EXPLICIT=0
if [ -n "${FIREBAN_SCRIPT_BASE_URL+x}" ]; then
    FIREBAN_SCRIPT_BASE_URL_EXPLICIT=1
fi
FIREBAN_SCRIPT_BASE_URL="${FIREBAN_SCRIPT_BASE_URL:-${FIREBAN_RAW_BASE}/scripts/rebecca}"
FIREBAN_TEMPLATE_BASE_URL="${FIREBAN_TEMPLATE_BASE_URL:-${FIREBAN_RAW_BASE}/templates/fireban}"
FIREBAN_RELEASE_REPO="${FIREBAN_RELEASE_REPO:-$FIREBAN_DISTRIBUTION_REPO}"
FIREBAN_RELEASE_MANIFEST_URL="${FIREBAN_RELEASE_MANIFEST_URL:-${FIREBAN_RAW_BASE}/manifests/fireban.json}"
FIREBAN_BINARY_DEV_BRANCH="${FIREBAN_BINARY_DEV_BRANCH:-dev}"
FIREBAN_BINARY_WORKFLOW_NAME="${FIREBAN_BINARY_WORKFLOW_NAME:-binary-build}"
FIREBAN_BINARY_DEV_MANIFEST_BRANCH="${FIREBAN_BINARY_DEV_MANIFEST_BRANCH:-dev-build-manifest}"
FIREBAN_BINARY_DEV_MANIFEST_PATH="${FIREBAN_BINARY_DEV_MANIFEST_PATH:-dev-builds.json}"
FIREBAN_BINARY_DEV_MANIFEST_URL="${FIREBAN_BINARY_DEV_MANIFEST_URL:-}"
INSTALL_MODE_FILE="$APP_DIR/.install-mode"
CHANNEL_FILE="$APP_DIR/.channel"
BINARY_BIN_DIR="$APP_DIR/bin"
BINARY_SERVER="$BINARY_BIN_DIR/fireban-server"
BINARY_CLI="$BINARY_BIN_DIR/fireban-cli"
BINARY_CLI_LAUNCHER="/usr/local/bin/fireban-cli"
BINARY_METADATA_FILE="$APP_DIR/.binary-release.json"
BINARY_ARTIFACT_PREFIX="${BINARY_ARTIFACT_PREFIX:-fireban-binaries}"
BINARY_SERVICE_UNIT="/etc/systemd/system/$APP_NAME.service"
CERTBOT_VENV_DIR="$APP_DIR/certbot-venv"
CERTBOT_BIN=""
PARSED_DOMAINS=()
FIREBAN_SCRIPT_FLAVOR="${FIREBAN_SCRIPT_FLAVOR:-binary}"
FIREBAN_SCRIPT_SOURCE_FILE="${FIREBAN_SCRIPT_SOURCE_FILE:-fireban-binary.sh}"
FIREBAN_SCRIPT_INSTALL_PATH="${FIREBAN_SCRIPT_INSTALL_PATH:-/usr/local/bin/fireban}"

github_token() {
    local first_non_empty="${FIREBAN_GITHUB_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"
    printf '%s' "$first_non_empty"
}

github_curl() {
    local token
    token=$(github_token)
    if [ -n "$token" ]; then
        curl -H "Authorization: Bearer $token" -H "X-GitHub-Api-Version: 2022-11-28" "$@"
    else
        curl "$@"
    fi
}

# GitHub's raw-content CDN can briefly return a stale manifest immediately
# after a new dev build is published. Keep query parameters intact and make
# every release-manifest lookup unique so an updater never installs an older
# verified package by accident.
cache_busted_url() {
    local url="$1"
    local separator="?"
    if [[ "$url" == *\?* ]]; then
        separator="&"
    fi
    printf '%s%scache_bust=%s-%s\n' "$url" "$separator" "$(date +%s)" "$RANDOM"
}

colorized_echo() {
    local color=$1
    local text=$2
    
    case $color in
        "red")
        printf "\e[91m${text}\e[0m\n";;
        "green")
        printf "\e[92m${text}\e[0m\n";;
        "yellow")
        printf "\e[93m${text}\e[0m\n";;
        "blue")
        printf "\e[94m${text}\e[0m\n";;
        "magenta")
        printf "\e[95m${text}\e[0m\n";;
        "cyan")
        printf "\e[96m${text}\e[0m\n";;
        *)
            echo "${text}"
        ;;
    esac
}

ui_is_tty() {
    [ -t 1 ] && [ -z "${NO_COLOR:-}" ]
}

ui_color() {
    local code="$1"
    shift || true
    if ui_is_tty; then
        printf "\033[%sm%s\033[0m" "$code" "$*"
    else
        printf "%s" "$*"
    fi
}

ui_line() {
    ui_color "38;5;39" "────────────────────────────────────────────────────────────"
    printf "\n"
}

ui_header() {
    local title="$1"
    local subtitle="${2:-}"
    printf "\n"
    ui_color "38;5;45;1" "╭──────────────────────────────────────────────────────────╮"
    printf "\n  "
    ui_color "38;5;231;1" "$title"
    printf "\n"
    if [ -n "$subtitle" ]; then
        printf "  "
        ui_color "38;5;117" "$subtitle"
        printf "\n"
    fi
    ui_color "38;5;45;1" "╰──────────────────────────────────────────────────────────╯"
    printf "\n"
}

ui_section() {
    printf "\n"
    ui_color "38;5;45;1" "◆ $1"
    printf "\n"
    ui_line
}

ui_status_row() {
    local label="$1"
    local value="$2"
    printf "  "
    ui_color "38;5;245" "$(printf '%-14s' "$label")"
    ui_color "38;5;231;1" "$value"
    printf "\n"
}

ui_menu_item() {
    local number="$1"
    local command="$2"
    local description="$3"
    local selected="${4:-0}"
    local command_width=20
    printf "  "
    if [ "$selected" = "1" ]; then
        ui_color "38;5;16;48;5;45;1" " ▶ "
    else
        printf "   "
    fi
    ui_color "38;5;45;1" "$(printf '%2s' "$number")"
    printf "  "
    if [ "$selected" = "1" ]; then
        ui_color "38;5;231;1" "$(printf "%-${command_width}s" "$command")"
        ui_color "38;5;231" "$description"
    else
        ui_color "38;5;231;1" "$(printf "%-${command_width}s" "$command")"
        ui_color "38;5;245" "$description"
    fi
    printf "\n"
}

ui_menu_category() {
    printf "\n"
    ui_color "38;5;117;1" "  $1"
    printf "\n"
}

ui_clear() {
    if ui_is_tty; then
        printf "\033[H\033[2J"
    fi
}

ui_read_menu_choice() {
    local selected="$1"
    local total="$2"
    local key rest digits

    IFS= read -rsn1 key || return 1
    case "$key" in
        "")
            echo "enter:$selected"
            return
        ;;
        $'\033')
            IFS= read -rsn2 -t 0.05 rest || true
            case "$rest" in
                "[A")
                    selected=$((selected - 1))
                    [ "$selected" -lt 1 ] && selected="$total"
                    echo "move:$selected"
                    return
                ;;
                "[B")
                    selected=$((selected + 1))
                    [ "$selected" -gt "$total" ] && selected=1
                    echo "move:$selected"
                    return
                ;;
            esac
            echo "move:$selected"
            return
        ;;
        [0-9])
            digits="$key"
            while IFS= read -rsn1 -t 0.35 rest; do
                case "$rest" in
                    [0-9]) digits="${digits}${rest}" ;;
                    "") break ;;
                    *) break ;;
                esac
            done
            echo "value:$digits"
            return
        ;;
        q|Q)
            echo "quit:"
            return
        ;;
        *)
            IFS= read -r rest || true
            echo "value:${key}${rest}"
            return
        ;;
    esac
}

ui_read_yes_no() {
    local prompt="$1"
    local default_value="${2:-n}"
    local answer suffix
    if [ "$default_value" = "y" ]; then
        suffix="Y/n"
    else
        suffix="y/N"
    fi
    while true; do
        printf "%s [%s]: " "$prompt" "$suffix"
        IFS= read -r answer
        answer=$(echo "$answer" | tr '[:upper:]' '[:lower:]')
        if [ -z "$answer" ]; then
            answer="$default_value"
        fi
        case "$answer" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) colorized_echo yellow "Please answer y or n." ;;
        esac
    done
}

ui_spinner_run() {
    local message="$1"
    shift
    if ! ui_is_tty; then
        "$@"
        return $?
    fi

    local log_file
    log_file=$(mktemp)
    "$@" >"$log_file" 2>&1 &
    local pid=$!
    local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local i=0
    while kill -0 "$pid" >/dev/null 2>&1; do
        printf "\r"
        ui_color "38;5;45;1" "${frames[$((i % ${#frames[@]}))]}"
        printf " %s" "$message"
        sleep 0.08
        i=$((i + 1))
    done

    local status=0
    wait "$pid" || status=$?
    printf "\r\033[K"
    if [ "$status" -eq 0 ]; then
        ui_color "38;5;82;1" "✓"
        printf " %s\n" "$message"
        rm -f "$log_file"
        return 0
    fi

    ui_color "38;5;196;1" "✗"
    printf " %s\n" "$message"
    tail -n 80 "$log_file" >&2 || true
    rm -f "$log_file"
    return "$status"
}

format_rebecca_journal_logs() {
    while IFS= read -r line; do
        local log_time=""
        local message="$line"
        if [[ "$line" =~ ^[0-9-]+[[:space:]T]([0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]+)?([+-][0-9:]+|Z)?[[:space:]][^[:space:]]+[[:space:]][^:]+:[[:space:]](.*)$ ]]; then
            log_time="${BASH_REMATCH[1]}"
            message="${BASH_REMATCH[4]}"
        elif [[ "$line" =~ ^[A-Za-z]{3}[[:space:]][[:space:][:digit:]][[:digit:]][[:space:]]([0-9]{2}:[0-9]{2}:[0-9]{2})[[:space:]][^[:space:]]+[[:space:]][^:]+:[[:space:]](.*)$ ]]; then
            log_time="${BASH_REMATCH[1]}"
            message="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ ^([0-9]{2}:[0-9]{2}:[0-9]{2})[[:space:]][^[:space:]]+[[:space:]][^:]+:[[:space:]](.*)$ ]]; then
            log_time="${BASH_REMATCH[1]}"
            message="${BASH_REMATCH[2]}"
        fi
        if [[ "$message" =~ ^[0-9]{4}/[0-9]{2}/[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]](.*)$ ]]; then
            message="${BASH_REMATCH[1]}"
        fi
        if [ -z "$log_time" ]; then
            printf "%s\n" "$message"
            continue
        fi
        ui_color "38;5;208;1" "FireBan"
        printf "-"
        ui_color "38;5;245" "$log_time"
        printf ": "
        if [[ "$message" =~ ^\[([^]]+)\][[:space:]](DEBUG|INFO|WARN|ERROR)[[:space:]](.*)$ ]]; then
            local component="${BASH_REMATCH[1]}"
            local level="${BASH_REMATCH[2]}"
            local text="${BASH_REMATCH[3]}"
            local component_color="38;5;45;1"
            local level_color="38;5;250"
            case "$component" in
                Admin) component_color="38;5;141;1" ;;
                Database) component_color="38;5;220;1" ;;
                Node) component_color="38;5;45;1" ;;
                Runtime) component_color="38;5;82;1" ;;
                Telegram) component_color="38;5;39;1" ;;
                User) component_color="38;5;213;1" ;;
                Webhook) component_color="38;5;214;1" ;;
            esac
            case "$level" in
                DEBUG) level_color="38;5;245" ;;
                INFO) level_color="38;5;82" ;;
                WARN) level_color="38;5;220;1" ;;
                ERROR) level_color="38;5;196;1" ;;
            esac
            ui_color "$component_color" "$component"
            printf " "
            ui_color "$level_color" "$level"
            printf " : %s\n" "$text"
        else
            printf "%s\n" "$message"
        fi
    done
}

journal_output_format() {
    if journalctl -o short-iso --no-pager -n 0 >/dev/null 2>&1; then
        echo "short-iso"
    else
        echo "short"
    fi
}

humanize_seconds() {
    local seconds="${1:-0}"
    local days hours minutes
    if ! [[ "$seconds" =~ ^[0-9]+$ ]]; then
        echo "-"
        return
    fi
    days=$((seconds / 86400))
    hours=$(((seconds % 86400) / 3600))
    minutes=$(((seconds % 3600) / 60))
    seconds=$((seconds % 60))
    if [ "$days" -gt 0 ]; then
        printf "%sd %sh %sm\n" "$days" "$hours" "$minutes"
    elif [ "$hours" -gt 0 ]; then
        printf "%sh %sm\n" "$hours" "$minutes"
    elif [ "$minutes" -gt 0 ]; then
        printf "%sm %ss\n" "$minutes" "$seconds"
    else
        printf "%ss\n" "$seconds"
    fi
}


read_binary_metadata_tag() {
    local tag=""
    if [ ! -f "$BINARY_METADATA_FILE" ]; then
        return
    fi
    if command -v jq >/dev/null 2>&1; then
        tag=$(jq -r '.tag // empty' "$BINARY_METADATA_FILE" 2>/dev/null || true)
    else
        tag=$(sed -n 's/.*"tag"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$BINARY_METADATA_FILE" | head -n 1)
    fi
    tag=$(printf '%s' "$tag" | tr -d '[:space:]')
    [ "$tag" != "null" ] && printf '%s\n' "$tag"
}

get_current_rebecca_version() {
    local version=""
    local metadata_version=""
    if [ -f "$CHANNEL_FILE" ]; then
        version=$(tr -d '[:space:]' < "$CHANNEL_FILE")
    fi
    metadata_version=$(read_binary_metadata_tag)
    if [ -n "$metadata_version" ] && { [ -z "$version" ] || [ "$version" = "dev" ] || [ "$version" = "latest" ]; }; then
        version="$metadata_version"
    fi
    printf '%s\n' "${version:-unknown}"
}



get_xray_runtime_status() {
    echo "managed-by-firenode"
}

print_menu_status_summary() {
    local service_status="stopped"
    local version xray_status
    if systemctl is-active --quiet "$APP_NAME.service" 2>/dev/null; then
        service_status="running"
    fi
    version=$(get_current_rebecca_version)
    xray_status=$(get_xray_runtime_status)
    ui_status_row "Version" "${version}"
    ui_status_row "Service" "${service_status}"
    ui_status_row "Mode" "$(get_install_mode)"
    ui_status_row "Xray" "${xray_status}"
}

set_rebecca_source_ref() {
    local ref="${1:-dev}"
    FIREBAN_REF="$ref"
}

set_rebecca_source_for_version() {
    case "${1:-latest}" in
        dev)
            set_rebecca_source_ref "$FIREBAN_BINARY_DEV_BRANCH"
            ;;
        dev-*)
            set_rebecca_source_ref "$FIREBAN_BINARY_DEV_BRANCH"
            ;;
        v[0-9]*)
            set_rebecca_source_ref "$1"
            ;;
        *)
            set_rebecca_source_ref "$FIREBAN_BINARY_DEV_BRANCH"
            ;;
    esac
}

check_running_as_root() {
    if [ "$(id -u)" != "0" ]; then
        colorized_echo red "This command must be run as root."
        exit 1
    fi
}

detect_os() {
    # Detect the operating system
    if [ -f /etc/lsb-release ]; then
        OS=$(lsb_release -si)
    elif [ -f /etc/os-release ]; then
        OS=$(awk -F= '/^NAME/{print $2}' /etc/os-release | tr -d '"')
    elif [ -f /etc/redhat-release ]; then
        OS=$(cat /etc/redhat-release | awk '{print $1}')
    elif [ -f /etc/arch-release ]; then
        OS="Arch"
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}

remove_broken_xanmod_apt_sources() {
    local matches
    matches=$(grep -RIlE 'deb\.xanmod\.org|xanmod\.org' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true)
    if [ -z "$matches" ]; then
        return 1
    fi
    colorized_echo yellow "Removing broken XanMod apt source entries"
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        case "$file" in
            /etc/apt/sources.list)
                sed -i.bak '/deb\.xanmod\.org/d;/xanmod\.org/d' "$file"
            ;;
            /etc/apt/sources.list.d/*)
                rm -f "$file"
            ;;
        esac
    done <<< "$matches"
    return 0
}

apt_update_with_repo_repair() {
    local log_file
    log_file=$(mktemp)
    if DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a "$PKG_MANAGER" "$@" update -qq >"$log_file" 2>&1; then
        rm -f "$log_file"
        return 0
    fi
    cat "$log_file" >&2
    if grep -qiE 'deb\.xanmod\.org|xanmod.*release file|does not have a release file' "$log_file" && remove_broken_xanmod_apt_sources; then
        rm -f "$log_file"
        DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a "$PKG_MANAGER" "$@" update -qq
        return
    fi
    rm -f "$log_file"
    return 1
}


detect_and_update_package_manager() {
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        PKG_MANAGER="apt-get"
        ui_spinner_run "Updating package index" apt_update_with_repo_repair -o Acquire::AllowReleaseInfoChange=true -o Acquire::AllowReleaseInfoChange::Label=true
    elif [[ "$OS" == "CentOS"* ]] || [[ "$OS" == "AlmaLinux"* ]]; then
        PKG_MANAGER="yum"
        ui_spinner_run "Updating package index" "$PKG_MANAGER" update -y -q
        ui_spinner_run "Installing EPEL repository" "$PKG_MANAGER" install -y -q epel-release
    elif [ "$OS" == "Fedora"* ]; then
        PKG_MANAGER="dnf"
        ui_spinner_run "Updating package index" "$PKG_MANAGER" update -q -y
    elif [ "$OS" == "Arch" ]; then
        PKG_MANAGER="pacman"
        ui_spinner_run "Updating package index" "$PKG_MANAGER" -Sy --noconfirm --quiet
    elif [[ "$OS" == "openSUSE"* ]]; then
        PKG_MANAGER="zypper"
        ui_spinner_run "Updating package index" "$PKG_MANAGER" refresh --quiet
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}

install_package_impl() {
    local PACKAGE="$1"
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a $PKG_MANAGER -y -qq install "$PACKAGE" \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold"
    elif [[ "$OS" == "CentOS"* ]] || [[ "$OS" == "AlmaLinux"* ]]; then
        $PKG_MANAGER install -y -q "$PACKAGE"
    elif [ "$OS" == "Fedora"* ]; then
        $PKG_MANAGER install -y -q "$PACKAGE"
    elif [ "$OS" == "Arch" ]; then
        $PKG_MANAGER -S --noconfirm --quiet "$PACKAGE"
    elif [[ "$OS" == "openSUSE"* ]]; then
        $PKG_MANAGER --quiet install -y "$PACKAGE"
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}

install_package () {
    if [ -z "$PKG_MANAGER" ]; then
        detect_and_update_package_manager
    fi

    local PACKAGE="$1"
    ui_spinner_run "Installing $PACKAGE" install_package_impl "$PACKAGE"
}

ensure_python3_venv() {
    detect_os
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        PY_VER=$(python3 -c 'import sys; print(f"%s.%s" % (sys.version_info.major, sys.version_info.minor))' 2>/dev/null || echo "3")
        install_package "python${PY_VER}-venv"
    else
        install_package python3-venv
    fi
}



normalize_install_mode() {
    local mode
    mode=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    case "$mode" in
        binary|bin|native)
            echo "binary"
            ;;
        "")
            echo ""
            ;;
        *)
            colorized_echo red "Invalid install mode: $1" >&2
            colorized_echo yellow "Valid mode is: binary" >&2
            exit 1
            ;;
    esac
}

script_install_mode() {
    case "${FIREBAN_SCRIPT_FLAVOR:-binary}" in
        binary|bin|native)
            echo "binary"
            ;;
        mixed|"")
            echo ""
            ;;
        *)
            colorized_echo red "Invalid script flavor: $FIREBAN_SCRIPT_FLAVOR" >&2
            exit 1
            ;;
    esac
}

get_install_mode() {
    if [ -f "$INSTALL_MODE_FILE" ]; then
        mode=$(tr -d '[:space:]' < "$INSTALL_MODE_FILE")
        normalize_install_mode "$mode"
        return
    fi

    if [ -x "$BINARY_SERVER" ] || [ -f "$BINARY_SERVICE_UNIT" ]; then
        echo "binary"
        return
    fi

	local forced_mode
	forced_mode=$(script_install_mode)
    if [ -n "$forced_mode" ]; then
        echo "$forced_mode"
        return
    fi

    echo "binary"
}

is_binary_install() {
    [ "$(get_install_mode)" = "binary" ]
}

select_install_mode() {
    local requested_mode
    local forced_mode
    forced_mode=$(script_install_mode)
    requested_mode=$(normalize_install_mode "${1:-${FIREBAN_INSTALL_MODE:-}}")

    if [ -n "$forced_mode" ]; then
        if [ -n "$requested_mode" ] && [ "$requested_mode" != "$forced_mode" ]; then
            colorized_echo red "This script is dedicated to ${forced_mode} installs. Use the matching FireBan script for $requested_mode." >&2
            exit 1
        fi
        echo "$forced_mode"
        return
    fi

    if [ -n "$requested_mode" ]; then
        echo "$requested_mode"
        return
    fi

    echo "binary"
}

select_rebecca_version() {
    local requested_version="${1:-}"
	local install_mode="${2:-binary}"

    if [ -n "$requested_version" ]; then
        echo "$requested_version"
        return
    fi

    if [ ! -t 0 ]; then
        echo "latest"
        return
    fi

    colorized_echo cyan "Select FireBan release channel for ${install_mode} mode:" >&2
    colorized_echo yellow "  1) latest (stable release)" >&2
    colorized_echo yellow "  2) dev (latest successful binary build from branch ${FIREBAN_BINARY_DEV_BRANCH})" >&2
    read -r -p "Release channel [1]: " rebecca_version_answer

    case "$rebecca_version_answer" in
        2|dev|Dev)
            echo "dev"
            ;;
        ""|1|latest|Latest|stable|Stable)
            echo "latest"
            ;;
        *)
            colorized_echo red "Invalid release channel selection."
            exit 1
            ;;
    esac
}

write_rebecca_channel() {
    local channel="${1:-latest}"
    mkdir -p "$APP_DIR"
    echo "$channel" > "$CHANNEL_FILE"
}

get_installed_rebecca_channel() {
    local channel
    local metadata_tag

    if [ -f "$CHANNEL_FILE" ]; then
        channel=$(tr -d '[:space:]' < "$CHANNEL_FILE")
        if [ -n "$channel" ]; then
            echo "$channel"
            return
        fi
    fi

    if [ -f "$BINARY_METADATA_FILE" ]; then
        metadata_tag=$(sed -nE 's/.*"tag"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$BINARY_METADATA_FILE" | head -n 1)
        if [[ "$metadata_tag" == dev-* ]]; then
            echo "dev"
            return
        elif [ -n "$metadata_tag" ] && [ "$metadata_tag" != "latest" ]; then
            echo "$metadata_tag"
            return
        fi
    fi

    echo "latest"
}

install_rebecca_script() {
    local source_version="${1:-}"
    local temp_script
    if [ -n "$source_version" ]; then
        set_rebecca_source_for_version "$source_version"
    elif is_rebecca_installed; then
        set_rebecca_source_for_version "$(get_installed_rebecca_channel)"
    fi
    SCRIPT_URL="$FIREBAN_SCRIPT_BASE_URL/$FIREBAN_SCRIPT_SOURCE_FILE"
    temp_script=$(mktemp)
    ui_spinner_run "Downloading FireBan command script" github_curl -fsSL "$SCRIPT_URL" -o "$temp_script"
    if head -n 1 "$temp_script" | grep -qi "<!DOCTYPE"; then
        rm -f "$temp_script"
        colorized_echo red "Unexpected HTML response while downloading script"
        exit 1
    fi
    ui_spinner_run "Installing FireBan command script" install -m 755 "$temp_script" "$FIREBAN_SCRIPT_INSTALL_PATH"
    rm -f "$temp_script"
    colorized_echo green "FireBan script installed successfully"
}

trim_string() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

validate_domain_format() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        colorized_echo red "Invalid domain: $domain"
        return 1
    fi
    return 0
}

is_valid_ipv4() {
    local ip="$1"
    local IFS='.'
    read -r -a octets <<< "$ip"
    if [ ${#octets[@]} -ne 4 ]; then
        return 1
    fi
    for octet in "${octets[@]}"; do
        if [[ ! "$octet" =~ ^[0-9]+$ ]]; then
            return 1
        fi
        if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
            return 1
        fi
    done
    return 0
}

is_valid_ipv6() {
    local ip="$1"
    if [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$ip" == *:*:* ]]; then
        return 0
    fi
    return 1
}

is_valid_ip() {
    local value="$1"
    if is_valid_ipv4 "$value" || is_valid_ipv6 "$value"; then
        return 0
    fi
    return 1
}

ssl_cert_id_for_name() {
    local value="$1"
    value=$(echo "$value" | tr ':' '_' | tr '/' '_')
    printf '%s' "$value"
}

detect_public_ip() {
    local ip=""
    local urls=(
        "https://api.ipify.org"
        "https://ifconfig.me/ip"
        "https://checkip.amazonaws.com"
    )
    for url in "${urls[@]}"; do
        ip=$(curl -fsS4 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$ip" ] && is_valid_ip "$ip"; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

install_ssl_dependencies() {
    detect_os
    local packages=("curl" "socat" "certbot" "openssl")
    for pkg in "${packages[@]}"; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            install_package "$pkg"
        fi
    done
}

ensure_acme_sh() {
    if [ ! -d "$HOME/.acme.sh" ]; then
        curl https://get.acme.sh | sh -s email="$1"
        if [ -f "$HOME/.bashrc" ]; then
            # shellcheck disable=SC1090
            source "$HOME/.bashrc"
        fi
    fi
}

certbot_supports_ip_certificates() {
    local certbot_bin="$1"
    "$certbot_bin" --help all 2>/dev/null | grep -q -- "--ip-address" \
        && "$certbot_bin" --help all 2>/dev/null | grep -q -- "--preferred-profile"
}

find_certbot_with_ip_support() {
    if command -v certbot >/dev/null 2>&1 && certbot_supports_ip_certificates "$(command -v certbot)"; then
        CERTBOT_BIN="$(command -v certbot)"
        return 0
    fi

    if [ -x "$CERTBOT_VENV_DIR/bin/certbot" ] && certbot_supports_ip_certificates "$CERTBOT_VENV_DIR/bin/certbot"; then
        CERTBOT_BIN="$CERTBOT_VENV_DIR/bin/certbot"
        return 0
    fi

    return 1
}

ensure_certbot_ip_support() {
    if find_certbot_with_ip_support; then
        return 0
    fi

    colorized_echo yellow "Installed certbot does not support IP certificates. Installing a modern certbot in $CERTBOT_VENV_DIR"
    detect_os
    if ! command -v python3 >/dev/null 2>&1; then
        install_package python3
    fi
    ensure_python3_venv
    python3 -m venv "$CERTBOT_VENV_DIR"
    "$CERTBOT_VENV_DIR/bin/python" -m pip install --upgrade pip >/dev/null
    "$CERTBOT_VENV_DIR/bin/python" -m pip install --upgrade "certbot>=5.4.0" >/dev/null

    if ! certbot_supports_ip_certificates "$CERTBOT_VENV_DIR/bin/certbot"; then
        colorized_echo red "The installed certbot still does not support --ip-address and --preferred-profile."
        return 1
    fi

    CERTBOT_BIN="$CERTBOT_VENV_DIR/bin/certbot"
    return 0
}

SSL_CERT_DIR=""

issue_ssl_with_acme() {
    local email="$1"
    shift
    local domains=("$@")
    ensure_acme_sh "$email"

    local args=""
    for domain in "${domains[@]}"; do
        args+=" -d $domain"
    done

    ~/.acme.sh/acme.sh --issue --standalone $args --accountemail "$email" || return 1

    local primary="${domains[0]}"
    SSL_CERT_DIR="$CERTS_BASE/$primary"
    mkdir -p "$SSL_CERT_DIR"

    ~/.acme.sh/acme.sh --install-cert -d "$primary" \
        --key-file "$SSL_CERT_DIR/privkey.pem" \
        --fullchain-file "$SSL_CERT_DIR/fullchain.pem" || return 1

    echo "provider=acme" > "$SSL_CERT_DIR/.metadata"
    echo "email=$email" >> "$SSL_CERT_DIR/.metadata"
    echo "domains=${domains[*]}" >> "$SSL_CERT_DIR/.metadata"
    echo "issued_at=$(date -u +%s)" >> "$SSL_CERT_DIR/.metadata"
    return 0
}

issue_ssl_with_certbot() {
    local email="$1"
    shift
    local domains=("$@")

    local args=""
    for domain in "${domains[@]}"; do
        args+=" -d $domain"
    done

    certbot certonly --standalone $args --non-interactive --agree-tos --email "$email" || return 1

    local primary="${domains[0]}"
    SSL_CERT_DIR="$CERTS_BASE/$primary"
    mkdir -p "$SSL_CERT_DIR"

    cat "/etc/letsencrypt/live/$primary/privkey.pem" > "$SSL_CERT_DIR/privkey.pem"
    cat "/etc/letsencrypt/live/$primary/fullchain.pem" > "$SSL_CERT_DIR/fullchain.pem"

    echo "provider=certbot" > "$SSL_CERT_DIR/.metadata"
    echo "email=$email" >> "$SSL_CERT_DIR/.metadata"
    echo "domains=${domains[*]}" >> "$SSL_CERT_DIR/.metadata"
    echo "issued_at=$(date -u +%s)" >> "$SSL_CERT_DIR/.metadata"
    return 0
}

issue_ssl_public_ip() {
    local email="$1"
    shift
    local ips=("$@")

    if [ ${#ips[@]} -eq 0 ]; then
        colorized_echo red "At least one IP address is required for Let's Encrypt IP SSL."
        return 1
    fi

    ensure_certbot_ip_support || return 1

    local primary="${ips[0]}"
    local cert_id
    cert_id=$(ssl_cert_id_for_name "$primary")
    SSL_CERT_DIR="$CERTS_BASE/$cert_id"
    mkdir -p "$SSL_CERT_DIR"

    local certbot_args=(
        certonly
        --standalone
        --non-interactive
        --agree-tos
        --email "$email"
        --preferred-profile shortlived
        --cert-name "$cert_id"
    )
    local ip
    for ip in "${ips[@]}"; do
        certbot_args+=(--ip-address "$ip")
    done

    local deploy_hook
    deploy_hook="mkdir -p '$SSL_CERT_DIR' && cp '/etc/letsencrypt/live/$cert_id/privkey.pem' '$SSL_CERT_DIR/privkey.pem' && cp '/etc/letsencrypt/live/$cert_id/fullchain.pem' '$SSL_CERT_DIR/fullchain.pem' && systemctl restart '$APP_NAME.service' >/dev/null 2>&1 || true"
    certbot_args+=(--deploy-hook "$deploy_hook")

    "$CERTBOT_BIN" "${certbot_args[@]}" || return 1

    cat "/etc/letsencrypt/live/$cert_id/privkey.pem" > "$SSL_CERT_DIR/privkey.pem"
    cat "/etc/letsencrypt/live/$cert_id/fullchain.pem" > "$SSL_CERT_DIR/fullchain.pem"

    echo "provider=letsencrypt-ip" > "$SSL_CERT_DIR/.metadata"
    echo "email=$email" >> "$SSL_CERT_DIR/.metadata"
    echo "domains=${ips[*]}" >> "$SSL_CERT_DIR/.metadata"
    echo "certbot_cert_name=$cert_id" >> "$SSL_CERT_DIR/.metadata"
    echo "validity=shortlived" >> "$SSL_CERT_DIR/.metadata"
    echo "issued_at=$(date -u +%s)" >> "$SSL_CERT_DIR/.metadata"
    return 0
}

issue_ssl_self_signed_ip() {
    local email="$1"
    shift
    local ips=("$@")

    if [ ${#ips[@]} -eq 0 ]; then
        colorized_echo red "At least one IP address is required for self-signed SSL."
        return 1
    fi

    detect_os
    if ! command -v openssl >/dev/null 2>&1; then
        install_package openssl
    fi

    local primary="${ips[0]}"
    local cert_id
    cert_id=$(ssl_cert_id_for_name "$primary")
    SSL_CERT_DIR="$CERTS_BASE/$cert_id"
    mkdir -p "$SSL_CERT_DIR"

    local openssl_conf
    openssl_conf=$(mktemp)
    {
        echo "[ req ]"
        echo "default_bits = 2048"
        echo "prompt = no"
        echo "default_md = sha256"
        echo "req_extensions = v3_req"
        echo "distinguished_name = dn"
        echo
        echo "[ dn ]"
        echo "CN = $primary"
        echo
        echo "[ v3_req ]"
        echo "subjectAltName = @alt_names"
        echo
        echo "[ alt_names ]"
        local idx=1
        for ip in "${ips[@]}"; do
            echo "IP.$idx = $ip"
            idx=$((idx + 1))
        done
    } > "$openssl_conf"

    if ! openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
        -keyout "$SSL_CERT_DIR/privkey.pem" \
        -out "$SSL_CERT_DIR/fullchain.pem" \
        -config "$openssl_conf" >/dev/null 2>&1; then
        rm -f "$openssl_conf"
        colorized_echo red "Failed to generate self-signed certificate."
        return 1
    fi
    rm -f "$openssl_conf"

    echo "provider=self-signed" > "$SSL_CERT_DIR/.metadata"
    echo "email=$email" >> "$SSL_CERT_DIR/.metadata"
    echo "domains=${ips[*]}" >> "$SSL_CERT_DIR/.metadata"
    echo "issued_at=$(date -u +%s)" >> "$SSL_CERT_DIR/.metadata"
    return 0
}

set_env_value() {
    local key="$1"
    local value="$2"
    value=$(echo "$value" | sed 's/^"//;s/"$//')
    mkdir -p "$(dirname "$ENV_FILE")"
    touch "$ENV_FILE"
    if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$ENV_FILE" 2>/dev/null; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=.*|${key} = \"${value}\"|" "$ENV_FILE"
    else
        echo "${key} = \"${value}\"" >> "$ENV_FILE"
    fi
}

get_env_value() {
    local key="$1"
    if [ ! -f "$ENV_FILE" ]; then
        return
    fi
    grep -E "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$ENV_FILE" 2>/dev/null \
        | tail -n 1 \
        | sed -E 's/^[^=]+=//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//'
}

escape_dotenv_double_quoted() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\\$}"
    printf '%s' "$value"
}

upsert_env_assignment() {
    local key="$1"
    local value="$2"
    local escaped_value
    local tmp_env

    escaped_value=$(escape_dotenv_double_quoted "$value")
    mkdir -p "$(dirname "$ENV_FILE")"
    touch "$ENV_FILE"

    tmp_env=$(mktemp)
    grep -vE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$ENV_FILE" > "$tmp_env" || true
    mv "$tmp_env" "$ENV_FILE"

    echo "${key}=\"${escaped_value}\"" >> "$ENV_FILE"
}

urlencode_value() {
    local value="$1"

    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "$value"
        return
    fi

    if command -v python >/dev/null 2>&1; then
        python -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "$value"
        return
    fi

    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$value" | jq -sRr @uri
        return
    fi

    printf '%s' "$value"
}

normalize_url_path() {
    local value="${1:-}"
    local default_value="${2:-dashboard}"
    value=$(echo "$value" | xargs)
    value="${value#/}"
    value="${value%/}"
    if [ -z "$value" ]; then
        value="$default_value"
    fi
    if ! [[ "$value" =~ ^[A-Za-z0-9._~/-]+$ ]]; then
        return 1
    fi
    printf "/%s/" "$value"
}

validate_tcp_port() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] && [ "$value" -le 65535 ]
}

is_tcp_port_listening() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tuln 2>/dev/null | awk '{print $5}' | grep -Eq "(:|\\])${port}$"
        return $?
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
        return $?
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -tuln 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\])${port}$"
        return $?
    fi
    return 1
}

prompt_tcp_port() {
    local label="$1"
    local default_value="$2"
    local value
    while true; do
        printf "%s [%s]: " "$label" "$default_value" >&2
        IFS= read -r value
        value="${value:-$default_value}"
        if validate_tcp_port "$value"; then
            if is_tcp_port_listening "$value"; then
                colorized_echo red "Port $value is already in use. Please choose another port." >&2
                continue
            fi
            printf "%s" "$value"
            return 0
        fi
        colorized_echo red "Port must be a number between 1 and 65535." >&2
    done
}

prompt_url_path() {
    local label="$1"
    local default_value="$2"
    local value normalized
    while true; do
        printf "%s [%s]: " "$label" "$default_value" >&2
        IFS= read -r value
        value="${value:-$default_value}"
        if normalized=$(normalize_url_path "$value" "${default_value#/}"); then
            printf "%s" "$normalized"
            return 0
        fi
        colorized_echo red "Path can contain only letters, numbers, dots, underscores, dashes, slashes, and tildes." >&2
    done
}

print_database_menu() {
    local selected="$1"
    local names=("MySQL" "SQLite" "MariaDB")
    local descriptions=("(recommended)" "" "")
    local idx
    ui_header "FireBan Database" "Choose storage backend for binary install"
    for idx in 1 2 3; do
        printf "  "
        if [ "$idx" -eq "$selected" ]; then
            ui_color "38;5;16;48;5;45;1" " ▶ "
        else
            printf "   "
        fi
        ui_color "38;5;45;1" "$(printf '%2s' "$idx")"
        printf "  "
        if [ "$idx" -eq 1 ]; then
            ui_color "38;5;82;1" "$(printf '%-10s' "${names[$((idx - 1))]}")"
        else
            ui_color "38;5;231;1" "$(printf '%-10s' "${names[$((idx - 1))]}")"
        fi
        ui_color "38;5;245" "${descriptions[$((idx - 1))]}"
        printf "\n"
    done
    printf "\n"
    ui_color "38;5;245" "Use ↑/↓ and Enter, type 1-3, or press Enter for MySQL."
    printf "\n"
}

select_database_type_interactive() {
    local selected=1
    local action kind value
    if ! ui_is_tty; then
        echo "mysql"
        return
    fi
    while true; do
        ui_clear >&2
        print_database_menu "$selected" >&2
        printf "Select database: " >&2
        action=$(ui_read_menu_choice "$selected" 3) || {
            echo "mysql"
            return
        }
        kind="${action%%:*}"
        value="${action#*:}"
        case "$kind" in
            move)
                selected="$value"
            ;;
            enter)
                selected="$value"
                break
            ;;
            value)
                if [[ "$value" =~ ^[1-3]$ ]]; then
                    selected="$value"
                    break
                fi
            ;;
            quit)
                echo "mysql"
                return
            ;;
        esac
    done
    case "$selected" in
        2) echo "sqlite" ;;
        3) echo "mariadb" ;;
        *) echo "mysql" ;;
    esac
}

prompt_dashboard_bind_settings() {
    local port
    if [ ! -t 0 ]; then
        upsert_env_assignment "UVICORN_PORT" "8000"
        return
    fi
    ui_section "Dashboard"
    port=$(prompt_tcp_port "Dashboard port" "8000")
    echo
    upsert_env_assignment "UVICORN_PORT" "$port"
}

mysql_password_is_strong() {
    local password="$1"
    [ "${#password}" -ge 12 ] || return 1
    [[ "$password" =~ [A-Z] ]] || return 1
    [[ "$password" =~ [a-z] ]] || return 1
    [[ "$password" =~ [0-9] ]] || return 1
    [[ "$password" =~ [^A-Za-z0-9] ]] || return 1
    [[ "$password" != *" "* ]] || return 1
    return 0
}

generate_secure_mysql_password() {
    local candidate
    while true; do
        candidate="$(tr -dc 'A-Za-z0-9@#%_=+.-' </dev/urandom | head -c 28)"
        if mysql_password_is_strong "$candidate"; then
            printf "%s" "$candidate"
            return
        fi
    done
}

read_secret() {
    local prompt="$1"
    local value
    if [ -t 0 ]; then
        IFS= read -rsp "$prompt" value
        printf "\n" >&2
    else
        IFS= read -r value
    fi
    printf "%s" "$value"
}

prompt_confirmed_secret() {
    local label="$1"
    local first second
    while true; do
        first=$(read_secret "$label: ")
        [ -n "$first" ] || {
            colorized_echo red "Password cannot be empty." >&2
            continue
        }
        second=$(read_secret "Confirm $label: ")
        if [ "$first" = "$second" ]; then
            printf "%s" "$first"
            return
        fi
        colorized_echo red "Passwords do not match." >&2
    done
}

prompt_initial_admin() {
    INITIAL_ADMIN_CREATE=0
    INITIAL_ADMIN_USERNAME=""
    INITIAL_ADMIN_PASSWORD=""
    [ -t 0 ] || return 0
    ui_section "Initial admin"
    if ! ui_read_yes_no "Create a full-access admin now?" "y"; then
        return
    fi
    while true; do
        IFS= read -r -p "Admin username [admin]: " INITIAL_ADMIN_USERNAME
        INITIAL_ADMIN_USERNAME="${INITIAL_ADMIN_USERNAME:-admin}"
        if [[ "$INITIAL_ADMIN_USERNAME" =~ ^[A-Za-z0-9_.@-]{3,64}$ ]]; then
            break
        fi
        colorized_echo red "Username must be 3-64 chars and may contain letters, numbers, dot, underscore, dash, and @."
    done
    INITIAL_ADMIN_PASSWORD=$(prompt_confirmed_secret "Admin password")
    INITIAL_ADMIN_CREATE=1
}

create_initial_admin_if_requested() {
    if [ "${INITIAL_ADMIN_CREATE:-0}" != "1" ]; then
        return
    fi
    ui_spinner_run "Running database migrations" rebecca_cli migrate up
    ui_spinner_run "Creating full-access admin ${INITIAL_ADMIN_USERNAME}" rebecca_cli admin create "$INITIAL_ADMIN_USERNAME" --role full_access --password "$INITIAL_ADMIN_PASSWORD"
}

prompt_phpmyadmin_settings() {
    PHPMYADMIN_PATH=$(prompt_url_path "phpMyAdmin path" "phpmyadmin")
    echo
}

find_php_fpm_sock() {
    local sock
    sock=$(find /run/php -maxdepth 1 -type s -name 'php*-fpm.sock' 2>/dev/null | sort -V | tail -n 1)
    [ -n "$sock" ] && printf "%s" "$sock"
}

install_phpmyadmin_blueberry_theme() {
    local theme_dir="/usr/share/phpmyadmin/themes"
    local theme_url="https://files.phpmyadmin.net/themes/blueberry/1.1.0/blueberry-1.1.0.zip"
    local temp_zip

    if [ ! -d "$theme_dir" ]; then
        return 0
    fi
    if [ -d "$theme_dir/blueberry" ]; then
        return 0
    fi
    install_package unzip
    temp_zip=$(mktemp)
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$theme_url" -o "$temp_zip" || {
            rm -f "$temp_zip"
            colorized_echo yellow "Could not download phpMyAdmin blueberry theme."
            return 0
        }
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$theme_url" -O "$temp_zip" || {
            rm -f "$temp_zip"
            colorized_echo yellow "Could not download phpMyAdmin blueberry theme."
            return 0
        }
    else
        rm -f "$temp_zip"
        colorized_echo yellow "curl or wget is required to download phpMyAdmin blueberry theme."
        return 0
    fi
    unzip -qo "$temp_zip" -d "$theme_dir" >/dev/null 2>&1 || colorized_echo yellow "Could not extract phpMyAdmin blueberry theme."
    rm -f "$temp_zip"
}

configure_phpmyadmin_upload_limits() {
    local ini_content
    ini_content="upload_max_filesize=4096M
post_max_size=4096M
memory_limit=4096M
max_execution_time=0
max_input_time=0"
    local wrote=0
    local dir
    for dir in /etc/php/*/fpm/conf.d /etc/php/*/cli/conf.d; do
        [ -d "$dir" ] || continue
        printf "%s\n" "$ini_content" > "$dir/99-fireban-phpmyadmin-upload.ini" || true
        wrote=1
    done
    if [ "$wrote" = "1" ]; then
        systemctl reload php*-fpm >/dev/null 2>&1 || systemctl restart php*-fpm >/dev/null 2>&1 || true
    fi
}

phpmyadmin_nginx_config_path() {
    printf "/etc/nginx/sites-available/%s-phpmyadmin" "$APP_NAME"
}

enable_host_phpmyadmin() {
    local database_type
    local path="${1:-}"
    local normalized_path
    local fpm_sock

    database_type=$(get_configured_database_type)
    if [ "$database_type" = "sqlite" ]; then
        colorized_echo red "phpMyAdmin is supported only with MySQL or MariaDB. Current database is SQLite."
        return 1
    fi

    detect_os
    for package in php-fpm php-mysql phpmyadmin; do
        install_package "$package"
    done
    install_phpmyadmin_blueberry_theme
    configure_phpmyadmin_upload_limits
    systemctl enable --now php*-fpm >/dev/null 2>&1 || true

    path="${path:-${PHPMYADMIN_PATH:-phpmyadmin}}"
    normalized_path=$(normalize_url_path "$path" "phpmyadmin") || {
        colorized_echo red "Invalid phpMyAdmin path."
        return 1
    }
    path="$normalized_path"
    path="${path%/}"
    fpm_sock=$(find_php_fpm_sock)
    if [ -z "$fpm_sock" ]; then
        colorized_echo red "Could not find php-fpm socket under /run/php."
        return 1
    fi

    rm -f "/etc/nginx/sites-enabled/${APP_NAME}-phpmyadmin" "$(phpmyadmin_nginx_config_path)"
    if command -v nginx >/dev/null 2>&1; then
        nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    fi
    colorized_echo green "phpMyAdmin is installed and will be served through FireBan using local php-fpm."
}

disable_host_phpmyadmin() {
    rm -f "/etc/nginx/sites-enabled/${APP_NAME}-phpmyadmin" "$(phpmyadmin_nginx_config_path)"
    if command -v nginx >/dev/null 2>&1; then
        nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    fi
    colorized_echo green "phpMyAdmin has been disabled."
}

enable_phpmyadmin() {
    check_running_as_root
    local cli_path=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --port)
                shift 2
                ;;
            --path)
                cli_path="${2:-}"
                shift 2
                ;;
            --yes|-y)
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    if ! is_rebecca_installed; then
        colorized_echo red "FireBan is not installed. Please install FireBan first."
        exit 1
    fi

    if ! is_binary_install; then
        colorized_echo red "phpMyAdmin management from this TUI is available for binary installations only."
        exit 1
    fi

    if [ "$(get_configured_database_type)" = "sqlite" ]; then
        colorized_echo red "phpMyAdmin is not supported for SQLite installations."
        return 0
    fi

    if [ -n "$cli_path" ]; then
        PHPMYADMIN_PATH="$cli_path"
    else
        prompt_phpmyadmin_settings
    fi
    enable_host_phpmyadmin "$PHPMYADMIN_PATH"
}

disable_phpmyadmin() {
    check_running_as_root
    if ! is_binary_install; then
        colorized_echo red "phpMyAdmin management from this TUI is available for binary installations only."
        exit 1
    fi
    disable_host_phpmyadmin
}

sync_ssl_env_paths() {
    local cert_dir="$1"
    local ca_type="${2:-public}"
    set_env_value "UVICORN_SSL_CERTFILE" "$cert_dir/fullchain.pem"
    set_env_value "UVICORN_SSL_KEYFILE" "$cert_dir/privkey.pem"
    set_env_value "UVICORN_SSL_CA_TYPE" "$ca_type"
}

perform_ssl_issue() {
    local email="$1"
    local preferred="${2:-auto}"
    shift 2
    local domains=("$@")
    local provider_used=""
    local has_ip=0
    local has_domain=0

    if [ ${#domains[@]} -eq 0 ]; then
        colorized_echo red "At least one domain is required for SSL issuance."
        return 1
    fi

    for d in "${domains[@]}"; do
        if is_valid_ip "$d"; then
            has_ip=1
        else
            has_domain=1
        fi
    done

    if [ "$has_ip" -eq 1 ] && [ "$has_domain" -eq 1 ]; then
        colorized_echo red "Mixing IP addresses and domains is not supported in one certificate request."
        return 1
    fi

    install_ssl_dependencies
    mkdir -p "$CERTS_BASE"

    if [ "$has_ip" -eq 1 ]; then
        if [ "$has_domain" -eq 1 ]; then
            colorized_echo red "IP certificates cannot be mixed with domain names."
            return 1
        fi
        case "$preferred" in
            letsencrypt-ip|ip|public-ip|shortlived|certbot-ip)
                issue_ssl_public_ip "$email" "${domains[@]}" || return 1
                provider_used="letsencrypt-ip"
                sync_ssl_env_paths "$SSL_CERT_DIR" "public"
                colorized_echo green "Public short-lived IP SSL certificate installed at $SSL_CERT_DIR for IP(s): ${domains[*]}"
                ;;
            auto|self-signed)
                issue_ssl_self_signed_ip "$email" "${domains[@]}" || return 1
                provider_used="self-signed"
                sync_ssl_env_paths "$SSL_CERT_DIR" "self-signed"
                colorized_echo green "Self-signed SSL certificate generated at $SSL_CERT_DIR for IP(s): ${domains[*]}"
                ;;
            *)
                colorized_echo red "IP SSL requires --provider letsencrypt-ip or --provider self-signed."
                return 1
                ;;
        esac
        
        if is_rebecca_installed; then
            if is_rebecca_up; then
                colorized_echo blue "Restarting FireBan to apply SSL configuration..."
                down_rebecca
                up_rebecca
                colorized_echo green "FireBan restarted with SSL configuration"
            fi
        fi
        
        return 0
    fi

    if [ "$preferred" = "self-signed" ] || [ "$preferred" = "letsencrypt-ip" ] || [ "$preferred" = "ip" ] || [ "$preferred" = "public-ip" ] || [ "$preferred" = "shortlived" ] || [ "$preferred" = "certbot-ip" ]; then
        colorized_echo red "Provider $preferred is only valid for IP address certificates."
        return 1
    fi

    if [ "$preferred" = "acme" ]; then
        issue_ssl_with_acme "$email" "${domains[@]}" || return 1
        provider_used="acme"
    elif [ "$preferred" = "certbot" ]; then
        issue_ssl_with_certbot "$email" "${domains[@]}" || return 1
        provider_used="certbot"
    else
        if issue_ssl_with_acme "$email" "${domains[@]}"; then
            provider_used="acme"
        else
            colorized_echo yellow "acme.sh issuance failed, falling back to certbot..."
            issue_ssl_with_certbot "$email" "${domains[@]}" || return 1
            provider_used="certbot"
        fi
    fi

    sync_ssl_env_paths "$SSL_CERT_DIR"
    colorized_echo green "SSL certificate installed at $SSL_CERT_DIR using $provider_used"
    
    # Check if FireBan is installed and running, then restart to apply SSL changes
    if is_rebecca_installed; then
        if is_rebecca_up; then
            colorized_echo blue "Restarting FireBan to apply SSL configuration..."
            down_rebecca
            up_rebecca
            colorized_echo green "FireBan restarted with SSL configuration"
        fi
    fi
    
    return 0
}

parse_domains_input() {
    local input="$1"
    PARSED_DOMAINS=()
    PARSED_IS_IP=0
    local has_ip=0
    local has_domain=0
    IFS=',' read -ra raw_domains <<< "$input"
    for entry in "${raw_domains[@]}"; do
        local domain
        domain=$(trim_string "$entry")
        if [ -z "$domain" ]; then
            continue
        fi
        if is_valid_ip "$domain"; then
            has_ip=1
        else
            validate_domain_format "$domain" || return 1
            has_domain=1
        fi
        PARSED_DOMAINS+=("$domain")
    done
    if [ ${#PARSED_DOMAINS[@]} -eq 0 ]; then
        colorized_echo red "No valid domains provided."
        return 1
    fi
    if [ "$has_ip" -eq 1 ] && [ "$has_domain" -eq 1 ]; then
        colorized_echo red "Cannot mix IP addresses and domains in one request."
        return 1
    fi
    if [ "$has_ip" -eq 1 ]; then
        PARSED_IS_IP=1
    fi
}

prompt_ssl_setup() {
    [ -t 0 ] || return 0
    read -p "Do you want to configure SSL certificates now? (y/N): " ssl_answer
    if [[ ! "$ssl_answer" =~ ^[Yy]$ ]]; then
        return
    fi

    colorized_echo cyan "Select SSL certificate type:"
    echo "  1) Domain certificate (Let's Encrypt, regular public SSL)"
    echo "  2) Temporary public IP certificate (Let's Encrypt short-lived, about 6 days)"
    echo "  3) Self-signed IP certificate (browser warning, local fallback)"
    read -p "Select option [1]: " ssl_mode
    ssl_mode="${ssl_mode:-1}"

    read -p "Enter email for certificate notifications: " ssl_email

    local ssl_domains=""
    local ssl_provider="auto"
    case "$ssl_mode" in
        2)
            local detected_ip=""
            detected_ip=$(detect_public_ip || true)
            if [ -n "$detected_ip" ]; then
                read -p "Enter server public IP [$detected_ip]: " ssl_domains
                ssl_domains="${ssl_domains:-$detected_ip}"
            else
                read -p "Enter server public IP: " ssl_domains
            fi
            ssl_provider="letsencrypt-ip"
            ;;
        3)
            local detected_self_ip=""
            detected_self_ip=$(detect_public_ip || true)
            if [ -n "$detected_self_ip" ]; then
                read -p "Enter server IP [$detected_self_ip]: " ssl_domains
                ssl_domains="${ssl_domains:-$detected_self_ip}"
            else
                read -p "Enter server IP: " ssl_domains
            fi
            ssl_provider="self-signed"
            ;;
        *)
            read -p "Enter domain(s) separated by comma: " ssl_domains
            ssl_provider="auto"
            ;;
    esac

    if ! ssl_command issue --email "$ssl_email" --domains "$ssl_domains" --provider "$ssl_provider" --non-interactive; then
        colorized_echo yellow "SSL setup skipped due to input/issuance error. You can retry with: fireban ssl issue"
    fi
}

ssl_issue() {
    local email=""
    local domains_input=""
    local ip_input=""
    local provider="auto"
    local interactive=true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --email=*)
                email="${1#*=}"
                shift
                ;;
            --email)
                email="$2"
                shift 2
                ;;
            --domains=*)
                domains_input="${1#*=}"
                shift
                ;;
            --domains)
                domains_input="$2"
                shift 2
                ;;
            --ip-address=*|--ip=*)
                ip_input="${1#*=}"
                if [ "$provider" = "auto" ]; then
                    provider="letsencrypt-ip"
                fi
                shift
                ;;
            --ip-address|--ip)
                ip_input="$2"
                if [ "$provider" = "auto" ]; then
                    provider="letsencrypt-ip"
                fi
                shift 2
                ;;
            --provider=*)
                provider="${1#*=}"
                shift
                ;;
            --provider)
                provider="$2"
                shift 2
                ;;
            --non-interactive)
                interactive=false
                shift
                ;;
            *)
                colorized_echo red "Unknown option: $1"
                return 1
                ;;
        esac
    done

    if [ -n "$ip_input" ]; then
        domains_input="$ip_input"
    fi

    if [ "$interactive" = true ]; then
        if [ -z "$email" ]; then
            read -p "Enter email address: " email
        fi
        if [ -z "$domains_input" ]; then
            read -p "Enter domain(s) or IP address(es) separated by comma: " domains_input
        fi
    else
        if [ -z "$email" ] || [ -z "$domains_input" ]; then
            colorized_echo red "Email and domains/IP addresses are required when using non-interactive mode."
            return 1
        fi
    fi

    parse_domains_input "$domains_input" || return 1
    perform_ssl_issue "$email" "$provider" "${PARSED_DOMAINS[@]}"
}

get_domain_from_env() {
    if [ ! -f "$ENV_FILE" ]; then
        return
    fi
    local line
    line=$(grep "^UVICORN_SSL_CERTFILE" "$ENV_FILE" | tail -n 1 | cut -d'=' -f2-)
    line=$(echo "$line" | tr -d ' "')
    if [ -z "$line" ]; then
        return
    fi
    basename "$(dirname "$line")"
}

ssl_renew() {
    local target_domain=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain=*)
                target_domain="${1#*=}"
                shift
                ;;
            --domain)
                target_domain="$2"
                shift 2
                ;;
            *)
                colorized_echo red "Unknown option: $1"
                return 1
                ;;
        esac
    done

    if [ -z "$target_domain" ]; then
        target_domain=$(get_domain_from_env)
    fi

    if [ -z "$target_domain" ]; then
        colorized_echo red "Unable to detect domain. Please specify --domain example.com"
        return 1
    fi

    local metadata="$CERTS_BASE/$target_domain/.metadata"
    if [ ! -f "$metadata" ]; then
        colorized_echo red "Metadata not found for domain $target_domain"
        return 1
    fi

    local provider email domains_line
    provider=$(grep '^provider=' "$metadata" | cut -d'=' -f2-)
    email=$(grep '^email=' "$metadata" | cut -d'=' -f2-)
    domains_line=$(grep '^domains=' "$metadata" | cut -d'=' -f2-)

    if [ -z "$email" ] || [ -z "$domains_line" ]; then
        colorized_echo red "Metadata is incomplete for $target_domain"
        return 1
    fi

    read -ra stored_domains <<< "$domains_line"
    perform_ssl_issue "$email" "$provider" "${stored_domains[@]}" || return 1
    colorized_echo green "SSL certificate renewed for $target_domain"
    
    # Note: perform_ssl_issue already restarts FireBan if needed
}

ssl_command() {
    local action="$1"
    shift || true

    case "$action" in
        issue)
            ssl_issue "$@"
            ;;
        renew)
            ssl_renew "$@"
            ;;
        *)
            colorized_echo blue "Usage: fireban ssl <issue|renew> [options]"
            colorized_echo magenta "  Issue domain SSL: fireban ssl issue --email you@example.com --domains example.com"
            colorized_echo magenta "  Issue public IP SSL: fireban ssl issue --email you@example.com --ip-address 203.0.113.10"
            colorized_echo magenta "  Issue self-signed IP SSL: fireban ssl issue --email you@example.com --domains 203.0.113.10 --provider self-signed"
            ;;
    esac
}

ensure_script_matches_installed_mode() {
    local forced_mode
    local installed_mode
    forced_mode=$(script_install_mode)
    if [ -z "$forced_mode" ] || [ ! -d "$APP_DIR" ]; then
        return
    fi
    installed_mode=$(get_install_mode)
	if [ "$installed_mode" != "$forced_mode" ]; then
		colorized_echo red "This FireBan installation is in ${installed_mode} mode, but ${0##*/} is the ${forced_mode} script."
		colorized_echo yellow "Use the FireBan binary script."
		exit 1
	fi
}

is_rebecca_installed() {
    if [ -d $APP_DIR ]; then
        return 0
    else
        return 1
    fi
}

identify_the_operating_system_and_architecture() {
    if [[ "$(uname)" == 'Linux' ]]; then
        case "$(uname -m)" in
            'i386' | 'i686')
                ARCH='32'
            ;;
            'amd64' | 'x86_64')
                ARCH='64'
            ;;
            'armv5tel')
                ARCH='arm32-v5'
            ;;
            'armv6l')
                ARCH='arm32-v6'
                grep Features /proc/cpuinfo | grep -qw 'vfp' || ARCH='arm32-v5'
            ;;
            'armv7' | 'armv7l')
                ARCH='arm32-v7a'
                grep Features /proc/cpuinfo | grep -qw 'vfp' || ARCH='arm32-v5'
            ;;
            'armv8' | 'aarch64')
                ARCH='arm64-v8a'
            ;;
            'mips')
                ARCH='mips32'
            ;;
            'mipsle')
                ARCH='mips32le'
            ;;
            'mips64')
                ARCH='mips64'
                lscpu | grep -q "Little Endian" && ARCH='mips64le'
            ;;
            'mips64le')
                ARCH='mips64le'
            ;;
            'ppc64')
                ARCH='ppc64'
            ;;
            'ppc64le')
                ARCH='ppc64le'
            ;;
            'riscv64')
                ARCH='riscv64'
            ;;
            's390x')
                ARCH='s390x'
            ;;
            *)
                echo "error: The architecture is not supported."
                exit 1
            ;;
        esac
    else
        echo "error: This operating system is not supported."
        exit 1
    fi
}

send_backup_to_telegram() {
    if [ -f "$ENV_FILE" ]; then
        while IFS='=' read -r key value; do
            if [[ -z "$key" || "$key" =~ ^# ]]; then
                continue
            fi
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            if [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
                export "$key"="$value"
            else
                colorized_echo yellow "Skipping invalid line in .env: $key=$value"
            fi
        done < "$ENV_FILE"
    else
        colorized_echo red "Environment file (.env) not found."
        exit 1
    fi

    if [ "$BACKUP_SERVICE_ENABLED" != "true" ]; then
        colorized_echo yellow "Backup service is not enabled. Skipping Telegram upload."
        return
    fi

    local server_ip=$(curl -s ifconfig.me || echo "Unknown IP")
    local latest_backup=$(ls -t "$APP_DIR/backup" | head -n 1)
    local backup_path="$APP_DIR/backup/$latest_backup"

    if [ ! -f "$backup_path" ]; then
        colorized_echo red "No backups found to send."
        return
    fi

    local backup_size=$(du -m "$backup_path" | cut -f1)
    local split_dir="/tmp/rebecca_backup_split"
    local is_single_file=true

    mkdir -p "$split_dir"

    if [ "$backup_size" -gt 49 ]; then
        colorized_echo yellow "Backup is larger than 49MB. Splitting the archive..."
        split -b 49M "$backup_path" "$split_dir/part_"
        is_single_file=false
    else
        cp "$backup_path" "$split_dir/part_aa"
    fi


    local backup_time=$(date "+%Y-%m-%d %H:%M:%S %Z")


    for part in "$split_dir"/*; do
        local part_name=$(basename "$part")
        local custom_filename="backup_${part_name}.tar.gz"
        local caption="📦 *Backup Information*\n🌐 *Server IP*: \`${server_ip}\`\n📁 *Backup File*: \`${custom_filename}\`\n⏰ *Backup Time*: \`${backup_time}\`"
        curl -s -F chat_id="$BACKUP_TELEGRAM_CHAT_ID" \
            -F document=@"$part;filename=$custom_filename" \
            -F caption="$(echo -e "$caption" | sed 's/-/\\-/g;s/\./\\./g;s/_/\\_/g')" \
            -F parse_mode="MarkdownV2" \
            "https://api.telegram.org/bot$BACKUP_TELEGRAM_BOT_KEY/sendDocument" >/dev/null 2>&1 && \
        colorized_echo green "Backup part $custom_filename successfully sent to Telegram." || \
        colorized_echo red "Failed to send backup part $custom_filename to Telegram."
    done

    rm -rf "$split_dir"
}

send_backup_error_to_telegram() {
    local error_messages=$1
    local log_file=$2
    local server_ip=$(curl -s ifconfig.me || echo "Unknown IP")
    local error_time=$(date "+%Y-%m-%d %H:%M:%S %Z")
    local message="⚠️ *Backup Error Notification*\n"
    message+="🌐 *Server IP*: \`${server_ip}\`\n"
    message+="❌ *Errors*:\n\`${error_messages//_/\\_}\`\n"
    message+="⏰ *Time*: \`${error_time}\`"


    message=$(echo -e "$message" | sed 's/-/\\-/g;s/\./\\./g;s/_/\\_/g;s/(/\\(/g;s/)/\\)/g')

    local max_length=1000
    if [ ${#message} -gt $max_length ]; then
        message="${message:0:$((max_length - 50))}...\n\`[Message truncated]\`"
    fi


    curl -s -X POST "https://api.telegram.org/bot$BACKUP_TELEGRAM_BOT_KEY/sendMessage" \
        -d chat_id="$BACKUP_TELEGRAM_CHAT_ID" \
        -d parse_mode="MarkdownV2" \
        -d text="$message" >/dev/null 2>&1 && \
    colorized_echo green "Backup error notification sent to Telegram." || \
    colorized_echo red "Failed to send error notification to Telegram."


    if [ -f "$log_file" ]; then
        response=$(curl -s -w "%{http_code}" -o /tmp/tg_response.json \
            -F chat_id="$BACKUP_TELEGRAM_CHAT_ID" \
            -F document=@"$log_file;filename=backup_error.log" \
            -F caption="📜 *Backup Error Log* - ${error_time}" \
            "https://api.telegram.org/bot$BACKUP_TELEGRAM_BOT_KEY/sendDocument")

        http_code="${response:(-3)}"
        if [ "$http_code" -eq 200 ]; then
            colorized_echo green "Backup error log sent to Telegram."
        else
            colorized_echo red "Failed to send backup error log to Telegram. HTTP code: $http_code"
            cat /tmp/tg_response.json
        fi
    else
        colorized_echo red "Log file not found: $log_file"
    fi
}





backup_service() {
    local telegram_bot_key=""
    local telegram_chat_id=""
    local cron_schedule=""
    local interval_hours=""

    colorized_echo blue "====================================="
    colorized_echo blue "      Welcome to Backup Service      "
    colorized_echo blue "====================================="

    if grep -q "BACKUP_SERVICE_ENABLED=true" "$ENV_FILE"; then
        telegram_bot_key=$(awk -F'=' '/^BACKUP_TELEGRAM_BOT_KEY=/ {print $2}' "$ENV_FILE")
        telegram_chat_id=$(awk -F'=' '/^BACKUP_TELEGRAM_CHAT_ID=/ {print $2}' "$ENV_FILE")
        cron_schedule=$(awk -F'=' '/^BACKUP_CRON_SCHEDULE=/ {print $2}' "$ENV_FILE" | tr -d '"')

        if [[ "$cron_schedule" == "0 0 * * *" ]]; then
            interval_hours=24
        else
            interval_hours=$(echo "$cron_schedule" | grep -oP '(?<=\*/)[0-9]+')
        fi

        colorized_echo green "====================================="
        colorized_echo green "Current Backup Configuration:"
        colorized_echo cyan "Telegram Bot API Key: $telegram_bot_key"
        colorized_echo cyan "Telegram Chat ID: $telegram_chat_id"
        colorized_echo cyan "Backup Interval: Every $interval_hours hour(s)"
        colorized_echo green "====================================="
        echo "Choose an option:"
        echo "1. Reconfigure Backup Service"
        echo "2. Remove Backup Service"
        echo "3. Exit"
        read -p "Enter your choice (1-3): " user_choice

        case $user_choice in
            1)
                colorized_echo yellow "Starting reconfiguration..."
                remove_backup_service
                ;;
            2)
                colorized_echo yellow "Removing Backup Service..."
                remove_backup_service
                return
                ;;
            3)
                colorized_echo yellow "Exiting..."
                return
                ;;
            *)
                colorized_echo red "Invalid choice. Exiting."
                return
                ;;
        esac
    else
        colorized_echo yellow "No backup service is currently configured."
    fi

    while true; do
        printf "Enter your Telegram bot API key: "
        read telegram_bot_key
        if [[ -n "$telegram_bot_key" ]]; then
            break
        else
            colorized_echo red "API key cannot be empty. Please try again."
        fi
    done

    while true; do
        printf "Enter your Telegram chat ID: "
        read telegram_chat_id
        if [[ -n "$telegram_chat_id" ]]; then
            break
        else
            colorized_echo red "Chat ID cannot be empty. Please try again."
        fi
    done

    while true; do
        printf "Set up the backup interval in hours (1-24):\n"
        read interval_hours

        if ! [[ "$interval_hours" =~ ^[0-9]+$ ]]; then
            colorized_echo red "Invalid input. Please enter a valid number."
            continue
        fi

        if [[ "$interval_hours" -eq 24 ]]; then
            cron_schedule="0 0 * * *"
            colorized_echo green "Setting backup to run daily at midnight."
            break
        fi

        if [[ "$interval_hours" -ge 1 && "$interval_hours" -le 23 ]]; then
            cron_schedule="0 */$interval_hours * * *"
            colorized_echo green "Setting backup to run every $interval_hours hour(s)."
            break
        else
            colorized_echo red "Invalid input. Please enter a number between 1-24."
        fi
    done

    sed -i '/^BACKUP_SERVICE_ENABLED/d' "$ENV_FILE"
    sed -i '/^BACKUP_TELEGRAM_BOT_KEY/d' "$ENV_FILE"
    sed -i '/^BACKUP_TELEGRAM_CHAT_ID/d' "$ENV_FILE"
    sed -i '/^BACKUP_CRON_SCHEDULE/d' "$ENV_FILE"

    {
        echo ""
        echo "# Backup service configuration"
        echo "BACKUP_SERVICE_ENABLED=true"
        echo "BACKUP_TELEGRAM_BOT_KEY=$telegram_bot_key"
        echo "BACKUP_TELEGRAM_CHAT_ID=$telegram_chat_id"
        echo "BACKUP_CRON_SCHEDULE=\"$cron_schedule\""
    } >> "$ENV_FILE"

    colorized_echo green "Backup service configuration saved in $ENV_FILE."

    local backup_command
    backup_command="$(backup_cron_command)"
    add_cron_job "$cron_schedule" "$backup_command"

    colorized_echo green "Backup service successfully configured."
    if [[ "$interval_hours" -eq 24 ]]; then
        colorized_echo cyan "Backups will be sent to Telegram daily (every 24 hours at midnight)."
    else
        colorized_echo cyan "Backups will be sent to Telegram every $interval_hours hour(s)."
    fi
    colorized_echo green "====================================="
}


add_cron_job() {
    local schedule="$1"
    local command="$2"
    local temp_cron=$(mktemp)

    crontab -l 2>/dev/null > "$temp_cron" || true
    sed -i '/# rebecca-backup-service/d; /# fireban-backup-service/d' "$temp_cron"
    echo "$schedule $command # fireban-backup-service" >> "$temp_cron"
    
    if crontab "$temp_cron"; then
        colorized_echo green "Cron job successfully added."
    else
        colorized_echo red "Failed to add cron job. Please check manually."
    fi
    rm -f "$temp_cron"
}

remove_backup_service() {
    colorized_echo red "in process..."


    sed -i '/^# Backup service configuration/d' "$ENV_FILE"
    sed -i '/BACKUP_SERVICE_ENABLED/d' "$ENV_FILE"
    sed -i '/BACKUP_TELEGRAM_BOT_KEY/d' "$ENV_FILE"
    sed -i '/BACKUP_TELEGRAM_CHAT_ID/d' "$ENV_FILE"
    sed -i '/BACKUP_CRON_SCHEDULE/d' "$ENV_FILE"

    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null > "$temp_cron"

    sed -i '/# rebecca-backup-service/d; /# fireban-backup-service/d' "$temp_cron"

    if crontab "$temp_cron"; then
        colorized_echo green "Backup service task removed from crontab."
    else
        colorized_echo red "Failed to update crontab. Please check manually."
    fi

    rm -f "$temp_cron"

    colorized_echo green "Backup service has been removed."
}

backup_cron_command() {
    local script_path="${FIREBAN_SCRIPT_INSTALL_PATH:-}"
    if [ -z "$script_path" ] || [ ! -x "$script_path" ]; then
        script_path="$(command -v "$APP_NAME" 2>/dev/null || true)"
    fi
    if [ -z "$script_path" ]; then
        script_path="/usr/local/bin/$APP_NAME"
    fi
    printf '%s backup' "$script_path"
}

backup_strip_quotes() {
    local value="$1"
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"
    printf '%s' "$value"
}

backup_url_decode() {
    local value="$1"
    value="${value//%/\\x}"
    printf '%b' "$value"
}

backup_parse_database_url() {
    local raw
    raw="$(backup_strip_quotes "$1")"
    BACKUP_DB_TYPE=""
    BACKUP_SQLITE_FILE=""
    BACKUP_DB_USER=""
    BACKUP_DB_PASSWORD=""
    BACKUP_DB_HOST=""
    BACKUP_DB_PORT=""
    BACKUP_DB_NAME=""
    BACKUP_DB_SOCKET=""

    case "$raw" in
        sqlite:///*)
            BACKUP_DB_TYPE="sqlite"
            BACKUP_SQLITE_FILE="${raw#sqlite:///}"
            if [[ ! "$BACKUP_SQLITE_FILE" =~ ^/ ]]; then
                BACKUP_SQLITE_FILE="/$BACKUP_SQLITE_FILE"
            fi
            return 0
            ;;
        mysql*://*|mariadb*://*)
            BACKUP_DB_TYPE="mysql"
            local rest="${raw#*://}"
            local authority="${rest%%/*}"
            local path_query="${rest#*/}"
            local query=""
            BACKUP_DB_NAME="${path_query%%\?*}"
            if [[ "$path_query" == *"?"* ]]; then
                query="${path_query#*\?}"
            fi
            if [[ "$authority" == *"@"* ]]; then
                local credentials="${authority%@*}"
                local hostport="${authority##*@}"
                BACKUP_DB_USER="$(backup_url_decode "${credentials%%:*}")"
                if [[ "$credentials" == *":"* ]]; then
                    BACKUP_DB_PASSWORD="$(backup_url_decode "${credentials#*:}")"
                fi
                authority="$hostport"
            fi
            if [[ "$authority" == *":"* ]]; then
                BACKUP_DB_HOST="${authority%%:*}"
                BACKUP_DB_PORT="${authority##*:}"
            else
                BACKUP_DB_HOST="$authority"
                BACKUP_DB_PORT="3306"
            fi
            BACKUP_DB_HOST="${BACKUP_DB_HOST:-127.0.0.1}"
            BACKUP_DB_PORT="${BACKUP_DB_PORT:-3306}"
            BACKUP_DB_NAME="$(backup_url_decode "$BACKUP_DB_NAME")"
            if [ -n "$query" ]; then
                IFS='&' read -ra query_parts <<< "$query"
                for query_part in "${query_parts[@]}"; do
                    case "$query_part" in
                        unix_socket=*|socket=*)
                            BACKUP_DB_SOCKET="$(backup_url_decode "${query_part#*=}")"
                            ;;
                    esac
                done
            fi
            [ -n "$BACKUP_DB_NAME" ]
            return
            ;;
    esac
    return 1
}

write_mysql_backup_defaults() {
    local defaults_file="$1"
    {
        echo "[client]"
        [ -n "${BACKUP_DB_USER:-}" ] && printf 'user="%s"\n' "${BACKUP_DB_USER//\"/\\\"}"
        [ -n "${BACKUP_DB_PASSWORD:-}" ] && printf 'password="%s"\n' "${BACKUP_DB_PASSWORD//\"/\\\"}"
        if [ -n "${BACKUP_DB_SOCKET:-}" ]; then
            printf 'socket="%s"\n' "${BACKUP_DB_SOCKET//\"/\\\"}"
        else
            printf 'host="%s"\n' "${BACKUP_DB_HOST:-127.0.0.1}"
            printf 'port=%s\n' "${BACKUP_DB_PORT:-3306}"
            echo "protocol=tcp"
        fi
    } > "$defaults_file"
    chmod 600 "$defaults_file"
}

backup_command() {
    local backup_dir="$APP_DIR/backup"
    local temp_dir="/tmp/rebecca_backup"
    local timestamp=$(date +"%Y%m%d%H%M%S")
    local backup_file="$backup_dir/backup_$timestamp.tar.gz"
    local error_messages=()
    local log_file="/var/log/rebecca_backup_error.log"
    > "$log_file"
    echo "Backup Log - $(date)" > "$log_file"

    if ! command -v rsync >/dev/null 2>&1; then
        detect_os
        install_package rsync
    fi

    rm -rf "$backup_dir"
    mkdir -p "$backup_dir"
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir"

    if [ -f "$ENV_FILE" ]; then
        while IFS='=' read -r key value; do
            if [[ -z "$key" || "$key" =~ ^# ]]; then
                continue
            fi
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            if [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
                export "$key"="$value"
            else
                echo "Skipping invalid line in .env: $key=$value" >> "$log_file"
            fi
        done < "$ENV_FILE"
    else
        error_messages+=("Environment file (.env) not found.")
        echo "Environment file (.env) not found." >> "$log_file"
        send_backup_error_to_telegram "${error_messages[*]}" "$log_file"
        exit 1
    fi

    local db_type=""
    local sqlite_file=""
    if [ -n "${SQLALCHEMY_DATABASE_URL:-}" ] && backup_parse_database_url "$SQLALCHEMY_DATABASE_URL"; then
        db_type="$BACKUP_DB_TYPE"
        sqlite_file="$BACKUP_SQLITE_FILE"
    elif grep -q "SQLALCHEMY_DATABASE_URL = .*sqlite" "$ENV_FILE"; then
        db_type="sqlite"
        sqlite_file=$(grep -Po '(?<=SQLALCHEMY_DATABASE_URL = "sqlite:////).*"' "$ENV_FILE" | tr -d '"')
        if [[ ! "$sqlite_file" =~ ^/ ]]; then
            sqlite_file="/$sqlite_file"
        fi

    fi

    if [ -n "$db_type" ]; then
        echo "Database detected: $db_type" >> "$log_file"
        case $db_type in
            mariadb)
                local dump_bin
                dump_bin="$(command -v mariadb-dump 2>/dev/null || command -v mysqldump 2>/dev/null || true)"
                if [ -z "$dump_bin" ]; then
                    error_messages+=("mariadb-dump or mysqldump is not installed.")
                else
                    local defaults_file="$temp_dir/mysql-client.cnf"
                    write_mysql_backup_defaults "$defaults_file"
                    if ! "$dump_bin" --defaults-extra-file="$defaults_file" --single-transaction --quick --routines --triggers --events --hex-blob --default-character-set=utf8mb4 "$BACKUP_DB_NAME" > "$temp_dir/db_backup.sql" 2>>"$log_file"; then
                        error_messages+=("MariaDB dump failed.")
                    fi
                fi
                ;;
            mysql)
                local dump_bin
                dump_bin="$(command -v mysqldump 2>/dev/null || command -v mariadb-dump 2>/dev/null || true)"
                if [ -z "$dump_bin" ]; then
                    error_messages+=("mysqldump or mariadb-dump is not installed.")
                else
                    local defaults_file="$temp_dir/mysql-client.cnf"
                    write_mysql_backup_defaults "$defaults_file"
                    if ! "$dump_bin" --defaults-extra-file="$defaults_file" --single-transaction --quick --routines --triggers --events --hex-blob --default-character-set=utf8mb4 "$BACKUP_DB_NAME" > "$temp_dir/db_backup.sql" 2>>"$log_file"; then
                        error_messages+=("MySQL dump failed.")
                    fi
                fi
                ;;
            sqlite)
                if [ -f "$sqlite_file" ]; then
                    if ! cp "$sqlite_file" "$temp_dir/db_backup.sqlite" 2>>"$log_file"; then
                        error_messages+=("Failed to copy SQLite database.")
                    fi
                else
                    error_messages+=("SQLite database file not found at $sqlite_file.")
                fi
                ;;
        esac
    fi

    cp "$APP_DIR/.env" "$temp_dir/" 2>>"$log_file" || true
    if ! rsync -a --exclude 'xray-core' --exclude 'mysql' --exclude 'logs' "$DATA_DIR/" "$temp_dir/rebecca_data/" >>"$log_file" 2>&1; then
        error_messages+=("Failed to copy FireBan data files.")
    fi

    if ! tar -C "$temp_dir" -cf - . | gzip -1 > "$backup_file"; then
        error_messages+=("Failed to create backup archive.")
        echo "Failed to create backup archive." >> "$log_file"
    fi

    rm -rf "$temp_dir"

    if [ ${#error_messages[@]} -gt 0 ]; then
        send_backup_error_to_telegram "${error_messages[*]}" "$log_file"
        return
    fi
    colorized_echo green "Backup created: $backup_file"
    send_backup_to_telegram "$backup_file"
}



get_xray_core() {
    identify_the_operating_system_and_architecture
    clear

    validate_version() {
        local version="$1"
        
        local response=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/tags/$version")
        if echo "$response" | grep -q '"message": "Not Found"'; then
            echo "invalid"
        else
            echo "valid"
        fi
    }

    print_menu() {
        clear
        echo -e "\033[1;32m==============================\033[0m"
        echo -e "\033[1;32m      Xray-core Installer     \033[0m"
        echo -e "\033[1;32m==============================\033[0m"
        echo -e "\033[1;33mAvailable Xray-core versions:\033[0m"
        for ((i=0; i<${#versions[@]}; i++)); do
            echo -e "\033[1;34m$((i + 1)):\033[0m ${versions[i]}"
        done
        echo -e "\033[1;32m==============================\033[0m"
        echo -e "\033[1;35mM:\033[0m Enter a version manually"
        echo -e "\033[1;31mQ:\033[0m Quit"
        echo -e "\033[1;32m==============================\033[0m"
    }

    latest_releases=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=$LAST_XRAY_CORES")

    versions=($(echo "$latest_releases" | grep -oP '"tag_name": "\K(.*?)(?=")'))

    while true; do
        print_menu
        read -p "Choose a version to install (1-${#versions[@]}), or press M to enter manually, Q to quit: " choice
        
        if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -le "${#versions[@]}" ]; then
            choice=$((choice - 1))
            selected_version=${versions[choice]}
            break
        elif [ "$choice" == "M" ] || [ "$choice" == "m" ]; then
            while true; do
                read -p "Enter the version manually (e.g., v1.2.3): " custom_version
                if [ "$(validate_version "$custom_version")" == "valid" ]; then
                    selected_version="$custom_version"
                    break 2
                else
                    echo -e "\033[1;31mInvalid version or version does not exist. Please try again.\033[0m"
                fi
            done
        elif [ "$choice" == "Q" ] || [ "$choice" == "q" ]; then
            echo -e "\033[1;31mExiting.\033[0m"
            exit 0
        else
            echo -e "\033[1;31mInvalid choice. Please try again.\033[0m"
            sleep 2
        fi
    done

    echo -e "\033[1;32mSelected version $selected_version for installation.\033[0m"

    # Check if the required packages are installed
    if ! command -v unzip >/dev/null 2>&1; then
        echo -e "\033[1;33mInstalling required packages...\033[0m"
        detect_os
        install_package unzip
    fi
    if ! command -v wget >/dev/null 2>&1; then
        echo -e "\033[1;33mInstalling required packages...\033[0m"
        detect_os
        install_package wget
    fi

    mkdir -p $DATA_DIR/xray-core
    cd $DATA_DIR/xray-core

    xray_filename="Xray-linux-$ARCH.zip"
    xray_download_url="https://github.com/XTLS/Xray-core/releases/download/${selected_version}/${xray_filename}"

    echo -e "\033[1;33mDownloading Xray-core version ${selected_version}...\033[0m"
    wget -q -O "${xray_filename}" "${xray_download_url}"

    echo -e "\033[1;33mExtracting Xray-core...\033[0m"
    unzip -o "${xray_filename}" >/dev/null 2>&1
    rm "${xray_filename}"
}

get_current_xray_core_version() {
    XRAY_BINARY="$DATA_DIR/xray-core/xray"
    if [ -f "$XRAY_BINARY" ]; then
        version_output=$("$XRAY_BINARY" -version 2>/dev/null)
        if [ $? -eq 0 ]; then
            version=$(echo "$version_output" | head -n1 | awk '{print $2}')
            echo "$version"
            return
        fi
    fi

    echo "Not installed"
}

# Function kept for legacy CLI compatibility. Xray core is managed by nodes now.
update_core_command() {
    colorized_echo yellow "Master no longer runs a local Xray core. Update Xray from the Nodes page or the firenode installer."
}

detect_binary_arch() {
    case "$(uname -m)" in
        amd64|x86_64)
            echo "amd64"
            ;;
        arm64|aarch64)
            echo "arm64"
            ;;
        i386|i486|i586|i686)
            echo "386"
            ;;
        armv5l|armv5tel|armv5tejl)
            echo "armv5"
            ;;
        armv6l|armv6)
            echo "armv6"
            ;;
        armv7l|armv7)
            echo "armv7"
            ;;
        ppc64le)
            echo "ppc64le"
            ;;
        s390x)
            echo "s390x"
            ;;
        *)
            colorized_echo red "Binary install is not available for architecture: $(uname -m)" >&2
            colorized_echo yellow "This server architecture needs a published binary asset." >&2
            exit 1
            ;;
    esac
}

verify_sha256_file() {
    local expected_sha256="$1"
    local file_path="$2"
    local actual_sha256

    if ! [[ "$expected_sha256" =~ ^[A-Fa-f0-9]{64}$ ]]; then
        colorized_echo red "Release metadata is missing a valid SHA-256 checksum." >&2
        return 1
    fi

    actual_sha256=$(sha256sum "$file_path" | awk '{print $1}')
    if [ "$actual_sha256" != "$expected_sha256" ]; then
        colorized_echo red "Checksum verification failed for $(basename "$file_path")." >&2
        return 1
    fi
}

get_binary_distribution_metadata() {
    local binary_arch="$1"
    local requested_version="${2:-latest}"
    local channel="stable"
    local manifest_payload
    local selected

    if [[ "$requested_version" == "dev" || "$requested_version" == dev-* ]]; then
        channel="dev"
    fi

    manifest_payload=$(github_curl -fsSL -H 'Cache-Control: no-cache' "$(cache_busted_url "$FIREBAN_RELEASE_MANIFEST_URL")") || {
        colorized_echo red "Unable to read FireBan distribution manifest: $FIREBAN_RELEASE_MANIFEST_URL" >&2
        exit 1
    }

    selected=$(echo "$manifest_payload" | jq -r \
        --arg channel "$channel" \
        --arg arch "linux-${binary_arch}" \
        --arg requested "$requested_version" '
        .channels[$channel] as $channel_data
        | def selected_build:
            if ($requested != "" and $requested != "latest" and $requested != "dev") then
                ($channel_data.builds[]? | select(.tag == $requested))
            else
                (($channel_data.builds[]? | select(.tag == ($channel_data.latest // ""))) // $channel_data.builds[0]?)
            end;
        selected_build as $build
        | ($build.assets[$arch] // empty) as $asset
        | select(($build.tag // "") != "" and ($asset.url // "") != "" and ($asset.sha256 // "") != "")
        | [$build.tag, $asset.url, ($asset.name // ""), $asset.sha256] | @tsv
    ' | head -n 1)

    if [ -z "$selected" ]; then
        colorized_echo red "No FireBan ${channel} binary is published for linux-${binary_arch}." >&2
        exit 1
    fi

    printf '%s\n' "$selected" | awk -F '\t' '{ printf "%s|%s|%s|%s\n", $1, $2, $3, $4 }'
}

get_binary_release_asset_metadata() {
    local rebecca_version="$1"
    local binary_arch="$2"
    local release_api
    local release_payload
    local resolved_tag
    local server_asset_url
    local cli_asset_url
    local package_asset_url
    local package_asset_name
    local server_asset_name
    local cli_asset_name

    if [ "$rebecca_version" = "latest" ]; then
        release_api="https://api.github.com/repos/${FIREBAN_RELEASE_REPO}/releases/latest"
    else
        release_api="https://api.github.com/repos/${FIREBAN_RELEASE_REPO}/releases/tags/${rebecca_version}"
    fi

    release_payload=$(github_curl -fsSL "$release_api") || {
        colorized_echo red "Unable to read FireBan release metadata: $release_api" >&2
        exit 1
    }

    resolved_tag=$(echo "$release_payload" | jq -r '.tag_name // empty')
    package_asset_name="fireban-linux-${binary_arch}.tar.gz"
    server_asset_name="fireban-server-${resolved_tag}-linux-${binary_arch}"
    cli_asset_name="fireban-cli-${resolved_tag}-linux-${binary_arch}"

    package_asset_url=$(echo "$release_payload" | jq -r --arg name "$package_asset_name" '
        .assets[]?
        | select(.name == $name)
        | .browser_download_url
    ' | head -n 1)

    if [ -n "$package_asset_url" ] && [ "$package_asset_url" != "null" ]; then
        printf 'archive|%s|%s|\n' "${resolved_tag:-$rebecca_version}" "$package_asset_url"
        return
    fi

    server_asset_url=$(echo "$release_payload" | jq -r --arg name "$server_asset_name" '
        .assets[]?
        | select(.name == $name)
        | .browser_download_url
    ' | head -n 1)

    cli_asset_url=$(echo "$release_payload" | jq -r --arg name "$cli_asset_name" '
        .assets[]?
        | select(.name == $name)
        | .browser_download_url
    ' | head -n 1)

    if [ -n "$server_asset_url" ] && [ "$server_asset_url" != "null" ] && [ -n "$cli_asset_url" ] && [ "$cli_asset_url" != "null" ]; then
        printf 'split|%s|%s|%s\n' "${resolved_tag:-$rebecca_version}" "$server_asset_url" "$cli_asset_url"
        return
    fi

    colorized_echo red "No Go binary release assets found for linux-${binary_arch}." >&2
    colorized_echo yellow "Publish fireban-linux-${binary_arch}.tar.gz or split fireban-server/fireban-cli assets for this release." >&2
    exit 1
}

get_binary_dev_manifest_url() {
    if [ -n "$FIREBAN_BINARY_DEV_MANIFEST_URL" ]; then
        printf '%s\n' "$FIREBAN_BINARY_DEV_MANIFEST_URL"
        return
    fi
    printf 'https://raw.githubusercontent.com/%s/%s/%s\n' \
        "$FIREBAN_RELEASE_REPO" \
        "$FIREBAN_BINARY_DEV_MANIFEST_BRANCH" \
        "$FIREBAN_BINARY_DEV_MANIFEST_PATH"
}

get_binary_dev_manifest_metadata() {
    local binary_arch="$1"
    local requested_version="${2:-dev}"
    local manifest_url
    local manifest_payload
    local selected

    manifest_url=$(get_binary_dev_manifest_url)
    manifest_payload=$(github_curl -fsSL -H 'Cache-Control: no-cache' "$(cache_busted_url "$manifest_url")") || return 1

    selected=$(echo "$manifest_payload" | jq -r \
        --arg arch "linux-${binary_arch}" \
        --arg requested "$requested_version" '
        . as $root
        | def selected_build:
            if ($requested != "" and $requested != "dev") then
                ($root.builds[]? | select(.tag == $requested))
            else
                (($root.builds[]? | select(.tag == ($root.latest // ""))) // $root.builds[0]?)
            end;
        selected_build as $build
        | ($build.assets[$arch] // empty) as $asset
        | select(($build.tag // "") != "" and ($asset.url // "") != "")
        | [$build.tag, $asset.url, ($asset.name // "")] | @tsv
    ' | head -n 1)

    if [ -z "$selected" ]; then
        return 1
    fi

    printf '%s\n' "$selected" | awk -F '\t' '{ printf "%s|%s|%s\n", $1, $2, $3 }'
}

get_binary_dev_artifact_metadata() {
    local binary_arch="$1"
    local requested_version="${2:-dev}"
    local workflow_runs_api
    local workflow_runs_payload
    local latest_run_json
    local run_id
    local head_sha
    local artifact_name
    local artifacts_api
    local artifacts_payload
    local artifact_url
    local nightly_workflow
    local workflow_path

    if get_binary_dev_manifest_metadata "$binary_arch" "$requested_version"; then
        return
    fi

    if [ "$requested_version" != "dev" ]; then
        colorized_echo red "Dev binary build ${requested_version} was not found in $(get_binary_dev_manifest_url)." >&2
        exit 1
    fi

    nightly_workflow="$FIREBAN_BINARY_WORKFLOW_NAME"
    case "$nightly_workflow" in
        *.yml|*.yaml) ;;
        *) nightly_workflow="${nightly_workflow}.yml" ;;
    esac
    workflow_path=".github/workflows/${nightly_workflow}"
    workflow_runs_api="https://api.github.com/repos/${FIREBAN_RELEASE_REPO}/actions/runs?per_page=50"
    workflow_runs_payload=$(github_curl -fsSL "$workflow_runs_api") || {
        colorized_echo red "Unable to read binary dev workflow metadata: $workflow_runs_api" >&2
        exit 1
    }

    latest_run_json=$(echo "$workflow_runs_payload" | jq -c --arg branch "$FIREBAN_BINARY_DEV_BRANCH" --arg workflow_path "$workflow_path" '
        .workflow_runs[]?
        | select(.head_branch == $branch and .event == "push" and .conclusion == "success" and .path == $workflow_path)
    ' | head -n 1)

    if [ -z "$latest_run_json" ]; then
        colorized_echo red "No successful binary dev workflow run was found on branch ${FIREBAN_BINARY_DEV_BRANCH}." >&2
        exit 1
    fi

    run_id=$(echo "$latest_run_json" | jq -r '.id // empty')
    head_sha=$(echo "$latest_run_json" | jq -r '.head_sha // empty')
    artifacts_api="https://api.github.com/repos/${FIREBAN_RELEASE_REPO}/actions/runs/${run_id}/artifacts"
    artifacts_payload=$(github_curl -fsSL "$artifacts_api") || {
        colorized_echo red "Unable to read binary dev workflow artifacts: $artifacts_api" >&2
        exit 1
    }

    artifact_name=$(echo "$artifacts_payload" | jq -r --arg preferred "${BINARY_ARTIFACT_PREFIX}-linux-${binary_arch}" --arg arch "linux-${binary_arch}" '
        [
            .artifacts[]?
            | select((.expired | not) and (.name == $preferred or (.name | startswith("rebecca")) and (.name | contains($arch))))
        ]
        | sort_by(if .name == $preferred then 0 else 1 end, .created_at)
        | .[0].name // empty
    ')

    if [ -z "$artifact_name" ]; then
        colorized_echo red "No usable binary dev artifact was found for workflow run ${run_id}." >&2
        exit 1
    fi

    artifact_url="https://nightly.link/${FIREBAN_RELEASE_REPO}/workflows/${nightly_workflow}/${FIREBAN_BINARY_DEV_BRANCH}/${artifact_name}.zip"
    printf '%s|%s|%s.zip\n' "dev-${head_sha:0:7}" "$artifact_url" "$artifact_name"
}

install_binary_cli_launcher() {
    cat > "$BINARY_CLI_LAUNCHER" <<EOF
#!/usr/bin/env bash
set -e
export FIREBAN_ENV_FILE="$ENV_FILE"
export FIREBAN_APP_DIR="$APP_DIR"
export FIREBAN_DATA_DIR="$DATA_DIR"
exec "$BINARY_CLI" "\$@"
EOF

    chmod 755 "$BINARY_CLI_LAUNCHER"
}

write_binary_release_metadata() {
    local resolved_version="$1"
    local binary_arch="$2"
    local asset_url="$3"

    jq -n \
        --arg image "fireban-server (binary)" \
        --arg tag "$resolved_version" \
        --arg asset_url "$asset_url" \
        --arg arch "linux-${binary_arch}" \
        --arg server_binary "$BINARY_SERVER" \
        --arg cli_binary "$BINARY_CLI" \
        --arg installed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            install_mode: "binary",
            image: $image,
            tag: $tag,
            asset_url: $asset_url,
            arch: $arch,
            server_binary: $server_binary,
            cli_binary: $cli_binary,
            installed_at: $installed_at
        }' > "$BINARY_METADATA_FILE"
}

create_binary_service() {
    cat > "$BINARY_SERVICE_UNIT" <<EOF
[Unit]
Description=FireBan Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
Environment=FIREBAN_APP_DIR=$APP_DIR
Environment=FIREBAN_ENV_FILE=$ENV_FILE
Environment=FIREBAN_INSTALL_MODE=binary
Environment=FIREBAN_BINARY_METADATA_FILE=$BINARY_METADATA_FILE
Environment=FIREBAN_DATA_DIR=$DATA_DIR
ExecStart=$BINARY_SERVER
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

install_binary_rebecca() {
    local rebecca_version="$1"
    local database_type="$2"
    local configure_database="${3:-1}"
    local binary_arch
    local resolved_version
    local artifact_url
    local artifact_name
    local artifact_sha256
    local tmp_dir
    local package_path=""
    local dev_package_path=""

    detect_os
    for package in curl jq tar gzip unzip; do
        if ! command -v "$package" >/dev/null 2>&1; then
            install_package "$package"
        fi
    done

    binary_arch=$(detect_binary_arch)
    tmp_dir=$(mktemp -d)

    if [ -n "${FIREBAN_BINARY_SERVER_OVERRIDE:-}" ] || [ -n "${FIREBAN_BINARY_CLI_OVERRIDE:-}" ]; then
        if [ ! -f "${FIREBAN_BINARY_SERVER_OVERRIDE:-}" ] || [ ! -f "${FIREBAN_BINARY_CLI_OVERRIDE:-}" ]; then
            colorized_echo red "Both FIREBAN_BINARY_SERVER_OVERRIDE and FIREBAN_BINARY_CLI_OVERRIDE must point to existing files." >&2
            rm -rf "$tmp_dir"
            exit 1
        fi
        ui_spinner_run "Installing FireBan custom server binary" install -m 755 "$FIREBAN_BINARY_SERVER_OVERRIDE" "$tmp_dir/fireban-server"
        ui_spinner_run "Installing FireBan custom CLI binary" install -m 755 "$FIREBAN_BINARY_CLI_OVERRIDE" "$tmp_dir/fireban-cli"
        resolved_version="${FIREBAN_BINARY_OVERRIDE_VERSION:-custom}"
        artifact_url="local-override"
    else
        IFS='|' read -r resolved_version artifact_url artifact_name artifact_sha256 < <(get_binary_distribution_metadata "$binary_arch" "$rebecca_version")
        artifact_name="${artifact_name:-fireban-linux-${binary_arch}.tar.gz}"
        package_path="$tmp_dir/$artifact_name"
        ui_spinner_run "Downloading FireBan binary package" curl -fL "$artifact_url" -o "$package_path"
        if ! verify_sha256_file "$artifact_sha256" "$package_path"; then
            rm -rf "$tmp_dir"
            exit 1
        fi
        if [[ "$package_path" == *.zip ]]; then
            ui_spinner_run "Extracting FireBan binary package" unzip -j -o "$package_path" -d "$tmp_dir"
            dev_package_path="$tmp_dir/fireban-linux-${binary_arch}.tar.gz"
            if [ -f "$dev_package_path" ]; then
                ui_spinner_run "Unpacking FireBan binary package" tar -xzf "$dev_package_path" -C "$tmp_dir"
            else
                colorized_echo red "Downloaded FireBan archive is missing fireban-linux-${binary_arch}.tar.gz." >&2
                rm -rf "$tmp_dir"
                exit 1
            fi
        elif [[ "$package_path" == *.tar.gz ]]; then
            ui_spinner_run "Unpacking FireBan binary package" tar -xzf "$package_path" -C "$tmp_dir"
        else
            colorized_echo red "Unsupported FireBan binary asset format: $artifact_name" >&2
            rm -rf "$tmp_dir"
            exit 1
        fi
    fi

    if [ ! -f "$tmp_dir/fireban-server" ] || [ ! -f "$tmp_dir/fireban-cli" ]; then
        colorized_echo red "Downloaded binary package is incomplete; fireban-server or fireban-cli is missing." >&2
        rm -rf "$tmp_dir"
        exit 1
    fi

    mkdir -p "$BINARY_BIN_DIR" "$DATA_DIR" "$APP_DIR/scripts"
    install -m 755 "$tmp_dir/fireban-server" "$BINARY_SERVER"
    install -m 755 "$tmp_dir/fireban-cli" "$BINARY_CLI"
    install_binary_cli_launcher

    if [ ! -f "$ENV_FILE" ]; then
        ui_spinner_run "Fetching default .env file" github_curl -fsSL "$FIREBAN_TEMPLATE_BASE_URL/.env.example" -o "$ENV_FILE"
    fi

    upsert_env_assignment "FIREBAN_DATA_DIR" "$DATA_DIR"
    upsert_env_assignment "XRAY_JSON" "$DATA_DIR/xray_config.json"
    if [ "$configure_database" = "1" ]; then
        configure_binary_database "$database_type"
    fi

    if [ ! -f "$DATA_DIR/xray_config.json" ]; then
        colorized_echo yellow "No bundled xray_config.json found; FireBan will use its built-in default."
    fi

    write_binary_release_metadata "${resolved_version:-$rebecca_version}" "$binary_arch" "${artifact_url:-}"
    echo "binary" > "$INSTALL_MODE_FILE"
    write_rebecca_channel "$rebecca_version"
    create_binary_service
    rm -rf "$tmp_dir"
    colorized_echo green "FireBan binary files installed successfully"
}

up_rebecca() {
    systemctl enable --now "$APP_NAME.service"
}

schedule_binary_service_restart() {
    local delay_seconds="${1:-1}"
    local unit_name="${APP_NAME}-delayed-restart-$(date +%s%N)"
    local restart_script="sleep ${delay_seconds}; systemctl restart ${APP_NAME}.service"

    if command -v systemd-run >/dev/null 2>&1; then
        systemd-run \
            --unit "$unit_name" \
            --collect \
            --description "FireBan delayed service restart" \
            -- /bin/sh -c "$restart_script" >/dev/null
        return
    fi

    nohup /bin/sh -c "$restart_script" >/dev/null 2>&1 &
}

restart_binary_service_now() {
    systemctl restart "$APP_NAME.service"
}


follow_rebecca_logs() {
    journalctl -u "$APP_NAME.service" -f -o "$(journal_output_format)" --no-pager | format_rebecca_journal_logs
}

status_command() {
    
    # Check if rebecca is installed
    if ! is_rebecca_installed; then
        echo -n "Status: "
        colorized_echo red "Not Installed"
        exit 1
    fi
    
    if ! is_rebecca_up; then
        echo -n "Status: "
        colorized_echo blue "Down"
        exit 1
    fi
    
    echo -n "Status: "
    colorized_echo green "Up"

    systemctl status "$APP_NAME.service" --no-pager
}


prompt_for_rebecca_password() {
    if [ -n "${MYSQL_PASSWORD:-}" ]; then
        if ! mysql_password_is_strong "$MYSQL_PASSWORD"; then
            colorized_echo red "MYSQL_PASSWORD is not strong enough. Use at least 12 chars with uppercase, lowercase, digit, and symbol."
            exit 1
        fi
        return
    fi
    MYSQL_PASSWORD=$(get_env_value "MYSQL_PASSWORD")
    if [ -n "${MYSQL_PASSWORD:-}" ]; then
        if ! mysql_password_is_strong "$MYSQL_PASSWORD"; then
            colorized_echo red "MYSQL_PASSWORD in .env is not strong enough. Use at least 12 chars with uppercase, lowercase, digit, and symbol."
            exit 1
        fi
        return
    fi
    if [ ! -t 0 ]; then
        MYSQL_PASSWORD=$(generate_secure_mysql_password)
        colorized_echo green "A secure database password has been generated automatically."
        return
    fi
    colorized_echo cyan "This password will be used to access the database and should be strong."
    colorized_echo cyan "Leave it empty to generate a secure password automatically."
    while true; do
        MYSQL_PASSWORD=$(read_secret "Database password: ")
        if [ -z "$MYSQL_PASSWORD" ]; then
            MYSQL_PASSWORD=$(generate_secure_mysql_password)
            colorized_echo green "A secure password has been generated automatically."
            break
        fi
        if mysql_password_is_strong "$MYSQL_PASSWORD"; then
            local confirm_password
            confirm_password=$(read_secret "Confirm database password: ")
            if [ "$MYSQL_PASSWORD" = "$confirm_password" ]; then
                break
            fi
            colorized_echo red "Passwords do not match."
        else
            colorized_echo red "Password must be at least 12 chars and include uppercase, lowercase, digit, and symbol. Press Enter for auto-generation."
        fi
    done
    colorized_echo green "This password will be recorded in the .env file for future use."
}

sql_escape_literal() {
    printf "%s" "$1" | sed "s/'/''/g"
}

get_configured_database_type() {
    local flavor
    local db_url
    flavor=$(get_env_value "FIREBAN_DATABASE_FLAVOR")
    case "$flavor" in
        mysql|mariadb|sqlite)
            echo "$flavor"
            return
        ;;
    esac

    db_url=$(get_env_value "SQLALCHEMY_DATABASE_URL")
    if [[ "$db_url" == sqlite* ]]; then
        echo "sqlite"
    elif [[ "$db_url" == mysql* ]]; then
        if [ -d "/var/lib/mysql" ] && command -v mariadb >/dev/null 2>&1 && ! command -v mysqld >/dev/null 2>&1; then
            echo "mariadb"
        else
            echo "mysql"
        fi
    else
        echo "sqlite"
    fi
}

mysql_root_command() {
    if command -v mysql >/dev/null 2>&1; then
        mysql --protocol=socket -uroot "$@"
    elif command -v mariadb >/dev/null 2>&1; then
        mariadb --protocol=socket -uroot "$@"
    else
        return 1
    fi
}

install_host_database() {
    local database_type="$1"
    local package_name
    local service_name
    local config_file

    case "$database_type" in
        mysql)
            package_name="mysql-server"
            service_name="mysql"
            config_file="/etc/mysql/mysql.conf.d/fireban.cnf"
        ;;
        mariadb)
            package_name="mariadb-server"
            service_name="mariadb"
            config_file="/etc/mysql/mariadb.conf.d/60-fireban.cnf"
        ;;
        *)
            return 0
        ;;
    esac

    detect_os
    if ! command -v mysql >/dev/null 2>&1 && ! command -v mariadb >/dev/null 2>&1; then
        install_package "$package_name" || {
            if [ "$database_type" = "mysql" ]; then
                install_package default-mysql-server
            else
                return 1
            fi
        }
    fi

    systemctl enable --now "$service_name" >/dev/null 2>&1 || systemctl enable --now mysql >/dev/null 2>&1 || true

    mkdir -p "$(dirname "$config_file")"
    cat > "$config_file" <<EOF
[mysqld]
bind-address=127.0.0.1
skip-name-resolve=ON
local-infile=0
symbolic-links=0
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
max_connections=200
EOF
    systemctl restart "$service_name" >/dev/null 2>&1 || systemctl restart mysql >/dev/null 2>&1 || true

    if [ -z "${MYSQL_PASSWORD:-}" ]; then
        prompt_for_rebecca_password
    fi
    MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$(generate_secure_mysql_password)}"
    MYSQL_PASSWORD="${MYSQL_PASSWORD:-$(generate_secure_mysql_password)}"
    local escaped_password
    escaped_password=$(sql_escape_literal "$MYSQL_PASSWORD")

    local sql_file
    sql_file=$(mktemp)
    cat > "$sql_file" <<EOF
CREATE DATABASE IF NOT EXISTS \`fireban\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'fireban'@'127.0.0.1' IDENTIFIED BY '${escaped_password}';
CREATE USER IF NOT EXISTS 'fireban'@'localhost' IDENTIFIED BY '${escaped_password}';
ALTER USER 'fireban'@'127.0.0.1' IDENTIFIED BY '${escaped_password}';
ALTER USER 'fireban'@'localhost' IDENTIFIED BY '${escaped_password}';
GRANT ALL PRIVILEGES ON \`fireban\`.* TO 'fireban'@'127.0.0.1';
GRANT ALL PRIVILEGES ON \`fireban\`.* TO 'fireban'@'localhost';
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
EOF
    if ! mysql_root_command < "$sql_file"; then
        rm -f "$sql_file"
        colorized_echo red "Failed to configure local $database_type. Make sure root can access MySQL/MariaDB through the local socket."
        exit 1
    fi
    rm -f "$sql_file"

    local mysql_password_url_encoded
    mysql_password_url_encoded=$(urlencode_value "$MYSQL_PASSWORD")
    upsert_env_assignment "FIREBAN_DATABASE_FLAVOR" "$database_type"
    upsert_env_assignment "MYSQL_DATABASE" "fireban"
    upsert_env_assignment "MYSQL_USER" "fireban"
    upsert_env_assignment "MYSQL_PASSWORD" "$MYSQL_PASSWORD"
    upsert_env_assignment "MYSQL_ROOT_PASSWORD" "$MYSQL_ROOT_PASSWORD"
    upsert_env_assignment "SQLALCHEMY_DATABASE_URL" "mysql+pymysql://fireban:${mysql_password_url_encoded}@127.0.0.1:3306/fireban"
}

configure_binary_database() {
    local database_type="${1:-mysql}"
    case "$database_type" in
        sqlite|"")
            upsert_env_assignment "FIREBAN_DATABASE_FLAVOR" "sqlite"
            upsert_env_assignment "SQLALCHEMY_DATABASE_URL" "sqlite:///${DATA_DIR}/db.sqlite3"
        ;;
        mysql|mariadb)
            install_host_database "$database_type"
        ;;
        *)
            colorized_echo red "Unsupported database type for binary install: $database_type"
            exit 1
        ;;
    esac
}

install_command() {
    check_running_as_root

    # Default values
    database_type=""
    database_type_set="false"
    rebecca_version="latest"
    rebecca_version_set="false"
    install_mode=""
    install_phpmyadmin="false"

    # Parse options
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            --database)
                database_type="$2"
                database_type_set="true"
                shift 2
            ;;
            --dev)
                if [[ "$rebecca_version_set" == "true" ]]; then
                    colorized_echo red "Error: Cannot use --dev and --version options simultaneously."
                    exit 1
                fi
                rebecca_version="dev"
                rebecca_version_set="true"
                shift
            ;;
            --version)
                if [[ "$rebecca_version_set" == "true" ]]; then
                    colorized_echo red "Error: Cannot use --dev and --version options simultaneously."
                    exit 1
                fi
                if [ -z "${2:-}" ]; then
                    colorized_echo red "Error: --version requires a value."
                    exit 1
                fi
                rebecca_version="$2"
                rebecca_version_set="true"
                shift 2
            ;;
            --mode)
                if [ -z "${2:-}" ]; then
                    colorized_echo red "Error: --mode accepts only binary."
                    exit 1
                fi
                install_mode=$(normalize_install_mode "$2")
                shift 2
            ;;
            --binary)
                install_mode="binary"
                shift
            ;;
            *)
                echo "Unknown option: $1"
                exit 1
            ;;
        esac
    done

    # Check if rebecca is already installed
    if is_rebecca_installed; then
        colorized_echo red "FireBan is already installed at $APP_DIR"
        read -p "Do you want to override the previous installation? (y/n) "
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            colorized_echo red "Aborted installation"
            exit 1
        fi
    fi
    install_mode=$(select_install_mode "$install_mode")
    if [ "$install_mode" = "binary" ]; then
        if [ "$database_type_set" != "true" ]; then
            database_type=$(select_database_type_interactive)
        fi
        database_type="${database_type:-mysql}"
        case "$database_type" in
            mysql|mariadb)
                if [ -t 0 ] && ui_read_yes_no "Install phpMyAdmin for this ${database_type} database?" "n"; then
                    install_phpmyadmin="true"
                fi
            ;;
        esac
    fi
    if [[ "$rebecca_version_set" != "true" ]]; then
        rebecca_version=$(select_rebecca_version "" "$install_mode")
    fi
    set_rebecca_source_for_version "$rebecca_version"
    detect_os
    if ! command -v jq >/dev/null 2>&1; then
        install_package jq
    fi
    if ! command -v curl >/dev/null 2>&1; then
        install_package curl
    fi
    install_rebecca_script "$rebecca_version"

    # Function to check if a version exists in the GitHub releases
    check_version_exists() {
        local version=$1
        if [ "$version" == "latest" ] || [ "$version" == "dev" ]; then
            return 0
        fi
        if [[ "$version" =~ ^dev-[0-9a-fA-F]{7,40}$ ]]; then
            [ "$install_mode" = "binary" ]
            return
        fi
        
        github_curl -fsSL "$FIREBAN_RELEASE_MANIFEST_URL" \
            | jq -e --arg version "$version" \
                '[.channels.stable.builds[]? | select(.tag == $version)] | length > 0' \
            >/dev/null
    }
    # Check if the version is valid and exists
    if [[ "$rebecca_version" == "latest" || "$rebecca_version" == "dev" || "$rebecca_version" =~ ^dev-[0-9a-fA-F]{7,40}$ || "$rebecca_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if check_version_exists "$rebecca_version"; then
            install_binary_rebecca "$rebecca_version" "$database_type"
            prompt_dashboard_bind_settings
            prompt_initial_admin
            if [ "$install_phpmyadmin" = "true" ]; then
                ui_section "phpMyAdmin"
                prompt_phpmyadmin_settings
                enable_host_phpmyadmin "$PHPMYADMIN_PATH"
            fi
            write_rebecca_channel "$rebecca_version"
            echo "Installing $rebecca_version version"
        else
            echo "Version $rebecca_version does not exist. Please enter a valid version (e.g. v0.5.2)"
            exit 1
        fi
    else
        echo "Invalid version format. Please enter a valid version (e.g. v0.5.2)"
        exit 1
    fi
    prompt_ssl_setup
    if [ "$install_mode" = "binary" ]; then
        create_initial_admin_if_requested
    fi
    up_rebecca
    follow_rebecca_logs
}

install_yq() {
    if command -v yq &>/dev/null; then
        colorized_echo green "yq is already installed."
        return
    fi

    identify_the_operating_system_and_architecture

    local base_url="https://github.com/mikefarah/yq/releases/latest/download"
    local yq_binary=""

    case "$ARCH" in
        '64' | 'x86_64')
            yq_binary="yq_linux_amd64"
            ;;
        'arm32-v7a' | 'arm32-v6' | 'arm32-v5' | 'armv7l')
            yq_binary="yq_linux_arm"
            ;;
        'arm64-v8a' | 'aarch64')
            yq_binary="yq_linux_arm64"
            ;;
        '32' | 'i386' | 'i686')
            yq_binary="yq_linux_386"
            ;;
        *)
            colorized_echo red "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac

    local yq_url="${base_url}/${yq_binary}"
    colorized_echo blue "Downloading yq from ${yq_url}..."

    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        colorized_echo yellow "Neither curl nor wget is installed. Attempting to install curl."
        install_package curl || {
            colorized_echo red "Failed to install curl. Please install curl or wget manually."
            exit 1
        }
    fi


    if command -v curl &>/dev/null; then
        if curl -L "$yq_url" -o /usr/local/bin/yq; then
            chmod +x /usr/local/bin/yq
            colorized_echo green "yq installed successfully!"
        else
            colorized_echo red "Failed to download yq using curl. Please check your internet connection."
            exit 1
        fi
    elif command -v wget &>/dev/null; then
        if wget -O /usr/local/bin/yq "$yq_url"; then
            chmod +x /usr/local/bin/yq
            colorized_echo green "yq installed successfully!"
        else
            colorized_echo red "Failed to download yq using wget. Please check your internet connection."
            exit 1
        fi
    fi


    if ! echo "$PATH" | grep -q "/usr/local/bin"; then
        export PATH="/usr/local/bin:$PATH"
    fi


    hash -r

    if command -v yq &>/dev/null; then
        colorized_echo green "yq is ready to use."
    elif [ -x "/usr/local/bin/yq" ]; then

        colorized_echo yellow "yq is installed at /usr/local/bin/yq but not found in PATH."
        colorized_echo yellow "You can add /usr/local/bin to your PATH environment variable."
    else
        colorized_echo red "yq installation failed. Please try again or install manually."
        exit 1
    fi
}


down_rebecca() {
    systemctl stop "$APP_NAME.service"
}



show_rebecca_logs() {
    journalctl -u "$APP_NAME.service" -o "$(journal_output_format)" --no-pager | format_rebecca_journal_logs
}

rebecca_cli() {
    FIREBAN_ENV_FILE="$ENV_FILE" FIREBAN_APP_DIR="$APP_DIR" FIREBAN_DATA_DIR="$DATA_DIR" CLI_PROG_NAME="fireban cli" "$BINARY_CLI" "$@"
}


is_rebecca_up() {
    systemctl is-active --quiet "$APP_NAME.service"
}

uninstall_command() {
    check_running_as_root
    local install_mode
    install_mode=$(get_install_mode)
    local app_exists=0
    if is_rebecca_installed; then
        app_exists=1
    fi

    if [ "$app_exists" -eq 0 ]; then
        colorized_echo red "FireBan's not installed!"
        exit 1
    fi

    read -p "Do you really want to uninstall FireBan? (y/n) "
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        colorized_echo red "Aborted"
        exit 1
    fi

	if [ "$app_exists" -eq 1 ]; then
		if is_rebecca_up; then
			down_rebecca
		fi
    fi
    uninstall_rebecca_script

	if [ "$app_exists" -eq 1 ]; then
		uninstall_rebecca

		read -p "Do you want to remove FireBan's data files too ($DATA_DIR)? (y/n) "
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            colorized_echo green "FireBan uninstalled successfully"
        else
            uninstall_rebecca_data_files
            colorized_echo green "FireBan uninstalled successfully"
        fi
    else
        colorized_echo green "Legacy FireBan script removed"
    fi
}

uninstall_rebecca_script() {
    if [ -f "/usr/local/bin/fireban" ]; then
        colorized_echo yellow "Removing FireBan script"
        rm "/usr/local/bin/fireban"
    fi
}

uninstall_rebecca() {
    if [ -f "$BINARY_SERVICE_UNIT" ]; then
        systemctl disable --now "$APP_NAME.service" >/dev/null 2>&1 || true
        rm -f "$BINARY_SERVICE_UNIT"
        systemctl daemon-reload
    fi
    if [ -f "$BINARY_CLI_LAUNCHER" ] || [ -L "$BINARY_CLI_LAUNCHER" ]; then
        rm -f "$BINARY_CLI_LAUNCHER"
    fi
    if [ -d "$APP_DIR" ]; then
        colorized_echo yellow "Removing directory: $APP_DIR"
        rm -r "$APP_DIR"
    fi
}


uninstall_rebecca_data_files() {
    if [ -d "$DATA_DIR" ]; then
        colorized_echo yellow "Removing directory: $DATA_DIR"
        rm -r "$DATA_DIR"
    fi
}

restart_command() {
    help() {
        colorized_echo red "Usage: fireban restart [options]"
        echo
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-logs     do not follow logs after starting"
    }
    
    local no_logs=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--no-logs)
                no_logs=true
            ;;
            -h|--help)
                help
                exit 0
            ;;
            *)
                echo "Error: Invalid option: $1" >&2
                help
                exit 0
            ;;
        esac
        shift
    done
    
    # Check if rebecca is installed
    if ! is_rebecca_installed; then
        colorized_echo red "FireBan's not installed!"
        exit 1
    fi
    
    if is_binary_install; then
        if [ "$no_logs" = true ]; then
            schedule_binary_service_restart 1
            colorized_echo green "FireBan restart scheduled."
            return
        fi
        restart_binary_service_now
        follow_rebecca_logs
        return
    fi

    down_rebecca
    up_rebecca
    if [ "$no_logs" = false ]; then
        follow_rebecca_logs
    fi
    colorized_echo green "FireBan successfully restarted!"
}
logs_command() {
    help() {
        colorized_echo red "Usage: fireban logs [options]"
        echo ""
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-follow   do not show follow logs"
    }
    
    local no_follow=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--no-follow)
                no_follow=true
            ;;
            -h|--help)
                help
                exit 0
            ;;
            *)
                echo "Error: Invalid option: $1" >&2
                help
                exit 0
            ;;
        esac
        shift
    done
    
    # Check if rebecca is installed
    if ! is_rebecca_installed; then
        colorized_echo red "FireBan's not installed!"
        exit 1
    fi
    
    if ! is_rebecca_up; then
        colorized_echo red "FireBan is not up."
        exit 1
    fi
    
    if [ "$no_follow" = true ]; then
        show_rebecca_logs
    else
        follow_rebecca_logs
    fi
}

down_command() {
    
    # Check if rebecca is installed
    if ! is_rebecca_installed; then
        colorized_echo red "FireBan's not installed!"
        exit 1
    fi
    
    if ! is_rebecca_up; then
        colorized_echo red "FireBan's already down"
        exit 1
    fi
    
    down_rebecca
}

cli_command() {
    # Check if rebecca is installed
    if ! is_rebecca_installed; then
        colorized_echo red "FireBan's not installed!"
        exit 1
    fi
    
    if ! is_rebecca_up; then
        colorized_echo red "FireBan is not up."
        exit 1
    fi
    
    rebecca_cli "$@"
}

up_command() {
    help() {
        colorized_echo red "Usage: fireban up [options]"
        echo ""
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-logs     do not follow logs after starting"
    }
    
    local no_logs=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--no-logs)
                no_logs=true
            ;;
            -h|--help)
                help
                exit 0
            ;;
            *)
                echo "Error: Invalid option: $1" >&2
                help
                exit 0
            ;;
        esac
        shift
    done
    
    # Check if rebecca is installed
    if ! is_rebecca_installed; then
        colorized_echo red "FireBan's not installed!"
        exit 1
    fi
    
    if is_rebecca_up; then
        colorized_echo red "FireBan's already up"
        exit 1
    fi
    
    up_rebecca
    if [ "$no_logs" = false ]; then
        follow_rebecca_logs
    fi
}

update_command() {
    check_running_as_root
    local rebecca_version=""
    local rebecca_version_set="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dev)
                if [[ "$rebecca_version_set" == "true" ]]; then
                    colorized_echo red "Error: Cannot use --dev and --version options simultaneously."
                    exit 1
                fi
                rebecca_version="dev"
                rebecca_version_set="true"
                shift
                ;;
            --version)
                if [[ "$rebecca_version_set" == "true" ]]; then
                    colorized_echo red "Error: Cannot use --dev and --version options simultaneously."
                    exit 1
                fi
                if [ -z "${2:-}" ]; then
                    colorized_echo red "Error: --version requires a value."
                    exit 1
                fi
                rebecca_version="$2"
                rebecca_version_set="true"
                shift 2
                ;;
            -h|--help)
                colorized_echo red "Usage: fireban update [--dev | --version vX.Y.Z|dev-abcdef0]"
                exit 0
                ;;
            *)
                colorized_echo red "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Check if rebecca is installed
    if ! is_rebecca_installed; then
        colorized_echo red "FireBan's not installed!"
        exit 1
    fi

    if [[ "$rebecca_version_set" != "true" ]]; then
        rebecca_version=$(get_installed_rebecca_channel)
    fi
    set_rebecca_source_for_version "$rebecca_version"

	colorized_echo blue "Updating FireBan CLI..."
    update_rebecca_script "$rebecca_version"

    colorized_echo blue "Updating requested version: $rebecca_version"
    update_rebecca "$rebecca_version"
    write_rebecca_channel "$rebecca_version"
    
    colorized_echo blue "Restarting FireBan's services"
	schedule_binary_service_restart 1
	colorized_echo blue "FireBan updated successfully; restart scheduled."
}

update_rebecca_script() {
    local source_version="${1:-}"
    local temp_script
    if [ -n "$source_version" ]; then
        set_rebecca_source_for_version "$source_version"
    elif is_rebecca_installed; then
        set_rebecca_source_for_version "$(get_installed_rebecca_channel)"
    fi
    SCRIPT_URL="$FIREBAN_SCRIPT_BASE_URL/$FIREBAN_SCRIPT_SOURCE_FILE"
    colorized_echo blue "Updating FireBan script"
    temp_script=$(mktemp)
    github_curl -fsSL "$SCRIPT_URL" -o "$temp_script"
    if head -n 1 "$temp_script" | grep -qi "<!DOCTYPE"; then
        rm -f "$temp_script"
        colorized_echo red "Unexpected HTML response while downloading script"
        exit 1
    fi
    install -m 755 "$temp_script" "$FIREBAN_SCRIPT_INSTALL_PATH"
    rm -f "$temp_script"
    colorized_echo green "FireBan script updated successfully"
}


update_rebecca() {
    local rebecca_version="${1:-latest}"

	if is_binary_install; then
		install_binary_rebecca "$rebecca_version" "$(get_configured_database_type)" "0"
		return
	fi

	colorized_echo red "FireBan updates require binary installation mode."
	exit 1
}

migration_sqlite_path() {
    local db_url
    db_url=$(get_env_value "SQLALCHEMY_DATABASE_URL")
    case "$db_url" in
        sqlite:////*)
            printf "/%s\n" "${db_url#sqlite:////}"
        ;;
        sqlite:///*)
            printf "%s\n" "${db_url#sqlite:///}"
        ;;
        *)
            printf "%s/db.sqlite3\n" "$DATA_DIR"
        ;;
    esac
}



import_binary_database_backup() {
    local database_type="$1"
    local backup_dir="$2"
    case "$database_type" in
        sqlite)
            if [ -f "$backup_dir/db.sqlite3" ]; then
                mkdir -p "$DATA_DIR"
                install -m 600 "$backup_dir/db.sqlite3" "$DATA_DIR/db.sqlite3"
            fi
        ;;
        mysql|mariadb)
            if [ -f "$backup_dir/db.sql" ]; then
                mysql_root_command -e "DROP DATABASE IF EXISTS \`fireban\`; CREATE DATABASE \`fireban\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
                mysql_root_command fireban < "$backup_dir/db.sql"
            fi
        ;;
    esac
}



check_editor() {
    if [ -z "$EDITOR" ]; then
        if command -v nano >/dev/null 2>&1; then
            EDITOR="nano"
            elif command -v vi >/dev/null 2>&1; then
            EDITOR="vi"
        else
            detect_os
            install_package nano
            EDITOR="nano"
        fi
    fi
}


edit_command() {
    detect_os
    check_editor
	if is_binary_install; then
		mkdir -p "$(dirname "$ENV_FILE")"
		touch "$ENV_FILE"
		$EDITOR "$ENV_FILE"
		return
	fi
	colorized_echo red "FireBan edit requires binary installation mode."
	exit 1
}

edit_env_command() {
    detect_os
    check_editor
    if [ -f "$ENV_FILE" ]; then
        $EDITOR "$ENV_FILE"
    else
        colorized_echo red "Environment file not found at $ENV_FILE"
        exit 1
    fi
}

menu_commands() {
    echo "up down restart status logs cli migrate backup backup-service install update uninstall script-install script-update script-uninstall core-update enable-phpmyadmin disable-phpmyadmin edit edit-env ssl help"
}

menu_category_for() {
    case "$1" in
        up|down|restart|status|logs) echo "Panel runtime" ;;
        cli|migrate|backup|backup-service) echo "Administration and data" ;;
        install|update|uninstall) echo "Install and update" ;;
        script-install|script-update|script-uninstall) echo "Script management" ;;
		core-update|enable-phpmyadmin|disable-phpmyadmin|edit|edit-env|ssl) echo "Tools" ;;
        *) echo "Help" ;;
    esac
}

menu_description_for() {
    case "$1" in
        up) echo "Start services" ;;
        down) echo "Stop services" ;;
        restart) echo "Restart services" ;;
        status) echo "Show status" ;;
        logs) echo "Show logs" ;;
        cli) echo "FireBan CLI" ;;
        migrate) echo "Run database migrations" ;;
        backup) echo "Manual backup launch" ;;
        backup-service) echo "Backup service (Telegram + cron job)" ;;
        install) echo "Install FireBan" ;;
        update) echo "Update to latest version" ;;
        uninstall) echo "Uninstall FireBan" ;;
        script-install) echo "Install FireBan script" ;;
        script-update) echo "Update FireBan CLI script" ;;
        script-uninstall) echo "Uninstall FireBan script" ;;
        core-update) echo "Deprecated; Xray is managed by nodes" ;;
        enable-phpmyadmin) echo "Enable phpMyAdmin on local MySQL/MariaDB" ;;
        disable-phpmyadmin) echo "Disable phpMyAdmin panel bridge" ;;
		edit) echo "Edit environment file" ;;
        edit-env) echo "Edit environment file" ;;
        ssl) echo "Issue or renew SSL certificates" ;;
        help) echo "Show this help message" ;;
        *) echo "" ;;
    esac
}

print_menu() {
    local selected="${1:-0}"
    local previous_category=""
    local idx=1
    local cmd category desc is_selected
    ui_header "FireBan Panel" "Control center"
    ui_section "Status"
    print_menu_status_summary
    ui_section "Actions"
    for cmd in $(menu_commands); do
        category=$(menu_category_for "$cmd")
        if [ "$category" != "$previous_category" ]; then
            ui_menu_category "$category"
            previous_category="$category"
        fi
        desc=$(menu_description_for "$cmd")
        is_selected=0
        [ "$idx" -eq "$selected" ] && is_selected=1
        ui_menu_item "$idx" "$cmd" "$desc" "$is_selected"
        idx=$((idx + 1))
    done
    printf "\n"
    ui_color "38;5;245" "Tip: use ↑/↓ and Enter, or type a number/command directly. Press q to exit."
    printf "\n"
    echo
}

map_choice_to_command() {
    local commands=($(menu_commands))

    if [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le "${#commands[@]}" ]; then
        echo "${commands[$(($1 - 1))]}"
        return
    fi
    echo "$1"
}

read_menu_command() {
    MENU_COMMAND=""
    if ! ui_is_tty; then
        print_menu
        ui_color "38;5;45;1" "Select option"
        printf " "
        ui_color "38;5;245" "(number or command): "
        read -r user_choice
        [ -z "$user_choice" ] && return 1
        MENU_COMMAND=$(map_choice_to_command "$user_choice")
        return
    fi

    local commands=($(menu_commands))
    local selected=1
    local action kind value mapped
    while true; do
        ui_clear
        print_menu "$selected"
        ui_color "38;5;45;1" "Select option"
        printf " "
        ui_color "38;5;245" "(↑/↓, Enter, number, command): "
        action=$(ui_read_menu_choice "$selected" "${#commands[@]}") || return 1
        kind="${action%%:*}"
        value="${action#*:}"
        case "$kind" in
            move)
                selected="$value"
            ;;
            enter)
                MENU_COMMAND="${commands[$(($value - 1))]}"
                return
            ;;
            value)
                mapped=$(map_choice_to_command "$value")
                [ -n "$mapped" ] && MENU_COMMAND="$mapped"
                return
            ;;
            quit)
                return 1
            ;;
        esac
    done
}

usage() {
    local script_name="${0##*/}"
    colorized_echo blue "=============================="
    colorized_echo magenta "           FireBan Help"
    colorized_echo blue "=============================="
    colorized_echo cyan "Usage:"
    echo "  ${script_name} [command]"
    echo

    colorized_echo cyan "Commands:"
    colorized_echo yellow "  up              – Start services"
    colorized_echo yellow "  down            – Stop services"
    colorized_echo yellow "  restart         – Restart services"
    colorized_echo yellow "  status          – Show status"
    colorized_echo yellow "  logs            - Show logs"
    colorized_echo yellow "  cli             - FireBan CLI"
    colorized_echo yellow "  migrate         - Run database migrations"
    colorized_echo yellow "  install         - Install FireBan"
    colorized_echo yellow "  update          - Update to latest/dev or a specific release"
    colorized_echo yellow "  uninstall       - Uninstall FireBan"
    colorized_echo yellow "  script-install  - Install FireBan script"
    colorized_echo yellow "  script-update   - Update FireBan CLI script"
    colorized_echo yellow "  script-uninstall  - Uninstall FireBan script"
    colorized_echo yellow "  backup          - Manual backup launch"
    colorized_echo yellow "  backup-service  - FireBan Backupservice to backup to TG, and a new job in crontab"
    colorized_echo yellow "  core-update     - Deprecated; Xray is managed by nodes"
    colorized_echo yellow "  enable-phpmyadmin - Enable phpMyAdmin for local MySQL/MariaDB"
    colorized_echo yellow "  disable-phpmyadmin - Disable phpMyAdmin"
    colorized_echo yellow "  edit            - Edit environment file (via nano or vi editor)"
    colorized_echo yellow "  edit-env        - Edit environment file (via nano or vi editor)"
    colorized_echo yellow "  ssl             - Issue or renew SSL certificates"
    colorized_echo yellow "  help            - Show this help message"
    
    
    echo
    colorized_echo cyan "Directories:"
    colorized_echo magenta "  App directory: $APP_DIR"
    colorized_echo magenta "  Data directory: $DATA_DIR"
    echo
    colorized_echo cyan "Install options:"
    case "$(script_install_mode)" in
        binary)
            colorized_echo magenta "  This script installs binary mode only."
            ;;
    esac
    colorized_echo magenta "  --database sqlite|mysql|mariadb"
    colorized_echo magenta "  --dev or --version vX.Y.Z (install/update)"
    echo
    current_version=$(get_current_xray_core_version)
    colorized_echo cyan "Current Xray-core version: $current_version"
    colorized_echo blue "================================"
    echo
}

dispatch_command() {
    local cmd="$1"
    shift || true
    case "$cmd" in
        help|install|script-install|install-script|script-update|update-script|script-uninstall|uninstall-script)
            ;;
        *)
            ensure_script_matches_installed_mode
            ;;
    esac
    case "$cmd" in
        up) up_command "$@" ;;
        down) down_command "$@" ;;
        restart) restart_command "$@" ;;
        status) status_command "$@" ;;
        logs) logs_command "$@" ;;
        cli) cli_command "$@" ;;
        migrate) cli_command migrate "$@" ;;
        backup) backup_command "$@" ;;
        backup-service) backup_service "$@" ;;
        install) install_command "$@" ;;
        update) update_command "$@" ;;
        uninstall) uninstall_command "$@" ;;
        script-install|install-script) install_rebecca_script "$@" ;;
        script-update|update-script) install_rebecca_script "$@" ;;
        script-uninstall|uninstall-script) uninstall_rebecca_script "$@" ;;
        core-update) update_core_command "$@" ;;
        enable-phpmyadmin) enable_phpmyadmin "$@" ;;
        disable-phpmyadmin) disable_phpmyadmin "$@" ;;
        ssl) ssl_command "$@" ;;
        edit) edit_command "$@" ;;
        edit-env) edit_env_command "$@" ;;
        help) usage ;;
        *) usage ;;
    esac
}

if [ $# -eq 0 ]; then
    read_menu_command || exit 0
    set -- $MENU_COMMAND
fi

dispatch_command "$@"
