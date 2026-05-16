#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT_DIR/TM-Ebook_Converter/Resources/Tools"

mkdir -p "$TOOLS_DIR"

for tool in ffmpeg ffprobe; do
  source_path="$(command -v "$tool" || true)"
  if [[ -z "$source_path" ]]; then
    echo "$tool not found. Install with: brew install ffmpeg" >&2
    exit 1
  fi

  cp -L "$source_path" "$TOOLS_DIR/$tool"
  chmod 755 "$TOOLS_DIR/$tool"
  echo "Installed $tool -> $TOOLS_DIR/$tool"
done

echo "For distribution, replace these with static, license-reviewed macOS binaries before signing."
