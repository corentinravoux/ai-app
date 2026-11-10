# ALCF AI

A Linux desktop app that runs AI coding agents (Claude Code, Codex, OpenCode,
Pi) on the [ALCF Inference Endpoints](https://docs.alcf.anl.gov/services/inference-endpoints/),
in terminal tabs, side by side, and lets you switch between them. It can also
open your usual Claude Code accounts in the same window.

The app sets each agent up for ALCF with `alcf-ai agent configure`, but in a
folder of its own (`~/.local/share/alcfai/home`). Your normal agent settings
(`~/.claude`, `~/.codex`, `~/.pi`, `~/.config/opencode`) are never changed:
you can keep using the agents outside the app exactly as before.

No AI assistant is needed to install or use it: follow the steps below.

## What you need

- A Linux desktop, x86-64. Tested on Ubuntu 24.04.
- An ALCF account with access to the Inference Endpoints.
- At least one agent installed, with its own installer:
  [Claude Code](https://docs.anthropic.com/en/docs/claude-code),
  [Codex](https://github.com/openai/codex),
  [OpenCode](https://opencode.ai),
  [Pi](https://github.com/badlogic/pi-mono).
  You do not need an Anthropic or OpenAI subscription to use them on ALCF.
- [uv](https://docs.astral.sh/uv/) (for the ALCF command-line tools).
- To build the app: the [Flutter SDK](https://docs.flutter.dev/get-started/install/linux)
  and the Linux build tools. On Ubuntu:
  `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`

## Install

1. Install the ALCF tools and log in with your ALCF account (follow the
   login prompt; you will be asked to log in again about every 30 days):

   ```bash
   uv tool install alcf-ai
   uv tool install alcf-tokens
   alcf-tokens login inference
   ```

2. Build and install the app:

   ```bash
   git clone https://github.com/corentinravoux/alcfai-app
   cd alcfai-app
   ./scripts/install-linux.sh
   ```

   If Flutter is not on your `PATH`: `FLUTTER=/path/to/flutter/bin/flutter ./scripts/install-linux.sh`.

3. Ubuntu 23.10 and later only, if you use Codex: allow its command sandbox
   (asks for your password once):

   ```bash
   ./scripts/install-apparmor.sh
   ```

   Without it, every command Codex tries to run fails with
   `bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted`.
   The script installs the same small AppArmor profile Ubuntu ships for
   VS Code: it only lets the app use user namespaces.

4. Start **ALCF AI** from your applications menu.

To update later: `git pull` then `./scripts/install-linux.sh` again. Your
settings are kept.

## First use

The left sidebar lists the agents.

- **ALCF inference**: Claude, Pi, Codex and OpenCode served by ALCF.
  1. Click **Configure** next to an agent.
  2. Pick a cluster and a model. The status next to each model says whether
     it is running, queued (the first answer can take minutes while it loads)
     or offline.
  3. Click **Configure**. The app runs `alcf-ai agent configure` in its own
     folder and checks that your real settings files did not change.
  4. Click **Open**, choose the folder to work in, and the agent starts in a
     new tab.
- **Your Claude accounts**: Claude Code with your usual login, launched as is.
  The app finds `~/.claude` and every `~/.claude-<name>` folder that holds a
  login. To rename or choose them, see [Settings](#settings).

The bar above each tab says where its requests go ("Runs on ALCF tara,
model inkling-bf16"). If the ALCF login has expired, a banner offers
**Log in**; the app re-checks it every 3 hours.

Agents marked "Not installed" were not found. The app looks on your `PATH`
and in `~/.local/bin`, `~/.opencode/bin`, `~/.pi/agent/bin`, `~/.bun/bin`,
`~/.npm-global/bin` and `~/.cargo/bin`.

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

## Files it uses

| path | what |
|---|---|
| `~/.local/opt/alcfai-app/` | the installed app |
| `~/.local/share/applications/dev.ravoux.alcfai_app.desktop` | menu entry (plus icons under `~/.local/share/icons/hicolor/`) |
| `~/.local/share/alcfai/home/` | the agents' ALCF settings (the app's own "home"; `.globus` links to your ALCF login) |
| `~/.local/share/alcfai/state.json` | app state, no secrets |
| `/etc/apparmor.d/alcfai-app` | only if you ran `install-apparmor.sh` |

To uninstall, delete those. To start the ALCF setup over, delete
`~/.local/share/alcfai/home` and configure again.

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

## Troubleshooting

| you see | do |
|---|---|
| "Needs alcf-ai" | install the ALCF tools (Install, step 1), then restart the app |
| "ALCF login needed" | click **Log in**, or run `alcf-tokens login inference` |
| a model "queued" or "offline" | pick a running one, or wait: ALCF loads models on demand |
| Codex: `bwrap: loopback: Failed RTM_NEWADDR` | run `./scripts/install-apparmor.sh`, restart the app |
| Codex: `stream disconnected before completion` | configure Codex again in the app (it re-applies its fixes) |
| no models listed in Configure | check `alcf-ai ls-models minerva` works in a terminal |

## Development

```bash
flutter pub get
flutter test
flutter run -d linux
dart run tool/e2e_configure.dart claude pi   # real configure into the app folder
```

End-to-end records: [docs/e2e-2026-10-27.md](docs/e2e-2026-10-27.md),
[docs/e2e-2026-10-28-codex-opencode.md](docs/e2e-2026-10-28-codex-opencode.md).
