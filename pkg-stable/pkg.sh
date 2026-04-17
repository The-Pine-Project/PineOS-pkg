#!/usr/bin/env bash
# =============================================================================
#  pkg — PineOS Package Manager
#  Repos:
#    Stable packages : https://github.com/The-Pine-Project/pkg-stable-repo
#    pkg itself      : https://github.com/The-Pine-Project/PineOS-pkg
# =============================================================================

# ── Config ────────────────────────────────────────────────────────────────────
readonly TITLE="PineOS Package Manager"
readonly VERSION="1.1.0"

readonly STABLE_REPO_URL="https://github.com/The-Pine-Project/pkg-stable-repo/raw/refs/heads/main"
readonly PKG_SELF_URL="https://github.com/The-Pine-Project/PineOS-pkg/raw/refs/heads/main"
readonly PKGBUILD_SELF_URL="https://github.com/The-Pine-Project/PineOS-pkg/raw/refs/heads/main/pkg-stable/PKGBUILD"
readonly ARCH="x86_64"
readonly BUILD_BASE="/tmp/pine-build"

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
msg()  { echo -e "${GREEN}[pkg]${NC} $*"; }
info() { echo -e "${BLUE}[pkg]${NC} $*"; }
warn() { echo -e "${YELLOW}[pkg]${NC} $*"; }
err()  { echo -e "${RED}[pkg]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

need_arg() {
    [[ -z "$1" ]] && die "Usage: pkg $2"
}

has_cmd() { command -v "$1" &>/dev/null; }

aur_helper() {
    if has_cmd paru; then echo "paru"
    elif has_cmd yay; then echo "yay"
    else die "No AUR helper found. Install paru or yay."; fi
}

# ── install ───────────────────────────────────────────────────────────────────
cmd_install() {
    need_arg "$1" "install <package>"
    local target="$1"

    if pacman -Si "$target" &>/dev/null; then
        msg "Installing $target from official repos..."
        sudo pacman -S --noconfirm "$target"
    else
        local aur; aur=$(aur_helper)
        msg "Not in official repos — trying AUR via $aur..."
        "$aur" -S --noconfirm "$target"
    fi
}

# ── remove ────────────────────────────────────────────────────────────────────
cmd_remove() {
    need_arg "$1" "remove <package>"
    msg "Removing $1 and its unneeded dependencies..."
    sudo pacman -Rs --noconfirm "$1"
}

# ── update ────────────────────────────────────────────────────────────────────
cmd_update() {
    msg "Syncing databases and upgrading system packages..."
    sudo pacman -Syu --noconfirm

    if has_cmd paru; then
        msg "Upgrading AUR packages via paru..."
        paru -Sua --noconfirm
    elif has_cmd yay; then
        msg "Upgrading AUR packages via yay..."
        yay -Sua --noconfirm
    fi
}

# ── search ────────────────────────────────────────────────────────────────────
cmd_search() {
    need_arg "$1" "search <query>"
    info "Official repos:"
    pacman -Ss "$1"

    local aur; aur=$(aur_helper)
    info "AUR (via $aur):"
    "$aur" -Ss "$1"
}

# ── build (source build from pkg-stable-repo) ─────────────────────────────────
cmd_build() {
    need_arg "$1" "build <package>"
    local pkg="$1"
    local build_dir="$BUILD_BASE/$pkg"

    msg "Setting up build directory: $build_dir"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    cd "$build_dir" || die "Cannot enter build directory."

    msg "Fetching PKGBUILD for $pkg from pkg-stable-repo..."
    curl -fsSL "$STABLE_REPO_URL/$ARCH/$pkg/PKGBUILD" -o PKGBUILD \
        || die "PKGBUILD for '$pkg' not found in pkg-stable-repo."

    # Pull optional .install file if PKGBUILD references one
    if grep -q "^install=" PKGBUILD; then
        local install_file
        install_file=$(grep "^install=" PKGBUILD | cut -d'=' -f2 | tr -d "'\"")
        msg "Fetching install script: $install_file"
        curl -fsSL "$STABLE_REPO_URL/$ARCH/$pkg/$install_file" -o "$install_file" \
            || warn "Could not fetch $install_file — continuing anyway."
    fi

    # Pull any extra source files listed in PKGBUILD (non-URL entries)
    while IFS= read -r src_entry; do
        [[ "$src_entry" =~ ^https?:// ]] && continue   # skip real URLs
        [[ "$src_entry" == "PKGBUILD" ]] && continue
        msg "Fetching source file: $src_entry"
        curl -fsSL "$STABLE_REPO_URL/$ARCH/$pkg/$src_entry" -o "$src_entry" \
            || warn "Could not fetch $src_entry — build may fail."
    done < <(grep -Po "(?<=source=\()[^)]*(?=\))" PKGBUILD | tr " '" '\n' | tr -d '"' | grep -v '^$')

    msg "Building $pkg..."
    makepkg -sic --noconfirm
}

# ── pull (download & install a raw script/binary OR clone & build) ─────────────
cmd_pull() {
    local subcmd="$1"
    local target="$2"

    case "$subcmd" in
        script|bin)
            # pkg pull script <repo_path>
            # repo_path is relative to STABLE_REPO_URL, e.g. "tools/myscript.sh"
            need_arg "$target" "pull script <repo/path/to/file>"
            local filename; filename=$(basename "$target")
            local dest="/usr/local/bin/${filename%.sh}"

            msg "Pulling script from pkg-stable-repo: $target"
            sudo curl -fsSL "$STABLE_REPO_URL/$target" -o "$dest" \
                || die "Could not fetch '$target' from pkg-stable-repo."
            sudo chmod +x "$dest"
            msg "Installed to $dest"
            ;;

        clone|src)
            # pkg pull clone <github_user/repo>
            need_arg "$target" "pull clone <user/repo>"
            local clone_dir="$BUILD_BASE/clones/$(basename "$target")"

            msg "Cloning https://github.com/$target ..."
            rm -rf "$clone_dir"
            git clone --depth=1 "https://github.com/$target" "$clone_dir" \
                || die "Clone failed for '$target'."

            if [[ -f "$clone_dir/PKGBUILD" ]]; then
                msg "PKGBUILD found — building with makepkg..."
                cd "$clone_dir" || die "Cannot enter clone directory."
                makepkg -sic --noconfirm
            else
                info "No PKGBUILD found. Sources available at: $clone_dir"
            fi
            ;;

        *)
            die "Usage: pkg pull {script|clone} <target>
  pull script <repo/path/file.sh>   Download & install a script from pkg-stable-repo
  pull clone  <user/repo>           Clone a GitHub repo and build if PKGBUILD exists"
            ;;
    esac
}

