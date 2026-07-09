# Architecture

## The stack, bottom to top

### 1. Transport & security: Tailscale (WireGuard)

The app deliberately contains **no SSH stack, no TLS, no certificates**. Encryption,
authentication and roaming are delegated to WireGuard via Tailscale:

- A WireGuard session is keyed to device identities, not IP addresses. When the phone
  hops Wi-Fi → LTE, the tunnel re-targets silently; the TCP connection inside it
  **survives unchanged**. (Verified: a mux TCP connection kept the same 5-tuple across a
  Wi-Fi→tether switch, observed server-side over 350 consecutive `ss` snapshots.)
- Tailnet membership is the authentication boundary. See SERVER-SETUP.md for the
  additional per-port source-IP allowlists.

Practical consequence: the phone and the server **must be in the same tailnet**.
Cross-tailnet *node sharing* is not enough — shared nodes only pass SSH (port 22) with
default ACLs; arbitrary TCP ports are silently dropped (we measured this the hard way).

### 2. Protocol: the wezterm mux codec, spoken natively

`wezterm-mux-server` holds all terminal state (workspaces, tabs, panes, scrollback) and
talks a length-prefixed PDU protocol implemented in the vendored `codec` crate
(codec version **42** at the pinned wezterm release).

Key PDUs used by this client:

| PDU | Purpose |
|-----|---------|
| `GetCodecVersion` | handshake; hard-fail on mismatch |
| `SetClientId` | register this client |
| `ListPanes` | pane tree (window/tab/pane, sizes, titles, active flags) |
| `GetPaneRenderChanges` | subscribe; server then *pushes* screen deltas unilaterally (serial=0) |
| `GetLines` | fetch arbitrary `StableRowIndex` ranges (scrollback) |
| `WriteToPane` | key/paste input |
| `Resize` | reflow the pane to the phone's grid |
| `SpawnV2` / `KillPane` | new panes (also used by the automated smoke test) |

Because the server pushes rendered *line data* (not a byte stream), the client needs no
VT/escape parser — it is a true thin client.

The transport is a plain TCP socket to a `socat` bridge in front of the server's mux
unix socket. During development the same protocol was validated over
`ssh <host> "wezterm cli --prefer-mux proxy"` (see `wezterm/poc-attach/`, the headless
CLI client that still supports both transports).

### 3. Rust core: `wezterm-ios-core`

New crate in the vendored workspace. Single engine thread owns the connection:

```
Swift ──(UniFFI calls)──▶ Command channel ──▶ engine thread ──▶ TCP
Swift ◀─(delegate callbacks)── Snapshot/Row conversion ◀── PDU decode loop
```

- RPCs and unilateral pushes share one socket; while an RPC awaits its reply, unrelated
  PDUs are queued and replayed in order (no lost pushes).
- Color resolution happens **in Rust**: `Line` cells + the server-pushed `SetPalette`
  are flattened into `Span { text, fg: 0xRRGGBBAA, bg, flags }`. Swift never sees
  terminal attributes, only styled runs.
- `Snapshot` carries `physical_top` / `scrollback_top` (scrollback range) and
  `mouse_grabbed` (see Scrolling below).
- Public API (UniFFI proc-macro mode): `connect(addr, delegate)`,
  `list_panes`, `attach(pane, cols, rows)`, `send_input`, `resize`, `fetch_lines`,
  `spawn`, `kill`, `disconnect`; delegate receives `on_snapshot` / `on_disconnected`.

### 4. iOS app: SwiftUI thin client

- `ConnectionStore` implements the delegate; every callback hops to the MainActor before
  touching `@Published` state.
- `TerminalView` renders `Snapshot` rows as `AttributedString` in a vertical
  `ScrollView`, anchored to the bottom via `defaultScrollAnchor(.bottom)`.
- Pane fitting: cell metrics are measured from the monospaced font; `cols × rows` are
  derived from the available geometry and sent as `Resize` (debounced). The *server*
  reflows; the phone never horizontally clips.
- Key input: a `UIView` conforming to **`UITextInput`** (not just `UIKeyInput`) using
  the "fake document" technique — the document *is* the IME marked text. Committed text
  is sent as UTF-8; composition stays local (strip above the accessory bar). This is
  what makes Japanese flick input work.

## Scrolling: two modes, chosen per snapshot

This mirrors desktop WezTerm's semantics and was the subtlest part of the project:

1. **Local scrollback** (regular shell panes): upward scrolling lazily fetches history
   via `fetch_lines` (100-row chunks) into a row cache; a "↓ Live" pill returns to the
   tail. Auto-follow on new output only engages when the view is at the bottom and the
   user is not interacting (`onScrollGeometryChange` + `onScrollPhaseChange`; **never**
   `scrollTo` on every snapshot — with a busy pane that cancels the user's gesture
   continuously and scrolling feels "dead").
2. **Forwarded scrolling** (`mouse_grabbed == true`, e.g. full-screen TUIs like Claude
   Code): such panes keep no useful terminal scrollback (measured: 8 lines); the *app*
   inside the pane owns scrolling. Vertical drags are converted to SGR wheel events
   (`ESC [ < 64/65 ; col ; row M`, pane-center coordinates, one event per cell height)
   and the local ScrollView is disabled entirely to avoid double-scroll jitter. Non-grabbed
   panes with empty scrollback fall back to arrow keys ×3 (wezterm's
   `alternate_buffer_wheel_scroll_speed` default).

Note that forwarded scrolling is **session-shared**: every attached client (your desktop
included) sees the TUI scroll, because the application itself repaints. That is inherent
to multiplexer semantics, not a bug.

## Design decisions & trade-offs

- **Version pinning over protocol stability**: the wezterm mux protocol is explicitly
  not a stable API. Client and server are built from the same source tag; the codec
  handshake enforces it. Upgrading wezterm = rebuild both sides together.
- **socat over in-server TLS**: wezterm has a TLS domain mode, but certificates on a
  phone are friction. WireGuard already provides mutual auth + encryption; a dumb TCP
  bridge keeps the app footprint minimal.
- **No local echo prediction** (yet): wezterm's mux client has `local_echo_threshold_ms`
  upstream; the core is structured so this can be added later if latency ever hurts.
- **Free-account signing**: acceptable for a personal tool; the 7-day expiry is a
  documented operational chore, not an architectural constraint.

## Development history

The project was built in verified stages, each with its own design doc under
`docs/design/`:

1. Roaming proof over Tailscale (plain SSH, then the mux itself)
2. `poc-attach` v0/v1 — headless protocol client (read-only → interactive, ssh+tcp)
3. `wezterm-ios-core` — UniFFI core + smoke test
4. iOS dependency surgery (openssl removal, iOS target stubs) + SwiftUI app
5. Device build, IME, scrolling, saved connections
