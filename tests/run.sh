#!/bin/sh
# Runs Nightstand's tests inside KOReader's own LuaJIT.
#
#   tests/run.sh            all specs
#   tests/run.sh library    specs whose file name contains "library"
#
# KOREADER_DIR points at an unpacked KOReader (the folder holding reader.lua).
# UI specs need an X display; a private Xvfb is started so nothing appears on
# the desktop, and they run once per screen size below.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
KOREADER_DIR="${KOREADER_DIR:-$HOME/.local/share/koreader-app/lib/koreader}"
PLUGIN="$HERE/../nightstand.koplugin"
FILTER="${1:-}"

[ -f "$KOREADER_DIR/reader.lua" ] || { echo "KOReader not found in $KOREADER_DIR (set KOREADER_DIR)"; exit 2; }

WORK="$(mktemp -d)"
# Xvfb picks a free display itself, so back-to-back runs never collide
Xvfb -displayfd 3 -screen 0 2600x2600x24 -nolisten tcp 3>"$WORK/display" >/dev/null 2>&1 &
XVFB=$!
trap 'kill $XVFB 2>/dev/null; wait $XVFB 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$WORK/display" ] && break; sleep 0.3; done
DISP=":$(tr -d '\n' < "$WORK/display")"
[ "$DISP" != ":" ] || { echo "Xvfb did not start"; exit 2; }

# name WxH dpi
SIZES="nova-portrait 1404x1872 300
nova-landscape 1872x1404 300
hibreak 824x1648 300
fairphone 1080x2340 420
desktop-default 600x800 160"

run() {  # spec file, size label, WxH, dpi
    home="$WORK/$(basename "$1" .lua)-$2"
    mkdir -p "$home/settings"
    w="${3%x*}"; h="${3#*x}"
    out="$(cd "$KOREADER_DIR" && DISPLAY="$DISP" HOME="$home" KO_HOME="$home" KO_MULTIUSER=1 \
        EMULATE_READER_W="$w" EMULATE_READER_H="$h" TEST_DPI="$4" \
        PLUGIN="$PLUGIN" TESTS="$HERE" SIZE_LABEL="$2" LUA_PATH="$HERE/lib/?.lua;;" \
        ./luajit "$1" 2>&1)"
    status=$?
    summary="$(printf '%s\n' "$out" | grep -E '^[0-9]+ passed' | tail -1)"
    printf '%-24s %-16s %s\n' "$(basename "$1" .lua)" "$2" "${summary:-crashed (exit $status)}"
    if [ $status -ne 0 ]; then
        touch "$WORK/failed"  # the size loop runs in a subshell
        printf '%s\n' "$out" | grep -vE '^(ffi\.|lib_|has monolibtic|Started SDL|[0-9/]+-[0-9:]+ (INFO|DEBUG|WARN)| +[hw] = |} --\[\[table)' | sed 's/^/    /'
    fi
}

for spec in "$HERE"/spec_*.lua; do
    case "$spec" in *"$FILTER"*) ;; *) continue ;; esac
    case "$spec" in
        *spec_ui*)
            printf '%s\n' "$SIZES" | while read -r label size dpi; do
                run "$spec" "$label" "$size" "$dpi" || true
            done
            ;;
        *) run "$spec" "-" "600x800" "160" ;;
    esac
done
[ ! -e "$WORK/failed" ]
