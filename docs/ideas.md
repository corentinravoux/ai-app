# AI App: ideas for later

Collected 2026-11-13 from the plans and reviews. Nothing here is scheduled;
each line says what it would take. Active work is in
[next-steps-plan.md](next-steps-plan.md).

## Platforms

- **macOS and Windows on real machines** (next-steps § C): install with
  `scripts/install-macos.sh` / `scripts\install-windows.ps1`, open agent tabs,
  check links and model hosts over SSH. CI only compiles them today.
- **Windows agent tabs**: vendor and patch flutter_pty (`flutter_pty_win.c`:
  argv[0] passed twice, no quoting, byte-wise UTF-8). Needs a Windows machine.
- **Persistent SSH session on Windows** (no ControlMaster there), if polling
  over a fresh connection each time proves too slow.

## Network

- **Another way to connect than Tailscale**: own WireGuard (needs a public
  IPv4 and a port forward), Headscale (self-hosted Tailscale control server,
  needs a public server), NetBird or ZeroTier, a reverse SSH tunnel through a
  reachable machine, or the lab's own VPN or SSH gateway.
- **SSH on the PC only through Tailscale** with ufw:
  `sudo ufw allow in on tailscale0 to any port 22 proto tcp`,
  `sudo ufw deny 22/tcp`, `sudo ufw enable`.
- **Remote wake-up of the PC**: the PC is on Wi-Fi, where wake-on-LAN rarely
  works. Either Ethernet + wake-on-LAN in the BIOS + an always-on device at
  home (router or Raspberry Pi), or a smart plug + "power on after AC loss"
  in the BIOS.

## Agents and context

- **Shorter old tool output for Pi** (the Lewis policy: keep the last 4 tool
  results whole, head and tail of older ones), as a Pi extension. Large gains
  at 20K windows, about none at 262K: measure on 10–20 of your own tasks at
  64K before adopting it.
- **mini-swe-agent profile**: a minimal bash-only agent, useful to compare
  harnesses on the same tasks rather than for daily coding.

## Known small issues, accepted

- While a bad entry stays in `hosts.json`, every launch makes another
  `hosts.json.dropped-*` copy and repeats the notice. Fix: skip the copy when
  an earlier `.dropped-*` holds the same bytes.
- On Windows, `webread.cmd` still cuts a URL at an unquoted `&` or `)` when a
  shell other than Pi calls it (cmd.exe expands `%*` before parsing). Fix:
  callers quote the URL, or ship a small launcher instead of a `.cmd`.
