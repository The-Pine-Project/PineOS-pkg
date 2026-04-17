#!/usr/bin/env bash
# =============================================================================
#  pkg — PineOS Package Manager vEDGE
#  Repos:
#    Stable packages : https://github.com/The-Pine-Project/pkg-stable-repo
#    pkg itself      : https://github.com/The-Pine-Project/PineOS-pkg
# =============================================================================

readonly TITLE="PineOS Package Manager"
readonly VERSION="EDGE"

# ── XDG Paths ─────────────────────────────────────────────────────────────────
readonly CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pkg"
readonly DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pkg"
readonly CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/pkg"
readonly CONFIG_FILE="$CONFIG_DIR/pkg.conf"
readonly HISTORY_FILE="$DATA_DIR/history.log"
readonly PLUGIN_DIR="$CONFIG_DIR/plugins"
readonly PINNED_FILE="$DATA_DIR/pinned.list"
readonly LOCK_FILE="/tmp/pkg-$UID.lock"

# ── Defaults (overridden after config load) ───────────────────────────────────
ARCH="$(uname -m)"
AUR_HELPER="auto"
BUILD_BASE="/tmp/pine-build"
COLOR="true"
CONFIRM="true"
MAX_HISTORY=1000
DOWNLOAD_TOOL="auto"
PLUGINS_ENABLED="true"
STABLE_REPO_URL="https://github.com/The-Pine-Project/pkg-stable-repo/raw/refs/heads/main"
PKG_SELF_URL="https://github.com/The-Pine-Project/PineOS-pkg/raw/refs/heads/main/pkg-edge"
PKGBUILD_SELF_URL="https://github.com/The-Pine-Project/PineOS-pkg/raw/refs/heads/main/pkg-edge"
PKG_POST_INSTALL_SELF="https://github.com/The-Pine-Project/PineOS-pkg/raw/refs/heads/main/pkg-edge"
# ── Colors ────────────────────────────────────────────────────────────────────
_init_colors() {
    if [[ "$COLOR" == "true" ]] && [[ -t 1 ]]; then
        GREEN='\033[0;32m';  BLUE='\033[0;34m';  YELLOW='\033[1;33m'
        RED='\033[0;31m';    CYAN='\033[0;36m';  MAGENTA='\033[0;35m'
        BOLD='\033[1m';      DIM='\033[2m';       NC='\033[0m'
    else
        GREEN=''; BLUE=''; YELLOW=''; RED=''; CYAN=''; MAGENTA=''
        BOLD=''; DIM=''; NC=''
    fi
}
_init_colors

# ── Logging helpers ───────────────────────────────────────────────────────────
msg()     { echo -e "${GREEN}[pkg]${NC} $*"; }
info()    { echo -e "${BLUE}[info]${NC} $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC} $*"; }
err()     { echo -e "${RED}[err]${NC} $*" >&2; }
die()     { err "$*"; _release_lock 2>/dev/null; exit 1; }
ok()      { echo -e "${GREEN}[✔]${NC} $*"; }
step()    { echo -e "${CYAN}[→]${NC} $*"; }
banner()  { echo -e "\n${BOLD}${MAGENTA}══ $* ══${NC}"; }
divider() { echo -e "${DIM}────────────────────────────────────────${NC}"; }

need_arg() { [[ -z "${1:-}" ]] && die "Usage: pkg $2"; }
has_cmd()  { command -v "$1" &>/dev/null; }

# ── Process lock ──────────────────────────────────────────────────────────────
_acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid; pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            die "Another pkg instance is already running (PID $pid).\nRemove $LOCK_FILE to force unlock."
        fi
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
    trap '_release_lock; exit' EXIT INT TERM HUP
}

_release_lock() {
    [[ -f "$LOCK_FILE" ]] && [[ "$(cat "$LOCK_FILE" 2>/dev/null)" == "$$" ]] && rm -f "$LOCK_FILE"
}

# ── Directory bootstrap ───────────────────────────────────────────────────────
_init_dirs() {
    mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$CACHE_DIR" "$PLUGIN_DIR"
}

# ── Config ────────────────────────────────────────────────────────────────────
_create_default_config() {
    _init_dirs
    cat > "$CONFIG_FILE" <<EOF
# =============================================================================
#  pkg.conf — PineOS Package Manager Configuration
#  Generated on $(date '+%Y-%m-%d %H:%M:%S') by pkg v${VERSION}
#  Edit with: pkg config edit   |   Reset with: pkg config reset
# =============================================================================

[general]
arch=$(uname -m)
aur_helper=auto
build_base=/tmp/pine-build
color=true
confirm=true
download_tool=auto
max_history=1000

[repos]
stable=${STABLE_REPO_URL}
self=${PKG_SELF_URL}
pkgbuild_self=${PKGBUILD_SELF_URL}

[history]
log_file=${HISTORY_FILE}
max_entries=1000

[cache]
dir=${CACHE_DIR}
ttl_hours=24

[plugins]
enabled=true
plugin_dir=${PLUGIN_DIR}
; To activate a plugin, uncomment or add its reverse-domain ID below.
; Install plugins with: pkg plugin install <id>
; Scaffold a new one with: pkg plugin create <id>
;
; com.pineos.flatpak
; com.pineos.snap
; com.pineos.pip
; com.pineos.npm
; com.pineos.cargo
EOF
    info "Created default config at ${CONFIG_FILE}"
}

