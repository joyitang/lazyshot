#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O -framework AppKit -framework Foundation main.swift -o MiniScreenshotOverlay
echo "Built: $(pwd)/MiniScreenshotOverlay"
