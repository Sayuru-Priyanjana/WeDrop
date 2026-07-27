# WeDrop

WeDrop turns your computers and phones into one ecosystem on your local network.
Once two devices are paired they share clipboard, send files, mirror
notifications and control each other's media — automatically, encrypted, and
without any cloud service in between. Everything happens over the LAN and only
ever within your own paired group.

```
┌────────────┐         encrypted TCP          ┌────────────┐
│  Desktop   │◀──────── session + files ──────▶│   Phone    │
│  (Wails +  │                                 │  (Flutter  │
│   Go core) │◀──────── UDP discovery ────────▶│  + Go-parity│
└────────────┘                                 │   Dart core)│
                                               └────────────┘
```

## Layout

| Path       | What it is                                                        |
|------------|-------------------------------------------------------------------|
| `core/`    | The Go reference implementation: crypto, discovery, transport, transfer. Shared by the desktop app. |
| `desktop/` | The Wails desktop app (Go + React/TypeScript UI).                 |
| `mobile/`  | The Flutter app. Its `lib/core` is a faithful Dart port of the Go core, verified against it by a shared test fixture. |
| `testdata/`| Cross-language crypto vectors that both sides must reproduce.      |

## How it works

**Discovery.** Each device announces itself over UDP (multicast + broadcast +
per-interface directed broadcast, so it works on home Wi-Fi and phone hotspots
alike). Receivers trust the packet's *source* address rather than any address in
the payload — the single biggest cause of the old "device found but won't
connect" failures.

**Pairing.** To join an ecosystem a device dials with intent `pair`. Both ends
run a full authenticated handshake and display the same six-digit verification
code, derived from the negotiated session key. The user compares the codes and
accepts. Only then is the peer's *proven* identity key stored — never a key
taken from an unauthenticated announcement.

**Handshake.** X25519 for key agreement, Ed25519 to prove identity, and a
length-prefixed transcript that both sides sign. The raw shared secret is run
through HKDF-SHA256 (salted with both handshake nonces) to produce the AES-256
session key, so every session is unique and recorded sessions cannot be
replayed. See `core/crypto/kdf.go` and `core/transport/handshake.go`.

**Sessions.** Trusted, online peers keep one long-lived, multiplexed control
channel open, with keepalive pings and automatic reconnect with jittered
backoff. Clipboard, notifications and media commands ride this channel. Each
file transfer gets its own short-lived connection so a big file never stalls
sync.

**Capabilities & permissions.** Every feature has independent send/receive
switches globally, plus per-device overrides. A device advertises what it is
willing to receive, so peers skip work the user has turned off.

## Building

**Core (Go):**
```bash
cd core && go test ./...
```

**Desktop (Wails):**
```bash
cd desktop && wails build      # or: wails dev
```

**Mobile (Flutter):**
```bash
cd mobile && flutter build apk   # or: flutter run
```

## Cross-language safety

The Go and Dart crypto layers must agree byte-for-byte or a desktop and a phone
could never talk. This is enforced by a shared fixture:

```bash
cd core && go test ./crypto -run TestWriteInteropVectors   # writes testdata/crypto_interop.json
cd mobile && flutter test test/interop_test.dart           # Dart must reproduce every value
```

If HKDF, the verification code, or the AES-GCM frame layout ever diverged
between the two implementations, `interop_test.dart` fails.

## Running in the background

Both apps are built to keep syncing while out of sight. The desktop app hides to
the background on window close (toggleable) and can start on login. The mobile
app runs a foreground service holding a multicast lock, so discovery and
sessions survive the screen turning off.
