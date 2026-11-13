# Web search with SearXNG

Local agents search the web with `websearch <query>` (Pi has it as the
`web_search` tool). It asks a [SearXNG](https://docs.searxng.org) instance
you run yourself: a free, open-source metasearch engine. No account and no
API key. SearXNG forwards each query to public engines (Google, Bing,
DuckDuckGo, Wikipedia…), so those engines still see the queries, but not
who you are beyond your IP address.

Run it on the machine where AI App runs (the agents call it from there):
your laptop, and the PC too if you use AI App on the PC.

## Install (Linux, macOS)

Needs Docker or Podman. On Ubuntu: `sudo apt install docker.io`, then
`sudo usermod -aG docker $USER` and log out and back in.

```bash
cd ai-app
./scripts/install-searxng.sh
```

The script writes `~/.config/ai-app/searxng/settings.yml` once (macOS:
`~/Library/Application Support/ai-app/searxng/`), with JSON output on and the
bot limiter off, then runs the `ai-app-searxng` container on
`127.0.0.1:8899` only, restarted with the machine. Check:

```bash
websearch flutter pty          # numbered results
```

Update: run the script again (settings are kept). Remove:
`./scripts/install-searxng.sh --remove`.

## Another address

`websearch` uses, in this order: `AI_APP_SEARXNG_URL`, the file
`~/.config/ai-app/searxng-url` (one line, e.g. `http://127.0.0.1:8080`),
then `http://127.0.0.1:8899`. Any SearXNG works if its `settings.yml`
has `search.formats: [html, json]`.

## When it fails

| `websearch` says | do |
|---|---|
| `SearXNG is not running at …` | start it: `./scripts/install-searxng.sh` (or `docker start ai-app-searxng`) |
| `refuses JSON (HTTP 403)` | add `json` to `search.formats` in its `settings.yml`, then `docker restart ai-app-searxng` |
| `rate limiting (HTTP 429)` | set `server.limiter: false` in its `settings.yml`, restart it |
| `No results for: …` | an upstream engine may block it for a while; try again later, or enable other engines in `settings.yml` |

Reading a page (`webread <url>`) needs no SearXNG.
