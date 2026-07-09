# Troubleshooting

Everything below actually happened during development. Symptoms first.

## Connection

### "codec version mismatch" on connect
Client and server must be built from the same wezterm source tag (this repo: 20240203,
codec v42). Upgrade both together; there is no compatibility window.

### App shows instant "TCP connection failed"
The address points at something that isn't there. Check, in order:

1. Is the entry's address the server's **tailnet IP** and the **right port**?
   (A saved entry silently pointing at an old IP or at the server's *public* IP
   reproduces this exactly — the mux port only exists on the tailnet interface.)
2. Is the phone's Tailscale connected, **and on the same tailnet as the server**?
   Profile switching is per-device; a phone left on another tailnet gets fast failures
   for hosts that don't exist there.

### Connect hangs, then times out
The SYN is being dropped before reaching the server. Causes we hit:

- **Cross-tailnet node sharing**: with default ACLs, shared nodes pass only SSH
  (port 22). Everything else is dropped silently — `tcpdump -ni tailscale0` on the
  server shows nothing. Fix: put all devices in one tailnet (sharing is not enough).
- **socat allowlist mismatch**: the client's tailnet IP isn't the one in `range=`.
  Check `tailscale status` for the real IP; update the socat invocation.
- **Fresh-peer path warm-up**: right after a node joins a tailnet, client→server may
  time out while NAT traversal establishes. From the *server*:
  `tailscale ping <client-ip>` — the path opens and stays open.
- **Stale tailscaled**: a daemon that has been up for weeks handles re-auth poorly.
  `sudo systemctl restart tailscaled` on the server fixed repeated flapping for us.

### Worked yesterday, dead today (device app)
Free-account signing expires after 7 days — the app won't launch (not a network issue).
Rebuild + reinstall (BUILD.md §4). Saved connections survive reinstalls.

### After EC2 reboot
Both the mux server (sessions are in-memory!) and the socats are gone. Runbook in
SERVER-SETUP.md. The app itself needs no changes.

## Scrolling

### Can't scroll in a full-screen TUI pane (Claude Code, vim, …)
Expected mechanics: those panes keep (almost) no terminal scrollback; scrolling means
*forwarding wheel events to the application*. The app does this automatically when the
pane reports `mouse_grabbed`. Two consequences:

- Scrolling such a pane scrolls it **for every attached client** (your desktop too).
  That's multiplexer semantics, not a bug.
- If the TUI app doesn't react to SGR wheel events, nothing will scroll — same as
  desktop WezTerm.

### Scrolling feels dead / view snaps back while output streams
If you fork this code: never call `scrollTo` on every snapshot. Busy panes push several
snapshots per second and each programmatic scroll cancels the in-flight user gesture.
Auto-follow must be gated on "at bottom AND scroll phase idle"
(`onScrollGeometryChange` / `onScrollPhaseChange`, iOS 18+).

## Input / IME

### Software keyboard doesn't appear (simulator)
Simulator menu: **I/O → Keyboard → Connect Hardware Keyboard** off (⇧⌘K), then ⌘K if
still hidden. With a hardware keyboard "connected", iOS suppresses the software
keyboard even though first-responder status is fine. On a real device this problem
doesn't exist.

### Japanese/flick input types Latin letters only
`keyboardType` must be `.default` (not `.asciiCapable`), and the input view must
implement `UITextInput` (marked-text composition), not just `UIKeyInput`. This repo
already does; noted for forks.

### Backspace does nothing (edge case)
Some IME states stop delivering `deleteBackward` when the fake document is empty. If
you can reproduce it, the known fix is a sentinel character in the document; file an
issue with the exact keyboard + state.

## Simulator-specific

### Drag/scroll gestures don't register
Two-finger trackpad scrolling is delivered as wheel events, which never reach touch
`DragGesture`s. **Click and drag** (mouse-style) to simulate a finger. Cost us a full
debugging session.

### App can't reach the tailnet
The simulator shares the Mac's network stack: the Mac's Tailscale must be connected.
(No Tailscale app inside the simulator is needed or possible.)

## Server-side foot-guns

### Killing socat kills your SSH session
`ssh host 'pkill -f "socat TCP4-LISTEN..."'` — the pattern matches the remote shell's
own command line (it contains the socat string you're about to start/kill), taking your
session down with exit 255. Use `pkill -x socat`, or separate kill/start SSH calls.

### socat `range=` syntax
`range=100.64.0.11/32` requires `TCP4-LISTEN` (with plain `TCP-LISTEN` you get
"syntax error in range … of unspecified address family").

## Build

### `xcodebuild … generic/platform=iOS` fails: "team has no devices"
Free accounts need the device registered; building with
`-destination 'platform=iOS,id=<udid>'` + `-allowProvisioningUpdates` auto-registers
the connected phone. Pairing prompt issues: `xcrun devicectl manage pair`.

### Vendored wezterm doesn't build on new Rust
The tree carries small forward-compat fixes (see UPSTREAM-CHANGES.md). If a newer
toolchain introduces more (the never-type-fallback class of errors), apply the same
minimal-annotation pattern — and please PR it.
