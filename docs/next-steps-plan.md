# AI App: next steps that need you

Date: 2026-11-11. Everything here needs your hands, a second machine, sudo,
or a decision. What did not is done on branch `local-hosts`
([improvements-plan.md](improvements-plan.md)). Each item says what to run
and what "done" looks like; tell Claude which ones you did and it picks up
from there.

## A. Publish

1. **Push the branch** and let CI run: `git push -u origin local-hosts`.
   - Done: the three jobs in `.github/workflows/ci.yml` are green on GitHub
     (Linux tests and build, macOS build plus the Python tests, Windows
     build).
   - If macOS or Windows fail, paste the log: those builds were never run
     locally.
2. **Merge** `local-hosts` into `main` (locally, or through a pull request)
   once CI is green.
3. **Node on PATH**: add `export PATH="$HOME/opt/node/bin:$HOME/.npm-global/bin:$PATH"`
   to `~/.bashrc` on the PC.

## B. Remote use from the laptop (first plan, Tasks 15 and 17)

1. On the PC, as root: `openssh-server` with password login off, and
   Tailscale. On the laptop: Tailscale, an `ai_app` SSH key, and a `pc`
   entry in `~/.ssh/config`. The commands are in [hosts.md](hosts.md)
   § Network.
2. On the laptop: pull, `scripts/install-linux.sh`, re-run
   `scripts/install-apparmor.sh` (the profile was renamed to `ai-app`), then
   **Add host** → *Over SSH*, `pc`, then **Test**.
3. Drills, results into `docs/e2e-remote-<date>.md`:
   - Wi-Fi off for 30 s during a Pi turn. Expected: the row turns
     unreachable in about 15 s and comes back by itself.
   - Stop the model under an open tab.
   - Something else already listening on port 19931.
   - The same work from a phone hotspot.
   - Close an SSH session and check the model is still loaded (systemd
     `KillUserProcesses`).

## C. macOS and Windows on real machines

CI only compiles them. On a Mac, `scripts/install-macos.sh`; on Windows,
`scripts\install-windows.ps1` in PowerShell. Things to check:

- **Agents** start in a tab: Pi, OpenCode and Claude Code installed with npm.
  On Windows they are `.cmd` shims.
- **Links** open with Ctrl+click.
- **Model hosts over SSH**: Windows has no ControlMaster, so each poll opens
  a new connection. If that is too slow, a persistent session is the next
  step.
- **ALCF** works on macOS. It is disabled on Windows on purpose.

**Windows agent tabs need a patched flutter_pty first** (found by the
round 2 review in `flutter_pty_win.c`). Its `build_command`:

- writes the executable and then every argv entry, including argv[0], so
  the program's path is passed twice;
- joins arguments with spaces and no quoting (cmd.exe then re-parses
  `.cmd` shims, and `<url>` becomes a redirection);
- casts UTF-8 bytes to WCHAR one by one, which breaks non-ASCII paths and
  environment values.

The plan: vendor flutter_pty under `third_party/`, drop argv[0] from the
command line, quote with MSVCRT rules, run `.cmd`/`.bat` through
`cmd.exe /d /s /c "…"` with cmd escaping, convert with
`MultiByteToWideChar(CP_UTF8)`. This needs a Windows machine to test
(CI only compiles it); say when one is available.

## D. Decisions and features waiting for you

1. **Full Claude on local hosts.** Your `CLAUDE.md`, commands and skills,
   with all of Claude Code's tools, when the window is large enough. The
   measured prompt size and the threshold are in `docs/local-wire-notes.md`
   (improvements plan, Task 8): 18,503 tokens, so it fits the 64K recipe.
   - Decide whether you want it, and whether per host or per tab.
   - It also needs an interactive check: first-run screens and the "use
     this API key?" prompt in a fresh config folder.
2. **Qwen Code and mini-swe-agent profiles.** Like Phase 0 of the first
   plan, each needs a by-hand session to confirm how its config folder can
   be redirected.
3. **Shorter old tool output for Pi.** The Lewis policy, as a Pi
   extension. Research first: measure on your own tasks with and without it.
4. **Web search** for local agents. It needs a search provider: a key, or a
   self-hosted SearXNG.
5. **Remote wake-up** of a host. It needs an always-on device at home.
