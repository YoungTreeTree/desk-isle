#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
source_icon="$root/resources/icons/cat-head.png"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/deskisle-icon.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
iconset="$temporary/DeskIsle.iconset"
mkdir -p "$iconset"

for size in 16 32 128 256 512; do
  for scale in 1 2; do
    suffix=""
    if [[ "$scale" == 2 ]]; then suffix="@2x"; fi
    pixels=$((size * scale))
    sips -z "$pixels" "$pixels" "$source_icon" \
      --out "$iconset/icon_${size}x${size}${suffix}.png" >/dev/null
  done
done
iconutil -c icns "$iconset" -o "$root/resources/DeskIsle.icns"
print -r -- "$root/resources/DeskIsle.icns"
