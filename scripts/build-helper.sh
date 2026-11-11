#!/usr/bin/env bash
# Rebuild the native keystroke helper for the current Mac.
# Run this after moving the extension to a Mac with a different CPU architecture.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/assets/TypeKeystrokes.swift"
OUTPUT="$ROOT/assets/type-keystrokes-helper"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi

swiftc -O -o "$OUTPUT" "$SOURCE" -framework Carbon
chmod +x "$OUTPUT"
echo "Built: $OUTPUT"
file "$OUTPUT"