_load_config() {
    _init_dirs
    [[ ! -f "$CONFIG_FILE" ]] && _create_default_config

    local section=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(#|;|$) ]] && continue
        if [[ "$line" =~ ^\[([a-zA-Z_]+)\]$ ]]; then
            section="${BASH_REMATCH[1]}"; continue
        fi
        if [[ "$line" =~ ^[[:space:]]*([^=[:space:]]+)[[:space:]]*=[[:space:]]*(.*)[[:space:]]*$ ]]; then
            local key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
            case "$section/$key" in
                general/arch)           ARCH="$val" ;;
                general/aur_helper)     AUR_HELPER="$val" ;;
                general/build_base)     BUILD_BASE="${val/\~/$HOME}" ;;
                general/color)          COLOR="$val"; _init_colors ;;
                general/confirm)        CONFIRM="$val" ;;
                general/download_tool)  DOWNLOAD_TOOL="$val" ;;
                general/max_history)    MAX_HISTORY="$val" ;;
                repos/stable)           STABLE_REPO_URL="$val" ;;
                repos/self)             PKG_SELF_URL="$val" ;;
                repos/pkgbuild_self)    PKGBUILD_SELF_URL="$val" ;;
                history/log_file)       HISTORY_FILE="${val/\~/$HOME}" ;;
                history/max_entries)    MAX_HISTORY="$val" ;;
                cache/dir)              CACHE_DIR="${val/\~/$HOME}" ;;
                plugins/enabled)        PLUGINS_ENABLED="$val" ;;
                plugins/plugin_dir)     PLUGIN_DIR="${val/\~/$HOME}" ;;
            esac
        fi
    done < "$CONFIG_FILE"
}

_config_get() {
    local section="$1" key="$2"
    local in_sec=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^\[$section\]$ ]]  && in_sec=true  && continue
        [[ "$line" =~ ^\[[a-zA-Z_]+\]$ ]] && in_sec=false
        if $in_sec && [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*) ]]; then
            echo "${BASH_REMATCH[1]}"; return 0
        fi
    done < "$CONFIG_FILE"
    return 1
}

_config_set() {
    local section="$1" key="$2" value="$3"
    awk -v sec="[$section]" -v k="$key" -v v="$value" '
        /^\[/ { in_sec = ($0 == sec) }
        in_sec && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { print k "=" v; next }
        { print }
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
        && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE" \
        || die "Failed to write config"
}

cmd_config() {
    local subcmd="${1:-show}"
    case "$subcmd" in
        show|cat)
            banner "Configuration: $CONFIG_FILE"
            divider
            cat "$CONFIG_FILE"
            ;;
        edit)
            local editor="${EDITOR:-${VISUAL:-nano}}"
            has_cmd "$editor" || die "Editor '$editor' not found. Set \$EDITOR."
            "$editor" "$CONFIG_FILE"
            ;;
        set)
            need_arg "${2:-}" "config set <section.key> <value>"
            need_arg "${3:-}" "config set <section.key> <value>"
            local sk="$2" val="$3"
            local section="${sk%%.*}" key="${sk#*.}"
            _config_set "$section" "$key" "$val"
            ok "[$section] $key = $val"
            ;;
        get)
            need_arg "${2:-}" "config get <section.key>"
            local sk="$2" section="${2%%.*}" key="${2#*.}"
            _config_get "$section" "$key" || die "Key not found: $sk"
            ;;
        reset)
            _confirm "Reset config to defaults? This cannot be undone." || return 0
            rm -f "$CONFIG_FILE"
            _create_default_config
            ok "Config reset to defaults"
            ;;
        path)
            echo "$CONFIG_FILE"
            ;;
        *)
            die "Usage: pkg config {show|edit|set <s.k> <v>|get <s.k>|reset|path}"
            ;;
    esac
}

# ── History ───────────────────────────────────────────────────────────────────
_history_add() {
    local action="$1"; shift
    local subject="${*:-}"
    mkdir -p "$(dirname "$HISTORY_FILE")"
    printf '[%s] %-20s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$action" "$subject" >> "$HISTORY_FILE"
    # Trim to max_entries
    if [[ -f "$HISTORY_FILE" ]]; then
        local lines; lines=$(wc -l < "$HISTORY_FILE")
        if (( lines > MAX_HISTORY )); then
            tail -n "$MAX_HISTORY" "$HISTORY_FILE" > "${HISTORY_FILE}.tmp"
            mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
        fi
    fi
}

cmd_history() {
    local n="${1:-25}"
    if [[ ! -f "$HISTORY_FILE" ]] || [[ ! -s "$HISTORY_FILE" ]]; then
        info "No history recorded yet."; return 0
    fi
    banner "History — last $n entries"
    divider
    tail -n "$n" "$HISTORY_FILE" | while IFS= read -r line; do
        if [[ "$line" =~ ^\[([^\]]+)\][[:space:]]+([A-Z_]+)[[:space:]]+(.*) ]]; then
            local ts="${BASH_REMATCH[1]}" action="${BASH_REMATCH[2]}" subject="${BASH_REMATCH[3]}"
            local color="$NC"
            case "$action" in
                INSTALL*)   color="$GREEN"   ;;
                REMOVE*)    color="$RED"     ;;
                UPDATE*)    color="$BLUE"    ;;
                BUILD*)     color="$CYAN"    ;;
                PULL*|GIT*) color="$MAGENTA" ;;
                PLUGIN*)    color="$YELLOW"  ;;
                PIN*|UNPIN) color="$YELLOW"  ;;
                WGET*|CURL) color="$CYAN"    ;;
            esac
            printf "  ${DIM}%s${NC}  ${color}${BOLD}%-20s${NC}  %s\n" "$ts" "$action" "$subject"
        else
            echo "  $line"
        fi
    done
    divider
    echo -e "  ${DIM}Full log: $HISTORY_FILE${NC}"
}

cmd_history_clear() {
    _confirm "Clear all history?" || return 0
    > "$HISTORY_FILE"
    ok "History cleared"
}

# ── Download abstraction ──────────────────────────────────────────────────────
# _dl <url> <dest>  — save to file
_dl() {
    local url="$1" dest="$2"
    case "$DOWNLOAD_TOOL" in
        curl)  curl -fsSL "$url" -o "$dest" ;;
        wget)  wget -q "$url" -O "$dest" ;;
        auto|*)
            if has_cmd curl;      then curl -fsSL "$url" -o "$dest"
            elif has_cmd wget;    then wget -q "$url" -O "$dest"
            else die "Neither curl nor wget found. Install one: pkg install curl"; fi ;;
    esac
}

