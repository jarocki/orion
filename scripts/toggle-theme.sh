#!/bin/bash
#
# Orion-X Phoenix Edition v2.0.0-rc4
# Theme Toggle Script
#
# @decision DEC-PHASE9-003
# @title toggle-theme.sh: single phoenix wallpaper asset; stale refs removed
# @status accepted
# @rationale rc3 shipped with references to orionx-green-wallpaper.png and
#   orionx-dark-wallpaper.png, neither of which exists in the ISO. The only
#   real branded wallpaper asset is orionx-phoenix-wallpaper.png (staged to
#   /opt/orionx/theme/wallpapers/ by stage_application_content in build-iso.sh).
#   Both theme variants now point to the same phoenix asset. A future work item
#   can produce separate dark/green variants; until then, using the one real
#   asset is strictly better than referencing missing files.
#   xfconf property path: /backdrop/screen0/monitor0/workspace0/last-image
#   (same path set statically in 0100-create-user.hook.chroot xfce4-desktop.xml).
#   Terminal config switched from Terminator (not installed) to xfce4-terminal.
#   Theme dir corrected from /usr/share/orionx/theme to /opt/orionx/theme (the
#   actual staging path used by stage_application_content).

# Define paths
THEME_DIR="/opt/orionx/theme"
WALLPAPER_DIR="$THEME_DIR/wallpapers"

# Log file
LOGFILE="/var/log/orionx/theme_toggle.log"
mkdir -p "/var/log/orionx" 2>/dev/null

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

log "Starting theme toggle operation"

# Determine current theme
CURRENT_THEME="dark"
if [ -f "$HOME/.orionx_theme" ]; then
    CURRENT_THEME=$(cat "$HOME/.orionx_theme")
fi

log "Current theme: $CURRENT_THEME"

# Toggle theme
if [ "$CURRENT_THEME" = "dark" ]; then
    NEW_THEME="green"
    log "Switching to green theme"
else
    NEW_THEME="dark"
    log "Switching to dark theme"
fi

# Update desktop wallpaper (XFCE) using xfconf-query.
# Both themes use the phoenix asset — the only staged branded wallpaper.
# Stale references to orionx-green-wallpaper.png / orionx-dark-wallpaper.png
# have been removed (DEC-PHASE9-003): those files do not exist in the ISO.
WALLPAPER="$WALLPAPER_DIR/orionx-phoenix-wallpaper.png"
log "Setting XFCE wallpaper to phoenix asset: $WALLPAPER"
if command -v xfconf-query > /dev/null 2>&1; then
    xfconf-query -c xfce4-desktop \
        -p /backdrop/screen0/monitor0/workspace0/last-image \
        -s "$WALLPAPER" 2>/dev/null \
        || log "WARNING: xfconf-query failed — XFCE session may not be running"
    log "XFCE wallpaper updated to $WALLPAPER"
else
    log "xfconf-query not found, unable to update XFCE wallpaper at runtime"
fi

# Update xfce4-terminal color theme
XFCE_TERM_CONFIG_DIR="$HOME/.config/xfce4/terminal"
mkdir -p "$XFCE_TERM_CONFIG_DIR"
TERM_CONFIG_FILE="$XFCE_TERM_CONFIG_DIR/terminalrc"

if [ "$NEW_THEME" = "green" ]; then
    log "Applying green terminal theme"
    cat > "$TERM_CONFIG_FILE" << 'TERMRC_EOF'
[Configuration]
FontName=Monospace 12
MiscAlwaysShowTabs=FALSE
MiscBell=FALSE
MiscCursorBlinks=TRUE
MiscCursorShape=TERMINAL_CURSOR_SHAPE_BLOCK
MiscDefaultGeometry=80x24
MiscMenubarDefault=FALSE
ColorForeground=#0cfa54
ColorBackground=#031a11
ColorCursor=#25c3dc
ColorPalette=#2e3436;#cc0000;#4e9a06;#c4a000;#3465a4;#75507b;#06989a;#d3d7cf;#555753;#ef2929;#8ae234;#fce94f;#729fcf;#ad7fa8;#34e2e2;#eeeeec
TERMRC_EOF
else
    log "Applying dark/amber terminal theme"
    cat > "$TERM_CONFIG_FILE" << 'TERMRC_EOF'
[Configuration]
FontName=Monospace 12
MiscAlwaysShowTabs=FALSE
MiscBell=FALSE
MiscCursorBlinks=TRUE
MiscCursorShape=TERMINAL_CURSOR_SHAPE_BLOCK
MiscDefaultGeometry=80x24
MiscMenubarDefault=FALSE
ColorForeground=#ff9900
ColorBackground=#1a1a1a
ColorCursor=#aaaaaa
ColorPalette=#2e3436;#cc0000;#4e9a06;#c4a000;#3465a4;#75507b;#06989a;#d3d7cf;#555753;#ef2929;#8ae234;#fce94f;#729fcf;#ad7fa8;#34e2e2;#eeeeec
TERMRC_EOF
fi
log "xfce4-terminal configuration updated: $TERM_CONFIG_FILE"

# Update bash prompt color
if [ "$NEW_THEME" = "green" ]; then
    PS1_COLOR="\[\033[01;32m\]"  # Green
else
    PS1_COLOR="\[\033[38;5;214m\]"  # Amber/orange
fi

# Update .bashrc with new prompt color
if [ -f "$HOME/.bashrc" ]; then
    # Remove any existing Orion-X PS1 settings
    sed -i '/# Orion-X Phoenix Edition PS1/d' "$HOME/.bashrc"
    sed -i '/^PS1=/d' "$HOME/.bashrc"

    # Add new PS1 setting
    echo "# Orion-X Phoenix Edition PS1" >> "$HOME/.bashrc"
    printf "PS1='%s[Orion-X]\\[\\033[00m\\] \\[\\033[01;34m\\]\\w\\[\\033[00m\\]\\\\$ '\n" \
        "${PS1_COLOR}" >> "$HOME/.bashrc"

    log "Bash prompt updated"
else
    log "$HOME/.bashrc not found, skipping bash prompt update"
fi

# Save current theme
echo "$NEW_THEME" > "$HOME/.orionx_theme"

log "Theme toggle complete. New theme: $NEW_THEME"
echo "Switched to $NEW_THEME theme. Please restart your terminal for full effect."

exit 0
