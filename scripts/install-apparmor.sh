#!/usr/bin/env bash
# Install the AppArmor profile that lets codex's bubblewrap sandbox run
# inside the app (see scripts/apparmor/ai-app). Needs sudo.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
sudo install -m 644 "$here/apparmor/ai-app" /etc/apparmor.d/ai-app
sudo apparmor_parser -r /etc/apparmor.d/ai-app
echo "Profile loaded. Restart AI App."
