# AI App: next steps that need you

Updated 2026-11-12. Everything here needs your hands, a second machine,
sudo, a GitHub login, or a decision. Work that needed none of these is done
and on `main`: [local-hosts-plan.md](local-hosts-plan.md),
[improvements-plan.md](improvements-plan.md),
[review-minors-plan.md](review-minors-plan.md). Each item says what to do
and what "done" looks like; tell Claude which ones you did and it picks up
from there.

## Done since the last update

- PR #1 (`local-hosts`) merged; the review fixes (`f4119f1`, `c571681`)
  and the deferred review minors (`168f58a`) are on `main`.
- PR #2 (Copilot review fixes) was read and run locally on 2026-11-12:
  analyzer clean, 256 Dart tests, the `llm-host` and `webread` suites pass;
  its Linux and Windows CI jobs are green.

## A. Publish and CI — done 2026-11-12

- PR #2 merged; stale `local-hosts` branch deleted; Node on `PATH` in
  `~/.bashrc`.
- CI green on Linux, macOS and Windows. The macOS `llm-host` tests had
  timed out (21 min) because Python's `HTTPServer` does a reverse DNS
  lookup at bind time that stalls on macOS runners; the test fakes now
  skip it. Failing tests are published as annotations (readable without a
  GitHub login), and the actions no longer run on Node 20.

## B. Remote use from the laptop — done 2026-11-13

Tailscale + SSH (key-only) between the work laptop and the home PC; AI App
on the laptop starts, probes and uses the PC's model; the drills passed.
Record: [e2e-remote-2026-11-13.md](e2e-remote-2026-11-13.md). Later, maybe:
another way to connect than Tailscale (self-hosted WireGuard, Headscale,
NetBird), and limiting SSH on the PC to the Tailscale interface with ufw.

## C. macOS and Windows on real machines

CI only compiles them. On a Mac, `scripts/install-macos.sh`; on Windows,
`scripts\install-windows.ps1` in PowerShell. Things to check:

- **Agents** start in a tab: Pi, OpenCode and Claude Code installed with npm.
- **Links** open with Ctrl+click.
- **Model hosts over SSH**, including a Mac used as a host (`llm-host`
  pinned to a Python ≥ 3.11 by `install-host.sh`).
- **ALCF** works on macOS. It is disabled on Windows on purpose.
- **Windows over SSH** has no ControlMaster, so each poll opens a new
  connection. If that is too slow, a persistent session is the next step.

**Windows agent tabs need a patched flutter_pty first** (round 2 review,
`flutter_pty_win.c`). Its `build_command`:

- writes the executable and then every argv entry, including argv[0], so
  the program's path is passed twice;
- joins arguments with spaces and no quoting (cmd.exe then re-parses
  `.cmd` shims, and `<url>` becomes a redirection);
- casts UTF-8 bytes to WCHAR one by one, which breaks non-ASCII paths and
  environment values.

The plan: vendor flutter_pty under `third_party/`, drop argv[0] from the
command line, quote with MSVCRT rules, run `.cmd`/`.bat` through
`cmd.exe /d /s /c "…"` with cmd escaping, convert with
`MultiByteToWideChar(CP_UTF8)`. Needs a Windows machine to test; say when
one is available.

## D. Decisions and features waiting for you

1. **Full Claude on local hosts.** Your `CLAUDE.md`, commands and skills,
   with all of Claude Code's tools. Measured at 18,503 tokens on the first
   turn, so it fits the 64K recipe ([local-wire-notes.md](local-wire-notes.md)).
   - Decide whether you want it, and whether per host or per tab.
   - It needs an interactive check: first-run screens and the API-key
     prompt in a fresh config folder (full mode uses `apiKeyHelper`).
2. **Qwen Code and mini-swe-agent profiles.** Each needs a by-hand session
   to confirm how its config folder can be redirected.
3. **Shorter old tool output for Pi.** The Lewis policy, as a Pi extension.
   Research first: measure on your own tasks with and without it.
4. **Web search** for local agents. It needs a search provider: a key, or a
   self-hosted SearXNG.
5. **Remote wake-up** of a host. It needs an always-on device at home.

## E. Known small issues, accepted for now

- While a bad entry stays in `hosts.json`, every launch makes another
  `hosts.json.dropped-*` copy and repeats the notice (fix the file to stop
  it).
- On Windows, `webread.cmd` still cuts a URL at an unquoted `&` or `)` when
  a shell other than Pi calls it (cmd.exe expands `%*` before parsing).
