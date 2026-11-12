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

## A. Publish and CI

1. **Merge PR #2** (`fix/copilot-review-pr1`). It is safe to merge (see
   above). Side effect: local profile ids become `local-<agent>-<host>`, so
   "reopen last session" misses local tabs saved before the merge, once.
2. **Make the macOS CI job green.** Its step
   "llm-host tests (no /proc on macOS)" fails on every run since the PR #1
   merge (`d72aaaf`); the Linux job runs the same `ps` code path and passes,
   so the cause is specific to macOS's `ps` or the macOS runner. GitHub
   serves job logs only to a signed-in user:
   - paste the `FAIL:` / `ERROR:` lines and their tracebacks from that step,
     or install `gh` and run `gh auth login` so Claude can read the logs.
   - Done: the three CI jobs are green on `main`.
3. **Delete the stale remote branch**: `git push origin --delete local-hosts`
   (Claude's attempt was refused by the permission system).
4. **Node on PATH** on the PC: add
   `export PATH="$HOME/opt/node/bin:$HOME/.npm-global/bin:$PATH"` to
   `~/.bashrc`.

## B. Remote use from the laptop (first plan, Tasks 15 and 17)

1. On the PC, as root: `openssh-server` with password login off, and
   Tailscale. On the laptop: Tailscale, an `ai_app` SSH key, and a `pc`
   entry in `~/.ssh/config`. The commands are in [hosts.md](hosts.md)
   § Network.
2. On the laptop: pull `main`, `scripts/install-linux.sh`, re-run
   `scripts/install-apparmor.sh` (the profile was renamed to `ai-app`), then
   **Add host** → *Over SSH*, `pc` (llm-host command
   `~/.local/bin/llm-host`), then **Test**.
3. Drills, results into `docs/e2e-remote-<date>.md`:
   - Wi-Fi off for 30 s during a Pi turn. Expected: the row turns
     unreachable in about 15 s and comes back by itself.
   - Stop the model under an open tab.
   - Something else already listening on port 19931. Expected (after PR #2):
     "port 19931 is already in use on this machine", no retry storm.
   - The same work from a phone hotspot.
   - Close an SSH session and check the model is still loaded (systemd
     `KillUserProcesses`).

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
