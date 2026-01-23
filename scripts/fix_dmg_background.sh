#!/bin/bash
set -e

# Configuration
APP_NAME="QuickDown"
APP_PATH="build/Export/QuickDown.app" 
BG_IMAGE="build/dmg-background.png"
OUTPUT_DMG="build/${APP_NAME}-Installer.dmg"
VOL_NAME="${APP_NAME}"
TMP_DMG="build/tmp.dmg"

# Clean up previous runs
rm -f "$OUTPUT_DMG" "$TMP_DMG"

echo "Creating temporary disk image..."
hdiutil create -size 200m -volname "${VOL_NAME}" -fs HFS+ -srcfolder "${APP_PATH}" -ov -format UDRW "${TMP_DMG}"

echo "Mounting temporary disk image..."
# Attach with shadow file to ensure R/W access even if image is stubborn
# This overlays a writable layer on top of the image
DEVICE=$(hdiutil attach -owners on -shadow -noverify -noautoopen "${TMP_DMG}" | egrep '^/dev/' | sed 1q | awk '{print $1}')
sleep 2 # Wait for mount to stabilize

# Convert background to 72 DPI TIFF (Sequioa Fix for Retain/Icon glitch)
echo "Converting background to 72DPI TIFF..."
TIFF_BG="build/background.tiff"
# Resize to exact window size if needed, force 72dpi, convert to tiff
sips -s format tiff -s dpiHeight 72 -s dpiWidth 72 --resampleHeightWidth 662 940 "${BG_IMAGE}" --out "${TIFF_BG}"

echo "Setting up background..."
# Create .background folder and copy image
mkdir -p "/Volumes/${VOL_NAME}/.background"
cp "${TIFF_BG}" "/Volumes/${VOL_NAME}/.background/background.tiff"

# Add Applications symlink
ln -s /Applications "/Volumes/${VOL_NAME}/Applications"

echo "Applying Finder customization (The Sequoia Fix v2)..."
# Fixes:
# 1. Background image format (TIFF)
# 2. Window bounds matching the image exactly
# 3. 'Jiggle' trick for forced refresh

osascript <<EOF
tell application "Finder"
    tell disk "${VOL_NAME}"
        open
        
        -- Wait for window to open
        delay 1
        
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        
        -- Set window size to match image exactly (940x662 based on sips resize)
        -- Bounds: left, top, right, bottom
        set the bounds of container window to {400, 100, 1340, 762}
        
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 120
        set background picture of theViewOptions to file ".background:background.tiff"
        
        -- Align icons
        set position of item "${APP_NAME}.app" of container window to {240, 330}
        set position of item "Applications" of container window to {700, 330}
        
        -- THE SEQUOIA FIX: 'Jiggle' the icon size to force a view refresh
        delay 1
        set icon size of theViewOptions to 121
        delay 1
        set icon size of theViewOptions to 120
        
        -- Force update and close
        update without registering applications
        delay 2
        close
        
        -- Re-open to verify (optional, helps persist settings)
        delay 1
        open
        delay 1
        close
    end tell
end tell
EOF

echo "Finalizing disk image..."
# Sync to ensure metadata is written
sync

# Detach
hdiutil detach "${DEVICE}"

echo "Compressing final DMG..."
# CRITICAL FIX: Must include the shadow file during convert, otherwise changes are lost!
hdiutil convert "${TMP_DMG}" -shadow "${TMP_DMG}.shadow" -format UDBZ -o "${OUTPUT_DMG}"

echo "Cleaning up..."
rm -f "${TMP_DMG}" "${TMP_DMG}.shadow"

echo "Done! created ${OUTPUT_DMG}"
