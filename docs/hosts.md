# Model hosts

A **model host** is a machine that runs llama-server for AI App: this PC
today, a mini AI PC later. Agents always run on the machine where the app
runs (your laptop, or the host itself); only the model is on the host.

```
 laptop (or the host itself)                       model host
┌──────────────────────────────┐                  ┌───────────────────────────────┐
│ AI App                       │   ssh (control)  │ llm-host  start/stop/status   │
│  ├ tab: Pi        ─┐         │ ───────────────► │   └ llama-server 127.0.0.1    │
│  ├ tab: OpenCode  ─┼► 127.0.0.1:19931 ══ssh -L══════► :9931  (one recipe)       │
│  └ tab: Claude    ─┘         │   over Tailscale │ recipes: ~/.config/llm-host/  │
└──────────────────────────────┘                  └───────────────────────────────┘
```

llama-server only ever listens on `127.0.0.1`. A remote laptop reaches it
through an SSH forward that the app keeps open; nothing is exposed to the
network and no API key is needed.

## llm-host

`host/llm_host.py`, installed as `~/.local/bin/llm-host`, owns the server
process. Python ≥ 3.11, standard library only.

| command | does |
|---|---|
| `llm-host list [--json]` | recipes in `~/.config/llm-host/recipes/` (invalid ones listed with the reason) |
| `llm-host status [--json]` | `stopped`, `loading`, `ready`, `foreign` (a server llm-host did not start holds the port) or `error` (last start failed: the log tail is in `error`) |
| `llm-host start <recipe> [--replace] [--wait 600]` | starts and waits for `/health`; exit 0 ready, 3 failed or timed out, 4 already running (use `--replace`), 5 foreign server on the port, 6 unknown recipe or model file missing |
| `llm-host stop` | stops the server it started; never touches a foreign one (exit 5) |
| `llm-host log [-n 80]` | tail of `~/.local/state/llm-host/server.log` |

The context reported by `status` is the server's own per-slot window (from
`/props`), not the recipe's `-c`: with `-np 2` each slot gets half.

A cold load of an 18 GB model on a 16 GB RAM machine takes 1–5 minutes,
longer when the system is swapping; hence the 600 s default wait.

## Recipes

One TOML file per tested launch, `~/.config/llm-host/recipes/<name>.toml`.
The file name is the recipe name and the model alias the agents see.

```toml
label = "Qwen3.6 35B-A3B · 64K"
model = "unsloth/Qwen3.6-35B-A3B-MTP-GGUF/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf"   # relative to models_dir
# mmproj = "…/mmproj-F16.gguf"                                               # optional, vision
ctx = 65536
max_output = 8192
args = ["-ngl", "99", "--n-cpu-moe", "20", "-t", "6", "-fa", "on",
        "-ctk", "q8_0", "-ctv", "q8_0", "-np", "1",
        "--chat-template-kwargs", "{\"enable_thinking\":false}"]
notes = "measured 2026-11-11, b12190"
```

llm-host adds `-m`, `--mmproj`, `--alias`, `-c`, `--host 127.0.0.1` and
`--port`; a recipe that sets any of them (or `--api-key`, `-hf`) is rejected.
Write recipes from measurements (`llm_probe.py`, `llama-bench`), not from
blog numbers: on a 12 GB GPU the `--n-cpu-moe` value decides whether the
model loads at all.

## Adding a model host (e.g. the mini PC)

1. **Engine.** Build llama.cpp with the GPU backend; keep the models on a
   large disk (`<models>/<hf repo>/<file>.gguf`).
2. **Measure.** For each model: find the offload and context that leave
   0.5–1 GB of VRAM free, and check with
   `python3 -I llm_probe.py --url http://127.0.0.1:9931` that tool calls,
   prefix caching and `/v1/messages` all PASS. Record the numbers.
3. **Install llm-host** from a checkout of this repository:
   `scripts/install-host.sh --server-bin <llama.cpp>/build/bin/llama-server --models-dir <models>`.
4. **Recipes.** Write one file per measured launch into
   `~/.config/llm-host/recipes/` (start from `recipes.example/`).
   `llm-host list` must show no invalid entry; `llm-host start <name>` must
   end `ready`.
5. **Network** (only for use from another machine): SSH server and
   Tailscale, see below.
6. **AI App → Add host.** On this machine choose *This machine*; from the
   laptop choose *Over SSH* with the host's SSH name. **Test** must answer
   `ready: …` or `reachable, no model running`.

## Network: SSH over Tailscale

Done once per host and per client machine. Steps with `sudo` are yours.

On the host:

```bash
sudo apt install openssh-server
sudo tee /etc/ssh/sshd_config.d/10-ai-app.conf <<'CONF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
CONF
sudo systemctl enable --now ssh
```

On the host and on the laptop: install Tailscale from its official apt
repository, then `sudo tailscale up` and sign in with the same account.
`tailscale status` must list both machines.

On the laptop:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ai_app -C ai-app   # with a passphrase, add it to ssh-agent:
                                                      # the app uses BatchMode and cannot type it
ssh-copy-id -i ~/.ssh/id_ai_app.pub <user>@<host tailscale name>
cat >> ~/.ssh/config <<'CONF'
Host pc
    HostName <host tailscale name>
    User <user>
    IdentityFile ~/.ssh/id_ai_app
    IdentitiesOnly yes
CONF
ssh pc hostname                              # accept the host key once
ssh -o BatchMode=yes pc -- llm-host status   # must print a status line
```

If the last command says `llm-host: command not found`, the non-interactive
shell lacks `~/.local/bin` on `PATH`: set the host's *llm-host command* in
AI App to the absolute path (`/home/<user>/.local/bin/llm-host`).

If the lab forbids Tailscale: any SSH route works (a reverse tunnel through a
machine both sides reach, a `ProxyJump`). The app only needs an SSH name that
`ssh -o BatchMode=yes <name>` can reach.

"Offline" means working at the host itself: two machines need the internet
to find each other through Tailscale unless they share a LAN.