# _dl_stdout <url>  — stream to stdout
_dl_stdout() {
    local url="$1"
    case "$DOWNLOAD_TOOL" in
        curl)  curl -fsSL "$url" ;;
        wget)  wget -q "$url" -O - ;;
        auto|*)
            if has_cmd curl;      then curl -fsSL "$url"
            elif has_cmd wget;    then wget -q "$url" -O -
            else die "Neither curl nor wget found."; fi ;;
    esac
}

# ── AUR helper ────────────────────────────────────────────────────────────────
_aur_helper() {
    if [[ "$AUR_HELPER" != "auto" ]] && has_cmd "$AUR_HELPER"; then
        echo "$AUR_HELPER"; return 0
    fi
    if   has_cmd paru; then echo "paru"
    elif has_cmd yay;  then echo "yay"
    else die "No AUR helper found. Install paru or yay first."; fi
}

# ── Confirmation prompt ───────────────────────────────────────────────────────
_confirm() {
    [[ "$CONFIRM" != "true" ]] && return 0
    local prompt="${1:-Continue?}"
    read -rp "$(echo -e "${YELLOW}[?]${NC} ${prompt} [y/N] ")" ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ── Pinned packages ───────────────────────────────────────────────────────────
_is_pinned() { [[ -f "$PINNED_FILE" ]] && grep -qx "$1" "$PINNED_FILE"; }

cmd_pin() {
    need_arg "${1:-}" "pin <package>"
    echo "$1" >> "$PINNED_FILE"
    sort -u -o "$PINNED_FILE" "$PINNED_FILE"
    ok "Pinned $1  (excluded from updates)"
    _history_add "PIN" "$1"
}

cmd_unpin() {
    need_arg "${1:-}" "unpin <package>"
    if ! _is_pinned "$1"; then warn "$1 is not pinned."; return 0; fi
    sed -i "/^${1}$/d" "$PINNED_FILE"
    ok "Unpinned $1"
    _history_add "UNPIN" "$1"
}

cmd_pinned() {
    banner "Pinned Packages"
    if [[ ! -f "$PINNED_FILE" ]] || [[ ! -s "$PINNED_FILE" ]]; then
        info "No packages pinned."; return 0
    fi
    while IFS= read -r p; do echo -e "  ${CYAN}⊕${NC} $p"; done < "$PINNED_FILE"
}

# ── Install ───────────────────────────────────────────────────────────────────
cmd_install() {
    need_arg "${1:-}" "install <package> [package2 ...]"

    for pkg in "$@"; do
        if _is_pinned "$pkg"; then
            warn "$pkg is pinned — skipping. Run: pkg unpin $pkg"; continue
        fi
        if pacman -Si "$pkg" &>/dev/null; then
            step "Installing ${BOLD}$pkg${NC} from official repos..."
            _confirm "Install $pkg?" || continue
            sudo pacman -S --noconfirm "$pkg"
            ok "Installed $pkg"
            _history_add "INSTALL" "$pkg"
        else
            local aur; aur=$(_aur_helper)
            step "${BOLD}$pkg${NC} not in official repos — trying AUR via ${aur}..."
            _confirm "Install $pkg from AUR?" || continue
            "$aur" -S --noconfirm "$pkg"
            ok "Installed $pkg  (AUR/$aur)"
            _history_add "INSTALL_AUR" "$pkg via $aur"
        fi
    done
}

# ── Remove ────────────────────────────────────────────────────────────────────
cmd_remove() {
    need_arg "${1:-}" "remove <package> [package2 ...]"

    for pkg in "$@"; do
        if _is_pinned "$pkg"; then
            warn "$pkg is pinned — skipping. Run: pkg unpin $pkg"; continue
        fi
        _confirm "Remove $pkg and its orphaned deps?" || continue
        sudo pacman -Rs --noconfirm "$pkg"
        ok "Removed $pkg"
        _history_add "REMOVE" "$pkg"
    done
}

# ── Update ────────────────────────────────────────────────────────────────────
cmd_update() {
    banner "System Update"

    local ignore_args=()
    if [[ -f "$PINNED_FILE" ]] && [[ -s "$PINNED_FILE" ]]; then
        while IFS= read -r p; do ignore_args+=("--ignore" "$p"); done < "$PINNED_FILE"
        warn "Pinned packages will be skipped: $(paste -sd ', ' "$PINNED_FILE")"
    fi

    step "Syncing databases and upgrading system packages..."
    sudo pacman -Syu --noconfirm "${ignore_args[@]}"

    if has_cmd paru; then
        step "Upgrading AUR packages via paru..."
        paru -Sua --noconfirm "${ignore_args[@]}"
    elif has_cmd yay; then
        step "Upgrading AUR packages via yay..."
        yay -Sua --noconfirm "${ignore_args[@]}"
    fi

    ok "System fully updated"
    _history_add "UPDATE_SYSTEM" "all packages"
}

# ── Search ────────────────────────────────────────────────────────────────────
cmd_search() {
    need_arg "${1:-}" "search <query>"
    local query="$1"
    banner "Search: $query"
    info "Official repos:"
    pacman -Ss "$query" 2>/dev/null || echo "  (no results)"

    local aur; aur=$(_aur_helper 2>/dev/null) || true
    if [[ -n "${aur:-}" ]]; then
        echo; info "AUR (via $aur):"
        "$aur" -Ss "$query" 2>/dev/null || echo "  (no results)"
    fi
}

# ── Info ──────────────────────────────────────────────────────────────────────
cmd_info() {
    need_arg "${1:-}" "info <package>"
    pacman -Qi "$1" 2>/dev/null || pacman -Si "$1" 2>/dev/null \
        || die "Package '$1' not found locally or in repos."
}

# ── List ──────────────────────────────────────────────────────────────────────
cmd_list() {
    local filter="${1:-}"
    banner "Explicitly Installed Packages"
    if [[ -n "$filter" ]]; then
        pacman -Qe | grep -i "$filter" || echo "  (no matches for '$filter')"
    else
        pacman -Qe
    fi
}

# ── Autoremove orphans ────────────────────────────────────────────────────────
cmd_autoremove() {
    banner "Autoremove Orphans"
    local orphans; orphans=$(pacman -Qtdq 2>/dev/null) || true
    if [[ -z "${orphans:-}" ]]; then
        ok "No orphaned packages found."; return 0
    fi
    echo "$orphans"
    echo
    _confirm "Remove $(echo "$orphans" | wc -l) orphaned package(s)?" || return 0
    sudo pacman -Rns --noconfirm $orphans
    ok "Orphans removed"
    _history_add "AUTOREMOVE" "$(echo "$orphans" | tr '\n' ' ')"
}

# ── Clean caches ──────────────────────────────────────────────────────────────
cmd_clean() {
    banner "Cache Cleanup"
    step "Clearing pacman package cache (keeping last 2 versions)..."
    if has_cmd paccache; then sudo paccache -rk2
    else sudo pacman -Sc --noconfirm; fi

    step "Clearing pkg build cache ($BUILD_BASE)..."
    rm -rf "$BUILD_BASE"

    step "Clearing pkg download cache ($CACHE_DIR)..."
    find "$CACHE_DIR" -mindepth 1 -delete 2>/dev/null || true

    ok "All caches cleaned"
    _history_add "CLEAN" "pacman + build + download cache"
}

# ── Doctor ────────────────────────────────────────────────────────────────────
cmd_doctor() {
    banner "System Doctor"
    local all_ok=true

    _chk() {
        local label="$1" cmd="$2"
        if has_cmd "$cmd"; then
            local ver; ver=$("$cmd" --version 2>&1 | head -1) || ver="(installed)"
            printf "  ${GREEN}✔${NC}  %-18s ${DIM}%s${NC}\n" "$label" "$ver"
        else
            printf "  ${RED}✘${NC}  %-18s ${RED}NOT FOUND${NC}\n" "$label"
            all_ok=false
        fi
    }

    echo -e "${BOLD}Core tools:${NC}"
    _chk "pacman"   pacman
    _chk "bash"     bash
    _chk "curl"     curl
    _chk "wget"     wget
    _chk "git"      git
    _chk "makepkg"  makepkg
    _chk "grep"     grep
    _chk "sed"      sed
    _chk "awk"      awk

    echo -e "\n${BOLD}Optional tools:${NC}"
    _chk "paru (AUR)" paru
    _chk "yay (AUR)"  yay
    _chk "vlock"      vlock
    _chk "paccache"   paccache
    _chk "diff"       diff

    echo -e "\n${BOLD}System health:${NC}"
    local orphans; orphans=$(pacman -Qtdq 2>/dev/null | wc -l) || orphans=0
    if (( orphans > 0 )); then
        printf "  ${YELLOW}⚠${NC}  %s orphaned package(s) — run: pkg autoremove\n" "$orphans"
    else
        printf "  ${GREEN}✔${NC}  No orphaned packages\n"
    fi

    local avail; avail=$(df -h / | awk 'NR==2{print $4}')
    printf "  ${BLUE}ℹ${NC}  Disk space available (/): %s\n" "$avail"

    local mem; mem=$(free -h | awk '/^Mem:/{print $4}')
    printf "  ${BLUE}ℹ${NC}  Free RAM: %s\n" "${mem:-n/a}"

    echo -e "\n${BOLD}pkg config:${NC}"
    printf "  ${BLUE}ℹ${NC}  Config file   : %s\n" "$CONFIG_FILE"
    printf "  ${BLUE}ℹ${NC}  History file  : %s\n" "$HISTORY_FILE"
    printf "  ${BLUE}ℹ${NC}  Plugin dir    : %s\n" "$PLUGIN_DIR"
    printf "  ${BLUE}ℹ${NC}  Download tool : %s\n" "$DOWNLOAD_TOOL"
    printf "  ${BLUE}ℹ${NC}  AUR helper    : %s\n" "$(_aur_helper 2>/dev/null || echo 'none')"

    echo
    $all_ok && ok "All required tools present" || warn "Some tools missing — install them for full functionality"
}

# ── Export / Import ───────────────────────────────────────────────────────────
cmd_export() {
    local outfile="${1:-pkg-export-$(date +%Y%m%d-%H%M%S).txt}"
    banner "Export Package List"
    {
        echo "# pkg export — $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# Restore with: pkg import $outfile"
        pacman -Qe | awk '{print $1}'
    } > "$outfile"
    ok "Exported $(pacman -Qe | wc -l) packages to: $outfile"
    _history_add "EXPORT" "$outfile"
}

cmd_import() {
    need_arg "${1:-}" "import <file>"
    local infile="$1"
    [[ ! -f "$infile" ]] && die "File not found: $infile"
    banner "Import Package List: $infile"
    local count=0 failed=0
    while IFS= read -r pkg || [[ -n "$pkg" ]]; do
        [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
        if cmd_install "$pkg"; then (( count++ )) || true
        else warn "Failed: $pkg"; (( failed++ )) || true; fi
    done < "$infile"
    ok "Imported: $count succeeded, $failed failed"
    _history_add "IMPORT" "$infile ($count packages)"
}

# ── Build from pkg-stable-repo ────────────────────────────────────────────────
cmd_build() {
    need_arg "${1:-}" "build <package>"
    local pkg="$1"
    local build_dir="$BUILD_BASE/$pkg"

    banner "Build: $pkg"
    step "Preparing build directory: $build_dir"
    rm -rf "$build_dir"; mkdir -p "$build_dir"
    cd "$build_dir" || die "Cannot enter build directory."

    step "Fetching PKGBUILD from pkg-stable-repo..."
    _dl "$STABLE_REPO_URL/$ARCH/$pkg/PKGBUILD" PKGBUILD \
        || die "PKGBUILD for '$pkg' not found in pkg-stable-repo ($ARCH)."

    # Fetch optional .install script
    if grep -q "^install=" PKGBUILD; then
        local install_file
        install_file=$(grep "^install=" PKGBUILD | cut -d'=' -f2 | tr -d "'\"")
        step "Fetching install script: $install_file"
        _dl "$STABLE_REPO_URL/$ARCH/$pkg/$install_file" "$install_file" \
            || warn "Could not fetch $install_file — continuing."
    fi

    # Fetch non-URL source entries
    while IFS= read -r src_entry; do
        [[ "$src_entry" =~ ^https?:// ]] && continue
        [[ "$src_entry" == "PKGBUILD"   ]] && continue
        [[ -z "$src_entry"              ]] && continue
        step "Fetching source: $src_entry"
        _dl "$STABLE_REPO_URL/$ARCH/$pkg/$src_entry" "$src_entry" \
            || warn "Could not fetch $src_entry — build may fail."
    done < <(grep -Po "(?<=source=\()[^)]*(?=\))" PKGBUILD 2>/dev/null \
             | tr " '" '\n' | tr -d '"' | grep -v '^$')

    step "Running makepkg..."
    makepkg -sic --noconfirm
    ok "Built and installed: $pkg"
    _history_add "BUILD" "$pkg"
}

# ── Pull ──────────────────────────────────────────────────────────────────────
cmd_pull() {
    local subcmd="${1:-}"
    local target="${2:-}"

    case "$subcmd" in
        script|bin)
            need_arg "$target" "pull script <repo/path/to/file>"
            local filename; filename=$(basename "$target")
            local dest="/usr/local/bin/${filename%.sh}"
            step "Downloading script: $STABLE_REPO_URL/$target"
            sudo bash -c "_dl() { $(declare -f _dl); _dl \"\$@\"; }; _dl '$STABLE_REPO_URL/$target' '$dest'" \
                || _dl "$STABLE_REPO_URL/$target" /tmp/_pkg_script_dl \
                && sudo mv /tmp/_pkg_script_dl "$dest" \
                || die "Could not fetch '$target' from pkg-stable-repo."
            sudo chmod +x "$dest"
            ok "Script installed: $dest"
            _history_add "PULL_SCRIPT" "$target → $dest"
            ;;

        clone|src)
            need_arg "$target" "pull clone <user/repo>"
            has_cmd git || die "git is not installed. Run: pkg install git"
            local clone_dir="$BUILD_BASE/clones/$(basename "$target")"
            step "Cloning https://github.com/$target"
            rm -rf "$clone_dir"
            git clone --depth=1 "https://github.com/$target" "$clone_dir" \
                || die "Clone failed for '$target'."
            if [[ -f "$clone_dir/PKGBUILD" ]]; then
                step "PKGBUILD found — building with makepkg..."
                cd "$clone_dir" || die "Cannot enter clone dir."
                makepkg -sic --noconfirm
                ok "Built and installed from $target"
            else
                info "No PKGBUILD found. Sources at: $clone_dir"
            fi
            _history_add "PULL_CLONE" "github.com/$target"
            ;;

        url)
            need_arg "$target" "pull url <url>"
            local filename; filename=$(basename "$target")
            local dest="/usr/local/bin/${filename%.sh}"
            step "Downloading from URL: $target"
            _dl "$target" /tmp/"$filename" || die "Download failed."
            sudo mv /tmp/"$filename" "$dest"
            sudo chmod +x "$dest"
            ok "Installed: $dest"
            _history_add "PULL_URL" "$target → $dest"
            ;;

        *)
            die "Usage: pkg pull {script|clone|url} <target>
  pull script <repo/path/file>   Download script from pkg-stable-repo
  pull clone  <user/repo>        Clone GitHub repo; build if PKGBUILD present
  pull url    <https://...>      Download & install from arbitrary URL"
            ;;
    esac
}

