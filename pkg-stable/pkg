#!/usr/bin/env bash

# PineOS Branding
TITLE="PineOS Package Manager"
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

case "$1" in
    install|add)
        TARGET=$2
        # ... (previous install logic)
        ;;
    remove|del)
        TARGET=$2
        # ... (previous remove logic)
        ;;
    update|up)
        # ... (previous update logic)
        ;;
    search|find|s)
        QUERY=$2
        if [ -z "$QUERY" ]; then echo "Usage: pkg search <query>"; exit 1; fi
        
        echo -e "${GREEN}--- Searching PineOS & Official Repos ---${NC}"

        pacman -Ss "$QUERY" | sed "s%^core/.*%${BLUE}&${NC}%" | sed "s%^extra/.*%${BLUE}&${NC}%"
        
        echo -e "\n${BLUE}--- Searching Arch User Repository (AUR) ---${NC}"
        if command -v paru &>/dev/null; then
            paru -Ss "$QUERY"
        elif command -v yay &>/dev/null; then
            yay -Ss "$QUERY"
        else
            echo "Install 'paru' or 'yay' to see AUR results."
        fi
        ;;
    *)
        echo "Usage: pkg {install|remove|update|search} <package>"
        exit 1
        ;;
esac

