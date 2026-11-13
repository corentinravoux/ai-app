#!/usr/bin/env bash
# Run SearXNG for AI App's `websearch`: one container, listening on
# 127.0.0.1:8899 only, restarted with the machine. Run it on the machine
# where AI App (and so the agents) run. Needs Docker or Podman.
#
#   scripts/install-searxng.sh            # install or update, then check
#   scripts/install-searxng.sh --remove   # stop and remove the container
#
# Settings: <AI App settings folder>/searxng/settings.yml (written once,
# kept on updates). See docs/searxng.md.
set -euo pipefail

name=ai-app-searxng
port=8899
image=docker.io/searxng/searxng:latest

engine="$(command -v docker || command -v podman || true)"
if [[ -z "$engine" ]]; then
  echo "Docker or Podman is needed: see docs/searxng.md" >&2
  exit 1
fi

if [[ "$(uname)" == Darwin ]]; then
  settings="$HOME/Library/Application Support/ai-app"
else
  settings="${XDG_CONFIG_HOME:-$HOME/.config}/ai-app"
fi
cfg="$settings/searxng"

if [[ "${1:-}" == "--remove" ]]; then
  "$engine" rm -f "$name" >/dev/null 2>&1 || true
  echo "removed the $name container (settings kept in $cfg)"
  exit 0
fi

mkdir -p "$cfg"
if [[ ! -f "$cfg/settings.yml" ]]; then
  key="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  cat > "$cfg/settings.yml" <<YAML
# SearXNG for AI App (scripts/install-searxng.sh). Edit freely: updates
# keep this file. https://docs.searxng.org/admin/settings/
use_default_settings: true
server:
  secret_key: "$key"
  # Only this machine reaches it (127.0.0.1): no bot limiter needed.
  limiter: false
  image_proxy: false
search:
  # websearch asks for JSON.
  formats: [html, json]
YAML
  echo "wrote $cfg/settings.yml"
fi

"$engine" pull "$image"
"$engine" rm -f "$name" >/dev/null 2>&1 || true
"$engine" run -d --name "$name" --restart unless-stopped \
  -p "127.0.0.1:$port:8080" \
  -v "$cfg:/etc/searxng" \
  "$image" >/dev/null
echo "started $name on http://127.0.0.1:$port"

for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:$port/search?q=test&format=json" >/dev/null 2>&1; then
    echo "SearXNG answers: websearch is ready (try: websearch flutter pty)"
    exit 0
  fi
  sleep 1
done
echo "SearXNG did not answer within 60 s: check '$engine logs $name'" >&2
exit 1