# ── Git shortcuts ─────────────────────────────────────────────────────────────
cmd_git() {
    local subcmd="${1:-}"
    has_cmd git || die "git is not installed. Run: pkg install git"

    case "$subcmd" in
        clone)
            need_arg "${2:-}" "git clone <user/repo> [dest]"
            local repo="$2" dest="${3:-$(basename "$2")}"
            step "Cloning https://github.com/$repo"
            git clone "https://github.com/$repo" "$dest" \
                && ok "Cloned to $dest" || die "Clone failed."
            _history_add "GIT_CLONE" "github.com/$repo"
            ;;
        pull)
            need_arg "${2:-}" "git pull <directory>"
            step "Pulling latest in $2..."
            git -C "$2" pull && ok "Pulled $2" || die "Pull failed."
            ;;
        status)
            need_arg "${2:-}" "git status <directory>"
            git -C "${2:-.}" status
            ;;
        log)
            need_arg "${2:-}" "git log <directory>"
            git -C "${2:-.}" log --oneline -20
            ;;
        diff)
            need_arg "${2:-}" "git diff <directory>"
            git -C "${2:-.}" diff
            ;;
        *)
            die "Usage: pkg git {clone <u/repo>|pull <dir>|status <dir>|log <dir>|diff <dir>}"
            ;;
    esac
}

