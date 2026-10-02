#!/bin/sh
# Render Nightstand's screens to PNGs at several device sizes.
#
#   tests/snap.sh PROFILE_DIR OUT_DIR [label WxH dpi]...
#
# PROFILE_DIR is a KOReader profile (it is copied, never modified), so real
# catalogue data and covers show up. Without explicit sizes, renders the
# devices the UI spec covers.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
KOREADER_DIR="${KOREADER_DIR:-$HOME/.local/share/koreader-app/lib/koreader}"
PROFILE="$1"; OUT="$2"; shift 2
mkdir -p "$OUT"
[ $# -gt 0 ] || set -- nova-portrait 1404x1872 300 nova-landscape 1872x1404 300 \
                        hibreak 824x1648 300 fairphone 1080x2340 420

WORK="$(mktemp -d)"
Xvfb -displayfd 3 -screen 0 2600x2600x24 -nolisten tcp 3>"$WORK/display" >/dev/null 2>&1 &
XVFB=$!
trap 'kill $XVFB 2>/dev/null; wait $XVFB 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$WORK/display" ] && break; sleep 0.3; done

while [ $# -ge 3 ]; do
    label="$1"; size="$2"; dpi="$3"; shift 3
    home="$WORK/$label"
    cp -r "$PROFILE" "$home"
    (cd "$KOREADER_DIR" && DISPLAY=":$(cat "$WORK/display")" HOME="$home" KO_HOME="$home" KO_MULTIUSER=1 \
        EMULATE_READER_W="${size%x*}" EMULATE_READER_H="${size#*x}" TEST_DPI="$dpi" \
        PLUGIN="$HERE/../nightstand.koplugin" TESTS="$HERE" LUA_PATH="$HERE/lib/?.lua;;" \
        SIZE_LABEL="$label" SNAP_OUT="$OUT" SNAP_DISCOVER="${SNAP_DISCOVER:-}" \
        ./luajit "$HERE/snap.lua" 2>&1 | grep -E "snapshots|rror|traceback" || true)
done
