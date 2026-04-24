// receiver.swift — 2016 MacBook Pro için
// swiftc receiver.swift -o receiver && ./receiver
import AppKit
import Foundation
import Network
import CoreGraphics

// Serial queue üzerinde çalışır — race condition yok
final class FrameBuffer {
    private var buf = Data()
    var onFrame: ((Data) -> Void)?

    func append(_ chunk: Data) {
        buf.append(chunk)
        drain()
    }

    private func drain() {
        while buf.count >= 4 {
            let s = buf.startIndex   // removeFirst sonrası 0 olmayabilir
            let len = Int(
                (UInt32(buf[s    ]) << 24) |
                (UInt32(buf[s + 1]) << 16) |
                (UInt32(buf[s + 2]) <<  8) |
                 UInt32(buf[s + 3])
            )
            guard len > 0, len < 10_000_000 else { buf.removeAll(); return }
            guard buf.count >= 4 + len else { return }
            let frame = Data(buf[s + 4 ..< s + 4 + len])  // startIndex-relative range
            buf.removeFirst(4 + len)
            onFrame?(frame)
        }
    }
}

// JPEG → plain CGBitmapContext → NSImage
// Hardware JPEG decoder (AppleVPA/CMPhoto) bypass — macOS 12 Intel bug workaround
func decodeJPEG(_ data: Data) -> NSImage? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { return nil }

    let w = cg.width, h = cg.height
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
        data: nil, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    ) else { return nil }

    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let bitmap = ctx.makeImage() else { return nil }
    return NSImage(cgImage: bitmap, size: NSSize(width: w, height: h))
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var imageView: NSImageView!
    private var statusLabel: NSTextField!
    private var listener: NWListener!
    private var connData: [ObjectIdentifier: (DispatchQueue, FrameBuffer)] = [:]

    func applicationDidFinishLaunching(_ n: Notification) {
        buildWindow()
        startServer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    private func buildWindow() {
        let screen = NSScreen.main!
        let rect   = screen.frame

        window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = NSColor(white: 0.05, alpha: 1)
        window.level = .floating
        window.isOpaque = true
        window.makeKeyAndOrderFront(nil)

        imageView = NSImageView(frame: NSRect(origin: .zero, size: rect.size))
        imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(imageView)

        statusLabel = NSTextField(labelWithString: "DisplayStream\nPort 7878'de bağlantı bekleniyor…\n\nÇıkmak için Esc")
        statusLabel.textColor       = NSColor(white: 0.8, alpha: 1)
        statusLabel.font            = .systemFont(ofSize: 18, weight: .medium)
        statusLabel.backgroundColor = .clear
        statusLabel.isBezeled       = false
        statusLabel.isEditable      = false
        statusLabel.alignment       = .center
        statusLabel.sizeToFit()
        statusLabel.frame.origin    = CGPoint(
            x: (rect.width  - statusLabel.frame.width)  / 2,
            y: (rect.height - statusLabel.frame.height) / 2
        )
        window.contentView!.addSubview(statusLabel)

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { NSApplication.shared.terminate(nil) }
            return event
        }
    }

    private func startServer() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try! NWListener(using: params, on: 7878)

        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            let key    = ObjectIdentifier(conn)
            // Serial queue — her bağlantı için ayrı, race condition yok
            let serial = DispatchQueue(label: "ds.conn.\(key.hashValue)", qos: .userInteractive)
            let fb     = FrameBuffer()

            DispatchQueue.main.async { self.connData[key] = (serial, fb) }

            fb.onFrame = { [weak self] data in
                // JPEG decode burada (serial queue'da) yapılıyor — main thread'e ham bitmap gidiyor
                guard let img = decodeJPEG(data) else { return }
                DispatchQueue.main.async {
                    self?.imageView.image      = img
                    self?.statusLabel.isHidden = true
                }
            }

            conn.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    DispatchQueue.main.async {
                        self?.connData.removeValue(forKey: key)
                        self?.statusLabel.isHidden = false
                    }
                }
            }

            func recv() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 131_072) { data, _, done, err in
                    if let data, !data.isEmpty { fb.append(data) }
                    if !done && err == nil { recv() }
                }
            }

            conn.start(queue: serial) // serial queue — kritik düzeltme
            recv()
        }

        listener.stateUpdateHandler = { state in
            if case .ready = state { print("DisplayReceiver hazır — port 7878") }
        }
        listener.start(queue: .global())
    }
}

let app      = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