# ── wget wrapper ──────────────────────────────────────────────────────────────
cmd_wget() {
    need_arg "${1:-}" "wget <url> [output-dir]"
    has_cmd wget || die "wget is not installed. Run: pkg install wget"
    local url="$1" outdir="${2:-.}"
    step "wget → $outdir: $url"
    wget --continue --progress=bar "$url" -P "$outdir"
    ok "Downloaded"
    _history_add "WGET" "$url"
}

# ── curl wrapper ──────────────────────────────────────────────────────────────
cmd_curl() {
    need_arg "${1:-}" "curl <url> [output-file]"
    has_cmd curl || die "curl is not installed. Run: pkg install curl"
    local url="$1" outfile="${2:-}"
    if [[ -n "$outfile" ]]; then
        curl -L --progress-bar "$url" -o "$outfile"
        ok "Saved to $outfile"
    else
        curl -L "$url"
    fi
    _history_add "CURL" "$url"
}

# ── Self update ───────────────────────────────────────────────────────────────
cmd_update_self() {
    banner "Self-Update"
    local tmp; tmp=$(mktemp /tmp/pkg_new.XXXXXX)

    step "Fetching latest pkg.sh from upstream..."
    _dl "$PKG_SELF_URL/pkg-edge/pkg.sh" "$tmp" \
        || { rm -f "$tmp"; die "Failed to fetch latest pkg.sh — check connection."; }

    step "Fetching latest pkg.install from upstream..."
    _dl "$PKG_SELF_URL/pkg-edge/pkg.install" "$tmp" \
        || { rm -f "$tmp"; die "Failed to fetch latest pkg.sh — check connection."; }

    # Show a diff if possible
    if has_cmd diff && [[ -x /usr/bin/pkg ]]; then
        echo; info "Diff (current → upstream):"
        diff --color=auto /usr/bin/pkg "$tmp" || true; echo
    fi

    _confirm "Apply update to /usr/bin/pkg?" || { rm -f "$tmp"; return 0; }
    sudo mv "$tmp" /usr/bin/pkg
    sudo chmod +x /usr/bin/pkg
    ok "pkg script updated."

    # Version-bump local PKGBUILD if present
    local pkgbuild_path=""
    for candidate in \
        "/usr/share/pkg/PKGBUILD" \
        "$HOME/.local/share/pkg/PKGBUILD" \
        "$BUILD_BASE/pkg-stable/PKGBUILD"
    do
        [[ -f "$candidate" ]] && pkgbuild_path="$candidate" && break
    done

    if [[ -n "$pkgbuild_path" ]]; then
        step "Checking remote version..."
        local remote_ver
        remote_ver=$(_dl_stdout "$PKGBUILD_SELF_URL" 2>/dev/null | grep "^pkgver=" | cut -d'=' -f2)
        if [[ -n "${remote_ver:-}" ]]; then
            local current_ver
            current_ver=$(grep "^pkgver=" "$pkgbuild_path" | cut -d'=' -f2)
            if [[ "$remote_ver" != "$current_ver" ]]; then
                sed -i "s/^pkgver=.*/pkgver=$remote_ver/" "$pkgbuild_path"
                sed -i "s/^pkgrel=.*/pkgrel=1/"           "$pkgbuild_path"
                ok "Bumped pkgver: $current_ver → $remote_ver  ($pkgbuild_path)"
            else
                info "pkgver already up to date ($current_ver)."
            fi
        fi
    else
        info "No local PKGBUILD found to version-bump."
    fi

    _history_add "UPDATE_SELF" "pkg → v$VERSION"
    ok "pkg is up to date!"
}

