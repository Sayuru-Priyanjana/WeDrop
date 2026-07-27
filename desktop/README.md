# WeDrop — Desktop

The Wails desktop client. Go backend (`service.go`, `api.go`, platform helpers)
bridged to a React/TypeScript frontend in `frontend/`.

- `service.go` — app lifecycle, discovery/session wiring, clipboard watcher,
  inbound pairing and transfers.
- `api.go` — every method bound into the frontend (pair, send files, settings,
  media, diagnostics).
- `state.go` — the snapshot the UI renders from, plus the feed ring buffers.
- `media_*.go`, `autostart_*.go` — per-OS media keys and login startup.

The shared protocol/crypto/transport code lives in `../core`.

## Live development

```bash
wails dev
```

Runs a Vite dev server with hot reload for the frontend, plus a dev server on
http://localhost:34115 for calling the Go methods from browser devtools.

## Building

```bash
wails build
```

Produces `build/bin/desktop.exe`. Closing the window keeps the app running in
the background (so clipboard, files and notifications keep flowing); this is
toggleable under Settings → Startup.
