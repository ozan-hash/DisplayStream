# DisplayStream

Use a second Mac as an extended display over Wi-Fi — no AirPlay, no cables, no extra software needed.

Built entirely in Swift using `ScreenCaptureKit`, `Network.framework`, and `AppKit`. Two source files, zero dependencies.

---

## Why

AirPlay Receiver requires macOS 12 Monterey or newer on the target Mac. Older Macs (2015–2017 era) don't support it. DisplayStream fills that gap: the sender captures your screen and streams it as JPEG frames over TCP; the receiver displays them fullscreen.

---

## How it works

```
[2025 Mac — sender]                    [2016 Mac — receiver]
ScreenCaptureKit → JPEG → TCP :7878 →  NWListener → decode → NSImageView
```

- **Sender** (newer Mac): captures the selected display at up to 1920×1080 / 15 FPS using `SCStream`, compresses each frame to JPEG (~65% quality), and sends it over a length-prefixed TCP stream.
- **Receiver** (older Mac): listens on port 7878, reassembles the TCP byte stream into frames using a 4-byte big-endian length prefix, decodes JPEG in software (bypassing the hardware decoder that crashes on Intel + macOS 12), and renders the image fullscreen.

Frame protocol: `[UInt32 big-endian length][JPEG bytes]`

---

## Requirements

| Machine | Role | macOS | Notes |
|---------|------|-------|-------|
| Newer Mac (sender) | Sends the screen | macOS 13+ | Needs Screen Recording permission |
| Older Mac (receiver) | Shows the screen | macOS 12+ | Intel or Apple Silicon |

Both Macs must be on the same Wi-Fi network.

---

## Build & Run

### On the newer Mac (sender)

```bash
swiftc sender.swift -o sender -framework ScreenCaptureKit
```

### On the older Mac (receiver)

```bash
swiftc receiver.swift -o receiver
./receiver
```

AirDrop `receiver.swift` from the sender Mac if needed — or copy it any way you like.

---

## Usage

### 1. Start the receiver first

On the older Mac:

```bash
./receiver
```

A dark fullscreen window opens and waits for a connection.  
Press **Esc** to quit.

### 2. Find the receiver's IP address

On the older Mac:

```bash
ipconfig getifaddr en0
# e.g. 192.168.1.42
```

### 3. Start the sender

On the newer Mac — list available displays:

```bash
./sender <receiver-ip> list
```

Stream the main display:

```bash
./sender <receiver-ip>
```

Stream a specific display by index (useful for extended desktop setups):

```bash
./sender <receiver-ip> 1
```

**First run:** macOS will ask for Screen Recording permission. Grant it in System Settings → Privacy & Security → Screen Recording, then run again.

---

## Performance

| Setting | Value |
|---------|-------|
| Frame rate | 15 FPS |
| Max resolution | 1920 × 1080 |
| JPEG quality | 65% |
| Protocol | TCP (length-prefixed) |

These defaults work well on a local Wi-Fi network. Edit `sender.swift` to adjust FPS or quality.

---

## Troubleshooting

**"connection refused"** — Receiver isn't running. Start `./receiver` on the older Mac first.

**"connection timed out"** — Wrong IP, or the two Macs are on different networks. Double-check with `ipconfig getifaddr en0`.

**Screen Recording permission denied** — Go to System Settings → Privacy & Security → Screen Recording and enable the terminal app (Terminal.app or iTerm2).

**Blank / frozen screen** — The sender may have lost the stream. Press Ctrl+C on the sender and restart it.

---

## Technical notes

- **Hardware JPEG decoder crash (macOS 12 Intel):** `AppleVPA`/`CMPhoto` crashes with `SIGILL` on certain Intel Macs running macOS 12. The receiver pre-renders every JPEG into a plain `CGBitmapContext` (software path) before handing it to `NSImageView`, bypassing the hardware decoder entirely.
- **vImage color conversion crash:** `CoreAnimation` tries to convert `DeviceRGB` bitmaps to the display profile using an AVX2 vImage path that also crashes on macOS 12 Intel. Fixed by using `CGColorSpace.sRGB` with native BGRA (`byteOrder32Little | premultipliedFirst`) so no conversion is needed.
- **TCP framing:** `NWConnection` delivers data in arbitrary chunks. `FrameBuffer` accumulates bytes and extracts complete frames only when the full payload has arrived.
- **Race condition:** Each `NWConnection` runs on its own serial `DispatchQueue` — no locking needed in the hot path.

---

## License

MIT
