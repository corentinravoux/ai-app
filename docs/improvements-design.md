# AI App — round 2 improvements: design

Date: 2026-11-11. Builds on [local-hosts-design.md](local-hosts-design.md).
Plans: [improvements-plan.md](improvements-plan.md) (executed now, no user
step needed) and [next-steps-plan.md](next-steps-plan.md) (needs the user,
a second machine, or a decision).

## Intent

The user tested the local-hosts branch on the PC ("very nice") and asked for
every improvement that does not need them to test, the repository rename
carried through locally (GitHub is now `corentinravoux/ai-app`), a better
README, and macOS and Windows installs "if that is easy".

## Decisions

| topic | decision |
|---|---|
| Rename | `origin` → `git@github.com:corentinravoux/ai-app.git`; every local reference to `alcfai-app` as a repo or URL updated (the ALCF sandbox path `~/.local/share/alcfai/` stays, as before). |
| License and CI | The user's rule for applications: README, MIT license, CI tests. Add `LICENSE` (MIT, Corentin Ravoux) and a GitHub Actions workflow. The user pushes; CI runs then. |
| Review leftovers | Fix every "minor (deferred)" item of the first review (ledger in `.superpowers/sdd/local-hosts-plan/progress.md`). |
| Project overrides (new finding) | Under `--bare`, a project's `.claude/settings.json` `env` still overrides `ANTHROPIC_BASE_URL` and the model (measured). Local Claude is launched with `--setting-sources user`; local OpenCode with `OPENCODE_DISABLE_PROJECT_CONFIG=1`. Bedrock/Vertex/Foundry switches are stripped from local tabs. |
| macOS and Windows | flutter_pty and xterm support both. Make the client code portable (home folder, PATH separator, executable lookup, opening links, ssh control sockets), add the `macos/` and `windows/` runners, install scripts, and CI builds on macOS and Windows runners. ALCF on Windows is disabled (alcf-ai's home redirection and the `.globus` symlink are POSIX-only). Agents and ssh on Windows are best effort and marked untested. llm-host gains a macOS code path (no `/proc`) so a Mac mini can be a model host. |
| Probe | `llm-host probe` checks a ready server (structured tool call, Anthropic endpoint, generation speed) and the host row gets a Probe button. |
| Measurements | Measure a vision recipe (Qwen3.6 + mmproj) and the prompt size of a full (non-`--bare`) local Claude, record them; the full-Claude mode itself waits for the user (next-steps). |

## Non-goals (this round)

Remote wake-up, Qwen Code / mini-swe-agent profiles, tool-output shortening
for Pi, a web search tool, Tasks 15–17 of the first plan, signing or
notarising macOS/Windows builds, merging or pushing.

## Anti-goals

- Any change that makes a local tab able to reach Anthropic, ALCF or a
  cloud provider, or that writes into the user's real agent configs.
- Breaking the Linux build or any existing test to gain portability.
- Claiming macOS or Windows "work": they are built by CI, not run.
