#!/bin/bash
# Opens demo.md in QuickDown sized to exactly 1280x800 (2560x1600 on Retina)

open -a QuickDown /Users/Tennyson/QuickDown/demo.md
sleep 1.5  # wait for window to appear

osascript << 'APPLESCRIPT'
tell application "System Events"
    tell process "QuickDown"
        set frontmost to true
        set position of front window to {0, 25}
        set size of front window to {1280, 800}
    end tell
end tell
APPLESCRIPT

echo "✅ QuickDown opened at 1280x800 — ready to screenshot"
