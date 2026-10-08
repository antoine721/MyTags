#!/usr/bin/env bash
# Installs a LaunchAgent that exports the cloud database every Sunday at 20:00
# (`djtag backup-db`, spec phase 8) and keeps the 10 latest application backups.
# Usage: ./install-weekly-backup.sh            (install or update)
#        ./install-weekly-backup.sh --remove   (uninstall)
set -euo pipefail

LABEL="fr.mytags.djtag.backup"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CLI_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UV="$(command -v uv || true)"

if [[ "${1:-}" == "--remove" ]]; then
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Sauvegarde hebdomadaire désinstallée."
  exit 0
fi

if [[ -z "$UV" ]]; then
  echo "uv introuvable : brew install uv" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/DJTag/logs"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>cd "$CLI_DIR" &amp;&amp; "$UV" run djtag backup-db &amp;&amp; "$UV" run djtag prune-backups</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict><key>Weekday</key><integer>0</integer><key>Hour</key><integer>20</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>$HOME/DJTag/logs/backup-db.log</string>
  <key>StandardErrorPath</key><string>$HOME/DJTag/logs/backup-db.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Sauvegarde hebdomadaire installée (dimanche 20 h) : ~/DJTag/backups/db/, journal ~/DJTag/logs/backup-db.log"