# ── Lock terminal ─────────────────────────────────────────────────────────────
cmd_lock() {
    has_cmd vlock || die "vlock is not installed. Run: pkg install vlock"
    vlock -a
}

# ── Plugin system ─────────────────────────────────────────────────────────────
# Plugin format ($PLUGIN_DIR/com.vendor.name.plugin):
#
#   PLUGIN_NAME="name"
#   PLUGIN_VERSION="1.0.0"
#   PLUGIN_DESC="Short description"
#   PLUGIN_COMMANDS=("cmd1" "cmd2")
#   plugin_help()      { ... }
#   plugin_cmd_cmd1()  { ... }
#   plugin_cmd_cmd2()  { ... }

declare -A _LOADED_PLUGINS=()   # id → "name vX.Y.Z"

_load_plugins() {
    [[ "$PLUGINS_ENABLED" != "true" ]] && return 0
    [[ ! -d "$PLUGIN_DIR"           ]] && return 0

    local in_plugins=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^\[plugins\]$  ]] && in_plugins=true  && continue
        [[ "$line" =~ ^\[[a-zA-Z_]+\]$ ]] && in_plugins=false
        if $in_plugins && [[ "$line" =~ ^[[:space:]]*(com\.[a-zA-Z0-9._-]+)[[:space:]]*$ ]]; then
            local plugin_id="${BASH_REMATCH[1]}"
            local plugin_file="$PLUGIN_DIR/${plugin_id}.plugin"
            if [[ -f "$plugin_file" ]]; then
                # Source in a subshell first to validate, then source for real
                (bash -n "$plugin_file" 2>/dev/null) \
                    || { warn "Plugin syntax error: $plugin_file"; continue; }
                # shellcheck disable=SC1090
                source "$plugin_file"
                _LOADED_PLUGINS["$plugin_id"]="${PLUGIN_NAME:-$plugin_id} v${PLUGIN_VERSION:-?}"
            else
                warn "Plugin $plugin_id enabled in config but missing: $plugin_file"
                warn "Install it with: pkg plugin install $plugin_id"
            fi
        fi
    done < "$CONFIG_FILE"
}

_dispatch_plugin() {
    # Returns 0 if a plugin handled the command, 1 otherwise
    local cmd="$1"; shift
    for plugin_id in "${!_LOADED_PLUGINS[@]}"; do
        local plugin_file="$PLUGIN_DIR/${plugin_id}.plugin"
        [[ -f "$plugin_file" ]] || continue
        # shellcheck disable=SC1090
        source "$plugin_file"
        if [[ " ${PLUGIN_COMMANDS[*]:-} " =~ " $cmd " ]]; then
            "plugin_cmd_${cmd}" "$@"
            return 0
        fi
    done
    return 1
}

