#!/bin/bash -p
# Build the Heznpc app icon from the tracked vector source.

set -euo pipefail
umask 022
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV CDPATH GLOBIGNORE

ROOT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
OUTPUT="${1:-$ROOT_DIR/build/macos/AppIcon.icns}"
SOURCE="${2:-$ROOT_DIR/assets/macos/AppIcon.svg}"

if [[ "$(/usr/bin/uname)" != "Darwin" ]]; then
    /usr/bin/printf 'ERROR: iconutil and sips require macOS.\n' >&2
    exit 1
fi
if [[ "$SOURCE" != /* || ! -f "$SOURCE" || -L "$SOURCE" ]]; then
    /usr/bin/printf 'ERROR: icon source missing: %s\n' "$SOURCE" >&2
    exit 1
fi

current_uid="$(/usr/bin/id -u)"
user_temp="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)"
[[ -n "$user_temp" && "$user_temp" == /* && -d "$user_temp" && ! -L "$user_temp" ]] || exit 1
user_temp="$(cd -P "$user_temp" && /bin/pwd -P)"
[[ "$(/usr/bin/stat -f '%u' "$user_temp")" == "$current_uid" \
    && $((8#$(/usr/bin/stat -f '%Lp' "$user_temp") & 0022)) -eq 0 ]] || exit 1
work_dir="$(/usr/bin/mktemp -d "$user_temp/pch-icon.XXXXXX")"
trap '/bin/rm -rf "$work_dir"' EXIT
iconset="$work_dir/AppIcon.iconset"
master="$work_dir/AppIcon-1024.png"
/bin/mkdir -p "$iconset" "$(/usr/bin/dirname "$OUTPUT")"

/usr/bin/sips -s format png "$SOURCE" --out "$master" >/dev/null
pixel_width="$(/usr/bin/sips -g pixelWidth "$master" | /usr/bin/awk '/pixelWidth/ {print $2}')"
pixel_height="$(/usr/bin/sips -g pixelHeight "$master" | /usr/bin/awk '/pixelHeight/ {print $2}')"
if [[ "$pixel_width" != "1024" || "$pixel_height" != "1024" ]]; then
    /usr/bin/printf 'ERROR: icon raster must be 1024x1024, got %sx%s.\n' "$pixel_width" "$pixel_height" >&2
    exit 2
fi

render_size() {
    size="$1"
    name="$2"
    /usr/bin/sips -z "$size" "$size" "$master" --out "$iconset/$name" >/dev/null
}

render_size 16 icon_16x16.png
render_size 32 icon_16x16@2x.png
render_size 32 icon_32x32.png
render_size 64 icon_32x32@2x.png
render_size 128 icon_128x128.png
render_size 256 icon_128x128@2x.png
render_size 256 icon_256x256.png
render_size 512 icon_256x256@2x.png
render_size 512 icon_512x512.png
/bin/cp "$master" "$iconset/icon_512x512@2x.png"

/usr/bin/iconutil -c icns "$iconset" -o "$OUTPUT"
/usr/bin/printf 'Built icon: %s\n' "$OUTPUT"
