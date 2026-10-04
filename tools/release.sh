#!/bin/sh
# Mark and publish a Nightstand version.
#
#   tools/release.sh 0.1.0-alpha.2 [notes-file]
#
# Sets the version in _meta.lua, commits and tags it, builds
# nightstand.koplugin.zip from the tagged tree, pushes, and creates the GitHub
# release the in-app updater looks for. Versions with a suffix (-alpha.N,
# -beta.N, -rc.N) are published as pre-releases.
set -eu

VERSION="${1:?usage: tools/release.sh VERSION [notes-file]}"
NOTES="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$' \
    || { echo "version must look like 1.2.3 or 1.2.3-alpha.4" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "commit or stash your changes first" >&2; exit 1; }
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "release from main" >&2; exit 1; }
! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || { echo "v$VERSION exists" >&2; exit 1; }

sed -i "s/^    version = \".*\",$/    version = \"$VERSION\",/" nightstand.koplugin/_meta.lua
grep -q "version = \"$VERSION\"" nightstand.koplugin/_meta.lua || { echo "could not set the version" >&2; exit 1; }
git diff --quiet nightstand.koplugin/_meta.lua || git commit -qm "Release $VERSION" nightstand.koplugin/_meta.lua
git tag -a "v$VERSION" -m "Nightstand $VERSION"

mkdir -p dist
ZIP="dist/nightstand.koplugin.zip"
rm -f "$ZIP"
git archive --format=zip --prefix=nightstand.koplugin/ -o "$ZIP" "v$VERSION:nightstand.koplugin"

git push -q origin main "v$VERSION"
PRE=""
case "$VERSION" in *-*) PRE="--prerelease" ;; esac
if [ -n "$NOTES" ]; then
    gh release create "v$VERSION" "$ZIP" --repo emrroe/Nightstand --title "Nightstand $VERSION" $PRE --notes-file "$NOTES"
else
    gh release create "v$VERSION" "$ZIP" --repo emrroe/Nightstand --title "Nightstand $VERSION" $PRE --generate-notes
fi
echo "released $VERSION"
