#!/bin/bash
# Claude Chat installer.
# Builds the app on this Mac, installs it in Applications, pins it to the Dock and launches it.
# The menu bar icon appears whenever the app is running.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/app"
LOG="$HERE/install-log.txt"
APP_NAME="Claude Chat"

say()  { printf "\n\033[1m%s\033[0m\n" "$*"; }
fail() { printf "\n\033[31m%s\033[0m\n" "$*"; echo "Full log: $LOG"; exit 1; }

say "Claude Chat installer"

# 1. macOS version
ver="$(sw_vers -productVersion)"
major="${ver%%.*}"
[ "$major" -ge 14 ] || fail "Claude Chat needs macOS 14 (Sonoma) or later. This Mac has macOS $ver."

# 2. Apple's Swift compiler (Command Line Tools or Xcode)
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swift >/dev/null 2>&1; then
    say "Apple's free Command Line Tools are needed to build the app. Opening their installer…"
    xcode-select --install >/dev/null 2>&1 || true
    fail "When the Command Line Tools finish installing, run this installer again."
fi

# 3. Build
say "Building Claude Chat (about a minute the first time)…"
cd "$SRC" || fail "Can't find the app folder next to this installer."
swift build -c release 2>&1 | tee "$LOG"
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo ""
    grep -E "error:" "$LOG" | head -20
    fail "The build failed. Send install-log.txt (in the installer folder) to Claude and it can fix it."
fi
BIN="$(swift build -c release --show-bin-path)/ClaudeChat"
[ -x "$BIN" ] || fail "The build finished but the app binary is missing."

# 4. Assemble the .app bundle
say "Packaging…"
STAGE="$HERE/build/$APP_NAME.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/ClaudeChat"
cp "$SRC/Resources/AppIcon.icns" "$SRC/Resources/MenuBarIcon.png" "$SRC/Resources/MenuBarIcon@2x.png" \
   "$STAGE/Contents/Resources/"

cat > "$STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>        <string>ClaudeChat</string>
    <key>CFBundleIdentifier</key>        <string>com.fred.ClaudeChat</string>
    <key>CFBundleName</key>              <string>Claude Chat</string>
    <key>CFBundleDisplayName</key>       <string>Claude Chat</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.0</string>
    <key>CFBundleVersion</key>           <string>4</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSMicrophoneUsageDescription</key>     <string>Claude Chat uses the microphone when you dictate a message.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Claude Chat turns your dictation into text, on your Mac when possible.</string>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$STAGE" >>"$LOG" 2>&1 || echo "Note: ad-hoc signing failed; the app should still open."

# 5. Install. Reuse ~/Applications if an earlier build is there (keeps an existing Dock pin working),
#    otherwise use /Applications when it's writable.
if [ -d "$HOME/Applications/$APP_NAME.app" ]; then
    DEST="$HOME/Applications"
elif [ -w "/Applications" ]; then
    DEST="/Applications"
else
    DEST="$HOME/Applications"
fi
mkdir -p "$DEST"
APP_PATH="$DEST/$APP_NAME.app"

say "Installing to $APP_PATH…"
pkill -x ClaudeChat >/dev/null 2>&1 && sleep 1
rm -rf "$APP_PATH"
ditto "$STAGE" "$APP_PATH" || fail "Couldn't copy the app into $DEST."
xattr -dr com.apple.quarantine "$APP_PATH" >/dev/null 2>&1 || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP_PATH" >/dev/null 2>&1 || true
touch "$APP_PATH"

# 6. Pin to the Dock (once)
if defaults read com.apple.dock persistent-apps 2>/dev/null | grep -Eq "Claude( |%20)Chat\.app"; then
    echo "Already in your Dock."
else
    url="file://${APP_PATH// /%20}/"
    defaults write com.apple.dock persistent-apps -array-add \
        "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$url</string><key>_CFURLStringType</key><integer>15</integer></dict></dict></dict>"
    killall Dock >/dev/null 2>&1 || true
    echo "Added to your Dock."
fi

# 7. Launch
open "$APP_PATH"

say "Done. Claude Chat is installed and running."
echo "• Dock: its icon is pinned there."
echo "• Menu bar: click the chat-bubble icon at the top right for quick questions and your credit."
echo "• First launch: paste your API key from platform.claude.com."
