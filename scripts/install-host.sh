#!/usr/bin/env bash
# Install llm-host on a model host (the machine that runs llama-server).
#
#   scripts/install-host.sh --server-bin ~/Software/llama.cpp/build/bin/llama-server \
#                           --models-dir ~/Software/models [--port 9931]
#
# Copies host/llm_host.py to ~/.local/bin/llm-host. On the first run it also
# writes ~/.config/llm-host/config.toml from the arguments and copies the
# example recipes to ~/.config/llm-host/recipes.example/. It never overwrites
# an existing config or recipe. See docs/hosts.md.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
bin_dir="$HOME/.local/bin"
cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/llm-host"
server_bin="" models_dir="" port=9931

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server-bin) server_bin="$2"; shift 2 ;;
        --models-dir) models_dir="$2"; shift 2 ;;
        --port)       port="$2"; shift 2 ;;
        -h|--help)    sed -n '2,11p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

command -v python3 >/dev/null || { echo "python3 is required (>= 3.11)" >&2; exit 1; }
python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' \
    || { echo "python3 >= 3.11 is required (tomllib)" >&2; exit 1; }

mkdir -p "$bin_dir"
install -m 755 "$here/host/llm_host.py" "$bin_dir/llm-host"
echo "installed $bin_dir/llm-host"

if [[ ! -f "$cfg_dir/config.toml" ]]; then
    if [[ -z "$server_bin" || -z "$models_dir" ]]; then
        echo "first install: pass --server-bin and --models-dir" >&2
        exit 2
    fi
    [[ -x "$server_bin" ]] || { echo "not executable: $server_bin" >&2; exit 1; }
    [[ -d "$models_dir" ]] || { echo "not a directory: $models_dir" >&2; exit 1; }
    mkdir -p "$cfg_dir/recipes"
    printf 'server_bin = "%s"\nmodels_dir = "%s"\nport = %s\n' \
        "$server_bin" "$models_dir" "$port" > "$cfg_dir/config.toml"
    echo "wrote $cfg_dir/config.toml"
else
    echo "kept $cfg_dir/config.toml"
fi

mkdir -p "$cfg_dir/recipes.example" "$cfg_dir/recipes"
for f in "$here"/host/recipes.example/*.toml; do
    t="$cfg_dir/recipes.example/$(basename "$f")"
    [[ -e "$t" ]] || cp "$f" "$t"
done

case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "note: $bin_dir is not on PATH in this shell" ;;
esac

"$bin_dir/llm-host" list
