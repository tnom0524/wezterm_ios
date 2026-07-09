# Server setup

Target: a Linux host (tested: Ubuntu 22.04/24.04 on EC2) that will run
`wezterm-mux-server`, joined to your tailnet.

## 1. Install wezterm-mux-server (pinned version)

The codec version must match the app. This repo tracks
**20240203-110809-5046fc22** (codec v42):

```bash
curl -LO https://github.com/wez/wezterm/releases/download/20240203-110809-5046fc22/wezterm-20240203-110809-5046fc22.Ubuntu22.04.deb
sudo dpkg -i wezterm-20240203-110809-5046fc22.Ubuntu22.04.deb
# GUI dependency warnings are harmless for the mux server; if you care:
sudo apt-get install -f
```

The Ubuntu 22.04 .deb works on 24.04 as well (the missing GUI deps are irrelevant to the
mux server binary).

Start the server as your login user (it keeps sessions in memory; an EC2 reboot loses
them — see the runbook below):

```bash
wezterm-mux-server --daemonize
# unix socket appears at: /run/user/$(id -u)/wezterm/sock
```

## 2. Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
tailscale ip -4     # note this — e.g. 100.64.0.1 (call it <server-ts-ip>)
```

**Critical**: the server, your phone, and your Mac must be members of the **same
tailnet**. Cross-tailnet node *sharing* is not sufficient — with default ACLs, shared
nodes only pass SSH (port 22); the mux ports will be silently dropped at the WireGuard
layer and you will chase ghosts (we did).

## 3. Expose the mux socket with socat

The mux socket is unix-only; socat bridges it to TCP **on the tailnet IP only**, with a
per-port source-IP allowlist. One port per client device keeps the allowlists exact
(socat's `range=` takes a single CIDR):

```bash
sudo apt-get install -y socat

# Port 17777 → your desktop (e.g. 100.64.0.10)
nohup socat TCP4-LISTEN:17777,bind=<server-ts-ip>,reuseaddr,fork,range=<desktop-ts-ip>/32 \
      UNIX-CONNECT:/run/user/1000/wezterm/sock >/tmp/socat-desktop.log 2>&1 &

# Port 17778 → your phone (e.g. 100.64.0.11)
nohup socat TCP4-LISTEN:17778,bind=<server-ts-ip>,reuseaddr,fork,range=<phone-ts-ip>/32 \
      UNIX-CONNECT:/run/user/1000/wezterm/sock >/tmp/socat-phone.log 2>&1 &
```

Find your device IPs with `tailscale status` on the server.

### Verify

From the allowed desktop:

```bash
nc -z <server-ts-ip> 17777 && echo reachable
# then, from this repo:
cd wezterm && cargo build -p poc-attach
./target/debug/poc-attach tcp <server-ts-ip>:17777 list
# → prints codec handshake + your pane tree
```

In the app, add `<server-ts-ip>:17778` and tap.

## Security

Read this section twice. The mux protocol has **no authentication and no encryption**:
anyone who can open a TCP connection to the socat port owns your terminal sessions.

The three layers that make this safe:

1. **Never bind to a public interface.** `bind=<server-ts-ip>` ensures the listener only
   exists on the WireGuard interface. Nothing to scan from the internet.
2. **Tailnet membership** is mutual-auth: only your logged-in devices can produce
   packets that arrive at that interface.
3. **`range=` allowlist** pins each port to exactly one client IP — important if your
   tailnet contains devices you don't fully control (other users, work machines).

If your tailnet is multi-user, treat the allowlist as mandatory, not optional.

## Reboot runbook

Both the mux server (in-memory sessions) and the nohup'd socats die on reboot:

```bash
# after server reboot:
wezterm-mux-server --daemonize
# re-run both socat lines above
```

(Turning these into systemd units is a straightforward improvement — PRs welcome.
The socket path `/run/user/<uid>/wezterm/sock` requires the user session; use
`loginctl enable-linger <user>` if you go that route.)

Note: if the mux server restarts, clients' workspaces are gone; desktop WezTerm users
re-create them with `wezterm cli spawn --new-window --domain-name <dom> --workspace default`
from an external terminal. The iOS app simply lists whatever panes exist.

## Operational notes learned in production

- **Restart tailscaled after re-authenticating a long-running node.** We re-authed a
  node into a different tailnet while `tailscaled` had been up for a month; path
  establishment was flaky until `sudo systemctl restart tailscaled`.
- **Fresh peer pairs may need a first packet from the server side.** Right after a node
  joins, client→server connections can time out while the NAT traversal warms up.
  `tailscale ping <client-ip>` *from the server* opens the path immediately.
- **Killing socat**: `pkill -f "socat TCP4-LISTEN"` run over SSH matches *your own SSH
  command line* and kills your session. Use `pkill -x socat`, or split kill and start
  into separate SSH invocations.
