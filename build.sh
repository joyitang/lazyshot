#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="lazyshot"
APP_DIR="${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"
BIN="${MACOS}/${APP_NAME}"

mkdir -p "${MACOS}" "${RESOURCES}"

swiftc -O -framework AppKit -framework Foundation -framework ServiceManagement main.swift -o "${BIN}"

# Remove leftover bare binary from older builds (optional cleanup)
if [[ -f MiniScreenshotOverlay ]]; then
  rm -f MiniScreenshotOverlay
fi

# --- App icon (.icns from 1024 master) ---
ICON_SRC="assets/lazyshot_final_app_1024.png"
ICONSET="${RESOURCES}/AppIcon.iconset"
ICNS="${RESOURCES}/AppIcon.icns"
if [[ ! -f "${ICON_SRC}" ]]; then
  echo "error: missing ${ICON_SRC}" >&2
  exit 1
fi

# iconutil wants PNGs with alpha; master is RGB — rasterize to RGBA via AppKit.
ICON_RGBA="$(mktemp -t lazyshot_iconXXXX).png"
ICON_HELPER="$(mktemp -t lazyshot_rgbaXXXX).swift"
cat > "${ICON_HELPER}" <<'SWIFT'
import AppKit
import Foundation
let args = CommandLine.arguments
precondition(args.count >= 3, "usage: helper <src> <dst>")
guard let img = NSImage(contentsOfFile: args[1]) else {
    fputs("failed to load icon source\n", stderr); exit(1)
}
let px = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fputs("bitmap alloc failed\n", stderr); exit(1) }
rep.size = NSSize(width: px, height: px)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: px, height: px).fill()
img.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
         from: .zero, operation: .sourceOver, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()
guard let data = rep.representation(using: .png, properties: [:]) else {
    fputs("png encode failed\n", stderr); exit(1)
}
try data.write(to: URL(fileURLWithPath: args[2]))
SWIFT
swiftc -O -framework AppKit "${ICON_HELPER}" -o "${ICON_HELPER}.bin"
"${ICON_HELPER}.bin" "${ICON_SRC}" "${ICON_RGBA}"
rm -f "${ICON_HELPER}" "${ICON_HELPER}.bin"

rm -rf "${ICONSET}"
mkdir -p "${ICONSET}"
# Standard iconset sizes
sips -z 16 16     "${ICON_RGBA}" --out "${ICONSET}/icon_16x16.png" >/dev/null
sips -z 32 32     "${ICON_RGBA}" --out "${ICONSET}/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "${ICON_RGBA}" --out "${ICONSET}/icon_32x32.png" >/dev/null
sips -z 64 64     "${ICON_RGBA}" --out "${ICONSET}/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "${ICON_RGBA}" --out "${ICONSET}/icon_128x128.png" >/dev/null
sips -z 256 256   "${ICON_RGBA}" --out "${ICONSET}/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "${ICON_RGBA}" --out "${ICONSET}/icon_256x256.png" >/dev/null
sips -z 512 512   "${ICON_RGBA}" --out "${ICONSET}/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "${ICON_RGBA}" --out "${ICONSET}/icon_512x512.png" >/dev/null
sips -z 1024 1024 "${ICON_RGBA}" --out "${ICONSET}/icon_512x512@2x.png" >/dev/null
iconutil -c icns "${ICONSET}" -o "${ICNS}"
rm -rf "${ICONSET}" "${ICON_RGBA}"

# --- Menu bar template PNGs into Resources ---
for f in lazyshot_menubar_16.png lazyshot_menubar_32.png lazyshot_menubar_64.png; do
  if [[ ! -f "assets/${f}" ]]; then
    echo "error: missing assets/${f}" >&2
    exit 1
  fi
  cp "assets/${f}" "${RESOURCES}/${f}"
done

cat > "${CONTENTS}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleDisplayName</key>
	<string>lazyshot</string>
	<key>CFBundleExecutable</key>
	<string>lazyshot</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.joytang.lazyshot</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>lazyshot</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.1.0</string>
	<key>CFBundleVersion</key>
	<string>2</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Built: $(pwd)/${APP_DIR}"
echo "  icon: ${ICNS}"
echo "  menubar: ${RESOURCES}/lazyshot_menubar_{16,32,64}.png"