_scaffold_plugin() {
    local plugin_id="$1" plugin_file="$2"
    local short_name="${plugin_id##*.}"
    cat > "$plugin_file" <<SCAFFOLD
# =============================================================================
#  Plugin: ${plugin_id}
#  Generated by pkg v${VERSION} on $(date '+%Y-%m-%d %H:%M:%S')
#
#  Drop this file in: ${PLUGIN_DIR}/
#  Enable by adding a line under [plugins] in: ${CONFIG_FILE}
#      ${plugin_id}
# =============================================================================

PLUGIN_NAME="${short_name}"
PLUGIN_VERSION="0.1.0"
PLUGIN_AUTHOR=""
PLUGIN_DESC="Description of the ${short_name} plugin"

# Commands this plugin handles (no spaces in names)
PLUGIN_COMMANDS=("${short_name}-example")

# Called by: pkg plugin help  |  pkg help
plugin_help() {
    printf "  \${GREEN}%-28s\${NC} %s\n" "${short_name}-example <arg>" "An example command"
}

# pkg ${short_name}-example <arg>
plugin_cmd_${short_name}-example() {
    local arg="\${1:-}"
    msg "[\$PLUGIN_NAME v\$PLUGIN_VERSION] example called with: '\$arg'"
}
SCAFFOLD
}

