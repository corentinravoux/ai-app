#!/usr/bin/env bash
# Build and install AI App for the current user.
#
#   scripts/install-linux.sh            # flutter build linux --release, then install
#   scripts/install-linux.sh --no-build # install the existing release bundle
#
# Safe to run again to update: the app directory is replaced; the app's own
# folders (~/.local/share/alcfai for ALCF, ~/.local/share/ai-app for model
# hosts) are not touched.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
flutter="${FLUTTER:-$(command -v flutter || true)}"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
dest="$HOME/.local/opt/ai-app"
apps="$data/applications"
hicolor="$data/icons/hicolor"
app_id="dev.ravoux.ai_app"
src="$here/build/linux/x64/release/bundle"

if [[ "${1:-}" != "--no-build" && ! -x "${flutter:-}" ]]; then
  echo "Flutter not found. Install it (https://docs.flutter.dev/get-started/install/linux)" >&2
  echo "and put it on PATH, or run: FLUTTER=/path/to/flutter $0" >&2
  exit 1
fi

if [[ "${1:-}" != "--no-build" ]]; then
  (cd "$here" && "$flutter" build linux --release)
fi
if [[ ! -x "$src/ai_app" ]]; then
  echo "No release bundle at $src. Build it with: flutter build linux --release" >&2
  exit 1
fi

mkdir -p "$(dirname "$dest")" "$apps" "$hicolor/512x512/apps" "$hicolor/scalable/apps"
rm -rf "$dest.new"
cp -a "$src" "$dest.new"
rm -rf "$dest"
mv "$dest.new" "$dest"

cp "$here/assets/icon/ai-app.png" "$hicolor/512x512/apps/$app_id.png"
cp "$here/assets/icon/ai-app.svg" "$hicolor/scalable/apps/$app_id.svg"

# Named after the application id, which GNOME uses to match the window.
cat > "$apps/$app_id.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=AI App
Comment=Coding agents on ALCF or your own model hosts, without touching your Claude setup
Exec=$dest/ai_app
Icon=$app_id
Terminal=false
Categories=Development;
StartupWMClass=$app_id
DESKTOP

# The app was called "ALCF AI" (alcfai-app) before: remove the old copy and
# menu entry once the new one is in place. Its data folder stays.
rm -rf "$HOME/.local/opt/alcfai-app"
rm -f "$apps/dev.ravoux.alcfai_app.desktop" \
  "$hicolor/512x512/apps/dev.ravoux.alcfai_app.png" \
  "$hicolor/scalable/apps/dev.ravoux.alcfai_app.svg"

update-desktop-database "$apps" >/dev/null 2>&1 || true
gtk-update-icon-cache -q -t "$hicolor" >/dev/null 2>&1 || true
echo "Installed to $dest. Launch AI App from the applications menu."
if [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" = 1 ] \
  && [ ! -e /etc/apparmor.d/ai-app ]; then
  echo "Codex's sandbox needs an AppArmor profile here: run ./scripts/install-apparmor.sh (sudo)."
fi