# ── update-self ───────────────────────────────────────────────────────────────
cmd_update_self() {
    msg "Checking for pkg updates..."

    # 1. Update the pkg script itself
    sudo curl -fsSL "$PKG_SELF_URL/pkg-stable/pkg.sh" -o /tmp/pkg_new.sh \
        || die "Failed to fetch latest pkg.sh — check your connection."
    sudo mv /tmp/pkg_new.sh /usr/bin/pkg
    sudo chmod +x /usr/bin/pkg
    msg "pkg script updated."

    # 2. Auto-bump pkgver in the local PKGBUILD (if present)
    local pkgbuild_path
    for candidate in \
        "/usr/share/pkg/PKGBUILD" \
        "$HOME/.local/share/pkg/PKGBUILD" \
        "$BUILD_BASE/pkg-stable/PKGBUILD"
    do
        [[ -f "$candidate" ]] && pkgbuild_path="$candidate" && break
    done

    if [[ -n "$pkgbuild_path" ]]; then
        msg "Fetching latest PKGBUILD for version info..."
        local remote_ver
        remote_ver=$(curl -fsSL "$PKGBUILD_SELF_URL" | grep "^pkgver=" | cut -d'=' -f2)

        if [[ -n "$remote_ver" ]]; then
            local current_ver
            current_ver=$(grep "^pkgver=" "$pkgbuild_path" | cut -d'=' -f2)
            if [[ "$remote_ver" != "$current_ver" ]]; then
                sed -i "s/^pkgver=.*/pkgver=$remote_ver/" "$pkgbuild_path"
                # Also bump pkgrel back to 1 on a new upstream version
                sed -i "s/^pkgrel=.*/pkgrel=1/" "$pkgbuild_path"
                msg "Bumped pkgver: $current_ver → $remote_ver in $pkgbuild_path"
            else
                info "pkgver already up to date ($current_ver)."
            fi
        fi
    else
        info "No local PKGBUILD found to version-bump (not installed via makepkg?)."
    fi

    msg "pkg is up to date!"
}

