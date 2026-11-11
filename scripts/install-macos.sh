#!/usr/bin/env bash
# Build and install AI App on macOS for the current user.
#
#   scripts/install-macos.sh             # flutter build macos --release, then install
#   scripts/install-macos.sh --no-build  # install the existing release build
#
# Installs "AI App.app" into ~/Applications and webread (the page reader
# local agents use) into ~/Library/Application Support/ai-app/bin.
# Needs Xcode (or its command-line tools) and Flutter. Built by CI, not yet
# run on a real Mac: see docs/next-steps-plan.md § C.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
flutter="${FLUTTER:-$(command -v flutter || true)}"
app_src="$here/build/macos/Build/Products/Release/AI App.app"
dest="$HOME/Applications"
data="$HOME/Library/Application Support/ai-app"

if [[ "${1:-}" != "--no-build" ]]; then
  if [[ ! -x "${flutter:-}" ]]; then
    echo "Flutter not found: put it on PATH or run FLUTTER=/path/to/flutter $0" >&2
    exit 1
  fi
  (cd "$here" && "$flutter" build macos --release)
fi
[[ -d "$app_src" ]] || { echo "No build at $app_src" >&2; exit 1; }

mkdir -p "$dest" "$data/bin"
rm -rf "$dest/AI App.app"
cp -R "$app_src" "$dest/"
install -m 755 "$here/tools/webread" "$data/bin/webread"

echo "Installed $dest/AI App.app. Open it from Finder or Launchpad."
echo "The first launch of an unsigned build may need: right-click → Open."
