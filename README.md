# AI App

[![CI](https://github.com/corentinravoux/ai-app/actions/workflows/ci.yml/badge.svg)](https://github.com/corentinravoux/ai-app/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

One desktop window for AI coding agents. AI App opens **Claude Code, Pi,
OpenCode and Codex** in terminal tabs, side by side, and runs each one on the
model you choose:

- **ALCF Inference Endpoints**: large open models on Argonne's clusters
  ([docs](https://docs.alcf.anl.gov/services/inference-endpoints/)).
- **Your own model hosts**: a PC with a GPU serving a model with llama.cpp,
  used from that PC or from your laptop anywhere (home, office, travelling).
- **Your Claude Code accounts**, opened as they are.

Every agent gets a configuration of its own, built by the app. Your normal
settings (`~/.claude`, `~/.pi`, `~/.config/opencode`, `~/.codex`) are never
changed, and a tab never silently uses another backend: the bar above each
tab says where its requests go.

| | Linux | macOS | Windows |
|---|---|---|---|
| App | tested (Ubuntu 24.04–26.04) | built by CI, not yet tried | built by CI, not yet tried |
| ALCF | yes | yes | no |
| Model hosts over SSH | yes | yes | yes (no shared SSH connection) |
| Serving a model (`llm-host`) | yes (NVIDIA tested) | yes (Apple Silicon expected) | no |

## Contents

- [Install](#install) · [First use](#first-use) · [In a session](#in-a-session)
- [Agents on ALCF](#agents-on-alcf-what-to-know) · [Your own model hosts](#your-own-model-hosts)
- [How the app keeps backends apart](#how-the-app-keeps-backends-apart) · [Files](#files-it-uses)
- [Troubleshooting](#troubleshooting) · [Development](#development)

## Install

### What you need

- At least one agent, installed with its own installer:
  [Claude Code](https://docs.anthropic.com/en/docs/claude-code),
  [Pi](https://github.com/earendil-works/pi),
  [OpenCode](https://opencode.ai),
  [Codex](https://github.com/openai/codex).
  You need no Anthropic or OpenAI subscription to use them on ALCF or on
  your own hosts.
- For ALCF: an ALCF account with access to the Inference Endpoints, and
  [uv](https://docs.astral.sh/uv/).
- To build the app: the [Flutter SDK](https://docs.flutter.dev/get-started/install)
  (3.47 or later) and your platform's build tools (below).

### Linux

```bash
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev
git clone https://github.com/corentinravoux/ai-app
cd ai-app
./scripts/install-linux.sh        # FLUTTER=/path/to/flutter/bin/flutter if not on PATH
```

Start **AI App** from your applications menu. To update: `git pull` and run
the script again; your settings are kept.

Ubuntu 23.10 and later, if you use Codex: `./scripts/install-apparmor.sh`
(asks for your password once). Without it, every command Codex runs fails
with `bwrap: loopback: Failed RTM_NEWADDR`. The script installs the same
small AppArmor profile Ubuntu ships for VS Code.

### macOS (not yet tried on a real Mac)

Needs Xcode (or its command-line tools) and Flutter.

```bash
git clone https://github.com/corentinravoux/ai-app && cd ai-app
./scripts/install-macos.sh        # installs ~/Applications/AI App.app
```

The build is unsigned: the first time, right-click the app and choose
**Open**. Agents installed with Homebrew or npm are found even when the app
is started from Finder.

### Windows (not yet tried on a real machine)

Needs Visual Studio with "Desktop development with C++", and Flutter.

```powershell
git clone https://github.com/corentinravoux/ai-app; cd ai-app
powershell -ExecutionPolicy Bypass -File scripts\install-windows.ps1
```

Start **AI App** from the Start menu. ALCF is not available on Windows.
Model hosts work over OpenSSH (built into Windows 10 and 11).

### ALCF tools (Linux, macOS)

```bash
uv tool install alcf-ai
uv tool install alcf-tokens
alcf-tokens login inference     # log in again about every 30 days
```

## First use

The left sidebar has three groups.

- **ALCF inference**: Claude, Pi, Codex and OpenCode served by ALCF.
  1. Click **Configure** next to an agent.
  2. Pick a cluster and a model. The badge next to each model says whether
     it is running, queued (the first answer can take minutes while it
     loads) or offline.
  3. Click **Configure**. The app runs `alcf-ai agent configure` in its own
     folder and checks that your real settings files did not change.
  4. Click **▶**, choose the folder to work in, and the agent starts in a
     new tab.
- **Model hosts**: one row per machine that serves a model, showing what
  runs there, its context window and GPU memory. Start, switch or stop the
  model from the row, then click **▶** on Pi, OpenCode or Claude below it.
  See [Your own model hosts](#your-own-model-hosts).
- **Your Claude accounts**: Claude Code with your usual login, launched as
  is. The app finds `~/.claude` and every `~/.claude-<name>` folder that
  holds a login (see [Settings](#settings)).

If the ALCF login has expired, a banner offers **Log in**; the app checks it
every 3 hours. Agents marked "Not installed" were not found on your `PATH`
or in the usual install folders (`~/.local/bin`, `~/.npm-global/bin`,
`~/opt/node/bin`, `~/.opencode/bin`, `~/.bun/bin`, `~/.cargo/bin`, Homebrew
on macOS, `%APPDATA%\npm` on Windows).

## In a session

| keys | does |
|---|---|
| Ctrl+Shift+C / Ctrl+Shift+V | copy selection / paste |
| Ctrl+Shift+A | select all output |
| Ctrl+Shift+F | find in output (Enter next, Shift+Enter previous, Esc close) |
| Ctrl+= / Ctrl+- / Ctrl+0 | bigger / smaller / default text |
| Ctrl+click on a link | open it in the browser |

Plain Ctrl+A, Ctrl+C and Ctrl+V go to the agent, as in any terminal.

**Split view.** Every pane's "Runs on" bar has two buttons: split right
and split down. Split as often as you like, as in VS Code. You can also
drag a tab from the tab bar onto a pane: drop it in the middle to show it
there, or on a pane's left, right, top or bottom edge to split that side
(a blue outline shows where it will land). A tab already shown in another
pane swaps with the one it is dropped on. Click a pane to make it the
active one: tabs you pick and new sessions go there (its bar has a blue top
line). Drag a divider to resize; double-click it to even the two sides. The
× on a pane's bar closes the pane; its session keeps running in its tab.

- Each agent starts on the model you picked in Configure.
- The app asks before closing a running session, and offers **Restart** on
  one that ended.
- When all tabs are closed, it offers to reopen the sessions from last time.
- The new-session window lists your recent folders and has a **Browse**
  button.

## Agents on ALCF: what to know

- **Clusters**: Tara is the default. It has the most capacity (many Muse
  Spark and Mistral 4 replicas), so pick it when Minerva answers slowly. Tara
  needs alcf-ai 0.21 or later (`uv tool upgrade alcf-ai`). On Tara, Muse
  Spark and Mistral 4 are not yet on alcf-ai's agent allowlist; Configure
  adds `--include-experimental` for them on its own.
- **Claude**: only models that speak the Anthropic API are offered.
  Plugins and hooks are off by default because they fill the context; tick
  "Include plugins & hooks" in Configure to use the ones from `~/.claude`.
- **Codex**: only Minerva and Tara models (the clusters with the API Codex
  needs).
  The ALCF gateway refuses three Codex tools, so in the app's copy the app
  turns off the `apply_patch` tool, multi-agent mode and web search. Codex
  still edits files, through shell commands.
- **OpenCode** and **Pi**: all clusters. They start on the model chosen in
  Configure; pick another inside the agent if you like.

## Your own model hosts

A **model host** is a machine with a GPU that serves one model at a time
with llama.cpp's `llama-server`. A small script, **`llm-host`**, runs there:
it starts the model from a tested *recipe* (model file, context size, GPU
offload), stops it, reports its state and checks it. The agents always run
on the machine where the app runs, in your project folder; only the model
is on the host.

```
 laptop (or the host itself)                     model host
 ┌──────────────────────────┐                   ┌─────────────────────────────┐
 │ AI App                   │  ssh: llm-host …  │ llm-host  start/stop/probe  │
 │  tabs: Pi, OpenCode,     │ ────────────────► │   └ llama-server 127.0.0.1  │
 │        Claude ─► 127.0.0.1:19931 ═ ssh -L ═══════► :9931                   │
 └──────────────────────────┘   (Tailscale)     └─────────────────────────────┘
```

**Set up a host** (once, on the machine with the GPU):
[docs/hosts.md](docs/hosts.md) walks through building llama.cpp, measuring
a model, `scripts/install-host.sh`, writing recipes and, for remote use,
SSH over Tailscale. On that machine the app then shows **This machine**.

**Use it from another computer**: click **Add host**, choose *Over SSH*,
enter the host's SSH name (`pc`, or `user@pc.tailnet.ts.net`), click
**Test**, then **Save**. The app keeps an SSH tunnel open to the host's
server. Nothing is exposed to the network, and no key or token is needed
beyond your SSH key.

**On the host's row**:

| control | does |
|---|---|
| ▶ / ⇄ menu | start a recipe, or switch to another (asks first if tabs use the model) |
| ■ | stop the model |
| probe | checks a structured tool call, the Claude endpoint and the speed |
| log | the end of the server's log, e.g. why a model failed to start |
| ✎ | edit or remove the host |

**What each agent gets.** The app writes the agent's configuration from
the server's live state every time a tab opens, so it always declares the
window and output cap the server really has.

| agent | configured with | reads the web with |
|---|---|---|
| Pi | `models.json` and `settings.json` (window, output cap, compaction) | a `web_read` tool |
| OpenCode | `opencode.jsonc` (window, output cap, compaction, tool-output limits) | its own WebFetch |
| Claude | environment only (`ANTHROPIC_BASE_URL` to the host), `--bare`, Bash/Read/Edit | `webread <url>` through Bash |

Claude needs a window of at least 32K tokens, OpenCode 24K and Pi 16K; an
agent below its minimum stays greyed with the reason. Switching the model
while tabs use it keeps them running; click **Restart** on a tab to give it
the new model's settings. Working "offline" means working at the host
itself: two machines need the internet to find each other unless they
share a network.

**A caution.** Pi asks no permission before running commands, and a web
page can contain instructions aimed at the model. Use a scratch copy of
your project for web-heavy Pi sessions.

## Share your Claude instructions (optional)

Claude on ALCF starts without your `CLAUDE.md`, commands and skills (the
sidebar shows a hint while that is so). To reuse them, link them into the
app's Claude folder:

```bash
d=~/.local/share/alcfai/home/.claude
mkdir -p "$d"
for f in CLAUDE.md commands skills agents; do
  [ -e ~/.claude/$f ] && ln -sfn ~/.claude/$f "$d/$f"
done
```

Do not link `settings.json`: the app writes its own there.

## Settings

The app keeps its state in `~/.local/share/alcfai/state.json`: the model
picked per agent, recent folders, last tabs and text size. To name your
Claude accounts yourself, add an `accounts` list there while the app is
closed:

```json
{
  "accounts": [
    {"id": "claude-work", "label": "Claude · Work", "dir": "~/.claude"},
    {"id": "claude-home", "label": "Claude · Home", "dir": "~/.claude-home"}
  ]
}
```

## How the app keeps backends apart

- **One folder per backend and agent.** ALCF agents live in
  `~/.local/share/alcfai/home`; local agents in the app's data folder
  (`local/<host>/<agent>`). Your own `~/.claude`, `~/.pi`,
  `~/.config/opencode` and `~/.codex` are only hashed, never written.
- **Inherited routing is removed.** Every tab starts without the
  `ANTHROPIC_*` variables, `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_OAUTH_TOKEN` and
  the other agents' config variables of the window it came from. Local tabs
  also drop the Bedrock, Vertex and Foundry switches.
- **Projects cannot redirect a local tab.** A repository's own
  `.claude/settings.json` or `opencode.json` could otherwise point the agent
  at another endpoint: local Claude runs with `--setting-sources user`, local
  OpenCode with `OPENCODE_DISABLE_PROJECT_CONFIG=1`.
- **Before and after** every configure run and every local tab, the app
  hashes your real settings files; a change is shown in red and the tab
  does not open.
- **Local models listen on 127.0.0.1 only.** `llm-host` refuses recipes
  that set `--host`, `--port` or `--api-key`, and never stops a server it
  did not start.

## Why a separate folder

`alcf-ai agent configure` writes to fixed files in your home directory, and
writes through symlinks:

| agent | file alcf-ai writes | how the app redirects it |
|---|---|---|
| claude | `~/.claude/settings.json` | `CLAUDE_CONFIG_DIR` |
| codex | `~/.codex/config.toml` | `CODEX_HOME` |
| opencode | `~/.config/opencode/opencode.jsonc` | `OPENCODE_CONFIG` |
| pi | `~/.pi/agent/models.json` | `PI_CODING_AGENT_DIR` |

Run by hand, it would switch your normal Claude Code to an ALCF model. The
app runs `alcf-ai` with `HOME` set to its own folder, then starts each agent
with your real `HOME` and the variable above pointing into that folder.
Before and after every configure run it hashes your real settings files and
shows a red warning if any changed.

## Files it uses

On Linux (macOS: `~/Library/Application Support/ai-app` for the data and
settings; Windows: `%LOCALAPPDATA%\ai-app` and `%APPDATA%\ai-app`):

| path | what |
|---|---|
| `~/.local/opt/ai-app/` | the installed app |
| `~/.local/share/applications/dev.ravoux.ai_app.desktop` | menu entry (plus icons under `~/.local/share/icons/hicolor/`) |
| `~/.local/share/alcfai/home/` | the agents' ALCF settings (the app's own "home"; `.globus` links to your ALCF login) |
| `~/.local/share/alcfai/state.json` | app state, no secrets |
| `~/.config/ai-app/hosts.json` | your model hosts (an unreadable file is kept as `hosts.json.corrupt-*`) |
| `~/.local/share/ai-app/` | local agents' configs (`local/`), SSH control sockets (`ssh/`), `bin/webread` |
| `~/.local/bin/llm-host`, `~/.config/llm-host/`, `~/.local/state/llm-host/` | on a model host only: the script, its recipes, its log and pid |
| `/etc/apparmor.d/ai-app` | only if you ran `install-apparmor.sh` |

To uninstall, delete those. To start the ALCF setup over, delete
`~/.local/share/alcfai/home` and configure again.

## Troubleshooting

| you see | do |
|---|---|
| "Needs alcf-ai" | install the ALCF tools, then restart the app |
| "ALCF login needed" | click **Log in**, or run `alcf-tokens login inference` |
| a model "queued" or "offline" | pick a running one, or wait: ALCF loads models on demand |
| Codex: `bwrap: loopback: Failed RTM_NEWADDR` | run `./scripts/install-apparmor.sh`, restart the app |
| Codex: `stream disconnected before completion` | configure Codex again in the app (it re-applies its fixes) |
| no models listed in Configure | check `alcf-ai ls-models minerva` works in a terminal |
| a host shows "llm-host is not installed" | install it on the host ([docs/hosts.md](docs/hosts.md)); over SSH, set the host's llm-host command to `~/.local/bin/llm-host` |
| a host is unreachable | `ssh -o BatchMode=yes <host> -- llm-host status` must work in a terminal |
| "Tunnel: port 19931 is already in use" | another program (or an old app) holds the port: close it, or edit the host's local port |
| a model fails to start | open the host's **log**: often out of GPU memory; use a recipe with more `--n-cpu-moe` or a smaller window |
| tool calls show up as text | click **probe**; see the llama.cpp notes in [docs/local-wire-notes.md](docs/local-wire-notes.md) |

## Development

```bash
flutter pub get
flutter analyze && flutter test                               # app
python3 -I -m unittest discover -s host/tests -t .            # llm-host
python3 -I -m unittest discover -s tools/tests -t .           # webread
flutter run -d linux
dart run tool/e2e_configure.dart claude pi                    # real ALCF configure into the app folder
```

| folder | what |
|---|---|
| `lib/core/` | pure Dart: profiles, launch environments, ALCF CLI, model hosts, tunnels, agent configs, platform paths |
| `lib/app/`, `lib/ui/` | app state and Flutter UI |
| `host/` | `llm_host.py` and its tests (a fake llama-server) |
| `tools/` | `webread` |
| `scripts/` | install scripts per platform, `install-host.sh` |
| `docs/` | designs, plans, measured notes, end-to-end records |

CI (GitHub Actions) runs the tests and the Linux build on Ubuntu, builds the
macOS app and runs the Python tests on macOS, and builds the Windows app.

Design and plans: [docs/local-hosts-design.md](docs/local-hosts-design.md),
[docs/improvements-design.md](docs/improvements-design.md),
[docs/next-steps-plan.md](docs/next-steps-plan.md). End-to-end records:
[docs/e2e-2026-10-27.md](docs/e2e-2026-10-27.md),
[docs/e2e-2026-10-28-codex-opencode.md](docs/e2e-2026-10-28-codex-opencode.md).

## License

[MIT](LICENSE) © 2026 Corentin Ravoux.