# ── lock ──────────────────────────────────────────────────────────────────────
cmd_lock() {
    has_cmd vlock || die "vlock is not installed. Run: pkg install vlock"
    vlock -a
}

# ── info ──────────────────────────────────────────────────────────────────────
cmd_info() {
    need_arg "$1" "info <package>"
    pacman -Qi "$1" 2>/dev/null || pacman -Si "$1" 2>/dev/null \
        || die "Package '$1' not found locally or in repos."
}

# ── list ──────────────────────────────────────────────────────────────────────
cmd_list() {
    msg "Explicitly installed packages:"
    pacman -Qe
}

# ── help ──────────────────────────────────────────────────────────────────────
cmd_help() {
    echo -e "${BOLD}${GREEN}$TITLE${NC} v$VERSION"
    echo
    echo -e "${BOLD}Usage:${NC} pkg <command> [options]"
    echo
    echo -e "${BOLD}Package commands:${NC}"
    echo -e "  ${GREEN}install${NC}  <pkg>            Install from official repos or AUR"
    echo -e "  ${GREEN}remove${NC}   <pkg>            Remove package and unneeded deps"
    echo -e "  ${GREEN}update${NC}                    Upgrade all system + AUR packages"
    echo -e "  ${GREEN}search${NC}   <query>          Search official repos and AUR"
    echo -e "  ${GREEN}info${NC}     <pkg>            Show package details"
    echo -e "  ${GREEN}list${NC}                      List explicitly installed packages"
    echo
    echo -e "${BOLD}Build commands (from pkg-stable-repo):${NC}"
    echo -e "  ${GREEN}build${NC}    <pkg>            Fetch PKGBUILD + sources and build via makepkg"
    echo
    echo -e "${BOLD}Pull commands (from GitHub):${NC}"
    echo -e "  ${GREEN}pull script${NC} <path/file>   Download & install a raw script from pkg-stable-repo"
    echo -e "  ${GREEN}pull clone${NC}  <user/repo>   Clone a GitHub repo; build if PKGBUILD is present"
    echo
    echo -e "${BOLD}System commands:${NC}"
    echo -e "  ${GREEN}update-self${NC}               Update pkg itself + auto-bump pkgver in local PKGBUILD"
    echo -e "  ${GREEN}lock${NC}                      Lock the terminal via vlock"
    echo -e "  ${GREEN}help${NC}                      Show this message"
    echo
    echo -e "${BOLD}Repos:${NC}"
    echo -e "  Packages : $STABLE_REPO_URL"
    echo -e "  pkg self : $PKG_SELF_URL"
}

# ── Entry point ───────────────────────────────────────────────────────────────
case "$1" in
    install|add)       cmd_install    "$2" ;;
    remove|del|rm)     cmd_remove     "$2" ;;
    update|up)         cmd_update          ;;
    search|s)          cmd_search     "$2" ;;
    build|make)        cmd_build      "$2" ;;
    pull)              cmd_pull       "$2" "$3" ;;
    update-self)       cmd_update_self     ;;
    lock)              cmd_lock            ;;
    info|show)         cmd_info       "$2" ;;
    list|ls)           cmd_list            ;;
    help|--help|-h)    cmd_help            ;;
    *)
        err "Unknown command: '$1'"
        echo
        cmd_help
        exit 1
        ;;
esac
