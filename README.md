# WezTerm Mobile

A native iOS thin client for the [WezTerm](https://wezfurlong.org/wezterm/) multiplexer.
Attach to `wezterm-mux-server` sessions running on your remote machines — no tmux, no mosh,
no SSH stack inside the app. Roaming (Wi-Fi ⇄ LTE) is handled by
[Tailscale](https://tailscale.com/)/WireGuard underneath, so sessions survive network switches.

日本語版: [README.ja.md](README.ja.md)

```
iPhone (SwiftUI)                            Your server (EC2 etc.)
┌───────────────────────────┐               ┌─────────────────────────┐
│ Terminal UI / IME / keys  │               │ wezterm-mux-server      │
│   ↕ UniFFI                │  Tailscale    │   ↕ unix socket         │
│ Rust core                 │═══════════════│ socat  TCP:17778        │
│  (wezterm codec + TCP)    │  (WireGuard   │  (tailnet-only,         │
└───────────────────────────┘   encrypts +  │   source-IP allowlist)  │
                                 roams)     └─────────────────────────┘
```

## Why

- **tmux-free**: the WezTerm mux already keeps sessions alive server-side. This app speaks
  its native protocol (`codec` crate) directly, so your phone sees the *same* workspace,
  tabs and panes as your desktop WezTerm.
- **mosh-free**: mosh's killer features are replaced piecewise — roaming and encryption by
  WireGuard/Tailscale, prediction by the mux's client-side design, session persistence by
  the mux server itself.
- **Thin**: the server renders; the app just draws lines and forwards keys. No VT parser,
  no TLS, no SSH inside the app.

## Features

- Multiple named connections (saved in-app)
- Pane list → tap to attach; pane reflows to the phone's cell grid
- Color rendering, bold/italic/underline, cursor
- Software keyboard incl. **Japanese IME / flick input** (UITextInput with proper
  composition handling), accessory bar for Esc / Tab / Ctrl / arrows / ^C
- Scrollback for regular panes; wheel-event forwarding for full-screen TUI apps that grab
  the mouse (matches desktop WezTerm semantics — e.g. scrolling a Claude Code transcript)
- Reconnect-friendly: the mux keeps all state; reattaching is cheap

## Requirements

| Where | What |
|-------|------|
| Server | Linux with `wezterm-mux-server` **20240203-110809-5046fc22**, `socat`, Tailscale |
| Phone | iOS 18+, Tailscale app joined to the *same tailnet* as the server |
| Build machine | macOS with Xcode 16+, Rust (stable), `xcodegen` |

The wezterm codec version must match on both ends — this repo vendors the wezterm
20240203 source tree (with iOS portability patches, see
[docs/UPSTREAM-CHANGES.md](docs/UPSTREAM-CHANGES.md)) so client and server speak codec v42.

## Getting started

1. **Server**: [docs/SERVER-SETUP.md](docs/SERVER-SETUP.md) — install the mux server,
   expose its unix socket on your tailnet IP with socat, lock it down to your devices.
2. **Build & install the app**: [docs/BUILD.md](docs/BUILD.md) — Rust → XCFramework →
   SwiftUI app, simulator and device instructions included.
3. Add your server in the app (`+` button): `100.x.y.z:17778`, tap, done.

If something misbehaves, [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) collects every
pitfall we actually hit while building this (there were many).

## Repository layout

```
wezterm/            vendored wezterm 20240203 source + patches
  wezterm-ios-core/   the Rust core exposed to Swift via UniFFI (new crate)
  poc-attach/         headless CLI client used to validate the protocol (new crate)
ios/                SwiftUI app (xcodegen project)
docs/               architecture, setup, build, troubleshooting, design history
```

## Security model

The mux protocol is **unauthenticated and unencrypted** by design (it normally never
leaves a unix socket). This project keeps it safe by stacking:

1. WireGuard encryption + identity (Tailscale) — nothing is exposed to the internet
2. socat binds only to the server's tailnet IP
3. socat `range=` allowlists restrict each port to one client device IP

Never expose the socat port on a public interface. See
[docs/SERVER-SETUP.md](docs/SERVER-SETUP.md#security) for details.

## Status & caveats

Personal-tool grade, working end-to-end on a real device. Known rough edges:

- Rendering is AttributedString-based (fine for typical panes; not optimized for
  very large scrollback batches)
- Composition candidates window placement for IME is approximate
- Free Apple ID signing expires every 7 days (rebuild + reinstall, or join the
  Developer Program)

## License

MIT — see [LICENSE](LICENSE). The `wezterm/` tree is Wez Furlong's work (MIT), vendored
with small patches; see [NOTICE](NOTICE) and [docs/UPSTREAM-CHANGES.md](docs/UPSTREAM-CHANGES.md).
