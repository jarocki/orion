#!/bin/bash
#
# Orion-X Phoenix Edition v1.5.5
# Theme Toggle Script
#
# This script toggles between the dark (amber) and green terminal themes
# and desktop wallpapers in Orion-X.

# Define paths
THEME_DIR="/usr/share/orionx/theme"
WALLPAPER_DIR="$THEME_DIR/wallpapers"
TERM_CONFIG_DIR="$HOME/.config/terminator"
XFCE_CONFIG_DIR="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml"

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

# Update terminal configuration (Terminator)
if [ -d "$TERM_CONFIG_DIR" ]; then
    log "Updating Terminator configuration"
    
    # Create config directory if it doesn't exist
    mkdir -p "$TERM_CONFIG_DIR"
    
    # Create or update Terminator config
    CONFIG_FILE="$TERM_CONFIG_DIR/config"
    
    if [ "$NEW_THEME" = "green" ]; then
        # Green phosphor theme
        cat > "$CONFIG_FILE" << EOF
[global_config]
  title_transmit_bg_color = "#12521c"
  title_inactive_bg_color = "#142311"
  enabled_plugins = LaunchpadBugURLHandler, LaunchpadCodeURLHandler, APTURLHandler, TerminatorThemes
[keybindings]
[profiles]
  [[default]]
    background_color = "#031a11"
    cursor_color = "#25c3dc"
    foreground_color = "#0cfa54"
    palette = "#2e3436:#cc0000:#4e9a06:#c4a000:#3465a4:#75507b:#06989a:#d3d7cf:#555753:#ef2929:#8ae234:#fce94f:#729fcf:#ad7fa8:#34e2e2:#eeeeec"
    background_image = "$THEME_DIR/term-bg-green.png"
    background_type = image
    background_darkness = 0.80
[layouts]
  [[default]]
    [[[window0]]]
      type = Window
      parent = ""
    [[[child1]]]
      type = Terminal
      parent = window0
[plugins]
EOF
    else
        # Dark/amber theme
        cat > "$CONFIG_FILE" << EOF
[global_config]
  title_transmit_bg_color = "#501d2c"
  title_inactive_bg_color = "#3d2121"
  enabled_plugins = LaunchpadBugURLHandler, LaunchpadCodeURLHandler, APTURLHandler, TerminatorThemes
[keybindings]
[profiles]
  [[default]]
    background_color = "#1a1a1a"
    cursor_color = "#aaaaaa"
    foreground_color = "#ff9900"
    palette = "#2e3436:#cc0000:#4e9a06:#c4a000:#3465a4:#75507b:#06989a:#d3d7cf:#555753:#ef2929:#8ae234:#fce94f:#729fcf:#ad7fa8:#34e2e2:#eeeeec"
    background_image = "$THEME_DIR/term-bg-dark.png"
    background_type = image
    background_darkness = 0.85
[layouts]
  [[default]]
    [[[window0]]]
      type = Window
      parent = ""
    [[[child1]]]
      type = Terminal
      parent = window0
[plugins]
EOF
    fi
    
    log "Terminator configuration updated"
else
    log "Terminator configuration directory not found, skipping terminal config"
fi

# Update desktop wallpaper (XFCE)
if [ -d "$XFCE_CONFIG_DIR" ]; then
    log "Updating XFCE desktop wallpaper"
    
    if [ "$NEW_THEME" = "green" ]; then
        WALLPAPER="$WALLPAPER_DIR/orionx-green-wallpaper.png"
    else
        WALLPAPER="$WALLPAPER_DIR/orionx-dark-wallpaper.png"
    fi
    
    # Update XFCE wallpaper using xfconf-query
    if command -v xfconf-query &> /dev/null; then
        xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitor0/workspace0/last-image -s "$WALLPAPER"
        log "XFCE wallpaper updated to $WALLPAPER"
    else
        log "xfconf-query not found, unable to update XFCE wallpaper"
    fi
else
    log "XFCE configuration directory not found, trying alternative wallpaper setting"
    
    # Try generic wallpaper setting for other desktop environments
    if command -v gsettings &> /dev/null; then
        if [ "$NEW_THEME" = "green" ]; then
            WALLPAPER="$WALLPAPER_DIR/orionx-green-wallpaper.png"
        else
            WALLPAPER="$WALLPAPER_DIR/orionx-dark-wallpaper.png"
        fi
        
        gsettings set org.gnome.desktop.background picture-uri "file://$WALLPAPER"
        log "Desktop wallpaper updated using gsettings"
    else
        log "No supported wallpaper setting method found"
    fi
fi

# Update bash prompt
if [ "$NEW_THEME" = "green" ]; then
    PS1_COLOR="\[\033[01;32m\]"  # Green
else
    PS1_COLOR="\[\033[38;5;214m\]"  # Amber/orange
fi

# Update .bashrc with new prompt color
if [ -f "$HOME/.bashrc" ]; then
    # Remove any existing Orion-X PS1 settings
    sed -i '/# Orion-X Phoenix Edition PS1/d' "$HOME/.bashrc"
    sed -i '/PS1=/d' "$HOME/.bashrc"
    
    # Add new PS1 setting
    echo "# Orion-X Phoenix Edition PS1" >> "$HOME/.bashrc"
    printf "PS1='%s[Orion-X]\\[\\033[00m\\] \\[\\033[01;34m\\]\\w\\[\\033[00m\\]\\\\$ '\n" "${PS1_COLOR}" >> "$HOME/.bashrc"
    
    log "Bash prompt updated"
else
    log "/.bashrc not found, skipping bash prompt update"
fi

# Save current theme
echo "$NEW_THEME" > "$HOME/.orionx_theme"

log "Theme toggle complete. New theme: $NEW_THEME"
echo "Switched to $NEW_THEME theme. Please restart your terminal for full effect."

# Optionally restart terminal if using a supported terminal
if [ "$1" = "--restart-terminal" ]; then
    if pgrep terminator > /dev/null; then
        pkill terminator
        terminator &
        log "Restarted Terminator terminal"
    else
        log "Terminal restart requested but Terminator not running"
    fi
fi

exit 0