cmd_plugin() {
    local subcmd="${1:-list}"
    case "$subcmd" in
        list)
            banner "Plugins"
            if [[ ${#_LOADED_PLUGINS[@]} -eq 0 ]]; then
                info "No plugins loaded."
                echo -e "  ${DIM}Enable plugins under [plugins] in: $CONFIG_FILE${NC}"
                echo -e "  ${DIM}Install:  pkg plugin install <com.vendor.name>${NC}"
                echo -e "  ${DIM}Scaffold: pkg plugin create  <com.vendor.name>${NC}"
            else
                for id in "${!_LOADED_PLUGINS[@]}"; do
                    local plugin_file="$PLUGIN_DIR/${id}.plugin"
                    # shellcheck disable=SC1090
                    source "$plugin_file" 2>/dev/null
                    printf "  ${GREEN}●${NC} ${BOLD}%-35s${NC}  ${DIM}%s${NC}\n" \
                        "$id" "${_LOADED_PLUGINS[$id]} — ${PLUGIN_DESC:-}"
                done
            fi
            ;;

        install)
            need_arg "${2:-}" "plugin install <com.vendor.name>"
            local plugin_id="$2"
            [[ "$plugin_id" =~ ^com\. ]] || die "Plugin ID must follow reverse-domain format: com.vendor.name"
            local plugin_file="$PLUGIN_DIR/${plugin_id}.plugin"
            step "Downloading plugin: $plugin_id"
            _dl "$STABLE_REPO_URL/plugins/${plugin_id}.plugin" "$plugin_file" \
                || die "Plugin '$plugin_id' not found in pkg-stable-repo."
            # Enable in config if not already present
            if ! grep -qF "$plugin_id" "$CONFIG_FILE" 2>/dev/null; then
                awk -v id="$plugin_id" '
                    /^\[plugins\]/ { print; found=1; next }
                    found && !inserted { print id; inserted=1 }
                    { print }
                ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
                && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
            fi
            ok "Plugin $plugin_id installed — restart pkg or re-source to activate"
            _history_add "PLUGIN_INSTALL" "$plugin_id"
            ;;

        remove)
            need_arg "${2:-}" "plugin remove <com.vendor.name>"
            local plugin_id="$2"
            rm -f "$PLUGIN_DIR/${plugin_id}.plugin"
            sed -i "/^[[:space:]]*${plugin_id}[[:space:]]*$/d" "$CONFIG_FILE"
            ok "Plugin $plugin_id removed"
            _history_add "PLUGIN_REMOVE" "$plugin_id"
            ;;

        create)
            need_arg "${2:-}" "plugin create <com.vendor.name>"
            local plugin_id="$2"
            [[ "$plugin_id" =~ ^com\. ]] || die "Plugin ID must follow reverse-domain format: com.vendor.name"
            local plugin_file="$PLUGIN_DIR/${plugin_id}.plugin"
            [[ -f "$plugin_file" ]] && die "Plugin already exists: $plugin_file"
            _scaffold_plugin "$plugin_id" "$plugin_file"
            ok "Scaffolded plugin: $plugin_file"
            info "Edit the file, then add '$plugin_id' under [plugins] in $CONFIG_FILE"
            ;;

        help)
            banner "Plugin Commands"
            if [[ ${#_LOADED_PLUGINS[@]} -eq 0 ]]; then
                info "No plugins loaded."; return 0
            fi
            for plugin_id in "${!_LOADED_PLUGINS[@]}"; do
                local plugin_file="$PLUGIN_DIR/${plugin_id}.plugin"
                [[ -f "$plugin_file" ]] || continue
                # shellcheck disable=SC1090
                source "$plugin_file"
                echo -e "\n${BOLD}${CYAN}$plugin_id${NC}  ${DIM}${_LOADED_PLUGINS[$plugin_id]}${NC}"
                has_cmd plugin_help && plugin_help || echo "  (no help provided)"
            done
            ;;

        *)
            die "Usage: pkg plugin {list|install <id>|remove <id>|create <id>|help}"
            ;;
    esac
}

# ── Version ───────────────────────────────────────────────────────────────────
cmd_version() {
    echo -e "${BOLD}${GREEN}$TITLE${NC} ${BOLD}v$VERSION${NC}"
    echo -e "  ${DIM}Config : $CONFIG_FILE${NC}"
    echo -e "  ${DIM}Data   : $DATA_DIR${NC}"
    echo -e "  ${DIM}Cache  : $CACHE_DIR${NC}"
    echo -e "  ${DIM}Plugins: $PLUGIN_DIR (${#_LOADED_PLUGINS[@]} loaded)${NC}"
}

# ── Help ──────────────────────────────────────────────────────────────────────
cmd_help() {
    echo -e "${BOLD}${GREEN}$TITLE${NC}  v${VERSION}"
    echo -e "  ${DIM}Config  : $CONFIG_FILE${NC}"
    echo -e "  ${DIM}History : $HISTORY_FILE${NC}"
    echo -e "  ${DIM}Plugins : $PLUGIN_DIR  (${#_LOADED_PLUGINS[@]} loaded)${NC}"
    echo
    echo -e "${BOLD}Usage:${NC}  pkg <command> [args]"

    _h() { printf "    ${GREEN}%-26s${NC} %s\n" "$1" "$2"; }
    _s() { echo -e "\n  ${BOLD}$1${NC}"; }

    _s "Package commands"
    _h "install <pkg...>"         "Install from official repos or AUR"
    _h "remove  <pkg...>"         "Remove package(s) and orphaned deps"
    _h "update"                   "Upgrade all system + AUR packages"
    _h "search  <query>"          "Search official repos and AUR"
    _h "info    <pkg>"            "Show package info"
    _h "list    [filter]"         "List explicitly installed packages"
    _h "autoremove"               "Remove all orphaned packages"
    _h "clean"                    "Clear build/download caches"

    _s "Build & Pull"
    _h "build   <pkg>"            "Fetch PKGBUILD from repo and build"
    _h "pull script <path>"       "Install a script from pkg-stable-repo"
    _h "pull clone  <user/repo>"  "Clone a GitHub repo; build if PKGBUILD"
    _h "pull url    <url>"        "Download & install from arbitrary URL"

    _s "Network"
    _h "git clone <user/repo>"    "Clone a GitHub repository"
    _h "git pull  <dir>"          "Pull latest commits in a local repo"
    _h "git status/log/diff <dir>" "Git helpers"
    _h "wget <url> [dir]"         "Download with wget (resumable)"
    _h "curl <url> [file]"        "Download with curl"

    _s "Package pinning"
    _h "pin     <pkg>"            "Pin package (skip during updates)"
    _h "unpin   <pkg>"            "Unpin a package"
    _h "pinned"                   "List all pinned packages"

    _s "Configuration  (pkg.conf)"
    _h "config show"              "Print current config"
    _h "config edit"              "Open config in \$EDITOR"
    _h "config set <s.k> <val>"  "Set a config value"
    _h "config get <s.k>"        "Read a config value"
    _h "config reset"             "Restore default config"
    _h "config path"              "Print config file location"

    _s "Plugins  [plugins] in pkg.conf"
    _h "plugin list"              "List loaded plugins"
    _h "plugin install <id>"      "Install plugin (com.vendor.name)"
    _h "plugin remove  <id>"      "Uninstall plugin"
    _h "plugin create  <id>"      "Scaffold a new plugin file"
    _h "plugin help"              "Show commands from loaded plugins"

    _s "System"
    _h "update-self"              "Update pkg itself from upstream"
    _h "doctor"                   "Dependency & health check"
    _h "history [n]"              "Show last n operations (default 25)"
    _h "history clear"            "Clear all history"
    _h "export  [file]"           "Export installed package list"
    _h "import  <file>"           "Install packages from exported list"
    _h "lock"                     "Lock terminal via vlock"
    _h "version"                  "Show version info"
    _h "help"                     "Show this message"

    # Loaded plugin commands
    if [[ ${#_LOADED_PLUGINS[@]} -gt 0 ]]; then
        _s "Plugin commands  (loaded)"
        for plugin_id in "${!_LOADED_PLUGINS[@]}"; do
            local plugin_file="$PLUGIN_DIR/${plugin_id}.plugin"
            [[ -f "$plugin_file" ]] || continue
            # shellcheck disable=SC1090
            source "$plugin_file"
            echo -e "    ${CYAN}[$plugin_id]${NC}  ${DIM}${_LOADED_PLUGINS[$plugin_id]}${NC}"
            has_cmd plugin_help && plugin_help || true
        done
    fi

    echo
    echo -e "  ${BOLD}Repos:${NC}"
    echo -e "    Packages : $STABLE_REPO_URL"
    echo -e "    pkg self : $PKG_SELF_URL"
}

# ── Bootstrap & dispatch ──────────────────────────────────────────────────────
_load_config
_load_plugins

# Acquire write lock only for mutating operations
case "${1:-}" in
    install|add|remove|del|rm|update|up|build|make|pull|update-self|autoremove|clean|import)
        _acquire_lock ;;
esac

case "${1:-}" in
    install|add)        shift; cmd_install      "$@" ;;
    remove|del|rm)      shift; cmd_remove       "$@" ;;
    update|up)                 cmd_update            ;;
    search|s)           shift; cmd_search       "$@" ;;
    info|show)          shift; cmd_info         "$@" ;;
    list|ls)            shift; cmd_list         "$@" ;;
    autoremove)                cmd_autoremove        ;;
    clean)                     cmd_clean             ;;
    build|make)         shift; cmd_build        "$@" ;;
    pull)               shift; cmd_pull         "$@" ;;
    git)                shift; cmd_git          "$@" ;;
    wget)               shift; cmd_wget         "$@" ;;
    curl)               shift; cmd_curl         "$@" ;;
    pin)                shift; cmd_pin          "$@" ;;
    unpin)              shift; cmd_unpin        "$@" ;;
    pinned)                    cmd_pinned            ;;
    config)             shift; cmd_config       "$@" ;;
    plugin)             shift; cmd_plugin       "$@" ;;
    doctor)                    cmd_doctor            ;;
    history)
        shift
        [[ "${1:-}" == "clear" ]] && cmd_history_clear || cmd_history "${1:-}"
        ;;
    export)             shift; cmd_export       "$@" ;;
    import)             shift; cmd_import       "$@" ;;
    update-self)               cmd_update_self       ;;
    lock)                      cmd_lock              ;;
    version|-V|--version)      cmd_version           ;;
    help|--help|-h|"")         cmd_help              ;;
    *)
        # Try plugins before giving up
        if _dispatch_plugin "$1" "${@:2}"; then
            exit 0
        fi
        err "Unknown command: '$1'"
        echo
        cmd_help
        exit 1
        ;;
esac
