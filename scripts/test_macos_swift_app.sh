#!/bin/bash -p
# One managed verification slot. Successful tests retire their compiler output;
# failures leave the slot and receipt intact, blocking accidental replacement.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
ROOT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
OUTPUT="$ROOT_DIR/build/verification"
exec /usr/bin/python3 -I -B "$ROOT_DIR/scripts/build_lifecycle.py" test \
    --repository "$ROOT_DIR" --output "$OUTPUT" "$@"
