#!/usr/bin/env bash

# --- PineOS Configuration ---
TITLE="PineOS Package Manager"
REPO_URL="https://github.com/The-Pine-Project/pkg-stable-repo/blob/main/x86_64/"
ARCH="x86_64"
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Internal Functions ---
pine_msg() { echo -e "${GREEN}[PineOS]${NC} $1"; }

update_self() {
    pine_msg "Checking for pkg updates..."
    sudo curl -fsSL "${REPO_URL}/${ARCH}/raw/pkg-stable/pkg.sh" -o /tmp/pkg.sh
    if [[ $? -eq 0 ]]; then
        sudo mv /tmp/pkg.sh /usr/bin/pkg
        sudo chmod +x /usr/bin/pkg
        pine_msg "pkg has been updated successfully!"
    else
        echo "Update failed. Check your internet connection."
    fi
}

build_source() {
    local PKG_NAME=$1
    if [ -z "$PKG_NAME" ]; then echo "Usage: pkg build <package>"; exit 1; fi

    local BUILD_DIR="/tmp/pine-build/$PKG_NAME"
    mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR" || exit

    pine_msg "Fetching source files for $PKG_NAME from raw repo..."
    curl -fsSL "$REPO_URL/$ARCH/raw/$PKG_NAME/PKGBUILD" -o PKGBUILD

    if [ ! -f "PKGBUILD" ]; then
        echo "Error: PKGBUILD for $PKG_NAME not found."
        exit 1
    fi

    # Check for .install file if defined in PKGBUILD
    if grep -q "install=" PKGBUILD; then
        INSTALL_FILE=$(grep "install=" PKGBUILD | cut -d'=' -f2 | tr -d "'\"")
        curl -fsSL "$REPO_URL/$ARCH/raw/$PKG_NAME/$INSTALL_FILE" -o "$INSTALL_FILE"
    fi

    pine_msg "Starting build for $PKG_NAME..."
    makepkg -sic --noconfirm
}

# --- Main Logic ---
case "$1" in
    install|add)
        TARGET=$2
        if pacman -Si "$TARGET" &>/dev/null; then
            sudo pacman -S --noconfirm "$TARGET"
        else
            pine_msg "Not in repos, trying AUR..."
            paru -S --noconfirm "$TARGET" || yay -S --noconfirm "$TARGET"
        fi
        ;;
    remove|del)
        sudo pacman -Rs --noconfirm "$2"
        ;;
    update|up)
        pine_msg "Updating system and repos..."
        sudo pacman -Syu --noconfirm
        command -v paru &>/dev/null && paru -Sua --noconfirm
        ;;
    search|s)
        pine_msg "Searching Repos..."
        pacman -Ss "$2"
        pine_msg "Searching AUR..."
        command -v paru &>/dev/null && paru -Ss "$2" || yay -Ss "$2"
        ;;
    build|make)
        build_source "$2"
        ;;
    update-self)
        update_self
        ;;
    lock)
        vlock -a
        ;;
    *)
        echo "PineOS Package Manager (pkg)"
        echo "Usage: pkg {install|remove|update|search|build|update-self|lock} [package]"
        exit 1
        ;;
esac
