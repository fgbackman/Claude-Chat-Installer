#!/bin/bash
# Removes Claude Chat from Applications and the Dock. Your chats and API key are kept unless you choose otherwise.
set -uo pipefail
APP_NAME="Claude Chat"
PB=/usr/libexec/PlistBuddy

pkill -x ClaudeChat >/dev/null 2>&1 && sleep 1

for dir in /Applications "$HOME/Applications"; do
    if [ -d "$dir/$APP_NAME.app" ]; then
        rm -rf "$dir/$APP_NAME.app" && echo "Removed $dir/$APP_NAME.app"
    fi
done

# Remove the Dock tile(s): export the Dock settings, edit the copy, import it back.
TMP="$(mktemp -t dock).plist"
if defaults export com.apple.dock "$TMP" 2>/dev/null; then
    removed=0
    i=0
    while $PB -c "Print persistent-apps:$i" "$TMP" >/dev/null 2>&1; do
        url="$($PB -c "Print persistent-apps:$i:tile-data:file-data:_CFURLString" "$TMP" 2>/dev/null || true)"
        if echo "$url" | grep -Eq "Claude( |%20)Chat\.app"; then
            $PB -c "Delete persistent-apps:$i" "$TMP" && removed=1
        else
            i=$((i + 1))
        fi
    done
    if [ "$removed" -eq 1 ]; then
        defaults import com.apple.dock "$TMP"
        killall Dock >/dev/null 2>&1 || true
        echo "Removed it from the Dock."
    fi
    rm -f "$TMP"
fi

echo ""
read -r -p "Also delete your saved chats, attachments and settings? [y/N] " answer
if [[ "$answer" =~ ^[Yy]$ ]]; then
    rm -rf "$HOME/Library/Application Support/ClaudeChat"
    defaults delete com.fred.ClaudeChat >/dev/null 2>&1 || true
    security delete-generic-password -s "ClaudeChat.anthropic-api-key" >/dev/null 2>&1 || true
    echo "Deleted chats, settings and the saved API key."
else
    echo "Kept your chats in ~/Library/Application Support/ClaudeChat and your key in the Keychain."
fi
echo "Claude Chat is uninstalled."
